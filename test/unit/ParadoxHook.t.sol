// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}    from "forge-std/Test.sol";
import "forge-std/Vm.sol";

import {IPoolManager}          from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}               from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency}              from "v4-core/types/Currency.sol";
import {Hooks}                 from "v4-core/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {ParadoxHook}         from "../../src/core/ParadoxHook.sol";
import {EpochManager}        from "../../src/core/EpochManager.sol";
import {YieldRouter}         from "../../src/core/YieldRouter.sol";
import {RateOracle}          from "../../src/core/RateOracle.sol";
import {FYToken}             from "../../src/tokens/FYToken.sol";
import {VYToken}             from "../../src/tokens/VYToken.sol";
import {FixedDateEpochModel} from "../../src/epochs/FixedDateEpochModel.sol";
import {PositionId}          from "../../src/libraries/PositionId.sol";

/// @title ParadoxHookTest
/// @notice Unit tests for ParadoxHook callback logic.
///
/// Strategy: stub IPoolManager to control getSlot0/getLiquidity return values.
/// Deploy real core contracts and wire them to the hook, making tests
/// integration-level for the hook↔core boundary.
///
/// Architecture notes (post-refactor):
///   - No PositionManager — the hook mints FYT+VYT directly in afterAddLiquidity.
///   - afterInitialize is a no-op; pool registration happens via initializePool().
///   - beforeRemoveLiquidity REVERTS during an active epoch (RemovalBlockedUntilMaturity).
///   - afterAddLiquidity decodes the real LP address from hookData; falls back to sender.
///   - positionId is captured from the PositionOpened event.
///
/// Test organisation
/// -----------------
///   Section A  — getHookPermissions
///   Section B  — initializePool + afterInitialize
///   Section C  — afterAddLiquidity (FYT/VYT minting)
///   Section D  — beforeRemoveLiquidity (removal lock)
///   Section E  — afterSwap
///   Section F  — access control
///   Section G  — openNextEpoch

// =============================================================================
// Mock PoolManager
// =============================================================================

contract MockPoolManager {
    uint160 public sqrtPriceX96 = 2 ** 96;
    uint128 public poolLiq      = 1_000_000e18;

    function getLiquidity(PoolId) external view returns (uint128) { return poolLiq; }

    // StateLibrary reads slot0 via extsload.
    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(sqrtPriceX96));
    }
    function extsload(bytes32, uint256 count) external view returns (bytes32[] memory r) {
        r = new bytes32[](count);
        r[0] = bytes32(uint256(sqrtPriceX96));
        if (count > 1) r[1] = bytes32(uint256(poolLiq));
    }

    // Minimal stub so BaseHook constructor doesn't revert.
    function isValidHookAddress(address, Hooks.Permissions memory)
        external pure returns (bool) { return true; }

    // modifyLiquidity stub — MaturityVault calls this at redemption.
    function modifyLiquidity(
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (BalanceDelta) { return toBalanceDelta(0, 0); }

    function setOperator(address, bool) external {}

    function setSqrtPrice(uint160 p) external { sqrtPriceX96 = p; }
    function setLiquidity(uint128 l) external { poolLiq = l; }
}

// =============================================================================
// Test contract
// =============================================================================

contract ParadoxHookTest is Test {
    using PoolIdLibrary for PoolKey;

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    ParadoxHook      internal hook;
    EpochManager     internal em;
    YieldRouter      internal yr;
    RateOracle       internal oracle;
    FYToken          internal fyt;
    VYToken          internal vyt;
    FixedDateEpochModel internal model;
    MockPoolManager  internal mockPM;

    address internal constant OWNER  = address(0xA110CE);
    address internal constant LP     = address(0xAB01);
    address internal constant VAULT  = address(0xDEAD);
    address internal constant TOKEN0 = address(0xE0);

    // Hook address: afterInitialize(12)|afterAddLiquidity(10)|
    //               beforeRemoveLiquidity(9)|afterSwap(6) = 0x1640
    address internal constant HOOK_ADDR = address(uint160(0x1640));

    PoolKey  internal KEY;
    PoolId   internal POOL;

    uint32  internal constant EPOCH_DURATION = 30 days;
    uint64  internal constant T0             = 1_700_000_000;
    uint256 internal constant MIN_RATE       = 0.0001e18;

    ParadoxHook.InitParams internal INIT_PARAMS;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.warp(T0);
        vm.chainId(1);

        mockPM = new MockPoolManager();
        model  = new FixedDateEpochModel();

        // Core contracts — authorizedCaller set to hook after etch.
        em     = new EpochManager(OWNER, address(0));
        yr     = new YieldRouter(OWNER, address(0), em);
        oracle = new RateOracle(OWNER, address(0));

        vm.prank(OWNER);
        yr.setMaturityVault(VAULT);

        // Tokens — no burners yet; roles granted after etch.
        address[] memory noBurners = new address[](0);
        fyt = new FYToken(OWNER, address(0), noBurners, "");
        vyt = new VYToken(OWNER, address(0), noBurners, "", fyt);

        // Etch hook to the permission-encoded address.
        // Constructor: (poolManager, epochManager, yieldRouter, rateOracle, fyt, vyt, owner)
        ParadoxHook tempHook = new ParadoxHook(
            IPoolManager(address(mockPM)),
            em, yr, oracle,
            fyt, vyt,
            OWNER
        );
        vm.etch(HOOK_ADDR, address(tempHook).code);
        vm.store(HOOK_ADDR, bytes32(0), vm.load(address(tempHook), bytes32(0)));
        hook = ParadoxHook(HOOK_ADDR);

        // Wire authorizations.
        vm.startPrank(OWNER);
        em.setAuthorizedCaller(HOOK_ADDR);
        yr.setAuthorizedCaller(HOOK_ADDR);
        oracle.setAuthorizedCaller(HOOK_ADDR);
        // Token roles: hook mints, VAULT burns (stands in for MaturityVault).
        fyt.grantRole(fyt.MINTER_ROLE(), HOOK_ADDR);
        fyt.grantRole(fyt.BURNER_ROLE(), VAULT);
        vyt.grantRole(vyt.MINTER_ROLE(), HOOK_ADDR);
        vyt.grantRole(vyt.BURNER_ROLE(), VAULT);
        vm.stopPrank();

        KEY = PoolKey({
            currency0:   Currency.wrap(TOKEN0),
            currency1:   Currency.wrap(address(0xE1)),
            fee:         3000,
            tickSpacing: 60,
            hooks:       hook
        });
        POOL = KEY.toId();

        INIT_PARAMS = ParadoxHook.InitParams({
            model:       address(model),
            modelParams: abi.encode(uint32(EPOCH_DURATION)),
            alphaWad:    0.80e18,
            betaWad:     0.30e18,
            gammaWad:    0.15e18
        });

        // Register pool with Paradox Fi core (opens first epoch).
        vm.prank(OWNER);
        hook.initializePool(KEY, INIT_PARAMS, MIN_RATE);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// Trigger the no-op afterInitialize callback (confirms selector only).
    function _afterInitialize() internal returns (bytes4) {
        vm.prank(address(mockPM));
        return hook.afterInitialize(address(0), KEY, uint160(2**96), 0);
    }

    /// Add liquidity for LP via afterAddLiquidity, encoding LP in hookData.
    /// Returns positionId captured from PositionOpened event.
    function _addLiquidity(address lp, int256 liquidityDelta)
        internal returns (uint256 positionId)
    {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower:      -100,
            tickUpper:       100,
            liquidityDelta:  liquidityDelta,
            salt:            bytes32(0)
        });

        vm.recordLogs();
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            address(mockPM), KEY, mlp,
            toBalanceDelta(0, 0), toBalanceDelta(0, 0),
            abi.encode(lp)  // hookData carries the real LP address
        );

        // PositionOpened(bytes32 indexed poolId, uint256 indexed positionId,
        //                uint256 indexed epochId, uint128 liquidity, uint128 halfNotional)
        bytes32 sig = keccak256(
            "PositionOpened(bytes32,uint256,uint256,uint128,uint128)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                positionId = uint256(logs[i].topics[2]);
                break;
            }
        }
        require(positionId != 0, "ParadoxHookTest: PositionOpened event not found");
    }

    /// Add liquidity with empty hookData (falls back to sender = mockPM).
    function _addLiquidityNoHookData(int256 liquidityDelta)
        internal returns (uint256 positionId)
    {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: liquidityDelta, salt: bytes32(0)
        });
        vm.recordLogs();
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            address(mockPM), KEY, mlp,
            toBalanceDelta(0, 0), toBalanceDelta(0, 0),
            ""  // empty hookData → sender (mockPM) is recipient
        );
        bytes32 sig = keccak256(
            "PositionOpened(bytes32,uint256,uint256,uint128,uint128)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                positionId = uint256(logs[i].topics[2]);
                break;
            }
        }
    }

    /// Execute a swap producing feeAmount tokens of input.
    function _swap(int128 amount0In) internal {
        SwapParams memory sp = SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(amount0In),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(amount0In, -amount0In);
        vm.prank(address(mockPM));
        hook.afterSwap(address(0), KEY, sp, delta, "");
    }

    /// Attempt removal — will revert with RemovalBlockedUntilMaturity during epoch.
    function _removeLiquidity(int256 delta) internal {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: delta, salt: bytes32(0)
        });
        vm.prank(address(mockPM));
        hook.beforeRemoveLiquidity(address(0), KEY, mlp, "");
    }

    // =========================================================================
    // A — getHookPermissions
    // =========================================================================

    function test_permissions_correctFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();

        assertFalse(p.beforeInitialize);
        assertTrue(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertTrue(p.afterAddLiquidity);
        assertTrue(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    // =========================================================================
    // B — initializePool + afterInitialize
    // =========================================================================

    function test_initializePool_registersPool() public view {
        assertTrue(hook.registeredPools(POOL));
    }

    function test_initializePool_registersOracle() public view {
        assertTrue(oracle.registered(PoolId.unwrap(POOL)));
    }

    function test_initializePool_opensFirstEpoch() public view {
        assertTrue(em.hasActiveEpoch(POOL));
    }

    function test_initializePool_alreadyRegisteredReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(ParadoxHook.PoolAlreadyRegistered.selector, POOL)
        );
        hook.initializePool(KEY, INIT_PARAMS, MIN_RATE);
    }

    function test_initializePool_nonOwnerReverts() public {
        // Build a different pool key so it isn't already registered.
        PoolKey memory otherKey = KEY;
        otherKey.fee = 500;

        vm.prank(LP);
        vm.expectRevert(ParadoxHook.NotOwner.selector);
        hook.initializePool(otherKey, INIT_PARAMS, MIN_RATE);
    }

    function test_afterInitialize_isNoOp_returnsSelector() public {
        // afterInitialize is a no-op — pool registration happens via initializePool.
        // It must return the correct selector and not revert.
        bytes4 sel = _afterInitialize();
        assertEq(sel, IHooks.afterInitialize.selector);
    }

    function test_afterInitialize_doesNotDoubleRegister() public {
        // Calling afterInitialize should not revert even though pool is already registered.
        _afterInitialize();
        // Pool state unchanged.
        assertTrue(hook.registeredPools(POOL));
        assertTrue(em.hasActiveEpoch(POOL));
    }

    // =========================================================================
    // C — afterAddLiquidity (FYT+VYT minting)
    // =========================================================================

    function test_afterAddLiquidity_mintsFYTToLP() public {
        uint256 pid = _addLiquidity(LP, 1_000e18);
        // FYT amount = halfNotional. Must be > 0.
        assertGt(fyt.balanceOf(LP, pid), 0);
    }

    function test_afterAddLiquidity_mintsVYTToLP() public {
        uint256 pid = _addLiquidity(LP, 1_000e18);
        assertEq(vyt.balanceOf(LP, pid), 1);
    }

    function test_afterAddLiquidity_fytAmountIsHalfNotional() public {
        uint256 pid = _addLiquidity(LP, 1_000e18);
        FYToken.PositionData memory pos = fyt.getPosition(pid);
        assertEq(fyt.balanceOf(LP, pid), pos.halfNotional);
    }

    function test_afterAddLiquidity_storesPositionMetadata() public {
        uint256 pid = _addLiquidity(LP, 1_000e18);
        FYToken.PositionData memory pos = fyt.getPosition(pid);

        assertEq(pos.poolId,    PoolId.unwrap(POOL));
        assertEq(pos.tickLower, -100);
        assertEq(pos.tickUpper,  100);
        assertEq(pos.liquidity,  1_000e18);
        assertEq(pos.epochId,    em.activeEpochIdFor(POOL));
    }

    function test_afterAddLiquidity_incrementsEpochPositionCount() public {
        uint256 epochId = em.activeEpochIdFor(POOL);
        uint256 before  = fyt.epochPositionCount(epochId);

        _addLiquidity(LP, 1_000e18);

        assertEq(fyt.epochPositionCount(epochId), before + 1);
    }

    function test_afterAddLiquidity_addsNotionalToEpoch() public {
        _addLiquidity(LP, 1_000e18);
        EpochManager.Epoch memory ep = em.getEpoch(em.activeEpochIdFor(POOL));
        assertGt(ep.totalNotional, 0);
    }

    function test_afterAddLiquidity_hookDataRecipientOverridesSender() public {
        // When hookData encodes LP, FYT goes to LP (not sender = mockPM).
        uint256 pid = _addLiquidity(LP, 1_000e18);
        assertGt(fyt.balanceOf(LP, pid), 0);
        assertEq(fyt.balanceOf(address(mockPM), pid), 0);
    }

    function test_afterAddLiquidity_emptyHookDataFallsBackToSender() public {
        // Empty hookData → sender (mockPM) receives FYT+VYT.
        uint256 pid = _addLiquidityNoHookData(1_000e18);
        assertGt(fyt.balanceOf(address(mockPM), pid), 0);
    }

    function test_afterAddLiquidity_multipleDeposits_uniquePositionIds() public {
        uint256 pid1 = _addLiquidity(LP, 1_000e18);
        uint256 pid2 = _addLiquidity(LP, 2_000e18);
        assertTrue(pid1 != pid2);
    }

    function test_afterAddLiquidity_zeroLiquidityReverts() public {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: 0, salt: bytes32(0)
        });
        vm.prank(address(mockPM));
        vm.expectRevert(ParadoxHook.ZeroLiquidity.selector);
        hook.afterAddLiquidity(
            LP, KEY, mlp,
            toBalanceDelta(0,0), toBalanceDelta(0,0),
            abi.encode(LP)
        );
    }

    function test_afterAddLiquidity_unregisteredPoolReverts() public {
        PoolKey memory otherKey = KEY;
        otherKey.fee = 500;
        PoolId otherPool = otherKey.toId();

        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: 1_000e18, salt: bytes32(0)
        });
        vm.prank(address(mockPM));
        vm.expectRevert(
            abi.encodeWithSelector(ParadoxHook.PoolNotRegistered.selector, otherPool)
        );
        hook.afterAddLiquidity(
            LP, otherKey, mlp,
            toBalanceDelta(0,0), toBalanceDelta(0,0),
            abi.encode(LP)
        );
    }

    function test_afterAddLiquidity_returnsZeroDelta() public {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: 1_000e18, salt: bytes32(0)
        });
        vm.prank(address(mockPM));
        (, BalanceDelta delta) = hook.afterAddLiquidity(
            address(mockPM), KEY, mlp,
            toBalanceDelta(0,0), toBalanceDelta(0,0),
            abi.encode(LP)
        );
        assertEq(delta.amount0(), 0);
        assertEq(delta.amount1(), 0);
    }

    // =========================================================================
    // D — beforeRemoveLiquidity (removal lock)
    // =========================================================================

    function test_beforeRemoveLiquidity_revertsWhileEpochActive() public {
        _addLiquidity(LP, 1_000e18);

        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(activeEpoch);

        vm.expectRevert(
            abi.encodeWithSelector(
                ParadoxHook.RemovalBlockedUntilMaturity.selector,
                POOL,
                ep.maturity
            )
        );
        _removeLiquidity(-1_000e18);
    }

    function test_beforeRemoveLiquidity_allowedAfterSettlement() public {
        _addLiquidity(LP, 1_000e18);

        // Settle the epoch.
        uint256 epochId = em.activeEpochIdFor(POOL);
        vm.warp(T0 + EPOCH_DURATION);
        em.settle(epochId, 0, 0, 0);

        // No active epoch → removal no longer blocked.
        // Should return the selector without reverting.
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: -1_000e18, salt: bytes32(0)
        });
        vm.prank(address(mockPM));
        bytes4 sel = hook.beforeRemoveLiquidity(address(0), KEY, mlp, "");
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_beforeRemoveLiquidity_unregisteredPoolReverts() public {
        PoolKey memory otherKey = KEY;
        otherKey.fee = 500;
        PoolId otherPool = otherKey.toId();

        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: -1_000e18, salt: bytes32(0)
        });
        vm.prank(address(mockPM));
        vm.expectRevert(
            abi.encodeWithSelector(ParadoxHook.PoolNotRegistered.selector, otherPool)
        );
        hook.beforeRemoveLiquidity(address(0), otherKey, mlp, "");
    }

    // =========================================================================
    // E — afterSwap
    // =========================================================================

    function test_afterSwap_recordsOracleObservation() public {
        _addLiquidity(LP, 1_000e18);
        uint16 before = oracle.observationCount(PoolId.unwrap(POOL));
        _swap(100_000e18);
        assertGt(oracle.observationCount(PoolId.unwrap(POOL)), before);
    }

    function test_afterSwap_ingestsFeesToYieldRouter() public {
        _addLiquidity(LP, 1_000e18);
        _swap(100_000e18);

        uint256 epochId = em.activeEpochIdFor(POOL);
        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(epochId);
        uint256 total = uint256(bal.fixedAccrued)
                      + uint256(bal.variableAccrued)
                      + uint256(bal.reserveContrib);
        assertGt(total, 0);
    }

    function test_afterSwap_noActiveEpoch_skipsGracefully() public {
        // Settle the epoch then swap — must not revert.
        uint256 epochId = em.activeEpochIdFor(POOL);
        vm.warp(T0 + EPOCH_DURATION);
        em.settle(epochId, 0, 0, 0);

        _swap(100_000e18);
    }

    function test_afterSwap_returnsZeroHookDelta() public {
        _addLiquidity(LP, 1_000e18);

        SwapParams memory sp = SwapParams({
            zeroForOne: true, amountSpecified: -100_000e18, sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(100_000e18, -100_000e18);

        vm.prank(address(mockPM));
        (, int128 hookDelta) = hook.afterSwap(address(0), KEY, sp, delta, "");
        assertEq(hookDelta, 0);
    }

    function test_afterSwap_unregisteredPool_skipsGracefully() public {
        PoolKey memory otherKey = KEY;
        otherKey.fee = 500;

        SwapParams memory sp = SwapParams({
            zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0
        });
        // Should return selector + 0 delta without reverting.
        vm.prank(address(mockPM));
        (bytes4 sel, int128 hd) = hook.afterSwap(
            address(0), otherKey, sp, toBalanceDelta(0,0), ""
        );
        assertEq(sel, IHooks.afterSwap.selector);
        assertEq(hd, 0);
    }

    // =========================================================================
    // F — access control (onlyPoolManager)
    // =========================================================================

    function test_afterInitialize_notPoolManagerReverts() public {
        vm.prank(LP);
        vm.expectRevert();
        hook.afterInitialize(address(0), KEY, uint160(2**96), 0);
    }

    function test_afterAddLiquidity_notPoolManagerReverts() public {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: 1_000e18, salt: bytes32(0)
        });
        vm.prank(LP);
        vm.expectRevert();
        hook.afterAddLiquidity(
            LP, KEY, mlp,
            toBalanceDelta(0,0), toBalanceDelta(0,0),
            abi.encode(LP)
        );
    }

    function test_beforeRemoveLiquidity_notPoolManagerReverts() public {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: -1_000e18, salt: bytes32(0)
        });
        vm.prank(LP);
        vm.expectRevert();
        hook.beforeRemoveLiquidity(LP, KEY, mlp, "");
    }

    function test_afterSwap_notPoolManagerReverts() public {
        SwapParams memory sp = SwapParams({
            zeroForOne: true, amountSpecified: -100e18, sqrtPriceLimitX96: 0
        });
        vm.prank(LP);
        vm.expectRevert();
        hook.afterSwap(address(0), KEY, sp, toBalanceDelta(0,0), "");
    }

    // =========================================================================
    // G — openNextEpoch
    // =========================================================================

    function test_openNextEpoch_ownerCanOpen() public {
        // Settle current epoch.
        uint256 epochId = em.activeEpochIdFor(POOL);
        vm.warp(T0 + EPOCH_DURATION);
        em.settle(epochId, 0, 0, 0);
        assertFalse(em.hasActiveEpoch(POOL));

        // Seed oracle with enough observations.
        vm.prank(OWNER);
        oracle.setAuthorizedCaller(OWNER);
        vm.prank(OWNER);
        oracle.setTwapWindowObservations(3);
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 4 hours);
            vm.prank(OWNER);
            oracle.record(POOL, 10e18, 1_000_000e18);
        }
        vm.prank(OWNER);
        oracle.setAuthorizedCaller(HOOK_ADDR);

        vm.prank(OWNER);
        hook.openNextEpoch(POOL);

        assertTrue(em.hasActiveEpoch(POOL));
    }

    function test_openNextEpoch_newEpochIdDifferent() public {
        uint256 epoch0 = em.activeEpochIdFor(POOL);

        vm.warp(T0 + EPOCH_DURATION);
        em.settle(epoch0, 0, 0, 0);

        vm.prank(OWNER);
        oracle.setAuthorizedCaller(OWNER);
        vm.prank(OWNER);
        oracle.setTwapWindowObservations(3);
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 4 hours);
            vm.prank(OWNER);
            oracle.record(POOL, 10e18, 1_000_000e18);
        }
        vm.prank(OWNER);
        oracle.setAuthorizedCaller(HOOK_ADDR);

        vm.prank(OWNER);
        hook.openNextEpoch(POOL);

        uint256 epoch1 = em.activeEpochIdFor(POOL);
        assertTrue(epoch1 != epoch0);
    }

    function test_openNextEpoch_nonOwnerReverts() public {
        vm.prank(LP);
        vm.expectRevert(ParadoxHook.NotOwner.selector);
        hook.openNextEpoch(POOL);
    }

    function test_openNextEpoch_unregisteredPoolReverts() public {
        PoolId unknown = PoolId.wrap(keccak256("UNKNOWN"));
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(ParadoxHook.PoolNotRegistered.selector, unknown)
        );
        hook.openNextEpoch(unknown);
    }

    function test_openNextEpoch_activeEpochReverts() public {
        // Epoch is still active — openNextEpoch should revert.
        uint256 activeEpoch = em.activeEpochIdFor(POOL);
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                EpochManager.EpochAlreadyActive.selector,
                POOL,
                activeEpoch
            )
        );
        hook.openNextEpoch(POOL);
    }
}

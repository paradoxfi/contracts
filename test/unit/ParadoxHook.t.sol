// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}         from "forge-std/Test.sol";
import {StdCheats}         from "forge-std/StdCheats.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}      from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency}     from "v4-core/types/Currency.sol";
import {Hooks}        from "v4-core/libraries/Hooks.sol";

import {ParadoxHook}    from "../../src/core/ParadoxHook.sol";
import {EpochManager}   from "../../src/core/EpochManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {YieldRouter}    from "../../src/core/YieldRouter.sol";
import {RateOracle}     from "../../src/core/RateOracle.sol";
import {FixedDateEpochModel} from "../../src/epochs/FixedDateEpochModel.sol";
import {PositionId}         from "../../src/libraries/PositionId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title ParadoxHookTest
/// @notice Unit tests for ParadoxHook callback logic using mock stubs.
///
/// Strategy: we stub IPoolManager so we control getSlot0() and getLiquidity()
/// return values. We deploy real core contracts (EpochManager, PositionManager,
/// YieldRouter, RateOracle) and wire them up to the hook, making the tests
/// integration-level for the hook↔core boundary.
///
/// Test organisation
/// -----------------
///   Section A  — getHookPermissions
///   Section B  — afterInitialize
///   Section C  — afterAddLiquidity
///   Section D  — beforeRemoveLiquidity
///   Section E  — afterSwap
///   Section F  — access control
///   Section G  — openNextEpoch (governance)

// =============================================================================
// Mock PoolManager
// =============================================================================

contract MockPoolManager {
    // Configurable return values for the hook to read.
    uint160 public sqrtPriceX96 = 2 ** 96; // price = 1.0 (sqrtPrice = 2^96)
    uint128 public liquidity    = 1_000_000e18;

    function getSlot0(PoolId)
        external view
        returns (uint160 _sqrtPrice, int24, uint16, uint24)
    {
        return (sqrtPriceX96, 0, 0, 0);
    }

    function getLiquidity(PoolId) external view returns (uint128) {
        return liquidity;
    }

    // StateLibrary reads slot0 via extsload at a computed storage slot.
    // We implement extsload and return our configured sqrtPrice packed
    // into the slot0 layout: sqrtPriceX96 occupies bits 0-159.
    function extsload(bytes32) external view returns (bytes32) {
        // slot0 layout: sqrtPriceX96 (160 bits) | tick (24) | ...
        // Pack sqrtPriceX96 into the lower 160 bits.
        return bytes32(uint256(sqrtPriceX96));
    }

    // StateLibrary also uses extsload for getLiquidity.
    // It reads a different slot — we need to distinguish them.
    // Simpler: implement the multi-slot variant too.
    function extsload(bytes32, uint256 count) external view returns (bytes32[] memory result) {
        result = new bytes32[](count);
        result[0] = bytes32(uint256(sqrtPriceX96)); // slot0
        if (count > 1) result[1] = bytes32(uint256(liquidity)); // liquidity slot
    }

    // Minimal stubs so BaseHook constructor doesn't revert.
    function isValidHookAddress(address, Hooks.Permissions memory)
        external pure returns (bool) { return true; }

    function setSqrtPrice(uint160 p) external { sqrtPriceX96 = p; }
    function setLiquidity(uint128 l) external { liquidity = l; }
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
    PositionManager  internal pm;
    YieldRouter      internal yr;
    RateOracle       internal oracle;
    FixedDateEpochModel internal model;
    MockPoolManager  internal mockPM;

    address internal constant OWNER  = address(0xA110CE);
    address internal constant LP     = address(0xAB1);
    address internal constant VAULT  = address(0xDEAD);
    address internal constant TOKEN0 = address(0xE0);

    PoolKey  internal KEY;
    PoolId   internal POOL;

    uint32  internal constant EPOCH_DURATION = 30 days;
    uint64  internal constant T0 = 1_700_000_000;

    // Canonical InitParams for afterInitialize.
    ParadoxHook.InitParams internal INIT_PARAMS;

    function setUp() public {
        vm.warp(T0);
        vm.chainId(1);

        mockPM = new MockPoolManager();
        model  = new FixedDateEpochModel();

        // Deploy core contracts with a temporary zero authorized caller.
        // The real hook address is wired in after etching.
        em     = new EpochManager(OWNER, address(0));
        pm     = new PositionManager(OWNER, address(0));
        yr     = new YieldRouter(OWNER, address(0), em);
        oracle = new RateOracle(OWNER, address(0));

        vm.prank(OWNER);
        yr.setMaturityVault(VAULT);

        // ── Hook address surgery ──────────────────────────────────────────────
        // v4 validates that the hook address encodes permission flags in its
        // lower bits. The required mask for our flags is:
        //   afterInitialize(12) | afterAddLiquidity(10) |
        //   beforeRemoveLiquidity(9) | afterSwap(6)
        //   = 0x1640
        //
        // Strategy:
        //   1. Deploy the hook at a throwaway address to capture its bytecode.
        //   2. etch that bytecode onto the correctly-masked address.
        //   3. Re-initialise storage by calling a setup helper via the etched address.
        //
        // Because the constructor args are encoded into initcode (not stored in
        // the deployed bytecode), we re-run initialisation by casting the etched
        // address and calling an internal init helper exposed for tests.

        address HOOK_ADDR = address(uint160(0x1640));

        deployCodeTo("ParadoxHook.sol", abi.encode(mockPM, em,pm,yr,oracle,OWNER), HOOK_ADDR);
    

        hook = ParadoxHook(HOOK_ADDR);

        // Wire hook as authorized caller on all core contracts.
        vm.startPrank(OWNER);
        em.setAuthorizedCaller(HOOK_ADDR);
        pm.setAuthorizedCaller(HOOK_ADDR);
        yr.setAuthorizedCaller(HOOK_ADDR);
        oracle.setAuthorizedCaller(HOOK_ADDR);
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

        uint256 MIN_RATE = 0.0001e18;
        vm.prank(OWNER);
        hook.initializePool(KEY, INIT_PARAMS, MIN_RATE);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Call afterInitialize as PoolManager.
    function _initialize() internal {
        vm.prank(address(mockPM));
        hook.afterInitialize(
            address(0), KEY, uint160(2**96), 0
        );
    }

    /// Call afterAddLiquidity as PoolManager with given liquidity delta.
    function _addLiquidity(int256 liquidityDelta) internal returns (uint256 positionId) {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower:      -100,
            tickUpper:      100,
            liquidityDelta: liquidityDelta,
            salt:           bytes32(0)
        });

        // Snapshot counter before mint — next positionId uses counter + 1.
        uint32 nextCounter = pm.poolCounter(POOL) + 1;

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            LP, KEY, mlp,
            toBalanceDelta(0, 0), toBalanceDelta(0, 0),
            ""
        );

        // PositionId is deterministic: same encoding as PositionId.encode(pool, counter).
        positionId = PositionId.encode(POOL, nextCounter);
    }

    /// Call afterSwap as PoolManager with a zeroForOne swap of given input.
    function _swap(int128 amount0In) internal {
        SwapParams memory sp = SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(amount0In), // exact input negative
            sqrtPriceLimitX96: 0
        });

        // delta: amount0 positive (pool received), amount1 negative (pool sent)
        BalanceDelta delta = toBalanceDelta(amount0In, -amount0In);

        vm.prank(address(mockPM));
        hook.afterSwap(address(0), KEY, sp, delta, "");
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
    }

    // =========================================================================
    // B — afterInitialize
    // =========================================================================

    function test_afterInitialize_registersPool() public {
        _initialize();
        assertTrue(hook.registeredPools(POOL));
    }

    function test_afterInitialize_registersOraclePool() public {
        _initialize();
        assertTrue(oracle.registered(PoolId.unwrap(POOL)));
    }

    function test_afterInitialize_opensFirstEpoch() public {
        _initialize();
        assertTrue(em.hasActiveEpoch(POOL));
    }

    function test_afterInitialize_returnsCorrectSelector() public {
        vm.prank(address(mockPM));
        bytes4 sel = hook.afterInitialize(
            address(0), KEY, uint160(2**96), 0
        );
        assertEq(sel, hook.afterInitialize.selector);
    }

    // =========================================================================
    // C — afterAddLiquidity
    // =========================================================================

    function test_afterAddLiquidity_mintsPositionNFT() public {
        _initialize();
        _addLiquidity(1_000e18);
        assertEq(pm.balanceOf(LP), 1);
    }

    function test_afterAddLiquidity_storesCorrectFields() public {
        _initialize();
        uint256 pid = _addLiquidity(1_000e18);

        PositionManager.Position memory pos = pm.getPosition(pid);
        assertEq(PoolId.unwrap(pos.poolId), PoolId.unwrap(POOL));
        assertEq(pos.epochId, em.activeEpochIdFor(POOL));
        assertEq(pos.liquidity, 1_000e18);
        assertFalse(pos.exited);
    }

    function test_afterAddLiquidity_addsNotionalToEpoch() public {
        _initialize();
        _addLiquidity(1_000e18);

        uint256 epochId = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epochId);
        assertTrue(ep.totalNotional > 0);
    }

    function test_afterAddLiquidity_zeroLiquidityReverts() public {
        _initialize();

        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: 0, salt: bytes32(0)
        });

        vm.prank(address(mockPM));
        vm.expectRevert(ParadoxHook.ZeroLiquidity.selector);
        hook.afterAddLiquidity(LP, KEY, mlp, toBalanceDelta(0,0), toBalanceDelta(0,0), "");
    }

    function test_afterAddLiquidity_unregisteredPoolReverts() public {
        PoolKey memory otherKey = KEY;
        otherKey.fee = 500;
        PoolId otherPool = otherKey.toId();

        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: 1000e18, salt: bytes32(0)
        });

        vm.prank(address(mockPM));
        vm.expectRevert(
            abi.encodeWithSelector(ParadoxHook.PoolNotRegistered.selector, otherPool)
        );
        hook.afterAddLiquidity(LP, otherKey, mlp, toBalanceDelta(0,0), toBalanceDelta(0,0), "");
    }

    // =========================================================================
    // D — beforeRemoveLiquidity
    // =========================================================================

    function test_beforeRemoveLiquidity_marksExited() public {
        _initialize();
        uint256 pid = _addLiquidity(1_000e18);

        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: -1_000e18, salt: bytes32(0)
        });

        vm.prank(address(mockPM));
        hook.beforeRemoveLiquidity(address(0), KEY, mlp, abi.encode(pid));

        assertFalse(pm.isActive(pid));
    }

    function test_beforeRemoveLiquidity_emptyHookDataReverts() public {
        _initialize();

        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: -1_000e18, salt: bytes32(0)
        });

        vm.prank(address(mockPM));
        vm.expectRevert(ParadoxHook.InvalidHookData.selector);
        hook.beforeRemoveLiquidity(address(0), KEY, mlp, "");
    }

    function test_beforeRemoveLiquidity_returnsSelector() public {
        _initialize();
        uint256 pid = _addLiquidity(1_000e18);

        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: -1_000e18, salt: bytes32(0)
        });

        vm.prank(address(mockPM));
        bytes4 sel = hook.beforeRemoveLiquidity(address(0), KEY, mlp, abi.encode(pid));
        assertEq(sel, hook.beforeRemoveLiquidity.selector);
    }

    // =========================================================================
    // E — afterSwap
    // =========================================================================

    function test_afterSwap_recordsOracleObservation() public {
        _initialize();
        _addLiquidity(1_000e18);

        uint16 countBefore = oracle.observationCount(PoolId.unwrap(POOL));
        _swap(100_000e18);

        // First observation written.
        assertGt(oracle.observationCount(PoolId.unwrap(POOL)), countBefore);
    }

    function test_afterSwap_ingestsFeesToYieldRouter() public {
        _initialize();
        _addLiquidity(1_000e18);
        _swap(100_000e18);

        uint256 epochId = em.activeEpochIdFor(POOL);
        YieldRouter.EpochBalance memory bal = yr.getEpochBalance(epochId);

        // Some fees must have been ingested (fixed or variable).
        uint256 total = uint256(bal.fixedAccrued)
                      + uint256(bal.variableAccrued)
                      + uint256(bal.reserveContrib);
        assertGt(total, 0);
    }

    function test_afterSwap_noActiveEpoch_skipsGracefully() public {
        _initialize();
        // Settle the epoch immediately.
        uint256 epochId = em.activeEpochIdFor(POOL);
        vm.warp(T0 + EPOCH_DURATION);
        em.settle(epochId, 0, 0, 0);

        // Swap with no active epoch — should not revert.
        _swap(100_000e18);
    }

    function test_afterSwap_returnsZeroHookDelta() public {
        _initialize();
        _addLiquidity(1_000e18);

        SwapParams memory sp = SwapParams({
            zeroForOne: true, amountSpecified: -100_000e18, sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(100_000e18, -100_000e18);

        vm.prank(address(mockPM));
        (, int128 hookDelta) = hook.afterSwap(address(0), KEY, sp, delta, "");
        assertEq(hookDelta, 0);
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
        _initialize();
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100, tickUpper: 100,
            liquidityDelta: 1_000e18, salt: bytes32(0)
        });

        vm.prank(LP);
        vm.expectRevert();
        hook.afterAddLiquidity(LP, KEY, mlp, toBalanceDelta(0,0), toBalanceDelta(0,0), "");
    }

    function test_afterSwap_notPoolManagerReverts() public {
        _initialize();
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
        _initialize();

        // Settle current epoch.
        uint256 epochId = em.activeEpochIdFor(POOL);
        vm.warp(T0 + EPOCH_DURATION);
        em.settle(epochId, 0, 0, 0);

        assertFalse(em.hasActiveEpoch(POOL));

        // Need enough oracle observations for getTWAP and getVolatility.
        // Seed the oracle manually as the hook (bypassing afterSwap).
        vm.prank(OWNER);
        oracle.setAuthorizedCaller(OWNER);
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 4 hours);
            vm.prank(OWNER);
            oracle.record(POOL, 10e18, 1_000_000e18);
        }
        vm.prank(OWNER);
        oracle.setAuthorizedCaller(address(hook));

        vm.prank(OWNER);
        oracle.setTwapWindowObservations(3);

        vm.prank(OWNER);
        hook.openNextEpoch(POOL);

        assertTrue(em.hasActiveEpoch(POOL));
    }

    function test_openNextEpoch_nonOwnerReverts() public {
        _initialize();
        vm.prank(LP);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                LP
            )
        );
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
}

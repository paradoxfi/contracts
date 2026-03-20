// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "v4-core/types/PoolOperation.sol";

import {EpochManager} from "../../src/core/EpochManager.sol";
import {YieldRouter} from "../../src/core/YieldRouter.sol";
import {MaturityVault} from "../../src/core/MaturityVault.sol";
import {RateOracle} from "../../src/core/RateOracle.sol";
import {ParadoxHook} from "../../src/core/ParadoxHook.sol";
import {FYToken} from "../../src/tokens/FYToken.sol";
import {VYToken} from "../../src/tokens/VYToken.sol";
import {FixedDateEpochModel} from "../../src/epochs/FixedDateEpochModel.sol";
import {PositionId} from "../../src/libraries/PositionId.sol";

// =============================================================================
// Test infrastructure
// =============================================================================

contract MockToken is ERC20 {
    constructor(string memory name, string memory sym) ERC20(name, sym) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock PoolManager with extsload (StateLibrary) and a stub modifyLiquidity
///      that records calls without moving real tokens.
contract MockPoolManager {
    uint160 public sqrtPriceX96 = 2 ** 96;
    uint128 public poolLiquidity = 1_000_000e18;

    address public lastRecipient;
    int256 public lastLiquidityDelta;

    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(sqrtPriceX96));
    }

    function extsload(
        bytes32,
        uint256 count
    ) external view returns (bytes32[] memory r) {
        r = new bytes32[](count);
        r[0] = bytes32(uint256(sqrtPriceX96));
        if (count > 1) r[1] = bytes32(uint256(poolLiquidity));
    }

    function getLiquidity(PoolId) external view returns (uint128) {
        return poolLiquidity;
    }

    /// Stub: records call, returns zero delta.
    /// Real token movement from liquidity removal is not simulated — integration
    /// tests verify accounting, not v4-internal token transfers.
    function modifyLiquidity(
        PoolKey calldata,
        ModifyLiquidityParams calldata params,
        bytes calldata data
    ) external returns (BalanceDelta callerDelta, BalanceDelta feesAccrued) {
        lastLiquidityDelta = params.liquidityDelta;
        if (data.length >= 32) {
            lastRecipient = abi.decode(data, (address));
        }
        return (toBalanceDelta(0, 0),toBalanceDelta(0, 0));
    }

    function setOperator(address, bool) external {}

    function setSqrtPrice(uint160 p) external {
        sqrtPriceX96 = p;
    }
    function setLiquidity(uint128 l) external {
        poolLiquidity = l;
    }
}

// =============================================================================
// IntegrationBase
// =============================================================================

/// @title IntegrationBase
/// @notice Shared deployment and wiring for all integration test suites.
///
/// Architecture changes from the old base (no PositionManager):
///   - FYToken stores position metadata (tick range, liquidity, halfNotional, epochId).
///   - VYToken reads position metadata from FYToken; its constructor takes FYToken.
///   - MaturityVault constructor takes poolManager + hook for liquidity removal.
///   - ParadoxHook constructor takes fyt + vyt directly; no positionManager.
///   - Hook mints FYT+VYT atomically inside afterAddLiquidity — _mintTokens removed.
///   - positionId is captured from the PositionOpened event (counters are private).
///   - beforeRemoveLiquidity reverts during active epoch; _removeLiquidity reflects this.
///   - _settleEpoch does not call receiveSettlement separately
///     (YieldRouter.finalizeEpoch calls it internally).
abstract contract IntegrationBase is Test {
    using PoolIdLibrary for PoolKey;

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address internal constant OWNER = address(0xA110CE);
    address internal constant LP_A = address(0xAA01);
    address internal constant LP_B = address(0xAA02);
    address internal constant LP_C = address(0xAA03);
    address internal constant KEEPER = address(0xBEEF);

    // -------------------------------------------------------------------------
    // Protocol constants
    // -------------------------------------------------------------------------

    uint32 internal constant EPOCH_DURATION = 30 days;
    uint64 internal constant T0 = 1_700_000_000;
    uint256 internal constant ALPHA = 0.80e18;
    uint256 internal constant BETA = 0.30e18;
    uint256 internal constant GAMMA = 0.15e18;
    uint256 internal constant GENESIS_TWAP = 0.0001e18;

    // Hook address: afterInitialize(12)|afterAddLiquidity(10)|
    //               beforeRemoveLiquidity(9)|afterSwap(6) = 0x1640
    address internal constant HOOK_ADDR = address(uint160(0x1640));

    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------

    MockPoolManager internal mockPM;
    MockToken internal token0;

    EpochManager internal em;
    YieldRouter internal yr;
    MaturityVault internal mv;
    RateOracle internal oracle;
    ParadoxHook internal hook;
    FYToken internal fyt;
    VYToken internal vyt;
    FixedDateEpochModel internal model;

    PoolKey internal KEY;
    PoolId internal POOL;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public virtual {
        vm.warp(T0);
        vm.chainId(1);

        mockPM = new MockPoolManager();
        token0 = new MockToken("USD Coin", "USDC");
        model = new FixedDateEpochModel();

        // Core contracts — authorizedCaller wired to hook after etch.
        em = new EpochManager(OWNER, address(0));
        yr = new YieldRouter(OWNER, address(0), em);
        oracle = new RateOracle(OWNER, address(0));

        // FYToken: no burners yet (mv address unknown until deployed).
        // VYToken: takes FYToken address so it can read position metadata.
        address[] memory noBurners = new address[](0);
        fyt = new FYToken(OWNER, address(0), noBurners, "");
        vyt = new VYToken(OWNER, address(0), noBurners, "", fyt);

        // MaturityVault: needs poolManager and hook for liquidity removal.
        // HOOK_ADDR is known ahead of etching.
        mv = new MaturityVault(
            OWNER,
            address(0), // authorizedCaller = yr, set below
            fyt,
            vyt,
            IPoolManager(address(mockPM))
        );

        vm.prank(OWNER);
        yr.setMaturityVault(address(mv));

        // Deploy hook at valid permission-encoded address via etch.
        // The runtime bytecode from tempHook has immutables baked in.
        deployCodeTo(
            "ParadoxHook.sol",
            abi.encode(address(mockPM), em, yr, oracle, fyt, vyt, OWNER),
            HOOK_ADDR
        );

        hook = ParadoxHook(HOOK_ADDR);

        // Wire authorizations.
        vm.startPrank(OWNER);
        em.setAuthorizedCaller(HOOK_ADDR);
        yr.setAuthorizedCaller(HOOK_ADDR);
        oracle.setAuthorizedCaller(HOOK_ADDR);
        mv.setAuthorizedCaller(address(yr));

        // Token roles:
        //   MINTER_ROLE → hook  (mints FYT+VYT on deposit)
        //   BURNER_ROLE → mv    (burns at redemption)
        // No early-exit burn role needed: removal is blocked until maturity.
        fyt.grantRole(fyt.MINTER_ROLE(), HOOK_ADDR);
        fyt.grantRole(fyt.BURNER_ROLE(), address(mv));
        vyt.grantRole(vyt.MINTER_ROLE(), HOOK_ADDR);
        vyt.grantRole(vyt.BURNER_ROLE(), address(mv));
        vm.stopPrank();

        KEY = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(0xE1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        POOL = KEY.toId();

        _initializePool();
    }

    // -------------------------------------------------------------------------
    // Core scenario helpers
    // -------------------------------------------------------------------------

    /// Register the pool via hook.initializePool() (owner call) then trigger
    /// the no-op afterInitialize callback.
    function _initializePool() internal {
        ParadoxHook.InitParams memory p = ParadoxHook.InitParams({
            model: address(model),
            modelParams: abi.encode(uint32(EPOCH_DURATION)),
            alphaWad: ALPHA,
            betaWad: BETA,
            gammaWad: GAMMA
        });

        vm.prank(OWNER);
        hook.initializePool(KEY, p, GENESIS_TWAP);

        vm.prank(address(mockPM));
        hook.afterInitialize(address(0), KEY, uint160(2 ** 96), 0);
    }

    /// Add liquidity for an LP. FYT and VYT are minted atomically inside
    /// afterAddLiquidity — no separate _mintTokens call needed.
    ///
    /// positionId is captured from the PositionOpened event because the hook's
    /// _counters mapping is private.
    function _addLiquidity(
        address lp,
        uint128 liquidity
    ) internal returns (uint256 positionId) {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100,
            tickUpper: 100,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        vm.recordLogs();
        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            address(mockPM),
            KEY,
            mlp,
            toBalanceDelta(0, 0),
            toBalanceDelta(0, 0),
            abi.encode(lp) // hookData carries the real recipient
        );

        // PositionOpened(bytes32 indexed poolId, uint256 indexed positionId,
        //                uint256 indexed epochId, uint128 liquidity, uint128 halfNotional)
        // topic[0] = selector, topic[1] = poolId, topic[2] = positionId
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
        require(
            positionId != 0,
            "IntegrationBase: PositionOpened event not found"
        );
    }

    /// Simulate a swap generating `feeAmount` of fee income.
    function _swap(uint128 feeAmount) internal {
        uint128 grossInput = uint128((uint256(feeAmount) * 1_000_000) / 3000);
        token0.mint(address(yr), feeAmount);

        SwapParams memory sp = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(grossInput)),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(
            int128(grossInput),
            -int128(grossInput)
        );

        vm.prank(address(mockPM));
        hook.afterSwap(address(0), KEY, sp, delta, "");
    }

    /// Attempt to remove liquidity via beforeRemoveLiquidity.
    /// During an active epoch this REVERTS with RemovalBlockedUntilMaturity.
    /// After epoch settlement it succeeds (no active epoch → no-op in hook).
    function _removeLiquidity(address lp, uint128 liquidity) internal {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100,
            tickUpper: 100,
            liquidityDelta: -int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        vm.prank(address(mockPM));
        hook.beforeRemoveLiquidity(lp, KEY, mlp, "");
    }

    /// Settle the current epoch and finalize via YieldRouter.
    /// finalizeEpoch calls receiveSettlement internally.
    function _settleEpoch()
        internal
        returns (uint256 epochId, YieldRouter.SettlementAmounts memory amounts)
    {
        epochId = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epochId);

        vm.warp(ep.maturity);

        uint256 obligation = em.currentObligation(epochId);

        vm.prank(KEEPER);
        em.settle(epochId, GENESIS_TWAP, 0, 0);

        vm.prank(OWNER);
        yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER);
        amounts = yr.finalizeEpoch(
            epochId,
            POOL,
            address(token0),
            uint128(obligation)
        );
        vm.prank(OWNER);
        yr.setAuthorizedCaller(HOOK_ADDR);
    }

    /// Redeem FYT for a position after settlement.
    /// Calls MaturityVault.redeemFYT(positionId, poolKey) as `holder`.
    function _redeemFYT(address holder, uint256 positionId) internal {
        vm.prank(holder);
        mv.redeemFYT(positionId, KEY);
    }

    /// Redeem VYT for a position after settlement.
    function _redeemVYT(address holder, uint256 positionId) internal {
        vm.prank(holder);
        mv.redeemVYT(positionId, KEY);
    }

    /// Preview fixed fee payout for a position (excludes principal).
    function _previewFYTPayout(
        uint256 positionId
    ) internal view returns (uint128) {
        return mv.previewFYTPayout(positionId);
    }

    /// Preview variable fee payout for a position.
    function _previewVYTPayout(
        uint256 positionId
    ) internal view returns (uint128) {
        return mv.previewVYTPayout(positionId);
    }
}

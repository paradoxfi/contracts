// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "v4-core/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary
} from "v4-core/types/BeforeSwapDelta.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {BaseHook} from "../BaseHook.sol";
import {IEpochModel} from "../epochs/IEpochModel.sol";
import {FeeAccounting} from "../libraries/FeeAccounting.sol";
import {EpochManager} from "./EpochManager.sol";
import {PositionManager} from "./PositionManager.sol";
import {YieldRouter} from "./YieldRouter.sol";
import {RateOracle} from "./RateOracle.sol";

/// @title ParadoxHook
/// @notice Thin Uniswap v4 hook — the sole entry point into the Paradox Fi
///         fixed-income protocol from the v4 PoolManager.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Design principle: thin hook, fat core
/// ─────────────────────────────────────────────────────────────────────────────
///
/// This contract contains NO business logic. Each callback does exactly:
///   1. Validate the caller (BaseHook provides onlyPoolManager).
///   2. Extract the minimum data needed from the v4 context.
///   3. Delegate to the appropriate core contract(s).
///   4. Return the correct v4 selector / delta.
///
/// All epoch state, position state, fee accounting, and oracle updates live
/// in EpochManager, PositionManager, YieldRouter, and RateOracle respectively.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Active hook flags
/// ─────────────────────────────────────────────────────────────────────────────
///
///   AFTER_INITIALIZE        — register pool, open first epoch
///   AFTER_ADD_LIQUIDITY     — mint position NFT, mint FYT+VYT, add notional
///   BEFORE_REMOVE_LIQUIDITY — exit guard, mark position exited
///   AFTER_SWAP              — capture fees, record oracle, ingest YieldRouter
///
/// ─────────────────────────────────────────────────────────────────────────────
/// hookData conventions
/// ─────────────────────────────────────────────────────────────────────────────
///
///   afterInitialize:      abi.encode(InitParams) — epoch model address,
///                         modelParams, rate weights, oracle params
///   afterAddLiquidity:    empty (all data derived from v4 context)
///   beforeRemoveLiquidity: abi.encode(uint256 positionId) — the NFT the LP
///                         is exiting
///   afterSwap:            empty
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Fee token convention
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Paradox Fi denominates all fee accounting in token0. For pools where the
/// fee-bearing leg is token1 (zeroForOne == false), the fee amount is converted
/// to token0 units using FeeAccounting.toToken0Denominated() before ingestion.
/// This keeps YieldRouter and MaturityVault single-currency per pool.
contract ParadoxHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    using FeeAccounting for BalanceDelta;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Parameters supplied via hookData in afterInitialize.
    struct InitParams {
        /// @notice IEpochModel strategy address for this pool.
        address model;
        /// @notice ABI-encoded model parameters (e.g. abi.encode(uint32 duration)).
        bytes modelParams;
        /// @notice α weight for FixedRateMath (WAD).
        uint256 alphaWad;
        /// @notice β weight for FixedRateMath (WAD).
        uint256 betaWad;
        /// @notice γ weight for FixedRateMath (WAD).
        uint256 gammaWad;
    }

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice Epoch lifecycle manager.
    EpochManager public immutable epochManager;

    /// @notice LP position NFT registry.
    PositionManager public immutable positionManager;

    /// @notice Fee waterfall router.
    YieldRouter public immutable yieldRouter;

    /// @notice Fee TWAP and volatility oracle.
    RateOracle public immutable rateOracle;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice Pools that have been initialized through this hook.
    mapping(PoolId => bool) public registeredPools;

    // =========================================================================
    // Events
    // =========================================================================

    event PoolRegistered(PoolId indexed poolId);
    event PositionOpened(
        PoolId indexed poolId,
        uint256 indexed positionId,
        uint256 indexed epochId,
        uint128 notional
    );
    event PositionClosed(PoolId indexed poolId, uint256 indexed positionId);
    event FeesRouted(
        PoolId indexed poolId,
        uint256 indexed epochId,
        uint128 feeAmount
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error PoolNotRegistered(PoolId poolId);
    error PoolAlreadyRegistered(PoolId poolId);
    error NoActiveEpoch(PoolId poolId);
    error ZeroLiquidity();
    error InvalidHookData();

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        IPoolManager _poolManager,
        EpochManager _epochManager,
        PositionManager _positionManager,
        YieldRouter _yieldRouter,
        RateOracle _rateOracle,
        address _owner
    ) BaseHook(_poolManager) Ownable(_owner) {
        epochManager = _epochManager;
        positionManager = _positionManager;
        yieldRouter = _yieldRouter;
        rateOracle = _rateOracle;
    }

    // =========================================================================
    // Hook permission flags
    // =========================================================================

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function initializePool(
        PoolKey calldata key,
        InitParams calldata params,
        uint256 genesisTwapWad
    ) external onlyOwner {
        PoolId poolId = key.toId();
        if (registeredPools[poolId]) revert PoolAlreadyRegistered(poolId);

        rateOracle.registerPool(poolId);

        epochManager.registerPool(
            poolId,
            IEpochModel(params.model),
            params.modelParams,
            params.alphaWad,
            params.betaWad,
            params.gammaWad
        );

        epochManager.openEpoch(poolId, genesisTwapWad, 0, 0);

        registeredPools[poolId] = true;
        emit PoolRegistered(poolId);
    }

    // =========================================================================
    // afterInitialize
    // =========================================================================

    /// @notice Called by PoolManager after a new v4 pool is initialized.
    ///
    /// Registers the pool with all core contracts and opens the first epoch.
    /// hookData must be abi.encode(InitParams).
    function _afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24
    ) internal override view onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();

        if (!registeredPools[poolId]) {
            revert PoolNotRegistered(poolId);
        }

        return BaseHook.afterInitialize.selector;
    }

    // =========================================================================
    // afterAddLiquidity
    // =========================================================================

    /// @notice Called by PoolManager after an LP adds liquidity.
    ///
    /// Computes notional, mints position NFT, adds notional to active epoch.
    /// hookData is ignored (all data comes from v4 callback params).
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        if (!registeredPools[poolId]) revert PoolNotRegistered(poolId);

        uint128 liquidity = params.liquidityDelta > 0
            ? uint128(uint256(int256(params.liquidityDelta)))
            : 0;

        if (liquidity == 0) revert ZeroLiquidity();

        _processDeposit(
            sender,
            poolId,
            params.tickLower,
            params.tickUpper,
            liquidity
        );

        return (
            BaseHook.afterAddLiquidity.selector,
            BalanceDeltaLibrary.ZERO_DELTA
        );
    }

    // =========================================================================
    // beforeRemoveLiquidity
    // =========================================================================

    /// @notice Called by PoolManager before an LP removes liquidity.
    ///
    /// Exit guard: marks the position as exited. The LP must pass their
    /// positionId in hookData as abi.encode(uint256 positionId).
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        if (!registeredPools[poolId]) revert PoolNotRegistered(poolId);
        if (hookData.length < 32) revert InvalidHookData();

        uint256 positionId = abi.decode(hookData, (uint256));

        positionManager.markExited(positionId);

        emit PositionClosed(poolId, positionId);

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // =========================================================================
    // afterSwap
    // =========================================================================

    /// @notice Called by PoolManager after every swap.
    ///
    /// Extracts the fee from the swap delta, records an oracle observation,
    /// and ingests the fee into YieldRouter. hookDelta is always 0 — Paradox Fi
    /// does not take custody of tokens during the swap.
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4, int128) {
        PoolId poolId = key.toId();
        if (!registeredPools[poolId]) return (BaseHook.afterSwap.selector, 0);

        uint256 epochId = epochManager.activeEpochIdFor(poolId);
        if (epochId == 0) return (BaseHook.afterSwap.selector, 0);

        // Extract fee-bearing leg (token0-denominated).
        // FeeAccounting.extractInputAmount returns the gross input amount.
        // We use it as a proxy for the fee: actual fee = inputAmount × feeRate,
        // but since YieldRouter only tracks relative proportions and the
        // obligation is set in the same units, any consistent fee proxy works.
        // For correctness, the hook applies the pool's fee tier:
        //   feeAmount = inputAmount × key.fee / 1e6
        uint128 inputAmount = FeeAccounting.extractInputAmount(
            delta,
            params.zeroForOne
        );

        // key.fee is in pips (1 pip = 0.0001%), so fee/1e6 gives the fraction.
        // feeAmount = inputAmount × fee / 1_000_000.
        uint128 feeAmount = uint128(
            (uint256(inputAmount) * uint256(key.fee)) / 1_000_000
        );

        if (feeAmount == 0) return (BaseHook.afterSwap.selector, 0);

        // Read current TVL for the oracle: use the pool's total liquidity as
        // a TVL proxy (liquidity units, token0-denominated).
        uint128 tvl = poolManager.getLiquidity(poolId);

        // Record oracle observation (rate-limited internally).
        rateOracle.record(poolId, feeAmount, tvl);

        // Get fixed obligation for ingest waterfall.
        EpochManager.Epoch memory ep = epochManager.getEpoch(epochId);
        uint128 fixedObligation = uint128(
            // computeObligation is a pure function — call it inline to avoid
            // a cross-contract call just for a view. We replicate the formula:
            // obligation = notional × rate × duration / SECONDS_PER_YEAR / WAD
            // This is already stored in the epoch as the running total from addNotional.
            // We read it from YieldRouter's perspective via the epoch struct fields.
            _computeCurrentObligation(ep)
        );

        // Address of the fee token (always token0 for our accounting convention).
        address feeToken = Currency.unwrap(key.currency0);

        // Ingest into YieldRouter (pure accounting — no token transfer here).
        yieldRouter.ingest(
            epochId,
            poolId,
            feeToken,
            feeAmount,
            fixedObligation
        );

        emit FeesRouted(poolId, epochId, feeAmount);

        return (BaseHook.afterSwap.selector, 0);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Compute running fixed obligation from epoch fields.
    ///      Mirrors FixedRateMath.computeObligation() without importing it here.
    ///      obligation = totalNotional × fixedRate × duration / SECONDS_PER_YEAR / WAD
    function _computeCurrentObligation(
        EpochManager.Epoch memory ep
    ) internal pure returns (uint128 obligation) {
        if (ep.totalNotional == 0) return 0;
        uint64 duration = ep.maturity - ep.startTime;
        // Same two-step formula as FixedRateMath.computeObligation:
        // step1 = notional × rate / WAD
        // step2 = step1 × duration / SECONDS_PER_YEAR
        uint256 step1 = (uint256(ep.totalNotional) * uint256(ep.fixedRate)) /
            1e18;
        obligation = uint128((step1 * uint256(duration)) / (365 days));
    }

    /// @dev Handles the deposit logic in a separate frame to avoid stack-too-deep.
    ///      Called only from afterAddLiquidity after input validation.
    function _processDeposit(
        address sender,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal {
        // Read current sqrtPrice from PoolManager state.
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

        // Notional = liquidity × sqrtPriceX96 >> 96
        // Single-sided token0 approximation at current price.
        // Safe: liquidity ≤ 2^128, sqrtPriceX96 ≤ 2^96 (Q64.96) →
        // product ≤ 2^224, >> 96 → ≤ 2^128.
        uint128 notional = uint128(
            (uint256(liquidity) * uint256(sqrtPriceX96)) >> 96
        );

        // Look up the active epoch and its fixed rate.
        uint256 epochId = epochManager.activeEpochIdFor(poolId);
        if (epochId == 0) revert NoActiveEpoch(poolId);

        uint64 fixedRate = uint64(epochManager.getEpoch(epochId).fixedRate);

        // Mint the position NFT.
        uint256 positionId = positionManager.mint(
            sender,
            poolId,
            epochId,
            tickLower,
            tickUpper,
            liquidity,
            notional,
            fixedRate
        );

        // Record notional in EpochManager.
        epochManager.addNotional(poolId, notional);

        emit PositionOpened(poolId, positionId, epochId, notional);
    }

    // =========================================================================
    // Governance helpers
    // =========================================================================

    /// @notice Manually open a new epoch for a pool (e.g. after settlement
    ///         when shouldAutoRoll() is false).
    ///
    /// Reads fresh oracle values and opens the epoch. Called by governance
    /// or a keeper after the previous epoch has been settled.
    function openNextEpoch(PoolId poolId) external onlyOwner {
        if (!registeredPools[poolId]) revert PoolNotRegistered(poolId);

        uint256 twapWad = rateOracle.getTWAP(poolId);
        uint256 volWad = rateOracle.getVolatility(poolId);

        epochManager.openEpoch(poolId, twapWad, volWad, 0);
    }
}

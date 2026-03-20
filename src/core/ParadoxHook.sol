// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "../BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {
    BalanceDelta,
    BalanceDeltaLibrary
} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {
    SwapParams,
    ModifyLiquidityParams
} from "v4-core/types/PoolOperation.sol";

import {FeeAccounting} from "../libraries/FeeAccounting.sol";
import {PositionId} from "../libraries/PositionId.sol";
import {EpochManager} from "./EpochManager.sol";
import {YieldRouter} from "./YieldRouter.sol";
import {RateOracle} from "./RateOracle.sol";
import {FYToken} from "../tokens/FYToken.sol";
import {VYToken} from "../tokens/VYToken.sol";

import {IEpochModel} from "../epochs/IEpochModel.sol";

/// @title ParadoxHook
/// @notice Uniswap v4 hook — sole entry point into the Paradox Fi protocol.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Token model
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Each LP deposit mints two tokens to the LP:
///
///   FYT (tokenId = positionId, amount = notional/2)
///     — half of the underlying liquidity principal
///     — pro-rata claim on the fixed fee tranche at maturity
///
///   VYT (tokenId = positionId, amount = 1)
///     — the other half of the underlying liquidity principal
///     — pro-rata claim on the variable fee tranche at maturity (Zone A only)
///
/// Together FYT + VYT fully reconstruct the LP position. Neither can be
/// redeemed without the other presenting to MaturityVault separately.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Liquidity removal
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Liquidity removal from the v4 pool is blocked until the epoch matures.
/// beforeRemoveLiquidity reverts unconditionally while the epoch is ACTIVE.
///
/// At maturity, liquidity is removed by MaturityVault via redeemFYT() and
/// redeemVYT() — each burns its token and removes half the position's v4
/// liquidity, returning underlying tokens to the caller.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Active hook flags
/// ─────────────────────────────────────────────────────────────────────────────
///
///   AFTER_INITIALIZE        — register pool, open first epoch
///   AFTER_ADD_LIQUIDITY     — mint FYT + VYT, record notional
///   BEFORE_REMOVE_LIQUIDITY — block early removal (reverts until maturity)
///   AFTER_SWAP              — capture fees, record oracle, route to YieldRouter
contract ParadoxHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using FeeAccounting for BalanceDelta;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Parameters for pool initialization (passed by owner, not hookData).
    struct InitParams {
        address model;
        bytes modelParams;
        uint256 alphaWad;
        uint256 betaWad;
        uint256 gammaWad;
    }

    // =========================================================================
    // Immutables
    // =========================================================================

    EpochManager public immutable epochManager;
    YieldRouter public immutable yieldRouter;
    RateOracle public immutable rateOracle;
    FYToken public immutable fyt;
    VYToken public immutable vyt;

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice Pools registered with this hook.
    mapping(PoolId => bool) public registeredPools;

    /// @notice Per-pool deposit counter for positionId generation.
    mapping(bytes32 => uint32) private _counters;

    address public owner;

    // =========================================================================
    // Events
    // =========================================================================

    event PoolRegistered(PoolId indexed poolId);
    event PositionOpened(
        PoolId indexed poolId,
        uint256 indexed positionId,
        uint256 indexed epochId,
        uint128 liquidity,
        uint128 halfNotional
    );
    event FeesRouted(
        PoolId indexed poolId,
        uint256 indexed epochId,
        uint128 feeAmount
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error NotOwner();
    error PoolNotRegistered(PoolId poolId);
    error PoolAlreadyRegistered(PoolId poolId);
    error NoActiveEpoch(PoolId poolId);
    error ZeroLiquidity();
    error RemovalBlockedUntilMaturity(PoolId poolId, uint64 maturity);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        IPoolManager _poolManager,
        EpochManager _epochManager,
        YieldRouter _yieldRouter,
        RateOracle _rateOracle,
        FYToken _fyt,
        VYToken _vyt,
        address _owner
    ) BaseHook(_poolManager) {
        epochManager = _epochManager;
        yieldRouter = _yieldRouter;
        rateOracle = _rateOracle;
        fyt = _fyt;
        vyt = _vyt;
        owner = _owner;
    }

    // =========================================================================
    // Hook permissions
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

    // =========================================================================
    // Pool initialisation (called by owner before v4 pool creation)
    // =========================================================================

    /// @notice Register a pool with all Paradox Fi core contracts and open
    ///         the first epoch. Must be called before IPoolManager.initialize().
    ///
    /// v4 before/afterInitialize callbacks carry no hookData, so registration
    /// must happen via this explicit call rather than the hook callback.
    ///
    /// @param key           The v4 PoolKey that will be initialized.
    /// @param params        Epoch model and rate weight configuration.
    /// @param genesisTwapWad Fixed rate for the first epoch (WAD, >= MIN_RATE).
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
    // afterInitialize — no-op (registration done in initializePool)
    // =========================================================================

    function _afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) internal override onlyPoolManager returns (bytes4) {
        return BaseHook.afterInitialize.selector;
    }

    // =========================================================================
    // afterAddLiquidity — mint FYT + VYT
    // =========================================================================

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) internal override onlyPoolManager returns (bytes4, BalanceDelta) {
        PoolId poolId = key.toId();
        if (!registeredPools[poolId]) revert PoolNotRegistered(poolId);

        uint128 liquidity = params.liquidityDelta > 0
            ? uint128(uint256(int256(params.liquidityDelta)))
            : 0;
        if (liquidity == 0) revert ZeroLiquidity();

        // The actual LP is passed via hookData. When hookData is empty
        // (e.g. in tests calling afterAddLiquidity directly), fall back to sender.
        address recipient = hookData.length >= 32
            ? abi.decode(hookData, (address))
            : sender;

        _processDeposit(
            recipient,
            key,
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

    /// @dev Separated to avoid stack-too-deep in afterAddLiquidity.
    function _processDeposit(
        address sender,
        PoolKey calldata key,
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal {
        uint256 epochId = epochManager.activeEpochIdFor(poolId);
        if (epochId == 0) revert NoActiveEpoch(poolId);

        // Notional = liquidity × sqrtPriceX96 >> 96 (token0-denominated).
        (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);
        uint128 notional = uint128(
            (uint256(liquidity) * uint256(sqrtPriceX96)) >> 96
        );
        uint128 halfNotional = notional / 2;

        // Generate a unique positionId for this deposit.
        bytes32 poolKey = PoolId.unwrap(poolId);
        uint32 next = PositionId.nextCounter(_counters[poolKey]);
        _counters[poolKey] = next;
        uint256 positionId = PositionId.encode(poolId, next);

        // Build position metadata — stored once in FYToken, read by both tokens
        // and MaturityVault when executing the liquidity removal at redemption.
        FYToken.PositionData memory data = FYToken.PositionData({
            poolId: poolKey,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            halfNotional: halfNotional,
            epochId: epochId
        });

        // Mint FYT (amount = halfNotional) and VYT (amount = 1).
        fyt.mint(sender, positionId, data);
        vyt.mint(sender, positionId);

        // Record full notional in EpochManager for obligation accounting.
        epochManager.addNotional(poolId, notional);

        emit PositionOpened(
            poolId,
            positionId,
            epochId,
            liquidity,
            halfNotional
        );
    }

    // =========================================================================
    // beforeRemoveLiquidity — block until epoch maturity
    // =========================================================================

    /// @notice Revert if the epoch is still ACTIVE.
    ///
    /// Liquidity is locked in the pool until maturity. After settlement,
    /// MaturityVault orchestrates removal via redeemFYT() and redeemVYT()
    /// by calling IPoolManager.modifyLiquidity() directly as an authorised
    /// operator of the hook.
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override onlyPoolManager returns (bytes4) {
        PoolId poolId = key.toId();
        if (!registeredPools[poolId]) revert PoolNotRegistered(poolId);

        // If the pool has an active epoch, removal is blocked.
        uint256 activeEpoch = epochManager.activeEpochIdFor(poolId);
        if (activeEpoch != 0) {
            EpochManager.Epoch memory ep = epochManager.getEpoch(activeEpoch);
            revert RemovalBlockedUntilMaturity(poolId, ep.maturity);
        }

        // No active epoch means the epoch has settled — removal is permitted.
        // (MaturityVault calls modifyLiquidity after settle() clears activeEpochId.)
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // =========================================================================
    // afterSwap — fee routing
    // =========================================================================

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

        uint128 inputAmount = FeeAccounting.extractInputAmount(
            delta,
            params.zeroForOne
        );
        uint128 feeAmount = uint128(
            (uint256(inputAmount) * uint256(key.fee)) / 1_000_000
        );
        if (feeAmount == 0) return (BaseHook.afterSwap.selector, 0);

        uint128 tvl = poolManager.getLiquidity(poolId);
        rateOracle.record(poolId, feeAmount, tvl);

        EpochManager.Epoch memory ep = epochManager.getEpoch(epochId);
        uint128 fixedObligation = _computeCurrentObligation(ep);

        address feeToken = Currency.unwrap(key.currency0);
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

    function _computeCurrentObligation(
        EpochManager.Epoch memory ep
    ) internal pure returns (uint128 obligation) {
        if (ep.totalNotional == 0) return 0;
        uint64 duration = ep.maturity - ep.startTime;
        uint256 step1 = (uint256(ep.totalNotional) * uint256(ep.fixedRate)) /
            1e18;
        obligation = uint128((step1 * uint256(duration)) / (365 days));
    }

    // =========================================================================
    // Governance
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice Open the next epoch for a pool using fresh oracle values.
    ///         Called by a keeper after the previous epoch settles.
    function openNextEpoch(PoolId poolId) external onlyOwner {
        if (!registeredPools[poolId]) revert PoolNotRegistered(poolId);
        uint256 twapWad = rateOracle.getTWAP(poolId);
        uint256 volWad = rateOracle.getVolatility(poolId);
        epochManager.openEpoch(poolId, twapWad, volWad, 0);
    }
}

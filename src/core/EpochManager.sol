// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {IEpochModel}   from "../epochs/IEpochModel.sol";
import {EpochId}       from "../libraries/EpochId.sol";
import {FixedRateMath} from "../libraries/FixedRateMath.sol";

/// @title EpochManager
/// @notice Sole source of truth for epoch state transitions in the Paradox Fi
///         fixed-income protocol.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Responsibility boundary
/// ─────────────────────────────────────────────────────────────────────────────
///
/// EpochManager owns the lifecycle of every epoch:
///
///   1. registerPool()  — bind a pool to an IEpochModel strategy + rate params
///   2. openEpoch()     — create a new epoch; call computeMaturity(), mint the
///                        epochId, store the fixed-rate obligation
///   3. settle()        — finalise a matured epoch; anyone may call after
///                        block.timestamp ≥ maturity
///   4. autoRoll        — if the model returns shouldAutoRoll() == true,
///                        settle() calls openEpoch() immediately afterward
///
/// EpochManager does NOT:
///   • Hold or move tokens (that is YieldRouter / MaturityVault)
///   • Mint FYT / VYT ERC-1155 tokens (that is FYToken / VYToken)
///   • Execute hook callbacks (that is ParadoxHook)
///
/// ParadoxHook calls openEpoch() after the first deposit into a new epoch
/// window and calls settle() permissionlessly after maturity. All other
/// callers (e.g. governance) may also call settle() once the epoch has matured.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// State machine
/// ─────────────────────────────────────────────────────────────────────────────
///
///   PENDING ──openEpoch()──► ACTIVE ──settle()──► SETTLED
///
/// PENDING is not a stored state — an epoch does not exist until openEpoch()
/// succeeds, at which point it is immediately ACTIVE.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
/// registerPool        — owner only
/// openEpoch           — authorizedCaller or owner (ParadoxHook in production)
/// addNotional         — authorizedCaller or owner
/// settle              — permissionless (anyone, after maturity)
/// transferOwnership   — owner only (two-step)
/// setAuthorizedCaller — owner only
contract EpochManager is Ownable2Step {

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Lifecycle state of an epoch.
    enum EpochStatus { ACTIVE, SETTLED }

    /// @notice All persistent state for a single epoch.
    ///
    /// Storage layout (4 slots):
    ///   slot 0: epochId          (uint256)
    ///   slot 1: poolId           (bytes32)
    ///   slot 2: startTime(64) + maturity(64) + fixedRate(128)
    ///   slot 3: totalNotional(128) + status(8) + padding
    ///
    /// obligation is derived on-demand from (totalNotional, fixedRate, duration)
    /// via FixedRateMath.computeObligation() to avoid stored state that can
    /// drift as totalNotional accumulates via addNotional().
    struct Epoch {
        /// @notice The packed EpochId (= FYT ERC-1155 tokenId).
        uint256 epochId;
        /// @notice Full 256-bit PoolId. Not derivable from epochId alone because
        ///         epochId only embeds the lower 160 bits of the PoolId.
        PoolId  poolId;
        /// @notice Unix timestamp when the epoch was opened.
        uint64  startTime;
        /// @notice Unix timestamp when the epoch may be settled. Immutable
        ///         after openEpoch().
        uint64  maturity;
        /// @notice Annualised fixed rate locked in at epoch open (WAD = 1e18).
        uint128 fixedRate;
        /// @notice Sum of all LP notional deposits into this epoch (token0 units).
        ///         Increases during ACTIVE; frozen at settle.
        uint128 totalNotional;
        /// @notice Lifecycle state.
        EpochStatus status;
    }

    /// @notice Per-pool registration record.
    ///
    /// Rate weights (alphaWad, betaWad, gammaWad) are stored individually to
    /// match FixedRateMath.computeFixedRate()'s calling convention exactly and
    /// to allow per-pool governance overrides without a shared struct type.
    struct PoolConfig {
        /// @notice The epoch model strategy for this pool.
        IEpochModel model;
        /// @notice ABI-encoded model parameters passed to computeMaturity().
        bytes modelParams;
        /// @notice α — weight on the TWAP term (WAD, ≤ 1e18).
        uint256 alphaWad;
        /// @notice β — weight on the volatility discount (WAD, ≤ 1e18).
        uint256 betaWad;
        /// @notice γ — weight on the utilisation premium (WAD, ≤ 1e18).
        uint256 gammaWad;
        /// @notice The epochId of the currently ACTIVE epoch, or EpochId.NULL.
        uint256 activeEpochId;
        /// @notice Monotonically increasing index used as the epochIndex field
        ///         of the next epochId. 0-based; incremented after each open.
        uint32  epochCounter;
        /// @notice True after registerPool() succeeds.
        bool    registered;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev epoch storage: epochId → Epoch.
    mapping(uint256 => Epoch) private _epochs;

    /// @dev pool config storage: PoolId.unwrap() → PoolConfig.
    mapping(bytes32 => PoolConfig) private _pools;

    /// @notice Authorized non-owner address that may call openEpoch() and
    ///         addNotional(). Set to the ParadoxHook address in production.
    address public authorizedCaller;

    // =========================================================================
    // Events
    // =========================================================================

    event PoolRegistered(
        PoolId  indexed poolId,
        address indexed model,
        uint256         alphaWad,
        uint256         betaWad,
        uint256         gammaWad
    );

    event EpochOpened(
        uint256 indexed epochId,
        PoolId  indexed poolId,
        uint64          startTime,
        uint64          maturity,
        uint128         fixedRate
    );

    event EpochSettled(
        uint256 indexed epochId,
        PoolId  indexed poolId,
        uint128         totalNotional,
        uint64          settledAt
    );

    event NotionalAdded(
        uint256 indexed epochId,
        uint128         delta,
        uint128         newTotal
    );

    event AuthorizedCallerSet(address indexed previous, address indexed next);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotAuthorized();
    error ZeroAddress();
    error PoolAlreadyRegistered(PoolId poolId);
    error PoolNotRegistered(PoolId poolId);
    error EpochAlreadyActive(PoolId poolId, uint256 activeEpochId);
    error EpochDoesNotExist(uint256 epochId);
    error EpochNotActive(uint256 epochId);
    error EpochAlreadySettled(uint256 epochId);
    error EpochNotMatured(uint256 epochId, uint64 maturity, uint64 currentTime);
    error NotionalOverflow();
    error InvalidModelParams();

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _owner, address _authorizedCaller) Ownable(_owner) {
        authorizedCaller = _authorizedCaller;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================
    modifier onlyAuthorized() {
        if (msg.sender != owner() && msg.sender != authorizedCaller) {
            revert NotAuthorized();
        }
        _;
    }

    /// @notice Update the authorized non-owner caller (ParadoxHook address).
    function setAuthorizedCaller(address caller) external onlyOwner {
        address prev = authorizedCaller;
        authorizedCaller = caller;
        emit AuthorizedCallerSet(prev, caller);
    }

    // =========================================================================
    // Pool registration
    // =========================================================================

    /// @notice Register a pool with an epoch model and rate parameters.
    ///
    /// Validates model params eagerly — misconfigured params are rejected at
    /// registration rather than producing a broken epoch later.
    ///
    /// @param poolId      The Uniswap v4 PoolId to register.
    /// @param model       IEpochModel strategy address. Must be non-zero.
    /// @param modelParams ABI-encoded model-specific configuration.
    /// @param alphaWad    α weight on TWAP term (WAD, ≤ 1e18).
    /// @param betaWad     β weight on volatility discount (WAD, ≤ 1e18).
    /// @param gammaWad    γ weight on utilisation premium (WAD, ≤ 1e18).
    function registerPool(
        PoolId         poolId,
        IEpochModel    model,
        bytes calldata modelParams,
        uint256        alphaWad,
        uint256        betaWad,
        uint256        gammaWad
    ) external onlyOwner {
        bytes32 key = PoolId.unwrap(poolId);
        if (_pools[key].registered)             revert PoolAlreadyRegistered(poolId);
        if (address(model) == address(0))       revert ZeroAddress();
        if (!model.validateParams(modelParams)) revert InvalidModelParams();

        _pools[key] = PoolConfig({
            model:         model,
            modelParams:   modelParams,
            alphaWad:      alphaWad,
            betaWad:       betaWad,
            gammaWad:      gammaWad,
            activeEpochId: EpochId.NULL,
            epochCounter:  0,
            registered:    true
        });

        emit PoolRegistered(poolId, address(model), alphaWad, betaWad, gammaWad);
    }

    // =========================================================================
    // Epoch lifecycle — openEpoch
    // =========================================================================

    /// @notice Open a new epoch for a registered pool.
    ///
    /// Computes maturity via IEpochModel.computeMaturity() and locks in a fixed
    /// rate via FixedRateMath.computeFixedRate(). The returned epochId is also
    /// the ERC-1155 tokenId used for FYT minting.
    ///
    /// Reverts if the pool already has an ACTIVE epoch — only one may be open
    /// per pool at a time.
    ///
    /// @param poolId  Pool to open the epoch for.
    /// @param twapWad 30-day TWAP annualised fee yield (WAD). Supplied by
    ///                RateOracle via the hook; EpochManager does not read the
    ///                oracle directly to avoid circular construction dependencies.
    /// @param volWad  Annualised fee-yield standard deviation (WAD).
    /// @param utilWad Current epoch utilisation fraction (WAD). Typically 0 at
    ///                open time; non-zero for autoRoll continuations.
    /// @return epochId The packed identifier for the new epoch.
    function openEpoch(
        PoolId  poolId,
        uint256 twapWad,
        uint256 volWad,
        uint256 utilWad
    ) external onlyAuthorized returns (uint256 epochId) {
        bytes32 key = PoolId.unwrap(poolId);
        PoolConfig storage cfg = _pools[key];

        if (!cfg.registered) revert PoolNotRegistered(poolId);
        if (cfg.activeEpochId != EpochId.NULL) {
            revert EpochAlreadyActive(poolId, cfg.activeEpochId);
        }

        epochId = _openEpochInternal(poolId, twapWad, volWad, utilWad);
    }

    // =========================================================================
    // Epoch lifecycle — addNotional
    // =========================================================================

    /// @notice Record an LP notional deposit into the active epoch for a pool.
    ///
    /// Called by ParadoxHook on afterAddLiquidity. Accumulates notional so the
    /// total obligation can be computed and compared against collected fees at
    /// settlement.
    ///
    /// @param poolId Pool whose active epoch receives the deposit.
    /// @param delta  Notional amount in token0 units.
    function addNotional(PoolId poolId, uint128 delta) external onlyAuthorized {
        bytes32 key = PoolId.unwrap(poolId);
        PoolConfig storage cfg = _pools[key];

        if (!cfg.registered)                    revert PoolNotRegistered(poolId);
        if (cfg.activeEpochId == EpochId.NULL)  revert EpochNotActive(0);

        Epoch storage ep = _epochs[cfg.activeEpochId];

        uint256 next = uint256(ep.totalNotional) + uint256(delta);
        if (next > type(uint128).max) revert NotionalOverflow();

        ep.totalNotional = uint128(next);
        emit NotionalAdded(cfg.activeEpochId, delta, uint128(next));
    }

    // =========================================================================
    // Epoch lifecycle — settle
    // =========================================================================

    /// @notice Settle a matured epoch. Permissionless after block.timestamp ≥ maturity.
    ///
    /// Marks the epoch SETTLED and clears the pool's activeEpochId.
    /// If the pool's model has shouldAutoRoll() == true, a successor epoch is
    /// opened immediately using the provided oracle values.
    ///
    /// @param epochId      The epoch to settle.
    /// @param twapWad      TWAP for the auto-roll successor (WAD). Ignored if
    ///                     shouldAutoRoll() == false.
    /// @param volWad       Volatility for the auto-roll successor (WAD).
    /// @param utilWad      Utilisation for the auto-roll successor (WAD).
    /// @return nextEpochId EpochId of the successor, or EpochId.NULL.
    function settle(
        uint256 epochId,
        uint256 twapWad,
        uint256 volWad,
        uint256 utilWad
    ) external returns (uint256 nextEpochId) {
        Epoch storage ep = _epochs[epochId];

        // ep.epochId == NULL means the mapping slot is uninitialised.
        // Real epochIds embed block.chainid (≥ 1) in the upper bits, so NULL == 0
        // is an unambiguous sentinel.
        if (ep.epochId == EpochId.NULL)        revert EpochDoesNotExist(epochId);
        if (ep.status == EpochStatus.SETTLED)  revert EpochAlreadySettled(epochId);
        if (block.timestamp < ep.maturity) {
            revert EpochNotMatured(epochId, ep.maturity, uint64(block.timestamp));
        }

        ep.status = EpochStatus.SETTLED;

        PoolId  poolId = ep.poolId;
        bytes32 key    = PoolId.unwrap(poolId);
        _pools[key].activeEpochId = EpochId.NULL;

        emit EpochSettled(epochId, poolId, ep.totalNotional, uint64(block.timestamp));

        // Auto-roll: _openEpochInternal bypasses the access modifier.
        // The authorization to open epochs was established when the first
        // epoch in the series was opened by an authorized caller. Auto-roll
        // is a permitted continuation of that authorization, not a new grant.
        if (_pools[key].model.shouldAutoRoll()) {
            nextEpochId = _openEpochInternal(poolId, twapWad, volWad, utilWad);
        }
        // else nextEpochId == 0 == EpochId.NULL
    }

    // =========================================================================
    // Internal
    // =========================================================================

    /// @dev Core epoch-open logic, without access control.
    ///      Callers must ensure the pool is registered and has no active epoch.
    function _openEpochInternal(
        PoolId  poolId,
        uint256 twapWad,
        uint256 volWad,
        uint256 utilWad
    ) internal returns (uint256 epochId) {
        bytes32 key = PoolId.unwrap(poolId);
        PoolConfig storage cfg = _pools[key];

        uint64 startTime = uint64(block.timestamp);
        uint64 maturity  = cfg.model.computeMaturity(startTime, cfg.modelParams);

        uint128 fixedRate = uint128(
            FixedRateMath.computeFixedRate(
                twapWad, volWad, utilWad,
                cfg.alphaWad, cfg.betaWad, cfg.gammaWad
            )
        );

        uint32 index = cfg.epochCounter;
        epochId = EpochId.encode(poolId, index);

        cfg.activeEpochId = epochId;
        cfg.epochCounter  = index + 1;

        _epochs[epochId] = Epoch({
            epochId:       epochId,
            poolId:        poolId,
            startTime:     startTime,
            maturity:      maturity,
            fixedRate:     fixedRate,
            totalNotional: 0,
            status:        EpochStatus.ACTIVE
        });

        emit EpochOpened(epochId, poolId, startTime, maturity, fixedRate);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Return the full Epoch struct for a given epochId.
    ///         Returns a zero-value struct for unknown epochIds.
    ///         Check epoch.epochId != EpochId.NULL before using.
    function getEpoch(uint256 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    /// @notice Return top-level pool config fields.
    function getPoolConfig(PoolId poolId) external view returns (
        address model,
        uint256 activeEpochId_,
        uint32  epochCounter,
        bool    registered
    ) {
        PoolConfig storage cfg = _pools[PoolId.unwrap(poolId)];
        return (
            address(cfg.model),
            cfg.activeEpochId,
            cfg.epochCounter,
            cfg.registered
        );
    }

    /// @notice Compute the current fixed obligation for an epoch based on its
    ///         stored notional, rate, and full epoch duration.
    ///         Returns 0 for unknown epochIds or epochs with zero notional.
    function currentObligation(uint256 epochId) external view returns (uint256 obligation) {
        Epoch storage ep = _epochs[epochId];
        if (ep.epochId == EpochId.NULL) return 0;
        if (ep.totalNotional == 0)      return 0;

        uint64 duration = ep.maturity - ep.startTime;
        obligation = FixedRateMath.computeObligation(
            ep.totalNotional,
            ep.fixedRate,
            duration
        );
    }

    /// @notice True if the pool has an open, unsettled epoch.
    function hasActiveEpoch(PoolId poolId) external view returns (bool) {
        return _pools[PoolId.unwrap(poolId)].activeEpochId != EpochId.NULL;
    }

    /// @notice Return the active epochId for a pool, or EpochId.NULL.
    function activeEpochIdFor(PoolId poolId) external view returns (uint256) {
        return _pools[PoolId.unwrap(poolId)].activeEpochId;
    }
}

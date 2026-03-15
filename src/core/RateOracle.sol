// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AuthorizedCaller} from "../libraries/AuthorizedCaller.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title RateOracle
/// @notice Per-pool fee-yield TWAP and annualised volatility oracle for the
///         Paradox Fi fixed-income protocol.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// What it tracks
/// ─────────────────────────────────────────────────────────────────────────────
///
/// For each registered pool, RateOracle maintains a ring buffer of Observations.
/// Each observation records:
///   • A timestamp
///   • Cumulative fees earned by the protocol since deployment (for TWAP diff)
///   • A TVL snapshot at observation time (for yield normalisation)
///
/// From this buffer, two values are derived on demand:
///
///   twapWad  — 30-day TWAP of annualised fee yield (WAD = 1e18 = 100%)
///              = (feeDelta / avgTVL) × (SECONDS_PER_YEAR / timeDelta)
///
///   sigmaWad — Annualised standard deviation of per-observation fee yields (WAD)
///              Used by FixedRateMath as the volatility discount input.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Write strategy: rate-limited observations
/// ─────────────────────────────────────────────────────────────────────────────
///
/// record() is called by ParadoxHook on every afterSwap. However, a new ring
/// buffer slot is only written if at least `minObservationInterval` seconds
/// have elapsed since the last write. Between intervals, the running
/// feeCumulative is updated in-place on the most recent slot — this preserves
/// accuracy for TWAP computation without the gas cost of a new slot write.
///
/// Default minObservationInterval: 4 hours (14_400 seconds).
/// Ring buffer size: 360 slots ≈ one observation/day for one year at 4h intervals.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Annualisation
/// ─────────────────────────────────────────────────────────────────────────────
///
/// All outputs are annualised. A fee yield observed over D seconds is scaled:
///   annualisedYield = yieldOverPeriod × SECONDS_PER_YEAR / D
///
/// This makes the output directly compatible with FixedRateMath.computeFixedRate(),
/// which expects WAD-scaled annualised rates.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
/// record()         — authorizedCaller only (ParadoxHook)
/// getTWAP()        — unrestricted view
/// getVolatility()  — unrestricted view
/// registerPool()   — owner only
contract RateOracle is Ownable2Step, AuthorizedCaller {

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 internal constant WAD              = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev Number of slots in each pool's ring buffer.
    ///      360 slots at a 4-hour minimum interval covers ~60 days of writes,
    ///      or ~1 year at one write per day. Sized for the 30-day TWAP window.
    uint16  internal constant BUFFER_SIZE = 360;

    /// @dev Default minimum seconds between new ring buffer slots.
    uint32  public minObservationInterval = 4 hours;

    /// @dev Number of observations used for the TWAP window (30 days worth).
    ///      At minObservationInterval = 4h, 30 days = 180 observations.
    uint16  public twapWindowObservations = 180;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice One data point in the ring buffer.
    ///
    /// feeCumulative is a running sum of raw fee amounts (in the pool's fee
    /// token, unscaled). TVL is recorded as a token0-denominated snapshot at
    /// the time of the observation, used to normalise fees into a yield rate.
    struct Observation {
        /// @notice Unix timestamp of this observation.
        uint32  timestamp;
        /// @notice Cumulative fees collected since oracle deployment for this pool.
        ///         Monotonically increasing. TWAP is derived from the delta
        ///         between two observations.
        uint128 feeCumulative;
        /// @notice Pool TVL (token0-denominated) at observation time.
        ///         Used as the denominator for yield normalisation.
        uint128 tvlAtTime;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev Ring buffer: poolId → fixed array of BUFFER_SIZE observations.
    ///      Solidity does not support dynamic-size fixed arrays in mappings
    ///      directly, so we use a flat mapping with a manual index.
    mapping(bytes32 => Observation[BUFFER_SIZE]) private _observations;

    /// @dev Current write pointer for each pool's ring buffer (0-based, wraps).
    mapping(bytes32 => uint16) public observationIndex;

    /// @dev Count of total observations written (capped at BUFFER_SIZE).
    ///      Used to distinguish "buffer not yet full" from "slot 0 is oldest".
    mapping(bytes32 => uint16) public observationCount;

    /// @notice Whether a pool has been registered with the oracle.
    mapping(bytes32 => bool) public registered;

    // =========================================================================
    // Events
    // =========================================================================

    event PoolRegistered(PoolId indexed poolId);
    event ObservationRecorded(
        PoolId  indexed poolId,
        uint32          timestamp,
        uint128         feeCumulative,
        uint128         tvlAtTime,
        bool            newSlot
    );
    event MinObservationIntervalSet(uint32 previous, uint32 next);
    event TwapWindowSet(uint16 previous, uint16 next);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error PoolNotRegistered(PoolId poolId);
    error PoolAlreadyRegistered(PoolId poolId);
    error InsufficientObservations(uint16 available, uint16 required);
    error ZeroTVL();
    error InvalidWindow(uint16 window);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _owner, address _authorizedCaller) Ownable(_owner) AuthorizedCaller(_authorizedCaller) {
    }

    // =========================================================================
    // Governance
    // =========================================================================

    /// @notice Set the minimum seconds between new ring buffer slots.
    function setMinObservationInterval(uint32 interval) external onlyOwner {
        uint32 prev = minObservationInterval;
        minObservationInterval = interval;
        emit MinObservationIntervalSet(prev, interval);
    }

    /// @notice Set the number of observations used for the TWAP window.
    ///         Must be ≥ 2 (need at least two points for a diff) and
    ///         < BUFFER_SIZE.
    function setTwapWindowObservations(uint16 window) external onlyOwner {
        if (window < 2 || window >= BUFFER_SIZE) revert InvalidWindow(window);
        uint16 prev = twapWindowObservations;
        twapWindowObservations = window;
        emit TwapWindowSet(prev, window);
    }

    function setAuthorizedCaller(address caller) external onlyOwner {
        _setAuthorizedCaller(caller);
    }


    // =========================================================================
    // Pool registration
    // =========================================================================

    /// @notice Register a pool. Must be called before record() for a given pool.
    function registerPool(PoolId poolId) external onlyOwner {
        bytes32 key = PoolId.unwrap(poolId);
        if (registered[key]) revert PoolAlreadyRegistered(poolId);
        registered[key] = true;
        emit PoolRegistered(poolId);
    }

    // =========================================================================
    // Core: record
    // =========================================================================

    /// @notice Record a fee and TVL snapshot for a pool.
    ///
    /// Called by ParadoxHook on every afterSwap. Rate-limited: a new ring
    /// buffer slot is only written once per `minObservationInterval`. Between
    /// intervals, `feeCumulative` on the current slot is updated in-place so
    /// the TWAP computation always uses the latest cumulative value.
    ///
    /// @param poolId       The pool to record for.
    /// @param feeAmount    Raw fee amount earned in this swap (unscaled token units).
    /// @param currentTVL   Current pool TVL in token0-denominated units.
    function record(
        PoolId  poolId,
        uint128 feeAmount,
        uint128 currentTVL
    ) external onlyAuthorized {
        bytes32 key = PoolId.unwrap(poolId);
        if (!registered[key]) revert PoolNotRegistered(poolId);

        uint16 idx   = observationIndex[key];
        uint16 count = observationCount[key];

        uint32 now32 = uint32(block.timestamp);
        bool   newSlot;

        if (count == 0) {
            // First observation for this pool.
            _observations[key][0] = Observation({
                timestamp:     now32,
                feeCumulative: feeAmount,
                tvlAtTime:     currentTVL
            });
            observationIndex[key] = 0;
            observationCount[key] = 1;
            newSlot = true;

        } else {
            Observation storage current = _observations[key][idx];
            uint128 newCumulative = current.feeCumulative + feeAmount;

            if (now32 - current.timestamp >= minObservationInterval) {
                // Enough time has elapsed — advance to the next ring slot.
                uint16 nextIdx = (idx + 1) % BUFFER_SIZE;
                _observations[key][nextIdx] = Observation({
                    timestamp:     now32,
                    feeCumulative: newCumulative,
                    tvlAtTime:     currentTVL
                });
                observationIndex[key] = nextIdx;
                if (count < BUFFER_SIZE) observationCount[key] = count + 1;
                newSlot = true;
                idx = nextIdx;
            } else {
                // Within the interval — update cumulative in-place, keep timestamp.
                current.feeCumulative = newCumulative;
                // Also update TVL to the latest snapshot for better accuracy.
                current.tvlAtTime = currentTVL;
                newSlot = false;
            }
        }

        emit ObservationRecorded(
            poolId,
            _observations[key][idx].timestamp,
            _observations[key][idx].feeCumulative,
            _observations[key][idx].tvlAtTime,
            newSlot
        );
    }

    // =========================================================================
    // TWAP computation
    // =========================================================================

    /// @notice Compute the 30-day TWAP of annualised fee yield for a pool.
    ///
    /// Uses the two endpoints of the TWAP window (oldest and newest observation
    /// within `twapWindowObservations` slots) to compute:
    ///
    ///   feeDelta  = newestCumulative − oldestCumulative
    ///   avgTVL    = (newestTVL + oldestTVL) / 2
    ///   timeDelta = newestTimestamp − oldestTimestamp
    ///   twapYield = feeDelta / avgTVL                    (fractional yield over period)
    ///   twapWad   = twapYield × SECONDS_PER_YEAR / timeDelta   (annualised, WAD)
    ///
    /// Reverts if fewer than 2 observations are available.
    ///
    /// @param poolId The pool to query.
    /// @return twapWad Annualised fee yield as a WAD fraction (1e18 = 100%).
    function getTWAP(PoolId poolId) external view returns (uint256 twapWad) {
        bytes32 key   = PoolId.unwrap(poolId);
        if (!registered[key]) revert PoolNotRegistered(poolId);

        uint16 count  = observationCount[key];
        if (count < 2) revert InsufficientObservations(count, 2);

        uint16 windowSize = count < twapWindowObservations ? count : twapWindowObservations;

        // Newest observation is at observationIndex[key].
        uint16 newestIdx = observationIndex[key];
        // Oldest within the window: go back (windowSize - 1) slots.
        uint16 oldestIdx = _ringBack(newestIdx, windowSize - 1);

        Observation storage newest = _observations[key][newestIdx];
        Observation storage oldest = _observations[key][oldestIdx];

        uint32  timeDelta = newest.timestamp - oldest.timestamp;
        uint128 feeDelta  = newest.feeCumulative - oldest.feeCumulative;

        // Guard against degenerate case where both observations share a timestamp
        // (can happen if minObservationInterval is 0 in tests).
        if (timeDelta == 0) return 0;

        // avgTVL: simple average of endpoints. Using uint256 to avoid overflow.
        uint256 avgTVL = (uint256(newest.tvlAtTime) + uint256(oldest.tvlAtTime)) / 2;
        if (avgTVL == 0) revert ZeroTVL();

        // twapWad = (feeDelta / avgTVL) × (SECONDS_PER_YEAR / timeDelta) × WAD
        //
        // Reordered to multiply before dividing:
        //   = feeDelta × SECONDS_PER_YEAR × WAD / (avgTVL × timeDelta)
        //
        // Overflow analysis:
        //   feeDelta      ≤ 2^128
        //   SECONDS_PER_YEAR = 365 × 86400 ≈ 3.15e7 < 2^25
        //   WAD           = 1e18 < 2^60
        //   product       ≤ 2^128 × 2^25 × 2^60 = 2^213 — fits in uint256.
        twapWad = (uint256(feeDelta) * SECONDS_PER_YEAR * WAD)
                / (avgTVL * uint256(timeDelta));
    }

    // =========================================================================
    // Volatility computation
    // =========================================================================

    /// @notice Compute the annualised standard deviation of per-observation
    ///         fee yields (σ) over the TWAP window.
    ///
    /// Each consecutive pair of observations contributes one yield sample:
    ///   yieldI = (feeDelta_i / avgTVL_i) × (SECONDS_PER_YEAR / timeDelta_i)
    ///
    /// σ is then the population standard deviation of those samples, annualised.
    /// Returned as a WAD fraction.
    ///
    /// Reverts if fewer than 3 observations are available (need ≥ 2 samples for
    /// a meaningful standard deviation).
    ///
    /// @param poolId The pool to query.
    /// @return sigmaWad Annualised fee yield standard deviation (WAD).
    function getVolatility(PoolId poolId) external view returns (uint256 sigmaWad) {
        bytes32 key  = PoolId.unwrap(poolId);
        if (!registered[key]) revert PoolNotRegistered(poolId);

        uint16 count = observationCount[key];
        if (count < 3) revert InsufficientObservations(count, 3);

        uint16 windowSize = count < twapWindowObservations ? count : twapWindowObservations;
        uint16 n          = windowSize - 1; // number of yield samples

        uint16 newestIdx  = observationIndex[key];

        // Pass 1: compute mean yield across samples.
        uint256 sumYields;
        for (uint16 i = 0; i < n; i++) {
            uint16 b = _ringBack(newestIdx, i);
            uint16 a = _ringBack(newestIdx, i + 1);
            sumYields += _sampleYield(key, a, b);
        }
        uint256 meanYield = sumYields / n;

        // Pass 2: compute sum of squared deviations.
        uint256 sumSqDev;
        for (uint16 i = 0; i < n; i++) {
            uint16 b     = _ringBack(newestIdx, i);
            uint16 a     = _ringBack(newestIdx, i + 1);
            uint256 y    = _sampleYield(key, a, b);
            uint256 dev  = y > meanYield ? y - meanYield : meanYield - y;
            // dev is a WAD value ≤ ~2^60; dev^2 / WAD keeps it in WAD units.
            sumSqDev += (dev * dev) / WAD;
        }

        // Population variance = sumSqDev / n (in WAD).
        uint256 variance = sumSqDev / n;

        // σ = sqrt(variance). Integer square root on WAD-scaled value.
        // sqrt(WAD-scaled variance) gives a WAD-scaled σ because
        // sqrt(x × WAD) = sqrt(x) × sqrt(WAD) — we need one extra WAD factor.
        // Correct formula: sigmaWad = sqrt(variance × WAD).
        sigmaWad = _sqrt(variance * WAD);
    }

    // =========================================================================
    // View: raw observations
    // =========================================================================

    /// @notice Return a single observation by its ring buffer index.
    function getObservation(PoolId poolId, uint16 index)
        external view
        returns (Observation memory)
    {
        return _observations[PoolId.unwrap(poolId)][index];
    }

    /// @notice Return the most recent observation for a pool.
    function latestObservation(PoolId poolId)
        external view
        returns (Observation memory)
    {
        bytes32 key = PoolId.unwrap(poolId);
        return _observations[key][observationIndex[key]];
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Walk `steps` slots back from `idx` in the ring buffer.
    function _ringBack(uint16 idx, uint16 steps) internal pure returns (uint16) {
        // Add BUFFER_SIZE before subtracting to avoid underflow in modular arithmetic.
        return uint16((uint32(idx) + BUFFER_SIZE - steps) % BUFFER_SIZE);
    }

    /// @dev Compute the annualised yield WAD for the interval between
    ///      observations at ring indices `a` (older) and `b` (newer).
    ///      Returns 0 if timeDelta is 0 or TVL is 0.
    function _sampleYield(bytes32 key, uint16 a, uint16 b)
        internal view
        returns (uint256 yieldWad)
    {
        Observation storage obs_a = _observations[key][a];
        Observation storage obs_b = _observations[key][b];

        uint32  timeDelta = obs_b.timestamp - obs_a.timestamp;
        uint128 feeDelta  = obs_b.feeCumulative - obs_a.feeCumulative;

        if (timeDelta == 0) return 0;

        uint256 avgTVL = (uint256(obs_a.tvlAtTime) + uint256(obs_b.tvlAtTime)) / 2;
        if (avgTVL == 0) return 0;

        yieldWad = (uint256(feeDelta) * SECONDS_PER_YEAR * WAD)
                 / (avgTVL * uint256(timeDelta));
    }

    /// @dev Integer square root via Babylonian method.
    ///      Returns floor(sqrt(x)).
    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        // Initial estimate: use bit-length to get close.
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}

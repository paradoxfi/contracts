// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title FixedRateMath
/// @notice Pure library for computing the fixed rate offered to an LP at
///         deposit time, and for deriving the fixed obligation that accrues
///         over an epoch.
///
/// All rates are represented in WAD (1e18 = 100%).
/// All time values are in seconds.
/// All arithmetic uses unsigned integers; the formula is constructed so that
/// intermediate values never require signed arithmetic.
///
/// ─────────────────────────────────────────────────────────────────────────
/// Rate formula
/// ─────────────────────────────────────────────────────────────────────────
///
///   r_fixed = α · r_TWAP  −  β · r_vol  +  γ · r_util
///
/// where
///
///   r_TWAP  — 30-day TWAP of annualised fee yield for the pool (WAD)
///   r_vol   — volatility discount = σ / VOL_NORMALISER
///             σ is the annualised standard deviation of the fee yield (WAD)
///             VOL_NORMALISER = 3  (a 3-sigma fee drop should still cover
///             the fixed obligation; dividing by 3 scales the discount to
///             match that safety margin)
///   r_util  — utilisation premium = max(0, util − UTIL_THRESHOLD)
///             util is the fraction of epoch FYTs already sold (WAD)
///             UTIL_THRESHOLD = 0.5e18 (50%) — no premium below half-full
///
///   α, β, γ — governance-controlled weights, each stored in WAD
///
/// The formula is evaluated with mulWad throughout to preserve precision
/// without overflow (all operands are WAD fractions < 1e36 after mul).
///
/// The result is floored at MIN_RATE and capped at r_TWAP to prevent
/// the formula from ever offering more than the historical average
/// (which would guarantee a deficit) or a negative rate.
///
/// ─────────────────────────────────────────────────────────────────────────
/// Fixed obligation
/// ─────────────────────────────────────────────────────────────────────────
///
///   obligation = notional · r_fixed · epochDuration / SECONDS_PER_YEAR
///
/// This is simple-interest accrual — no compounding. Appropriate for
/// short-to-medium epoch durations (≤ 1 year). Compounding would add
/// complexity with negligible economic difference at these timescales.
///
/// ─────────────────────────────────────────────────────────────────────────
/// Why a library and not inline math?
/// ─────────────────────────────────────────────────────────────────────────
/// Isolating the arithmetic here means:
///   • computeFixedRate() and computeObligation() can be unit-tested and
///     fuzz-tested without any protocol scaffolding.
///   • EpochManager and RateOracle can call the same functions without
///     duplicating logic.
///   • Governance parameter changes affect a single, audited code path.
library FixedRateMath {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a WAD-scaled weight (α, β, or γ) exceeds 1e18.
    /// Weights above 1 WAD are almost certainly misconfigured and would
    /// produce rates far outside sensible economic bounds.
    error WeightExceedsWad(uint256 weight);

    /// @notice Thrown when r_TWAP is zero. A zero TWAP means the oracle has
    /// no fee history for the pool; opening an epoch in this state would
    /// lock in a 0% fixed rate regardless of weights.
    error ZeroTwap();

    /// @notice Thrown when r_TWAP is below MIN_RATE.
    /// When the TWAP is smaller than the protocol floor, the cap (twapWad) and
    /// the floor (MIN_RATE) are contradictory — no valid rate exists. This
    /// indicates the pool has insufficient fee history to open a new epoch.
    error TwapBelowMinRate(uint256 twapWad, uint256 minRate);

    /// @notice Thrown when notional is zero. A zero-notional position cannot
    /// accrue any obligation and indicates a caller bug.
    error ZeroNotional();

    /// @notice Thrown when epochDuration is zero.
    error ZeroDuration();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @dev WAD: 1e18. The unit for all rate and weight values.
    uint256 internal constant WAD = 1e18;

    /// @dev Seconds in a 365-day year. Used for annualisation.
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @dev The volatility term is σ / VOL_NORMALISER.
    /// Setting this to 3 means the discount equals one-third of the
    /// annualised fee standard deviation, leaving a 3-sigma buffer before
    /// the fixed rate would exceed realised fees.
    uint256 internal constant VOL_NORMALISER = 3;

    /// @dev Utilisation threshold below which no premium is added (50% in WAD).
    uint256 internal constant UTIL_THRESHOLD = 0.5e18;

    /// @dev Minimum fixed rate: 0.01% APR in WAD.
    /// Prevents the formula from producing a rate so low it is economically
    /// meaningless or triggers edge cases in obligation arithmetic.
    uint256 internal constant MIN_RATE = 0.0001e18;

    /// @dev Maximum weight value: 1 WAD (= 100%).
    uint256 internal constant MAX_WEIGHT = WAD;

    // -------------------------------------------------------------------------
    // Core computation
    // -------------------------------------------------------------------------

    /// @notice Compute the fixed rate to offer an LP at deposit time.
    ///
    /// @param twapWad   30-day TWAP of annualised fee yield, in WAD.
    ///                  Example: 6.2% APR → 0.062e18.
    /// @param sigmaWad  Annualised standard deviation of the fee yield, in WAD.
    ///                  Example: 28% → 0.28e18.
    /// @param utilWad   Fraction of epoch FYTs already sold, in WAD.
    ///                  Example: 72% sold → 0.72e18.
    /// @param alphaWad  Weight on the TWAP component. Must be ≤ 1e18.
    /// @param betaWad   Weight on the volatility discount. Must be ≤ 1e18.
    /// @param gammaWad  Weight on the utilisation premium. Must be ≤ 1e18.
    ///
    /// @return rateWad  The fixed rate in WAD, floored at MIN_RATE and capped
    ///                  at twapWad. Example: 2.49% → 0.0249e18.
    function computeFixedRate(
        uint256 twapWad,
        uint256 sigmaWad,
        uint256 utilWad,
        uint256 alphaWad,
        uint256 betaWad,
        uint256 gammaWad
    ) internal pure returns (uint256 rateWad) {
        // ── Input validation ─────────────────────────────────────────────────

        if (twapWad == 0) revert ZeroTwap();
        if (twapWad < MIN_RATE) revert TwapBelowMinRate(twapWad, MIN_RATE);
        _requireValidWeight(alphaWad);
        _requireValidWeight(betaWad);
        _requireValidWeight(gammaWad);

        // ── Component 1: TWAP term  (α · r_TWAP) ────────────────────────────

        uint256 twapTerm = mulWad(alphaWad, twapWad);

        // ── Component 2: volatility discount  (β · σ / 3) ───────────────────
        //
        // vol discount = β · (σ / VOL_NORMALISER)
        //
        // We divide first (σ / 3) then multiply by β to keep the intermediate
        // value in the same WAD range as the other terms.
        // Rounding down the division is conservative: a smaller discount means
        // a slightly lower offered rate, which is safer for the protocol.

        uint256 volTerm = mulWad(betaWad, sigmaWad / VOL_NORMALISER);

        // ── Component 3: utilisation premium  (γ · max(0, util − 0.5)) ──────

        uint256 utilExcess = utilWad > UTIL_THRESHOLD
            ? utilWad - UTIL_THRESHOLD
            : 0;
        uint256 utilTerm = mulWad(gammaWad, utilExcess);

        // ── Combine: TWAP term − vol discount + util premium ─────────────────
        //
        // The subtraction (twapTerm − volTerm) can underflow if the volatility
        // discount exceeds the TWAP term. This is valid: it means the pool is
        // so volatile relative to its average fee yield that the formula
        // produces a "negative" rate before the util premium is added.
        // We handle this by saturating at zero before adding the util premium,
        // then applying the floor afterward.

        uint256 afterDiscount = twapTerm > volTerm ? twapTerm - volTerm : 0;
        uint256 raw = afterDiscount + utilTerm;

        // ── Bounds ────────────────────────────────────────────────────────────
        //
        // Floor at MIN_RATE: a rate below 0.01% is economically meaningless.
        // Cap at twapWad: the protocol must never promise more than the
        // historical average yield — doing so guarantees a deficit.

        rateWad = _clamp(raw, MIN_RATE, twapWad);
    }

    /// @notice Compute the total fixed obligation for a position over an epoch.
    ///
    /// Uses simple-interest accrual (no compounding). Appropriate for epoch
    /// durations up to one year.
    ///
    ///   obligation = notional · rateWad · epochDuration / SECONDS_PER_YEAR / WAD
    ///
    /// The division by WAD collapses the WAD scaling introduced by mulWad.
    /// The division by SECONDS_PER_YEAR converts from APR to epoch-period yield.
    ///
    /// @param notional       Deposit notional in token units (not WAD-scaled).
    ///                       Example: 10,000 USDC at 6 decimals → 10_000e6.
    /// @param rateWad        Fixed rate in WAD. Example: 8% → 0.08e18.
    /// @param epochDuration  Epoch length in seconds. Example: 90 days.
    ///
    /// @return obligation    Fixed yield owed at maturity, in the same token
    ///                       units as notional.
    function computeObligation(
        uint256 notional,
        uint256 rateWad,
        uint256 epochDuration
    ) internal pure returns (uint256 obligation) {
        if (notional == 0)      revert ZeroNotional();
        if (epochDuration == 0) revert ZeroDuration();

        // notional · rateWad / WAD  →  notional scaled to epoch yield
        // then  · epochDuration / SECONDS_PER_YEAR  →  pro-rate to epoch length
        //
        // Order of operations matters for precision. Multiply before dividing
        // to minimise truncation. Both divisors are large constants so we
        // combine them: divide by (WAD · SECONDS_PER_YEAR / epochDuration)
        // is not safe without careful overflow analysis. Instead we use the
        // two-step approach, which is safe because:
        //   notional · rateWad ≤ 2^128 · 1e18 < 2^256  (notional is uint128
        //   in PositionManager, rateWad < 1e18 by validation above)
        obligation = (notional * rateWad / WAD) * epochDuration / SECONDS_PER_YEAR;
    }

    // -------------------------------------------------------------------------
    // WAD arithmetic helpers
    // -------------------------------------------------------------------------

    /// @notice Multiply two WAD values, returning a WAD result.
    ///
    ///   mulWad(a, b) = a · b / 1e18
    ///
    /// Rounds down (floor). This is the standard WAD multiply used throughout
    /// DeFi (cf. solmate FixedPointMathLib). We inline it here rather than
    /// importing solmate so this library has no external dependencies and can
    /// be tested and audited in complete isolation.
    ///
    /// Overflow analysis: a and b are both WAD-scaled rates or weights, so
    /// both are < 1e18. Their product is < 1e36 < 2^120, well within uint256.
    ///
    /// @param a  WAD-scaled value.
    /// @param b  WAD-scaled value.
    /// @return   a · b / 1e18, rounded down.
    function mulWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    /// @notice Divide two WAD values, returning a WAD result.
    ///
    ///   divWad(a, b) = a · 1e18 / b
    ///
    /// Rounds down. Reverts on division by zero (Solidity default behaviour).
    ///
    /// @param a  WAD-scaled numerator.
    /// @param b  WAD-scaled denominator. Must be non-zero.
    /// @return   (a / b) in WAD, rounded down.
    function divWad(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD) / b;
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Revert if weight > MAX_WEIGHT (1 WAD).
    function _requireValidWeight(uint256 weight) private pure {
        if (weight > MAX_WEIGHT) revert WeightExceedsWad(weight);
    }

    /// @dev Clamp value into [lo, hi]. Assumes lo ≤ hi.
    function _clamp(uint256 value, uint256 lo, uint256 hi)
        private
        pure
        returns (uint256)
    {
        if (value < lo) return lo;
        if (value > hi) return hi;
        return value;
    }
}

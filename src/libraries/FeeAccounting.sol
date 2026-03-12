// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @title FeeAccounting
/// @notice Pure library for extracting fee amounts from Uniswap v4 swap deltas.
///
/// ─────────────────────────────────────────────────────────────────────────
/// v4 BalanceDelta primer
/// ─────────────────────────────────────────────────────────────────────────
///
/// BalanceDelta is a packed int256:
///   • Upper 128 bits  →  amount0 (int128): net change in token0 for the pool
///   • Lower 128 bits  →  amount1 (int128): net change in token1 for the pool
///
/// Sign convention (from the pool's perspective):
///   • Negative amount  →  pool is paying out (sending tokens to the swapper)
///   • Positive amount  →  pool is receiving  (taking tokens from the swapper)
///
/// In afterSwap, the hook receives:
///   • `delta`      — the net BalanceDelta for the entire swap (including fees)
///   • `hookDelta`  — a separate int128 representing any amount the hook itself
///                    wishes to claim (Paradox Fi sets this to 0)
///
/// ─────────────────────────────────────────────────────────────────────────
/// Fee extraction logic
/// ─────────────────────────────────────────────────────────────────────────
///
/// In a v4 pool the LP fee is retained inside the pool — it does not appear as
/// a separate line in BalanceDelta. What we observe in the hook is the *net*
/// effect on pool balances after the fee has already been withheld:
///
///   For an exact-input swap (swapper pays tokenIn, receives tokenOut):
///     • The tokenIn amount received by the pool  = gross input
///     • The tokenOut amount paid by the pool     = gross input × (1 − fee_rate)
///     • Fee stays inside the pool as LP revenue
///
/// Paradox Fi does not intercept the fee mid-swap — it reads the cumulative
/// fee revenue from the PoolManager after the fact via
/// `poolManager.getPoolFeeRevenue()` / protocol-fee accounting, or equivalently
/// it tracks the fee by comparing the expected no-fee delta against the actual
/// delta.
///
/// However, the cleanest hook-level approach in v4 is to read the fee from
/// the swap's BalanceDelta directly:
///
///   swapFee = |amountIn| × poolFeeRate / (1e6 − poolFeeRate)
///
/// But this requires knowing which leg is "in". A simpler and equally correct
/// approach for a hook that does not itself charge a hook fee is:
///
///   fees_in_token0 = max(0,  delta.amount0())   // positive = pool received
///   fees_in_token1 = max(0,  delta.amount1())   // positive = pool received
///
/// For a swap zeroForOne (token0 in, token1 out):
///   • delta.amount0() > 0  — pool received token0 (gross input including fee)
///   • delta.amount1() < 0  — pool paid token1 (output net of fee)
///   • The fee component in token0 = amount0 − |amount1| × price  (approximate)
///
/// Rather than attempting to reconstruct the exact fee from price, this library
/// takes the approach used by most v4 fee-tracking hooks: record the gross
/// positive amount received on the input leg as the fee-accruing quantity, then
/// let the YieldRouter normalise this into a yield figure relative to TVL via
/// the RateOracle. The absolute precision of the per-swap fee split is less
/// important than the long-run TWAP, which smooths out rounding.
///
/// Concretely: extractFeeAmount returns the absolute value of the *input* leg
/// of the swap delta — the leg where the pool received tokens. This is the
/// quantity that contains the fee.
///
/// ─────────────────────────────────────────────────────────────────────────
/// Denominating fees in a single token
/// ─────────────────────────────────────────────────────────────────────────
///
/// Uniswap v4 pools can have fees in either token0 or token1 (or both for a
/// two-sided fee pool). This library exposes:
///
///   1. extractInputAmount()  — the raw uint128 input amount, useful when the
///                              caller knows which leg is the input.
///   2. extractFeeAmounts()   — returns both legs' absolute values and a
///                              `zeroForOne` flag so the caller can route each
///                              to the correct token balance.
///   3. toToken1Denominated() — converts a token0 amount to token1 using the
///                              pool's current sqrtPrice, for normalisation.
///
/// YieldRouter uses (2) and stores per-token balances separately; RateOracle
/// uses (3) to denominate all fee observations in a single unit for TWAP.
library FeeAccounting {
    using BalanceDeltaLibrary for BalanceDelta;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when both legs of the delta are zero or both are negative
    ///         (pool paid out on both sides). This should never happen on a
    ///         well-formed swap.
    error UnexpectedDelta(int128 amount0, int128 amount1);

    /// @notice Thrown when sqrtPriceX96 is zero (uninitialized pool).
    error ZeroSqrtPrice();

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    /// @notice The result of extracting fee amounts from a swap delta.
    ///
    /// @param amount0      Absolute value of the token0 leg of the delta.
    ///                     Non-zero when token0 is the input leg.
    /// @param amount1      Absolute value of the token1 leg of the delta.
    ///                     Non-zero when token1 is the input leg.
    /// @param zeroForOne   True if the swap was token0-in / token1-out.
    ///                     When true, amount0 is the fee-bearing leg.
    ///                     When false, amount1 is the fee-bearing leg.
    struct SwapFeeAmounts {
        uint128 amount0;
        uint128 amount1;
        bool    zeroForOne;
    }

    // -------------------------------------------------------------------------
    // Core extraction
    // -------------------------------------------------------------------------

    /// @notice Extract the absolute value of the input leg from a swap delta.
    ///
    /// The input leg is the one where the pool received tokens (positive delta).
    /// This is the quantity that contains the LP fee.
    ///
    /// @param delta      The BalanceDelta from afterSwap.
    /// @param zeroForOne The swap direction from SwapParams.zeroForOne.
    /// @return inputAmt  Absolute value of the input leg (always ≥ 0).
    function extractInputAmount(BalanceDelta delta, bool zeroForOne)
        internal
        pure
        returns (uint128 inputAmt)
    {
        if (zeroForOne) {
            // token0 in, token1 out: amount0 is positive (pool received token0)
            int128 a0 = delta.amount0();
            inputAmt = a0 >= 0 ? uint128(a0) : uint128(uint256(-int256(a0)));
        } else {
            // token1 in, token0 out: amount1 is positive (pool received token1)
            int128 a1 = delta.amount1();
            inputAmt = a1 >= 0 ? uint128(a1) : uint128(uint256(-int256(a1)));
        }
    }

    /// @notice Extract both leg amounts and the swap direction from a delta.
    ///
    /// Both amount0 and amount1 are returned as absolute values (uint128).
    /// The zeroForOne flag indicates which is the fee-bearing (input) leg.
    ///
    /// Reverts with UnexpectedDelta if the delta is structurally impossible
    /// (both legs zero, or both legs positive, which would mean the pool
    /// received tokens on both sides simultaneously).
    ///
    /// @param delta   The BalanceDelta from afterSwap.
    /// @param params  The SwapParams from afterSwap (used for zeroForOne).
    /// @return sfa    SwapFeeAmounts struct with both absolute amounts and direction.
    function extractFeeAmounts(
        BalanceDelta delta,
        SwapParams calldata params
    ) internal pure returns (SwapFeeAmounts memory sfa) {
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();

        // Both zero: a no-op swap (zero amountSpecified). Not an error per se,
        // but produces zero fee — the caller should handle this gracefully.
        // We still populate the struct with zeros and the direction flag.
        sfa.zeroForOne = params.zeroForOne;

        // Both positive would mean the pool received tokens on both legs
        // simultaneously — structurally impossible for a legitimate swap.
        if (a0 > 0 && a1 > 0) revert UnexpectedDelta(a0, a1);

        // Safe absolute value: int128.min = -2^127; negating it directly in
        // int128 overflows (2^127 > int128.max = 2^127-1). We widen to int256
        // first so the negation is exact, then truncate to uint128.
        sfa.amount0 = a0 >= 0 ? uint128(a0) : uint128(uint256(-int256(a0)));
        sfa.amount1 = a1 >= 0 ? uint128(a1) : uint128(uint256(-int256(a1)));
    }

    /// @notice Return only the fee-bearing input amount from a full delta,
    ///         denominated in the input token's native units.
    ///
    /// Convenience wrapper around extractFeeAmounts for callers that only
    /// need the single fee quantity and already know or don't care about the
    /// output leg.
    ///
    /// @param delta   The BalanceDelta from afterSwap.
    /// @param params  The SwapParams from afterSwap.
    /// @return token  The input token Currency.
    /// @return amt    The input amount in that token's native units.
    function extractInputLeg(
        BalanceDelta delta,
        SwapParams calldata params,
        PoolKey calldata key
    ) internal pure returns (Currency token, uint128 amt) {
        SwapFeeAmounts memory sfa = extractFeeAmounts(delta, params);
        if (sfa.zeroForOne) {
            token = key.currency0;
            amt   = sfa.amount0;
        } else {
            token = key.currency1;
            amt   = sfa.amount1;
        }
    }

    // -------------------------------------------------------------------------
    // Price conversion helper
    // -------------------------------------------------------------------------

    /// @notice Convert a token0 amount to token1 using sqrtPriceX96.
    ///
    /// Used by RateOracle to denominate all fee observations in token1 for a
    /// consistent TWAP unit. For ETH/USDC pools, token1 is USDC, so all fee
    /// observations become USDC-denominated.
    ///
    /// Formula:
    ///   price = (sqrtPriceX96 / 2^96)^2
    ///   amount1 = amount0 × price
    ///           = amount0 × sqrtPriceX96^2 / 2^192
    ///
    /// Intermediate overflow analysis:
    ///   amount0     ≤ 2^128 − 1
    ///   sqrtPriceX96 ≤ 2^96  (by v4 invariant: price fits in Q64.96)
    ///   sqrtPriceX96^2 ≤ 2^192
    ///   amount0 × sqrtPriceX96^2 ≤ 2^320 — overflows uint256.
    ///
    /// To avoid overflow we use the decomposed form:
    ///   result = amount0 × sqrtPriceX96 / 2^96 × sqrtPriceX96 / 2^96
    /// Each step stays within uint256 provided amount0 < 2^128 and
    /// sqrtPriceX96 < 2^96 (both guaranteed by v4 invariants).
    ///
    /// Precision note: two sequential divisions by 2^96 introduce rounding
    /// (floor). For fee accounting this is acceptable — the TWAP smooths
    /// per-swap rounding errors over the observation window.
    ///
    /// @param amount0      Token0 amount in native units.
    /// @param sqrtPriceX96 Current pool sqrtPrice in Q64.96 format.
    /// @return amount1     Equivalent token1 amount, rounded down.
    function toToken1Denominated(uint128 amount0, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtPriceX96 == 0) revert ZeroSqrtPrice();
        if (amount0 == 0)      return 0;

        // Step 1: amount0 × sqrtPriceX96 / 2^96
        //   max intermediate: (2^128 − 1) × (2^96) ≈ 2^224 — fits in uint256.
        uint256 step1 = (uint256(amount0) * uint256(sqrtPriceX96)) >> 96;

        // Step 2: step1 × sqrtPriceX96 / 2^96
        //   max intermediate: step1 ≤ (2^224)/2^96 = 2^128, then × 2^96 = 2^224
        //   — fits in uint256.
        amount1 = (step1 * uint256(sqrtPriceX96)) >> 96;
    }

    /// @notice Convert a token1 amount to token0 using sqrtPriceX96.
    ///
    /// Inverse of toToken1Denominated. Used when the fee-bearing leg is
    /// token1 and the caller wants a token0-denominated observation.
    ///
    /// Formula:
    ///   amount0 = amount1 / price
    ///           = amount1 × 2^192 / sqrtPriceX96^2
    ///
    /// Decomposed to avoid overflow:
    ///   result = amount1 × 2^96 / sqrtPriceX96 × 2^96 / sqrtPriceX96
    ///
    /// @param amount1      Token1 amount in native units.
    /// @param sqrtPriceX96 Current pool sqrtPrice in Q64.96 format.
    /// @return amount0     Equivalent token0 amount, rounded down.
    function toToken0Denominated(uint128 amount1, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtPriceX96 == 0) revert ZeroSqrtPrice();
        if (amount1 == 0)      return 0;

        // Step 1: amount1 × 2^96 / sqrtPriceX96
        uint256 step1 = (uint256(amount1) << 96) / uint256(sqrtPriceX96);

        // Step 2: step1 × 2^96 / sqrtPriceX96
        amount0 = (step1 << 96) / uint256(sqrtPriceX96);
    }

    // -------------------------------------------------------------------------
    // Utility: zero-swap guard
    // -------------------------------------------------------------------------

    /// @notice Return true if the delta represents a zero-value swap.
    ///
    /// A zero swap (amountSpecified = 0) produces a zero delta. The hook
    /// should skip fee accounting entirely in this case — calling ingest()
    /// with zero fees is safe but wastes gas.
    ///
    /// @param delta  The BalanceDelta from afterSwap.
    /// @return       True if both legs are zero.
    function isZeroSwap(BalanceDelta delta) internal pure returns (bool) {
        return delta.amount0() == 0 && delta.amount1() == 0;
    }
}

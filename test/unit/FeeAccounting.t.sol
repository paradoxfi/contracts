// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {FeeAccounting} from "../../src/libraries/FeeAccounting.sol";

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------
contract FeeAccountingHarness {
    function extractInputAmount(BalanceDelta delta, bool zeroForOne)
        external pure returns (uint128)
    {
        return FeeAccounting.extractInputAmount(delta, zeroForOne);
    }

    function extractFeeAmounts(
        BalanceDelta delta,
        SwapParams calldata params
    ) external pure returns (FeeAccounting.SwapFeeAmounts memory) {
        return FeeAccounting.extractFeeAmounts(delta, params);
    }

    function extractInputLeg(
        BalanceDelta delta,
        SwapParams calldata params,
        PoolKey calldata key
    ) external pure returns (Currency, uint128) {
        return FeeAccounting.extractInputLeg(delta, params, key);
    }

    function toToken1Denominated(uint128 amount0, uint160 sqrtPriceX96)
        external pure returns (uint256)
    {
        return FeeAccounting.toToken1Denominated(amount0, sqrtPriceX96);
    }

    function toToken0Denominated(uint128 amount1, uint160 sqrtPriceX96)
        external pure returns (uint256)
    {
        return FeeAccounting.toToken0Denominated(amount1, sqrtPriceX96);
    }

    function isZeroSwap(BalanceDelta delta) external pure returns (bool) {
        return FeeAccounting.isZeroSwap(delta);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// @dev Build a SwapParams with only the fields FeeAccounting reads.
function makeParams(bool zeroForOne) pure returns (SwapParams memory p) {
    p.zeroForOne      = zeroForOne;
    p.amountSpecified = 1e18; // non-zero; value irrelevant for extraction
    p.sqrtPriceLimitX96 = 0;
}

/// @dev Build a minimal PoolKey. Only currency0/currency1 are used by extractInputLeg.
function makeKey(address token0, address token1) pure returns (PoolKey memory k) {
    k.currency0 = Currency.wrap(token0);
    k.currency1 = Currency.wrap(token1);
    k.fee       = 3000;
    k.tickSpacing = 60;
    k.hooks     = IHooks(address(0));
}

// ---------------------------------------------------------------------------
// Test contract
// ---------------------------------------------------------------------------

/// @title FeeAccountingTest
///
/// Test organisation
/// -----------------
///   Section A — extractInputAmount: direction cases
///   Section B — extractFeeAmounts: both legs, revert paths
///   Section C — extractInputLeg: currency routing
///   Section D — toToken1Denominated / toToken0Denominated
///   Section E — inverse relationship (token0 ↔ token1 round-trip)
///   Section F — isZeroSwap
///   Section G — Fuzz
contract FeeAccountingTest is Test {
    FeeAccountingHarness internal h;

    // Canonical sqrtPrice for 1:1 price (token0 = token1 in value).
    // sqrtPriceX96 at price=1: sqrt(1) × 2^96 = 2^96
    uint160 internal constant SQRT_PRICE_1_1 = uint160(1 << 96);

    // sqrtPrice for price = 4 (token0 worth 4× token1): sqrt(4) × 2^96 = 2 × 2^96
    uint160 internal constant SQRT_PRICE_4_1 = uint160(2 << 96);

    // sqrtPrice for price = 1/4: sqrt(0.25) × 2^96 = 0.5 × 2^96 = 2^95
    uint160 internal constant SQRT_PRICE_1_4 = uint160(1 << 95);

    address internal constant TOKEN0 = address(0xA0A0);
    address internal constant TOKEN1 = address(0xB1B1);

    function setUp() public {
        h = new FeeAccountingHarness();
    }

    // =========================================================================
    // A — extractInputAmount
    // =========================================================================

    function test_extractInputAmount_zeroForOne_positiveAmount0() public view {
        // zeroForOne: token0 in (positive), token1 out (negative)
        BalanceDelta delta = toBalanceDelta(int128(1_000e6), int128(-990e6));
        uint128 amt = h.extractInputAmount(delta, true);
        assertEq(amt, 1_000e6);
    }

    function test_extractInputAmount_oneForZero_positiveAmount1() public view {
        // oneForZero: token1 in (positive), token0 out (negative)
        BalanceDelta delta = toBalanceDelta(int128(-990e6), int128(1_000e6));
        uint128 amt = h.extractInputAmount(delta, false);
        assertEq(amt, 1_000e6);
    }

    function test_extractInputAmount_zeroForOne_takeAbsWhenNegative() public view {
        // Edge case: amount0 is negative in a zeroForOne swap.
        // Should not happen in practice, but the function handles it defensively
        // by taking abs() — it returns the magnitude either way.
        BalanceDelta delta = toBalanceDelta(int128(-500e6), int128(490e6));
        uint128 amt = h.extractInputAmount(delta, true);
        assertEq(amt, 500e6);
    }

    function test_extractInputAmount_zeroAmount() public view {
        BalanceDelta delta = toBalanceDelta(int128(0), int128(-100e6));
        uint128 amt = h.extractInputAmount(delta, true);
        assertEq(amt, 0);
    }

    // =========================================================================
    // B — extractFeeAmounts
    // =========================================================================

    function test_extractFeeAmounts_zeroForOne() public view {
        // Normal zeroForOne swap: amount0 > 0 (input), amount1 < 0 (output)
        BalanceDelta delta = toBalanceDelta(int128(2_000e6), int128(-1_980e6));
        SwapParams memory params = makeParams(true);

        FeeAccounting.SwapFeeAmounts memory sfa = h.extractFeeAmounts(delta, params);

        assertTrue(sfa.zeroForOne);
        assertEq(sfa.amount0, 2_000e6);
        assertEq(sfa.amount1, 1_980e6);
    }

    function test_extractFeeAmounts_oneForZero() public view {
        // Normal oneForZero swap: amount0 < 0 (output), amount1 > 0 (input)
        BalanceDelta delta = toBalanceDelta(int128(-1_980e6), int128(2_000e6));
        SwapParams memory params = makeParams(false);

        FeeAccounting.SwapFeeAmounts memory sfa = h.extractFeeAmounts(delta, params);

        assertFalse(sfa.zeroForOne);
        assertEq(sfa.amount0, 1_980e6);
        assertEq(sfa.amount1, 2_000e6);
    }

    function test_extractFeeAmounts_zeroSwap_bothZero() public view {
        // Both amounts zero: valid (zero-value swap), no revert.
        BalanceDelta delta = toBalanceDelta(int128(0), int128(0));
        SwapParams memory params = makeParams(true);

        FeeAccounting.SwapFeeAmounts memory sfa = h.extractFeeAmounts(delta, params);

        assertEq(sfa.amount0, 0);
        assertEq(sfa.amount1, 0);
    }

    function test_extractFeeAmounts_reverts_bothPositive() public {
        // Both legs positive is structurally impossible for a legitimate swap.
        BalanceDelta delta = toBalanceDelta(int128(100e6), int128(100e6));
        SwapParams memory params = makeParams(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                FeeAccounting.UnexpectedDelta.selector,
                int128(100e6),
                int128(100e6)
            )
        );
        h.extractFeeAmounts(delta, params);
    }

    function test_extractFeeAmounts_int128Min_doesNotOverflow() public view {
        // type(int128).min = -2^127. The safe absolute value is 2^127,
        // which fits in uint128 (max = 2^128 - 1).
        // Direct `uint128(-type(int128).min)` panics in Solidity because
        // negation is performed in int128 first and 2^127 overflows int128.
        // The library widens to int256 before negating to avoid this.
        int128 minVal = type(int128).min;
        BalanceDelta delta = toBalanceDelta(int128(0), minVal);
        SwapParams memory params = makeParams(false);

        FeeAccounting.SwapFeeAmounts memory sfa = h.extractFeeAmounts(delta, params);

        // |type(int128).min| = 2^127 = type(int128).max + 1
        uint128 expected = uint128(uint256(int256(type(int128).max)) + 1);
        assertEq(sfa.amount1, expected);
    }

    // =========================================================================
    // C — extractInputLeg: currency routing
    // =========================================================================

    function test_extractInputLeg_zeroForOne_returnsCurrency0() public view {
        BalanceDelta delta = toBalanceDelta(int128(500e6), int128(-495e6));
        SwapParams memory params = makeParams(true);
        PoolKey memory key = makeKey(TOKEN0, TOKEN1);

        (Currency token, uint128 amt) = h.extractInputLeg(delta, params, key);

        assertEq(Currency.unwrap(token), TOKEN0);
        assertEq(amt, 500e6);
    }

    function test_extractInputLeg_oneForZero_returnsCurrency1() public view {
        BalanceDelta delta = toBalanceDelta(int128(-495e6), int128(500e6));
        SwapParams memory params = makeParams(false);
        PoolKey memory key = makeKey(TOKEN0, TOKEN1);

        (Currency token, uint128 amt) = h.extractInputLeg(delta, params, key);

        assertEq(Currency.unwrap(token), TOKEN1);
        assertEq(amt, 500e6);
    }

    // =========================================================================
    // D — toToken1Denominated / toToken0Denominated
    // =========================================================================

    function test_toToken1_priceOneToOne() public view {
        // At price = 1 (sqrtPrice = 2^96): 100 token0 = 100 token1.
        uint256 result = h.toToken1Denominated(100e6, SQRT_PRICE_1_1);
        // Expect 100e6; small rounding from two shifts is acceptable.
        assertApproxEqAbs(result, 100e6, 2, "1:1 price conversion");
    }

    function test_toToken1_priceFourToOne() public view {
        // At price = 4 (token0 worth 4× token1):
        // 100 token0 → 400 token1
        uint256 result = h.toToken1Denominated(100e6, SQRT_PRICE_4_1);
        assertApproxEqAbs(result, 400e6, 4, "4:1 price conversion");
    }

    function test_toToken1_zeroAmount_returnsZero() public view {
        uint256 result = h.toToken1Denominated(0, SQRT_PRICE_1_1);
        assertEq(result, 0);
    }

    function test_toToken1_reverts_zeroSqrtPrice() public {
        vm.expectRevert(FeeAccounting.ZeroSqrtPrice.selector);
        h.toToken1Denominated(100e6, 0);
    }

    function test_toToken0_priceOneToOne() public view {
        uint256 result = h.toToken0Denominated(100e6, SQRT_PRICE_1_1);
        assertApproxEqAbs(result, 100e6, 2, "1:1 reverse conversion");
    }

    function test_toToken0_priceFourToOne() public view {
        // At price = 4: 400 token1 → 100 token0
        uint256 result = h.toToken0Denominated(400e6, SQRT_PRICE_4_1);
        assertApproxEqAbs(result, 100e6, 4, "4:1 reverse conversion");
    }

    function test_toToken0_zeroAmount_returnsZero() public view {
        uint256 result = h.toToken0Denominated(0, SQRT_PRICE_1_1);
        assertEq(result, 0);
    }

    function test_toToken0_reverts_zeroSqrtPrice() public {
        vm.expectRevert(FeeAccounting.ZeroSqrtPrice.selector);
        h.toToken0Denominated(100e6, 0);
    }

    // =========================================================================
    // E — round-trip: token0 → token1 → token0
    // =========================================================================

    function test_roundTrip_1_1() public view {
        uint128 original = 1_000e6;
        uint256 inToken1 = h.toToken1Denominated(original, SQRT_PRICE_1_1);
        // toToken0Denominated expects uint128; safe cast since inToken1 ≈ 1_000e6
        uint256 backTo0  = h.toToken0Denominated(uint128(inToken1), SQRT_PRICE_1_1);
        // Two sequential roundings: allow 2 wei tolerance.
        assertApproxEqAbs(backTo0, original, 2, "round-trip 1:1");
    }

    function test_roundTrip_4_1() public view {
        uint128 original = 1_000e6;
        uint256 inToken1 = h.toToken1Denominated(original, SQRT_PRICE_4_1);
        uint256 backTo0  = h.toToken0Denominated(uint128(inToken1), SQRT_PRICE_4_1);
        // Rounding tolerance scales with price ratio.
        assertApproxEqAbs(backTo0, original, 8, "round-trip 4:1");
    }

    // =========================================================================
    // F — isZeroSwap
    // =========================================================================

    function test_isZeroSwap_bothZero() public view {
        BalanceDelta delta = toBalanceDelta(int128(0), int128(0));
        assertTrue(h.isZeroSwap(delta));
    }

    function test_isZeroSwap_nonZeroAmount0() public view {
        BalanceDelta delta = toBalanceDelta(int128(1), int128(0));
        assertFalse(h.isZeroSwap(delta));
    }

    function test_isZeroSwap_nonZeroAmount1() public view {
        BalanceDelta delta = toBalanceDelta(int128(0), int128(-1));
        assertFalse(h.isZeroSwap(delta));
    }

    function test_isZeroSwap_normalSwap() public view {
        BalanceDelta delta = toBalanceDelta(int128(1_000e6), int128(-990e6));
        assertFalse(h.isZeroSwap(delta));
    }

    // =========================================================================
    // G — Fuzz
    // =========================================================================

    /// @notice extractInputAmount always returns the magnitude of the input leg,
    ///         regardless of sign.
    function testFuzz_extractInputAmount_magnitudeIsCorrect(
        int128 a0,
        int128 a1,
        bool   zeroForOne
    ) public view {
        BalanceDelta delta = toBalanceDelta(a0, a1);
        uint128 amt = h.extractInputAmount(delta, zeroForOne);

        int128 raw = zeroForOne ? a0 : a1;
        // Safe abs: widen to int256 before negating to handle type(int128).min.
        uint128 expected = raw >= 0
            ? uint128(raw)
            : uint128(uint256(-int256(raw)));
        assertEq(amt, expected);
    }

    /// @notice extractFeeAmounts.amount0 is always |delta.amount0()|,
    ///         and amount1 is always |delta.amount1()|, provided the delta
    ///         is not structurally invalid (both positive).
    function testFuzz_extractFeeAmounts_absoluteValues(
        int128 a0,
        int128 a1,
        bool   zeroForOne
    ) public view {
        // Skip the invalid case that triggers UnexpectedDelta.
        vm.assume(!(a0 > 0 && a1 > 0));

        BalanceDelta delta = toBalanceDelta(a0, a1);
        SwapParams memory params = makeParams(zeroForOne);

        FeeAccounting.SwapFeeAmounts memory sfa = h.extractFeeAmounts(delta, params);

        // Safe abs: widen to int256 before negating to handle type(int128).min.
        uint128 abs0 = a0 >= 0 ? uint128(a0) : uint128(uint256(-int256(a0)));
        uint128 abs1 = a1 >= 0 ? uint128(a1) : uint128(uint256(-int256(a1)));

        assertEq(sfa.amount0, abs0);
        assertEq(sfa.amount1, abs1);
        assertEq(sfa.zeroForOne, zeroForOne);
    }

    /// @notice toToken1Denominated is monotone: larger amount0 → larger amount1.
    function testFuzz_toToken1_monotone(
        uint64 amtA,
        uint64 amtB,
        uint96 sqrtPrice
    ) public view {
        // Non-zero sqrtPrice to avoid revert.
        vm.assume(sqrtPrice > 0);
        vm.assume(amtA < amtB);

        uint256 r1 = h.toToken1Denominated(uint128(amtA), uint160(sqrtPrice));
        uint256 r2 = h.toToken1Denominated(uint128(amtB), uint160(sqrtPrice));
        assertLe(r1, r2, "toToken1 must be monotone in amount0");
    }



    /// @notice isZeroSwap iff both legs are exactly zero.
    function testFuzz_isZeroSwap_iffBothZero(int128 a0, int128 a1) public view {
        BalanceDelta delta = toBalanceDelta(a0, a1);
        bool expected = (a0 == 0 && a1 == 0);
        assertEq(h.isZeroSwap(delta), expected);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {Test}   from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {AuthorizedCaller} from "../../src/libraries/AuthorizedCaller.sol";
import {RateOracle} from "../../src/core/RateOracle.sol";

/// @title RateOracleTest
/// @notice Unit and fuzz tests for RateOracle.
///
/// Test organisation
/// -----------------
///   Section A  — deployment & governance
///   Section B  — pool registration
///   Section C  — record(): slot write logic
///   Section D  — record(): in-place cumulative update
///   Section E  — getTWAP()
///   Section F  — getVolatility()
///   Section G  — ring buffer wrap-around
///   Section H  — access control
///   Section I  — fuzz

contract RateOracleTest is Test {

    // -------------------------------------------------------------------------
    // Fixtures
    // -------------------------------------------------------------------------

    RateOracle internal oracle;

    address internal constant OWNER = address(0xA110CE);
    address internal constant HOOK  = address(0xB00C);
    address internal constant ALICE = address(0xA11CE);

    PoolId internal POOL;

    uint256 internal constant WAD              = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint32  internal constant INTERVAL         = 4 hours;

    uint64  internal constant T0 = 1_700_000_000;

    function setUp() public {
        vm.warp(T0);
        oracle = new RateOracle(OWNER, HOOK);
        POOL   = PoolId.wrap(keccak256("ETH/USDC 0.05%"));

        vm.prank(OWNER);
        oracle.registerPool(POOL);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// Record an observation at the current block timestamp.
    function _record(uint128 fee, uint128 tvl) internal {
        vm.prank(HOOK);
        oracle.record(POOL, fee, tvl);
    }

    /// Warp forward by `delta` seconds then record.
    function _warpAndRecord(uint32 delta, uint128 fee, uint128 tvl) internal {
        vm.warp(block.timestamp + delta);
        _record(fee, tvl);
    }

    /// Write `n` evenly-spaced observations, each INTERVAL apart.
    /// fee and tvl are constant across all observations.
    function _fillObservations(uint16 n, uint128 fee, uint128 tvl) internal {
        for (uint16 i = 0; i < n; i++) {
            if (i > 0) vm.warp(block.timestamp + INTERVAL);
            _record(fee, tvl);
        }
    }

    // =========================================================================
    // A — deployment & governance
    // =========================================================================

    function test_deploy_ownerSet() public view {
        assertEq(oracle.owner(), OWNER);
    }

    function test_deploy_defaultInterval() public view {
        assertEq(oracle.minObservationInterval(), INTERVAL);
    }

    function test_deploy_defaultTwapWindow() public view {
        assertEq(oracle.twapWindowObservations(), 180);
    }

    function test_deploy_zeroOwnerReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableInvalidOwner.selector,
                address(0)
            )
        );
        new RateOracle(address(0), HOOK);
    }

    function test_setMinInterval_ownerCanSet() public {
        vm.prank(OWNER);
        oracle.setMinObservationInterval(1 hours);
        assertEq(oracle.minObservationInterval(), 1 hours);
    }

    function test_setTwapWindow_valid() public {
        vm.prank(OWNER);
        oracle.setTwapWindowObservations(90);
        assertEq(oracle.twapWindowObservations(), 90);
    }

    function test_setTwapWindow_tooSmallReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RateOracle.InvalidWindow.selector, 1));
        oracle.setTwapWindowObservations(1);
    }

    function test_setTwapWindow_tooLargeReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(RateOracle.InvalidWindow.selector, 360));
        oracle.setTwapWindowObservations(360);
    }

    // =========================================================================
    // B — pool registration
    // =========================================================================

    function test_registerPool_marksRegistered() public view {
        assertTrue(oracle.registered(PoolId.unwrap(POOL)));
    }

    function test_registerPool_duplicateReverts() public {
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(RateOracle.PoolAlreadyRegistered.selector, POOL)
        );
        oracle.registerPool(POOL);
    }

    function test_registerPool_nonOwnerReverts() public {
        PoolId other = PoolId.wrap(keccak256("X"));
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                ALICE
            )
        );
        oracle.registerPool(other);
    }

    // =========================================================================
    // C — record(): slot write logic
    // =========================================================================

    function test_record_firstObservation_setsFields() public {
        _record(100e18, 1000e18);

        RateOracle.Observation memory obs = oracle.latestObservation(POOL);
        assertEq(obs.timestamp,     uint32(T0));
        assertEq(obs.feeCumulative, 100e18);
        assertEq(obs.tvlAtTime,     1000e18);
        assertEq(oracle.observationCount(PoolId.unwrap(POOL)), 1);
    }

    function test_record_newSlotAfterInterval() public {
        _record(100e18, 1000e18);

        vm.warp(T0 + INTERVAL);
        _record(50e18, 1200e18);

        assertEq(oracle.observationCount(PoolId.unwrap(POOL)), 2);
        assertEq(oracle.observationIndex(PoolId.unwrap(POOL)), 1);

        RateOracle.Observation memory obs = oracle.latestObservation(POOL);
        assertEq(obs.timestamp,     uint32(T0 + INTERVAL));
        assertEq(obs.feeCumulative, 150e18); // 100 + 50
        assertEq(obs.tvlAtTime,     1200e18);
    }

    function test_record_inPlaceUpdateBeforeInterval() public {
        _record(100e18, 1000e18);

        // Just 1 second — within the interval.
        vm.warp(T0 + 1);
        _record(25e18, 1100e18);

        // Count must not increase.
        assertEq(oracle.observationCount(PoolId.unwrap(POOL)), 1);
        assertEq(oracle.observationIndex(PoolId.unwrap(POOL)), 0);

        RateOracle.Observation memory obs = oracle.latestObservation(POOL);
        // Cumulative updated, TVL updated, timestamp unchanged.
        assertEq(obs.feeCumulative, 125e18);
        assertEq(obs.tvlAtTime,     1100e18);
        assertEq(obs.timestamp,     uint32(T0));
    }

    function test_record_emitsEvent() public {
        vm.prank(HOOK);
        vm.expectEmit(true, false, false, false);
        emit RateOracle.ObservationRecorded(POOL, uint32(T0), 100e18, 1000e18, true);
        oracle.record(POOL, 100e18, 1000e18);
    }

    // =========================================================================
    // D — record(): cumulative accumulation
    // =========================================================================

    function test_record_feeCumulativeAccumulates() public {
        _record(100e18, 1000e18);
        _warpAndRecord(INTERVAL,   50e18, 1000e18);
        _warpAndRecord(INTERVAL,   75e18, 1000e18);

        RateOracle.Observation memory obs = oracle.latestObservation(POOL);
        assertEq(obs.feeCumulative, 225e18); // 100 + 50 + 75
    }

    function test_record_unregisteredPoolReverts() public {
        PoolId unknown = PoolId.wrap(keccak256("UNKNOWN"));
        vm.prank(HOOK);
        vm.expectRevert(
            abi.encodeWithSelector(RateOracle.PoolNotRegistered.selector, unknown)
        );
        oracle.record(unknown, 100e18, 1000e18);
    }

    // =========================================================================
    // E — getTWAP()
    // =========================================================================

    function test_getTWAP_insufficientObservationsReverts() public {
        _record(100e18, 1000e18); // only 1 observation

        vm.expectRevert(
            abi.encodeWithSelector(RateOracle.InsufficientObservations.selector, 1, 2)
        );
        oracle.getTWAP(POOL);
    }

    function test_getTWAP_twoObservations_basicMath() public {
        // Observation 0: t=T0, cumFee=0 (first write).
        _record(0, 1000e18);

        // Observation 1: t=T0+INTERVAL, cumFee=100e18.
        vm.warp(T0 + INTERVAL);
        _record(100e18, 1000e18);

        // twapWad = 100e18 × SECONDS_PER_YEAR × WAD / (1000e18 × INTERVAL)
        uint256 expected = (uint256(100e18) * SECONDS_PER_YEAR * WAD)
                         / (uint256(1000e18) * INTERVAL);

        uint256 twap = oracle.getTWAP(POOL);
        assertEq(twap, expected);
    }

    function test_getTWAP_constantFeeYield_returnsStableRate() public {
        // Write many observations with identical fee/TVL ratio.
        // Each interval earns 10e18 fees on 1000e18 TVL → 1% per interval.
        // Annualised: 1% × (SECONDS_PER_YEAR / INTERVAL).
        uint128 feePerInterval = 10e18;
        uint128 tvl            = 1000e18;

        // Set TWAP window to 10 observations for this test.
        vm.prank(OWNER);
        oracle.setTwapWindowObservations(10);

        _fillObservations(15, feePerInterval, tvl);

        uint256 twap = oracle.getTWAP(POOL);

        // Expected annualised rate: (10/1000) × (SECONDS_PER_YEAR / INTERVAL)
        uint256 expected = (uint256(feePerInterval) * SECONDS_PER_YEAR * WAD)
                         / (uint256(tvl) * uint256(INTERVAL));

        // Allow 1 wei rounding tolerance.
        assertApproxEqAbs(twap, expected, 1);
    }

    function test_getTWAP_higherFeesGiveHigherRate() public {
        // Pool A: 10 fee per interval. Pool B: 20 fee per interval.
        PoolId poolB = PoolId.wrap(keccak256("BTC/ETH 0.3%"));
        vm.prank(OWNER);
        oracle.registerPool(poolB);

        vm.prank(OWNER);
        oracle.setTwapWindowObservations(5);

        // Fill POOL with fee=10.
        for (uint16 i = 0; i < 5; i++) {
            if (i > 0) vm.warp(block.timestamp + INTERVAL);
            vm.prank(HOOK);
            oracle.record(POOL, 10e18, 1000e18);
            vm.prank(HOOK);
            oracle.record(poolB, 20e18, 1000e18);
        }

        assertGt(oracle.getTWAP(poolB), oracle.getTWAP(POOL),
            "higher fee pool must have higher TWAP");
    }

    // =========================================================================
    // F — getVolatility()
    // =========================================================================

    function test_getVolatility_insufficientObservationsReverts() public {
        _record(100e18, 1000e18);
        _warpAndRecord(INTERVAL, 50e18, 1000e18);
        // Only 2 observations — need 3.

        vm.expectRevert(
            abi.encodeWithSelector(RateOracle.InsufficientObservations.selector, 2, 3)
        );
        oracle.getVolatility(POOL);
    }

    function test_getVolatility_identicalSamples_zeroSigma() public {
        // All intervals have identical fee yields → σ = 0.
        vm.prank(OWNER);
        oracle.setTwapWindowObservations(5);

        _fillObservations(5, 10e18, 1000e18);

        uint256 sigma = oracle.getVolatility(POOL);
        assertEq(sigma, 0, "identical samples must produce zero volatility");
    }

    function test_getVolatility_varyingFees_nonZeroSigma() public {
        vm.prank(OWNER);
        oracle.setTwapWindowObservations(5);

        // Alternate between high and low fees to create non-zero variance.
        for (uint16 i = 0; i < 5; i++) {
            if (i > 0) vm.warp(block.timestamp + INTERVAL);
            uint128 fee = i % 2 == 0 ? 10e18 : 50e18;
            _record(fee, 1000e18);
        }

        uint256 sigma = oracle.getVolatility(POOL);
        assertTrue(sigma > 0, "alternating fees must produce non-zero sigma");
    }

    function test_getVolatility_higherVariance_higherSigma() public {
        // Two pools: low variance vs high variance fees.
        PoolId poolB = PoolId.wrap(keccak256("HIGH_VOL"));
        vm.prank(OWNER);
        oracle.registerPool(poolB);

        vm.prank(OWNER);
        oracle.setTwapWindowObservations(6);

        uint128[6] memory lowFees  = [uint128(10e18), 11e18, 10e18, 11e18, 10e18, 11e18];
        uint128[6] memory highFees = [uint128(5e18),  50e18, 5e18,  50e18, 5e18,  50e18];

        for (uint16 i = 0; i < 6; i++) {
            if (i > 0) vm.warp(block.timestamp + INTERVAL);
            vm.prank(HOOK); oracle.record(POOL,  lowFees[i],  1000e18);
            vm.prank(HOOK); oracle.record(poolB, highFees[i], 1000e18);
        }

        assertGt(
            oracle.getVolatility(poolB),
            oracle.getVolatility(POOL),
            "higher variance pool must have higher sigma"
        );
    }

    // =========================================================================
    // G — ring buffer wrap-around
    // =========================================================================

    function test_ringBuffer_wrapsWithoutRevert() public {
        // Write more than BUFFER_SIZE (360) observations and confirm no revert
        // and the index wraps correctly.
        vm.prank(OWNER);
        oracle.setMinObservationInterval(0); // allow every-second writes

        for (uint256 i = 0; i < 365; i++) {
            vm.warp(block.timestamp + 1);
            _record(10e18, 1000e18);
        }

        // Count is capped at BUFFER_SIZE.
        assertEq(oracle.observationCount(PoolId.unwrap(POOL)), 360);
        // Index has wrapped: 365 % 360 = 5.
        assertEq(oracle.observationIndex(PoolId.unwrap(POOL)), 4);
    }

    function test_ringBuffer_twapStillWorksAfterWrap() public {
        vm.prank(OWNER);
        oracle.setMinObservationInterval(0);
        vm.prank(OWNER);
        oracle.setTwapWindowObservations(10);

        for (uint256 i = 0; i < 370; i++) {
            vm.warp(block.timestamp + 1);
            _record(10e18, 1000e18);
        }

        // Should not revert and should return a non-zero value.
        uint256 twap = oracle.getTWAP(POOL);
        assertTrue(twap > 0);
    }

    // =========================================================================
    // H — access control
    // =========================================================================

    function test_record_unauthorizedReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(AuthorizedCaller.NotAuthorized.selector);
        oracle.record(POOL, 100e18, 1000e18);
    }

    function test_getTWAP_unregisteredPoolReverts() public {
        PoolId unknown = PoolId.wrap(keccak256("UNKNOWN2"));
        vm.expectRevert(
            abi.encodeWithSelector(RateOracle.PoolNotRegistered.selector, unknown)
        );
        oracle.getTWAP(unknown);
    }

    function test_getVolatility_unregisteredPoolReverts() public {
        PoolId unknown = PoolId.wrap(keccak256("UNKNOWN3"));
        vm.expectRevert(
            abi.encodeWithSelector(RateOracle.PoolNotRegistered.selector, unknown)
        );
        oracle.getVolatility(unknown);
    }

    // =========================================================================
    // I — fuzz
    // =========================================================================

    /// getTWAP is monotonically non-decreasing in fee income (same TVL, more fees).
    function testFuzz_twap_monotonicInFees(uint64 fee1, uint64 fee2) public {
        vm.assume(fee1 > 0 && fee2 > 0);
        vm.assume(fee2 >= fee1);

        PoolId poolA = PoolId.wrap(keccak256("A"));
        PoolId poolB = PoolId.wrap(keccak256("B"));
        vm.prank(OWNER); oracle.registerPool(poolA);
        vm.prank(OWNER); oracle.registerPool(poolB);
        vm.prank(OWNER); oracle.setTwapWindowObservations(3);

        uint128 tvl = 1_000_000e18;
        for (uint16 i = 0; i < 3; i++) {
            if (i > 0) vm.warp(block.timestamp + INTERVAL);
            vm.prank(HOOK); oracle.record(poolA, uint128(fee1), tvl);
            vm.prank(HOOK); oracle.record(poolB, uint128(fee2), tvl);
        }

        assertGe(oracle.getTWAP(poolB), oracle.getTWAP(poolA),
            "higher fees must produce >= TWAP");
    }

    /// TWAP is monotonically non-increasing in TVL (same fees, higher TVL).
    function testFuzz_twap_monotonicInTVL(uint64 tvl1, uint64 tvl2) public {
        vm.assume(tvl1 > 0 && tvl2 > 0 && tvl2 >= tvl1);

        PoolId poolA = PoolId.wrap(keccak256("TVL_A"));
        PoolId poolB = PoolId.wrap(keccak256("TVL_B"));
        vm.prank(OWNER); oracle.registerPool(poolA);
        vm.prank(OWNER); oracle.registerPool(poolB);
        vm.prank(OWNER); oracle.setTwapWindowObservations(3);

        uint128 fee = 100e18;
        for (uint16 i = 0; i < 3; i++) {
            if (i > 0) vm.warp(block.timestamp + INTERVAL);
            vm.prank(HOOK); oracle.record(poolA, fee, uint128(tvl1));
            vm.prank(HOOK); oracle.record(poolB, fee, uint128(tvl2));
        }

        assertGe(oracle.getTWAP(poolA), oracle.getTWAP(poolB),
            "lower TVL must produce >= TWAP (same fees)");
    }
}

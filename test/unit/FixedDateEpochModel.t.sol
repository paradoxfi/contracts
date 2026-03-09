// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FixedDateEpochModel} from "../../src/epochs/FixedDateEpochModel.sol";
import {IEpochModel} from "../../src/epochs/IEpochModel.sol";

/// @title FixedDateEpochModelTest
/// @notice Unit tests for FixedDateEpochModel and implicit coverage of IEpochModel.
///
/// Test organisation
/// -----------------
///   Section A — validateParams()
///   Section B — computeMaturity()
///   Section C — shouldAutoRoll() + modelType() + paramsDescription()
///   Section D — encodeParams() / externalDecode() round-trip
///   Section E — Fuzz
contract FixedDateEpochModelTest is Test {
    FixedDateEpochModel internal model;

    // Canonical durations used throughout tests
    uint32 internal constant D_1DAY   = 1 days;
    uint32 internal constant D_7DAY   = 7 days;
    uint32 internal constant D_30DAY  = 30 days;
    uint32 internal constant D_90DAY  = 90 days;
    uint32 internal constant D_365DAY = 365 days;
    uint32 internal constant D_730DAY = 730 days; // MAX

    function setUp() public {
        model = new FixedDateEpochModel();
        // Pin block.timestamp to a realistic value so "maturity in the past"
        // checks behave predictably.
        vm.warp(1_700_000_000); // ~Nov 2023
    }

    // =========================================================================
    // A — validateParams
    // =========================================================================

    function test_validateParams_minDuration() public view {
        bytes memory p = model.encodeParams(D_1DAY);
        assertTrue(model.validateParams(p));
    }

    function test_validateParams_maxDuration() public view {
        bytes memory p = model.encodeParams(D_730DAY);
        assertTrue(model.validateParams(p));
    }

    function test_validateParams_midRange() public view {
        bytes memory p = model.encodeParams(D_90DAY);
        assertTrue(model.validateParams(p));
    }

    function test_validateParams_zeroDuration() public view {
        bytes memory p = abi.encode(FixedDateEpochModel.Params({duration: 0}));
        assertFalse(model.validateParams(p));
    }

    function test_validateParams_belowMin() public view {
        // 1 day - 1 second
        bytes memory p = abi.encode(FixedDateEpochModel.Params({duration: D_1DAY - 1}));
        assertFalse(model.validateParams(p));
    }

    function test_validateParams_aboveMax() public view {
        bytes memory p = abi.encode(FixedDateEpochModel.Params({duration: D_730DAY + 1}));
        assertFalse(model.validateParams(p));
    }

    function test_validateParams_emptyCalldata() public view {
        assertFalse(model.validateParams(""));
    }

    function test_validateParams_malformedCalldata_tooShort() public view {
        // 16 bytes — not enough for a uint32 decode
        bytes memory bad = hex"deadbeefdeadbeefdeadbeefdeadbeef";
        assertFalse(model.validateParams(bad));
    }

    // =========================================================================
    // B — computeMaturity
    // =========================================================================

    function test_computeMaturity_basic() public view {
        uint64 start = uint64(block.timestamp);
        bytes memory p = model.encodeParams(D_90DAY);

        uint64 maturity = model.computeMaturity(start, p);

        assertEq(maturity, start + D_90DAY);
    }

    function test_computeMaturity_allCanonicalDurations() public view {
        uint64 start = uint64(block.timestamp);
        uint32[5] memory durations = [D_1DAY, D_7DAY, D_30DAY, D_90DAY, D_365DAY];

        for (uint256 i; i < durations.length; i++) {
            bytes memory p = model.encodeParams(durations[i]);
            uint64 maturity = model.computeMaturity(start, p);
            assertEq(maturity, start + uint64(durations[i]), "duration mismatch");
            assertGt(maturity, uint64(block.timestamp), "maturity not in future");
        }
    }

    function test_computeMaturity_maxDuration() public view {
        uint64 start = uint64(block.timestamp);
        bytes memory p = model.encodeParams(D_730DAY);

        uint64 maturity = model.computeMaturity(start, p);
        assertEq(maturity, start + D_730DAY);
    }

    function test_computeMaturity_revertsOnInvalidParams() public {
        uint64 start = uint64(block.timestamp);
        // duration = 0 → _decode reverts with InvalidModelParams
        bytes memory bad = abi.encode(FixedDateEpochModel.Params({duration: 0}));

        vm.expectRevert(IEpochModel.InvalidModelParams.selector);
        model.computeMaturity(start, bad);
    }

    function test_computeMaturity_revertsWhenMaturityInPast() public {
        // Set a start time far enough in the past that even a 365-day epoch
        // would have already matured.
        uint64 ancientStart = uint64(block.timestamp) - 400 days;
        bytes memory p = model.encodeParams(D_365DAY);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEpochModel.InvalidMaturity.selector,
                ancientStart,
                ancientStart + D_365DAY
            )
        );
        model.computeMaturity(ancientStart, p);
    }

    function test_computeMaturity_revertsOnZeroStartTime() public {
        // startTime = 0 is nonsensical; maturity (= duration) will be in the past.
        bytes memory p = model.encodeParams(D_90DAY);

        vm.expectRevert();
        model.computeMaturity(0, p);
    }

    // =========================================================================
    // C — shouldAutoRoll, modelType, paramsDescription
    // =========================================================================

    function test_shouldAutoRoll_isFalse() public view {
        assertFalse(model.shouldAutoRoll());
    }

    function test_modelType() public view {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 expected = bytes32("FIXED_DATE");
        assertEq(model.modelType(), expected);
    }

    function test_paramsDescription_nonEmpty() public view {
        string memory desc = model.paramsDescription();
        assertGt(bytes(desc).length, 0);
    }

    // =========================================================================
    // D — encodeParams / externalDecode round-trip
    // =========================================================================

    function test_encodeDecodeRoundTrip_30days() public view {
        bytes memory encoded = model.encodeParams(D_30DAY);
        FixedDateEpochModel.Params memory decoded = model.externalDecode(encoded);
        assertEq(decoded.duration, D_30DAY);
    }

    function test_encodeDecodeRoundTrip_allCanonical() public view {
        uint32[5] memory durations = [D_1DAY, D_7DAY, D_30DAY, D_90DAY, D_365DAY];
        for (uint256 i; i < durations.length; i++) {
            bytes memory encoded = model.encodeParams(durations[i]);
            FixedDateEpochModel.Params memory decoded = model.externalDecode(encoded);
            assertEq(decoded.duration, durations[i]);
        }
    }

    function test_externalDecode_revertsOnBadParams() public {
        bytes memory bad = abi.encode(FixedDateEpochModel.Params({duration: 0}));
        vm.expectRevert(IEpochModel.InvalidModelParams.selector);
        model.externalDecode(bad);
    }

    // =========================================================================
    // E — Fuzz
    // =========================================================================

    /// @notice Any duration in [MIN, MAX] should produce a maturity = start + duration.
    function testFuzz_computeMaturity_validDuration(uint32 duration) public view {
        duration = uint32(
            bound(uint256(duration), model.MIN_DURATION(), model.MAX_DURATION())
        );

        uint64 start = uint64(block.timestamp);
        bytes memory p = model.encodeParams(duration);
        uint64 maturity = model.computeMaturity(start, p);

        assertEq(maturity, start + uint64(duration));
        assertGt(maturity, uint64(block.timestamp));
    }

    /// @notice Any duration outside [MIN, MAX] should fail validateParams.
    function testFuzz_validateParams_outOfRange(uint32 duration) public view {
        vm.assume(
            duration < model.MIN_DURATION() || duration > model.MAX_DURATION()
        );
        bytes memory p = abi.encode(FixedDateEpochModel.Params({duration: duration}));
        assertFalse(model.validateParams(p));
    }

    /// @notice encodeParams/externalDecode round-trip holds for all valid durations.
    function testFuzz_encodeDecodeRoundTrip(uint32 duration) public view {
        duration = uint32(
            bound(uint256(duration), model.MIN_DURATION(), model.MAX_DURATION())
        );
        bytes memory encoded = model.encodeParams(duration);
        FixedDateEpochModel.Params memory decoded = model.externalDecode(encoded);
        assertEq(decoded.duration, duration);
    }

    /// @notice computeMaturity with a sufficiently old startTime should revert
    ///         for any valid duration (maturity already passed).
    function testFuzz_computeMaturity_pastStartReverts(uint32 duration) public {
        duration = uint32(
            bound(uint256(duration), model.MIN_DURATION(), model.MAX_DURATION())
        );

        // Use a startTime that guarantees maturity is in the past:
        // startTime = now - duration - 1
        uint64 start = uint64(block.timestamp) - uint64(duration) - 1;
        bytes memory p = model.encodeParams(duration);

        vm.expectRevert();
        model.computeMaturity(start, p);
    }
}

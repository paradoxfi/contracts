// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {PositionId} from "../../src/libraries/PositionId.sol";

// ---------------------------------------------------------------------------
// Harness — exposes internal library functions as external calls so Foundry
// can invoke them from the test contract.
// ---------------------------------------------------------------------------
contract PositionIdHarness {
    function encode(uint64 cid, PoolId pid, uint32 cnt) external view returns (uint256) {
        return PositionId.encode(cid, pid, cnt);
    }

    function encodeCurrentChain(PoolId pid, uint32 cnt) external view returns (uint256) {
        return PositionId.encode(pid, cnt);
    }

    function counter(uint256 id) external pure returns (uint32) {
        return PositionId.counter(id);
    }

    function poolIdTruncated(uint256 id) external pure returns (uint160) {
        return PositionId.poolIdTruncated(id);
    }

    function chainId(uint256 id) external pure returns (uint64) {
        return PositionId.chainId(id);
    }

    function decode(uint256 id) external view returns (uint64, uint160, uint32) {
        return PositionId.decode(id);
    }

    function validateChain(uint256 id) external view {
        PositionId.validateChain(id);
    }

    function isCurrentChain(uint256 id) external view returns (bool) {
        return PositionId.isCurrentChain(id);
    }

    function isNull(uint256 id) external pure returns (bool) {
        return PositionId.isNull(id);
    }

    function nextCounter(uint32 current) external pure returns (uint32) {
        return PositionId.nextCounter(current);
    }
}

// ---------------------------------------------------------------------------
// Test contract
// ---------------------------------------------------------------------------

/// @title PositionIdTest
///
/// Test organisation
/// -----------------
///   Section A — encode / decode round-trip
///   Section B — individual field extractors
///   Section C — chain ID validation
///   Section D — NULL sentinel + isNull
///   Section E — nextCounter
///   Section F — ZeroCounter guard
///   Section G — bit-layout regression (golden values)
///   Section H — cross-library layout parity with EpochId
///   Section I — Fuzz
contract PositionIdTest is Test {
    PositionIdHarness internal h;

    uint64  internal constant CHAIN   = 1;
    uint32  internal constant CTR     = 1;
    PoolId  internal POOL;

    function setUp() public {
        h = new PositionIdHarness();
        vm.chainId(CHAIN);
        POOL = PoolId.wrap(keccak256("ETH/USDC 0.05%"));
    }

    // =========================================================================
    // A — encode / decode round-trip
    // =========================================================================

    function test_roundTrip_basic() public view {
        uint256 id = h.encode(CHAIN, POOL, CTR);

        (uint64 gotChain, uint160 gotPool, uint32 gotCtr) = h.decode(id);

        assertEq(gotChain, CHAIN);
        assertEq(gotPool,  uint160(uint256(PoolId.unwrap(POOL))));
        assertEq(gotCtr,   CTR);
    }

    function test_roundTrip_currentChainOverload() public view {
        uint256 id = h.encodeCurrentChain(POOL, CTR);

        (uint64 gotChain, uint160 gotPool, uint32 gotCtr) = h.decode(id);

        assertEq(gotChain, CHAIN);
        assertEq(gotPool,  uint160(uint256(PoolId.unwrap(POOL))));
        assertEq(gotCtr,   CTR);
    }

    function test_roundTrip_counterOne() public view {
        uint256 id = h.encode(CHAIN, POOL, 1);
        assertEq(h.counter(id), 1);
    }

    function test_roundTrip_counterMax() public view {
        uint256 id = h.encode(CHAIN, POOL, type(uint32).max);
        assertEq(h.counter(id), type(uint32).max);
    }

    // =========================================================================
    // B — individual field extractors
    // =========================================================================

    function test_counter_isolatedBits() public view {
        uint32 want = 42;
        uint256 id  = h.encode(CHAIN, POOL, want);
        assertEq(h.counter(id), want);
    }

    function test_poolIdTruncated_correctBits() public view {
        uint256 id  = h.encode(CHAIN, POOL, CTR);
        uint160 want = uint160(uint256(PoolId.unwrap(POOL)));
        assertEq(h.poolIdTruncated(id), want);
    }

    function test_chainId_correctBits() public view {
        uint256 id = h.encode(CHAIN, POOL, CTR);
        assertEq(h.chainId(id), CHAIN);
    }

    function test_distinctPools_distinctIds() public view {
        PoolId poolB = PoolId.wrap(keccak256("BTC/ETH 0.3%"));
        uint256 idA  = h.encode(CHAIN, POOL,  CTR);
        uint256 idB  = h.encode(CHAIN, poolB, CTR);
        assertTrue(idA != idB, "different pools must produce different ids");
    }

    function test_distinctCounters_distinctIds() public view {
        uint256 id1 = h.encode(CHAIN, POOL, 1);
        uint256 id2 = h.encode(CHAIN, POOL, 2);
        assertTrue(id1 != id2, "different counters must produce different ids");
    }

    function test_fieldExtractors_doNotBleedIntoEachOther() public {
        // All fields at their maximum values.
        uint64  maxChain = type(uint64).max;
        uint32  maxCtr   = type(uint32).max;
        PoolId  maxPool  = PoolId.wrap(bytes32(type(uint256).max));

        vm.chainId(maxChain);

        uint256 id = h.encode(maxChain, maxPool, maxCtr);

        assertEq(h.chainId(id),         maxChain);
        assertEq(h.poolIdTruncated(id), type(uint160).max);
        assertEq(h.counter(id),         maxCtr);
    }

    // =========================================================================
    // C — chain ID validation
    // =========================================================================

    function test_decode_revertsOnWrongChain() public {
        uint256 id = h.encode(CHAIN, POOL, CTR);
        vm.chainId(137);

        vm.expectRevert(
            abi.encodeWithSelector(PositionId.WrongChain.selector, uint64(1), uint64(137))
        );
        h.decode(id);
    }

    function test_validateChain_passesOnCorrectChain() public view {
        uint256 id = h.encode(CHAIN, POOL, CTR);
        h.validateChain(id); // must not revert
    }

    function test_validateChain_revertsOnWrongChain() public {
        uint256 id = h.encode(CHAIN, POOL, CTR);
        vm.chainId(10);

        vm.expectRevert(
            abi.encodeWithSelector(PositionId.WrongChain.selector, uint64(1), uint64(10))
        );
        h.validateChain(id);
    }

    function test_isCurrentChain_trueOnMatch() public view {
        uint256 id = h.encode(CHAIN, POOL, CTR);
        assertTrue(h.isCurrentChain(id));
    }

    function test_isCurrentChain_falseOnMismatch() public {
        uint256 id = h.encode(CHAIN, POOL, CTR);
        vm.chainId(56);
        assertFalse(h.isCurrentChain(id));
    }

    function test_encode_revertsOnChainIdMismatch() public {
        vm.expectRevert(
            abi.encodeWithSelector(PositionId.ChainIdMismatch.selector, uint64(99), uint64(1))
        );
        h.encode(99, POOL, CTR);
    }

    // =========================================================================
    // D — NULL sentinel + isNull
    // =========================================================================

    function test_null_isZero() public pure {
        assertEq(PositionId.NULL, 0);
    }

    function test_realId_neverNull() public view {
        uint256 id = h.encode(CHAIN, POOL, 1);
        assertFalse(h.isNull(id));
        assertTrue(id != PositionId.NULL);
    }

    function test_isNull_trueForZero() public view {
        assertTrue(h.isNull(0));
    }

    function test_isNull_falseForValidId() public view {
        uint256 id = h.encode(CHAIN, POOL, CTR);
        assertFalse(h.isNull(id));
    }

    // =========================================================================
    // E — nextCounter
    // =========================================================================

    function test_nextCounter_fromZero() public view {
        assertEq(h.nextCounter(0), 1);
    }

    function test_nextCounter_increments() public view {
        assertEq(h.nextCounter(5),   6);
        assertEq(h.nextCounter(100), 101);
    }

    function test_nextCounter_atMaxMinusOne() public view {
        assertEq(h.nextCounter(type(uint32).max - 1), type(uint32).max);
    }

    function test_nextCounter_revertsAtMax() public {
        vm.expectRevert("PositionId: counter overflow");
        h.nextCounter(type(uint32).max);
    }

    /// @notice nextCounter(n) followed by encode must produce a non-null id.
    function test_nextCounter_producesValidId() public view {
        uint32  next = h.nextCounter(0);
        uint256 id   = h.encode(CHAIN, POOL, next);
        assertFalse(h.isNull(id));
        assertEq(h.counter(id), 1);
    }

    // =========================================================================
    // F — ZeroCounter guard
    // =========================================================================

    function test_encode_revertsOnZeroCounter_explicitChain() public {
        vm.expectRevert(PositionId.ZeroCounter.selector);
        h.encode(CHAIN, POOL, 0);
    }

    function test_encode_revertsOnZeroCounter_implicitChain() public {
        vm.expectRevert(PositionId.ZeroCounter.selector);
        h.encodeCurrentChain(POOL, 0);
    }

    // =========================================================================
    // G — bit-layout regression (golden values)
    // =========================================================================

    /// @notice Hard-coded golden test — any change to the bit layout will break
    ///         this immediately and require an explicit, reviewable update.
    ///
    /// Layout:
    ///   chainId = 1  → bit 192 set  →  1 << 192
    ///   poolId  = 1  → bit  32 set  →  1 << 32
    ///   counter = 1  → bit   0 set  →  1
    function test_goldenValue_layoutRegression() public view {
        PoolId trivialPool = PoolId.wrap(bytes32(uint256(1)));
        uint256 id = h.encode(CHAIN, trivialPool, 1);

        uint256 expected = (uint256(1) << 192) | (uint256(1) << 32) | uint256(1);
        assertEq(id, expected, "bit layout regression");
    }

    function test_goldenValue_counterOnly() public view {
        PoolId zeroPool = PoolId.wrap(bytes32(0));
        uint256 id = h.encode(CHAIN, zeroPool, 3);

        // chainId = 1 << 192, poolId = 0, counter = 3
        uint256 expected = (uint256(1) << 192) | uint256(3);
        assertEq(id, expected, "counter-only bits");
    }

    // =========================================================================
    // H — cross-library layout parity with EpochId
    // =========================================================================

    /// @notice The pool field occupies exactly bits [191:32] in both EpochId
    ///         and PositionId. Verify by comparing raw shifts against the same
    ///         pool input so that a PoolId comparison tool can treat both token
    ///         types identically.
    function test_poolFieldParity_sameShiftAsEpochId() public view {
        // Extract the pool field from a PositionId.
        uint256 posId = h.encode(CHAIN, POOL, 1);

        // Manually reproduce EpochId's extraction (POOL_ID_SHIFT = 32).
        uint160 fromPosId = uint160((posId >> 32) & type(uint160).max);

        // Should equal the lower 160 bits of the PoolId.
        uint160 expected = uint160(uint256(PoolId.unwrap(POOL)));
        assertEq(fromPosId, expected, "pool field shift parity with EpochId");
    }

    /// @notice chainId field occupies bits [255:192] in both libraries.
    function test_chainFieldParity_sameShiftAsEpochId() public view {
        uint256 posId = h.encode(CHAIN, POOL, 1);
        uint64  fromPosId = uint64((posId >> 192) & type(uint64).max);
        assertEq(fromPosId, CHAIN, "chainId field shift parity with EpochId");
    }

    // =========================================================================
    // I — Fuzz
    // =========================================================================

    /// @notice encode → decode round-trip holds for all (poolId, counter) pairs.
    function testFuzz_roundTrip(bytes32 rawPoolId, uint32 cnt) public view {
        vm.assume(cnt > 0);

        PoolId pid = PoolId.wrap(rawPoolId);
        uint256 id = h.encode(CHAIN, pid, cnt);

        assertEq(h.chainId(id),         CHAIN);
        assertEq(h.poolIdTruncated(id), uint160(uint256(rawPoolId)));
        assertEq(h.counter(id),         cnt);
    }

    /// @notice Field extractors return distinct values when truncated pool IDs
    ///         or counters differ. Guards against mask/shift bleed.
    ///
    /// Uses truncated pool IDs (lower 160 bits) as the comparison basis —
    /// identical to the fix applied in EpochIdTest — because PoolId truncation
    /// is intentional and does not constitute a bug.
    function testFuzz_fieldIndependence(
        bytes32 rawPoolA,
        bytes32 rawPoolB,
        uint32  cntA,
        uint32  cntB
    ) public view {
        vm.assume(cntA > 0 && cntB > 0);

        uint160 truncA = uint160(uint256(rawPoolA));
        uint160 truncB = uint160(uint256(rawPoolB));

        // Need at least one field to differ after truncation.
        vm.assume(truncA != truncB || cntA != cntB);

        PoolId pidA = PoolId.wrap(rawPoolA);
        PoolId pidB = PoolId.wrap(rawPoolB);

        uint256 idA = h.encode(CHAIN, pidA, cntA);
        uint256 idB = h.encode(CHAIN, pidB, cntB);

        if (truncA != truncB) {
            assertTrue(
                h.poolIdTruncated(idA) != h.poolIdTruncated(idB),
                "distinct truncated poolIds must decode distinctly"
            );
        }

        if (cntA != cntB) {
            assertTrue(
                h.counter(idA) != h.counter(idB),
                "distinct counters must decode distinctly"
            );
        }
    }

    /// @notice Any counter in [1, uint32.max] encodes and survives a NULL check.
    function testFuzz_nonNullForAllValidCounters(uint32 cnt) public view {
        vm.assume(cnt > 0);
        uint256 id = h.encode(CHAIN, POOL, cnt);
        assertFalse(h.isNull(id));
    }

    /// @notice nextCounter is strictly monotone and never returns 0.
    function testFuzz_nextCounter_strictlyMonotone(uint32 current) public view {
        vm.assume(current < type(uint32).max);
        uint32 next = h.nextCounter(current);
        assertGt(next, current);
        assertGt(next, 0);
    }

    /// @notice isCurrentChain returns false for any id whose embedded chainId
    ///         differs from the current block.chainid.
    function testFuzz_isCurrentChain_wrongChain(uint64 otherChain) public {
        vm.assume(otherChain != CHAIN && otherChain != 0);
        vm.chainId(otherChain);

        // Build an id that has CHAIN (1) in the upper bits.
        uint256 id = (uint256(CHAIN) << 192) | uint256(CTR);
        assertFalse(h.isCurrentChain(id));
    }
}

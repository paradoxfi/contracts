// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {EpochId} from "../../src/libraries/EpochId.sol";

/// @title EpochIdTest
/// @notice Unit + fuzz tests for the EpochId library.
///
/// Test organisation
/// -----------------
///   Section A — encode / decode round-trip
///   Section B — individual field extractors
///   Section C — chain ID validation
///   Section D — NULL sentinel
///   Section E — bit-layout regression (golden values)
///   Section F — Fuzz
///
/// Harness
/// -------
/// Foundry cannot call internal library functions directly from a test
/// contract. We wrap every library function in a thin external harness so
/// tests remain in Solidity without any vm.ffi chicanery.
contract EpochIdHarness {
    function encode(uint64 cid, PoolId pid, uint32 idx) external view returns (uint256) {
        return EpochId.encode(cid, pid, idx);
    }

    function encodeCurrentChain(PoolId pid, uint32 idx) external view returns (uint256) {
        return EpochId.encode(pid, idx);
    }

    function epochIndex(uint256 id) external pure returns (uint32) {
        return EpochId.epochIndex(id);
    }

    function poolIdTruncated(uint256 id) external pure returns (uint160) {
        return EpochId.poolIdTruncated(id);
    }

    function chainId(uint256 id) external pure returns (uint64) {
        return EpochId.chainId(id);
    }

    function decode(uint256 id) external view returns (uint64, uint160, uint32) {
        return EpochId.decode(id);
    }

    function validateChain(uint256 id) external view {
        EpochId.validateChain(id);
    }

    function isCurrentChain(uint256 id) external view returns (bool) {
        return EpochId.isCurrentChain(id);
    }
}

contract EpochIdTest is Test {
    EpochIdHarness internal h;

    // Fixture values
    uint64  internal constant CHAIN   = 1;        // mainnet
    uint32  internal constant IDX     = 7;
    // Construct a PoolId from a known bytes32 value so tests are deterministic.
    PoolId  internal pool;

    function setUp() public {
        h = new EpochIdHarness();
        vm.chainId(CHAIN);
        pool = PoolId.wrap(keccak256("ETH/USDC 0.05%"));
    }

    // =========================================================================
    // A — encode / decode round-trip
    // =========================================================================

    function test_roundTrip_basic() public view {
        uint256 id = h.encode(CHAIN, pool, IDX);

        (uint64 gotChain, uint160 gotPool, uint32 gotIdx) = h.decode(id);

        assertEq(gotChain, CHAIN);
        assertEq(gotPool,  uint160(uint256(PoolId.unwrap(pool))));
        assertEq(gotIdx,   IDX);
    }

    function test_roundTrip_currentChainOverload() public view {
        uint256 id = h.encodeCurrentChain(pool, IDX);

        (uint64 gotChain, uint160 gotPool, uint32 gotIdx) = h.decode(id);

        assertEq(gotChain, CHAIN);
        assertEq(gotPool,  uint160(uint256(PoolId.unwrap(pool))));
        assertEq(gotIdx,   IDX);
    }

    function test_roundTrip_epochIndexZero() public view {
        uint256 id = h.encode(CHAIN, pool, 0);
        assertEq(h.epochIndex(id), 0);
    }

    function test_roundTrip_epochIndexMax() public view {
        uint256 id = h.encode(CHAIN, pool, type(uint32).max);
        assertEq(h.epochIndex(id), type(uint32).max);
    }

    // =========================================================================
    // B — individual field extractors
    // =========================================================================

    function test_epochIndex_isolatedBits() public view {
        // Encode with a specific index, confirm extractor returns it exactly.
        uint32 want = 42;
        uint256 id = h.encode(CHAIN, pool, want);
        assertEq(h.epochIndex(id), want);
    }

    function test_poolIdTruncated_correctBits() public view {
        uint256 id = h.encode(CHAIN, pool, IDX);
        uint160 want = uint160(uint256(PoolId.unwrap(pool)));
        assertEq(h.poolIdTruncated(id), want);
    }

    function test_chainId_correctBits() public view {
        uint256 id = h.encode(CHAIN, pool, IDX);
        assertEq(h.chainId(id), CHAIN);
    }

    function test_distinctPools_distinctIds() public view {
        PoolId poolB = PoolId.wrap(keccak256("BTC/ETH 0.3%"));
        uint256 idA = h.encode(CHAIN, pool,  0);
        uint256 idB = h.encode(CHAIN, poolB, 0);
        assertTrue(idA != idB, "different pools must produce different ids");
    }

    function test_distinctEpochs_distinctIds() public view {
        uint256 id0 = h.encode(CHAIN, pool, 0);
        uint256 id1 = h.encode(CHAIN, pool, 1);
        assertTrue(id0 != id1, "different epoch indices must produce different ids");
    }

    function test_fieldExtractors_doNotBleedIntoEachOther() public {
        // Use maximum values in all three fields to expose any mask overflow.
        uint64  maxChain = type(uint64).max;
        uint32  maxIdx   = type(uint32).max;
        PoolId  maxPool  = PoolId.wrap(bytes32(type(uint256).max));

        vm.chainId(maxChain);

        uint256 id = h.encode(maxChain, maxPool, maxIdx);

        assertEq(h.chainId(id),         maxChain);
        assertEq(h.poolIdTruncated(id), type(uint160).max);
        assertEq(h.epochIndex(id),      maxIdx);
    }

    // =========================================================================
    // C — chain ID validation
    // =========================================================================

    function test_decode_revertsOnWrongChain() public {
        // Encode on mainnet (chain 1) then switch to chain 137 (Polygon).
        uint256 id = h.encode(CHAIN, pool, IDX);
        vm.chainId(137);

        vm.expectRevert(
            abi.encodeWithSelector(EpochId.WrongChain.selector, uint64(1), uint64(137))
        );
        h.decode(id);
    }

    function test_validateChain_passesOnCorrectChain() public view {
        uint256 id = h.encode(CHAIN, pool, IDX);
        // Should not revert.
        h.validateChain(id);
    }

    function test_validateChain_revertsOnWrongChain() public {
        uint256 id = h.encode(CHAIN, pool, IDX);
        vm.chainId(10); // Optimism

        vm.expectRevert(
            abi.encodeWithSelector(EpochId.WrongChain.selector, uint64(1), uint64(10))
        );
        h.validateChain(id);
    }

    function test_isCurrentChain_trueOnMatch() public view {
        uint256 id = h.encode(CHAIN, pool, IDX);
        assertTrue(h.isCurrentChain(id));
    }

    function test_isCurrentChain_falseOnMismatch() public {
        uint256 id = h.encode(CHAIN, pool, IDX);
        vm.chainId(56); // BSC

        assertFalse(h.isCurrentChain(id));
    }

    function test_encode_revertsWhenChainIdMismatch() public {
        // Pass chain 99 but block.chainid is 1.
        vm.expectRevert(
            abi.encodeWithSelector(EpochId.ChainIdMismatch.selector, uint64(99), uint64(1))
        );
        h.encode(99, pool, IDX);
    }

    // =========================================================================
    // D — NULL sentinel
    // =========================================================================

    function test_null_isZero() public pure {
        assertEq(EpochId.NULL, 0);
    }

    function test_realId_neverNull() public view {
        // Any valid encode() on a live chain (chainId ≥ 1) must be non-zero
        // because the chain ID is embedded in the upper bits.
        uint256 id = h.encode(CHAIN, pool, 0);
        assertTrue(id != EpochId.NULL);
    }

    // =========================================================================
    // E — bit-layout regression (golden values)
    // =========================================================================

    /// @notice Hard-coded golden test: if the bit layout ever changes, this test
    ///         immediately fails and forces an explicit update + audit review.
    ///
    /// Expected layout:
    ///   chainId    = 1    → bits [255:192]
    ///   poolId     = 0x000...0001 (truncated) → bits [191:32]
    ///   epochIndex = 0    → bits [31:0]
    function test_goldenValue_layoutRegression() public view {
        // Use a PoolId whose lower 160 bits are exactly 0x1 for easy inspection.
        PoolId trivialPool = PoolId.wrap(bytes32(uint256(1)));
        uint256 id = h.encode(CHAIN, trivialPool, 0);

        // chainId = 1 at bit 192  → 1 << 192
        // poolId  = 1 at bit 32   → 1 << 32
        // index   = 0             → 0
        uint256 expected = (uint256(1) << 192) | (uint256(1) << 32);
        assertEq(id, expected, "bit layout regression");
    }

    function test_goldenValue_epochIndexOnly() public view {
        // Pool lower 160 bits = 0, index = 5.
        PoolId zeroPool = PoolId.wrap(bytes32(0));
        uint256 id = h.encode(CHAIN, zeroPool, 5);

        // chainId = 1 << 192, poolId = 0, index = 5
        uint256 expected = (uint256(1) << 192) | uint256(5);
        assertEq(id, expected, "epoch index bits");
    }

    // =========================================================================
    // F — Fuzz
    // =========================================================================

    /// @notice Round-trip holds for all valid (poolId, epochIndex) combinations
    ///         on the current chain.
    function testFuzz_roundTrip(bytes32 rawPoolId, uint32 idx) public view {
        PoolId pid = PoolId.wrap(rawPoolId);
        uint256 id = h.encode(CHAIN, pid, idx);

        assertEq(h.chainId(id),         CHAIN);
        assertEq(h.poolIdTruncated(id), uint160(uint256(rawPoolId)));
        assertEq(h.epochIndex(id),      idx);
    }

/// @notice Field extractors are independent — distinct encoded values
    ///         round-trip back to the field that was encoded.
    ///
    /// The original version of this test assumed that rawPoolA != rawPoolB
    /// implied poolIdTruncated(idA) != poolIdTruncated(idB). That is wrong:
    /// we intentionally keep only the lower 160 bits of each PoolId, so two
    /// bytes32 values that differ only in their upper 96 bits will produce
    /// the same truncated pool field. The counterexample that exposed this:
    ///
    ///   rawPoolA = 0x0000...0000  → lower 160 bits = 0
    ///   rawPoolB = 0x4254432f...  → lower 160 bits = 0  (non-zero bytes are
    ///                               all in bits [255:160], which are dropped)
    ///
    /// The correct property to test: if the *truncated* pool fields differ,
    /// the extractors return distinct values; and if the index fields differ,
    /// the extractors return distinct values. We exclude truncation collisions
    /// from the fuzz space with vm.assume rather than asserting a property the
    /// library never promised.
    function testFuzz_fieldIndependence(
        bytes32 rawPoolA,
        bytes32 rawPoolB,
        uint32  idxA,
        uint32  idxB
    ) public view {
        // Compute truncated pool IDs up-front so vm.assume can exclude
        // collisions that arise purely from the intentional 160-bit truncation.
        uint160 truncA = uint160(uint256(rawPoolA));
        uint160 truncB = uint160(uint256(rawPoolB));

        // We need at least one field to differ after truncation; otherwise
        // idA == idB and there is nothing to assert.
        vm.assume(truncA != truncB || idxA != idxB);

        PoolId pidA = PoolId.wrap(rawPoolA);
        PoolId pidB = PoolId.wrap(rawPoolB);

        uint256 idA = h.encode(CHAIN, pidA, idxA);
        uint256 idB = h.encode(CHAIN, pidB, idxB);

        // If the truncated pool IDs differ, the extractor must reflect that.
        if (truncA != truncB) {
            assertTrue(
                h.poolIdTruncated(idA) != h.poolIdTruncated(idB),
                "distinct truncated poolIds must decode distinctly"
            );
        }

        // If the epoch indices differ, the extractor must reflect that.
        // uint32 is stored losslessly so no truncation caveat applies here.
        if (idxA != idxB) {
            assertTrue(
                h.epochIndex(idA) != h.epochIndex(idB),
                "distinct epoch indices must decode distinctly"
            );
        }
    }

    /// @notice isCurrentChain returns false for any id whose embedded chainId
    ///         differs from the current block.chainid.
    function testFuzz_isCurrentChain_wrongChain(uint64 otherChain) public {
        vm.assume(otherChain != CHAIN && otherChain != 0);
        vm.chainId(otherChain);

        // Build an id that has CHAIN (1) in the upper bits.
        uint256 id = (uint256(CHAIN) << 192) | uint256(IDX);
        assertFalse(h.isCurrentChain(id));
    }
}

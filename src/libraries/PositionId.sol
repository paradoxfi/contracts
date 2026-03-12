// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title PositionId
/// @notice Pure library for encoding and decoding position identifiers.
///
/// A position identifier is a single uint256 that uniquely identifies one LP
/// deposit across the entire protocol. It is used as:
///   • The ERC-721 tokenId in PositionManager (one NFT per deposit).
///   • The ERC-1155 tokenId for VYToken (one VYT series per position).
///   • A lookup key in PositionManager's position storage mapping.
///
/// Design goals
/// ------------
/// 1. Uniqueness  — no two deposits, on any chain, at any time, may share a
///                  position ID. Achieved by embedding chainId and a per-pool
///                  monotonic counter.
///
/// 2. Traceability — given only the uint256 ID an off-chain observer can
///                   recover the originating pool and the deposit sequence
///                   number without any additional storage reads.
///
/// 3. Gas efficiency — encoding and decoding are pure shift/mask arithmetic;
///                     no storage reads, no hashing, no assembly.
///
/// 4. NULL safety  — the zero value is reserved as "unassigned" sentinel.
///                   Real IDs are always non-zero because chainId ≥ 1.
///
/// Bit layout (256 bits total)
/// ---------------------------
///
///   [ 64 bits: chainId ][ 160 bits: poolId (truncated) ][ 32 bits: counter ]
///    255             192  191                          32  31               0
///
/// This mirrors EpochId's layout intentionally: the same upper fields mean
/// that off-chain tooling can apply identical parsing logic to both token
/// types. The counter field replaces EpochId's epochIndex field — it is the
/// per-pool deposit sequence number, starting at 1 (0 is NULL).
///
/// Counter scope
/// -------------
/// The counter is per-pool, not global. Two different pools can both have a
/// position with counter = 1 — they will produce different IDs because their
/// poolId fields differ. The counter is stored in and incremented by
/// PositionManager; this library is purely a codec.
///
/// PoolId truncation
/// -----------------
/// Identical to EpochId: we embed the lower 160 bits of the v4 PoolId
/// (itself a bytes32 keccak256). See EpochId.sol for the collision-probability
/// analysis. Both libraries truncate in the same way so that the pool field
/// is comparable between an EpochId and a PositionId belonging to the same pool.
library PositionId {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown by encode() when the provided chainId does not match
    ///         block.chainid.
    error ChainIdMismatch(uint64 provided, uint64 current);

    /// @notice Thrown by decode() and validateChain() when the embedded chainId
    ///         in a position ID does not match block.chainid.
    error WrongChain(uint64 embedded, uint64 current);

    /// @notice Thrown by encode() when counter is zero.
    ///         Zero is reserved as the NULL sentinel; the first real position
    ///         counter must be 1.
    error ZeroCounter();

    // -------------------------------------------------------------------------
    // Bit layout constants
    // -------------------------------------------------------------------------

    uint256 private constant COUNTER_BITS  = 32;
    uint256 private constant POOL_ID_BITS  = 160;

    uint256 private constant POOL_ID_SHIFT  = COUNTER_BITS;                 // 32
    uint256 private constant CHAIN_ID_SHIFT = COUNTER_BITS + POOL_ID_BITS;  // 192

    uint256 private constant COUNTER_MASK  = type(uint32).max;
    uint256 private constant POOL_ID_MASK  = type(uint160).max;
    uint256 private constant CHAIN_ID_MASK = type(uint64).max;

    // -------------------------------------------------------------------------
    // Null sentinel
    // -------------------------------------------------------------------------

    /// @notice The zero value — used as "no position assigned" sentinel.
    ///
    /// A real positionId can never be zero: encode() rejects counter == 0,
    /// and block.chainid is always ≥ 1 on any live EVM network, so the
    /// upper 64 bits of a valid ID are always non-zero.
    uint256 internal constant NULL = 0;

    // -------------------------------------------------------------------------
    // Encoding
    // -------------------------------------------------------------------------

    /// @notice Encode a (chainId, poolId, counter) triple into a uint256 positionId.
    ///
    /// @param _chainId  The EVM chain ID. Must equal block.chainid.
    /// @param _poolId   The Uniswap v4 PoolId the deposit belongs to.
    /// @param _counter  The per-pool deposit sequence number. Must be ≥ 1.
    /// @return id      The packed uint256 position identifier.
    function encode(uint64 _chainId, PoolId _poolId, uint32 _counter)
        internal
        view
        returns (uint256 id)
    {
        if (_chainId != uint64(block.chainid)) {
            revert ChainIdMismatch(_chainId, uint64(block.chainid));
        }
        if (_counter == 0) revert ZeroCounter();

        id = (uint256(_chainId)                               << CHAIN_ID_SHIFT)
           | (uint256(uint160(uint256(PoolId.unwrap(_poolId))))        << POOL_ID_SHIFT)
           | uint256(_counter);
    }

    /// @notice Convenience overload — reads block.chainid directly.
    ///
    /// This is what PositionManager should call. The explicit chainId overload
    /// is provided for deployment scripts and cross-chain tooling.
    ///
    /// @param _poolId   The Uniswap v4 PoolId the deposit belongs to.
    /// @param _counter  The per-pool deposit sequence number. Must be ≥ 1.
    /// @return id      The packed uint256 position identifier.
    function encode(PoolId _poolId, uint32 _counter)
        internal
        view
        returns (uint256 id)
    {
        if (_counter == 0) revert ZeroCounter();

        id = (uint256(uint64(block.chainid))                 << CHAIN_ID_SHIFT)
           | (uint256(uint160(uint256(PoolId.unwrap(_poolId))))        << POOL_ID_SHIFT)
           | uint256(_counter);
    }

    // -------------------------------------------------------------------------
    // Decoding — individual field extractors
    // -------------------------------------------------------------------------

    /// @notice Extract the deposit counter from a packed position ID.
    ///
    /// @param id  The packed position identifier.
    /// @return    The per-pool deposit sequence number (bits 0–31).
    function counter(uint256 id) internal pure returns (uint32) {
        return uint32(id & COUNTER_MASK);
    }

    /// @notice Extract the truncated pool identifier from a packed position ID.
    ///
    /// Returns the lower 160 bits of the original PoolId. Sufficient for all
    /// internal routing. Use the full PoolId stored in PositionManager if you
    /// need the complete 256-bit key.
    ///
    /// @param id  The packed position identifier.
    /// @return    The lower 160 bits of the PoolId.
    function poolIdTruncated(uint256 id) internal pure returns (uint160) {
        return uint160((id >> POOL_ID_SHIFT) & POOL_ID_MASK);
    }

    /// @notice Extract the chain ID from a packed position ID.
    ///
    /// @param id  The packed position identifier.
    /// @return    The chain ID embedded at bits 192–255.
    function chainId(uint256 id) internal pure returns (uint64) {
        return uint64((id >> CHAIN_ID_SHIFT) & CHAIN_ID_MASK);
    }

    /// @notice Decode all three fields in one call, with chain validation.
    ///
    /// Reverts with WrongChain if the embedded chainId ≠ block.chainid.
    ///
    /// @param id               The packed position identifier.
    /// @return embeddedChainId Chain ID extracted from the identifier.
    /// @return truncatedPoolId Lower 160 bits of the PoolId.
    /// @return depositCounter  Per-pool deposit sequence number.
    function decode(uint256 id)
        internal
        view
        returns (
            uint64  embeddedChainId,
            uint160 truncatedPoolId,
            uint32  depositCounter
        )
    {
        embeddedChainId = chainId(id);
        truncatedPoolId = poolIdTruncated(id);
        depositCounter  = counter(id);

        if (embeddedChainId != uint64(block.chainid)) {
            revert WrongChain(embeddedChainId, uint64(block.chainid));
        }
    }

    // -------------------------------------------------------------------------
    // Validation helpers
    // -------------------------------------------------------------------------

    /// @notice Revert if the position ID was not minted on this chain.
    ///
    /// Drop at the top of any function that accepts a positionId from an
    /// external caller (e.g. PositionManager.burn, MaturityVault.redeemVYT).
    ///
    /// @param id  The packed position identifier to validate.
    function validateChain(uint256 id) internal view {
        uint64 embedded = chainId(id);
        if (embedded != uint64(block.chainid)) {
            revert WrongChain(embedded, uint64(block.chainid));
        }
    }

    /// @notice Non-reverting variant of validateChain, for use in conditionals.
    ///
    /// @param id  The packed position identifier.
    /// @return    True if the embedded chain ID matches block.chainid.
    function isCurrentChain(uint256 id) internal view returns (bool) {
        return chainId(id) == uint64(block.chainid);
    }

    /// @notice Return true if the id is the NULL sentinel.
    ///
    /// Convenience wrapper so call sites read as `PositionId.isNull(pos.id)`
    /// rather than `pos.id == PositionId.NULL`.
    ///
    /// @param id  The packed position identifier.
    /// @return    True if id == 0.
    function isNull(uint256 id) internal pure returns (bool) {
        return id == NULL;
    }

    // -------------------------------------------------------------------------
    // Pool-scoped next-counter helper
    // -------------------------------------------------------------------------

    /// @notice Given the current highest counter for a pool, return the next one.
    ///
    /// Reverts on uint32 overflow — at one deposit per second, overflow takes
    /// ~136 years per pool; this is a deliberate safety check rather than
    /// silent wraparound, which would re-mint an existing positionId.
    ///
    /// PositionManager calls this to derive the counter to pass into encode():
    ///
    ///     uint32 next = PositionId.nextCounter(poolCounters[poolId]++);
    ///     uint256 id  = PositionId.encode(poolId, next);
    ///
    /// @param current  The current value of the pool's counter (before increment).
    /// @return next    current + 1, guaranteed to be ≥ 1 and ≤ uint32.max.
    function nextCounter(uint32 current) internal pure returns (uint32 next) {
        // Overflow check: current == type(uint32).max means the next counter
        // would wrap to 0, which encode() rejects as NULL. Revert explicitly.
        require(current < type(uint32).max, "PositionId: counter overflow");
        unchecked {
            next = current + 1;
        }
    }
}

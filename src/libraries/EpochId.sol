// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title EpochId
/// @notice Pure library for encoding and decoding epoch identifiers.
///
/// An epoch identifier is a single uint256 that uniquely identifies one epoch
/// across all pools, all chains, and all time. It is used as:
///   • The ERC-1155 tokenId for FYToken (all LPs in the same epoch share it).
///   • The key in EpochManager's epoch storage mapping.
///   • A lookup key in YieldRouter and MaturityVault.
///
/// Bit layout (256 bits total)
/// ---------------------------
///
///   [ 64 bits: chainId ][ 160 bits: poolId ][ 32 bits: epochIndex ]
///    255             192  191             32   31                 0
///
/// Rationale for each field width
/// --------------------------------
/// chainId    64 bits — EIP-2294 caps chainId at 2^64 - 49. Reserving 64 bits
///                      gives exact alignment and future-proofs multi-chain
///                      deployments where the same FYT tokenId must never
///                      collide across chains.
///
/// poolId    160 bits — PoolId in v4-core is itself a bytes32 (keccak256 of the
///                      PoolKey). We truncate to the lower 160 bits. Collision
///                      probability across the live pool set is negligible
///                      (birthday bound ≈ 2^80 for 160-bit truncation). We
///                      document this truncation explicitly so auditors are not
///                      surprised by it.
///
/// epochIndex  32 bits — supports 4,294,967,295 epochs per pool. At one epoch
///                       per week that is ~82,000 years. Packing into 32 bits
///                       keeps the full identifier in a single 256-bit word.
///
/// All encoding and decoding is done with explicit bit shifts and masks — no
/// assembly. This is intentional: the library is called on every deposit and
/// settlement, and the compiler optimises pure shift/mask arithmetic well
/// enough that the readability trade-off is worth it.
library EpochId {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the chainId passed to encode() does not match the
    ///         chain the contract is currently executing on.
    /// @dev    Prevents cross-chain identifier reuse by catching mismatches at
    ///         construction time rather than silently encoding the wrong value.
    error ChainIdMismatch(uint64 provided, uint64 current);

    /// @notice Thrown when decode() receives a uint256 whose embedded chainId
    ///         does not match block.chainid.
    /// @dev    Guards against a contract on chain A accidentally accepting an
    ///         epochId minted on chain B.
    error WrongChain(uint64 embedded, uint64 current);

    // -------------------------------------------------------------------------
    // Bit layout constants
    // -------------------------------------------------------------------------

    /// @dev Width of the epochIndex field (bits 0–31).
    uint256 private constant EPOCH_INDEX_BITS = 32;

    /// @dev Width of the poolId field (bits 32–191).
    uint256 private constant POOL_ID_BITS = 160;

    // Derived shift offsets
    uint256 private constant POOL_ID_SHIFT   = EPOCH_INDEX_BITS;                // 32
    uint256 private constant CHAIN_ID_SHIFT  = EPOCH_INDEX_BITS + POOL_ID_BITS; // 192

    // Derived masks (applied after shifting the value down to bit 0)
    uint256 private constant EPOCH_INDEX_MASK = type(uint32).max;  // 0xFFFFFFFF
    uint256 private constant POOL_ID_MASK     = type(uint160).max; // 20-byte mask
    uint256 private constant CHAIN_ID_MASK    = type(uint64).max;  // 0xFFFFFFFFFFFFFFFF

    // -------------------------------------------------------------------------
    // Encoding
    // -------------------------------------------------------------------------

    /// @notice Encode a (chainId, poolId, epochIndex) triple into a single uint256.
    ///
    /// @param _chainId    The EVM chain ID for the chain this identifier will live
    ///                   on. Must equal block.chainid to prevent accidental
    ///                   cross-chain misuse.
    /// @param _poolId     The Uniswap v4 PoolId. Lower 160 bits are used.
    /// @param _epochIndex The epoch sequence number for this pool (0-based).
    /// @return id        The packed uint256 epoch identifier.
    function encode(uint64 _chainId, PoolId _poolId, uint32 _epochIndex)
        internal
        view
        returns (uint256 id)
    {
        // Reject caller if they supplied the wrong chain — likely a copy-paste
        // error in a deployment script or test setup.
        if (_chainId != uint64(block.chainid)) {
            revert ChainIdMismatch(_chainId, uint64(block.chainid));
        }

        id = (uint256(_chainId)               << CHAIN_ID_SHIFT)
           | (uint256(uint160(uint256(PoolId.unwrap(_poolId)))) << POOL_ID_SHIFT)
           | uint256(_epochIndex);
    }

    /// @notice Convenience overload: uses block.chainid directly so callers
    ///         do not have to pass the chain ID explicitly.
    ///
    /// This is the function most internal callers should use. The explicit
    /// chainId overload exists for cross-chain tooling and tests that need to
    /// construct identifiers for a specific chain without forking.
    ///
    /// @param _poolId     The Uniswap v4 PoolId.
    /// @param _epochIndex The epoch sequence number for this pool.
    /// @return id        The packed uint256 epoch identifier.
    function encode(PoolId _poolId, uint32 _epochIndex)
        internal
        view
        returns (uint256 id)
    {
        id = (uint256(uint64(block.chainid))          << CHAIN_ID_SHIFT)
           | (uint256(uint160(uint256(PoolId.unwrap(_poolId)))) << POOL_ID_SHIFT)
           | uint256(_epochIndex);
    }

    // -------------------------------------------------------------------------
    // Decoding
    // -------------------------------------------------------------------------

    /// @notice Extract the epoch index from a packed epoch identifier.
    ///
    /// Does not validate the chain ID — callers that need chain validation
    /// should call validateChain() first, or use the full decode() function.
    ///
    /// @param id  The packed epoch identifier.
    /// @return    The epoch sequence number (bits 0–31).
    function epochIndex(uint256 id) internal pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(id & EPOCH_INDEX_MASK);
    }

    /// @notice Extract the (truncated) pool identifier from a packed epoch id.
    ///
    /// Returns the lower 160 bits of the original PoolId. Sufficient for all
    /// internal routing and storage lookups. Use the original PoolId value
    /// (stored separately in EpochManager) if you need the full 256-bit key.
    ///
    /// @param id  The packed epoch identifier.
    /// @return    The lower 160 bits of the PoolId, as a raw uint160.
    function poolIdTruncated(uint256 id) internal pure returns (uint160) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint160((id >> POOL_ID_SHIFT) & POOL_ID_MASK);
    }

    /// @notice Extract the chain ID from a packed epoch identifier.
    ///
    /// @param id  The packed epoch identifier.
    /// @return    The chain ID embedded at bits 192–255.
    function chainId(uint256 id) internal pure returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64((id >> CHAIN_ID_SHIFT) & CHAIN_ID_MASK);
    }

    /// @notice Decode all three fields from a packed epoch identifier in one call.
    ///
    /// Also validates that the embedded chain ID matches block.chainid.
    /// Reverts with WrongChain if there is a mismatch.
    ///
    /// @param id           The packed epoch identifier.
    /// @return embeddedChainId  Chain ID extracted from the identifier.
    /// @return truncatedPoolId  Lower 160 bits of the PoolId.
    /// @return index            Epoch sequence number.
    function decode(uint256 id)
        internal
        view
        returns (
            uint64  embeddedChainId,
            uint160 truncatedPoolId,
            uint32  index
        )
    {
        embeddedChainId = chainId(id);
        truncatedPoolId = poolIdTruncated(id);
        index           = epochIndex(id);

        if (embeddedChainId != uint64(block.chainid)) {
            revert WrongChain(embeddedChainId, uint64(block.chainid));
        }
    }

    // -------------------------------------------------------------------------
    // Validation helpers
    // -------------------------------------------------------------------------

    /// @notice Revert if the epoch identifier was not minted on this chain.
    ///
    /// Cheap guard that can be dropped at the top of any function that accepts
    /// an epochId from an external caller (e.g. MaturityVault.redeem).
    ///
    /// @param id  The packed epoch identifier to validate.
    function validateChain(uint256 id) internal view {
        uint64 embedded = chainId(id);
        if (embedded != uint64(block.chainid)) {
            revert WrongChain(embedded, uint64(block.chainid));
        }
    }

    /// @notice Return true if the epoch identifier was encoded on this chain.
    ///
    /// Non-reverting variant for use in conditionals.
    ///
    /// @param id  The packed epoch identifier.
    /// @return    True if the embedded chain ID matches block.chainid.
    function isCurrentChain(uint256 id) internal view returns (bool) {
        return chainId(id) == uint64(block.chainid);
    }

    // -------------------------------------------------------------------------
    // Null sentinel
    // -------------------------------------------------------------------------

    /// @notice The zero value. Used as a sentinel for "no epoch assigned".
    ///
    /// A real epochId can never be zero because encode() embeds block.chainid,
    /// which is always ≥ 1 on any live EVM network. Contracts may use
    ///   `epochId == EpochId.NULL`
    /// to check whether a field has been initialised.
    uint256 internal constant NULL = 0;
}

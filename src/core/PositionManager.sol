// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolId}  from "v4-core/types/PoolId.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {PositionId} from "../libraries/PositionId.sol";

/// @title PositionManager
/// @notice ERC-721 NFT contract — one token per LP deposit into the Paradox Fi
///         fixed-income protocol.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Responsibility boundary
/// ─────────────────────────────────────────────────────────────────────────────
///
/// PositionManager is a pure registry. It:
///   • Mints an NFT for each LP deposit (called by ParadoxHook on
///     afterAddLiquidity), storing the position's immutable attributes.
///   • Marks a position as exited when the LP removes liquidity (called by
///     the hook on beforeRemoveLiquidity).
///   • Exposes a read-only view of any position by its positionId.
///
/// It does NOT:
///   • Hold tokens (that is MaturityVault / YieldRouter).
///   • Compute or enforce fixed obligations (that is EpochManager).
///   • Mint or burn FYT / VYT tokens — callers are expected to do that
///     after calling mint() / markExited() here.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Position identifier
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Each position's tokenId is a uint256 packed by PositionId.encode():
///
///   [ 64 bits: chainId ][ 160 bits: poolId (truncated) ][ 32 bits: counter ]
///
/// The counter is per-pool, starting at 1, and incremented on every mint.
/// The identifier mirrors EpochId's layout so off-chain tools can parse both
/// with the same codec. Counter = 0 is the NULL sentinel (PositionId.NULL).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Notional computation
/// ─────────────────────────────────────────────────────────────────────────────
///
/// The caller (ParadoxHook) passes a pre-computed notional. The recommended
/// formula — documented in the impl spec — is:
///
///   notional = liquidity × sqrtPriceX96 >> 96
///
/// This is the single-sided token0 approximation of the position's value at
/// deposit price. It is computed once and stored immutably; it does not track
/// IL after the deposit.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
/// mint()       — authorizedCaller only (ParadoxHook in production)
/// markExited() — authorizedCaller only
/// All view functions — unrestricted
///
/// Owner can update authorizedCaller and transfer ownership (two-step).
contract PositionManager is ERC721, Ownable2Step {
    using PositionId for uint256;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice All immutable attributes of an LP deposit.
    ///
    /// Storage layout (5 slots):
    ///   slot 0: poolId           (bytes32)
    ///   slot 1: epochId          (uint256)
    ///   slot 2: tickLower(24) + tickUpper(24) + liquidity(128) + exited(8) = 185 bits
    ///   slot 3: notional(128) + fixedRate(64) + mintTimestamp(64) = 256 bits
    ///
    /// tickLower and tickUpper are int24 — Solidity packs them with the
    /// adjacent uint128 in slot 2 after the first two 32-byte slots. The
    /// exact packing is compiler-managed; we annotate the layout for auditors.
    struct Position {
        /// @notice The Uniswap v4 pool this deposit belongs to.
        PoolId  poolId;
        /// @notice The EpochId (= FYT tokenId) for the epoch this deposit
        ///         was assigned to at mint time.
        uint256 epochId;
        /// @notice Lower tick of the LP range.
        int24   tickLower;
        /// @notice Upper tick of the LP range.
        int24   tickUpper;
        /// @notice Uniswap v4 liquidity units at deposit time.
        uint128 liquidity;
        /// @notice Token0-denominated notional value at deposit price.
        ///         Computed as: liquidity × sqrtPriceX96 >> 96.
        ///         Immutable — does not track IL.
        uint128 notional;
        /// @notice Annualised fixed rate locked in at mint time (WAD = 1e18).
        ///         Sourced from EpochManager at the time of deposit.
        uint64  fixedRate;
        /// @notice block.timestamp at mint.
        uint64  mintTimestamp;
        /// @notice True after the LP removes all liquidity.
        ///         Set by markExited(); never unset.
        bool    exited;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    /// @dev position storage: positionId → Position.
    mapping(uint256 => Position) private _positions;

    /// @dev per-pool deposit counter: PoolId.unwrap() → current counter value.
    ///      The next positionId for pool P uses PositionId.nextCounter(counter[P]).
    ///      Starts at 0; first real counter passed to encode() is 1.
    mapping(bytes32 => uint32) private _counters;

    /// @notice Address authorised to call mint() and markExited().
    ///         Set to ParadoxHook in production.
    address public authorizedCaller;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new position NFT is minted.
    event PositionMinted(
        uint256 indexed positionId,
        address indexed owner,
        PoolId  indexed poolId,
        uint256         epochId,
        uint128         notional,
        uint64          fixedRate
    );

    /// @notice Emitted when an LP removes liquidity and the position is closed.
    event PositionExited(
        uint256 indexed positionId,
        address indexed owner
    );

    event AuthorizedCallerSet(address indexed previous, address indexed next);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotAuthorized();
    error ZeroAddress();
    error ZeroNotional();
    error ZeroLiquidity();
    error PositionDoesNotExist(uint256 positionId);
    error PositionAlreadyExited(uint256 positionId);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _owner,
        address _authorizedCaller
    ) ERC721("Paradox Fi Position", "PDX-POS")  Ownable(_owner) {
        authorizedCaller = _authorizedCaller;
    }

    // =========================================================================
    // Modifiers
    // =========================================================================
    modifier onlyAuthorized() {
        if (msg.sender != authorizedCaller) {
            revert NotAuthorized();
        }
        _;
    }

    /// @notice Update the authorized non-owner caller (ParadoxHook).
    function setAuthorizedCaller(address caller) external onlyOwner {
        address prev = authorizedCaller;
        authorizedCaller = caller;
        emit AuthorizedCallerSet(prev, caller);
    }

    // =========================================================================
    // Core: mint
    // =========================================================================

    /// @notice Mint a position NFT for an LP deposit.
    ///
    /// Called by ParadoxHook in the afterAddLiquidity callback. The hook is
    /// responsible for:
    ///   1. Computing notional = liquidity × sqrtPriceX96 >> 96.
    ///   2. Reading the current epochId and fixedRate from EpochManager.
    ///   3. Passing all fields to this function.
    ///
    /// PositionManager assigns the positionId via its per-pool counter and
    /// mints the ERC-721 to `recipient`.
    ///
    /// @param recipient    Address to receive the NFT (the LP).
    /// @param poolId       The v4 pool the deposit is in.
    /// @param epochId      The EpochId for the currently active epoch.
    /// @param tickLower    Lower tick of the LP range.
    /// @param tickUpper    Upper tick of the LP range.
    /// @param liquidity    v4 liquidity units at deposit.
    /// @param notional     Token0-denominated value at deposit price (WAD units).
    /// @param fixedRate    Annualised fixed rate from EpochManager (WAD).
    /// @return positionId  The newly minted ERC-721 tokenId.
    function mint(
        address recipient,
        PoolId  poolId,
        uint256 epochId,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity,
        uint128 notional,
        uint64  fixedRate
    ) external onlyAuthorized returns (uint256 positionId) {
        if (recipient == address(0)) revert ZeroAddress();
        if (liquidity == 0)          revert ZeroLiquidity();
        if (notional == 0)           revert ZeroNotional();

        // Derive the positionId using the pool's current counter.
        bytes32 key     = PoolId.unwrap(poolId);
        uint32  current = _counters[key];
        uint32  next    = PositionId.nextCounter(current);
        _counters[key]  = next;

        positionId = PositionId.encode(poolId, next);

        _positions[positionId] = Position({
            poolId:        poolId,
            epochId:       epochId,
            tickLower:     tickLower,
            tickUpper:     tickUpper,
            liquidity:     liquidity,
            notional:      notional,
            fixedRate:     fixedRate,
            mintTimestamp: uint64(block.timestamp),
            exited:        false
        });

        _mint(recipient, positionId);

        emit PositionMinted(
            positionId,
            recipient,
            poolId,
            epochId,
            notional,
            fixedRate
        );
    }

    // =========================================================================
    // Core: markExited
    // =========================================================================

    /// @notice Mark a position as exited when the LP removes liquidity.
    ///
    /// Called by ParadoxHook in the beforeRemoveLiquidity callback. Sets
    /// `position.exited = true`. The NFT is NOT burned — the owner retains it
    /// as a receipt for MaturityVault redemption after epoch settlement.
    ///
    /// Reverts if the position does not exist or has already been exited.
    ///
    /// @param positionId  The ERC-721 tokenId to mark as exited.
    function markExited(uint256 positionId) external onlyAuthorized {
        Position storage pos = _positions[positionId];

        // Existence check: positionId is stored iff pos.liquidity > 0 OR
        // pos.notional > 0. More robustly: the position was minted iff the
        // NFT exists in ERC-721 state. We use _ownerOf() which returns
        // address(0) for un-minted tokens.
        if (_ownerOf(positionId) == address(0)) {
            revert PositionDoesNotExist(positionId);
        }
        if (pos.exited) revert PositionAlreadyExited(positionId);

        pos.exited = true;

        emit PositionExited(positionId, _ownerOf(positionId));
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Return the full Position struct for a given positionId.
    ///         Reverts if the position does not exist.
    function getPosition(uint256 positionId) external view returns (Position memory) {
        if (_ownerOf(positionId) == address(0)) {
            revert PositionDoesNotExist(positionId);
        }
        return _positions[positionId];
    }

    /// @notice Return the current counter value for a pool.
    ///         The next positionId minted for this pool will use counter + 1.
    function poolCounter(PoolId poolId) external view returns (uint32) {
        return _counters[PoolId.unwrap(poolId)];
    }

    /// @notice Return true if the position exists and has not been exited.
    function isActive(uint256 positionId) external view returns (bool) {
        return _ownerOf(positionId) != address(0) && !_positions[positionId].exited;
    }
}

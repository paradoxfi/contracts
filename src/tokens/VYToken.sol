// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155}       from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title VYToken
/// @notice ERC-1155 Variable Yield Token for the Paradox Fi protocol.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Token semantics
/// ─────────────────────────────────────────────────────────────────────────────
///
/// tokenId = positionId (packed uint256 from PositionId library)
///
/// Each LP position receives a unique VYT tokenId — VYT is non-fungible within
/// the ERC-1155 scheme. Amount is always exactly 1 per position. This means
/// VYT behaves like an ERC-721 in economic terms (one token per LP deposit)
/// while remaining ERC-1155 for gas efficiency and composability with the
/// MaturityVault redemption flow.
///
/// At settlement the VYT holder receives:
///   vytTotal / vytSupplyAtSettle
/// where vytTotal and vytSupplyAtSettle are set by MaturityVault. Since each
/// position has amount=1 and the supply equals the count of active positions
/// in the epoch, this is a flat per-position split of the variable tranche.
///
/// VYT is fully transferable — the holder at settlement time receives the
/// payout, not the original minter. This allows LPs to sell their variable
/// upside independently of the fixed-income NFT.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
///   MINTER_ROLE — PositionManager (mints exactly 1 on LP deposit)
///   BURNER_ROLE — PositionManager (burns on early exit)
///                 MaturityVault   (burns on redemption)
///
/// DEFAULT_ADMIN_ROLE should be transferred to governance post-deployment.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// epochId tracking
/// ─────────────────────────────────────────────────────────────────────────────
///
/// MaturityVault.receiveSettlement() snapshots `totalSupply(epochId)` to get
/// the count of VYT positions in the epoch. Since VYT tokenIds are positionIds
/// (not epochIds), we maintain a separate mapping: epochId → total minted count.
/// This is what MaturityVault queries as `totalSupply(epochId)`.
///
/// We implement this by overriding totalSupply(uint256 id) to serve both:
///   • totalSupply(positionId) — returns 0 or 1 (standard ERC1155Supply)
///   • totalSupply(epochId)    — returns count of positions in that epoch
///
/// Since positionIds and epochIds are both packed uint256s with chainId in the
/// upper bits, they occupy the same namespace. We track epoch-level supply in a
/// separate mapping to avoid collision.
contract VYToken is ERC1155Supply, AccessControl {

    // =========================================================================
    // Roles
    // =========================================================================

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // =========================================================================
    // Metadata
    // =========================================================================

    string public name   = "Paradox Fi Variable Yield Token";
    string public symbol = "VYT";

    // =========================================================================
    // Epoch supply tracking
    // =========================================================================

    /// @notice Count of VYT positions minted for a given epochId.
    ///         Incremented on mint, decremented on burn.
    ///         Queried by MaturityVault.receiveSettlement() as the VYT supply
    ///         denominator for pro-rata payouts.
    mapping(uint256 => uint256) public epochSupply;

    // =========================================================================
    // Errors
    // =========================================================================

    error AmountMustBeOne(uint256 amount);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param admin    Address granted DEFAULT_ADMIN_ROLE.
    /// @param minter   PositionManager address.
    /// @param burners  Addresses granted BURNER_ROLE (PositionManager + MaturityVault).
    /// @param uri_     Base URI for token metadata.
    constructor(
        address          admin,
        address          minter,
        address[] memory burners,
        string memory    uri_
    ) ERC1155(uri_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, minter);
        for (uint256 i = 0; i < burners.length; i++) {
            _grantRole(BURNER_ROLE, burners[i]);
        }
    }

    // =========================================================================
    // Mint / Burn
    // =========================================================================

    /// @notice Mint exactly 1 VYT to `to` for the given `positionId`.
    ///
    /// Called by PositionManager when an LP deposits. Each position receives
    /// exactly one VYT. Also increments the epoch-level supply counter so
    /// MaturityVault can snapshot the correct denominator at settlement.
    ///
    /// @param to         Recipient (the LP).
    /// @param positionId The position's packed identifier (= tokenId).
    /// @param epochId    The epoch this position belongs to (for supply tracking).
    function mint(address to, uint256 positionId, uint256 epochId)
        external
        onlyRole(MINTER_ROLE)
    {
        _mint(to, positionId, 1, "");
        epochSupply[epochId]++;
    }

    /// @notice Burn the VYT for a given `positionId`.
    ///
    /// Called by:
    ///   • PositionManager — on early exit (before maturity)
    ///   • MaturityVault   — on redemption (after settlement)
    ///
    /// Also decrements the epoch-level supply counter.
    ///
    /// @param from       Token holder whose VYT is burned.
    /// @param positionId The position's packed identifier (= tokenId).
    /// @param epochId    The epoch this position belongs to (for supply tracking).
    function burn(address from, uint256 positionId, uint256 epochId)
        external
        onlyRole(BURNER_ROLE)
    {
        _burn(from, positionId, 1);
        if (epochSupply[epochId] > 0) epochSupply[epochId]--;
    }

    // =========================================================================
    // totalSupply override for MaturityVault compatibility
    // =========================================================================

    /// @notice Return the supply for a given id.
    ///
    /// MaturityVault calls `totalSupply(epochId)` to snapshot the VYT
    /// denominator at settlement. Since VYT tokenIds are positionIds (not
    /// epochIds), the inherited ERC1155Supply.totalSupply(epochId) would return
    /// 0. We override to check epochSupply first.
    ///
    /// For positionIds: delegates to ERC1155Supply (returns 0 or 1).
    /// For epochIds:    returns epochSupply[id].
    ///
    /// Because both positionIds and epochIds embed chainId + poolId in the same
    /// bit positions, there is no overlap between a valid positionId (counter ≥ 1)
    /// and a valid epochId (epochIndex field) — the fields occupy the same lower
    /// 32 bits but their upper structure is identical. In practice, MaturityVault
    /// always calls with epochId and PositionManager always calls with positionId,
    /// so the caller context disambiguates. We serve epochSupply when the
    /// ERC1155Supply returns 0 and epochSupply is non-zero.
    ///
    /// @dev This works because a valid positionId always has a non-zero lower
    ///      32-bit counter (PositionId encodes counter ≥ 1), while a valid
    ///      epochId has a non-zero lower 32-bit epochIndex OR epochIndex = 0
    ///      for the first epoch. The safest and simplest implementation is:
    ///      return max(ERC1155Supply.totalSupply(id), epochSupply[id]).
    function totalSupply(uint256 id)
        public view override
        returns (uint256)
    {
        uint256 tokenSupply = super.totalSupply(id);
        uint256 epochCount  = epochSupply[id];
        // Return whichever is larger — for positionIds this is tokenSupply (0 or 1),
        // for epochIds this is epochCount (number of positions in that epoch).
        return tokenSupply > epochCount ? tokenSupply : epochCount;
    }

    // =========================================================================
    // ERC-165
    // =========================================================================

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155}       from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {FYToken} from "./FYToken.sol";

/// @title VYToken
/// @notice ERC-1155 Variable Yield Token for the Paradox Fi protocol.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Token semantics
/// ─────────────────────────────────────────────────────────────────────────────
///
/// tokenId = positionId (same positionId used for FYToken)
/// Amount  = 1 (always exactly one VYT per position)
///
/// VYT represents:
///   • The other half of the LP's underlying liquidity principal
///   • A pro-rata claim on the variable fee tranche (Zone A only)
///
/// At epoch maturity:
///   burning VYT for a positionId removes the remaining 50% of the position's
///   v4 liquidity and pays variable fee yield (or zero in Zone B/C).
///
/// VYToken reads position metadata from FYToken — the single source of truth
/// for position data. This avoids duplicating storage and ensures consistency
/// between the two tokens for the same position.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
///   MINTER_ROLE — ParadoxHook (mints on afterAddLiquidity)
///   BURNER_ROLE — MaturityVault (burns on redemption)
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
    // Storage
    // =========================================================================

    /// @notice Canonical position data lives in FYToken. VYToken reads from it.
    FYToken public immutable fyToken;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param admin    Address granted DEFAULT_ADMIN_ROLE.
    /// @param minter   ParadoxHook address.
    /// @param burners  Addresses granted BURNER_ROLE (MaturityVault).
    /// @param uri_     Base URI for token metadata.
    /// @param _fyToken FYToken address — source of position metadata.
    constructor(
        address          admin,
        address          minter,
        address[] memory burners,
        string memory    uri_,
        FYToken          _fyToken
    ) ERC1155(uri_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, minter);
        for (uint256 i = 0; i < burners.length; i++) {
            _grantRole(BURNER_ROLE, burners[i]);
        }
        fyToken = _fyToken;
    }

    // =========================================================================
    // Mint
    // =========================================================================

    /// @notice Mint exactly 1 VYT for a position.
    ///
    /// Position metadata is stored in FYToken — VYToken.mint() does not
    /// accept or store it separately. FYToken.mint() must be called first
    /// for the same positionId so the data is available.
    ///
    /// @param to         Recipient (the LP).
    /// @param positionId The position identifier (= tokenId).
    function mint(address to, uint256 positionId)
        external
        onlyRole(MINTER_ROLE)
    {
        _mint(to, positionId, 1, "");
    }

    // =========================================================================
    // Burn
    // =========================================================================

    /// @notice Burn the VYT for a position. Called by MaturityVault at redemption.
    ///
    /// @param from       Token holder.
    /// @param positionId The position identifier (= tokenId).
    function burn(address from, uint256 positionId)
        external
        onlyRole(BURNER_ROLE)
    {
        _burn(from, positionId, 1);
    }

    // =========================================================================
    // Position metadata passthrough
    // =========================================================================

    /// @notice Return position metadata by reading from FYToken.
    ///         Convenience function so callers only need VYToken's address.
    function getPosition(uint256 positionId)
        external view
        returns (FYToken.PositionData memory)
    {
        return fyToken.getPosition(positionId);
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

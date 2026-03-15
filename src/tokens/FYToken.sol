// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155}       from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title FYToken
/// @notice ERC-1155 Fixed Yield Token for the Paradox Fi protocol.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Token semantics
/// ─────────────────────────────────────────────────────────────────────────────
///
/// tokenId = epochId (packed uint256 from EpochId library)
///
/// All LPs depositing into the same epoch receive FYT with the same tokenId,
/// making the fixed tranche fungible within an epoch. This maximises secondary
/// market depth — any two FYT holders in the same epoch hold interchangeable
/// tokens and can trade without price impact from position-specific attributes.
///
/// Amount minted per LP = their notional deposit (token0-denominated).
/// At redemption, each unit of FYT entitles the holder to:
///   notional × fytTotal / fytSupplyAtSettle
/// where fytTotal and fytSupplyAtSettle are set by MaturityVault at settlement.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
///   MINTER_ROLE — PositionManager (mints on LP deposit)
///   BURNER_ROLE — PositionManager (burns on early exit)
///                 MaturityVault   (burns on redemption)
///
/// Roles are separate so PositionManager cannot burn redemption-time tokens
/// and MaturityVault cannot mint. DEFAULT_ADMIN_ROLE is held by the deployer
/// and should be transferred to a governance multisig post-deployment.
contract FYToken is ERC1155Supply, AccessControl {

    // =========================================================================
    // Roles
    // =========================================================================

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // =========================================================================
    // Metadata
    // =========================================================================

    string public name   = "Paradox Fi Fixed Yield Token";
    string public symbol = "FYT";

    // =========================================================================
    // Errors
    // =========================================================================

    error NotMinter();
    error NotBurner();

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param admin       Address granted DEFAULT_ADMIN_ROLE. Should be a
    ///                    governance multisig — can grant/revoke MINTER/BURNER.
    /// @param minter      PositionManager address.
    /// @param burners     Addresses granted BURNER_ROLE (PositionManager +
    ///                    MaturityVault). Passed as an array so both can be
    ///                    granted atomically at deploy time.
    /// @param uri_        Base URI for token metadata.
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

    /// @notice Mint `amount` FYT to `to` for the given `epochId`.
    ///
    /// Called by PositionManager when an LP deposits into an active epoch.
    /// `amount` should equal the LP's token0-denominated notional.
    ///
    /// @param to      Recipient (the LP).
    /// @param epochId The epoch's packed identifier (= tokenId).
    /// @param amount  Number of FYT units to mint (= notional).
    function mint(address to, uint256 epochId, uint256 amount)
        external
        onlyRole(MINTER_ROLE)
    {
        _mint(to, epochId, amount, "");
    }

    /// @notice Burn `amount` FYT from `from` for the given `epochId`.
    ///
    /// Called by:
    ///   • PositionManager — on early exit (before maturity)
    ///   • MaturityVault   — on redemption (after settlement)
    ///
    /// @param from    Token holder whose FYT is burned.
    /// @param epochId The epoch's packed identifier (= tokenId).
    /// @param amount  Number of FYT units to burn.
    function burn(address from, uint256 epochId, uint256 amount)
        external
        onlyRole(BURNER_ROLE)
    {
        _burn(from, epochId, amount);
    }

    // =========================================================================
    // ERC-165 supportsInterface
    // =========================================================================

    /// @inheritdoc ERC1155
    function supportsInterface(bytes4 interfaceId)
        public view override(ERC1155, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

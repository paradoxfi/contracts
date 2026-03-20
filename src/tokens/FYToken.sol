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
/// tokenId = positionId (packed uint256 from PositionId library)
///
/// Each LP deposit receives its own FYT tokenId, making FYT position-unique.
/// Amount minted = notional / 2 (half the token0-denominated deposit value).
///
/// FYT represents:
///   • Half of the LP's underlying liquidity principal (redeemable at maturity
///     by removing liquidity from the v4 pool)
///   • A pro-rata claim on the fixed fee tranche accumulated during the epoch
///
/// Liquidity removal is blocked by the hook until epoch maturity. At maturity:
///   burning all FYT for a positionId removes 50% of the position's v4 liquidity
///   and pays the fixed fee yield to the FYT holder.
///
/// FYT stores the canonical position metadata — tick range, full liquidity,
/// halfNotional, and epochId — that both MaturityVault and the hook need to
/// execute the liquidity removal at redemption time.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
///   MINTER_ROLE — ParadoxHook (mints on afterAddLiquidity)
///   BURNER_ROLE — MaturityVault (burns on redemption)
///
/// DEFAULT_ADMIN_ROLE held by deployer; should be transferred to governance.
contract FYToken is ERC1155Supply, AccessControl {

    // =========================================================================
    // Roles
    // =========================================================================

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Position metadata stored at mint time. Used by MaturityVault
    ///         to execute liquidity removal from the v4 pool at redemption.
    struct PositionData {
        /// @notice The v4 pool this position belongs to (as bytes32 PoolId).
        bytes32 poolId;
        /// @notice Lower tick of the LP range.
        int24   tickLower;
        /// @notice Upper tick of the LP range.
        int24   tickUpper;
        /// @notice Full v4 liquidity units of the position at deposit time.
        ///         Both FYT and VYT remove liquidity/2 each at redemption.
        uint128 liquidity;
        /// @notice notional / 2 in token0 units. The principal share that
        ///         each of FYT and VYT is entitled to at redemption.
        uint128 halfNotional;
        /// @notice The epochId this position was opened in.
        uint256 epochId;
    }

    // =========================================================================
    // Metadata
    // =========================================================================

    string public name   = "Paradox Fi Fixed Yield Token";
    string public symbol = "FYT";

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice positionId → PositionData. Written once at mint, never updated.
    mapping(uint256 => PositionData) public positions;

    /// @notice epochId → total FYT positions minted in that epoch.
    ///         Used by MaturityVault to snapshot supply at settlement.
    ///         Incremented on mint, decremented on burn.
    mapping(uint256 => uint256) public epochPositionCount;

    // =========================================================================
    // Events
    // =========================================================================

    event PositionRegistered(
        uint256 indexed positionId,
        uint256 indexed epochId,
        bytes32         poolId,
        uint128         liquidity,
        uint128         halfNotional
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error PositionAlreadyRegistered(uint256 positionId);

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param admin    Address granted DEFAULT_ADMIN_ROLE.
    /// @param minter   ParadoxHook address (granted MINTER_ROLE).
    /// @param burners  Addresses granted BURNER_ROLE (MaturityVault).
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
    // Mint
    // =========================================================================

    /// @notice Mint FYT for a new LP deposit, storing position metadata.
    ///
    /// Called by ParadoxHook in afterAddLiquidity. The positionId is the
    /// ERC-1155 tokenId. Amount = halfNotional (notional / 2).
    ///
    /// @param to           Recipient (the LP).
    /// @param positionId   Unique position identifier (= tokenId).
    /// @param data         Position metadata to store.
    function mint(
        address      to,
        uint256      positionId,
        PositionData calldata data
    ) external onlyRole(MINTER_ROLE) {
        if (positions[positionId].liquidity != 0) {
            revert PositionAlreadyRegistered(positionId);
        }

        positions[positionId] = data;
        epochPositionCount[data.epochId]++;

        _mint(to, positionId, data.halfNotional, "");

        emit PositionRegistered(
            positionId,
            data.epochId,
            data.poolId,
            data.liquidity,
            data.halfNotional
        );
    }

    // =========================================================================
    // Burn
    // =========================================================================

    /// @notice Burn all FYT for a position. Called by MaturityVault at redemption.
    ///
    /// @param from       Token holder whose FYT is burned.
    /// @param positionId The position identifier (= tokenId).
    /// @param amount     Amount to burn (should equal holderBalance).
    function burn(address from, uint256 positionId, uint256 amount)
        external
        onlyRole(BURNER_ROLE)
    {
        uint256 epochId = positions[positionId].epochId;
        _burn(from, positionId, amount);
        // Decrement epoch position count if the tokenId supply reaches zero.
        if (totalSupply(positionId) == 0 && epochPositionCount[epochId] > 0) {
            epochPositionCount[epochId]--;
        }
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Return position metadata for a given positionId.
    function getPosition(uint256 positionId)
        external view
        returns (PositionData memory)
    {
        return positions[positionId];
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

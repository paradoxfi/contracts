// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    Ownable2Step,
    Ownable
} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IERC20}    from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId}    from "v4-core/types/PoolId.sol";

import {AuthorizedCaller} from "../libraries/AuthorizedCaller.sol";

import {IFYToken} from "../interfaces/IFYToken.sol";
import {IVYToken} from "../interfaces/IVYToken.sol";

/// @title MaturityVault
/// @notice Escrow and pro-rata redemption contract for the Paradox Fi protocol.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Responsibility boundary
/// ─────────────────────────────────────────────────────────────────────────────
///
/// MaturityVault is entirely passive. It:
///   1. Receives settled funds from YieldRouter via receiveSettlement().
///   2. Lets FYT holders redeem their pro-rata share of the fixed tranche.
///   3. Lets VYT holders redeem their pro-rata share of the variable tranche.
///   4. Burns the corresponding tokens upon successful redemption.
///
/// It does NOT:
///   • Compute settlement amounts (that is YieldRouter.finalizeEpoch()).
///   • Track positions or epoch lifecycle (that is EpochManager / PositionManager).
///   • Move tokens before settlement (funds arrive in a single push from YieldRouter).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Pro-rata mechanics
/// ─────────────────────────────────────────────────────────────────────────────
///
/// FYT (epochId as tokenId, fungible within epoch):
///   payout = holderBalance × fytTotal / fytSupplyAtSettle
///
/// VYT (positionId as tokenId, each position holds exactly 1):
///   payout = vytTotal / vytSupplyAtSettle
///   (simplifies to a flat per-position share in practice)
///
/// Supply snapshots are taken at receiveSettlement() time, not at redemption
/// time. This prevents late buyers of FYT/VYT from diluting early redeemers —
/// the denominator is fixed the moment the epoch closes.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Reentrancy
/// ─────────────────────────────────────────────────────────────────────────────
///
/// All state-mutating functions are nonReentrant. The claimed flags are set
/// BEFORE the ERC-20 transfer (checks-effects-interactions). The token burn
/// happens AFTER the transfer is safe because a reentrant FYT/VYT burn would
/// only affect future redemptions, not the current one (claimed flag already set).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
/// receiveSettlement() — authorizedCaller only (YieldRouter)
/// redeemFYT()        — unrestricted (any FYT holder)
/// redeemVYT()        — unrestricted (any VYT holder)
contract MaturityVault is ReentrancyGuard, Ownable2Step, AuthorizedCaller {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice All data for a settled epoch stored in the vault.
    struct Settlement {
        /// @notice ERC-20 token the fees were denominated in.
        address token;
        /// @notice Total available for FYT redemption.
        uint128 fytTotal;
        /// @notice Total available for VYT redemption.
        uint128 vytTotal;
        /// @notice Snapshot of FYT totalSupply at settlement — denominator for
        ///         pro-rata math. Frozen at receiveSettlement() time.
        uint128 fytSupplyAtSettle;
        /// @notice Snapshot of VYT totalSupply at settlement.
        uint128 vytSupplyAtSettle;
        /// @notice True after YieldRouter has pushed funds for this epoch.
        bool    finalized;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice epochId → Settlement.
    mapping(uint256 => Settlement) public settlements;

    /// @notice epochId → holder → whether FYT redemption has been claimed.
    ///         Prevents double-claim on the fungible FYT tranche.
    mapping(uint256 => mapping(address => bool)) public fytClaimed;

    /// @notice positionId → whether VYT redemption has been claimed.
    ///         VYT is position-unique so the key is the positionId (VYT tokenId).
    mapping(uint256 => bool) public vytClaimed;

    /// @notice FYT ERC-1155 contract.
    IFYToken public immutable fyToken;

    /// @notice VYT ERC-1155 contract.
    IVYToken public immutable vyToken;

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when YieldRouter pushes settlement funds for an epoch.
    event SettlementReceived(
        uint256 indexed epochId,
        address         token,
        uint128         fytTotal,
        uint128         vytTotal,
        uint128         fytSupply,
        uint128         vytSupply
    );

    /// @notice Emitted when an FYT holder redeems.
    event FYTRedeemed(
        uint256 indexed epochId,
        address indexed holder,
        uint256         fytBurned,
        uint128         payout
    );

    /// @notice Emitted when a VYT holder redeems.
    event VYTRedeemed(
        uint256 indexed positionId,
        address indexed holder,
        uint128         payout
    );

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error EpochNotFinalized(uint256 epochId);
    error EpochAlreadyFinalized(uint256 epochId);
    error FYTAlreadyClaimed(uint256 epochId, address holder);
    error VYTAlreadyClaimed(uint256 positionId);
    error NoFYTBalance(uint256 epochId, address holder);
    error NoVYTBalance(uint256 positionId, address holder);
    error ZeroFYTSupply(uint256 epochId);
    error ZeroVYTSupply(uint256 epochId);
    error ZeroVYTPayout(uint256 positionId);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address  _owner,
        address  _authorizedCaller,
        IFYToken _fyToken,
        IVYToken _vyToken
    ) Ownable(_owner) AuthorizedCaller(_authorizedCaller) {
        if (address(_fyToken) == address(0)) revert ZeroAddress();
        if (address(_vyToken) == address(0)) revert ZeroAddress();

        fyToken          = _fyToken;
        vyToken          = _vyToken;
    }

    function setAuthorizedCaller(address caller) external onlyOwner {
        _setAuthorizedCaller(caller);
    }

    // =========================================================================
    // Settlement ingestion
    // =========================================================================

    /// @notice Record a finalized epoch's settlement amounts and snapshot token
    ///         supplies. Called by YieldRouter after transferring funds here.
    ///
    /// The caller (YieldRouter) must transfer `fytTotal + vytTotal` worth of
    /// `token` to this contract BEFORE calling receiveSettlement(). This
    /// function does not pull tokens — it only records the accounting.
    ///
    /// Supply snapshots are taken here rather than at redemption time so that
    /// secondary-market buyers of FYT/VYT after epoch close cannot dilute
    /// existing holders. The denominator is frozen the moment this is called.
    /// TODO: Verify transfer of tokens
    ///
    /// @param epochId   The settled epoch.
    /// @param token     ERC-20 fee token address.
    /// @param fytTotal  Amount allocated to FYT redemption.
    /// @param vytTotal  Amount allocated to VYT redemption.
    function receiveSettlement(
        uint256 epochId,
        address token,
        uint128 fytTotal,
        uint128 vytTotal
    ) external nonReentrant onlyAuthorized {
        if (token == address(0)) revert ZeroAddress();
        if (settlements[epochId].finalized) revert EpochAlreadyFinalized(epochId);

        // Snapshot supplies at this exact moment.
        // Safe cast: ERC-1155 totalSupply is conceptually bounded by minting logic;
        // any realistic supply fits in uint128.
        uint128 fytSupply = uint128(fyToken.totalSupply(epochId));
        uint128 vytSupply = uint128(vyToken.totalSupply(epochId));

        settlements[epochId] = Settlement({
            token:             token,
            fytTotal:          fytTotal,
            vytTotal:          vytTotal,
            fytSupplyAtSettle: fytSupply,
            vytSupplyAtSettle: vytSupply,
            finalized:         true
        });

        emit SettlementReceived(epochId, token, fytTotal, vytTotal, fytSupply, vytSupply);
    }

    // =========================================================================
    // FYT redemption
    // =========================================================================

    /// @notice Redeem FYT tokens for a pro-rata share of the fixed settlement.
    ///
    /// The caller must hold a non-zero FYT balance for the given epochId.
    /// Their entire balance is burned and they receive:
    ///
    ///   payout = holderBalance × fytTotal / fytSupplyAtSettle
    ///
    /// @param epochId  The epoch whose FYT to redeem.
    function redeemFYT(uint256 epochId) external nonReentrant {
        Settlement storage s = settlements[epochId];
        if (!s.finalized) revert EpochNotFinalized(epochId);
        if (fytClaimed[epochId][msg.sender]) revert FYTAlreadyClaimed(epochId, msg.sender);

        uint256 holderBalance = fyToken.balanceOf(msg.sender, epochId);
        if (holderBalance == 0) revert NoFYTBalance(epochId, msg.sender);

        uint128 supply = s.fytSupplyAtSettle;
        if (supply == 0) revert ZeroFYTSupply(epochId);

        // Pro-rata payout. Multiply before dividing to preserve precision.
        // holderBalance × fytTotal ≤ supply × fytTotal ≤ 2^128 × 2^128 = 2^256 — overflows.
        // Safe bound: holderBalance ≤ supply (by ERC-1155 invariant), so
        // holderBalance × fytTotal / supply ≤ fytTotal ≤ type(uint128).max.
        // Use uint256 arithmetic throughout, then truncate safely.
        uint128 payout = uint128(
            (uint256(holderBalance) * uint256(s.fytTotal)) / uint256(supply)
        );

        // Checks-effects-interactions: set claimed before transfer.
        fytClaimed[epochId][msg.sender] = true;

        // Burn the FYT tokens.
        fyToken.burn(msg.sender, epochId, holderBalance);

        // Transfer payout.
        if (payout > 0) {
            IERC20(s.token).safeTransfer(msg.sender, payout);
        }

        emit FYTRedeemed(epochId, msg.sender, holderBalance, payout);
    }

    // =========================================================================
    // VYT redemption
    // =========================================================================

    /// @notice Redeem a VYT position for a pro-rata share of the variable settlement.
    ///
    /// VYT is position-unique: each positionId has exactly 1 token. The payout is:
    ///
    ///   payout = vytTotal / vytSupplyAtSettle
    ///
    /// Which is the flat per-position share of the variable tranche. In Zone B
    /// and C, vytTotal = 0 and payout is 0 — the call still burns the token.
    ///
    /// The caller must be the current holder of the VYT with id = positionId.
    ///
    /// @param epochId    The epoch this VYT was issued for (used to look up Settlement).
    /// @param positionId The VYT tokenId (= ERC-721 positionId from PositionManager).
    function redeemVYT(uint256 epochId, uint256 positionId) external nonReentrant {
        Settlement storage s = settlements[epochId];
        if (!s.finalized) revert EpochNotFinalized(epochId);
        if (vytClaimed[positionId]) revert VYTAlreadyClaimed(positionId);

        uint256 bal = vyToken.balanceOf(msg.sender, positionId);
        if (bal == 0) revert NoVYTBalance(positionId, msg.sender);

        uint128 supply = s.vytSupplyAtSettle;
        if (supply == 0) revert ZeroVYTSupply(epochId);

        // Flat per-position payout: vytTotal / supply.
        uint128 payout = uint128(uint256(s.vytTotal) / uint256(supply));

        // Checks-effects-interactions.
        vytClaimed[positionId] = true;

        // Burn the VYT token.
        vyToken.burn(msg.sender, positionId, bal);

        // Transfer payout (may be 0 in Zone B/C — burn still happens).
        if (payout > 0) {
            IERC20(s.token).safeTransfer(msg.sender, payout);
        }

        emit VYTRedeemed(positionId, msg.sender, payout);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Preview the FYT payout for a given holder without redeeming.
    /// @return payout The amount the holder would receive, or 0 if ineligible.
    function previewFYTPayout(uint256 epochId, address holder)
        external view
        returns (uint128 payout)
    {
        Settlement storage s = settlements[epochId];
        if (!s.finalized) return 0;
        if (fytClaimed[epochId][holder]) return 0;

        uint256 bal = fyToken.balanceOf(holder, epochId);
        if (bal == 0 || s.fytSupplyAtSettle == 0) return 0;

        payout = uint128(
            (uint256(bal) * uint256(s.fytTotal)) / uint256(s.fytSupplyAtSettle)
        );
    }

    /// @notice Preview the VYT payout for a given position without redeeming.
    /// @return payout The amount the holder would receive, or 0 if ineligible.
    function previewVYTPayout(uint256 epochId, uint256 positionId)
        external view
        returns (uint128 payout)
    {
        Settlement storage s = settlements[epochId];
        if (!s.finalized) return 0;
        if (vytClaimed[positionId]) return 0;
        if (s.vytSupplyAtSettle == 0) return 0;

        payout = uint128(uint256(s.vytTotal) / uint256(s.vytSupplyAtSettle));
    }
}

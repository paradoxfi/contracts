// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20}  from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolId}  from "v4-core/types/PoolId.sol";

import {AuthorizedCaller} from "../libraries/AuthorizedCaller.sol";
import {EpochManager} from "./EpochManager.sol";
import {IMaturityVault} from "../interfaces/IMaturityVault.sol";

/// @title YieldRouter
/// @notice Receives all fee income from the hook and routes it through a
///         priority waterfall: fixed tranche first, then reserve buffer skim,
///         then variable tranche.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Design principle: accounting vs. settlement
/// ─────────────────────────────────────────────────────────────────────────────
///
/// ingest() is PURE ACCOUNTING. It updates in-memory counters but does NOT
/// transfer tokens. All fee tokens accumulate in YieldRouter's ERC-20 balance.
/// Token transfers happen exactly twice per epoch:
///   1. finalizeEpoch() — YieldRouter → MaturityVault (settlement hand-off)
///   2. MaturityVault.redeem() — MaturityVault → FYT/VYT holder
///
/// This eliminates the reentrancy surface on the swap-critical ingest() path
/// and keeps the hot path (every swap) as cheap as possible.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Waterfall (ingest step-by-step)
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Given feeAmount arriving for a pool in the context of epoch E:
///
///   Step 1 — Always: heldFees[pool][token] += feeAmount
///
///   Step 2 — Fixed tranche fill:
///     gap = fixedObligation − fixedAccrued   (clamped to 0 if already full)
///     fixedFill = min(feeAmount, gap)
///     fixedAccrued += fixedFill
///     remaining = feeAmount − fixedFill
///
///   Step 3 — Buffer skim (on surplus only):
///     skim = remaining × BUFFER_SKIM_RATE / WAD
///     reserveBuffer[pool] += skim
///     reserveContrib[epoch] += skim
///     remaining -= skim
///
///   Step 4 — Variable tranche:
///     variableAccrued += remaining
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Settlement zones (finalizeEpoch)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   Zone A — fees ≥ obligation (full coverage):
///     FYT receives fixedObligation
///     VYT receives variableAccrued
///     reserveBuffer grows by skim already collected
///
///   Zone B — fees + buffer ≥ obligation (buffer rescue):
///     shortfall = fixedObligation − fixedAccrued
///     reserveBuffer[pool] -= shortfall
///     FYT receives fixedObligation
///     VYT receives 0
///
///   Zone C — fees + buffer < obligation (haircut):
///     reserveBuffer[pool] = 0  (fully depleted)
///     FYT receives fixedAccrued + full buffer draw  (< obligation)
///     VYT receives 0
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Access control
/// ─────────────────────────────────────────────────────────────────────────────
///
/// ingest()         — authorizedCaller only (ParadoxHook)
/// finalizeEpoch()  — authorizedCaller or owner (called from settle flow)
/// All view fns     — unrestricted
contract YieldRouter is ReentrancyGuard, Ownable2Step, AuthorizedCaller {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Constants
    // =========================================================================

    /// @dev WAD precision base.
    uint256 internal constant WAD = 1e18;

    /// @dev Default buffer skim rate: 10% of surplus fees.
    ///      Governance can override via setBufferSkimRate().
    uint256 public bufferSkimRate = 0.10e18;

    /// @dev Hard bounds for the skim rate — prevents governance from draining
    ///      variable holders (max 25%) or making the buffer useless (min 5%).
    uint256 internal constant MIN_SKIM_RATE = 0.05e18;
    uint256 internal constant MAX_SKIM_RATE = 0.25e18;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Per-epoch fee accounting state.
    ///
    /// Packed into two storage slots:
    ///   slot 0: fixedAccrued(128) + variableAccrued(128)
    ///   slot 1: reserveContrib(128) + [96 bits padding]
    struct EpochBalance {
        /// @notice Fees allocated to the fixed tranche so far.
        uint128 fixedAccrued;
        /// @notice Fees allocated to the variable tranche so far.
        uint128 variableAccrued;
        /// @notice Total amount skimmed to the reserve buffer during this epoch.
        ///         Informational — the actual buffer lives in reserveBuffer[pool].
        uint128 reserveContrib;
    }

    /// @notice Result of a finalizeEpoch() call — passed to MaturityVault.
    struct SettlementAmounts {
        /// @notice Amount to pay to FYT holders (fixed tranche).
        uint128 fytAmount;
        /// @notice Amount to pay to VYT holders (variable tranche).
        uint128 vytAmount;
        /// @notice Zone: 0 = full coverage, 1 = buffer rescue, 2 = haircut.
        uint8   zone;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice Per-epoch fee accounting. epochId → EpochBalance.
    mapping(uint256 => EpochBalance) public epochBalances;

    /// @notice Cross-epoch reserve buffer per pool. Grows from skim, shrinks
    ///         when used to rescue a deficit.
    mapping(bytes32 => uint128) public reserveBuffer;

    /// @notice Total fee tokens currently held per pool per token address.
    ///         Updated on every ingest(); decremented on finalizeEpoch().
    ///         Invariant: sum over all epochs of (fixedAccrued + variableAccrued)
    ///         ≤ heldFees for the corresponding pool+token pair.
    mapping(bytes32 => mapping(address => uint128)) public heldFees;

    /// @notice EpochManager — queried for fixedObligation at settlement.
    EpochManager public immutable epochManager;

    /// @notice MaturityVault address — recipient of finalizeEpoch() transfers.
    address public maturityVault;

    // =========================================================================
    // Events
    // =========================================================================

    event FeesIngested(
        uint256 indexed epochId,
        PoolId  indexed poolId,
        address         token,
        uint128         feeAmount,
        uint128         fixedFill,
        uint128         skimAmount,
        uint128         variableFill
    );

    event EpochFinalized(
        uint256 indexed epochId,
        PoolId  indexed poolId,
        uint128         fytAmount,
        uint128         vytAmount,
        uint8           zone
    );

    event BufferSkimRateSet(uint256 previous, uint256 next);
    event MaturityVaultSet(address previous, address next);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error SkimRateOutOfBounds(uint256 rate);
    error EpochNotFound(uint256 epochId);
    error MaturityVaultNotSet();
    error InsufficientHeldFees(uint128 needed, uint128 held);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address        _owner,
        address        _authorizedCaller,
        EpochManager   _epochManager
    ) Ownable(_owner) AuthorizedCaller(_authorizedCaller) {
        if (address(_epochManager) == address(0)) revert ZeroAddress();

        epochManager      = _epochManager;
    }

    // =========================================================================
    // Governance
    // =========================================================================

    function setAuthorizedCaller(address caller) external onlyOwner {
        _setAuthorizedCaller(caller);
    }

    /// @notice Update the MaturityVault address that receives settlement funds.
    function setMaturityVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        address prev = maturityVault;
        maturityVault = vault;
        emit MaturityVaultSet(prev, vault);
    }

    /// @notice Update the buffer skim rate. Must be in [5%, 25%].
    function setBufferSkimRate(uint256 rate) external onlyOwner {
        if (rate < MIN_SKIM_RATE || rate > MAX_SKIM_RATE) {
            revert SkimRateOutOfBounds(rate);
        }
        uint256 prev = bufferSkimRate;
        bufferSkimRate = rate;
        emit BufferSkimRateSet(prev, rate);
    }

    // =========================================================================
    // Core: ingest
    // =========================================================================

    /// @notice Record incoming fee income for an epoch and run the waterfall.
    ///
    /// Called by ParadoxHook on every afterSwap that generates protocol fees.
    /// Pure accounting — does NOT transfer tokens. The fee tokens must already
    /// reside in this contract's balance before ingest() is called (the hook
    /// transfers them before calling).
    ///
    /// @param epochId         The active epoch for this pool.
    /// @param poolId          The pool the fees originate from.
    /// @param token           The ERC-20 fee token (token0 or token1).
    /// @param feeAmount       Total fee amount to route.
    /// @param fixedObligation The epoch's current total fixed obligation from
    ///                        EpochManager. Passed in to avoid a storage read
    ///                        on the hot swap path.
    function ingest(
        uint256 epochId,
        PoolId  poolId,
        address token,
        uint128 feeAmount,
        uint128 fixedObligation
    ) external nonReentrant onlyAuthorized {
        if (feeAmount == 0) return;

        bytes32 poolKey = PoolId.unwrap(poolId);

        // Step 1: track gross fee receipt.
        heldFees[poolKey][token] += feeAmount;

        EpochBalance storage bal = epochBalances[epochId];

        // Step 2: fill fixed tranche up to the obligation.
        uint128 fixedFill;
        {
            uint128 alreadyFixed = bal.fixedAccrued;
            if (alreadyFixed < fixedObligation) {
                uint128 gap       = fixedObligation - alreadyFixed;
                fixedFill         = feeAmount < gap ? feeAmount : gap;
                bal.fixedAccrued  = alreadyFixed + fixedFill;
            }
            // If already at or beyond obligation, fixedFill stays 0.
        }

        uint128 remaining = feeAmount - fixedFill;

        // Step 3: buffer skim on surplus.
        uint128 skimAmount;
        if (remaining > 0) {
            // mulWad: remaining × bufferSkimRate / WAD, rounded down.
            // Safe: remaining ≤ type(uint128).max, bufferSkimRate ≤ 0.25e18 < 2^58,
            // product ≤ 2^128 × 2^58 = 2^186 < 2^256.
            skimAmount               = uint128((uint256(remaining) * bufferSkimRate) / WAD);
            reserveBuffer[poolKey]  += skimAmount;
            bal.reserveContrib      += skimAmount;
            remaining               -= skimAmount;
        }

        // Step 4: remainder goes to variable tranche.
        uint128 variableFill = remaining;
        if (variableFill > 0) {
            bal.variableAccrued += variableFill;
        }

        emit FeesIngested(
            epochId, poolId, token,
            feeAmount, fixedFill, skimAmount, variableFill
        );
    }

    // =========================================================================
    // Core: finalizeEpoch
    // =========================================================================

    /// @notice Compute settlement amounts and transfer them to MaturityVault.
    ///
    /// Called as part of the epoch settlement flow — after EpochManager marks
    /// the epoch SETTLED. Applies the three-zone waterfall to determine exactly
    /// how much FYT holders and VYT holders receive, depleting the reserve
    /// buffer if needed, then transfers both amounts to MaturityVault in a
    /// single call sequence.
    ///
    /// IMPORTANT: This function performs ERC-20 transfers. It must only be
    /// called once per epoch (enforced by EpochManager's SETTLED state check).
    ///
    /// @param epochId         The epoch being finalized.
    /// @param poolId          The pool the epoch belongs to.
    /// @param token           The fee token to transfer.
    /// @param fixedObligation The final fixed obligation for the epoch.
    /// @return result         Settlement amounts and zone classification.
    function finalizeEpoch(
        uint256 epochId,
        PoolId  poolId,
        address token,
        uint128 fixedObligation
    ) external nonReentrant onlyAuthorized returns (SettlementAmounts memory result) {
        if (maturityVault == address(0)) revert MaturityVaultNotSet();

        bytes32 poolKey = PoolId.unwrap(poolId);
        EpochBalance storage bal = epochBalances[epochId];

        uint128 fixedAccrued    = bal.fixedAccrued;
        uint128 variableAccrued = bal.variableAccrued;
        uint128 bufferAvail     = reserveBuffer[poolKey];

        if (fixedAccrued >= fixedObligation) {
            // ── Zone A: full coverage ────────────────────────────────────────
            // Fees alone covered the obligation. VYT gets the surplus.
            result.fytAmount = fixedObligation;
            result.vytAmount = variableAccrued;
            result.zone      = 0;
            // Reserve buffer keeps its skim (already in reserveBuffer).

        } else {
            uint128 shortfall = fixedObligation - fixedAccrued;

            if (bufferAvail >= shortfall) {
                // ── Zone B: buffer rescue ────────────────────────────────────
                // Buffer covers the gap. FYT made whole. VYT gets nothing.
                reserveBuffer[poolKey] = bufferAvail - shortfall;
                result.fytAmount       = fixedObligation;
                result.vytAmount       = 0;
                result.zone            = 1;

            } else {
                // ── Zone C: haircut ──────────────────────────────────────────
                // Even with full buffer, can't cover obligation.
                // FYT receives everything available. VYT gets nothing.
                result.fytAmount       = fixedAccrued + bufferAvail;
                result.vytAmount       = 0;
                result.zone            = 2;
                reserveBuffer[poolKey] = 0;
            }
        }

        // Update heldFees to reflect the outflow.
        uint128 totalOut = result.fytAmount + result.vytAmount;
        uint128 held     = heldFees[poolKey][token];
        if (totalOut > held) revert InsufficientHeldFees(totalOut, held);
        heldFees[poolKey][token] = held - totalOut;

        // Transfer to MaturityVault. Two separate transfers so MaturityVault
        // can account for FYT and VYT pools independently. If vytAmount is 0
        // we skip the second transfer to save gas.
        if (result.fytAmount > 0) {
            IERC20(token).safeTransfer(maturityVault, result.fytAmount);
        }
        if (result.vytAmount > 0) {
            IERC20(token).safeTransfer(maturityVault, result.vytAmount);
        }

        IMaturityVault(maturityVault).receiveSettlement(
            epochId, token, result.fytAmount, result.vytAmount
        );

        emit EpochFinalized(epochId, poolId, result.fytAmount, result.vytAmount, result.zone);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Return the EpochBalance for a given epochId.
    function getEpochBalance(uint256 epochId)
        external view
        returns (EpochBalance memory)
    {
        return epochBalances[epochId];
    }

    /// @notice Return the current reserve buffer for a pool.
    function getReserveBuffer(PoolId poolId) external view returns (uint128) {
        return reserveBuffer[PoolId.unwrap(poolId)];
    }

    /// @notice Return total fees held for a pool+token pair.
    function getHeldFees(PoolId poolId, address token) external view returns (uint128) {
        return heldFees[PoolId.unwrap(poolId)][token];
    }

    /// @notice Preview what finalizeEpoch() would return without state changes.
    ///         Useful for off-chain simulation and front-end display.
    function previewFinalization(
        uint256 epochId,
        PoolId  poolId,
        uint128 fixedObligation
    ) external view returns (SettlementAmounts memory result) {
        EpochBalance storage bal = epochBalances[epochId];
        uint128 fixedAccrued    = bal.fixedAccrued;
        uint128 variableAccrued = bal.variableAccrued;
        uint128 bufferAvail     = reserveBuffer[PoolId.unwrap(poolId)];

        if (fixedAccrued >= fixedObligation) {
            result.fytAmount = fixedObligation;
            result.vytAmount = variableAccrued;
            result.zone      = 0;
        } else {
            uint128 shortfall = fixedObligation - fixedAccrued;
            if (bufferAvail >= shortfall) {
                result.fytAmount = fixedObligation;
                result.vytAmount = 0;
                result.zone      = 1;
            } else {
                result.fytAmount = fixedAccrued + bufferAvail;
                result.vytAmount = 0;
                result.zone      = 2;
            }
        }
    }
}

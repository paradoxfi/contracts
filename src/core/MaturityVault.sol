// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20}         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager}          from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}               from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency}              from "v4-core/types/Currency.sol";
import {BalanceDelta}          from "v4-core/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {FYToken} from "../tokens/FYToken.sol";
import {VYToken} from "../tokens/VYToken.sol";

/// @title MaturityVault
/// @notice Escrow, liquidity redemption, and fee distribution at epoch maturity.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Responsibilities
/// ─────────────────────────────────────────────────────────────────────────────
///
///   1. receiveSettlement() — called by YieldRouter after finalizeEpoch().
///      Records fee amounts and snapshots FYT/VYT position counts.
///
///   2. redeemFYT(positionId) — burns FYT for a position and:
///        a. Removes liquidity/2 from the v4 pool → underlying tokens to caller
///        b. Pays pro-rata fixed fee yield to caller
///
///   3. redeemVYT(positionId) — burns VYT for a position and:
///        a. Removes the other liquidity/2 from v4 → underlying tokens to caller
///        b. Pays pro-rata variable fee yield (or zero in Zone B/C)
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Liquidity removal mechanics
/// ─────────────────────────────────────────────────────────────────────────────
///
/// The hook holds v4 LP positions during the epoch (depositors LP through the
/// hook, making the hook the position owner in PoolManager). MaturityVault is
/// granted operator rights over the hook so it can call modifyLiquidity() at
/// redemption time.
///
/// Each position's liquidity is split exactly 50/50:
///   FYT redemption removes liquidity/2  →  underlying delta_0a, delta_1a
///   VYT redemption removes liquidity/2  →  underlying delta_0b, delta_1b
///
/// Whatever is actually withdrawn (accounting for price drift / IL) is sent
/// directly to the token holder. Neither holder knows the exact split in advance
/// — together they receive the full position value.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Fee distribution
/// ─────────────────────────────────────────────────────────────────────────────
///
/// Fee tokenId is always token0 of the pool (per YieldRouter convention).
/// Fee payouts are pro-rata across all FYT positions (fixed) or all VYT
/// positions (variable), using position count snapshots taken at settlement.
///
///   FYT fee payout = fytTotal / fytPositionCount          (equal per position)
///   VYT fee payout = vytTotal / vytPositionCount          (equal per position)
///
/// Equal per-position distribution is correct because each position's halfNotional
/// (and thus its FYT amount) already encodes the LP's proportional stake.
/// The fee tranche was built proportionally during ingest() via addNotional().
contract MaturityVault is ReentrancyGuard {
    using SafeERC20    for IERC20;
    using PoolIdLibrary for PoolKey;

    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Settlement record for one epoch.
    struct Settlement {
        /// @notice ERC-20 fee token (token0).
        address token;
        /// @notice Total fee tokens available for FYT holders.
        uint128 fytTotal;
        /// @notice Total fee tokens available for VYT holders.
        uint128 vytTotal;
        /// @notice Number of FYT positions at settlement (denominator).
        uint128 fytPositionCount;
        /// @notice Number of VYT positions at settlement (denominator).
        uint128 vytPositionCount;
        /// @notice True after YieldRouter has pushed funds.
        bool    finalized;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    /// @notice epochId → Settlement.
    mapping(uint256 => Settlement) public settlements;

    /// @notice positionId → FYT redeemed.
    mapping(uint256 => bool) public fytRedeemed;

    /// @notice positionId → VYT redeemed.
    mapping(uint256 => bool) public vytRedeemed;

    /// @notice FYT token contract — canonical source of position metadata.
    FYToken public immutable fyToken;

    /// @notice VYT token contract.
    VYToken public immutable vyToken;

    /// @notice Uniswap v4 PoolManager — used to remove liquidity at redemption.
    IPoolManager public immutable poolManager;

    address public owner;
    address public pendingOwner;
    address public authorizedCaller; // YieldRouter

    // =========================================================================
    // Events
    // =========================================================================

    event SettlementReceived(
        uint256 indexed epochId,
        address         token,
        uint128         fytTotal,
        uint128         vytTotal,
        uint128         fytPositionCount,
        uint128         vytPositionCount
    );
    event FYTRedeemed(
        uint256 indexed positionId,
        address indexed holder,
        uint128         feePayout,
        int128          delta0,
        int128          delta1
    );
    event VYTRedeemed(
        uint256 indexed positionId,
        address indexed holder,
        uint128         feePayout,
        int128          delta0,
        int128          delta1
    );
    event OwnershipTransferInitiated(address indexed prev, address indexed pending);
    event OwnershipTransferred(address indexed prev, address indexed next);
    event AuthorizedCallerSet(address indexed prev, address indexed next);

    // =========================================================================
    // Errors
    // =========================================================================

    error NotOwner();
    error NotAuthorized();
    error ZeroAddress();
    error EpochNotFinalized(uint256 epochId);
    error EpochAlreadyFinalized(uint256 epochId);
    error FYTAlreadyRedeemed(uint256 positionId);
    error VYTAlreadyRedeemed(uint256 positionId);
    error NoFYTBalance(uint256 positionId, address holder);
    error NoVYTBalance(uint256 positionId, address holder);
    error ZeroPositionCount();

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address      _owner,
        address      _authorizedCaller,
        FYToken      _fyToken,
        VYToken      _vyToken,
        IPoolManager _poolManager
    ) {
        if (_owner == address(0))             revert ZeroAddress();
        if (address(_fyToken) == address(0))  revert ZeroAddress();
        if (address(_vyToken) == address(0))  revert ZeroAddress();
        if (address(_poolManager) == address(0)) revert ZeroAddress();

        owner            = _owner;
        authorizedCaller = _authorizedCaller;
        fyToken          = _fyToken;
        vyToken          = _vyToken;
        poolManager      = _poolManager;

        emit OwnershipTransferred(address(0), _owner);
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAuthorized() {
        if (msg.sender != owner && msg.sender != authorizedCaller)
            revert NotAuthorized();
        _;
    }

    // =========================================================================
    // Ownership
    // =========================================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferInitiated(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotAuthorized();
        address prev = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, msg.sender);
    }

    function setAuthorizedCaller(address caller) external onlyOwner {
        address prev = authorizedCaller;
        authorizedCaller = caller;
        emit AuthorizedCallerSet(prev, caller);
    }

    // =========================================================================
    // Settlement ingestion
    // =========================================================================

    /// @notice Record settlement amounts from YieldRouter and snapshot supplies.
    ///
    /// Called by YieldRouter.finalizeEpoch() after transferring fee tokens here.
    /// Snapshots use FYToken.epochPositionCount(epochId) — the count of
    /// positions minted into this epoch, which equals the number of FYT and
    /// VYT tokens respectively.
    function receiveSettlement(
        uint256 epochId,
        address token,
        uint128 fytTotal,
        uint128 vytTotal
    ) external nonReentrant onlyAuthorized {
        if (token == address(0))              revert ZeroAddress();
        if (settlements[epochId].finalized)   revert EpochAlreadyFinalized(epochId);

        // Snapshot position counts at settlement time. Both FYT and VYT have the
        // same count (one per deposit), stored in FYToken.epochPositionCount.
        uint128 positionCount = uint128(fyToken.epochPositionCount(epochId));

        settlements[epochId] = Settlement({
            token:             token,
            fytTotal:          fytTotal,
            vytTotal:          vytTotal,
            fytPositionCount:  positionCount,
            vytPositionCount:  positionCount,
            finalized:         true
        });

        emit SettlementReceived(
            epochId, token, fytTotal, vytTotal, positionCount, positionCount
        );
    }

    // =========================================================================
    // FYT redemption
    // =========================================================================

    /// @notice Burn FYT for a position, remove half its v4 liquidity, and
    ///         collect the fixed fee yield.
    ///
    /// The caller must hold the FYT for `positionId`. The underlying tokens
    /// from the liquidity removal are sent directly to the caller by the v4
    /// PoolManager. The fixed fee payout is transferred from this vault.
    ///
    /// @param positionId  The FYT tokenId to redeem.
    /// @param poolKey     The v4 PoolKey for this position's pool. Must match
    ///                    the poolId stored in FYToken.positions[positionId].
    function redeemFYT(
        uint256        positionId,
        PoolKey calldata poolKey
    ) external nonReentrant {
        FYToken.PositionData memory pos = fyToken.getPosition(positionId);
        uint256 epochId = pos.epochId;

        Settlement storage s = settlements[epochId];
        if (!s.finalized)             revert EpochNotFinalized(epochId);
        if (fytRedeemed[positionId])  revert FYTAlreadyRedeemed(positionId);

        uint256 holderBal = fyToken.balanceOf(msg.sender, positionId);
        if (holderBal == 0)           revert NoFYTBalance(positionId, msg.sender);
        if (s.fytPositionCount == 0)  revert ZeroPositionCount();

        // ── Checks-effects-interactions ──────────────────────────────────────
        fytRedeemed[positionId] = true;

        // Burn FYT.
        fyToken.burn(msg.sender, positionId, holderBal);

        // ── Remove half the v4 liquidity ─────────────────────────────────────
        // MaturityVault is an approved operator of the hook in PoolManager.
        // We call modifyLiquidity as the hook's operator, removing liquidity/2.
        // The PoolManager sends the underlying tokens directly to msg.sender.
        int128 liquidityToRemove = -int128(uint128(pos.liquidity / 2));

        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower:      pos.tickLower,
                tickUpper:      pos.tickUpper,
                liquidityDelta: int256(liquidityToRemove),
                salt:           bytes32(0)
            }),
            abi.encode(msg.sender) // recipient of the underlying tokens
        );

        // ── Fixed fee payout ─────────────────────────────────────────────────
        // Equal per-position: fytTotal / fytPositionCount.
        uint128 feePayout = uint128(
            uint256(s.fytTotal) / uint256(s.fytPositionCount)
        );

        if (feePayout > 0) {
            IERC20(s.token).safeTransfer(msg.sender, feePayout);
        }

        emit FYTRedeemed(
            positionId, msg.sender, feePayout,
            delta.amount0(), delta.amount1()
        );
    }

    // =========================================================================
    // VYT redemption
    // =========================================================================

    /// @notice Burn VYT for a position, remove the other half of its v4
    ///         liquidity, and collect the variable fee yield.
    ///
    /// @param positionId  The VYT tokenId to redeem.
    /// @param poolKey     The v4 PoolKey for this position's pool.
    function redeemVYT(
        uint256          positionId,
        PoolKey calldata poolKey
    ) external nonReentrant {
        // Position metadata is in FYToken — single source of truth.
        FYToken.PositionData memory pos = fyToken.getPosition(positionId);
        uint256 epochId = pos.epochId;

        Settlement storage s = settlements[epochId];
        if (!s.finalized)            revert EpochNotFinalized(epochId);
        if (vytRedeemed[positionId]) revert VYTAlreadyRedeemed(positionId);

        uint256 holderBal = vyToken.balanceOf(msg.sender, positionId);
        if (holderBal == 0)          revert NoVYTBalance(positionId, msg.sender);
        if (s.vytPositionCount == 0) revert ZeroPositionCount();

        // ── Checks-effects-interactions ──────────────────────────────────────
        vytRedeemed[positionId] = true;

        // Burn VYT.
        vyToken.burn(msg.sender, positionId);

        // ── Remove the other half of v4 liquidity ────────────────────────────
        // liquidity is odd numbers: FYT took floor(liq/2), VYT takes the rest.
        uint128 vytLiquidity = pos.liquidity - uint128(pos.liquidity / 2);
        int128  liquidityToRemove = -int128(vytLiquidity);

        (BalanceDelta delta, ) = poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower:      pos.tickLower,
                tickUpper:      pos.tickUpper,
                liquidityDelta: int256(liquidityToRemove),
                salt:           bytes32(0)
            }),
            abi.encode(msg.sender)
        );

        // ── Variable fee payout ──────────────────────────────────────────────
        // Equal per-position: vytTotal / vytPositionCount.
        // vytTotal is 0 in Zone B/C — the burn and liquidity removal still happen.
        uint128 feePayout = uint128(
            uint256(s.vytTotal) / uint256(s.vytPositionCount)
        );

        if (feePayout > 0) {
            IERC20(s.token).safeTransfer(msg.sender, feePayout);
        }

        emit VYTRedeemed(
            positionId, msg.sender, feePayout,
            delta.amount0(), delta.amount1()
        );
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @notice Preview FYT fee payout for a position (does not include liquidity).
    function previewFYTPayout(uint256 positionId)
        external view returns (uint128 feePayout)
    {
        FYToken.PositionData memory pos = fyToken.getPosition(positionId);
        Settlement storage s = settlements[pos.epochId];
        if (!s.finalized || fytRedeemed[positionId]) return 0;
        if (s.fytPositionCount == 0) return 0;
        return uint128(uint256(s.fytTotal) / uint256(s.fytPositionCount));
    }

    /// @notice Preview VYT fee payout for a position.
    function previewVYTPayout(uint256 positionId)
        external view returns (uint128 feePayout)
    {
        FYToken.PositionData memory pos = fyToken.getPosition(positionId);
        Settlement storage s = settlements[pos.epochId];
        if (!s.finalized || vytRedeemed[positionId]) return 0;
        if (s.vytPositionCount == 0) return 0;
        return uint128(uint256(s.vytTotal) / uint256(s.vytPositionCount));
    }
}

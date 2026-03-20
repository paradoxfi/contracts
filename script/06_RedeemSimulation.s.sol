// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20}           from "forge-std/interfaces/IERC20.sol";

import {PoolKey}               from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks}                from "v4-core/interfaces/IHooks.sol";

import {ParadoxHook}   from "../src/core/ParadoxHook.sol";
import {EpochManager}  from "../src/core/EpochManager.sol";
import {YieldRouter}   from "../src/core/YieldRouter.sol";
import {MaturityVault} from "../src/core/MaturityVault.sol";
import {RateOracle}    from "../src/core/RateOracle.sol";
import {FYToken}       from "../src/tokens/FYToken.sol";
import {VYToken}       from "../src/tokens/VYToken.sol";

/// @title RedeemSimulation
/// @notice Local Foundry simulation (NOT for broadcast) that:
///   1. Forks the target chain at the current block.
///   2. Reads position metadata from FYToken (tick range, liquidity, halfNotional).
///   3. Warps block.timestamp to epoch maturity.
///   4. Calls EpochManager.settle() → YieldRouter.finalizeEpoch().
///   5. Redeems FYT: removes liquidity/2 from v4 + collects fixed fee yield.
///   6. Redeems VYT: removes liquidity/2 from v4 + collects variable fee yield.
///   7. Prints a before/after comparison of token balances and principal.
///
/// Token model (post-refactor)
/// ─────────────────────────────────────────────────────────────────────────────
/// FYT and VYT are both keyed by positionId (not epochId).
///   FYT amount = halfNotional  (half the token0-denominated deposit value)
///   VYT amount = 1             (exactly one per position)
///
/// redeemFYT(positionId, poolKey) → removes liquidity/2 + fixed fee yield
/// redeemVYT(positionId, poolKey) → removes liquidity/2 + variable fee yield
///
/// Position metadata (tick range, liquidity, halfNotional, epochId) is stored
/// in FYToken and read by MaturityVault at redemption time.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (required)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   TOKEN_A        address — Pool token A.
///   TOKEN_B        address — Pool token B.
///   PARADOX_HOOK   address — Deployed ParadoxHook.
///   POSITION_ID    uint256 — The positionId (FYT and VYT tokenId).
///   HOLDER         address — Address holding FYT and VYT.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (optional)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   POOL_FEE         uint24  — Pool fee tier. Default: 3000.
///   TICK_SPACING     int24   — Tick spacing. Default: 60.
///   SETTLEMENT_TWAP  uint256 — TWAP for next epoch on auto-roll (WAD). Default: 0.
///   SETTLEMENT_VOL   uint256 — Vol for next epoch on auto-roll (WAD). Default: 0.
///
/// Usage (simulation only — no --broadcast):
///   TOKEN_A=0x... TOKEN_B=0x... PARADOX_HOOK=0x... \
///   POSITION_ID=<n> HOLDER=0x... \
///   forge script script/RedeemSimulation.s.sol --rpc-url $RPC_URL -vvvv
contract RedeemSimulation is Script {
    using PoolIdLibrary   for PoolKey;
    using CurrencyLibrary for Currency;

    struct Config {
        address      holder;
        uint256      positionId;
        Currency     currency0;
        Currency     currency1;
        PoolKey      poolKey;
        PoolId       poolId;
        uint256      settlementTwap;
        uint256      settlementVol;
        // Paradox Fi contracts
        ParadoxHook  hook;
        EpochManager em;
        YieldRouter  yr;
        MaturityVault mv;
        RateOracle   oracle;
        FYToken      fyt;
        VYToken      vyt;
    }

    function run() external {
        Config memory cfg = _loadConfig();

        // ── Resolve position and epoch ─────────────────────────────────────────
        FYToken.PositionData memory pos = cfg.fyt.getPosition(cfg.positionId);
        require(pos.liquidity > 0, "RedeemSimulation: position not found in FYToken");

        uint256 epochId = pos.epochId;
        EpochManager.Epoch memory ep = cfg.em.getEpoch(epochId);
        require(
            ep.status == EpochManager.EpochStatus.ACTIVE,
            "RedeemSimulation: epoch is not ACTIVE"
        );

        _printHeader(cfg, pos, epochId, ep);

        // ── Snapshot balances before ───────────────────────────────────────────
        // Both FYT and VYT are keyed by positionId in the new model.
        uint256 token0BalBefore = IERC20(Currency.unwrap(cfg.currency0)).balanceOf(cfg.holder);
        uint256 fytBalBefore    = cfg.fyt.balanceOf(cfg.holder, cfg.positionId);
        uint256 vytBalBefore    = cfg.vyt.balanceOf(cfg.holder, cfg.positionId);

        _printPreState(cfg, pos, epochId, ep, token0BalBefore, fytBalBefore, vytBalBefore);

        // ── Step 1: Warp to maturity ───────────────────────────────────────────
        console.log("\n[1/4] Warping to epoch maturity...");
        console.log("      current time:", block.timestamp);
        console.log("      maturity:    ", ep.maturity);

        vm.warp(ep.maturity);
        console.log("      warped to:   ", block.timestamp, "  OK");

        // ── Step 2: Settle epoch ───────────────────────────────────────────────
        console.log("\n[2/4] Settling epoch in EpochManager...");

        // settle() is permissionless after maturity.
        uint256 nextEpochId = cfg.em.settle(
            epochId, cfg.settlementTwap, cfg.settlementVol, 0
        );
        console.log("      EpochManager.settle()  OK");
        if (nextEpochId != 0) {
            console.log("      Auto-roll: new epoch:");
            console.logBytes32(bytes32(nextEpochId));
        }

        // ── Step 3: Finalize in YieldRouter ───────────────────────────────────
        console.log("\n[3/4] Finalizing in YieldRouter...");

        uint256 obligation = _computeObligation(ep);

        // finalizeEpoch is onlyAuthorized — prank as authorizedCaller (the hook).
        // Safe in simulation only; would revert in a real broadcast.
        vm.prank(cfg.yr.authorizedCaller());
        YieldRouter.SettlementAmounts memory amounts = cfg.yr.finalizeEpoch(
            epochId, cfg.poolId, Currency.unwrap(cfg.currency0), uint128(obligation)
        );

        console.log("      YieldRouter.finalizeEpoch()  OK");
        console.log("      Zone:          ", _zoneLabel(amounts.zone));
        console.log("      fytFeeAmount:  ", amounts.fytAmount , "tokens");
        console.log("      vytFeeAmount:  ", amounts.vytAmount , "tokens");

        // ── Step 4a: Redeem FYT ───────────────────────────────────────────────
        _redeemFYT(cfg, pos);

        // ── Step 4b: Redeem VYT ───────────────────────────────────────────────
        _redeemVYT(cfg, pos);

        // ── Final summary ─────────────────────────────────────────────────────
        _printSummary(cfg, pos, epochId, ep, token0BalBefore, fytBalBefore, vytBalBefore, obligation);
    }

    function _redeemFYT(
        Config memory cfg,
        FYToken.PositionData memory pos
    ) internal {
        console.log("\n[4a/4] Redeeming FYT...");

        uint256 fytHolding = cfg.fyt.balanceOf(cfg.holder, cfg.positionId);
        if (fytHolding == 0) {
            console.log("       SKIP: holder has no FYT for positionId", cfg.positionId);
        } else {
            // Preview: fee payout only (principal returned via modifyLiquidity).
            uint128 fytFeePreview = cfg.mv.previewFYTPayout(cfg.positionId);
            uint128 halfLiquidity = uint128(pos.liquidity / 2);

            console.log("       FYT balance:           ", fytHolding , "(halfNotional)");
            console.log("       Expected fee payout:   ", fytFeePreview , "tokens");
            console.log("       Expected liq removal:  ", halfLiquidity, "units (liquidity/2)");

            vm.prank(cfg.holder);
            cfg.mv.redeemFYT(cfg.positionId, cfg.poolKey);

            console.log("       FYT after burn:        ",
                cfg.fyt.balanceOf(cfg.holder, cfg.positionId), "(expect 0)");
            console.log("       redeemFYT()  OK");
        }
    }

    function _redeemVYT(
        Config memory cfg,
        FYToken.PositionData memory pos
    ) internal {
        console.log("\n[4b/4] Redeeming VYT...");

        uint256 vytHolding = cfg.vyt.balanceOf(cfg.holder, cfg.positionId);
        if (vytHolding == 0) {
            console.log("       SKIP: holder has no VYT for positionId", cfg.positionId);
        } else {
            uint128 vytFeePreview = cfg.mv.previewVYTPayout(cfg.positionId);
            // VYT removes the remainder: liquidity - floor(liquidity/2)
            uint128 vytLiquidity  = pos.liquidity - uint128(pos.liquidity / 2);

            console.log("       VYT balance:           ", vytHolding, "(expect 1)");
            console.log("       Expected fee payout:   ", vytFeePreview , "tokens");
            console.log("       Expected liq removal:  ", vytLiquidity, "units (remaining half)");

            vm.prank(cfg.holder);
            cfg.mv.redeemVYT(cfg.positionId, cfg.poolKey);

            console.log("       VYT after burn:        ",
                cfg.vyt.balanceOf(cfg.holder, cfg.positionId), "(expect 0)");
            console.log("       redeemVYT()  OK");
        }   
    }

    // =========================================================================
    // Config
    // =========================================================================

    function _loadConfig() private view returns (Config memory cfg) {
        cfg.holder     = vm.envAddress("HOLDER");
        cfg.positionId = vm.envUint("POSITION_ID");

        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        cfg.currency0 = Currency.wrap(t0);
        cfg.currency1 = Currency.wrap(t1);

        uint24 fee        = uint24(vm.envOr("POOL_FEE",     uint256(3000)));
        int24  tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        cfg.hook = ParadoxHook(payable(vm.envAddress("PARADOX_HOOK")));
        cfg.poolKey = PoolKey({
            currency0:   cfg.currency0,
            currency1:   cfg.currency1,
            fee:         fee,
            tickSpacing: tickSpacing,
            hooks:       IHooks(address(cfg.hook))
        });
        cfg.poolId = cfg.poolKey.toId();

        // Read core contracts from hook immutables.
        cfg.em     = cfg.hook.epochManager();
        cfg.yr     = cfg.hook.yieldRouter();
        cfg.oracle = cfg.hook.rateOracle();
        cfg.fyt    = cfg.hook.fyt();
        cfg.vyt    = cfg.hook.vyt();

        // MaturityVault from YieldRouter storage.
        cfg.mv = MaturityVault(payable(cfg.yr.maturityVault()));

        cfg.settlementTwap = vm.envOr("SETTLEMENT_TWAP", uint256(0));
        cfg.settlementVol  = vm.envOr("SETTLEMENT_VOL",  uint256(0));
    }

    // =========================================================================
    // Obligation helper (mirrors FixedRateMath.computeObligation)
    // =========================================================================

    function _computeObligation(EpochManager.Epoch memory ep)
        private pure returns (uint256)
    {
        if (ep.totalNotional == 0) return 0;
        uint64 duration = ep.maturity - ep.startTime;
        uint256 step1 = (uint256(ep.totalNotional) * uint256(ep.fixedRate)) ;
        return (step1 * uint256(duration)) / (365 days);
    }

    // =========================================================================
    // Print helpers
    // =========================================================================

    function _printHeader(
        Config memory cfg,
        FYToken.PositionData memory pos,
        uint256 epochId,
        EpochManager.Epoch memory ep
    ) private view {
        console.log("");
        console.log("==============================================================");
        console.log("  Paradox Fi Redeem Simulation (LOCAL ONLY)");
        console.log("==============================================================");
        console.log("  Holder:        ", cfg.holder);
        console.log("  PositionId:    ", cfg.positionId);
        console.log("  token0:        ", Currency.unwrap(cfg.currency0));
        console.log("  ParadoxHook:   ", address(cfg.hook));
        console.log("  MaturityVault: ", address(cfg.mv));
        console.log("--------------------------------------------------------------");
        console.log("  [POSITION DATA from FYToken]");
        console.log("  tickLower:     ", uint256(uint24(pos.tickLower)));
        console.log("  tickUpper:     ", uint256(uint24(pos.tickUpper)));
        console.log("  liquidity:     ", pos.liquidity);
        console.log("  halfNotional:  ", pos.halfNotional , "tokens");
        console.log("  epochId:       ");
        console.logBytes32(bytes32(epochId));
        console.log("--------------------------------------------------------------");
        console.log("  [EPOCH DATA]");
        console.log("  fixedRate:     ", ep.fixedRate / 1e14, "bps annualised");
        console.log("  maturity:      ", ep.maturity);
        console.log("  totalNotional: ", ep.totalNotional , "tokens");
        console.log("  positions:     ", cfg.fyt.epochPositionCount(epochId));
        console.log("--------------------------------------------------------------");
    }

    function _printPreState(
        Config memory cfg,
        FYToken.PositionData memory pos,
        uint256 epochId,
        EpochManager.Epoch memory ep,
        uint256 token0Bal,
        uint256 fytBal,
        uint256 vytBal
    ) private view {
        YieldRouter.EpochBalance memory bal = cfg.yr.getEpochBalance(epochId);
        uint256 obligation = _computeObligation(ep);
        uint128 buffer     = cfg.yr.getReserveBuffer(cfg.poolId);

        uint256 coveragePct = obligation > 0
            ? (uint256(bal.fixedAccrued) * 100) / obligation : 100;

        YieldRouter.SettlementAmounts memory preview =
            cfg.yr.previewFinalization(epochId, cfg.poolId, uint128(obligation));

        console.log("\n  [PRE-SETTLEMENT STATE]");
        console.log("  token0 balance:       ", token0Bal , "tokens");
        console.log("  FYT balance:          ", fytBal , "(halfNotional, positionId key)");
        console.log("  VYT balance:          ", vytBal, "(1 = held, positionId key)");
        console.log("  ---");
        console.log("  fixedAccrued:         ", bal.fixedAccrued , "tokens");
        console.log("  variableAccrued:      ", bal.variableAccrued , "tokens");
        console.log("  fixedObligation:      ", obligation , "tokens");
        console.log("  coverage ratio:       ", coveragePct, "%%");
        console.log("  reserveBuffer:        ", buffer , "tokens");
        console.log("  projected zone:       ", _zoneLabel(preview.zone));
        console.log("  ---");
        console.log("  [Projected redemption for this position]");

        _printpart2(cfg, pos, epochId, obligation);
    }

    function _printpart2(
        Config memory cfg,
        FYToken.PositionData memory pos,
        uint256 epochId,
        uint256 obligation
    ) internal view {
        YieldRouter.SettlementAmounts memory preview =
            cfg.yr.previewFinalization(epochId, cfg.poolId, uint128(obligation));

        // Per-position fee payout = total / positionCount
        uint256 posCount = cfg.fyt.epochPositionCount(epochId);
        uint256 fytFeeEst = posCount > 0 ? uint256(preview.fytAmount) / posCount : 0;
        uint256 vytFeeEst = posCount > 0 ? uint256(preview.vytAmount) / posCount : 0;
        console.log("  FYT fee est:          ", fytFeeEst , "tokens");
        console.log("  FYT principal (half): ", pos.halfNotional , "tokens (approx)");
        console.log("  VYT fee est:          ", vytFeeEst , "tokens");
        console.log("  VYT principal (half): ", pos.halfNotional , "tokens (approx)");
        console.log("  Total (approx):       ",
            (fytFeeEst + vytFeeEst + uint256(pos.halfNotional) * 2) , "tokens");
        console.log("--------------------------------------------------------------");
    }

    function _printSummary(
        Config memory cfg,
        FYToken.PositionData memory pos,
        uint256 epochId,
        EpochManager.Epoch memory ep,
        uint256 token0BalBefore,
        uint256 fytBalBefore,
        uint256 vytBalBefore,
        uint256 obligation
    ) private view {
        uint256 token0BalAfter = IERC20(Currency.unwrap(cfg.currency0)).balanceOf(cfg.holder);
        uint256 fytBalAfter    = cfg.fyt.balanceOf(cfg.holder, cfg.positionId);
        uint256 vytBalAfter    = cfg.vyt.balanceOf(cfg.holder, cfg.positionId);

        int256 token0Delta = int256(token0BalAfter) - int256(token0BalBefore);

        // ROI on FYT side: fee payout relative to halfNotional principal.
        // halfNotional is the deposit-time principal for the FYT holder.
        uint256 roiBps = pos.halfNotional > 0 && token0Delta > 0
            ? (uint256(token0Delta) * 10_000) / uint256(pos.halfNotional * 2)
            : 0;
        // Note: we use halfNotional * 2 as the total principal denominator
        // since both FYT and VYT principal is returned and token0Delta captures both.

        console.log("\n==============================================================");
        console.log("  SIMULATION RESULTS");
        console.log("==============================================================");
        console.log("  token0 before:      ", token0BalBefore , "tokens");
        console.log("  token0 after:       ", token0BalAfter  , "tokens");
        if (token0Delta >= 0) {
            console.log("  token0 received:   +", uint256(token0Delta) , "tokens");
        } else {
            console.log("  token0 change:     -", uint256(-token0Delta) , "tokens");
        }
        console.log("  ---");
        console.log("  FYT burned:         ", fytBalBefore , "-> 0 (halfNotional burned)");
        console.log("  VYT burned:         ", vytBalBefore, "-> 0");
        console.log("  FYT after:          ", fytBalAfter,  "(expect 0)");
        console.log("  VYT after:          ", vytBalAfter,  "(expect 0)");
        console.log("  ---");
        console.log("  Full liquidity:     ", pos.liquidity, "units removed total");
        console.log("  Locked rate:        ", ep.fixedRate / 1e14, "bps annualised");
        console.log("  Fixed obligation:   ", obligation , "tokens (epoch total)");
        console.log("  ROI (fee / principal):", roiBps, "bps");
        console.log("==============================================================");
        console.log("  Simulation complete. No transactions were broadcast.");
        console.log("==============================================================");
    }

    function _zoneLabel(uint8 zone) private pure returns (string memory) {
        if (zone == 0) return "A (full coverage FYT + VYT earn fees)";
        if (zone == 1) return "B (buffer rescue FYT full, VYT zero fees)";
        return                "C (haircut FYT partial, VYT zero fees)";
    }
}

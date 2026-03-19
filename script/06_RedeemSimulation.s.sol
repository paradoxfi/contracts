// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20}           from "forge-std/interfaces/IERC20.sol";

import {PoolKey}               from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks}                from "v4-core/interfaces/IHooks.sol";

import {ParadoxHook}    from "../src/core/ParadoxHook.sol";
import {EpochManager}   from "../src/core/EpochManager.sol";
import {PositionManager as PdxPositionManager} from "../src/core/PositionManager.sol";
import {YieldRouter}    from "../src/core/YieldRouter.sol";
import {MaturityVault}  from "../src/core/MaturityVault.sol";
import {RateOracle}     from "../src/core/RateOracle.sol";
import {FYToken}        from "../src/tokens/FYToken.sol";
import {VYToken}        from "../src/tokens/VYToken.sol";

/// @title RedeemSimulation
/// @notice Local Foundry simulation (NOT for broadcast) that:
///   1. Forks the target chain state at the current block.
///   2. Warps block.timestamp to epoch maturity.
///   3. Calls EpochManager.settle() → YieldRouter.finalizeEpoch() to push
///      funds to MaturityVault.
///   4. Redeems FYT for the fixed tranche payout.
///   5. Redeems VYT for the variable tranche payout.
///   6. Prints a before/after balance comparison.
///
/// This script uses vm.prank to impersonate privileged callers (the hook's
/// authorizedCaller and the deployer) without needing their private keys.
/// It is ONLY valid for local simulation — never broadcast.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (required)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   TOKEN_A           address — Pool token A.
///   TOKEN_B           address — Pool token B.
///   PARADOX_HOOK      address — Deployed ParadoxHook.
///   POSITION_ID       uint256 — The ERC-721 positionId to redeem VYT for.
///   HOLDER            address — Address holding FYT and VYT (the LP wallet).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (optional)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   POOL_FEE          uint24  — Pool fee tier. Default: 3000.
///   TICK_SPACING      int24   — Pool tick spacing. Default: 60.
///   SETTLEMENT_TWAP   uint256 — TWAP for auto-roll successor (WAD). Default: 0.
///   SETTLEMENT_VOL    uint256 — Volatility for auto-roll successor (WAD). Default: 0.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Usage (local fork — no broadcast)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   TOKEN_A=0x... TOKEN_B=0x... PARADOX_HOOK=0x... \
///   POSITION_ID=<n> HOLDER=0x... \
///   forge script script/RedeemSimulation.s.sol \
///     --rpc-url $RPC_URL \
///     -vvvv
///
/// Note: omit --broadcast. The script uses vm.prank / vm.warp which only
/// work in simulation mode. All state changes are local to the Foundry EVM.

contract RedeemSimulation is Script {
    using PoolIdLibrary   for PoolKey;
    using CurrencyLibrary for Currency;

    struct Config {
        address holder;
        Currency currency0;
        Currency currency1;
        PoolKey  poolKey;
        PoolId   poolId;
        uint256  positionId;
        uint256  settlementTwap;
        uint256  settlementVol;
        // Paradox Fi contracts
        ParadoxHook        hook;
        EpochManager       em;
        PdxPositionManager pdxPM;
        YieldRouter        yr;
        MaturityVault      mv;
        RateOracle         oracle;
        FYToken            fyt;
        VYToken            vyt;
    }

    function run() external {
        Config memory cfg = _loadConfig();

        // ── Resolve active epoch ───────────────────────────────────────────────
        uint256 epochId = cfg.em.activeEpochIdFor(cfg.poolId);
        require(epochId != 0, "RedeemSimulation: no active epoch");

        EpochManager.Epoch memory ep = cfg.em.getEpoch(epochId);
        require(
            ep.status == EpochManager.EpochStatus.ACTIVE,
            "RedeemSimulation: epoch is not ACTIVE"
        );

        _printHeader(cfg, epochId, ep);

        // ── Snapshot balances before ───────────────────────────────────────────
        uint256 tokenBalBefore = IERC20(Currency.unwrap(cfg.currency0)).balanceOf(cfg.holder);
        uint256 fytBalBefore   = cfg.fyt.balanceOf(cfg.holder, epochId);
        uint256 vytBalBefore   = cfg.vyt.balanceOf(cfg.holder, cfg.positionId);

        _printPreState(cfg, epochId, ep, tokenBalBefore, fytBalBefore, vytBalBefore);

        // ── Step 1: Warp to maturity ───────────────────────────────────────────
        console.log("\n[1/4] Warping to epoch maturity...");
        console.log("      current time:", block.timestamp);
        console.log("      maturity:    ", ep.maturity);

        vm.warp(ep.maturity);

        console.log("      warped to:   ", block.timestamp, "OK");

        // ── Step 2: Settle epoch ───────────────────────────────────────────────
        console.log("\n[2/4] Settling epoch in EpochManager...");

        // settle() is permissionless after maturity — no prank needed.
        uint256 nextEpochId = cfg.em.settle(
            epochId,
            cfg.settlementTwap,
            cfg.settlementVol,
            0
        );

        console.log("      EpochManager.settle() OK");
        if (nextEpochId != 0) {
            console.log("      Auto-roll: new epoch opened:");
            console.logBytes32(bytes32(nextEpochId));
        }

        // ── Step 3: Finalize in YieldRouter ───────────────────────────────────
        console.log("\n[3/4] Finalizing in YieldRouter...");
        console.log("      (transfers funds to MaturityVault + records settlement)");

        uint256 obligation = _computeObligation(ep);

        // finalizeEpoch is onlyAuthorized — prank as the hook's authorized caller.
        // In simulation this is safe; it would revert in a real broadcast.
        address authorizedCaller = cfg.yr.authorizedCaller();
        vm.prank(authorizedCaller);
        YieldRouter.SettlementAmounts memory amounts =
            cfg.yr.finalizeEpoch(epochId, cfg.poolId, Currency.unwrap(cfg.currency0), uint128(obligation));

        console.log("      YieldRouter.finalizeEpoch() OK");
        console.log("      Zone:        ", _zoneLabel(amounts.zone));
        console.log("      fytAmount:   ", amounts.fytAmount / 1e18, "tokens");
        console.log("      vytAmount:   ", amounts.vytAmount / 1e18, "tokens");
        console.log("      MaturityVault balance after:",
            IERC20(Currency.unwrap(cfg.currency0)).balanceOf(address(cfg.mv)) / 1e18, "tokens");

        // ── Step 4: Redeem FYT ────────────────────────────────────────────────
        console.log("\n[4a/4] Redeeming FYT...");

        uint256 fytHolding = cfg.fyt.balanceOf(cfg.holder, epochId);
        if (fytHolding == 0) {
            console.log("       SKIP: holder has no FYT for this epoch");
        } else {
            uint128 fytPreview = cfg.mv.previewFYTPayout(epochId, cfg.holder);
            console.log("       FYT holding:         ", fytHolding / 1e18, "FYT");
            console.log("       Expected payout:     ", fytPreview / 1e18, "tokens");

            vm.prank(cfg.holder);
            cfg.mv.redeemFYT(epochId);

            uint256 fytHoldingAfter = cfg.fyt.balanceOf(cfg.holder, epochId);
            console.log("       FYT after redemption:", fytHoldingAfter, "(expect 0)");
            console.log("       redeemFYT() OK");
        }

        // ── Step 5: Redeem VYT ────────────────────────────────────────────────
        _printHoldings(cfg, epochId, ep, tokenBalBefore, fytBalBefore, vytBalBefore, obligation);

        // ── Final summary ─────────────────────────────────────────────────────
        _printSummary(cfg, epochId, ep, tokenBalBefore, fytBalBefore, vytBalBefore, obligation);
    }

    function _printHoldings(
        Config memory cfg,
        uint256 epochId,
        EpochManager.Epoch memory ep,
        uint256 tokenBalBefore,
        uint256 fytBalBefore,
        uint256 vytBalBefore,
        uint256 obligation
    ) internal {
        // ── Step 5: Redeem VYT ────────────────────────────────────────────────
        console.log("\n[4b/4] Redeeming VYT...");

        uint256 vytHolding = cfg.vyt.balanceOf(cfg.holder, cfg.positionId);
        if (vytHolding == 0) {
            console.log("       SKIP: holder has no VYT for positionId", cfg.positionId);
        } else {
            uint128 vytPreview = cfg.mv.previewVYTPayout(epochId, cfg.positionId);
            console.log("       VYT holding:         ", vytHolding, "(expect 1)");
            console.log("       Expected payout:     ", vytPreview / 1e18, "tokens");

            vm.prank(cfg.holder);
            cfg.mv.redeemVYT(epochId, cfg.positionId);

            uint256 vytHoldingAfter = cfg.vyt.balanceOf(cfg.holder, cfg.positionId);
            console.log("       VYT after redemption:", vytHoldingAfter, "(expect 0)");
            console.log("       redeemVYT() OK");
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
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        cfg.hook = ParadoxHook(payable(vm.envAddress("PARADOX_HOOK")));
        cfg.poolKey = PoolKey({
            currency0:   cfg.currency0,
            currency1:   cfg.currency1,
            fee:         fee,
            tickSpacing: tickSpacing,
            hooks:       IHooks(address(cfg.hook))
        });
        cfg.poolId = cfg.poolKey.toId();

        cfg.em    = cfg.hook.epochManager();
        cfg.pdxPM = cfg.hook.positionManager();
        cfg.yr    = cfg.hook.yieldRouter();
        cfg.oracle = cfg.hook.rateOracle();
        cfg.mv    = MaturityVault(payable(address(cfg.yr.maturityVault())));
        cfg.fyt   = FYToken(address(cfg.mv.fyToken()));
        cfg.vyt   = VYToken(address(cfg.mv.vyToken()));

        cfg.settlementTwap = vm.envOr("SETTLEMENT_TWAP", uint256(0));
        cfg.settlementVol  = vm.envOr("SETTLEMENT_VOL",  uint256(0));
    }

    // =========================================================================
    // Obligation helper (mirrors FixedRateMath.computeObligation)
    // =========================================================================

    function _computeObligation(EpochManager.Epoch memory ep)
        private pure
        returns (uint256)
    {
        if (ep.totalNotional == 0) return 0;
        uint64 duration = ep.maturity - ep.startTime;
        uint256 step1 = (uint256(ep.totalNotional) * uint256(ep.fixedRate)) / 1e18;
        return (step1 * uint256(duration)) / (365 days);
    }

    // =========================================================================
    // Print helpers
    // =========================================================================

    function _printHeader(
        Config memory cfg,
        uint256 epochId,
        EpochManager.Epoch memory ep
    ) private pure {
        console.log("");
        console.log("==============================================================");
        console.log("  Paradox Fi Redeem Simulation (LOCAL ONLY)");
        console.log("==============================================================");
        console.log("  Holder:       ", cfg.holder);
        console.log("  PositionId:   ", cfg.positionId);
        console.log("  token0:       ", Currency.unwrap(cfg.currency0));
        console.log("  ParadoxHook:  ", address(cfg.hook));
        console.log("  EpochManager: ", address(cfg.em));
        console.log("  YieldRouter:  ", address(cfg.yr));
        console.log("  MaturityVault:", address(cfg.mv));
        console.log("--------------------------------------------------------------");
        console.log("  epochId:");
        console.logBytes32(bytes32(epochId));
        console.log("  fixedRate:    ", ep.fixedRate / 1e14, "bps annualised");
        console.log("  maturity:     ", ep.maturity);
        console.log("  totalNotional:", ep.totalNotional / 1e18, "tokens");
        console.log("--------------------------------------------------------------");
    }

    function _printPreState(
        Config memory cfg,
        uint256 epochId,
        EpochManager.Epoch memory ep,
        uint256 tokenBal,
        uint256 fytBal,
        uint256 vytBal
    ) private view {
        YieldRouter.EpochBalance memory bal = cfg.yr.getEpochBalance(epochId);
        uint256 obligation = _computeObligation(ep);
        uint128 buffer     = cfg.yr.getReserveBuffer(cfg.poolId);

        uint256 coveragePct = obligation > 0
            ? (uint256(bal.fixedAccrued) * 100) / obligation
            : 100;

        YieldRouter.SettlementAmounts memory preview =
            cfg.yr.previewFinalization(epochId, cfg.poolId, uint128(obligation));

        console.log("\n  [PRE-SETTLEMENT STATE]");
        console.log("  token0 balance:    ", tokenBal / 1e18, "tokens");
        console.log("  FYT balance:       ", fytBal / 1e18, "FYT");
        console.log("  VYT balance:       ", vytBal);
        console.log("  ---");
        console.log("  fixedAccrued:      ", bal.fixedAccrued / 1e18, "tokens");
        console.log("  variableAccrued:   ", bal.variableAccrued / 1e18, "tokens");
        console.log("  fixedObligation:   ", obligation / 1e18, "tokens");
        console.log("  coverage ratio:    ", coveragePct, "%%");
        console.log("  reserveBuffer:     ", buffer / 1e18, "tokens");
        console.log("  projected zone:    ", _zoneLabel(preview.zone));
        console.log("  projected FYT out: ", preview.fytAmount / 1e18, "tokens");
        console.log("  projected VYT out: ", preview.vytAmount / 1e18, "tokens");
        console.log("--------------------------------------------------------------");
    }

    function _printSummary(
        Config memory cfg,
        uint256 epochId,
        EpochManager.Epoch memory ep,
        uint256 tokenBalBefore,
        uint256 fytBalBefore,
        uint256 vytBalBefore,
        uint256 obligation
    ) private view {
        uint256 tokenBalAfter = IERC20(Currency.unwrap(cfg.currency0)).balanceOf(cfg.holder);
        uint256 fytBalAfter   = cfg.fyt.balanceOf(cfg.holder, epochId);
        uint256 vytBalAfter   = cfg.vyt.balanceOf(cfg.holder, cfg.positionId);

        int256  tokenDelta  = int256(tokenBalAfter) - int256(tokenBalBefore);

        // ROI: (payout / notional_share) where notional_share = (fytBefore / fytSupply) * totalNotional
        uint256 fytSupply     = cfg.fyt.totalSupply(epochId);
        uint256 notionalShare = fytSupply > 0
            ? (fytBalBefore * ep.totalNotional) / fytSupply
            : 0;
        uint256 roiBps = notionalShare > 0 && tokenDelta > 0
            ? (uint256(tokenDelta) * 10_000) / notionalShare
            : 0;

        console.log("\n==============================================================");
        console.log("  SIMULATION RESULTS");
        console.log("==============================================================");
        console.log("  token0 before:     ", tokenBalBefore / 1e18, "tokens");
        console.log("  token0 after:      ", tokenBalAfter  / 1e18, "tokens");
        if (tokenDelta >= 0) {
            console.log("  token0 received:  +", uint256(tokenDelta) / 1e18, "tokens");
        } else {
            console.log("  token0 change:    -", uint256(-tokenDelta) / 1e18, "tokens");
        }
        console.log("  ---");
        console.log("  FYT before:        ", fytBalBefore / 1e18);
        console.log("  FYT after:         ", fytBalAfter  / 1e18, "(burned)");
        console.log("  VYT before:        ", vytBalBefore);
        console.log("  VYT after:         ", vytBalAfter, "(burned)");
        console.log("  ---");
        console.log("  Fixed obligation:  ", obligation / 1e18, "tokens");
        console.log("  Total received:    ");
        console.logInt(tokenDelta);
        console.log("  Effective ROI:     ", roiBps, "bps on notional share");
        console.log("  Locked rate was:   ", ep.fixedRate / 1e14, "bps annualised");
        console.log("==============================================================");
        console.log("  Simulation complete. No transactions were broadcast.");
        console.log("==============================================================");
    }

    function _zoneLabel(uint8 zone) private pure returns (string memory) {
        if (zone == 0) return "A full coverage (FYT full + VYT surplus)";
        if (zone == 1) return "B buffer rescue (FYT full, VYT zero)";
        return                "C haircut (FYT partial, VYT zero)";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20}           from "forge-std/interfaces/IERC20.sol";

import {IPoolManager}              from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}                   from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary}     from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks}                    from "v4-core/interfaces/IHooks.sol";
import {TickMath}                  from "v4-core/libraries/TickMath.sol";
import {SwapParams}                from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest}              from "v4-core/test/PoolSwapTest.sol";

import {ParadoxHook}   from "../src/core/ParadoxHook.sol";
import {EpochManager}  from "../src/core/EpochManager.sol";
import {YieldRouter}   from "../src/core/YieldRouter.sol";
import {MaturityVault} from "../src/core/MaturityVault.sol";
import {FYToken}       from "../src/tokens/FYToken.sol";
import {VYToken}       from "../src/tokens/VYToken.sol";

/// @title Demo
/// @notice Live testnet demo. Assumes a pool has been initialized via
///         CreatePool.s.sol and the deployer holds FYT + VYT for a position.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Token model (post-refactor)
/// ─────────────────────────────────────────────────────────────────────────────
///
/// FYT and VYT are now both keyed by positionId (not epochId).
///   FYT amount = halfNotional  — half the LP's token0-denominated value
///   VYT amount = 1             — exactly one per position
///
/// At maturity:
///   redeemFYT(positionId) → removes liquidity/2 from v4 + fixed fee yield
///   redeemVYT(positionId) → removes liquidity/2 from v4 + variable fee yield
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (required)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   KEY            uint256 — Deployer private key.
///   TOKEN_A        address — Pool token A.
///   TOKEN_B        address — Pool token B.
///   PARADOX_HOOK   address — Deployed ParadoxHook.
///   POSITION_ID    uint256 — The positionId minted at deposit (FYT + VYT tokenId).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (optional)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   SWAP_COUNT     uint256 — Number of swaps. Default: 5.
///   SWAP_AMOUNT    uint256 — Tokens per swap. Default: 1_000e18.
///   POOL_FEE       uint24  — Pool fee tier. Default: 3000.
///   TICK_SPACING   int24   — Pool tick spacing. Default: 60.
///   POOL_SWAP_TEST address — PoolSwapTest address. Default: Unichain Sepolia.
///   POOL_MANAGER   address — PoolManager address. Default: Unichain Sepolia.
///
/// Usage:
///   KEY=<pk> TOKEN_A=0x... TOKEN_B=0x... PARADOX_HOOK=0x... POSITION_ID=<n> \
///   forge script script/Demo.s.sol --rpc-url $RPC_URL --broadcast -vvvv
contract Demo is Script {
    using PoolIdLibrary   for PoolKey;
    using CurrencyLibrary for Currency;

    address constant POOL_SWAP_TEST_DEFAULT = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;
    address constant POOL_MANAGER_DEFAULT   = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    struct Config {
        uint256      deployerPrivKey;
        address      deployer;
        address      poolSwapTest;
        address      poolManager;
        Currency     currency0;
        Currency     currency1;
        PoolKey      poolKey;
        PoolId       poolId;
        // Paradox Fi contracts (read from hook immutables / vault)
        ParadoxHook  hook;
        EpochManager em;
        YieldRouter  yr;
        MaturityVault mv;
        FYToken      fyt;
        VYToken      vyt;
        // Scenario params
        uint256      positionId;
        uint256      swapCount;
        uint256      swapAmount;
    }

    function run() external {
        Config memory cfg = _loadConfig();

        _printHeader(cfg);

        // ── 1. Read position and epoch state ─────────────────────────────────
        FYToken.PositionData memory pos = cfg.fyt.getPosition(cfg.positionId);
        (uint256 epochId, EpochManager.Epoch memory ep) = _readEpochState(cfg);

        _printPositionState(cfg, pos);
        _printEpochState(epochId, ep, cfg);

        // ── 2. Read pre-swap token balances ───────────────────────────────────
        // Both FYT and VYT are keyed by positionId in the new model.
        uint256 fytBalBefore = cfg.fyt.balanceOf(cfg.deployer, cfg.positionId);
        uint256 vytBalBefore = cfg.vyt.balanceOf(cfg.deployer, cfg.positionId);

        _printTokenBalances(epochId, cfg, fytBalBefore, vytBalBefore);

        // ── 3. Execute swaps ──────────────────────────────────────────────────
        vm.startBroadcast(cfg.deployerPrivKey);
        _approveSwapRouter(cfg);
        for (uint256 i = 0; i < cfg.swapCount; i++) {
            _executeSwap(cfg, i);
        }
        vm.stopBroadcast();

        // ── 4. Read accounting state post-swap ────────────────────────────────
        _printAccountingState(epochId, ep, cfg);

        // ── 5. Preview FYT + VYT payouts ─────────────────────────────────────
        _printPayoutPreview(cfg, pos, epochId, ep);

        console.log("");
        console.log("Demo complete. Run RedeemSimulation.s.sol locally to");
        console.log("simulate maturity and redemption without broadcasting.");
    }

    // =========================================================================
    // Config
    // =========================================================================

    function _loadConfig() private view returns (Config memory cfg) {
        cfg.deployerPrivKey = vm.envUint("KEY");
        cfg.deployer        = vm.addr(cfg.deployerPrivKey);
        cfg.poolSwapTest    = vm.envOr("POOL_SWAP_TEST", POOL_SWAP_TEST_DEFAULT);
        cfg.poolManager     = vm.envOr("POOL_MANAGER",   POOL_MANAGER_DEFAULT);

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

        // Core contracts from hook immutables.
        cfg.em  = cfg.hook.epochManager();
        cfg.yr  = cfg.hook.yieldRouter();
        cfg.fyt = cfg.hook.fyt();
        cfg.vyt = cfg.hook.vyt();

        // MaturityVault from YieldRouter storage.
        cfg.mv = MaturityVault(payable(cfg.yr.maturityVault()));

        cfg.positionId = vm.envUint("POSITION_ID");
        cfg.swapCount  = vm.envOr("SWAP_COUNT",  uint256(5));
        cfg.swapAmount = vm.envOr("SWAP_AMOUNT", uint256(1_000e18));
    }

    // =========================================================================
    // State readers
    // =========================================================================

    function _readEpochState(Config memory cfg)
        private view
        returns (uint256 epochId, EpochManager.Epoch memory ep)
    {
        epochId = cfg.em.activeEpochIdFor(cfg.poolId);
        require(epochId != 0, "Demo: no active epoch run CreatePool first");
        ep = cfg.em.getEpoch(epochId);
    }

    // =========================================================================
    // Swap execution
    // =========================================================================

    function _approveSwapRouter(Config memory cfg) private {
        IERC20(Currency.unwrap(cfg.currency0)).approve(cfg.poolSwapTest, type(uint256).max);
        IERC20(Currency.unwrap(cfg.currency1)).approve(cfg.poolSwapTest, type(uint256).max);
        console.log("  Tokens approved to PoolSwapTest");
    }

    function _executeSwap(Config memory cfg, uint256 i) private {
        bool zeroForOne = i % 2 == 0;

        SwapParams memory params = SwapParams({
            zeroForOne:        zeroForOne,
            amountSpecified:   -int256(cfg.swapAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims:      false,
            settleUsingBurn: false
        });

        PoolSwapTest(cfg.poolSwapTest).swap(cfg.poolKey, params, testSettings, "");

        console.log(string.concat(
            "  Swap ", _uint2str(i + 1), "/", _uint2str(cfg.swapCount),
            " | ", zeroForOne ? "token0->token1" : "token1->token0",
            " | ", _uint2str(cfg.swapAmount), " tokens"
        ));
    }

    // =========================================================================
    // Print helpers
    // =========================================================================

    function _printHeader(Config memory cfg) private view {
        console.log("");
        console.log("==============================================================");
        console.log("  Paradox Fi Live Demo");
        console.log("==============================================================");
        console.log("  Deployer:    ", cfg.deployer);
        console.log("  token0:      ", Currency.unwrap(cfg.currency0));
        console.log("  token1:      ", Currency.unwrap(cfg.currency1));
        console.log("  PoolSwapTest:", cfg.poolSwapTest);
        console.log("  ParadoxHook: ", address(cfg.hook));
        console.log("  PositionId:  ", cfg.positionId);
        console.log("  Swaps:       ", cfg.swapCount);
        console.log("  Swap amount: ", cfg.swapAmount, "tokens each");
        console.log("--------------------------------------------------------------");
    }

    function _printPositionState(
        Config memory cfg,
        FYToken.PositionData memory pos
    ) private view {
        console.log("");
        console.log("  [POSITION DATA]");
        console.log("  positionId:   ", cfg.positionId);
        console.log("  poolId:       ");
        console.logBytes32(pos.poolId);
        console.log("  tickLower:    ", uint256(uint24(pos.tickLower)));
        console.log("  tickUpper:    ", uint256(uint24(pos.tickUpper)));
        console.log("  liquidity:    ", pos.liquidity, "units");
        console.log("  halfNotional: ", pos.halfNotional, "tokens");
        console.log("  epochId:      ");
        console.logBytes32(bytes32(pos.epochId));
        console.log("--------------------------------------------------------------");
    }

    function _printEpochState(
        uint256 epochId,
        EpochManager.Epoch memory ep,
        Config memory cfg
    ) private view {
        uint256 obligation = cfg.em.currentObligation(epochId);
        uint256 timeLeft   = ep.maturity > block.timestamp
            ? ep.maturity - block.timestamp : 0;

        console.log("");
        console.log("  [EPOCH STATE]");
        console.log("  epochId:          ");
        console.logBytes32(bytes32(epochId));
        console.log("  fixedRate (bps):  ", ep.fixedRate / 1e14);
        console.log("  maturity:         ", ep.maturity);
        console.log("  time left:        ", timeLeft / 1 days, "days");
        console.log("  totalNotional:    ", ep.totalNotional, "tokens");
        console.log("  fixedObligation:  ", obligation, "tokens");
        console.log("  positions in epoch:", cfg.fyt.epochPositionCount(epochId));
        console.log("--------------------------------------------------------------");
    }

    function _printTokenBalances(
        uint256 epochId,
        Config memory cfg,
        uint256 fytBal,
        uint256 vytBal
    ) private view {
        // In the new model, FYT and VYT are both keyed by positionId.
        // fytBal = halfNotional (amount minted at deposit).
        // vytBal = 1 (flag token).
        // Epoch-level position count replaces the old "FYT total supply".
        uint256 positionCount = cfg.fyt.epochPositionCount(epochId);

        console.log("");
        console.log("  [TOKEN BALANCES keyed by positionId]");
        console.log("  FYT balance (halfNotional):", fytBal, "tokens");
        console.log("  VYT balance (1 = held):    ", vytBal);
        console.log("  Total positions in epoch:  ", positionCount);
        console.log("--------------------------------------------------------------");
    }

    function _printAccountingState(
        uint256 epochId,
        EpochManager.Epoch memory ep,
        Config memory cfg
    ) private view {
        YieldRouter.EpochBalance memory bal = cfg.yr.getEpochBalance(epochId);
        uint128 buffer   = cfg.yr.getReserveBuffer(cfg.poolId);
        uint128 heldFees = cfg.yr.getHeldFees(cfg.poolId, Currency.unwrap(cfg.currency0));
        uint256 obligation = cfg.em.currentObligation(epochId);

        uint256 coveragePct = obligation > 0
            ? (uint256(bal.fixedAccrued) * 100) / obligation
            : 100;

        string memory zone;
        if (bal.fixedAccrued >= uint128(obligation)) {
            zone = "A (full coverage)";
        } else if (uint256(bal.fixedAccrued) + uint256(buffer) >= obligation) {
            zone = "B (buffer rescue)";
        } else {
            zone = "C (haircut)";
        }

        console.log("");
        console.log("  [FEE ACCOUNTING post-swap]");
        console.log("  heldFees:        ", heldFees, "tokens");
        console.log("  fixedAccrued:    ", bal.fixedAccrued, "tokens");
        console.log("  variableAccrued: ", bal.variableAccrued, "tokens");
        console.log("  reserveContrib:  ", bal.reserveContrib, "tokens (this epoch)");
        console.log("  reserveBuffer:   ", buffer, "tokens (cross-epoch)");
        console.log("  fixedObligation: ", obligation, "tokens");
        console.log("  coverage:        ", coveragePct, "%%");
        console.log("  projected zone:  ", zone);
        console.log("--------------------------------------------------------------");
    }

    function _printPayoutPreview(
        Config memory cfg,
        FYToken.PositionData memory pos,
        uint256 epochId,
        EpochManager.Epoch memory ep
    ) private view {
        uint256 obligation = cfg.em.currentObligation(epochId);

        YieldRouter.SettlementAmounts memory preview =
            cfg.yr.previewFinalization(epochId, cfg.poolId, uint128(obligation));

        // previewFYTPayout / previewVYTPayout now take positionId only.
        uint128 fytFeePayout = cfg.mv.previewFYTPayout(cfg.positionId);
        uint128 vytFeePayout = cfg.mv.previewVYTPayout(cfg.positionId);

        // Principal return: whatever the v4 position is currently worth.
        // At sqrtPrice = 2^96 (1:1), token0 value ≈ halfNotional for each side.
        // This is approximate — actual amount depends on price at maturity.
        uint128 fytPrincipal = pos.halfNotional;
        uint128 vytPrincipal = pos.liquidity - uint128(pos.liquidity / 2) > 0
            ? pos.halfNotional  // symmetric approximation
            : 0;

        // ROI on FYT: fee payout relative to principal locked
        uint256 fytRoiBps = fytPrincipal > 0
            ? (uint256(fytFeePayout) * 10_000) / uint256(fytPrincipal)
            : 0;

        console.log("");
        console.log("  [PAYOUT PREVIEW if settled now]");
        console.log("  Settlement zone:          ", _zoneLabel(preview.zone));
        console.log("");
        console.log("  --- FYT holder receives ---");
        console.log("  Principal (approx):       ", fytPrincipal, "tokens (half liquidity)");
        console.log("  Fixed fee payout:         ", fytFeePayout, "tokens");
        console.log("  Fee ROI on principal:     ", fytRoiBps, "bps");
        console.log("  (Locked fixed rate was:   ", ep.fixedRate / 1e14, "bps annualised)");
        console.log("");
        console.log("  --- VYT holder receives ---");
        console.log("  Principal (approx):       ", vytPrincipal, "tokens (half liquidity)");
        console.log("  Variable fee payout:      ", vytFeePayout, "tokens");
        if (preview.zone == 0) {
            console.log("  Note: Zone A surplus distributed to VYT holders");
        } else {
            console.log("  Note: Zone B/C no variable payout at current coverage");
        }
        console.log("");
        console.log("  Total expected (fees only):",
            (uint256(fytFeePayout) + uint256(vytFeePayout)), "tokens");
        console.log("  Total expected (fees + principal ~):",
            (uint256(fytFeePayout) + uint256(vytFeePayout)
             + uint256(fytPrincipal) + uint256(vytPrincipal)), "tokens");
        console.log("==============================================================");
    }

    // =========================================================================
    // Utilities
    // =========================================================================

    function _zoneLabel(uint8 zone) private pure returns (string memory) {
        if (zone == 0) return "A (full coverage FYT + VYT earn fees)";
        if (zone == 1) return "B (buffer rescue FYT full, VYT zero fees)";
        return                "C (haircut FYT partial, VYT zero fees)";
    }

    function _uint2str(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v; uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory buf = new bytes(len);
        while (v != 0) { buf[--len] = bytes1(uint8(48 + (v % 10))); v /= 10; }
        return string(buf);
    }
}

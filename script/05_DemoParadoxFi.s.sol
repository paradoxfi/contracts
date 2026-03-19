// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20}           from "forge-std/interfaces/IERC20.sol";
import {IPoolManager}          from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey}               from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks}                from "v4-core/interfaces/IHooks.sol";
import {TickMath}              from "v4-core/libraries/TickMath.sol";

import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest}       from "v4-core/test/PoolSwapTest.sol";

import {ParadoxHook}    from "../src/core/ParadoxHook.sol";
import {EpochManager}   from "../src/core/EpochManager.sol";
import {PositionManager as PdxPositionManager} from "../src/core/PositionManager.sol";
import {YieldRouter}    from "../src/core/YieldRouter.sol";
import {MaturityVault}  from "../src/core/MaturityVault.sol";
import {FYToken}        from "../src/tokens/FYToken.sol";
import {VYToken}        from "../src/tokens/VYToken.sol";
import {PositionId}     from "../src/libraries/PositionId.sol";

/// @title Demo
/// @notice Live testnet demo script. Assumes a pool has already been
///         initialized via CreatePool.s.sol and the deployer holds FYT + VYT.
///
/// What this script does:
///   1. Reads current epoch state (epochId, fixedRate, maturity, notional).
///   2. Performs N swaps through the v4 pool, generating fee income.
///   3. Reads YieldRouter accounting after swaps:
///        - fixedAccrued vs fixedObligation (coverage ratio)
///        - variableAccrued (variable tranche balance)
///        - reserveBuffer (cross-epoch cushion)
///   4. Previews expected FYT and VYT payouts at current coverage.
///   5. Prints a human-readable dashboard.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (required)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   KEY               uint256 — Deployer private key.
///   TOKEN_A           address — Pool token A.
///   TOKEN_B           address — Pool token B.
///   PARADOX_HOOK      address — Deployed ParadoxHook.
///   POSITION_ID       uint256 — The ERC-721 positionId minted at deposit.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (optional)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   SWAP_COUNT        uint256 — Number of swaps to execute. Default: 5.
///   SWAP_AMOUNT       uint256 — Token amount per swap. Default: 1_000e18.
///   POOL_FEE          uint24  — Pool fee tier. Default: 3000.
///   TICK_SPACING      int24   — Pool tick spacing. Default: 60.
///   POOL_SWAP_TEST    address — Deployed PoolSwapTest contract address.
///                             On Unichain Sepolia this is a pre-deployed test helper.
///
/// Usage:
///   KEY=<pk> TOKEN_A=0x... TOKEN_B=0x... PARADOX_HOOK=0x... POSITION_ID=<n> \
///   forge script script/Demo.s.sol --rpc-url $RPC_URL --broadcast -vvvv

contract Demo is Script {
    using PoolIdLibrary   for PoolKey;
    using CurrencyLibrary for Currency;

    // Unichain Sepolia defaults
    // PoolSwapTest is deployed by the v4 team alongside PoolManager for testing.
    address constant POOL_SWAP_TEST_DEFAULT = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;
    address constant POOL_MANAGER_DEFAULT   = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    uint128 constant SQRT_PRICE_LIMIT_ZERO = 0; // no limit

    struct Config {
        uint256 deployerPrivKey;
        address deployer;
        address poolSwapTest;
        address poolManager;
        Currency currency0;
        Currency currency1;
        PoolKey  poolKey;
        PoolId   poolId;
        // Paradox Fi contracts (read from hook)
        ParadoxHook           hook;
        EpochManager          em;
        PdxPositionManager    pdxPM;
        YieldRouter           yr;
        MaturityVault         mv;
        FYToken               fyt;
        VYToken               vyt;
        // Scenario
        uint256 positionId;
        uint256 swapCount;
        uint256 swapAmount;
    }

    function run() external {
        Config memory cfg = _loadConfig();

        _printHeader(cfg);

        // ── 1. Read current epoch state ───────────────────────────────────────
        (
            uint256 epochId,
            EpochManager.Epoch memory ep
        ) = _readEpochState(cfg);

        _printEpochState(epochId, ep, cfg);

        // ── 2. Read pre-swap token balances ───────────────────────────────────
        uint256 fytBalanceBefore = cfg.fyt.balanceOf(cfg.deployer, epochId);
        uint256 vytBalanceBefore = cfg.vyt.balanceOf(cfg.deployer, cfg.positionId);

        _printTokenBalances(epochId, cfg, fytBalanceBefore, vytBalanceBefore);

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
        _printPayoutPreview(epochId, cfg);

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

        uint24 fee         = uint24(vm.envOr("POOL_FEE",     uint256(3000)));
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

        // Read core contracts from hook's immutables.
        cfg.em    = cfg.hook.epochManager();
        cfg.pdxPM = cfg.hook.positionManager();
        cfg.yr    = cfg.hook.yieldRouter();

        // MaturityVault and tokens are not stored on hook — read from YieldRouter.
        cfg.mv  = MaturityVault(payable(address(cfg.yr.maturityVault())));
        cfg.fyt = FYToken(address(cfg.mv.fyToken()));
        cfg.vyt = VYToken(address(cfg.mv.vyToken()));

        cfg.positionId = vm.envUint("POSITION_ID");
        cfg.swapCount  = vm.envOr("SWAP_COUNT",  uint256(5));
        cfg.swapAmount = vm.envOr("SWAP_AMOUNT", uint256(1_000e18));
    }

    // =========================================================================
    // Epoch state reader
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
        // PoolSwapTest settles tokens directly — approve it on both token contracts.
        // No Permit2 indirection needed.
        IERC20(Currency.unwrap(cfg.currency0)).approve(cfg.poolSwapTest, type(uint256).max);
        IERC20(Currency.unwrap(cfg.currency1)).approve(cfg.poolSwapTest, type(uint256).max);
        console.log("  Tokens approved to PoolSwapTest");
    }

    function _executeSwap(Config memory cfg, uint256 i) private {
        // Alternate swap direction each iteration to avoid draining one side.
        bool zeroForOne = i % 2 == 0;

        SwapParams memory params = SwapParams({
            zeroForOne:        zeroForOne,
            // Negative amountSpecified = exact-input swap.
            amountSpecified:   -int256(cfg.swapAmount),
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1  // token0 -> token1: price moves down
                : TickMath.MAX_SQRT_PRICE - 1  // token1 -> token0: price moves up
        });

        // TestSettings: don't use ERC-6909 claims, settle with real ERC-20.
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims:       false,
            settleUsingBurn:  false
        });

        PoolSwapTest(cfg.poolSwapTest).swap(
            cfg.poolKey,
            params,
            testSettings,
            bytes("") // hookData — afterSwap doesn't use it
        );

        console.log(
            string.concat(
                "  Swap ", _uint2str(i + 1), "/", _uint2str(cfg.swapCount),
                " | ", zeroForOne ? "token0->token1" : "token1->token0",
                " | amount: ", _uint2str(cfg.swapAmount / 1e18), " tokens"
            )
        );
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
        console.log("  Swap amount: ", cfg.swapAmount / 1e18, "tokens each");
        console.log("--------------------------------------------------------------");
    }

    function _printEpochState(
        uint256 epochId,
        EpochManager.Epoch memory ep,
        Config memory cfg
    ) private view {
        uint256 obligation = cfg.em.currentObligation(epochId);
        uint256 timeLeft   = ep.maturity > block.timestamp
            ? ep.maturity - block.timestamp
            : 0;

        console.log("");
        console.log("  [EPOCH STATE]");
        console.log("  epochId:        ");
        console.logBytes32(bytes32(epochId));
        console.log("  fixedRate (WAD):", ep.fixedRate);
        console.log("  fixedRate (%%):  ", ep.fixedRate / 1e14, "bps");
        console.log("  startTime:      ", ep.startTime);
        console.log("  maturity:       ", ep.maturity);
        console.log("  time to maturity:", timeLeft / 1 days, "days");
        console.log("  totalNotional:  ", ep.totalNotional / 1e18, "tokens");
        console.log("  fixedObligation:", obligation / 1e18, "tokens");
        console.log("--------------------------------------------------------------");
    }

    function _printTokenBalances(
        uint256 epochId,
        Config memory cfg,
        uint256 fytBalance,
        uint256 vytBalance
    ) private view {
        uint256 fytSupply  = cfg.fyt.totalSupply(epochId);
        uint256 vytEpochSz = cfg.vyt.epochSupply(epochId);

        console.log("");
        console.log("  [TOKEN BALANCES]");
        console.log("  FYT balance (this wallet):", fytBalance / 1e18, "FYT");
        console.log("  FYT total supply (epoch): ", fytSupply / 1e18, "FYT");
        console.log("  FYT share:                 %",
            fytSupply > 0 ? (fytBalance * 100) / fytSupply : 0);
        console.log("  VYT balance (positionId):  ", vytBalance);
        console.log("  VYT positions in epoch:   ", vytEpochSz);
        console.log("--------------------------------------------------------------");
    }

    function _printAccountingState(
        uint256 epochId,
        EpochManager.Epoch memory ep,
        Config memory cfg
    ) private view {
        YieldRouter.EpochBalance memory bal = cfg.yr.getEpochBalance(epochId);
        uint128 buffer      = cfg.yr.getReserveBuffer(cfg.poolId);
        uint128 heldFees    = cfg.yr.getHeldFees(cfg.poolId, Currency.unwrap(cfg.currency0));
        uint256 obligation  = cfg.em.currentObligation(epochId);

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
        console.log("  heldFees (total):  ", heldFees / 1e18, "tokens");
        console.log("  fixedAccrued:      ", bal.fixedAccrued / 1e18, "tokens");
        console.log("  variableAccrued:   ", bal.variableAccrued / 1e18, "tokens");
        console.log("  reserveContrib:    ", bal.reserveContrib / 1e18, "tokens (this epoch)");
        console.log("  reserveBuffer:     ", buffer / 1e18, "tokens (cross-epoch)");
        console.log("  fixedObligation:   ", obligation / 1e18, "tokens");
        console.log("  coverage ratio:    ", coveragePct, "%%");
        console.log("  settlement zone:   ", zone);
        console.log("--------------------------------------------------------------");
    }

    function _printPayoutPreview(uint256 epochId, Config memory cfg) private view {
        YieldRouter.SettlementAmounts memory preview =
            cfg.yr.previewFinalization(epochId, cfg.poolId, uint128(cfg.em.currentObligation(epochId)));

        uint128 fytPayout = cfg.mv.previewFYTPayout(epochId, cfg.deployer);
        uint128 vytPayout = cfg.mv.previewVYTPayout(epochId, cfg.positionId);

        // FYT ROI: (payout - cost) / cost where cost = notional proportion
        // We approximate cost as (walletFYT / totalFYT) * totalNotional
        uint256 fytBalance = cfg.fyt.balanceOf(cfg.deployer, epochId);
        uint256 fytSupply  = cfg.fyt.totalSupply(epochId);
        EpochManager.Epoch memory ep = cfg.em.getEpoch(epochId);

        uint256 notionalCost = fytSupply > 0
            ? (fytBalance * ep.totalNotional) / fytSupply
            : 0;

        uint256 fytRoiBps = notionalCost > 0
            ? (uint256(fytPayout) * 10_000) / notionalCost
            : 0;

        console.log("");
        console.log("  [PAYOUT PREVIEW if settled now]");
        console.log("  Settlement zone:       ", _zoneLabel(preview.zone));
        console.log("");
        console.log("  FYT expected payout:   ", fytPayout / 1e18, "tokens");
        console.log("  FYT approx. ROI:       ", fytRoiBps, "bps");
        console.log("  (FYT locked rate was:  ", ep.fixedRate / 1e14, "bps annualised)");
        console.log("");
        console.log("  VYT expected payout:   ", vytPayout / 1e18, "tokens");
        if (preview.zone == 0) {
            console.log("  VYT note: Zone A surplus distributed to variable holders");
        } else {
            console.log("  VYT note: Zone B/C no variable payout at current coverage");
        }
        console.log("");
        console.log("  Total expected payout: ",
            (uint256(fytPayout) + uint256(vytPayout)) / 1e18, "tokens");
        console.log("==============================================================");
    }

    // =========================================================================
    // Utilities
    // =========================================================================

    function _zoneLabel(uint8 zone) private pure returns (string memory) {
        if (zone == 0) return "A (full coverage FYT full + VYT surplus)";
        if (zone == 1) return "B (buffer rescue FYT full, VYT zero)";
        return                "C (haircut FYT partial, VYT zero)";
    }

    function _uint2str(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 len;
        while (tmp != 0) { len++; tmp /= 10; }
        bytes memory buf = new bytes(len);
        while (v != 0) { buf[--len] = bytes1(uint8(48 + (v % 10))); v /= 10; }
        return string(buf);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {
    IAllowanceTransfer
} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {
    IPositionManager
} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {
    IPoolInitializer_v4
} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {ParadoxHook} from "../src/core/ParadoxHook.sol";
import {FixedDateEpochModel} from "../src/epochs/FixedDateEpochModel.sol";

/// @title CreatePool
/// @notice Deploys and initializes a Uniswap v4 pool with ParadoxHook.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// What this script does
/// ─────────────────────────────────────────────────────────────────────────────
///
///   1. Sorts token0/token1 by address (v4 requires currency0 < currency1).
///   2. Calls ParadoxHook.initializePool() — registers the pool with
///      EpochManager and RateOracle, opens the first epoch at the genesis
///      rate. Must happen BEFORE the v4 pool is created because
///      before/afterInitialize callbacks carry no hookData in v4.
///   3. Approves both tokens to Permit2, then Permit2 to PositionManager.
///   4. Calls PositionManager.multicall() with two actions atomically:
///        a. IPoolInitializer_v4.initializePool — creates the v4 pool.
///           afterInitialize on ParadoxHook is a no-op (registration already
///           done in step 2).
///        b. IPositionManager.modifyLiquidities(MINT_POSITION + SETTLE_PAIR) —
///           seeds full-range initial liquidity, triggering afterAddLiquidity
///           which mints the deployer's position NFT, FYT, and VYT.
///   5. Verifies the pool is live and the first epoch is open.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (required)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   KEY             uint256 — Deployer private key.
///   TOKEN_A         address — First token (order doesn't matter; script sorts).
///   TOKEN_B         address — Second token.
///   PARADOX_HOOK    address — Deployed ParadoxHook address.
///   EPOCH_MODEL     address — Deployed FixedDateEpochModel (or custom model).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (optional)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   EPOCH_DURATION  uint32  — Epoch length in seconds. Default: 30 days.
///   ALPHA_WAD       uint256 — α weight (WAD). Default: 0.80e18.
///   BETA_WAD        uint256 — β weight (WAD). Default: 0.30e18.
///   GAMMA_WAD       uint256 — γ weight (WAD). Default: 0.15e18.
///   TICK_SPACING    int24   — Pool tick spacing. Default: 60.
///   SQRT_PRICE      uint160 — Initial sqrtPriceX96. Default: 2^96 (1:1 ratio).
///   SEED_LIQUIDITY  uint256 — Seed liquidity units. Default: 100_000e18.
///   GENESIS_TWAP    uint256 — Fixed rate for the first epoch (WAD). Must be
///                             >= MIN_RATE (0.0001e18). Default: 0.0001e18.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Usage
/// ─────────────────────────────────────────────────────────────────────────────
///
///   KEY=<pk> \
///   TOKEN_A=0x... TOKEN_B=0x... \
///   PARADOX_HOOK=0x... EPOCH_MODEL=0x... \
///   forge script script/CreatePool.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     -vvvv
contract CreatePool is Script {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // -------------------------------------------------------------------------
    // Unichain Sepolia (chain ID 1301) V4 contract addresses.
    // Override via env vars POOL_MANAGER / POSITION_MANAGER / PERMIT2 for other chains.
    // -------------------------------------------------------------------------
    address constant POOL_MANAGER_DEFAULT =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant POSITION_MANAGER_DEFAULT =
        0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;
    address constant PERMIT2_DEFAULT =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // v4 uses DYNAMIC_FEE_FLAG when the hook manages fees. Since ParadoxHook
    // does not override fees (hookDelta = 0), we use a static fee tier instead.
    // 3000 = 0.30%, the canonical mid-vol tier. Override via env var POOL_FEE.
    uint24 constant DEFAULT_FEE = 3000;

    uint256 constant DEADLINE_OFFSET = 600; // 10 minutes
    uint128 constant AMOUNT_MAX = type(uint128).max;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    // -------------------------------------------------------------------------
    // Config struct — keeps helpers under the 16-slot stack limit
    // -------------------------------------------------------------------------

    struct Config {
        // Deployer
        uint256 deployerPrivKey;
        address deployer;
        // Contracts
        address poolManager;
        address positionManager;
        address permit2;
        address paradoxHook;
        address epochModel;
        // Pool parameters
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint256 seedLiquidity;
        // Epoch parameters
        ParadoxHook.InitParams initParams;
        uint256 genesisTwapWad;
    }

    // -------------------------------------------------------------------------
    // Entry point
    // -------------------------------------------------------------------------

    function run() external returns (PoolKey memory poolKey, PoolId poolId) {
        Config memory cfg = _loadConfig();

        poolKey = PoolKey({
            currency0: cfg.currency0,
            currency1: cfg.currency1,
            fee: cfg.fee,
            tickSpacing: cfg.tickSpacing,
            hooks: IHooks(cfg.paradoxHook)
        });
        poolId = poolKey.toId();

        console.log("======================================================");
        console.log("Paradox Fi CreatePool");
        console.log("======================================================");
        console.log("Deployer:     ", cfg.deployer);
        console.log("token0:       ", Currency.unwrap(cfg.currency0));
        console.log("token1:       ", Currency.unwrap(cfg.currency1));
        console.log("fee tier:     ", cfg.fee);
        console.log("tickSpacing:  ", uint256(uint24(cfg.tickSpacing)));
        console.log("sqrtPriceX96: ", cfg.sqrtPriceX96);
        console.log("ParadoxHook:  ", cfg.paradoxHook);
        console.log("EpochModel:   ", cfg.epochModel);
        console.log(
            "epochDuration:",
            uint256(abi.decode(cfg.initParams.modelParams, (uint32)))
        );
        console.log("alphaWad:     ", cfg.initParams.alphaWad);
        console.log("betaWad:      ", cfg.initParams.betaWad);
        console.log("gammaWad:     ", cfg.initParams.gammaWad);
        console.log("genesisTwap:  ", cfg.genesisTwapWad);
        console.log("------------------------------------------------------");

        vm.startBroadcast(cfg.deployerPrivKey);

        // Step 1: Register pool with Paradox Fi core contracts.
        // Must happen before the v4 pool is created — before/afterInitialize
        // callbacks carry no hookData, so there is no other hook entry point
        // to perform registration. afterInitialize on ParadoxHook is a no-op.
        ParadoxHook(payable(cfg.paradoxHook)).initializePool(
            poolKey,
            cfg.initParams,
            cfg.genesisTwapWad
        );
        console.log(
            "ParadoxHook.initializePool() called pool registered, epoch opened"
        );

        bool isReg = ParadoxHook(cfg.paradoxHook).registeredPools(poolId);
        console.log("IS POOL REG: ", isReg);

        // Step 2: Approve token flow through Permit2 -> PositionManager.
        _approvePermit2(cfg);
        _approvePositionManager(cfg);

        // Step 3: Atomically create the v4 pool and seed liquidity.
        // afterInitialize fires but is a no-op (registration done above).
        // afterAddLiquidity fires, minting the deployer's position NFT, FYT,
        // and VYT.
        _initializeAndSeed(poolKey, cfg);

        vm.stopBroadcast();

        // Step 4: Verify.
        _verify(poolKey, poolId, cfg);
    }

    // -------------------------------------------------------------------------
    // Config loading
    // -------------------------------------------------------------------------

    function _loadConfig() private view returns (Config memory cfg) {
        cfg.deployerPrivKey = vm.envUint("KEY");
        cfg.deployer = vm.addr(cfg.deployerPrivKey);

        cfg.poolManager = vm.envOr("POOL_MANAGER", POOL_MANAGER_DEFAULT);
        cfg.positionManager = POSITION_MANAGER_DEFAULT;
        cfg.permit2 = vm.envOr("PERMIT2", PERMIT2_DEFAULT);
        cfg.paradoxHook = vm.envAddress("PARADOX_HOOK");
        cfg.epochModel = vm.envAddress("EPOCH_MODEL");

        // Sort tokens so currency0 < currency1 (v4 invariant).
        address tokenA = vm.envAddress("TOKEN_A");
        address tokenB = vm.envAddress("TOKEN_B");
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        cfg.currency0 = Currency.wrap(token0);
        cfg.currency1 = Currency.wrap(token1);

        // Pool parameters.
        cfg.fee = uint24(vm.envOr("POOL_FEE", uint256(DEFAULT_FEE)));
        cfg.tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        cfg.sqrtPriceX96 = SQRT_PRICE_1_1;
        cfg.seedLiquidity = vm.envOr("SEED_LIQUIDITY", uint256(100_000e18));

        // Compute full-range tick bounds for this tick spacing.
        // TickMath.minUsableTick / maxUsableTick rounds to the nearest valid tick.
        cfg.tickLower = TickMath.minUsableTick(cfg.tickSpacing);
        cfg.tickUpper = TickMath.maxUsableTick(cfg.tickSpacing);

        // Epoch / rate parameters.
        uint32 epochDuration = uint32(
            vm.envOr("EPOCH_DURATION", uint256(30 days))
        );

        cfg.initParams = ParadoxHook.InitParams({
            model: cfg.epochModel,
            modelParams: abi.encode(epochDuration),
            alphaWad: vm.envOr("ALPHA_WAD", uint256(0.80e18)),
            betaWad: vm.envOr("BETA_WAD", uint256(0.30e18)),
            gammaWad: vm.envOr("GAMMA_WAD", uint256(0.15e18))
        });

        // Genesis TWAP: the fixed rate for the first epoch. The oracle has no
        // history at this point, so governance supplies it explicitly. Must be
        // >= FixedRateMath.MIN_RATE (0.0001e18 = 0.01% APR).
        cfg.genesisTwapWad = vm.envOr("GENESIS_TWAP", uint256(0.0001e18));
        require(
            cfg.genesisTwapWad >= 0.0001e18,
            "CreatePool: GENESIS_TWAP must be >= MIN_RATE (0.0001e18)"
        );
    }

    // -------------------------------------------------------------------------
    // Approvals
    // -------------------------------------------------------------------------

    function _approvePermit2(Config memory cfg) private {
        IERC20(Currency.unwrap(cfg.currency0)).approve(
            cfg.permit2,
            type(uint256).max
        );
        IERC20(Currency.unwrap(cfg.currency1)).approve(
            cfg.permit2,
            type(uint256).max
        );
        console.log("Permit2 approved for both tokens");
    }

    function _approvePositionManager(Config memory cfg) private {
        IAllowanceTransfer(cfg.permit2).approve(
            Currency.unwrap(cfg.currency0),
            cfg.positionManager,
            type(uint160).max,
            type(uint48).max
        );
        IAllowanceTransfer(cfg.permit2).approve(
            Currency.unwrap(cfg.currency1),
            cfg.positionManager,
            type(uint160).max,
            type(uint48).max
        );
        console.log("PositionManager approved via Permit2");
    }

    // -------------------------------------------------------------------------
    // Pool initialization + liquidity seeding (single multicall)
    // -------------------------------------------------------------------------

    function _initializeAndSeed(
        PoolKey memory poolKey,
        Config memory cfg
    ) private {
        bytes[] memory multicallData = new bytes[](2);

        multicallData[0] = _encodeInitialize(poolKey);
        multicallData[1] = _encodeMintLiquidity(poolKey, cfg);

        IPositionManager(cfg.positionManager).multicall(multicallData);

        console.log("v4 pool initialized and seed liquidity added");
    }

    function _encodeInitialize(
        PoolKey memory poolKey
    ) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                IPoolInitializer_v4.initializePool.selector,
                poolKey,
                SQRT_PRICE_1_1
            );
    }

    function _encodeMintLiquidity(
        PoolKey memory poolKey,
        Config memory cfg
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        bytes[] memory params = new bytes[](2);

        // MINT_POSITION params.
        // hookData is empty — afterAddLiquidity uses only the v4 callback params.
        params[0] = abi.encode(
            poolKey,
            cfg.tickLower,
            cfg.tickUpper,
            cfg.seedLiquidity,
            AMOUNT_MAX, // amount0Max — slippage guard (max)
            AMOUNT_MAX, // amount1Max — slippage guard (max)
            cfg.deployer, // recipient of the position NFT
            abi.encode(cfg.deployer)  // hookData — tells the hook who the real recipient is
        );

        // SETTLE_PAIR params — pays both tokens from deployer.
        params[1] = abi.encode(cfg.currency0, cfg.currency1);

        return
            abi.encodeWithSelector(
                IPositionManager.modifyLiquidities.selector,
                abi.encode(actions, params),
                block.timestamp + DEADLINE_OFFSET
            );
    }

    // -------------------------------------------------------------------------
    // Post-deployment verification
    // -------------------------------------------------------------------------

    function _verify(
        PoolKey memory /* poolKey */,
        PoolId poolId,
        Config memory cfg
    ) private view {
        // Verify the pool is live in PoolManager.
        (uint160 sqrtPriceX96, , , ) = IPoolManager(cfg.poolManager).getSlot0(
            poolId
        );
        require(sqrtPriceX96 != 0, "CreatePool: pool not initialised");

        // Verify ParadoxHook registered the pool.
        require(
            ParadoxHook(payable(cfg.paradoxHook)).registeredPools(poolId),
            "CreatePool: pool not registered in ParadoxHook"
        );

        // Verify EpochManager has an active epoch for the pool.
        require(
            ParadoxHook(payable(cfg.paradoxHook)).epochManager().hasActiveEpoch(
                poolId
            ),
            "CreatePool: no active epoch after initialisation"
        );

        uint256 activeEpochId = ParadoxHook(payable(cfg.paradoxHook))
            .epochManager()
            .activeEpochIdFor(poolId);

        console.log("======================================================");
        console.log("Pool created successfully");
        console.log("------------------------------------------------------");
        console.log("PoolId:");
        console.logBytes32(PoolId.unwrap(poolId));
        console.log("sqrtPriceX96:  ", sqrtPriceX96);
        console.log("Active epochId:");
        console.logBytes32(bytes32(activeEpochId));
        console.log("======================================================");
        console.log("Next steps:");
        console.log("  - LPs add liquidity: FYT + VYT minted automatically.");
        console.log("  - After epoch maturity, keeper calls:");
        console.log("      EpochManager.settle(epochId, twap, vol, 0)");
        console.log(
            "      YieldRouter.finalizeEpoch(epochId, poolId, token, obligation)"
        );
        console.log(
            "  - FYT/VYT holders call MaturityVault.redeemFYT/redeemVYT."
        );
    }
}

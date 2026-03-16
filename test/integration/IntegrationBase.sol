// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {
    ModifyLiquidityParams,
    SwapParams
} from "v4-core/types/PoolOperation.sol";

import {EpochManager} from "../../src/core/EpochManager.sol";
import {PositionManager} from "../../src/core/PositionManager.sol";
import {YieldRouter} from "../../src/core/YieldRouter.sol";
import {MaturityVault} from "../../src/core/MaturityVault.sol";
import {RateOracle} from "../../src/core/RateOracle.sol";
import {ParadoxHook} from "../../src/core/ParadoxHook.sol";
import {FYToken} from "../../src/tokens/FYToken.sol";
import {VYToken} from "../../src/tokens/VYToken.sol";
import {IFYToken} from "../../src/interfaces/IFYToken.sol";
import {IVYToken} from "../../src/interfaces/IVYToken.sol";
import {FixedDateEpochModel} from "../../src/epochs/FixedDateEpochModel.sol";
import {PositionId} from "../../src/libraries/PositionId.sol";

/// @dev Minimal ERC-20 for the fee token.
contract MockToken is ERC20 {
    constructor(string memory name, string memory sym) ERC20(name, sym) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock PoolManager that supports extsload for StateLibrary compatibility.
contract MockPoolManager {
    uint160 public sqrtPriceX96 = 2 ** 96;
    uint128 public poolLiquidity = 1_000_000e18;

    /// StateLibrary reads slot0 via extsload. Returns sqrtPriceX96 in lower 160 bits.
    function extsload(bytes32) external view returns (bytes32) {
        return bytes32(uint256(sqrtPriceX96));
    }

    function extsload(
        bytes32,
        uint256 count
    ) external view returns (bytes32[] memory r) {
        r = new bytes32[](count);
        r[0] = bytes32(uint256(sqrtPriceX96));
        if (count > 1) r[1] = bytes32(uint256(poolLiquidity));
    }

    function getLiquidity(PoolId) external view returns (uint128) {
        return poolLiquidity;
    }

    function setSqrtPrice(uint160 p) external {
        sqrtPriceX96 = p;
    }
    function setLiquidity(uint128 l) external {
        poolLiquidity = l;
    }
}

/// @title IntegrationBase
/// @notice Shared deployment and wiring for all integration test suites.
///
/// Deploys the full Paradox Fi contract stack and wires authorizations.
/// Concrete test contracts inherit this and add scenario-specific helpers.
abstract contract IntegrationBase is Test {
    using PoolIdLibrary for PoolKey;

    // -------------------------------------------------------------------------
    // Actors
    // -------------------------------------------------------------------------

    address internal constant OWNER = address(0xA110CE);
    address internal constant LP_A = address(0xAA01);
    address internal constant LP_B = address(0xAA02);
    address internal constant LP_C = address(0xAA03);
    address internal constant KEEPER = address(0xBEEF); // calls settle

    // -------------------------------------------------------------------------
    // Protocol constants
    // -------------------------------------------------------------------------

    uint32 internal constant EPOCH_DURATION = 30 days;
    uint64 internal constant T0 = 1_700_000_000;

    // Rate params — stable pool defaults.
    uint256 internal constant ALPHA = 0.80e18;
    uint256 internal constant BETA = 0.30e18;
    uint256 internal constant GAMMA = 0.15e18;

    // Genesis TWAP (MIN_RATE floor from FixedRateMath).
    uint256 internal constant GENESIS_TWAP = 0.0001e18;

    // Hook address mask: afterInitialize(12)|afterAddLiquidity(10)|
    //                    beforeRemoveLiquidity(9)|afterSwap(6) = 0x1640
    address internal constant HOOK_ADDR = address(uint160(0x1640));

    // -------------------------------------------------------------------------
    // Contracts
    // -------------------------------------------------------------------------

    MockPoolManager internal mockPM;
    MockToken internal token0;

    EpochManager internal em;
    PositionManager internal pm;
    YieldRouter internal yr;
    MaturityVault internal mv;
    RateOracle internal oracle;
    ParadoxHook internal hook;
    FYToken internal fyt;
    VYToken internal vyt;
    FixedDateEpochModel internal model;

    PoolKey internal KEY;
    PoolId internal POOL;

    // -------------------------------------------------------------------------
    // setUp
    // -------------------------------------------------------------------------

    function setUp() public virtual {
        vm.warp(T0);
        vm.chainId(1);

        // Deploy infrastructure.
        mockPM = new MockPoolManager();
        token0 = new MockToken("USD Coin", "USDC");
        model = new FixedDateEpochModel();

        // Deploy core contracts (authorized caller set to hook after etch).
        em = new EpochManager(OWNER, address(0));
        pm = new PositionManager(OWNER, address(0));
        yr = new YieldRouter(OWNER, address(0), em);
        oracle = new RateOracle(OWNER, address(0));

        // Deploy tokens.
        address[] memory burners = new address[](2);
        burners[0] = address(0); // PositionManager — set after etch
        burners[1] = address(0); // MaturityVault   — set after etch
        fyt = new FYToken(OWNER, address(0), burners, "");
        vyt = new VYToken(OWNER, address(0), burners, "");

        // Deploy MaturityVault.
        mv = new MaturityVault(
            OWNER,
            address(0),
            IFYToken(address(fyt)),
            IVYToken(address(vyt))
        );

        // Wire YieldRouter → MaturityVault.
        vm.startPrank(OWNER);
        yr.setMaturityVault(address(mv));
        vm.stopPrank();

        deployCodeTo(
            "ParadoxHook.sol",
            abi.encode(address(mockPM), em, pm, yr, oracle, OWNER),
            HOOK_ADDR
        );

        hook = ParadoxHook(HOOK_ADDR);

        // Set authorized callers.
        vm.startPrank(OWNER);
        em.setAuthorizedCaller(HOOK_ADDR);
        pm.setAuthorizedCaller(HOOK_ADDR);
        yr.setAuthorizedCaller(HOOK_ADDR);
        oracle.setAuthorizedCaller(HOOK_ADDR);
        mv.setAuthorizedCaller(address(yr));

        // Grant token roles.
        fyt.grantRole(fyt.MINTER_ROLE(), HOOK_ADDR);
        fyt.grantRole(fyt.BURNER_ROLE(), HOOK_ADDR);
        fyt.grantRole(fyt.BURNER_ROLE(), address(mv));
        vyt.grantRole(vyt.MINTER_ROLE(), HOOK_ADDR);
        vyt.grantRole(vyt.BURNER_ROLE(), HOOK_ADDR);
        vyt.grantRole(vyt.BURNER_ROLE(), address(mv));
        vm.stopPrank();

        // Build PoolKey.
        KEY = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(0xE1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: hook
        });
        POOL = KEY.toId();

        // Initialize pool through the hook.
        _initializePool();
    }

    // -------------------------------------------------------------------------
    // Core scenario helpers
    // -------------------------------------------------------------------------

    /// Initialize the pool via afterInitialize callback.
    function _initializePool() internal {
        ParadoxHook.InitParams memory p = ParadoxHook.InitParams({
            model: address(model),
            modelParams: abi.encode(uint32(EPOCH_DURATION)),
            alphaWad: ALPHA,
            betaWad: BETA,
            gammaWad: GAMMA
        });
        uint256 MIN_RATE = 0.0001e18;
        vm.prank(OWNER);
        hook.initializePool(KEY, p, MIN_RATE);
        vm.prank(address(mockPM));
        hook.afterInitialize(address(0), KEY, uint160(2 ** 96), 0);
    }

    /// Add liquidity for an LP. Returns the minted positionId.
    function _addLiquidity(
        address lp,
        uint128 liquidity
    ) internal returns (uint256 positionId) {
        uint32 nextCounter = pm.poolCounter(POOL) + 1;

        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100,
            tickUpper: 100,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        vm.prank(address(mockPM));
        hook.afterAddLiquidity(
            lp,
            KEY,
            mlp,
            toBalanceDelta(0, 0),
            toBalanceDelta(0, 0),
            ""
        );

        positionId = PositionId.encode(POOL, nextCounter);
    }

    /// Simulate a swap that generates feeAmount of fee income.
    /// Mints tokens directly to YieldRouter (simulating PoolManager fee transfer)
    /// then calls afterSwap.
    function _swap(uint128 feeAmount) internal {
        // Back-calculate the gross input needed to produce feeAmount at 0.3% tier.
        // feeAmount = input × 3000 / 1_000_000 → input = feeAmount × 1_000_000 / 3000
        uint128 grossInput = uint128((uint256(feeAmount) * 1_000_000) / 3000);

        // Mint fee tokens to YieldRouter (hook does not transfer on afterSwap).
        token0.mint(address(yr), feeAmount);

        SwapParams memory sp = SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(uint256(grossInput)),
            sqrtPriceLimitX96: 0
        });
        BalanceDelta delta = toBalanceDelta(
            int128(grossInput),
            -int128(grossInput)
        );

        vm.prank(address(mockPM));
        hook.afterSwap(address(0), KEY, sp, delta, "");
    }

    /// Remove liquidity (mark position exited).
    function _removeLiquidity(
        address lp,
        uint256 positionId,
        uint128 liquidity
    ) internal {
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: -100,
            tickUpper: 100,
            liquidityDelta: -int256(uint256(liquidity)),
            salt: bytes32(0)
        });
        vm.prank(address(mockPM));
        hook.beforeRemoveLiquidity(lp, KEY, mlp, abi.encode(positionId));
    }

    /// Settle the current epoch and finalize via YieldRouter.
    /// Returns the settled epochId and settlement amounts.
    function _settleEpoch()
        internal
        returns (uint256 epochId, YieldRouter.SettlementAmounts memory amounts)
    {
        epochId = em.activeEpochIdFor(POOL);
        EpochManager.Epoch memory ep = em.getEpoch(epochId);

        // Warp to maturity.
        vm.warp(ep.maturity);

        // Compute final obligation.
        uint256 obligation = em.currentObligation(epochId);

        // Settle epoch state in EpochManager.
        vm.prank(KEEPER);
        em.settle(epochId, GENESIS_TWAP, 0, 0);

        // Finalize in YieldRouter (transfers to MaturityVault + notifies it).
        vm.prank(OWNER);
        yr.setAuthorizedCaller(KEEPER);
        vm.prank(KEEPER);
        amounts = yr.finalizeEpoch(
            epochId,
            POOL,
            address(token0),
            uint128(obligation)
        );
        vm.prank(OWNER);
        yr.setAuthorizedCaller(HOOK_ADDR);
    }

    /// Mint FYT and VYT for an LP at deposit time.
    /// In production this is done by PositionManager; here we call directly.
    function _mintTokens(
        address lp,
        uint256 positionId,
        uint256 epochId,
        uint128 notional
    ) internal {
        vm.startPrank(HOOK_ADDR);
        fyt.mint(lp, epochId, notional);
        vyt.mint(lp, positionId, epochId);
        vm.stopPrank();
    }
}

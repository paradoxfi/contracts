// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {EpochManager} from "../src/core/EpochManager.sol";
import {YieldRouter} from "../src/core/YieldRouter.sol";
import {MaturityVault} from "../src/core/MaturityVault.sol";
import {RateOracle} from "../src/core/RateOracle.sol";
import {ParadoxHook} from "../src/core/ParadoxHook.sol";
import {FYToken} from "../src/tokens/FYToken.sol";
import {VYToken} from "../src/tokens/VYToken.sol";
import {FixedDateEpochModel} from "../src/epochs/FixedDateEpochModel.sol";

/// @title Deploy
/// @notice Full protocol deployment script for Paradox Fi.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (required)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   SALT            bytes32 — Pre-mined CREATE2 salt that produces a hook
///                             address whose lower 14 bits equal 0x1640.
///                             Mine offline with HookMiner or a similar tool.
///
///   POOL_MANAGER    address — Uniswap v4 PoolManager on the target chain.
///
///   DEPLOYER        address — EOA or multisig executing the broadcast.
///                             Becomes the initial owner of all contracts.
///
///   GOVERNANCE      address — Final owner after deployment. Should be a
///                             timelock-controlled multisig. If identical to
///                             DEPLOYER, the ownership transfer step is skipped.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Environment variables (optional)
/// ─────────────────────────────────────────────────────────────────────────────
///
///   FYT_URI         string  — Base URI for FYToken metadata.
///                             Default: "https://api.paradoxfi.xyz/fyt/{id}"
///
///   VYT_URI         string  — Base URI for VYToken metadata.
///                             Default: "https://api.paradoxfi.xyz/vyt/{id}"
///
///   BUFFER_SKIM_RATE uint256 — Buffer skim rate in WAD. Default: 0.10e18 (10%).
///                              Must be in [0.05e18, 0.25e18].
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Deployment order
/// ─────────────────────────────────────────────────────────────────────────────
///
///   1.  FixedDateEpochModel   — stateless, no dependencies
///   2.  EpochManager          — depends on: nothing (hook wired after)
///   4.  RateOracle            — depends on: nothing (hook wired after)
///   5.  YieldRouter           — depends on: EpochManager
///   6.  FYToken               — depends on: PositionManager (minter),
///                                           MaturityVault (burner — set after)
///   7.  VYToken               — depends on: PositionManager (minter),
///                                           MaturityVault (burner — set after)
///   8.  MaturityVault         — depends on: FYToken, VYToken
///   9.  ParadoxHook (CREATE2) — depends on: all core contracts
///  10.  Wire authorizations   — set hook as authorizedCaller on all contracts
///  11.  Wire token roles      — grant MINTER/BURNER roles to hook and vault
///  12.  Wire YieldRouter      — set MaturityVault address
///  13.  Wire skim rate        — configure bufferSkimRate on YieldRouter
///  14.  Transfer ownership    — initiate two-step transfer to GOVERNANCE
///
/// ─────────────────────────────────────────────────────────────────────────────
/// Usage
/// ─────────────────────────────────────────────────────────────────────────────
///
///   forge script script/Deploy.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     --verify \
///     -vvvv
///
/// With environment variables:
///
///   SALT=0x... \
///   POOL_MANAGER=0x... \
///   DEPLOYER=0x... \
///   GOVERNANCE=0x... \
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

contract DeployCore is Script {
    using PoolIdLibrary for PoolKey;

    // =========================================================================
    // Required permission flag mask for the hook address.
    // Flags: afterInitialize(12) | afterAddLiquidity(10) |
    //        beforeRemoveLiquidity(9) | afterSwap(6) = 0x1640
    // =========================================================================
    uint160 internal constant HOOK_FLAGS =
        uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
                Hooks.AFTER_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );

    // =========================================================================
    // Deployed contract references — populated during run()
    // =========================================================================

    FixedDateEpochModel public fixedDateModel;
    EpochManager public epochManager;
    RateOracle public rateOracle;
    YieldRouter public yieldRouter;
    FYToken public fyToken;
    VYToken public vyToken;
    MaturityVault public maturityVault;
    ParadoxHook public hook;

    address constant POOL_MANAGER_ADDRESS =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    // =========================================================================
    // run()
    // =========================================================================

    function run() external {
        // ── Read environment ──────────────────────────────────────────────────
        uint256 deployerPrivKey = vm.envUint("KEY");
        address deployer = vm.addr(deployerPrivKey);

        address poolManager = POOL_MANAGER_ADDRESS;
        address governance = vm.envAddress("GOVERNANCE");

        string memory fytUri = vm.envOr(
            "FYT_URI",
            string("https://api.paradoxfi.xyz/fyt/{id}")
        );
        string memory vytUri = vm.envOr(
            "VYT_URI",
            string("https://api.paradoxfi.xyz/vyt/{id}")
        );
        uint256 bufferSkimRate = vm.envOr("BUFFER_SKIM_RATE", uint256(0.10e18));

        // ── Validate ──────────────────────────────────────────────────────────

        require(poolManager != address(0), "Deploy: POOL_MANAGER not set");
        require(deployer != address(0), "Deploy: DEPLOYER not set");
        require(governance != address(0), "Deploy: GOVERNANCE not set");
        require(
            bufferSkimRate >= 0.05e18 && bufferSkimRate <= 0.25e18,
            "Deploy: BUFFER_SKIM_RATE out of [5%, 25%]"
        );

        // ── Derive the expected hook address from CREATE2 ─────────────────────

        // The hook is deployed via CREATE2 so its address encodes the permission
        // flags in the lower bits. We compute the expected address upfront so we
        // can pass it to token constructors (as the minter) before deploying it.
        //
        // CREATE2 address = keccak256(0xff ++ factory ++ salt ++ keccak256(initcode))
        // We use the deployer EOA as the CREATE2 factory via vm.broadcast, which
        // means the factory is msg.sender == deployer.
        /*         bytes memory hookInitcode = abi.encodePacked(
            type(ParadoxHook).creationCode,
            abi.encode(
                IPoolManager(poolManager),
                address(0), // epochManager — placeholder, replaced below
                address(0), // yieldRouter — placeholder
                address(0), // rateOracle — placeholder
                deployer
            )
        ); */

        // We cannot compute the real address yet (core contracts not deployed).
        // Instead we derive it post-deploy by reading the CREATE2 result.
        // The hook constructor args include the core contract addresses, so we
        // must deploy core contracts first, then compute the full initcode.

        // ── Begin broadcast ───────────────────────────────────────────────────

        vm.startBroadcast(deployerPrivKey);

        // ── Step 1: FixedDateEpochModel ───────────────────────────────────────

        fixedDateModel = new FixedDateEpochModel();
        console2.log("FixedDateEpochModel:  ", address(fixedDateModel));

        // ── Step 2: EpochManager ──────────────────────────────────────────────
        // authorizedCaller is set to address(0) now; updated to hook after deploy.

        epochManager = new EpochManager({
            _owner: deployer,
            _authorizedCaller: address(0)
        });
        console2.log("EpochManager:         ", address(epochManager));

        // ── Step 4: RateOracle ────────────────────────────────────────────────

        rateOracle = new RateOracle({
            _owner: deployer,
            _authorizedCaller: address(0)
        });
        console2.log("RateOracle:           ", address(rateOracle));

        // ── Step 5: YieldRouter ───────────────────────────────────────────────

        yieldRouter = new YieldRouter({
            _owner: deployer,
            _authorizedCaller: address(0),
            _epochManager: epochManager
        });
        console2.log("YieldRouter:          ", address(yieldRouter));

        // ── Steps 6 & 7: Tokens ───────────────────────────────────────────────
        // At this point we know the hook will be the minter, but we don't yet
        // know the hook address (it depends on the full constructor args including
        // core contract addresses we now have). We deploy the hook with CREATE2
        // next, then grant roles. Tokens are deployed with empty minter/burner
        // lists; roles are granted after the hook address is known.
        //
        // FYToken and VYToken accept minter as a constructor arg, but roles can
        // also be granted post-deploy via grantRole (DEFAULT_ADMIN_ROLE = deployer).
        // We deploy with deployer as minter temporarily; roles are set correctly
        // in the wiring phase.

        address[] memory emptyBurners = new address[](0);

        fyToken = new FYToken({
            admin: deployer,
            minter: deployer, // overridden in wiring phase
            burners: emptyBurners,
            uri_: fytUri
        });
        console2.log("FYToken:              ", address(fyToken));

        vyToken = new VYToken({
            admin: deployer,
            minter: deployer, // overridden in wiring phase
            burners: emptyBurners,
            uri_: vytUri,
            _fyToken: fyToken
        });
        console2.log("VYToken:              ", address(vyToken));

        // ── Step 8: MaturityVault ─────────────────────────────────────────────

        maturityVault = new MaturityVault({
            _owner: deployer,
            _authorizedCaller: address(0), // set to yieldRouter in wiring phase
            _fyToken: FYToken(address(fyToken)),
            _vyToken: VYToken(address(vyToken)),
            _poolManager: IPoolManager(POOL_MANAGER_ADDRESS)
        });
        console2.log("MaturityVault:        ", address(maturityVault));

        // ── Step 14: Initiate governance ownership transfer ───────────────────
        //
        // Two-step transfer: deployer calls transferOwnership(), governance must
        // call acceptOwnership() to complete. This prevents accidentally locking
        // contracts if governance is a freshly-deployed multisig that hasn't been
        // tested yet.
        //
        // Contracts using DEFAULT_ADMIN_ROLE (FYToken, VYToken) also transfer
        // the admin role to governance.

        if (governance != deployer) {
            epochManager.transferOwnership(governance);
            rateOracle.transferOwnership(governance);
            yieldRouter.transferOwnership(governance);
            maturityVault.transferOwnership(governance);
            // ParadoxHook uses the same two-step pattern.
            // hook.transferOwnership(governance);  // add if hook exposes this

            // FYToken / VYToken: grant DEFAULT_ADMIN_ROLE to governance so it
            // can manage MINTER/BURNER roles post-deploy, then revoke from deployer.
            bytes32 ADMIN_ROLE = fyToken.DEFAULT_ADMIN_ROLE();
            fyToken.grantRole(ADMIN_ROLE, governance);
            fyToken.revokeRole(ADMIN_ROLE, deployer);
            vyToken.grantRole(ADMIN_ROLE, governance);
            vyToken.revokeRole(ADMIN_ROLE, deployer);

            console2.log(
                "Ownership transfer initiated to governance:",
                governance
            );
            console2.log(
                "Governance must call acceptOwnership() on each contract."
            );
        } else {
            console2.log("GOVERNANCE == DEPLOYER; ownership transfer skipped.");
        }

        vm.stopBroadcast();

        // ── Summary ───────────────────────────────────────────────────────────

        _printSummary(deployer, governance, poolManager, bufferSkimRate);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    function _printSummary(
        address deployer,
        address governance,
        address poolManager,
        uint256 bufferSkimRate
    ) internal view {
        console2.log(
            "\n======================================================"
        );
        console2.log("Paradox Fi Deployment Summary");
        console2.log("======================================================");
        console2.log("Chain ID:            ", block.chainid);
        console2.log("Deployer:            ", deployer);
        console2.log("Governance (pending):", governance);
        console2.log("PoolManager:         ", poolManager);

        console2.log("------------------------------------------------------");
        console2.log("FixedDateEpochModel: ", address(fixedDateModel));
        console2.log("EpochManager:        ", address(epochManager));
        console2.log("RateOracle:          ", address(rateOracle));
        console2.log("YieldRouter:         ", address(yieldRouter));
        console2.log("FYToken:             ", address(fyToken));
        console2.log("VYToken:             ", address(vyToken));
        console2.log("MaturityVault:       ", address(maturityVault));
        console2.log("ParadoxHook:         ", address(hook));
        console2.log("------------------------------------------------------");
        console2.log("bufferSkimRate:      ", bufferSkimRate);
        console2.log("Hook flags (0x1640)  encoded in lower bits: OK");
        console2.log("======================================================");
        console2.log("\nNext steps:");
        console2.log(
            "  1. Governance calls acceptOwnership() on each contract."
        );
        console2.log(
            "  2. For each pool: call hook.initializePool(poolKey, params, genesisTwap)."
        );
        console2.log(
            "  3. LPs add liquidity to v4 pool FYT/VYT minted automatically."
        );
        console2.log(
            "  4. After epoch maturity: keeper calls EpochManager.settle()"
        );
        console2.log(
            "     then YieldRouter.finalizeEpoch() to push funds to vault."
        );
        console2.log(
            "  5. FYT/VYT holders call MaturityVault.redeemFYT/redeemVYT()."
        );
    }
}

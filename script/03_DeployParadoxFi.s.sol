// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {EpochManager} from "../src/core/EpochManager.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {YieldRouter} from "../src/core/YieldRouter.sol";
import {MaturityVault} from "../src/core/MaturityVault.sol";
import {RateOracle} from "../src/core/RateOracle.sol";
import {ParadoxHook} from "../src/core/ParadoxHook.sol";
import {FYToken} from "../src/tokens/FYToken.sol";
import {VYToken} from "../src/tokens/VYToken.sol";
import {IFYToken} from "../src/interfaces/IFYToken.sol";
import {IVYToken} from "../src/interfaces/IVYToken.sol";
import {FixedDateEpochModel} from "../src/epochs/FixedDateEpochModel.sol";

contract DeployParadoxFi is Script {
    address constant POOL_MANAGER_ADDRESS =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    FixedDateEpochModel public fixedDateModel;
    EpochManager public epochManager;
    PositionManager public positionManager;
    RateOracle public rateOracle;
    YieldRouter public yieldRouter;
    FYToken public fyToken;
    VYToken public vyToken;
    MaturityVault public maturityVault;
    ParadoxHook public hook;

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

    function run() external {
        // ── Step 9: ParadoxHook (CREATE2) ─────────────────────────────────────
        //
        // The hook must be deployed at an address whose lower 14 bits encode the
        // permission flags (0x1640). The SALT env var is a pre-mined value that
        // produces such an address when used with CREATE2.
        //
        // The `new` keyword with a `salt` option uses CREATE2 in Foundry.
        // The resulting address is deterministic given (deployer, salt, initcode).
        //
        // IMPORTANT: the salt was mined against the full initcode including the
        // constructor args below. Any change to constructor args requires
        // re-mining the salt.
        _setCore();

        uint256 salt = vm.envUint("SALT");
        console2.log("SALT: ", salt);

        address deployer = vm.envAddress("DEPLOYER");

        uint256 bufferSkimRate = vm.envOr("BUFFER_SKIM_RATE", uint256(0.10e18));

        hook = new ParadoxHook{salt: bytes32(salt)}({
            _poolManager: IPoolManager(POOL_MANAGER_ADDRESS),
            _epochManager: epochManager,
            _positionManager: positionManager,
            _yieldRouter: yieldRouter,
            _rateOracle: rateOracle,
            _owner: deployer
        });

        console2.log("ParadoxHook:          ", address(hook));

        // Verify the hook address has the correct flags in its lower bits.
        // This will revert if the salt was mined incorrectly.
        require(
            uint160(address(hook)) & uint160(type(uint16).max) ==
                uint16(HOOK_FLAGS),
            "Deploy: hook address does not encode correct permission flags"
        );

        // ── Step 10: Wire authorizedCaller on core contracts ──────────────────

        epochManager.setAuthorizedCaller(address(hook));
        positionManager.setAuthorizedCaller(address(hook));
        rateOracle.setAuthorizedCaller(address(hook));
        yieldRouter.setAuthorizedCaller(address(hook));

        // MaturityVault is called by YieldRouter (receiveSettlement inside
        // finalizeEpoch), not the hook directly.
        maturityVault.setAuthorizedCaller(address(yieldRouter));

        console2.log("authorizedCaller set on all core contracts");

        // ── Step 11: Wire token roles ─────────────────────────────────────────
        //
        // FYToken / VYToken:
        //   MINTER_ROLE → hook (mints on afterAddLiquidity)
        //   BURNER_ROLE → hook (burns on early exit via beforeRemoveLiquidity)
        //   BURNER_ROLE → maturityVault (burns on redemption)
        //
        // Revoke the deployer's temporary MINTER_ROLE granted in the constructor.

        bytes32 MINTER_ROLE = fyToken.MINTER_ROLE();
        bytes32 BURNER_ROLE = fyToken.BURNER_ROLE();

        // FYToken roles.
        fyToken.grantRole(MINTER_ROLE, address(hook));
        fyToken.grantRole(BURNER_ROLE, address(hook));
        fyToken.grantRole(BURNER_ROLE, address(maturityVault));
        fyToken.revokeRole(MINTER_ROLE, deployer); // remove temporary minter

        // VYToken roles (same MINTER_ROLE / BURNER_ROLE bytes32 values).
        vyToken.grantRole(MINTER_ROLE, address(hook));
        vyToken.grantRole(BURNER_ROLE, address(hook));
        vyToken.grantRole(BURNER_ROLE, address(maturityVault));
        vyToken.revokeRole(MINTER_ROLE, deployer);

        console2.log("Token roles configured");

        // ── Step 12: Wire YieldRouter → MaturityVault ────────────────────────

        yieldRouter.setMaturityVault(address(maturityVault));
        console2.log("YieldRouter.maturityVault set");

        // ── Step 13: Configure buffer skim rate ───────────────────────────────

        if (bufferSkimRate != 0.10e18) {
            // 0.10e18 is the YieldRouter constructor default — skip if unchanged.
            yieldRouter.setBufferSkimRate(bufferSkimRate);
        }
        console2.log("bufferSkimRate:       ", bufferSkimRate);

        vm.stopBroadcast();
    }

    function _setCore() internal {
        fixedDateModel = FixedDateEpochModel(vm.envAddress("FIXED_RATE_MODEL"));
        epochManager = EpochManager(vm.envAddress("EPOCH_MANAGER"));
        positionManager = PositionManager(vm.envAddress("POSITION_MANAGER"));
        rateOracle = RateOracle(vm.envAddress("RATE_ORACLE"));
        yieldRouter = YieldRouter(vm.envAddress("YIELD_ROUTER"));
        fyToken = FYToken(vm.envAddress("FYT"));
        vyToken = VYToken(vm.envAddress("VYT"));
        maturityVault = MaturityVault(vm.envAddress("MATURITY_VAULT"));
    }
}

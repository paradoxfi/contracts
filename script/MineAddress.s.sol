// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import {HookMiner} from "../test/HookMiner.sol";
import {ParadoxHook} from "../src/core/ParadoxHook.sol";

contract ParadoxHookAddressMiner is Script {
    address constant POOL_MANAGER_ADDRESS =
        0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() external view {
        address epochManager = vm.envAddress("EPOCH_MANAGER");
        address yieldRouter = vm.envAddress("YIELD_ROUTER");
        address rateOracle = vm.envAddress("RATE_ORACLE");
        address sender = vm.envAddress("SENDER");
        address fyt = vm.envAddress("FYT");
        address vyt = vm.envAddress("VYT");

        bytes memory initCode = abi.encodePacked(
            type(ParadoxHook).creationCode,
            abi.encode(
                POOL_MANAGER_ADDRESS,
                epochManager,
                yieldRouter,
                rateOracle,
                fyt,
                vyt,
                sender
            )
        );

        uint160 mask = HookMiner.permissionsToMask(
            false,  // beforeInitialize
            true,  // afterInitialize
            false,  // beforeAddLiquidity
            true, // afterAddLiquidity
            true,  // beforeRemoveLiquidity
            false, // afterRemoveLiquidity
            false,  // beforeSwap
            true, // afterSwap
            false, false, false, false, false, false
        );

        uint256 salt = HookMiner.findSaltForMask(CREATE2_FACTORY, initCode, mask);
        console.log("SALT: ", salt);

        // Verify the predicted address has the right flags before trusting the salt
        address predicted = HookMiner.computeCreate2Address(
            salt,
            keccak256(initCode),
            CREATE2_FACTORY
        );

        console.log("Predicted:   ", predicted);
        console.log("Mask bits:   ", uint160(predicted) & HookMiner.ALL_HOOK_MASK);
    }
}

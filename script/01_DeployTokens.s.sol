// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

// =============================================================================
// DemoToken
// =============================================================================
// Minimal mintable ERC20 used only for the demo.
// The deployer is set as minter at construction time and is the only address
// that can call mint(). No other access control is needed for a testnet demo.
// =============================================================================

contract DemoToken is ERC20 {
    address public immutable minter;

    error NotMinter();

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals_
    ) ERC20(name, symbol, decimals_) {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        if (msg.sender != minter) revert NotMinter();
        _mint(to, amount);
    }
}

contract DeployTokens is Script {

    // Initial supply minted to the deployer.
    // 1_000_000 tokens with 18 decimals each.
    uint256 constant INITIAL_SUPPLY = 1_000_000 ether;

    function run() external returns (address tokenA, address tokenB) {
        uint256 deployerPrivKey = vm.envUint("KEY");
        address deployer = vm.addr(deployerPrivKey);

        console.log("Deployer:       ", deployer);
        console.log("Initial supply: ", INITIAL_SUPPLY / 1 ether, "tokens each");
        console.log("");

        vm.startBroadcast(deployerPrivKey);

        // Deploy DEMO_A
        DemoToken demoA = new DemoToken("Demo Token A", "DEMO_A", 18);
        demoA.mint(deployer, INITIAL_SUPPLY);

        // Deploy DEMO_B
        DemoToken demoB = new DemoToken("Demo Token B", "DEMO_B", 18);
        demoB.mint(deployer, INITIAL_SUPPLY);

        vm.stopBroadcast();

        tokenA = address(demoA);
        tokenB = address(demoB);

        // V4 requires currency0 < currency1 when constructing the PoolKey.
        // Log them in sorted order so the next script can use them directly.
        (address currency0, address currency1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        console.log("DEMO_A deployed to:  ", tokenA);
        console.log("DEMO_B deployed to:  ", tokenB);
        console.log("");
        console.log("Sorted for PoolKey:");
        console.log("  currency0:         ", currency0);
        console.log("  currency1:         ", currency1);
        console.log("");
        console.log("Deployer DEMO_A balance: ", demoA.balanceOf(deployer) / 1 ether);
        console.log("Deployer DEMO_B balance: ", demoB.balanceOf(deployer) / 1 ether);

        // Sanity checks
        require(demoA.balanceOf(deployer) == INITIAL_SUPPLY, "DEMO_A mint failed");
        require(demoB.balanceOf(deployer) == INITIAL_SUPPLY, "DEMO_B mint failed");
        require(demoA.minter() == deployer, "DEMO_A minter mismatch");
        require(demoB.minter() == deployer, "DEMO_B minter mismatch");
    }
}
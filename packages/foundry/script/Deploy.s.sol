// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Script, console2} from "forge-std/Script.sol";
import {USDC} from "../test/mocks/USDC.sol";
import {Core} from "../src/Core.sol";
import {Router} from "../src/Router.sol";
import {Multicall} from "../src/Multicall.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address treasury = vm.envOr("TREASURY_ADDRESS", address(0));
        address quote = vm.envOr("QUOTE_ADDRESS", address(0));

        vm.startBroadcast(deployerKey);

        if (quote == address(0)) {
            USDC usdc = new USDC();
            quote = address(usdc);
            console2.log("USDC mock deployed at:", quote);
        } else {
            console2.log("Using existing quote:", quote);
        }

        Core core = new Core(quote);
        console2.log("Core deployed at:", address(core));

        Router router = new Router(address(core));
        console2.log("Router deployed at:", address(router));

        Multicall multicall = new Multicall(address(core));
        console2.log("Multicall deployed at:", address(multicall));

        if (treasury != address(0)) {
            core.setTreasury(treasury);
            console2.log("Treasury set to:", treasury);
        } else {
            console2.log("Skipping setTreasury (TREASURY_ADDRESS not set)");
        }

        vm.stopBroadcast();
    }
}

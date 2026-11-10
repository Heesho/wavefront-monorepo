// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Script, console2} from "forge-std/Script.sol";

import {WavefrontRouter} from "../src/WavefrontRouter.sol";
import {IWavefrontHook} from "../src/interfaces/IWavefrontHook.sol";

/// @notice Launches a coin through the router, with the broadcaster making the first buy.
/// @dev Environment:
///        ROUTER         required  WavefrontRouter address
///        QUOTE          required  token the coin trades against (USDC on Base:
///                                 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
///        NAME, SYMBOL   required
///        URI            optional  metadata URI
///        SUPPLY         optional  raw units; defaults to 1,000,000,000 coins
///        VIRTUAL_QUOTE  required  raw quote units; the launch price is VIRTUAL_QUOTE / SUPPLY
///        FIRST_BUY      optional  raw quote units the broadcaster spends in the same transaction
///
///      Dry run, then for real:
///        forge script script/Launch.s.sol --rpc-url $BASE_RPC_URL --sender <address>
///        forge script script/Launch.s.sol --rpc-url $BASE_RPC_URL --account <name> --broadcast
contract Launch is Script {
    error NoUsableSalt();

    function run() external returns (address coin, uint256 coinOut) {
        WavefrontRouter router = WavefrontRouter(vm.envAddress("ROUTER"));
        uint256 firstBuy = vm.envOr("FIRST_BUY", uint256(0));
        IWavefrontHook.LaunchParams memory params = IWavefrontHook.LaunchParams({
            name: vm.envString("NAME"),
            symbol: vm.envString("SYMBOL"),
            uri: vm.envOr("URI", string("")),
            quote: vm.envAddress("QUOTE"),
            owner: msg.sender,
            team: msg.sender,
            supply: vm.envOr("SUPPLY", uint256(1_000_000_000e18)),
            virtualQuote: vm.envUint("VIRTUAL_QUOTE"),
            salt: bytes32(0)
        });
        params.salt = findSalt(router, msg.sender, params);

        vm.startBroadcast();
        if (firstBuy != 0) IERC20(params.quote).approve(address(router), firstBuy);
        (coin, coinOut) = router.launch(params, firstBuy, 0);
        vm.stopBroadcast();

        console2.log("coin        ", coin);
        console2.log("first buy   ", firstBuy);
        console2.log("coins bought", coinOut);
    }

    /// @notice A salt for which the coin's address sorts below its quote token, as v4 requires for the
    ///         price to read as quote per coin.
    function findSalt(WavefrontRouter router, address creator, IWavefrontHook.LaunchParams memory params)
        public
        view
        returns (bytes32)
    {
        for (uint256 i; i < 1000; ++i) {
            params.salt = bytes32(i);
            if (router.predictCoin(creator, params) < params.quote) return params.salt;
        }
        revert NoUsableSalt();
    }
}

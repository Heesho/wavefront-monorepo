// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {Coin} from "../src/Coin.sol";
import {IV1Coin} from "./reference/V1.sol";
import {WavefrontFixture} from "./utils/WavefrontFixture.sol";

/// @notice Prints the gas of the main operations next to v1's. Run with `-vv` to see the numbers.
contract GasTest is WavefrontFixture {
    uint256 internal constant ONE_USDC = 1e6;

    function setUp() public {
        _deployV1();
        _deployV4();
    }

    function test_gas_mainOperations() public {
        (Coin coin,) = _launch(creator, 100_000 * ONE_USDC);
        IV1Coin v1Coin = _createV1Coin(creator, 100_000 * ONE_USDC);
        _buy(coin, alice, 50_000 * ONE_USDC);
        _v1Buy(v1Coin, alice, 50_000 * ONE_USDC);
        // warm the accounts so the measurements below are steady-state
        _buy(coin, bob, 10 * ONE_USDC);
        _v1Buy(v1Coin, bob, 10 * ONE_USDC);

        quote.mint(bob, 100_000 * ONE_USDC);
        v1Quote.mint(bob, 100_000 * ONE_USDC);
        vm.startPrank(bob);
        quote.approve(address(router), type(uint256).max);
        coin.approve(address(router), type(uint256).max);
        v1Quote.approve(address(v1Router), type(uint256).max);
        v1Coin.approve(address(v1Router), type(uint256).max);

        uint256 gasBefore = gasleft();
        router.buy(address(coin), 10 * ONE_USDC, 0, 0);
        uint256 smallBuy = gasBefore - gasleft();
        gasBefore = gasleft();
        v1Router.buy(address(v1Coin), 10 * ONE_USDC, 0, 0);
        uint256 v1Buy = gasBefore - gasleft();

        gasBefore = gasleft();
        router.sell(address(coin), coin.balanceOf(bob) / 100, 0, 0);
        uint256 smallSell = gasBefore - gasleft();
        gasBefore = gasleft();
        v1Router.sell(address(v1Coin), v1Coin.balanceOf(bob) / 100, 0, 0);
        uint256 v1Sell = gasBefore - gasleft();

        gasBefore = gasleft();
        router.buy(address(coin), 20_000 * ONE_USDC, 0, 0);
        uint256 steppingBuy = gasBefore - gasleft();
        vm.stopPrank();

        uint256 amount = hook.creditOf(address(coin), alice) / 2;
        vm.startPrank(alice);
        gasBefore = gasleft();
        hook.borrow(address(coin), amount, alice);
        uint256 borrowGas = gasBefore - gasleft();
        gasBefore = gasleft();
        v1Coin.borrow(alice, amount);
        uint256 v1Borrow = gasBefore - gasleft();
        quote.approve(address(hook), amount);
        gasBefore = gasleft();
        hook.repay(address(coin), alice, amount);
        uint256 repayGas = gasBefore - gasleft();
        vm.stopPrank();

        console2.log("buy, floor does not step  v4 / v1", smallBuy, v1Buy);
        console2.log("sell, floor does not step v4 / v1", smallSell, v1Sell);
        console2.log("buy that steps the floor  v4", steppingBuy);
        console2.log("borrow                    v4 / v1", borrowGas, v1Borrow);
        console2.log("repay                     v4", repayGas);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Minimal views of the v1 contracts (packages/foundry, Solidity 0.8.19) used as the reference oracle.
interface IV1Coin {
    function reserveRealQuoteWad() external view returns (uint256);
    function reserveVirtQuoteWad() external view returns (uint256);
    function reserveCoinAmt() external view returns (uint256);
    function maxSupply() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getAccountCredit(address account) external view returns (uint256);
    function getAccountTransferrable(address account) external view returns (uint256);
    function heal(uint256 quoteRaw) external;
    function burn(uint256 coinAmt) external;
    function borrow(address to, uint256 quoteRaw) external;
    function repay(address to, uint256 quoteRaw) external;
    function setTeam(address newTeam) external;
    function getMarketPrice() external view returns (uint256);
    function getFloorPrice() external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IV1Router {
    function createCoin(string calldata name, string calldata symbol, uint256 amountQuoteIn) external returns (address);
    function buy(address coin, uint256 amountQuoteIn, uint256 minAmountCoinOut, uint256 expireTimestamp) external;
    function sell(address coin, uint256 amountCoinIn, uint256 minAmountQuoteOut, uint256 expireTimestamp) external;
}

interface IV1Core {
    function setTreasury(address treasury) external;
}

interface IV1Quote {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Deploys the real v1 system from packages/foundry's build output (run `forge build` there first).
abstract contract V1Fixture is Test {
    string internal constant V1_OUT = "../foundry/out/";

    IV1Quote internal v1Quote;
    IV1Core internal v1Core;
    IV1Router internal v1Router;

    address internal v1Treasury = makeAddr("v1Treasury");

    function _deployV1() internal {
        v1Quote = IV1Quote(deployCode(string.concat(V1_OUT, "USDC.sol/USDC.json")));
        v1Core = IV1Core(deployCode(string.concat(V1_OUT, "Core.sol/Core.json"), abi.encode(address(v1Quote))));
        v1Router = IV1Router(deployCode(string.concat(V1_OUT, "Router.sol/Router.json"), abi.encode(address(v1Core))));
        v1Core.setTreasury(v1Treasury);
    }

    /// @dev Launches a v1 coin with `creator` making the creation buy of `quoteIn`.
    function _createV1Coin(address creator, uint256 quoteIn) internal returns (IV1Coin coin) {
        v1Quote.mint(creator, quoteIn);
        vm.startPrank(creator);
        v1Quote.approve(address(v1Router), quoteIn);
        coin = IV1Coin(v1Router.createCoin("Wave", "WAVE", quoteIn));
        vm.stopPrank();
    }

    function _v1Buy(IV1Coin coin, address buyer, uint256 quoteIn) internal returns (uint256 coinOut) {
        v1Quote.mint(buyer, quoteIn);
        uint256 before = coin.balanceOf(buyer);
        vm.startPrank(buyer);
        v1Quote.approve(address(v1Router), quoteIn);
        v1Router.buy(address(coin), quoteIn, 0, 0);
        vm.stopPrank();
        coinOut = coin.balanceOf(buyer) - before;
    }

    function _v1Sell(IV1Coin coin, address seller, uint256 coinIn) internal returns (uint256 quoteOut) {
        uint256 before = v1Quote.balanceOf(seller);
        vm.startPrank(seller);
        coin.approve(address(v1Router), coinIn);
        v1Router.sell(address(coin), coinIn, 0, 0);
        vm.stopPrank();
        quoteOut = v1Quote.balanceOf(seller) - before;
    }
}

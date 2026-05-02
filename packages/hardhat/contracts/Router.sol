// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ICoin} from "./interfaces/ICoin.sol";

contract Router is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant CORE_COIN_AMT_REQUIRED = 1e18;

    address public immutable core;

    mapping(address => address) public account_Affiliate;

    event Router__CoinCreated(
        string name,
        string symbol,
        address indexed coin,
        address indexed creator,
        uint256 amountQuoteIn
    );
    event Router__Buy(
        address indexed coin,
        address indexed account,
        address indexed affiliate,
        uint256 amountQuoteIn,
        uint256 amountCoinOut
    );
    event Router__Sell(
        address indexed coin,
        address indexed account,
        address indexed affiliate,
        uint256 amountCoinIn,
        uint256 amountQuoteOut
    );
    event Router__AffiliateSet(address indexed account, address indexed affiliate);

    constructor(address _core) {
        core = _core;
    }

    function createCoin(string calldata name, string calldata symbol, uint256 amountQuoteIn)
        external
        nonReentrant
        returns (address coin)
    {
        address quote = ICore(core).quote();
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountQuoteIn);
        _safeApprove(quote, core, amountQuoteIn);
        coin = ICore(core).create(name, symbol, msg.sender, amountQuoteIn, CORE_COIN_AMT_REQUIRED);

        emit Router__CoinCreated(name, symbol, coin, msg.sender, amountQuoteIn);
    }

    function buy(
        address coin,
        address affiliate,
        uint256 amountQuoteIn,
        uint256 minAmountCoinOut,
        uint256 expireTimestamp
    ) external nonReentrant {
        _setAffiliate(affiliate);

        address quote = ICore(core).quote();
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountQuoteIn);
        _safeApprove(quote, coin, amountQuoteIn);

        uint256 amountCoinOut = ICoin(coin).buy(
            amountQuoteIn, minAmountCoinOut, expireTimestamp, msg.sender, account_Affiliate[msg.sender]
        );

        uint256 remainingQuote = IERC20(quote).balanceOf(address(this));
        if (remainingQuote > 0) {
            IERC20(quote).safeTransfer(msg.sender, remainingQuote);
        }

        emit Router__Buy(coin, msg.sender, affiliate, amountQuoteIn, amountCoinOut);
    }

    function sell(
        address coin,
        address affiliate,
        uint256 amountCoinIn,
        uint256 minAmountQuoteOut,
        uint256 expireTimestamp
    ) external nonReentrant {
        _setAffiliate(affiliate);

        IERC20(coin).safeTransferFrom(msg.sender, address(this), amountCoinIn);
        uint256 amountQuoteOut = ICoin(coin).sell(
            amountCoinIn, minAmountQuoteOut, expireTimestamp, msg.sender, account_Affiliate[msg.sender]
        );

        emit Router__Sell(coin, msg.sender, affiliate, amountCoinIn, amountQuoteOut);
    }

    function _setAffiliate(address affiliate) internal {
        if (account_Affiliate[msg.sender] == address(0) && affiliate != address(0)) {
            account_Affiliate[msg.sender] = affiliate;
            emit Router__AffiliateSet(msg.sender, affiliate);
        }
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).safeApprove(spender, 0);
        IERC20(token).safeApprove(spender, amount);
    }

    function withdrawStuckTokens(address _token, address _to) external onlyOwner {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(_to, balance);
    }
}

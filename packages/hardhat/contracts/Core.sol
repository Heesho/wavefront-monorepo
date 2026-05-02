// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Coin} from "./Coin.sol";
import {ICoin} from "./interfaces/ICoin.sol";

contract Core is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant RESERVE_VIRT_QUOTE_RAW = 100_000 * 1e6;
    uint256 public constant MINIMUM_CORE_AMT_REQUIRED = 1e18;

    address public immutable quote;
    address public treasury;

    uint256 public index;
    mapping(uint256 => address) public index_Coin;
    mapping(address => uint256) public coin_Index;

    error Core__InsufficientCoreAmtRequired();

    event Core__CoinCreated(string name, string symbol, uint256 index, address coin, address indexed owner);
    event Core__TreasurySet(address newTreasury);

    constructor(address _quote) Ownable() {
        quote = _quote;
    }

    function create(
        string memory name,
        string memory symbol,
        address owner,
        uint256 quoteRawIn,
        uint256 coreCoinAmtRequired
    ) external returns (address coin) {
        if (coreCoinAmtRequired < MINIMUM_CORE_AMT_REQUIRED) revert Core__InsufficientCoreAmtRequired();

        index++;

        coin = address(new Coin(
            name,
            symbol,
            address(this),
            quote,
            owner,
            INITIAL_SUPPLY,
            RESERVE_VIRT_QUOTE_RAW
        ));

        index_Coin[index] = coin;
        coin_Index[coin] = index;

        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteRawIn);
        IERC20(quote).safeApprove(coin, 0);
        IERC20(quote).safeApprove(coin, quoteRawIn);
        ICoin(coin).buy(quoteRawIn, 0, 0, address(this), address(0));
        IERC20(coin).safeTransfer(owner, IERC20(coin).balanceOf(address(this)) - coreCoinAmtRequired);

        emit Core__CoinCreated(name, symbol, index, coin, owner);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit Core__TreasurySet(_treasury);
    }
}

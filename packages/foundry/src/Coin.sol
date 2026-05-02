// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20, ERC20Permit, ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ICore} from "./interfaces/ICore.sol";

contract Coin is ERC20, ERC20Permit, ERC20Votes, ReentrancyGuard, Ownable {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant FEE = 100;
    uint256 public constant FEE_AMOUNT = 2_000;
    uint256 public constant DIVISOR = 10_000;
    uint256 public constant MIN_TRADE_SIZE = 1_000;

    address public immutable core;
    address public immutable quote;

    uint8 public immutable quoteDecimals;
    uint256 public immutable quoteScale;

    address public team;

    uint256 public maxSupply;

    uint256 public reserveRealQuoteWad;
    uint256 public reserveVirtQuoteWad;
    uint256 public reserveCoinAmt;

    uint256 public totalDebtRaw;
    mapping(address => uint256) public account_DebtRaw;

    error Coin__QuoteDecimals();
    error Coin__ZeroInput();
    error Coin__ZeroTo();
    error Coin__Expired();
    error Coin__MinTradeSize();
    error Coin__Slippage();
    error Coin__CollateralLocked();
    error Coin__CreditExceeded();
    error Coin__InvalidShift();
    error Coin__DivideByZero();
    error Coin__ReserveUnderflow();

    event Coin__Swap(
        address indexed from,
        uint256 quoteInRaw,
        uint256 coinIn,
        uint256 quoteOutRaw,
        uint256 coinOut,
        address indexed to
    );
    event Coin__SyncReserves(uint256 reserveRealQuoteWad, uint256 reserveVirtQuoteWad, uint256 reserveCoinAmt);
    event Coin__HealReserves(uint256 quoteWad, uint256 virtAddWad);
    event Coin__BurnReserves(uint256 coinAmt, uint256 reserveBurn);
    event Coin__ProviderFee(address indexed to, uint256 quoteRaw, uint256 coinAmt);
    event Coin__TeamFee(address indexed to, uint256 quoteRaw, uint256 coinAmt);
    event Coin__TreasuryFee(address indexed to, uint256 quoteRaw, uint256 coinAmt);
    event Coin__Heal(address indexed who, uint256 quoteRaw);
    event Coin__Burn(address indexed who, uint256 coinAmt);
    event Coin__Borrow(address indexed who, address indexed to, uint256 quoteRaw);
    event Coin__Repay(address indexed who, address indexed to, uint256 quoteRaw);
    event Coin__TeamSet(address indexed newTeam);

    modifier notZeroInput(uint256 amount) {
        if (amount == 0) revert Coin__ZeroInput();
        _;
    }

    modifier notZeroTo(address account) {
        if (account == address(0)) revert Coin__ZeroTo();
        _;
    }

    modifier notExpired(uint256 expireTimestamp) {
        if (expireTimestamp != 0 && expireTimestamp < block.timestamp) {
            revert Coin__Expired();
        }
        _;
    }

    modifier minTradeSize(uint256 amount) {
        if (amount < MIN_TRADE_SIZE) revert Coin__MinTradeSize();
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        address _core,
        address _quote,
        address _owner,
        uint256 _initialSupply,
        uint256 _virtQuoteRaw
    ) ERC20(name, symbol) ERC20Permit(name) {
        core = _core;
        quote = _quote;

        uint8 _quoteDecimals = IERC20Metadata(_quote).decimals();
        if (_quoteDecimals > 18) revert Coin__QuoteDecimals();
        quoteDecimals = _quoteDecimals;
        quoteScale = 10 ** (18 - _quoteDecimals);

        maxSupply = _initialSupply;
        reserveCoinAmt = _initialSupply;
        reserveVirtQuoteWad = rawToWad(_virtQuoteRaw);

        team = _owner;
        _transferOwnership(_owner);
    }

    function setTeam(address newTeam) external onlyOwner {
        if (newTeam == address(0)) revert Coin__ZeroTo();
        team = newTeam;
        emit Coin__TeamSet(newTeam);
    }

    function buy(uint256 quoteRawIn, uint256 minCoinAmtOut, uint256 deadline, address to, address provider)
        external
        nonReentrant
        notZeroTo(to)
        minTradeSize(quoteRawIn)
        notExpired(deadline)
        returns (uint256 coinAmtOut)
    {
        uint256 feeRaw;
        (coinAmtOut, feeRaw) = _processBuy(quoteRawIn, minCoinAmtOut);

        emit Coin__Swap(msg.sender, quoteRawIn, 0, 0, coinAmtOut, to);
        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteRawIn);

        uint256 healRaw = _processBuyFees(feeRaw, provider);
        if (healRaw > 0) _healQuoteReserves(healRaw);

        _mint(to, coinAmtOut);
    }

    function sell(uint256 coinAmtIn, uint256 minQuoteRawOut, uint256 deadline, address to, address provider)
        external
        nonReentrant
        notZeroTo(to)
        minTradeSize(coinAmtIn)
        notExpired(deadline)
        returns (uint256 quoteRawOut)
    {
        uint256 feeAmt;
        (quoteRawOut, feeAmt) = _processSell(coinAmtIn, minQuoteRawOut);

        emit Coin__Swap(msg.sender, 0, coinAmtIn, quoteRawOut, 0, to);
        _burn(msg.sender, coinAmtIn);

        uint256 burned = _processSellFees(feeAmt, provider);
        if (burned > 0) _burnCoinReserves(burned);

        IERC20(quote).safeTransfer(to, quoteRawOut);
    }

    function borrow(address to, uint256 quoteRaw) external nonReentrant notZeroTo(to) notZeroInput(quoteRaw) {
        uint256 credit = getAccountCredit(msg.sender);
        if (quoteRaw > credit) revert Coin__CreditExceeded();

        totalDebtRaw += quoteRaw;
        account_DebtRaw[msg.sender] += quoteRaw;

        emit Coin__Borrow(msg.sender, to, quoteRaw);
        IERC20(quote).safeTransfer(to, quoteRaw);
    }

    function repay(address to, uint256 quoteRaw) external nonReentrant notZeroTo(to) notZeroInput(quoteRaw) {
        totalDebtRaw -= quoteRaw;
        account_DebtRaw[to] -= quoteRaw;

        emit Coin__Repay(msg.sender, to, quoteRaw);
        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteRaw);
    }

    function heal(uint256 quoteRaw) external nonReentrant notZeroInput(quoteRaw) {
        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteRaw);
        _healQuoteReserves(quoteRaw);
        emit Coin__Heal(msg.sender, quoteRaw);
    }

    function burn(uint256 coinAmt) external nonReentrant notZeroInput(coinAmt) {
        _burn(msg.sender, coinAmt);
        _burnCoinReserves(coinAmt);
        emit Coin__Burn(msg.sender, coinAmt);
    }

    function rawToWad(uint256 raw) public view returns (uint256) {
        return raw * quoteScale;
    }

    function wadToRaw(uint256 wad) public view returns (uint256) {
        return wad / quoteScale;
    }

    function _processBuy(uint256 quoteRawIn, uint256 minCoinAmtOut)
        internal
        returns (uint256 coinAmtOut, uint256 feeRaw)
    {
        feeRaw = (quoteRawIn * FEE) / DIVISOR;
        uint256 netRaw = quoteRawIn - feeRaw;
        uint256 netWad = rawToWad(netRaw);

        uint256 y0 = reserveCoinAmt;
        uint256 x0 = reserveVirtQuoteWad + reserveRealQuoteWad;
        uint256 x1 = x0 + netWad;
        if (x1 == 0) revert Coin__DivideByZero();

        uint256 y1 = x0.mulWadUp(y0).divWadUp(x1);
        coinAmtOut = y0 - y1;
        if (coinAmtOut < minCoinAmtOut) revert Coin__Slippage();

        reserveRealQuoteWad = x1 - reserveVirtQuoteWad;
        reserveCoinAmt = y1;

        emit Coin__SyncReserves(reserveRealQuoteWad, reserveVirtQuoteWad, reserveCoinAmt);
    }

    function _processSell(uint256 coinAmtIn, uint256 minQuoteRawOut)
        internal
        returns (uint256 quoteRawOut, uint256 feeAmt)
    {
        feeAmt = (coinAmtIn * FEE) / DIVISOR;
        uint256 netAmt = coinAmtIn - feeAmt;

        uint256 x0 = reserveVirtQuoteWad + reserveRealQuoteWad;
        uint256 y0 = reserveCoinAmt;
        uint256 y1 = y0 + netAmt;
        if (y1 == 0) revert Coin__DivideByZero();

        uint256 x1 = x0.mulWadUp(y0).divWadUp(y1);
        uint256 quoteWadOut = x0 - x1;
        quoteRawOut = wadToRaw(quoteWadOut);

        if (quoteRawOut < minQuoteRawOut) revert Coin__Slippage();
        if (x1 < reserveVirtQuoteWad) revert Coin__ReserveUnderflow();

        reserveRealQuoteWad = x1 - reserveVirtQuoteWad;
        reserveCoinAmt = y1;

        emit Coin__SyncReserves(reserveRealQuoteWad, reserveVirtQuoteWad, reserveCoinAmt);
    }

    function _processBuyFees(uint256 quoteRaw, address provider) internal returns (uint256 remainingRaw) {
        remainingRaw = quoteRaw;
        uint256 feeRaw = (quoteRaw * FEE_AMOUNT) / DIVISOR;

        if (provider != address(0)) {
            IERC20(quote).safeTransfer(provider, feeRaw);
            emit Coin__ProviderFee(provider, feeRaw, 0);
            remainingRaw -= feeRaw;
        }

        IERC20(quote).safeTransfer(team, feeRaw);
        emit Coin__TeamFee(team, feeRaw, 0);
        remainingRaw -= feeRaw;

        address treasury = ICore(core).treasury();
        if (treasury != address(0)) {
            IERC20(quote).safeTransfer(treasury, feeRaw);
            emit Coin__TreasuryFee(treasury, feeRaw, 0);
            remainingRaw -= feeRaw;
        }

        return remainingRaw;
    }

    function _processSellFees(uint256 coinAmt, address provider) internal returns (uint256 remainingAmt) {
        remainingAmt = coinAmt;
        uint256 feeAmt = (coinAmt * FEE_AMOUNT) / DIVISOR;

        if (provider != address(0)) {
            _mint(provider, feeAmt);
            emit Coin__ProviderFee(provider, 0, feeAmt);
            remainingAmt -= feeAmt;
        }

        _mint(team, feeAmt);
        emit Coin__TeamFee(team, 0, feeAmt);
        remainingAmt -= feeAmt;

        address treasury = ICore(core).treasury();
        if (treasury != address(0)) {
            _mint(treasury, feeAmt);
            emit Coin__TreasuryFee(treasury, 0, feeAmt);
            remainingAmt -= feeAmt;
        }

        return remainingAmt;
    }

    function _healQuoteReserves(uint256 quoteRaw) internal {
        uint256 quoteWad = rawToWad(quoteRaw);
        uint256 m = maxSupply;
        uint256 y = reserveCoinAmt;
        if (m <= y) revert Coin__InvalidShift();

        uint256 virtAddWad = y.mulWadDown(quoteWad).divWadDown(m - y);

        reserveRealQuoteWad += quoteWad;
        reserveVirtQuoteWad += virtAddWad;

        emit Coin__HealReserves(quoteWad, virtAddWad);
    }

    function _burnCoinReserves(uint256 coinAmt) internal {
        uint256 m = maxSupply;
        uint256 y = reserveCoinAmt;
        if (m <= y) revert Coin__InvalidShift();

        uint256 reserveBurn = y.mulWadDown(coinAmt).divWadDown(m - y);

        reserveCoinAmt -= reserveBurn;
        maxSupply -= (coinAmt + reserveBurn);

        emit Coin__BurnReserves(coinAmt, reserveBurn);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._afterTokenTransfer(from, to, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20) {
        super._beforeTokenTransfer(from, to, amount);

        if (from != address(0) && account_DebtRaw[from] > 0) {
            uint256 transferrable = getAccountTransferrable(from);
            if (amount > transferrable) {
                revert Coin__CollateralLocked();
            }
        }
    }

    function _mint(address to, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._mint(to, amount);
    }

    function _burn(address account, uint256 amount) internal override(ERC20, ERC20Votes) {
        super._burn(account, amount);
    }

    function getMarketPrice() external view returns (uint256 price) {
        if (reserveCoinAmt == 0) return 0;
        uint256 totalQuoteWad = reserveVirtQuoteWad + reserveRealQuoteWad;
        return totalQuoteWad.divWadDown(reserveCoinAmt);
    }

    function getFloorPrice() external view returns (uint256 price) {
        if (maxSupply == 0) return 0;
        return reserveVirtQuoteWad.divWadDown(maxSupply);
    }

    function getAccountCredit(address account) public view returns (uint256 creditRaw) {
        uint256 balance = balanceOf(account);
        if (balance == 0) return 0;

        uint256 m = maxSupply;
        uint256 xv = reserveVirtQuoteWad;
        if (balance >= m) return 0;

        uint256 requiredWad = xv.mulWadDown(m).divWadDown(m - balance);
        uint256 creditLimitWad = requiredWad - xv;
        uint256 creditLimitRaw = wadToRaw(creditLimitWad);
        uint256 debtRaw = account_DebtRaw[account];

        creditRaw = creditLimitRaw > debtRaw ? creditLimitRaw - debtRaw : 0;
        return creditRaw;
    }

    function getAccountTransferrable(address account) public view returns (uint256 coinAmt) {
        uint256 debtRaw = account_DebtRaw[account];
        uint256 balance = balanceOf(account);
        if (debtRaw == 0) return balance;

        uint256 m = maxSupply;
        uint256 xv = reserveVirtQuoteWad;
        if (xv == 0) return 0;

        uint256 debtWad = rawToWad(debtRaw);
        uint256 requiredWad = xv + debtWad;
        if (requiredWad == 0) return 0;
        uint256 nonLocked = xv.mulWadDown(m).divWadDown(requiredWad);
        uint256 locked = m - nonLocked;

        coinAmt = balance > locked ? balance - locked : 0;
        return coinAmt;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {ICoin} from "./interfaces/ICoin.sol";
import {ICore} from "./interfaces/ICore.sol";

contract Multicall {
    using FixedPointMathLib for uint256;

    address public immutable core;

    struct CoinData {
        uint256 index;
        address coin;
        address quote;
        address team;
        address owner;
        string name;
        string symbol;
        uint256 marketCap;
        uint256 liquidity;
        uint256 floorPrice;
        uint256 marketPrice;
        uint256 circulatingSupply;
        uint256 maxSupply;
        uint256 accountQuoteBalance;
        uint256 accountCoinBalance;
        uint256 accountDebt;
        uint256 accountCredit;
        uint256 accountTransferrable;
    }

    constructor(address _core) {
        core = _core;
    }

    function getCoinData(address coin, address account) external view returns (CoinData memory data) {
        address quote = ICoin(coin).quote();
        uint256 precision = ICoin(coin).PRECISION();

        uint256 index = ICore(core).coin_Index(coin);

        data.index = index;
        data.coin = coin;
        data.quote = quote;
        data.team = ICoin(coin).team();
        data.owner = ICoin(coin).owner();

        data.name = IERC20Metadata(coin).name();
        data.symbol = IERC20Metadata(coin).symbol();

        data.marketCap = ICoin(coin).wadToRaw(
            ICoin(coin).maxSupply().mulDivDown(ICoin(coin).getMarketPrice(), precision)
        );
        data.liquidity = ICoin(coin).wadToRaw(
            ICoin(coin).reserveRealQuoteWad() + ICoin(coin).reserveVirtQuoteWad()
        ) * 2;
        data.floorPrice = ICoin(coin).getFloorPrice();
        data.marketPrice = ICoin(coin).getMarketPrice();
        data.circulatingSupply = IERC20(coin).totalSupply();
        data.maxSupply = ICoin(coin).maxSupply();

        if (account != address(0)) {
            data.accountQuoteBalance = IERC20(quote).balanceOf(account);
            data.accountCoinBalance = IERC20(coin).balanceOf(account);
            data.accountDebt = ICoin(coin).account_DebtRaw(account);
            data.accountCredit = ICoin(coin).getAccountCredit(account);
            data.accountTransferrable = ICoin(coin).getAccountTransferrable(account);
        }

        return data;
    }

    function buyQuoteIn(address coin, uint256 quoteRawIn, uint256 slippageTolerance)
        external
        view
        returns (uint256 coinAmtOut, uint256 slippage, uint256 minCoinAmtOut, uint256 autoMinCoinAmtOut)
    {
        if (quoteRawIn < ICoin(coin).MIN_TRADE_SIZE()) return (0, 0, 0, 0);

        uint256 fee = ICoin(coin).FEE();
        uint256 divisor = ICoin(coin).DIVISOR();
        uint256 precision = ICoin(coin).PRECISION();

        uint256 xr = ICoin(coin).reserveRealQuoteWad();
        uint256 xv = ICoin(coin).reserveVirtQuoteWad();

        uint256 quoteWadIn = ICoin(coin).rawToWad(quoteRawIn);
        uint256 feeRaw = (quoteRawIn * fee) / divisor;
        uint256 netRaw = quoteRawIn - feeRaw;
        uint256 netWad = ICoin(coin).rawToWad(netRaw);

        uint256 x0 = xv + xr;
        uint256 x1 = x0 + netWad;
        uint256 y0 = ICoin(coin).reserveCoinAmt();
        uint256 y1 = x0.mulWadUp(y0).divWadUp(x1);

        if (y1 >= y0) return (0, 0, 0, 0);

        coinAmtOut = y0 - y1;
        slippage = 100 * (precision - (coinAmtOut.mulDivDown(ICoin(coin).getMarketPrice(), quoteWadIn)));
        minCoinAmtOut =
            quoteWadIn.mulDivDown(precision, ICoin(coin).getMarketPrice()).mulDivDown(slippageTolerance, divisor);
        autoMinCoinAmtOut = quoteWadIn.mulDivDown(precision, ICoin(coin).getMarketPrice()).mulDivDown(
            (divisor * precision) - ((slippage + precision / 10) * 100), divisor * precision
        );
    }

    function sellCoinIn(address coin, uint256 coinAmtIn, uint256 slippageTolerance)
        external
        view
        returns (uint256 quoteRawOut, uint256 slippage, uint256 minQuoteRawOut, uint256 autoMinQuoteRawOut)
    {
        if (coinAmtIn < ICoin(coin).MIN_TRADE_SIZE()) return (0, 0, 0, 0);
        if (coinAmtIn > ICoin(coin).maxSupply()) return (0, 0, 0, 0);

        uint256 fee = ICoin(coin).FEE();
        uint256 divisor = ICoin(coin).DIVISOR();
        uint256 precision = ICoin(coin).PRECISION();

        uint256 xr = ICoin(coin).reserveRealQuoteWad();
        uint256 xv = ICoin(coin).reserveVirtQuoteWad();

        uint256 feeAmt = (coinAmtIn * fee) / divisor;
        uint256 netAmt = coinAmtIn - feeAmt;

        uint256 y0 = ICoin(coin).reserveCoinAmt();
        uint256 y1 = y0 + netAmt;
        uint256 x0 = xv + xr;
        uint256 x1 = x0.mulWadUp(y0).divWadUp(y1);

        if (x1 >= x0) return (0, 0, 0, 0);

        uint256 quoteWadOut = x0 - x1;
        quoteRawOut = ICoin(coin).wadToRaw(quoteWadOut);

        if (quoteRawOut == 0) return (0, 0, 0, 0);

        slippage = 100
            * (
                precision
                    - (quoteWadOut.mulDivDown(precision, coinAmtIn.mulDivDown(ICoin(coin).getMarketPrice(), precision)))
            );
        uint256 minQuoteWadOut =
            coinAmtIn.mulDivDown(ICoin(coin).getMarketPrice(), precision).mulDivDown(slippageTolerance, divisor);
        minQuoteRawOut = ICoin(coin).wadToRaw(minQuoteWadOut);
        uint256 autoMinQuoteWadOut = coinAmtIn.mulDivDown(ICoin(coin).getMarketPrice(), precision).mulDivDown(
            (divisor * precision) - ((slippage + precision / 10) * 100), divisor * precision
        );
        autoMinQuoteRawOut = ICoin(coin).wadToRaw(autoMinQuoteWadOut);
    }
}

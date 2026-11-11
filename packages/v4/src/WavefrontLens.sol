// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Coin} from "./Coin.sol";
import {IWavefrontHook} from "./interfaces/IWavefrontHook.sol";
import {CurveMath} from "./libraries/CurveMath.sol";

/// @title WavefrontLens
/// @notice Read-only aggregator for front ends: one call for a coin's state, plus exact-input quotes.
/// @dev Stateless and not relied on by any other contract.
contract WavefrontLens {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant FEE_DENOMINATOR = 1e6;

    /// @notice The wavefront hook this lens reads.
    IWavefrontHook public immutable hook;

    /// @notice Everything a front end needs about one coin and one account.
    struct CoinData {
        uint256 index;
        address coin;
        address quote;
        uint24 fee; // trade fee in hundredths of a bip; 20,000 is 2%
        string name;
        string symbol;
        address owner;
        address team;
        string uri;
        uint256 marketPrice; // whole quote per whole coin, 18 decimals
        uint256 floorPrice; // whole quote per whole coin, 18 decimals
        uint256 supply; // net of coins awaiting destruction
        uint256 pendingHeal; // quote waiting to join the curve
        uint256 pendingBurn; // coins waiting to be burned out of circulation
        uint128 liquidity;
        uint256 realQuote; // quote backing the curve, including quote lent out
        uint256 totalDebt;
        uint256 accountQuoteBalance;
        uint256 accountCoinBalance;
        uint256 accountDebt;
        uint256 accountCredit;
        uint256 accountLocked;
        uint256 accountTransferable;
    }

    /// @param hook_ The wavefront hook.
    constructor(IWavefrontHook hook_) {
        hook = hook_;
    }

    /// @notice State of `coin`, with `account`'s position if `account` is non-zero.
    /// @param coin Coin to read.
    /// @param account Account to read, or zero for market data only.
    /// @return data The aggregated state.
    function getCoinData(address coin, address account) external view returns (CoinData memory data) {
        IWavefrontHook.Market memory m = hook.market(coin);
        uint160 sqrtPrice = hook.sqrtPriceX96(coin);

        data.index = m.index;
        data.coin = coin;
        data.quote = m.quote;
        data.fee = m.fee;
        data.name = IERC20Metadata(coin).name();
        data.symbol = IERC20Metadata(coin).symbol();
        data.owner = Ownable(coin).owner();
        data.team = Coin(coin).team();
        data.uri = Coin(coin).contractURI();
        uint256 priceScale = _priceScale(coin, m.quote);
        data.marketPrice = _price(sqrtPrice, priceScale);
        data.floorPrice = _price(m.sqrtFloorX96, priceScale);
        data.supply = hook.effectiveSupply(coin);
        data.pendingHeal = m.pendingHeal;
        data.pendingBurn = m.pendingBurn;
        data.liquidity = m.liquidity;
        data.realQuote = CurveMath.realQuote(m.liquidity, m.sqrtFloorX96, sqrtPrice);
        data.totalDebt = m.totalDebt;

        if (account != address(0)) {
            data.accountQuoteBalance = IERC20(m.quote).balanceOf(account);
            data.accountCoinBalance = IERC20(coin).balanceOf(account);
            data.accountDebt = hook.debtOf(coin, account);
            data.accountCredit = hook.creditOf(coin, account);
            data.accountLocked = hook.lockedOf(coin, account);
            data.accountTransferable =
                data.accountCoinBalance > data.accountLocked ? data.accountCoinBalance - data.accountLocked : 0;
        }
    }

    /// @notice Coins an exact-input buy of `quoteIn` returns right now.
    /// @param coin Coin to buy.
    /// @param quoteIn Quote to spend.
    /// @return coinOut Coins received.
    function quoteBuy(address coin, uint256 quoteIn) external view returns (uint256 coinOut) {
        IWavefrontHook.Market memory m = hook.market(coin);
        if (m.liquidity == 0 || quoteIn == 0) return 0;
        uint160 sqrtPrice = hook.sqrtPriceX96(coin);
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPrice, m.liquidity, _lessFee(coin, quoteIn), false);
        return SqrtPriceMath.getAmount0Delta(sqrtPrice, next, m.liquidity, false);
    }

    /// @notice Quote an exact-input sell of `coinIn` returns right now.
    /// @dev A sell larger than the position can absorb fills only down to the position's lower tick.
    /// @param coin Coin to sell.
    /// @param coinIn Coins to sell.
    /// @return quoteOut Quote received.
    function quoteSell(address coin, uint256 coinIn) external view returns (uint256 quoteOut) {
        IWavefrontHook.Market memory m = hook.market(coin);
        if (m.liquidity == 0 || coinIn == 0) return 0;
        uint160 sqrtPrice = hook.sqrtPriceX96(coin);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);
        if (sqrtPrice <= sqrtLower) return 0;
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPrice, m.liquidity, _lessFee(coin, coinIn), true);
        if (next < sqrtLower) next = sqrtLower;
        return SqrtPriceMath.getAmount1Delta(next, sqrtPrice, m.liquidity, false);
    }

    /// @dev The part of an input that reaches the curve after the pool's LP fee.
    function _lessFee(address coin, uint256 amountIn) internal view returns (uint256) {
        PoolKey memory key = hook.poolKey(coin);
        return FullMath.mulDiv(amountIn, FEE_DENOMINATOR - key.fee, FEE_DENOMINATOR);
    }

    /// @dev Scales a raw quote-per-raw-coin price to an 18-decimal price of whole quote per whole coin.
    function _priceScale(address coin, address quote) internal view returns (uint256) {
        return FullMath.mulDiv(WAD, 10 ** IERC20Metadata(coin).decimals(), 10 ** IERC20Metadata(quote).decimals());
    }

    /// @dev Converts a sqrt price (raw quote per raw coin, Q64.96) to an 18-decimal price.
    function _price(uint160 sqrtPriceX96, uint256 priceScale) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return FullMath.mulDiv(priceX96, priceScale, FixedPoint96.Q96);
    }
}

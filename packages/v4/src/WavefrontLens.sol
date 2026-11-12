// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IImmutableState} from "@uniswap/v4-periphery/src/interfaces/IImmutableState.sol";

import {Coin} from "./Coin.sol";
import {IWavefrontHook} from "./interfaces/IWavefrontHook.sol";

/// @title WavefrontLens
/// @notice Read-only aggregator for front ends: one call for a coin's state, plus exact-input quotes.
/// @dev Stateless and not relied on by any other contract.
contract WavefrontLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant FEE_DENOMINATOR = 1e6;

    /// @notice The wavefront hook this lens reads.
    IWavefrontHook public immutable hook;
    /// @notice The Uniswap v4 PoolManager the hook's pools live in.
    IPoolManager public immutable poolManager;

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
        uint256 realQuote; // quote backing the curve: in the position, idle, or lent out; not `pendingHeal`
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
        poolManager = IImmutableState(address(hook_)).poolManager();
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
        data.realQuote = _realQuote(m, sqrtPrice);
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
        (uint160 sqrtPrice, uint24 swapFee) = _priceAndSwapFee(coin, false);
        uint160 next =
            SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPrice, m.liquidity, _lessFee(quoteIn, swapFee), false);
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
        (uint160 sqrtPrice, uint24 swapFee) = _priceAndSwapFee(coin, true);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);
        if (sqrtPrice <= sqrtLower) return 0;
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPrice, m.liquidity, _lessFee(coinIn, swapFee), true);
        if (next < sqrtLower) next = sqrtLower;
        return SqrtPriceMath.getAmount1Delta(next, sqrtPrice, m.liquidity, false);
    }

    /// @notice The pool's price and the fee a swap in the given direction pays right now.
    /// @dev That fee is the pool's LP fee plus, when Uniswap governance has switched one on for the
    ///      pool, the protocol fee, combined exactly as the PoolManager combines them (see `Pool.swap`).
    /// @param coin Coin whose pool to read.
    /// @param zeroForOne True for a sell (coin in), false for a buy (quote in). The protocol fee is
    ///        set per direction.
    /// @return sqrtPrice Current pool sqrt price.
    /// @return swapFee Total fee taken from the input, in hundredths of a bip.
    function _priceAndSwapFee(address coin, bool zeroForOne) internal view returns (uint160 sqrtPrice, uint24 swapFee) {
        uint24 protocolFees;
        (sqrtPrice,, protocolFees, swapFee) = poolManager.getSlot0(hook.poolKey(coin).toId());
        uint16 protocolFee = zeroForOne ? protocolFees.getZeroForOneFee() : protocolFees.getOneForZeroFee();
        if (protocolFee != 0) swapFee = protocolFee.calculateSwapFee(swapFee);
    }

    /// @dev The part of an input that reaches the curve after `swapFee`.
    function _lessFee(uint256 amountIn, uint24 swapFee) internal pure returns (uint256) {
        return FullMath.mulDiv(amountIn, FEE_DENOMINATOR - swapFee, FEE_DENOMINATOR);
    }

    /// @dev Real quote backing the curve, as the hook itself counts it when it decides whether the
    ///      floor can rise: what the position holds between its lower tick and the pool price, plus
    ///      what waits idle outside it, plus what is lent out.
    function _realQuote(IWavefrontHook.Market memory m, uint160 sqrtPrice) internal pure returns (uint256) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);
        uint256 inPosition =
            sqrtPrice > sqrtLower ? SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, m.liquidity, false) : 0;
        return inPosition + m.idleQuote + m.totalDebt;
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

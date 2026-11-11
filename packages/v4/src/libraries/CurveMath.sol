// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title CurveMath
/// @notice Pure math for wavefront's bonding curve expressed as a single Uniswap v4 liquidity position.
/// @dev The v1 curve `(virtQuote + realQuote) * coinReserve = k` with a floor at `virtQuote / maxSupply`
///      is the same curve as one concentrated-liquidity position that spans from the floor price to
///      (effectively) infinity. With `L` the position's liquidity, `s` the current sqrt price and `a`
///      the floor sqrt price (both quote-per-coin, Q64.96):
///
///        virtQuote  = L * a          realQuote   = L * (s - a)
///        maxSupply  = L / a          coinReserve = L / s
///
///      v1 never stores `L`, `s` or `a`. Its state is three reserves: the real quote `X`, the coins in
///      the pool `y` and the supply `S`. A heal adds to `X`; a burn removes coins from `y` and from
///      circulation `C = S - y` in the same proportion. The position follows from the reserves alone
///      ({sqrtFloorFor}, {sqrtPriceFor}), so this library has no heal or burn formula.
///
///      Every function is O(1). Rounding always favours the pool: amounts the pool pays out or promises
///      (floor, price, credit, liquidity) round down; amounts owed to the pool (coins locked, debt
///      boundary) round up.
library CurveMath {
    using SafeCast for uint256;

    uint256 internal constant Q96 = FixedPoint96.Q96;

    /// @notice Thrown when a position would have to be built from no coins.
    error EmptyCurve();
    /// @notice Thrown when a price argument is not strictly inside the range it is measured against.
    error PriceOutOfRange();

    /*//////////////////////////////////////////////////////////////
                              POSITION SIZING
    //////////////////////////////////////////////////////////////*/

    /// @notice Floor sqrt price of a freshly launched coin: sqrt(virtualQuote / supply).
    /// @param virtualQuote Virtual quote reserve in raw quote units. `virtualQuote / supply` must be below 2^64.
    /// @param supply Total coin supply in raw coin units.
    /// @return sqrtPriceX96 Floor sqrt price (quote per coin, Q64.96), rounded down.
    function floorSqrtPriceX96(uint256 virtualQuote, uint256 supply) internal pure returns (uint160 sqrtPriceX96) {
        return Math.sqrt(FullMath.mulDiv(virtualQuote, 1 << 192, supply)).toUint160();
    }

    /// @notice Liquidity of a position `[sqrtPrice, sqrtUpper]` that holds exactly `coinAmount` coins.
    /// @dev Rounds down, so re-adding the position never needs more coins than `coinAmount`.
    function liquidityForCoin(uint256 coinAmount, uint160 sqrtPriceX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceX96 >= sqrtUpperX96) revert PriceOutOfRange();
        uint256 intermediate = FullMath.mulDiv(sqrtPriceX96, sqrtUpperX96, Q96);
        return FullMath.mulDiv(coinAmount, intermediate, sqrtUpperX96 - sqrtPriceX96).toUint128();
    }

    /// @notice Real quote backing the curve: everything between the floor and the current price.
    /// @dev Rounds down. Includes quote that has been lent out.
    function realQuote(uint128 liquidity, uint160 sqrtFloorX96, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        if (sqrtPriceX96 <= sqrtFloorX96) return 0;
        return FullMath.mulDiv(liquidity, sqrtPriceX96 - sqrtFloorX96, Q96);
    }

    /*//////////////////////////////////////////////////////////////
                           SHAPE FROM RESERVES
    //////////////////////////////////////////////////////////////*/

    /// @notice Floor sqrt price of the curve that holds `quote` and `coins` while `circulating` coins are
    ///         outside it: the floor at which selling every circulating coin takes out exactly `quote`.
    /// @dev Selling all `C` circulating coins for all `X` real quote happens at the average price
    ///      `X / C = a * s`, and the curve's shape gives `s / a = S / y` with `S = C + y`. Hence
    ///      `a = sqrt(X * y / (C * S))`. This is v1's floor written in v1's own reserves, so a heal
    ///      (`X` grows) and a burn (`C` and `y` shrink together) need no formula of their own.
    ///      Rounds down. The result can exceed `uint160` on a nearly empty circulation; callers clamp.
    /// @param quote Real quote backing the curve `X`: in the position, idle, or lent out.
    /// @param coins Coins held by the position `y`.
    /// @param circulating Coins outside the position `C`; must not be zero.
    /// @return sqrtFloorX96 Floor sqrt price (quote per coin, Q64.96).
    function sqrtFloorFor(uint256 quote, uint256 coins, uint256 circulating)
        internal
        pure
        returns (uint256 sqrtFloorX96)
    {
        uint256 denominator = Math.sqrt(circulating * (circulating + coins), Math.Rounding.Ceil);
        return FullMath.mulDiv(Math.sqrt(quote * coins), Q96, denominator);
    }

    /// @notice Sqrt price of the position `[sqrtFloor, sqrtUpper]` that holds `coins` coins and as much of
    ///         `quote` as v1's curve at that floor does.
    /// @dev With `L` the liquidity, `a` the floor and `u` the upper bound, `quote = L * (s - a)` and
    ///      `coins = L * (1/s - 1/u)`. Eliminating `s` leaves a quadratic in `L`:
    ///
    ///        (1 - a/u) * L^2 - (coins * a + quote / u) * L - quote * coins = 0
    ///
    ///      That is the most liquidity the reserves can pay for. v1's curve at floor `a` has exactly the
    ///      liquidity of the position that holds the whole `supply` at the floor, and the result is
    ///      capped there: with the floor rounded down to a tick the reserves afford a little more, and
    ///      that surplus is left out of the position until it is enough to lift the floor a tick.
    ///      Keeping to v1's curve is what makes the coins backing a debt depend on the floor and the
    ///      supply alone, so that they never grow.
    ///
    ///      Every step rounds down, so the position at the returned price never needs more than `quote`.
    /// @param quote Real quote backing the curve.
    /// @param coins Coins held by the position; must not be zero.
    /// @param supply Coin supply: `coins` plus everything in circulation.
    /// @param sqrtFloorX96 Floor sqrt price.
    /// @param sqrtUpperX96 Sqrt price at the top of the position.
    /// @return sqrtPriceX96 The price, never below the floor.
    function sqrtPriceFor(uint256 quote, uint256 coins, uint256 supply, uint160 sqrtFloorX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        uint256 range = sqrtUpperX96 - sqrtFloorX96;
        uint256 b = FullMath.mulDiv(coins, sqrtFloorX96, Q96) + FullMath.mulDiv(quote, Q96, sqrtUpperX96);
        uint256 root = Math.sqrt(b * b + FullMath.mulDiv(4 * quote * coins, range, sqrtUpperX96));
        uint256 liquidity = FullMath.mulDiv(b + root, sqrtUpperX96, 2 * range);

        uint256 v1Liquidity = liquidityForCoin(supply, sqrtFloorX96, sqrtUpperX96);
        if (liquidity > v1Liquidity) liquidity = v1Liquidity;

        // coins = L * (1/s - 1/u), solved for s
        uint256 sqrtPrice =
            FullMath.mulDiv(liquidity, Q96, coins + FullMath.mulDivRoundingUp(liquidity, Q96, sqrtUpperX96));
        return sqrtPrice < sqrtFloorX96 ? sqrtFloorX96 : sqrtPrice.toUint160();
    }

    /*//////////////////////////////////////////////////////////////
                                 LENDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Sqrt price below which the position's quote has been lent out.
    /// @dev The quote between the floor and this price equals `totalDebt`. Rounds up, so at least
    ///      `totalDebt` is freed when the position's lower bound is moved here.
    function debtBoundarySqrtPriceX96(uint128 liquidity, uint160 sqrtFloorX96, uint256 totalDebt)
        internal
        pure
        returns (uint160 sqrtBoundaryX96)
    {
        if (totalDebt == 0) return sqrtFloorX96;
        return (uint256(sqrtFloorX96) + FullMath.mulDivRoundingUp(totalDebt, Q96, liquidity)).toUint160();
    }

    /// @notice Credit limit of a holder: what `balance` coins fetch if sold when every other coin has
    ///         already been sold. Same closed form as v1's `getAccountCredit` before subtracting debt.
    /// @dev Rounds down.
    function creditLimit(uint128 liquidity, uint160 sqrtFloorX96, uint256 balance)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        if (balance == 0 || liquidity == 0) return 0;
        uint256 virtualQuote = FullMath.mulDiv(liquidity, sqrtFloorX96, Q96);
        uint256 maxSupply = FullMath.mulDiv(liquidity, Q96, sqrtFloorX96);
        if (balance >= maxSupply) return 0;
        return FullMath.mulDiv(virtualQuote, balance, maxSupply - balance);
    }

    /// @notice Coins that back `debt`: what would have to be sold to push the price from the debt's own
    ///         boundary down to the floor. Same amount v1 locks.
    /// @dev Rounds up. For fixed `debt` it never grows as the curve heals or burns.
    /// @param liquidity Liquidity of the live position.
    /// @param sqrtFloorX96 Floor sqrt price.
    /// @param debt The account's debt.
    /// @return coinAmount Coins locked.
    function lockedCoins(uint128 liquidity, uint160 sqrtFloorX96, uint256 debt)
        internal
        pure
        returns (uint256 coinAmount)
    {
        if (debt == 0) return 0;
        uint256 sqrtDebt = uint256(sqrtFloorX96) + FullMath.mulDivRoundingUp(debt, Q96, liquidity);
        return FullMath.mulDivRoundingUp(liquidity, Q96, sqrtFloorX96) - FullMath.mulDiv(liquidity, Q96, sqrtDebt);
    }

    /// @notice Coins a position with `liquidity` takes in as the price falls from `sqrtUpper` to `sqrtLower`.
    /// @dev Rounds up.
    /// @param liquidity Liquidity of the position.
    /// @param sqrtLowerX96 Lower sqrt price.
    /// @param sqrtUpperX96 Upper sqrt price.
    /// @return coinAmount Coins absorbed across the range.
    function coinsBetween(uint128 liquidity, uint160 sqrtLowerX96, uint160 sqrtUpperX96)
        internal
        pure
        returns (uint256 coinAmount)
    {
        return FullMath.mulDivRoundingUp(liquidity, Q96, sqrtLowerX96) - FullMath.mulDiv(liquidity, Q96, sqrtUpperX96);
    }
}

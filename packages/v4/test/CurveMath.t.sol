// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {CurveMath} from "../src/libraries/CurveMath.sol";
import {TickRounding} from "../src/libraries/TickRounding.sol";
import {IV1Coin, V1Fixture} from "./reference/V1.sol";

/// @notice Differential tests: every CurveMath formula is checked against the deployed v1 Coin.
contract CurveMathTest is V1Fixture {
    uint256 internal constant QUOTE_SCALE = 1e12; // v1 keeps quote reserves in WAD; USDC has 6 decimals
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant VIRT_QUOTE = 100_000e6;

    /// @dev v1 rounds in WAD and this harness derives sqrt prices with an integer sqrt, so parity is
    ///      asserted to one part in a billion rather than exactly.
    uint256 internal constant TOLERANCE = 1e9; // 1e-9 relative, in forge's 1e18 = 100% scale

    address internal creator = makeAddr("creator");
    address internal donor = makeAddr("donor");

    /// @dev v1 state translated into the position variables CurveMath works in.
    struct Position {
        uint128 liquidity;
        uint160 sqrtPriceX96;
        uint160 sqrtFloorX96;
        uint256 coinReserve;
        uint256 circulating;
        uint256 realQuote;
    }

    function setUp() public {
        _deployV1();
    }

    function _position(IV1Coin coin) internal view returns (Position memory p) {
        uint256 virtQuote = coin.reserveVirtQuoteWad() / QUOTE_SCALE;
        uint256 totalQuote = (coin.reserveVirtQuoteWad() + coin.reserveRealQuoteWad()) / QUOTE_SCALE;
        uint256 coinReserve = coin.reserveCoinAmt();
        uint256 maxSupply = coin.maxSupply();

        p.liquidity = uint128(Math.sqrt(totalQuote * coinReserve));
        p.sqrtPriceX96 = uint160(Math.sqrt(FullMath.mulDiv(totalQuote, 1 << 192, coinReserve)));
        p.sqrtFloorX96 = uint160(Math.sqrt(FullMath.mulDiv(virtQuote, 1 << 192, maxSupply)));
        p.coinReserve = coinReserve;
        p.circulating = maxSupply - coinReserve;
        p.realQuote = coin.reserveRealQuoteWad() / QUOTE_SCALE;
    }

    /*//////////////////////////////////////////////////////////////
                              POSITION SIZING
    //////////////////////////////////////////////////////////////*/

    function test_floorSqrtPrice_matchesV1AtLaunch() public {
        IV1Coin coin = _createV1Coin(creator, 1000e6);
        // the creation buy heals the floor, so compare against the launch constants instead
        uint160 expected = uint160(Math.sqrt(FullMath.mulDiv(VIRT_QUOTE, 1 << 192, SUPPLY)));
        assertEq(CurveMath.floorSqrtPriceX96(VIRT_QUOTE, SUPPLY), expected);
        assertGt(_position(coin).sqrtFloorX96, expected, "creation buy should have raised the floor");
    }

    /// @notice The position identity itself: v1's reserves are exactly one position from the floor up.
    function testFuzz_positionIdentity_matchesV1(uint256 buyIn) public {
        buyIn = bound(buyIn, 1e6, 1_000_000e6);
        Position memory p = _position(_createV1Coin(creator, buyIn));

        // realQuote = L * (s - a); a couple of raw units of slack for the integer square roots above
        uint256 derived = CurveMath.realQuote(p.liquidity, p.sqrtFloorX96, p.sqrtPriceX96);
        assertApproxEqAbs(derived, p.realQuote, 2 + p.realQuote / 1e9);
        // coinReserve = L / s, i.e. the liquidity that holds `coinReserve` above the price is L
        uint160 sqrtMax = TickMath.MAX_SQRT_PRICE - 1;
        assertApproxEqRel(CurveMath.liquidityForCoin(p.coinReserve, p.sqrtPriceX96, sqrtMax), p.liquidity, TOLERANCE);
    }

    function testFuzz_liquidityForCoin_neverNeedsMoreCoin(uint256 coinAmount, uint160 sqrtPriceX96) public pure {
        coinAmount = bound(coinAmount, 1e18, SUPPLY);
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, 1e18, 1e30));
        uint160 sqrtMax = TickMath.MAX_SQRT_PRICE - 1;

        uint128 liquidity = CurveMath.liquidityForCoin(coinAmount, sqrtPriceX96, sqrtMax);
        // what the PoolManager charges for that position, using its own rounding
        uint256 needed = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtMax, liquidity, true);
        assertLe(needed, coinAmount);
    }

    /*//////////////////////////////////////////////////////////////
                           SHAPE FROM RESERVES
    //////////////////////////////////////////////////////////////*/

    /// @notice v1's floor and price follow from its three reserves alone, after any trade.
    function testFuzz_reserves_reproduceV1(uint256 buyIn, uint256 sellBps) public {
        buyIn = bound(buyIn, 1e6, 1_000_000e6);
        sellBps = bound(sellBps, 0, 9000);
        IV1Coin coin = _createV1Coin(creator, buyIn);
        if (sellBps != 0) _v1Sell(coin, creator, (coin.balanceOf(creator) * sellBps) / 10_000);

        _assertShape(coin, _position(coin));
    }

    /// @notice A heal is nothing more than quote added to the reserves.
    function testFuzz_heal_isQuoteAdded_matchesV1(uint256 buyIn, uint256 healAmount) public {
        buyIn = bound(buyIn, 1e6, 1_000_000e6);
        healAmount = bound(healAmount, 1e3, 1_000_000e6);
        IV1Coin coin = _createV1Coin(creator, buyIn);
        Position memory p = _position(coin);

        v1Quote.mint(donor, healAmount);
        vm.startPrank(donor);
        v1Quote.approve(address(coin), healAmount);
        coin.heal(healAmount);
        vm.stopPrank();

        p.realQuote += healAmount;
        _assertShape(coin, p);
        assertGe(_position(coin).sqrtFloorX96, p.sqrtFloorX96, "floor must not fall");
    }

    /// @notice A burn is nothing more than coins leaving the pool in the proportion they leave circulation.
    function testFuzz_burn_isProportional_matchesV1(uint256 buyIn, uint256 burnBps) public {
        buyIn = bound(buyIn, 1e6, 1_000_000e6);
        burnBps = bound(burnBps, 1, 9900);
        IV1Coin coin = _createV1Coin(creator, buyIn);
        Position memory p = _position(coin);
        uint256 burnAmount = (coin.balanceOf(creator) * burnBps) / 10_000;
        vm.assume(burnAmount > 0);

        vm.prank(creator);
        coin.burn(burnAmount);

        p.coinReserve -= FullMath.mulDiv(p.coinReserve, burnAmount, p.circulating);
        p.circulating -= burnAmount;
        assertApproxEqRel(p.coinReserve, coin.reserveCoinAmt(), TOLERANCE, "coins in the pool");
        _assertShape(coin, p);
        assertGe(_position(coin).sqrtFloorX96, p.sqrtFloorX96, "floor must not fall");
    }

    /// @notice The position {sqrtPriceFor} describes can always be paid for out of the reserves, by the
    ///         PoolManager's own rounding. It holds all the coins, never has more liquidity than v1's
    ///         curve at that floor, and unless it is that curve it uses up the quote too.
    function testFuzz_sqrtPriceFor_fitsTheReserves(uint256 quote, uint256 coins, uint256 circulating, int24 floorTick)
        public
        pure
    {
        coins = bound(coins, 1e18, 1e30);
        circulating = bound(circulating, 0, 1e30);
        quote = bound(quote, 0, 1e30);
        floorTick = int24(bound(floorTick, -80_000, 40_000)) * 10;
        uint160 sqrtFloor = TickMath.getSqrtPriceAtTick(floorTick);
        uint160 sqrtMax = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(10));
        // keep to what a v4 position can hold
        vm.assume(FullMath.mulDiv(coins + circulating, sqrtFloor, 1 << 96) <= type(uint104).max);

        uint160 sqrtPrice = CurveMath.sqrtPriceFor(quote, coins, coins + circulating, sqrtFloor, sqrtMax);
        assertGe(sqrtPrice, sqrtFloor, "price below the floor");
        vm.assume(sqrtPrice < TickMath.getSqrtPriceAtTick(700_000));
        uint128 liquidity = CurveMath.liquidityForCoin(coins, sqrtPrice, sqrtMax);
        vm.assume(liquidity >= 1e12);

        uint256 quoteNeeded = SqrtPriceMath.getAmount1Delta(sqrtFloor, sqrtPrice, liquidity, true);
        uint256 coinsNeeded = SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtMax, liquidity, true);
        assertLe(quoteNeeded, quote, "needs more quote than the reserves hold");
        assertLe(coinsNeeded, coins, "needs more coins than the reserves hold");
        assertApproxEqAbs(coinsNeeded, coins, coins / 1e9 + 2, "leaves coins unused");

        uint128 v1Liquidity = CurveMath.liquidityForCoin(coins + circulating, sqrtFloor, sqrtMax);
        assertLe(liquidity, v1Liquidity, "more liquidity than v1's curve at this floor");
        if (liquidity < v1Liquidity - v1Liquidity / 1e9 - 6) {
            // Liquidity and coins are whole numbers. Each rounding step can drop one raw unit of either;
            // a unit of liquidity is worth about twice the sqrt price in quote and a raw coin is worth
            // the price. Next to reserves of at least 1e12 and 1e18 of them that is nothing.
            uint256 dust = FullMath.mulDivRoundingUp(2 * 6, sqrtPrice, 1 << 96)
                + FullMath.mulDivRoundingUp(4 * uint256(sqrtPrice), sqrtPrice, 1 << 192);
            assertApproxEqAbs(quoteNeeded, quote, quote / 1e9 + 2 + dust, "leaves quote unused");
        }
    }

    /// @notice With the floor rounded down to a tick, as the hook does, the position is v1's curve at
    ///         that floor: it absorbs every circulating coin exactly as the price reaches the floor, and
    ///         leaves less than a tick spacing's worth of the quote out.
    function testFuzz_sqrtFloorFor_everyCoinCanBeSold(uint256 quote, uint256 coins, uint256 circulating) public pure {
        coins = bound(coins, 1e21, 1e30);
        circulating = bound(circulating, 1e18, 1e30);
        quote = bound(quote, 1e6, 1e24);
        uint160 sqrtMax = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(10));

        uint256 target = CurveMath.sqrtFloorFor(quote, coins, circulating);
        vm.assume(target > TickMath.getSqrtPriceAtTick(-800_000) && target < TickMath.getSqrtPriceAtTick(400_000));
        int24 floorTick = TickMath.getTickAtSqrtPrice(uint160(target));
        floorTick -= ((floorTick % 10) + 10) % 10;
        uint160 sqrtFloor = TickMath.getSqrtPriceAtTick(floorTick);

        uint160 sqrtPrice = CurveMath.sqrtPriceFor(quote, coins, coins + circulating, sqrtFloor, sqrtMax);
        vm.assume(sqrtPrice < TickMath.getSqrtPriceAtTick(700_000));
        uint128 liquidity = CurveMath.liquidityForCoin(coins, sqrtPrice, sqrtMax);
        vm.assume(liquidity >= 1e12 && liquidity <= type(uint104).max);

        // coins the pool takes in as the price falls from where it is to the floor
        uint256 absorbed = SqrtPriceMath.getAmount0Delta(sqrtFloor, sqrtPrice, liquidity, true);
        assertApproxEqAbs(absorbed, circulating, circulating / 1e9 + coins / 1e9 + 1e3, "not v1's curve");

        // a tick spacing is 0.1% of price; the quote a position at the lower floor does without is
        // at most that share of it
        uint256 quoteNeeded = SqrtPriceMath.getAmount1Delta(sqrtFloor, sqrtPrice, liquidity, true);
        assertLe(quoteNeeded, quote, "needs more quote than the reserves hold");
        assertLe(quote - quoteNeeded, quote / 999 + 2, "more than a tick spacing's worth left out");
    }

    /// @notice Adding quote never lowers the floor or the price; neither does a proportional burn.
    function testFuzz_sqrtFloorFor_neverFallsOnHealOrBurn(
        uint256 quote,
        uint256 coins,
        uint256 circulating,
        uint256 heal,
        uint256 burnBps
    ) public pure {
        coins = bound(coins, 1e21, 1e30);
        circulating = bound(circulating, 1e18, 1e30);
        quote = bound(quote, 1e3, 1e24);
        heal = bound(heal, 0, 1e24);
        burnBps = bound(burnBps, 0, 9900);

        uint256 before = CurveMath.sqrtFloorFor(quote, coins, circulating);
        assertGe(CurveMath.sqrtFloorFor(quote + heal, coins, circulating), before, "heal lowered the floor");

        uint256 burn = (circulating * burnBps) / 10_000;
        uint256 poolBurn = FullMath.mulDiv(coins, burn, circulating);
        // one part in a billion for the integer square roots
        assertGe(
            CurveMath.sqrtFloorFor(quote, coins - poolBurn, circulating - burn) + before / 1e9 + 1,
            before,
            "burn lowered the floor"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 LENDING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_creditLimit_matchesV1(uint256 buyIn) public {
        buyIn = bound(buyIn, 10e6, 1_000_000e6);
        IV1Coin coin = _createV1Coin(creator, buyIn);
        Position memory p = _position(coin);

        uint256 credit = CurveMath.creditLimit(p.liquidity, p.sqrtFloorX96, coin.balanceOf(creator));
        // credit is a raw USDC amount, so allow the integer rounding of both sides (2 units = $0.000002)
        uint256 expected = coin.getAccountCredit(creator);
        assertApproxEqAbs(credit, expected, 2 + expected / 1e9);
    }

    function testFuzz_lockedCoins_matchesV1(uint256 buyIn, uint256 borrowBps) public {
        buyIn = bound(buyIn, 100e6, 1_000_000e6);
        borrowBps = bound(borrowBps, 100, 10_000);
        IV1Coin coin = _createV1Coin(creator, buyIn);
        uint256 debt = (coin.getAccountCredit(creator) * borrowBps) / 10_000;
        vm.assume(debt > 0);

        vm.prank(creator);
        coin.borrow(creator, debt);
        Position memory p = _position(coin);
        uint256 expected = coin.balanceOf(creator) - coin.getAccountTransferrable(creator);

        uint256 locked = CurveMath.lockedCoins(p.liquidity, p.sqrtFloorX96, debt);
        assertApproxEqRel(locked, expected, 1e12);
        assertLe(locked, coin.balanceOf(creator) + coin.balanceOf(creator) / 1e9, "max borrow must stay coverable");
    }

    /// @notice The quote freed by moving the lower bound to the debt boundary always covers the debt.
    function testFuzz_debtBoundary_freesAtLeastTheDebt(uint128 liquidity, uint160 sqrtFloor, uint256 debt) public pure {
        liquidity = uint128(bound(liquidity, 1e15, 1e24));
        sqrtFloor = uint160(bound(sqrtFloor, 1e18, 1e27));
        debt = bound(debt, 1, 1e15);
        uint160 boundary = CurveMath.debtBoundarySqrtPriceX96(liquidity, sqrtFloor, debt);
        assertGe(CurveMath.realQuote(liquidity, sqrtFloor, boundary), debt);
    }

    /// @notice Splitting a debt across accounts never locks fewer coins than one account holding all of
    ///         it, so the sum of locks always covers the coins below the total-debt boundary.
    function testFuzz_lockedCoins_isSubadditive(uint256 buyIn, uint256 debtA, uint256 debtB) public {
        buyIn = bound(buyIn, 1000e6, 1_000_000e6);
        Position memory p = _position(_createV1Coin(creator, buyIn));
        debtA = bound(debtA, 1e6, p.realQuote / 4);
        debtB = bound(debtB, 1e6, p.realQuote / 4);

        uint256 split = CurveMath.lockedCoins(p.liquidity, p.sqrtFloorX96, debtA)
            + CurveMath.lockedCoins(p.liquidity, p.sqrtFloorX96, debtB);
        uint256 whole = CurveMath.lockedCoins(p.liquidity, p.sqrtFloorX96, debtA + debtB);
        assertGe(split, whole);

        // and the whole covers every coin below the total-debt boundary
        uint160 boundary = CurveMath.debtBoundarySqrtPriceX96(p.liquidity, p.sqrtFloorX96, debtA + debtB);
        assertGe(whole + 1e9, CurveMath.coinsBetween(p.liquidity, p.sqrtFloorX96, boundary) - 1e9);
    }

    /// @notice A debt's lock never grows when the curve heals.
    function testFuzz_lockedCoins_shrinksAsTheFloorRises(uint256 buyIn, uint256 debt, uint256 healAmount) public {
        buyIn = bound(buyIn, 1000e6, 1_000_000e6);
        healAmount = bound(healAmount, 1e6, 1_000_000e6);
        IV1Coin coin = _createV1Coin(creator, buyIn);
        Position memory p = _position(coin);
        debt = bound(debt, 1e6, p.realQuote / 2);
        uint256 before = CurveMath.lockedCoins(p.liquidity, p.sqrtFloorX96, debt);

        v1Quote.mint(donor, healAmount);
        vm.startPrank(donor);
        v1Quote.approve(address(coin), healAmount);
        coin.heal(healAmount);
        vm.stopPrank();

        p = _position(coin);
        assertLe(CurveMath.lockedCoins(p.liquidity, p.sqrtFloorX96, debt), before + before / 1e9);
    }

    function test_lockedCoins_zeroDebtLocksNothing() public pure {
        assertEq(CurveMath.lockedCoins(1e19, 1e20, 0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The floor and price CurveMath derives from the reserves in `p` are the ones `coin` reports.
    function _assertShape(IV1Coin coin, Position memory p) internal view {
        Position memory expected = _position(coin);
        // v1 keeps quote in WAD; the reserves here are whole raw units, so allow for the unit dropped
        uint256 tolerance = TOLERANCE + 1e18 / p.realQuote;
        uint256 sqrtFloor = CurveMath.sqrtFloorFor(p.realQuote, p.coinReserve, p.circulating);
        assertApproxEqRel(sqrtFloor, expected.sqrtFloorX96, tolerance, "floor");

        uint160 sqrtMax = TickMath.MAX_SQRT_PRICE - 1;
        uint160 sqrtPrice = CurveMath.sqrtPriceFor(
            p.realQuote, p.coinReserve, p.coinReserve + p.circulating, expected.sqrtFloorX96, sqrtMax
        );
        assertApproxEqRel(sqrtPrice, expected.sqrtPriceX96, tolerance, "price");
    }

    /*//////////////////////////////////////////////////////////////
                    A REBALANCE CAN ALWAYS PAY FOR ITSELF
    //////////////////////////////////////////////////////////////*/

    /// @dev A magnitude drawn evenly over the bit lengths up to `maxBits`, so that 1, a thousand and
    ///      2^120 are all as likely as each other.
    function _anyMagnitude(uint256 seed, uint256 maxBits) internal pure returns (uint256) {
        uint256 bits = seed % (maxBits + 1);
        if (bits == 0) return 0;
        uint256 low = 1 << (bits - 1);
        return low + (uint256(keccak256(abi.encode(seed))) % low);
    }

    /// @notice When the hook re-creates its position it puts back no more coins and no more quote than
    ///         it has, whatever the reserves: one raw coin, no quote at all, the lowest and highest
    ///         floors a launch allows, with or without debt. If it ever needed a unit more, the
    ///         subtraction in the rebalance would revert and that coin could no longer be traded.
    /// @dev The argument, for a position [lower, upper] at price `s` with the liquidity
    ///      `L = liquidityForCoin(coins, s, upper)`:
    ///
    ///      Coins. `L <= coins * s * upper / (Q96 * (upper - s))`, so `x = L * Q96 * (upper - s) / upper`
    ///      is at most `coins * s`. The PoolManager charges `ceil(ceil(x) / s)`; `coins * s` is a whole
    ///      number, so `ceil(x) <= coins * s` and the charge is at most `coins`.
    ///
    ///      Quote. {CurveMath-sqrtPriceFor} rounds its liquidity down from the root of the quadratic
    ///      that spends exactly `quote`, and rounds the price down from that liquidity; `L` above is
    ///      no more than it. `L * (s - floor)` grows with both, so it is at most `quote * Q96`, and
    ///      the charge `ceil(L * (s - floor) / Q96)` is at most `quote`. With debt, the lower bound is
    ///      rounded up from `floor + ceil(debt * Q96 / L)`, which takes at least `debt` off that.
    ///
    ///      This test checks the argument against the PoolManager's own arithmetic over the whole
    ///      range the hook's guards allow.
    function testFuzz_rebalance_neverNeedsMoreThanItHas(
        uint256 quoteSeed,
        uint256 coinSeed,
        uint256 circulatingSeed,
        uint256 debtSeed,
        int24 floorTick
    ) public pure {
        int24 spacing = 10;
        int24 maxTick = TickMath.maxUsableTick(spacing);
        uint160 sqrtMax = TickMath.getSqrtPriceAtTick(maxTick);
        // the hook's own limits: the launch range of floors, and half of v4's liquidity per tick
        floorTick = int24(bound(floorTick, -80_000, 40_000)) * spacing;
        uint160 sqrtFloor = TickMath.getSqrtPriceAtTick(floorTick);
        uint256 maxLiquidity = type(uint128).max / uint128(uint24(2 * (maxTick / spacing) + 1)) / 2;

        // the largest supply whose curve at this floor stays within the liquidity ceiling
        uint256 maxSupply = Math.min(1 << 126, FullMath.mulDiv(maxLiquidity, 1 << 96, sqrtFloor));
        uint256 coins = bound(_anyMagnitude(coinSeed, 126), 1, maxSupply / 2);
        uint256 circulating = bound(_anyMagnitude(circulatingSeed, 126), 0, maxSupply / 2);
        uint256 quote = _anyMagnitude(quoteSeed, 127);

        uint160 sqrtPrice = CurveMath.sqrtPriceFor(quote, coins, coins + circulating, sqrtFloor, sqrtMax);
        assertGe(sqrtPrice, sqrtFloor, "price below the floor");
        assertLt(sqrtPrice, sqrtMax, "price at the top of the range");
        uint128 liquidity = CurveMath.liquidityForCoin(coins, sqrtPrice, sqrtMax);

        // Debt is quote that was lent out of the curve, so it is never more than the curve between
        // the floor and the price holds; quote beyond the curve (idle) cannot have been borrowed.
        uint256 debt = bound(debtSeed, 0, SqrtPriceMath.getAmount1Delta(sqrtFloor, sqrtPrice, liquidity, false));
        uint160 sqrtLower = sqrtFloor;
        if (debt != 0) {
            uint160 boundary = CurveMath.debtBoundarySqrtPriceX96(liquidity, sqrtFloor, debt);
            int24 debtTick = TickRounding.ceil(boundary, spacing);
            if (debtTick > floorTick) sqrtLower = TickMath.getSqrtPriceAtTick(debtTick);
        }
        if (sqrtLower > sqrtPrice) {
            // parked on the lower bound: all coin
            sqrtPrice = sqrtLower;
            liquidity = CurveMath.liquidityForCoin(coins, sqrtPrice, sqrtMax);
        }

        uint256 coinsNeeded = SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtMax, liquidity, true);
        uint256 quoteNeeded = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, liquidity, true);
        assertLe(coinsNeeded, coins, "needs more coins than it has");
        assertLe(quoteNeeded, quote - debt, "needs more quote than it has");
    }
}

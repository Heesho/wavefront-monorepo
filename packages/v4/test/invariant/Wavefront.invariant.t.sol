// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Coin} from "../../src/Coin.sol";
import {IWavefrontHook} from "../../src/interfaces/IWavefrontHook.sol";
import {CurveMath} from "../../src/libraries/CurveMath.sol";
import {MockQuote} from "../mocks/MockQuote.sol";
import {WavefrontFixture} from "../utils/WavefrontFixture.sol";
import {WavefrontHandler} from "./WavefrontHandler.sol";

/// @notice Properties that must hold after any sequence of user actions.
/// @dev Five actors trade, lend, donate, burn, transfer and claim at random while fee recipients are
///      toggled on and off. The contracts at the end of this file choose which coins they do it to.
abstract contract WavefrontInvariants is WavefrontFixture {
    /// @dev Rounding allowance for a whole run, in raw quote units: coins worth this much at the floor
    ///      price may be left unsellable. 100 raw units is $0.0001 of a 6-decimal quote.
    uint256 internal constant DUST_QUOTE = 100;

    WavefrontHandler internal handler;
    address[] internal actors;

    function setUp() public {
        _deployV4();
        (Coin[] memory coins, MockQuote[] memory launchQuotes) = _launchCoins();

        actors.push(alice);
        actors.push(bob);
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(creator);

        handler = new WavefrontHandler(hook, router, owner, treasury, creator, coins, actors, launchQuotes);
        targetContract(address(handler));
    }

    /// @dev The coins a run starts with, and the quote tokens it may launch more against (none if empty).
    function _launchCoins() internal virtual returns (Coin[] memory coins, MockQuote[] memory launchQuotes);

    /// @dev Launches a coin owned by `creator` against `token`.
    function _launchAgainst(MockQuote token, uint256 supply, uint256 virtualQuote, uint24 fee)
        internal
        returns (Coin coin)
    {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.quote = address(token);
        params.supply = supply;
        params.virtualQuote = virtualQuote;
        params.fee = fee;
        (coin,) = _launchWith(creator, params, 0);
    }

    /// @notice Buying, repaying, donating, claiming, transferring unlocked coins and launching within
    ///         the documented bounds never revert.
    function invariant_nothingRevertsThatShouldNot() public view {
        assertEq(handler.failedAction(), bytes32(0), "an action that must always work reverted");
    }

    /*//////////////////////////////////////////////////////////////
                                   FLOOR
    //////////////////////////////////////////////////////////////*/

    /// @notice The floor never falls, always sits exactly on a usable tick, and bounds the price.
    function invariant_floorOnlyRisesAndBoundsThePrice() public view {
        assertFalse(handler.floorFell(), "a floor fell");
        for (uint256 i; i < handler.coinCount(); ++i) {
            IWavefrontHook.Market memory m = _market(handler.coins(i));
            assertEq(m.floorTick % TICK_SPACING, 0, "floor tick is usable");
            assertEq(m.sqrtFloorX96, TickMath.getSqrtPriceAtTick(m.floorTick), "floor sits on its tick");
            assertGe(m.lowerTick, m.floorTick, "position never extends below the floor");
            uint160 sqrtPrice = hook.sqrtPriceX96(address(handler.coins(i)));
            assertGe(sqrtPrice, TickMath.getSqrtPriceAtTick(m.lowerTick), "price is inside the position");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice The hook's claims on each quote token are exactly the idle quote and pending heal of the
    ///         markets that trade against it, plus unclaimed fees.
    function invariant_quoteClaimsAreFullyAccounted() public view {
        uint256 count = handler.coinCount();
        for (uint256 i; i < count; ++i) {
            address token = _market(handler.coins(i)).quote;
            // several coins can share a quote token; account for each token once
            bool seen;
            uint256 expected = hook.feesOwed(token, creator) + hook.feesOwed(token, treasury);
            for (uint256 j; j < count; ++j) {
                IWavefrontHook.Market memory m = _market(handler.coins(j));
                if (m.quote != token) continue;
                if (j < i) seen = true;
                expected += m.idleQuote + m.pendingHeal;
            }
            if (!seen) assertEq(_claims(token), expected, "quote claims");
        }
    }

    /// @notice The hook's coin claims are exactly its pending burn, burn queue and unclaimed fees.
    function invariant_coinClaimsAreFullyAccounted() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            address coin = address(handler.coins(i));
            IWavefrontHook.Market memory m = _market(handler.coins(i));
            uint256 expected =
                m.pendingBurn + m.burnQueue + hook.feesOwed(coin, creator) + hook.feesOwed(coin, treasury);
            assertEq(_claims(coin), expected, "coin claims");
        }
    }

    /// @notice The hook custodies nothing itself: everything it owns is a claim on the PoolManager.
    function invariant_hookHoldsNoTokens() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            assertEq(handler.coins(i).balanceOf(address(hook)), 0);
            assertEq(_quoteOf(handler.coins(i)).balanceOf(address(hook)), 0);
        }
    }

    /// @notice The PoolManager physically holds every token the position and the hook's claims need.
    function invariant_poolManagerIsFunded() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            IWavefrontHook.Market memory m = _market(handler.coins(i));
            uint160 sqrtPrice = hook.sqrtPriceX96(address(handler.coins(i)));
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);
            uint256 positionQuote = CurveMath.realQuote(m.liquidity, sqrtLower, sqrtPrice);
            assertGe(MockQuote(m.quote).balanceOf(address(manager)), positionQuote + _claims(m.quote), "quote");

            uint256 positionCoin = _positionCoin(m, sqrtPrice);
            assertGe(
                handler.coins(i).balanceOf(address(manager)) + 1e6,
                positionCoin + _claims(address(handler.coins(i))),
                "coin"
            );
        }
    }

    /// @notice Supply only ever shrinks.
    function invariant_supplyNeverGrows() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            assertLe(handler.coins(i).totalSupply(), handler.launchSupply(address(handler.coins(i))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  LENDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Total debt is the sum of every account's debt.
    function invariant_totalDebtIsTheSumOfDebts() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            uint256 sum;
            for (uint256 a; a < actors.length; ++a) {
                sum += hook.debtOf(address(handler.coins(i)), actors[a]);
            }
            assertEq(sum, _market(handler.coins(i)).totalDebt);
        }
    }

    /// @notice Every borrower still holds the coins their debt locks.
    function invariant_borrowersHoldTheirCollateral() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            for (uint256 a; a < actors.length; ++a) {
                uint256 locked = hook.lockedOf(address(handler.coins(i)), actors[a]);
                uint256 balance = handler.coins(i).balanceOf(actors[a]);
                // re-creating the position rounds its liquidity, which moves a lock by parts in 1e20
                assertLe(locked, balance + balance / 1e15 + 1e6, "collateral");
            }
        }
    }

    /// @notice Everything lent out came from below the position's lower tick, where no sale can reach.
    function invariant_debtIsCoveredByTheRangeBelowThePosition() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            IWavefrontHook.Market memory m = _market(handler.coins(i));
            if (m.totalDebt == 0) {
                assertEq(m.lowerTick, m.floorTick, "no debt, so the position reaches the floor");
                continue;
            }
            uint256 freed = CurveMath.realQuote(m.liquidity, m.sqrtFloorX96, TickMath.getSqrtPriceAtTick(m.lowerTick));
            assertGe(freed + m.idleQuote, m.totalDebt, "debt exceeds the quote freed below the position");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 RESERVES
    //////////////////////////////////////////////////////////////*/

    /// @notice The floor is v1's floor rounded down to a tick, at all times. v1's floor is a formula in
    ///         its reserves; evaluated on what the market holds it is never below the floor tick, and
    ///         evaluated with what is waiting to be applied it is never a whole tick spacing above.
    function invariant_floorIsV1sFloorRoundedDownToATick() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            IWavefrontHook.Market memory m = _market(handler.coins(i));
            uint160 sqrtPrice = hook.sqrtPriceX96(address(handler.coins(i)));
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);

            uint256 inPool = _positionCoin(m, sqrtPrice);
            uint256 circulating = hook.effectiveSupply(address(handler.coins(i))) - inPool;
            // while holders have no more than the minimum share of the supply the hook leaves the floor
            // where it is (`inPool` is rounded here, hence the few wei of allowance)
            uint256 minHeld = ((circulating + inPool) * hook.MIN_CIRCULATING_BPS()) / 10_000;
            if (circulating - m.pendingBurn <= minHeld + 1e6) continue;
            uint256 quote = m.idleQuote + m.totalDebt;
            if (sqrtPrice > sqrtLower) quote += SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, m.liquidity, true);

            // Re-creating a position can cost a raw unit of quote in the PoolManager's rounding. Allow
            // the dust of a whole run, and parts in a billion for the integer square roots.
            uint256 implied = CurveMath.sqrtFloorFor(quote + DUST_QUOTE, inPool, circulating);
            assertGe(implied + implied / 1e9, m.sqrtFloorX96, "reserves below the floor");

            // With the pending heal and burn applied the way the hook applies them. The hook counts the
            // position's quote in whole raw units, rounded down; allow it three of them.
            uint256 burn = m.pendingBurn;
            if (
                FullMath.mulDiv(uint256(m.liquidity) * m.liquidity, circulating - burn, circulating)
                    < uint256(hook.MIN_LIQUIDITY()) * hook.MIN_LIQUIDITY()
            ) burn = 0;
            quote += m.pendingHeal;
            quote = quote > 3 ? quote - 3 : 0;
            uint256 coinsLeft = inPool - FullMath.mulDiv(inPool, burn, circulating);
            uint256 pending = CurveMath.sqrtFloorFor(quote, coinsLeft, circulating - burn);

            // the hook leaves them pending while applying them would take the price or the liquidity
            // out of the range a v4 pool can represent
            uint256 supply = coinsLeft + circulating - burn;
            uint256 sqrtCap = TickMath.getSqrtPriceAtTick(hook.maxTick() - 100_000);
            if (
                quote > type(uint128).max || pending > FullMath.mulDiv(sqrtCap, coinsLeft, supply)
                    || FullMath.mulDiv(pending, supply, 1 << 96) > hook.maxLiquidity()
            ) continue;
            uint256 sqrtNext = TickMath.getSqrtPriceAtTick(m.floorTick + TICK_SPACING);
            assertLt(pending, sqrtNext + sqrtNext / 1e9, "the floor is a tick spacing behind its reserves");
        }
    }

    /// @notice No heal or burn ever sizes a position beyond what the PoolManager accepts.
    function invariant_liquidityStaysWithinTheCeiling() public view {
        for (uint256 i; i < handler.coinCount(); ++i) {
            assertLe(_market(handler.coins(i)).liquidity, hook.maxLiquidity(), "liquidity above the ceiling");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EXIT-ABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice The position can absorb every circulating coin that is not locked as collateral. This is
    ///         what makes the floor real and zero-interest lending safe.
    function invariant_everyUnlockedCoinCanBeSold() public view {
        assertFalse(handler.sellFailed(), "a holder without debt could not sell");
        for (uint256 i; i < handler.coinCount(); ++i) {
            IWavefrontHook.Market memory m = _market(handler.coins(i));
            uint160 sqrtPrice = hook.sqrtPriceX96(address(handler.coins(i)));
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);

            // coins the position takes in as the price falls from here to its lower tick
            uint256 absorbable = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtPrice, m.liquidity, false);
            uint256 circulating = handler.coins(i).totalSupply() - m.burnQueue - _positionCoin(m, sqrtPrice);
            uint256 locked;
            for (uint256 a; a < actors.length; ++a) {
                locked += hook.lockedOf(address(handler.coins(i)), actors[a]);
            }
            assertGe(absorbable + locked + _dust(m), circulating, "unlocked coins exceed what the pool absorbs");
        }
    }

    /// @notice After any run, everyone can still get out: debts are repaid, fees claimed, and every
    ///         holder sells every coin they have.
    function afterInvariant() public {
        for (uint256 i; i < handler.coinCount(); ++i) {
            Coin coin = handler.coins(i);
            MockQuote token = _quoteOf(coin);

            for (uint256 a; a < actors.length; ++a) {
                uint256 debt = hook.debtOf(address(coin), actors[a]);
                if (debt == 0) continue;
                token.mint(actors[a], debt);
                _repay(coin, actors[a], debt);
            }
            IWavefrontHook.Market memory m = _market(coin);
            assertEq(m.totalDebt, 0, "all debt repaid");
            assertEq(m.lowerTick, m.floorTick, "position back on the floor");

            // holders sell; selling pays coin fees to the team and treasury, who then sell those too
            for (uint256 round; round < 6; ++round) {
                hook.claimFees(address(coin), creator);
                hook.claimFees(address(coin), treasury);
                for (uint256 a; a < actors.length; ++a) {
                    _sellAll(coin, actors[a]);
                }
                _sellAll(coin, treasury);
            }
            uint256 dust = _dust(_market(coin));
            for (uint256 a; a < actors.length; ++a) {
                assertLe(coin.balanceOf(actors[a]), dust, "a holder could not fully exit");
            }
            assertLe(coin.balanceOf(treasury), dust, "the treasury could not fully exit");
            assertGe(hook.sqrtPriceX96(address(coin)), _market(coin).sqrtFloorX96, "price at or above the floor");
        }
    }

    function _sellAll(Coin coin, address seller) internal {
        uint256 balance = coin.balanceOf(seller);
        if (balance > _dust(_market(coin))) _sell(coin, seller, balance);
    }

    /// @dev Coins worth DUST_QUOTE raw quote units at the floor price, plus a millionth of a coin.
    function _dust(IWavefrontHook.Market memory m) internal pure returns (uint256) {
        return FullMath.mulDiv(DUST_QUOTE << 96, 1 << 96, uint256(m.sqrtFloorX96) * m.sqrtFloorX96) + 1e12;
    }

    /// @dev Coins the position holds at `sqrtPrice`.
    function _positionCoin(IWavefrontHook.Market memory m, uint160 sqrtPrice) internal view returns (uint256) {
        uint160 sqrtMax = TickMath.getSqrtPriceAtTick(hook.maxTick());
        return SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtMax, m.liquidity, false);
    }
}

/// @notice v1's own launch parameters against a 6-decimal quote, and a smaller, deeper coin against an
///         18-decimal one.
contract WavefrontInvariantTest is WavefrontInvariants {
    function _launchCoins() internal override returns (Coin[] memory coins, MockQuote[] memory launchQuotes) {
        coins = new Coin[](2);
        (coins[0],) = _launch(creator, 0);
        coins[1] = _launchAgainst(new MockQuote("Wrapped Ether", "WETH", 18), 21_000_000e18, 15 ether, DEFAULT_FEE);
        launchQuotes = new MockQuote[](0);
    }
}

/// @notice Coins at the edges of what a launch allows: quotes with 2 and 8 decimals, a thousand-coin
///         supply priced above its quote, a quadrillion-coin supply, and the smallest curve permitted,
///         at fees from the lowest (1%) to the highest (5%).
contract WavefrontShapesInvariantTest is WavefrontInvariants {
    function _launchCoins() internal override returns (Coin[] memory coins, MockQuote[] memory launchQuotes) {
        coins = new Coin[](5);
        coins[0] = _launchAgainst(new MockQuote("Two Decimals", "USD2", 2), 1_000_000_000e18, 100_000e2, 10_000);
        coins[1] = _launchAgainst(new MockQuote("Wrapped Bitcoin", "WBTC", 8), 1_000_000_000e18, 1e8, 50_000);
        coins[2] = _launchAgainst(new MockQuote("Wrapped Ether", "WETH", 18), 1000e18, 1000 ether, 30_000);
        coins[3] = _launchAgainst(new MockQuote("Wrapped Ether", "WETH", 18), 1e33, 10 ether, 10_000);
        coins[4] = _launchAgainst(quote, hook.MIN_SUPPLY(), hook.MIN_VIRTUAL_QUOTE(), 50_000);
        launchQuotes = new MockQuote[](0);
    }
}

/// @notice Runs that launch their own coins, with supply, curve depth and fee drawn from the whole range
///         a launch allows, against quotes of 2, 6, 8 and 18 decimals.
contract WavefrontLaunchInvariantTest is WavefrontInvariants {
    function _launchCoins() internal override returns (Coin[] memory coins, MockQuote[] memory launchQuotes) {
        coins = new Coin[](1);
        (coins[0],) = _launch(creator, 0);
        launchQuotes = new MockQuote[](4);
        launchQuotes[0] = new MockQuote("Two Decimals", "USD2", 2);
        launchQuotes[1] = quote;
        launchQuotes[2] = new MockQuote("Wrapped Bitcoin", "WBTC", 8);
        launchQuotes[3] = new MockQuote("Wrapped Ether", "WETH", 18);
    }
}

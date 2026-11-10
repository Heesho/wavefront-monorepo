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
/// @dev Two coins share the hook: one with v1's parameters against a 6-decimal quote, one with a
///      different supply and curve depth against an 18-decimal quote. Five actors trade, lend, donate,
///      burn, transfer and claim at random while fee recipients are toggled on and off.
contract WavefrontInvariantTest is WavefrontFixture {
    /// @dev Rounding allowance for a whole run, in raw quote units: coins worth this much at the floor
    ///      price may be left unsellable. 100 raw units is $0.0001 of a 6-decimal quote.
    uint256 internal constant DUST_QUOTE = 100;

    WavefrontHandler internal handler;
    Coin[] internal coins;
    address[] internal actors;
    MockQuote internal weth;

    function setUp() public {
        _deployV4();
        weth = new MockQuote("Wrapped Ether", "WETH", 18);

        (Coin usdcCoin,) = _launch(creator, 0);
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.quote = address(weth);
        params.supply = 21_000_000e18;
        params.virtualQuote = 15 ether;
        (Coin wethCoin,) = _launchWith(creator, params, 0);
        coins.push(usdcCoin);
        coins.push(wethCoin);

        actors.push(alice);
        actors.push(bob);
        actors.push(makeAddr("carol"));
        actors.push(makeAddr("dave"));
        actors.push(creator);

        handler = new WavefrontHandler(hook, router, owner, treasury, coins, actors);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                                   FLOOR
    //////////////////////////////////////////////////////////////*/

    /// @notice The floor never falls, always sits exactly on a usable tick, and bounds the price.
    function invariant_floorOnlyRisesAndBoundsThePrice() public view {
        assertFalse(handler.floorFell(), "a floor fell");
        for (uint256 i; i < coins.length; ++i) {
            IWavefrontHook.Market memory m = _market(coins[i]);
            assertEq(m.floorTick % TICK_SPACING, 0, "floor tick is usable");
            assertEq(m.sqrtFloorX96, TickMath.getSqrtPriceAtTick(m.floorTick), "floor sits on its tick");
            assertGe(m.lowerTick, m.floorTick, "position never extends below the floor");
            uint160 sqrtPrice = hook.sqrtPriceX96(address(coins[i]));
            assertGe(sqrtPrice, TickMath.getSqrtPriceAtTick(m.lowerTick), "price is inside the position");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice The hook's quote claims are exactly its idle quote, pending heal and unclaimed fees.
    function invariant_quoteClaimsAreFullyAccounted() public view {
        for (uint256 i; i < coins.length; ++i) {
            IWavefrontHook.Market memory m = _market(coins[i]);
            uint256 expected =
                m.idleQuote + m.pendingHeal + hook.feesOwed(m.quote, creator) + hook.feesOwed(m.quote, treasury);
            assertEq(_claims(m.quote), expected, "quote claims");
        }
    }

    /// @notice The hook's coin claims are exactly its pending burn, burn queue and unclaimed fees.
    function invariant_coinClaimsAreFullyAccounted() public view {
        for (uint256 i; i < coins.length; ++i) {
            address coin = address(coins[i]);
            IWavefrontHook.Market memory m = _market(coins[i]);
            uint256 expected =
                m.pendingBurn + m.burnQueue + hook.feesOwed(coin, creator) + hook.feesOwed(coin, treasury);
            assertEq(_claims(coin), expected, "coin claims");
        }
    }

    /// @notice The hook custodies nothing itself: everything it owns is a claim on the PoolManager.
    function invariant_hookHoldsNoTokens() public view {
        assertEq(quote.balanceOf(address(hook)), 0);
        assertEq(weth.balanceOf(address(hook)), 0);
        for (uint256 i; i < coins.length; ++i) {
            assertEq(coins[i].balanceOf(address(hook)), 0);
        }
    }

    /// @notice The PoolManager physically holds every token the position and the hook's claims need.
    function invariant_poolManagerIsFunded() public view {
        for (uint256 i; i < coins.length; ++i) {
            IWavefrontHook.Market memory m = _market(coins[i]);
            uint160 sqrtPrice = hook.sqrtPriceX96(address(coins[i]));
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);
            uint256 positionQuote = CurveMath.realQuote(m.liquidity, sqrtLower, sqrtPrice);
            assertGe(MockQuote(m.quote).balanceOf(address(manager)), positionQuote + _claims(m.quote), "quote");

            uint256 positionCoin = _positionCoin(m, sqrtPrice);
            assertGe(coins[i].balanceOf(address(manager)) + 1e6, positionCoin + _claims(address(coins[i])), "coin");
        }
    }

    /// @notice Supply only ever shrinks.
    function invariant_supplyNeverGrows() public view {
        assertLe(coins[0].totalSupply(), COIN_SUPPLY);
        assertLe(coins[1].totalSupply(), 21_000_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                                  LENDING
    //////////////////////////////////////////////////////////////*/

    /// @notice Total debt is the sum of every account's debt.
    function invariant_totalDebtIsTheSumOfDebts() public view {
        for (uint256 i; i < coins.length; ++i) {
            uint256 sum;
            for (uint256 a; a < actors.length; ++a) {
                sum += hook.debtOf(address(coins[i]), actors[a]);
            }
            assertEq(sum, _market(coins[i]).totalDebt);
        }
    }

    /// @notice Every borrower still holds the coins their debt locks.
    function invariant_borrowersHoldTheirCollateral() public view {
        for (uint256 i; i < coins.length; ++i) {
            for (uint256 a; a < actors.length; ++a) {
                uint256 locked = hook.lockedOf(address(coins[i]), actors[a]);
                uint256 balance = coins[i].balanceOf(actors[a]);
                // re-creating the position rounds its liquidity, which moves a lock by parts in 1e20
                assertLe(locked, balance + balance / 1e15 + 1e6, "collateral");
            }
        }
    }

    /// @notice Everything lent out came from below the position's lower tick, where no sale can reach.
    function invariant_debtIsCoveredByTheRangeBelowThePosition() public view {
        for (uint256 i; i < coins.length; ++i) {
            IWavefrontHook.Market memory m = _market(coins[i]);
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
        for (uint256 i; i < coins.length; ++i) {
            IWavefrontHook.Market memory m = _market(coins[i]);
            uint160 sqrtPrice = hook.sqrtPriceX96(address(coins[i]));
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);

            uint256 inPool = _positionCoin(m, sqrtPrice);
            uint256 circulating = hook.effectiveSupply(address(coins[i])) - inPool;
            // with no more than the minimum in circulation there is nobody for a floor to protect, and
            // the hook leaves it where it is (`inPool` is rounded here, hence the few wei of allowance)
            if (circulating <= hook.MIN_CIRCULATING() + 1e6) continue;
            uint256 quote = m.idleQuote + m.totalDebt;
            if (sqrtPrice > sqrtLower) quote += SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, m.liquidity, true);

            uint256 implied = CurveMath.sqrtFloorFor(quote, inPool, circulating);
            // parts in a billion for the integer square roots, and the rounding dust of a whole run
            assertGe(implied + implied / 1e9 + _sqrtDust(m, circulating), m.sqrtFloorX96, "reserves below the floor");

            // With the pending heal and burn applied the way the hook applies them. The hook counts the
            // position's quote in whole raw units, rounded down; allow it two of them.
            uint256 burn = m.pendingBurn;
            if (burn > circulating - hook.MIN_CIRCULATING()) burn = circulating - hook.MIN_CIRCULATING();
            quote += m.pendingHeal;
            quote = quote > 3 ? quote - 3 : 0;
            uint256 pending =
                CurveMath.sqrtFloorFor(quote, inPool - FullMath.mulDiv(inPool, burn, circulating), circulating - burn);
            uint256 sqrtNext = TickMath.getSqrtPriceAtTick(m.floorTick + TICK_SPACING);
            assertLt(pending, sqrtNext + sqrtNext / 1e9, "the floor is a tick spacing behind its reserves");
        }
    }

    /// @notice No heal or burn ever sizes a position beyond what the PoolManager accepts.
    function invariant_liquidityStaysWithinTheCeiling() public view {
        for (uint256 i; i < coins.length; ++i) {
            assertLe(_market(coins[i]).liquidity, hook.maxLiquidity(), "liquidity above the ceiling");
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 EXIT-ABILITY
    //////////////////////////////////////////////////////////////*/

    /// @notice The position can absorb every circulating coin that is not locked as collateral. This is
    ///         what makes the floor real and zero-interest lending safe.
    function invariant_everyUnlockedCoinCanBeSold() public view {
        assertFalse(handler.sellFailed(), "a holder without debt could not sell");
        for (uint256 i; i < coins.length; ++i) {
            IWavefrontHook.Market memory m = _market(coins[i]);
            uint160 sqrtPrice = hook.sqrtPriceX96(address(coins[i]));
            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);

            // coins the position takes in as the price falls from here to its lower tick
            uint256 absorbable = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtPrice, m.liquidity, false);
            uint256 circulating = coins[i].totalSupply() - m.burnQueue - _positionCoin(m, sqrtPrice);
            uint256 locked;
            for (uint256 a; a < actors.length; ++a) {
                locked += hook.lockedOf(address(coins[i]), actors[a]);
            }
            assertGe(absorbable + locked + _dust(m), circulating, "unlocked coins exceed what the pool absorbs");
        }
    }

    /// @notice After any run, everyone can still get out: debts are repaid, fees claimed, and every
    ///         holder sells every coin they have.
    function afterInvariant() public {
        for (uint256 i; i < coins.length; ++i) {
            Coin coin = coins[i];
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

    /// @dev How far `DUST_QUOTE` of missing quote can pull the implied sqrt floor down when only
    ///      `circulating` coins are out: d(a) = dX / (2 * a * C), from a^2 = X * y / (C * S) with y ~ S.
    function _sqrtDust(IWavefrontHook.Market memory m, uint256 circulating) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(DUST_QUOTE, 1 << 96, circulating), 1 << 96, m.sqrtFloorX96) + 1;
    }

    /// @dev Coins the position holds at `sqrtPrice`.
    function _positionCoin(IWavefrontHook.Market memory m, uint160 sqrtPrice) internal view returns (uint256) {
        uint160 sqrtMax = TickMath.getSqrtPriceAtTick(hook.maxTick());
        return SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtMax, m.liquidity, false);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Coin} from "../../src/Coin.sol";
import {IWavefrontHook} from "../../src/interfaces/IWavefrontHook.sol";
import {WavefrontFixture} from "../utils/WavefrontFixture.sol";

/// @notice Sequences the invariant suite once broke, kept as fixed tests.
contract RegressionTest is WavefrontFixture {
    uint256 internal constant ONE_USDC = 1e6;

    function setUp() public {
        _deployV4();
    }

    /// @notice A holder of most of the supply burns everything they hold. The burn used to scale the
    ///         position down to a few wei of liquidity, after which the next trade reverted for ever.
    /// @dev With nobody left holding the coin the burn now waits, and is applied for the next holders.
    function test_burningNearlyAllCirculatingCoinsKeepsTheMarketLive() public {
        (Coin coin,) = _launch(creator, 0);
        uint256 bought = _buy(coin, alice, 400_000 * ONE_USDC);
        uint128 liquidity = _market(coin).liquidity;
        _burn(coin, alice, bought);

        IWavefrontHook.Market memory m = _market(coin);
        assertEq(m.pendingBurn, bought, "with no holders left, the burn waits");
        assertEq(m.liquidity, liquidity, "and the position is untouched");

        // the market still trades in both directions, and the burn is applied once there are holders
        _buy(coin, bob, 250_000 * ONE_USDC);
        m = _market(coin);
        assertEq(m.pendingBurn, 0, "the burn was applied for the new holder");
        assertGe(m.liquidity, hook.MIN_LIQUIDITY(), "position keeps real liquidity");
        _buy(coin, bob, ONE_USDC / 100);
        uint256 balance = coin.balanceOf(bob);
        assertGt(_sell(coin, bob, balance / 2), 0);
        assertGt(_market(coin).liquidity, 0);
    }

    /// @notice A donation far larger than the curve's real quote must not push the price past the tick
    ///         range, which would make every later trade revert.
    function test_hugeHealIntoATinyCurveKeepsTheMarketLive() public {
        (Coin coin,) = _launch(creator, 0);
        _buy(coin, alice, ONE_USDC / 100);
        _heal(coin, bob, 1_000_000_000 * ONE_USDC);

        assertGt(_market(coin).liquidity, 0);
        _buy(coin, bob, 1000 * ONE_USDC);
        assertGt(_sell(coin, alice, coin.balanceOf(alice)), 0, "the early holder can still sell");
        _sell(coin, bob, coin.balanceOf(bob));
    }

    /// @notice Repeated extreme burns cannot grind a market's liquidity down to zero.
    function test_repeatedExtremeBurnsCannotBrickTheMarket() public {
        (Coin coin,) = _launch(creator, 0);
        for (uint256 i; i < 8; ++i) {
            uint256 bought = _buy(coin, alice, 100_000 * ONE_USDC);
            _burn(coin, alice, bought);
            assertGe(_market(coin).liquidity, hook.MIN_LIQUIDITY());
        }
        uint256 last = _buy(coin, bob, 10 * ONE_USDC);
        if (last != 0) _sell(coin, bob, last);
    }

    /// @notice A large donation followed by a tiny first buy. The heal amount used to be computed by
    ///         scaling the curve's few thousand raw units of quote by a factor of millions, magnifying
    ///         their rounding error until the pool could not take back the buyer's last coins.
    /// @dev The donation also used to go to that tiny buyer, lifting the floor millions of times over
    ///      for a cent. It now waits until a real share of the supply is in circulation.
    function test_largeHealIntoATinyCurveLeavesEveryCoinSellable() public {
        (Coin coin,) = _launch(creator, 0);
        int24 floorTick = _market(coin).floorTick;
        _heal(coin, bob, 58_265_888_783);
        uint256 bought = _buy(coin, alice, 10_000);

        IWavefrontHook.Market memory m = _market(coin);
        assertLt(m.burnQueue, 1e12, "no coins were squeezed out of the position");
        assertEq(m.floorTick, floorTick, "a cent's worth of coins must not capture the donation");
        assertApproxEqAbs(m.pendingHeal, 58_265_888_783 + 120, 2, "the donation and the buy's fee still wait");
        uint256 quoteOut = _sell(coin, alice, bought);
        assertEq(coin.balanceOf(alice), 0, "the buyer sold every coin");
        assertLe(quoteOut, 10_000, "and got back no more than they paid");

        // once a real share of the supply is bought, the donation is applied for those holders
        uint256 share = _buy(coin, alice, 1000 * ONE_USDC);
        assertGt(_market(coin).floorTick, floorTick, "the donation lifted the floor");
        assertGt(_sell(coin, alice, share), 50_000 * ONE_USDC, "and went to the holder, as on v1");
        assertEq(coin.balanceOf(alice), 0);
    }

    /// @notice A tiny buy, a burn of nearly everything, then a large donation. Re-creating the position
    ///         after the burn needed one more raw quote unit than the curve held; with nothing in
    ///         reserve the position was shrunk instead, leaving a sliver of coins unsellable that the
    ///         donation then made valuable.
    function test_burnThenHealOnATinyCurveLeavesEveryCoinSellable() public {
        (Coin coin,) = _launch(creator, 0);
        uint256 bought = _buy(coin, alice, 10_002);
        _burn(coin, alice, (bought * 99) / 100);
        _heal(coin, bob, 14_819 * ONE_USDC);

        uint256 quoteOut = _sell(coin, alice, coin.balanceOf(alice));
        assertEq(coin.balanceOf(alice), 0, "the holder sold every coin");
        assertGt(quoteOut, 0);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Coin} from "../src/Coin.sol";
import {WavefrontLens} from "../src/WavefrontLens.sol";
import {IV1Coin} from "./reference/V1.sol";
import {WavefrontFixture} from "./utils/WavefrontFixture.sol";

/// @notice Hundreds of random trades on v1 and v4 side by side. Short sequences cannot show whether the
///         two systems drift apart; these do, and then make everyone exit.
/// @dev v4 rounds its floor down to a tick and applies fees once they are worth a tick, so it follows
///      v1 closely rather than exactly. The bounds below are several times what these paths show.
contract LongPathTest is WavefrontFixture {
    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant STEPS = 400;
    /// @dev Market and floor price stay within 2% of v1 at every step.
    uint256 internal constant PRICE_PARITY = 2e16;
    /// @dev Everything paid out to sellers over the whole path is within 0.02% of v1.
    uint256 internal constant PAYOUT_PARITY = 2e14;

    address[3] internal traders;

    function setUp() public {
        _deployV1();
        _deployV4();
        traders = [alice, bob, makeAddr("carol")];
    }

    function test_longPath_balanced() public {
        _run(1, 45);
    }

    function test_longPath_balanced_otherSeed() public {
        _run(2, 45);
    }

    function test_longPath_sellHeavy() public {
        _run(3, 55);
    }

    function test_longPath_buyHeavy() public {
        _run(4, 30);
    }

    /// @param sellPct Share of steps that are sells, of 1% to 100% of the trader's balance.
    function _run(uint256 seed, uint256 sellPct) internal {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        IV1Coin v1Coin = _createV1Coin(creator, 1000 * ONE_USDC);
        uint256 paid;
        uint256 v1Paid;

        for (uint256 i; i < STEPS; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address trader = traders[r % 3];
            if ((r >> 8) % 100 < sellPct && coin.balanceOf(trader) != 0 && v1Coin.balanceOf(trader) != 0) {
                uint256 pct = 1 + ((r >> 16) % 100);
                paid += _sell(coin, trader, (coin.balanceOf(trader) * pct) / 100);
                v1Paid += _v1Sell(v1Coin, trader, (v1Coin.balanceOf(trader) * pct) / 100);
            } else {
                // between 10 and about 40,000 USDC, evenly spread across orders of magnitude
                uint256 amount = (10 * ONE_USDC) << ((r >> 16) % 12);
                amount += (amount * ((r >> 32) % 100)) / 100;
                _buy(coin, trader, amount);
                _v1Buy(v1Coin, trader, amount);
            }

            WavefrontLens.CoinData memory data = lens.getCoinData(address(coin), address(0));
            assertApproxEqRel(data.marketPrice, v1Coin.getMarketPrice(), PRICE_PARITY, "market price");
            assertApproxEqRel(data.floorPrice, v1Coin.getFloorPrice(), PRICE_PARITY, "floor price");
        }

        // Everyone exits, the creator last. v1 pushes the team's fee coins to the creator as they
        // accrue; on v4 they are claimed.
        for (uint256 i; i < 4; ++i) {
            address seller = i < 3 ? traders[i] : creator;
            if (i == 3) hook.claimFees(address(coin), creator);
            if (coin.balanceOf(seller) != 0) paid += _sell(coin, seller, coin.balanceOf(seller));
            if (v1Coin.balanceOf(seller) != 0) v1Paid += _v1Sell(v1Coin, seller, v1Coin.balanceOf(seller));
        }
        assertApproxEqRel(paid, v1Paid, PAYOUT_PARITY, "total paid to sellers");
        // what is not in the position is less than a tick spacing (0.1%) of what the market holds
        uint256 real = lens.getCoinData(address(coin), address(0)).realQuote;
        assertLe(_market(coin).idleQuote, (real + _market(coin).idleQuote) / 999 + 2, "quote left idle");
    }
}

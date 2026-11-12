// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Coin} from "../src/Coin.sol";
import {IWavefrontHook} from "../src/interfaces/IWavefrontHook.sol";
import {MockQuote} from "./mocks/MockQuote.sol";
import {WavefrontFixture} from "./utils/WavefrontFixture.sol";

/// @notice The smallest market anyone can make: the minimum launch against an 18-decimal quote, bought
///         up and burned down by its creator until a burn would take it under `MIN_LIQUIDITY`. Supply
///         ends near 1e13 raw coins and liquidity near 4e9, so a single raw unit of rounding is
///         visible in the price (see "Known limits" in the README).
/// @dev What must survive even here is that nobody is frozen in: a buy, a donation, and a sell of
///      coins that are not collateral never revert, whatever came before.
contract WeiScaleTest is WavefrontFixture {
    MockQuote internal weth;
    Coin internal coin;

    function setUp() public {
        _deployV1();
        _deployV4();
        weth = new MockQuote("Wrapped Ether", "WETH", 18);
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.quote = address(weth);
        params.supply = 1e21;
        params.virtualQuote = 1e6;
        params.fee = 10_000;
        (coin,) = _launchWith(creator, params, 0);

        _buy(coin, creator, 2e9);
        for (uint256 i; i < 12; ++i) {
            uint256 balance = coin.balanceOf(creator);
            uint256 keep = hook.effectiveSupply(address(coin)) / 400;
            if (balance <= keep) break;
            _burn(coin, creator, balance - keep);
            _buy(coin, creator, 2e9);
        }
    }

    function test_setup_reachesTheSmallestMarket() public view {
        assertLt(_market(coin).liquidity, 1e10, "liquidity was not burned down");
        // and no further: the last burn is refused and waits
        assertGe(_market(coin).liquidity, hook.MIN_LIQUIDITY(), "a burn thinned the position past the minimum");
        assertGt(_market(coin).pendingBurn, 0, "the burn that would have gone under was applied");
        assertLt(hook.effectiveSupply(address(coin)), 1e14, "supply was not burned down");
    }

    function testFuzz_nobodyIsFrozenIn(uint256 seed) public {
        address[3] memory actors = [creator, alice, bob];
        for (uint256 i; i < 40; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address who = actors[r % 3];
            uint256 action = (r >> 8) % 6;
            uint256 x = r >> 16;
            if (action < 2) {
                // anything from one raw unit to a few whole tokens
                uint256 amount = _anyMagnitude(x, 62);
                weth.mint(who, amount);
                vm.startPrank(who);
                weth.approve(address(router), amount);
                router.buy(address(coin), amount, 0, 0);
                vm.stopPrank();
            } else if (action == 2) {
                _sellFree(who, x);
            } else if (action == 3) {
                uint256 credit = hook.creditOf(address(coin), who);
                if (credit == 0) continue;
                vm.prank(who);
                // may be refused: at this scale the lock rounds by more than the credit view shows
                try hook.borrow(address(coin), bound(x, 1, credit), who) {} catch {}
            } else if (action == 4) {
                uint256 debt = hook.debtOf(address(coin), who);
                if (debt == 0) continue;
                uint256 amount = bound(x, 1, debt);
                weth.mint(who, amount);
                vm.startPrank(who);
                weth.approve(address(hook), amount);
                // may be refused while the pool holds no whole coin (a known limit)
                try hook.repay(address(coin), who, amount) {} catch {}
                vm.stopPrank();
            } else {
                _heal(coin, who, _anyMagnitude(x, 50));
            }
        }
        for (uint256 k; k < 3; ++k) {
            _sellFree(actors[k], type(uint256).max);
        }
    }

    /// @dev Sells up to all of `who`'s coins that are not collateral. A borrower's own sale may be
    ///      refused by their lock, which here can round up by a few raw coins as the sale lands;
    ///      someone with no debt must always get out.
    function _sellFree(address who, uint256 x) internal {
        uint256 balance = coin.balanceOf(who);
        uint256 locked = hook.lockedOf(address(coin), who);
        if (balance <= locked) return;
        uint256 amount = bound(x, 1, balance - locked);
        bool borrower = hook.debtOf(address(coin), who) != 0;

        vm.startPrank(who);
        coin.approve(address(router), amount);
        try router.sell(address(coin), amount, 0, 0) {}
        catch (bytes memory reason) {
            assertTrue(borrower && bytes4(reason) == Coin.CollateralLocked.selector, "a sale was refused");
        }
        vm.stopPrank();
    }

    /// @dev A magnitude drawn evenly over bit lengths, so one raw unit is as likely as a whole token.
    function _anyMagnitude(uint256 seed, uint256 maxBits) internal pure returns (uint256) {
        uint256 bits = 1 + seed % maxBits;
        uint256 low = 1 << (bits - 1);
        return low + (uint256(keccak256(abi.encode(seed))) % low);
    }
}

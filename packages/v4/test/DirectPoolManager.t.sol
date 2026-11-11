// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Coin} from "../src/Coin.sol";
import {WavefrontRouter} from "../src/WavefrontRouter.sol";
import {IWavefrontHook} from "../src/interfaces/IWavefrontHook.sol";
import {WavefrontFixture} from "./utils/WavefrontFixture.sol";

/// @notice What someone can do by talking to the PoolManager themselves instead of going through a
///         router: swaps no router sends, several swaps before paying for any, and credits handed to
///         the hook that it never asked for. The rest of the suite trades through the router only.
contract DirectPoolManagerTest is WavefrontFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ONE_USDC = 1e6;

    DirectTrader internal trader;
    Coin internal coin;
    PoolKey internal key;

    function setUp() public {
        _deployV1();
        _deployV4();
        trader = new DirectTrader(manager, address(hook));
        (coin,) = _launch(creator, 20_000 * ONE_USDC);
        key = hook.poolKey(address(coin));
        _buy(coin, alice, 200_000 * ONE_USDC);
        _buy(coin, bob, 50_000 * ONE_USDC);
        quote.mint(alice, 1e15);
        vm.startPrank(alice);
        quote.approve(address(trader), type(uint256).max);
        coin.approve(address(trader), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             UNUSUAL SWAPS
    //////////////////////////////////////////////////////////////*/

    /// @notice Exact-output swaps, arbitrary price limits and up to four swaps in either direction
    ///         before any is paid for, with a borrower in the market. After every batch the hook's
    ///         claims equal what it accounts for, the floor has not fallen, the price is inside the
    ///         position and the borrower's lock is covered; at the end everyone can still leave.
    function testFuzz_unusualSwaps_keepTheBooksBalanced(uint256 seed) public {
        _borrow(coin, bob, hook.creditOf(address(coin), bob) / 2);
        int24 floorTick = _market(coin).floorTick;

        for (uint256 round; round < 8; ++round) {
            SwapParams[] memory swaps = _randomSwaps(seed, round);
            vm.prank(alice);
            // a batch alice cannot pay for reverts as a whole, which is fine
            try trader.swap(key, swaps) {} catch {}

            IWavefrontHook.Market memory m = _market(coin);
            assertGe(m.floorTick, floorTick, "floor fell");
            floorTick = m.floorTick;
            _assertBooksBalance(m);
            (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
            assertGe(price, TickMath.getSqrtPriceAtTick(m.lowerTick), "price left below the position");
            assertLe(hook.lockedOf(address(coin), bob), coin.balanceOf(bob), "lock outgrew the balance");
        }

        _repay(coin, bob, hook.debtOf(address(coin), bob));
        _sell(coin, bob, coin.balanceOf(bob));
        _sell(coin, alice, coin.balanceOf(alice));
        _sell(coin, creator, coin.balanceOf(creator));
    }

    /// @dev Guards the fuzz test above against passing because nothing ran.
    function test_unusualSwaps_mostBatchesGoThrough() public {
        _borrow(coin, bob, hook.creditOf(address(coin), bob) / 2);
        uint256 done;
        for (uint256 round; round < 40; ++round) {
            SwapParams[] memory swaps = _randomSwaps(7, round);
            vm.prank(alice);
            try trader.swap(key, swaps) {
                ++done;
            } catch {}
        }
        assertGt(done, 30, "too few batches executed for the fuzz test to mean anything");
    }

    /// @notice A sell split into several swaps inside one unlock, paid for at the end. The first swap
    ///         can queue a burn, and the next one then redeems those coins from the PoolManager before
    ///         the seller has delivered any.
    function testFuzz_splitSell_beforePaying(uint256 parts, uint256 burnShare) public {
        parts = bound(parts, 2, 6);
        burnShare = bound(burnShare, 0, 80);
        // a burn left over from someone else, so that the queue the first swap creates is large
        if (burnShare != 0) _burn(coin, bob, coin.balanceOf(bob) * burnShare / 100);

        uint256 amount = coin.balanceOf(alice);
        SwapParams[] memory swaps = new SwapParams[](parts);
        for (uint256 i; i < parts; ++i) {
            swaps[i] = SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(amount / parts),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });
        }
        uint256 before = quote.balanceOf(alice);
        vm.prank(alice);
        trader.swap(key, swaps);
        assertGt(quote.balanceOf(alice), before);
        _assertBooksBalance(_market(coin));
    }

    /*//////////////////////////////////////////////////////////////
                           UNINVITED CREDITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Anyone can settle tokens with the PoolManager in the hook's name, leaving the hook a
    ///         credit it did not create. The hook books only what its own calls return, so the credit
    ///         stays unsettled and the PoolManager reverts the whole transaction.
    /// @dev Found in review: a rebalance used to read the hook's running balance, so coins given this
    ///      way were burned on the spot, without the pool's side of the burn and past the holders
    ///      rule, and quote went straight to idle.
    function test_uninvitedCoinCredit_isNotBookedAsABurn() public {
        uint256 gift = coin.balanceOf(alice) / 2;
        IWavefrontHook.Market memory before = _market(coin);
        uint256 supply = hook.effectiveSupply(address(coin));

        vm.prank(alice);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        // the buy is big enough to trigger a rebalance in the same unlock
        trader.giftThenBuy(key, gift, 0, 100_000 * ONE_USDC);

        assertEq(_market(coin).burnQueue, before.burnQueue);
        assertEq(hook.effectiveSupply(address(coin)), supply);
    }

    function test_uninvitedQuoteCredit_isNotBookedAsIdle() public {
        IWavefrontHook.Market memory before = _market(coin);

        vm.prank(alice);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.giftThenBuy(key, 0, 5000 * ONE_USDC, 100_000 * ONE_USDC);

        assertEq(_market(coin).idleQuote, before.idleQuote);
    }

    /*//////////////////////////////////////////////////////////////
                         NOTHING BELOW THE POSITION
    //////////////////////////////////////////////////////////////*/

    /// @notice A sell when the price already sits on the bottom of the position fills nothing: the
    ///         seller keeps their coins, the price ends where it started, and the router reports
    ///         what was actually sold.
    /// @dev The swap runs the price through the empty range to its limit and the hook brings it
    ///      back, which costs the seller a few million gas. See the README's known limits.
    function test_sellWithNothingBelow_fillsNothingAndReportsIt() public {
        (Coin fresh,) = _launch(creator, 0);
        PoolKey memory freshKey = hook.poolKey(address(fresh));
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(freshKey.toId());

        vm.expectEmit(address(router));
        emit WavefrontRouter.Sold(address(fresh), alice, 0, 0);
        vm.prank(alice);
        uint256 out = router.sell(address(fresh), 1e18, 0, 0);

        assertEq(out, 0);
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(freshKey.toId());
        assertEq(priceAfter, priceBefore, "price was not restored");
    }

    /*//////////////////////////////////////////////////////////////
                              KNOWN LIMITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Documents a known limit rather than a guarantee. A donation into a coin whose holders
    ///         have under 0.1% of the supply waits for holders, and whoever takes holders over 0.1%
    ///         collects most of it, even if they sell again inside the same transaction.
    function test_knownLimit_waitingDonationGoesToWhoeverCrossesTheHoldersLine() public {
        (Coin fresh,) = _launch(creator, 0);
        PoolKey memory freshKey = hook.poolKey(address(fresh));
        // bob holds about 0.05% of the supply
        _buy(fresh, bob, 50 * ONE_USDC);
        assertLt(fresh.balanceOf(bob), fresh.totalSupply() / 1000);
        _heal(fresh, creator, 10_000 * ONE_USDC);
        assertGe(_market(fresh).pendingHeal, 10_000 * ONE_USDC, "the donation waits");

        // alice buys 0.2% of the supply and sells it straight back, paying only at the end
        uint256 coins = fresh.totalSupply() / 500;
        SwapParams[] memory swaps = new SwapParams[](2);
        swaps[0] = SwapParams({
            zeroForOne: false, amountSpecified: int256(coins), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        swaps[1] = SwapParams({
            zeroForOne: true, amountSpecified: -int256(coins), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        uint256 before = quote.balanceOf(alice);
        vm.startPrank(alice);
        fresh.approve(address(trader), type(uint256).max);
        trader.swap(freshKey, swaps);
        vm.stopPrank();

        assertEq(_market(fresh).pendingHeal, 0, "the donation was applied");
        // she held four fifths of the circulating coins when it was, and paid the fee both ways
        assertGt(quote.balanceOf(alice) - before, 7000 * ONE_USDC);
        assertLt(quote.balanceOf(alice) - before, 8000 * ONE_USDC);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertBooksBalance(IWavefrontHook.Market memory m) internal view {
        assertEq(
            _claims(address(quote)),
            m.idleQuote + m.pendingHeal + hook.feesOwed(address(quote), creator)
                + hook.feesOwed(address(quote), treasury),
            "quote claims"
        );
        assertEq(
            _claims(address(coin)),
            m.pendingBurn + m.burnQueue + hook.feesOwed(address(coin), creator)
                + hook.feesOwed(address(coin), treasury),
            "coin claims"
        );
    }

    function _randomSwaps(uint256 seed, uint256 round) internal view returns (SwapParams[] memory swaps) {
        uint256 n = 1 + uint256(keccak256(abi.encode(seed, round))) % 4;
        swaps = new SwapParams[](n);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        for (uint256 j; j < n; ++j) {
            uint256 r = uint256(keccak256(abi.encode(seed, round, j)));
            bool sell = r & 1 == 1;
            bool exactOut = (r >> 1) & 1 == 1;
            // the amount is in coins for an exact-input sell or an exact-output buy, else in quote
            uint256 amount = sell == !exactOut
                ? bound(r >> 8, 1, coin.balanceOf(alice) / 3 + 1)
                : bound(r >> 8, 1, 300_000 * ONE_USDC);
            uint160 limit;
            uint256 mode = (r >> 2) % 3;
            if (mode == 0) {
                limit = sell ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
            } else if (mode == 1) {
                limit = sell ? uint160(uint256(price) * 97 / 100) : uint160(uint256(price) * 103 / 100);
            } else {
                limit = sell ? uint160(uint256(price) / 50) : uint160(uint256(price) * 50);
            }
            swaps[j] = SwapParams({
                zeroForOne: sell, amountSpecified: exactOut ? int256(amount) : -int256(amount), sqrtPriceLimitX96: limit
            });
        }
    }
}

/// @dev Talks to the PoolManager directly on behalf of whoever calls it.
contract DirectTrader is IUnlockCallback {
    IPoolManager internal immutable manager;
    address internal immutable hook;

    struct Batch {
        address payer;
        PoolKey key;
        uint256 coinGift;
        uint256 quoteGift;
        SwapParams[] swaps;
    }

    constructor(IPoolManager manager_, address hook_) {
        manager = manager_;
        hook = hook_;
    }

    /// @notice Runs `swaps` in order inside one unlock and settles the net at the end. A swap the
    ///         PoolManager refuses (a limit on the wrong side of the price) is skipped.
    function swap(PoolKey memory key, SwapParams[] memory swaps) external {
        manager.unlock(abi.encode(Batch(msg.sender, key, 0, 0, swaps)));
    }

    /// @notice Settles `coinGift` and `quoteGift` in the hook's name, then buys with `quoteIn`.
    function giftThenBuy(PoolKey memory key, uint256 coinGift, uint256 quoteGift, uint256 quoteIn) external {
        SwapParams[] memory swaps = new SwapParams[](1);
        swaps[0] = SwapParams({
            zeroForOne: false, amountSpecified: -int256(quoteIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
        manager.unlock(abi.encode(Batch(msg.sender, key, coinGift, quoteGift, swaps)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        Batch memory b = abi.decode(data, (Batch));
        if (b.coinGift != 0) _pay(b.key.currency0, b.payer, b.coinGift, hook);
        if (b.quoteGift != 0) _pay(b.key.currency1, b.payer, b.quoteGift, hook);

        int256 coins;
        int256 quote;
        for (uint256 i; i < b.swaps.length; ++i) {
            try manager.swap(b.key, b.swaps[i], "") returns (BalanceDelta delta) {
                coins += delta.amount0();
                quote += delta.amount1();
            } catch {}
        }
        _settle(b.key.currency0, b.payer, coins);
        _settle(b.key.currency1, b.payer, quote);
        return "";
    }

    function _settle(Currency currency, address payer, int256 delta) internal {
        if (delta < 0) {
            _pay(currency, payer, uint256(-delta), address(this));
        } else if (delta > 0) {
            manager.take(currency, payer, uint256(delta));
        }
    }

    function _pay(Currency currency, address payer, uint256 amount, address creditTo) internal {
        manager.sync(currency);
        IERC20(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
        manager.settleFor(creditTo);
    }
}

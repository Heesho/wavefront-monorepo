// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {Vm} from "forge-std/Vm.sol";

import {Coin} from "../src/Coin.sol";
import {WavefrontLens} from "../src/WavefrontLens.sol";
import {WavefrontRouter} from "../src/WavefrontRouter.sol";
import {IWavefrontHook} from "../src/interfaces/IWavefrontHook.sol";
import {MockQuote} from "./mocks/MockQuote.sol";
import {IV1Coin} from "./reference/V1.sol";
import {LiquidityProbe} from "./utils/LiquidityProbe.sol";
import {WavefrontFixture} from "./utils/WavefrontFixture.sol";

/// @notice Behaviour of the v4 system, checked against the deployed v1 contracts wherever v1 has an equivalent.
contract WavefrontHookTest is WavefrontFixture {
    uint256 internal constant ONE_USDC = 1e6;
    /// @dev Over a sequence, each sell of up to half a position can double the sub-step lag between the
    ///      two systems, so per-trade agreement inside a long sequence is checked to 2%. Single trades
    ///      are held to PARITY by the tests around it.
    uint256 internal constant SEQUENCE_PARITY = 2e16;

    function setUp() public {
        _deployV1();
        _deployV4();
    }

    /// @dev Launches the same coin on both systems with the same creation buy.
    function _launchBoth(uint256 quoteIn) internal returns (Coin coin, IV1Coin v1Coin) {
        (coin,) = _launch(creator, quoteIn);
        v1Coin = _createV1Coin(creator, quoteIn);
    }

    /*//////////////////////////////////////////////////////////////
                                  LAUNCH
    //////////////////////////////////////////////////////////////*/

    function test_launch_placesWholeSupplyAtTheFloor() public {
        (Coin coin, uint256 coinOut) = _launch(creator, 0);
        IWavefrontHook.Market memory m = _market(coin);

        assertEq(coinOut, 0);
        assertEq(hook.sqrtPriceX96(address(coin)), m.sqrtFloorX96, "price starts on the floor");
        assertEq(m.sqrtFloorX96, TickMath.getSqrtPriceAtTick(m.floorTick), "floor sits exactly on a tick");
        assertEq(m.lowerTick, m.floorTick);
        assertEq(m.quote, address(quote));
        assertApproxEqRel(coin.balanceOf(address(manager)), COIN_SUPPLY, 1e9, "supply sits in the pool");
        assertEq(coin.balanceOf(address(hook)), 0);
        assertEq(quote.balanceOf(address(manager)), 0);
        // 100,000 USDC virtual / 1B coins = 0.0001 USDC per coin, the v1 launch floor
        assertApproxEqRel(lens.getCoinData(address(coin), address(0)).floorPrice, 1e14, PARITY);
    }

    function test_launch_registersCoinAndSetsOwnerTeamAndUri() public {
        (Coin first,) = _launch(creator, 0);
        (Coin second,) = _launch(alice, 0);

        assertEq(hook.coinCount(), 2);
        assertEq(hook.coinAt(1), address(first));
        assertEq(hook.coinAt(2), address(second));
        assertEq(_market(second).index, 2);
        assertEq(first.owner(), creator);
        assertEq(first.team(), creator);
        assertEq(first.hook(), address(hook));
        assertEq(first.contractURI(), "ipfs://wave");
        assertEq(second.owner(), alice);
    }

    function test_launch_deploysToThePredictedAddress() public {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        _mineSalt(creator, params);
        address predicted = router.predictCoin(creator, params);
        vm.prank(creator);
        (address coin,) = router.launch(params, 0, 0);
        assertEq(coin, predicted);
    }

    function test_launch_revertsWhenCoinSortsAboveQuote() public {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        for (uint256 i;; ++i) {
            params.salt = bytes32(i);
            if (router.predictCoin(creator, params) > address(quote)) break;
        }
        vm.prank(creator);
        vm.expectRevert(IWavefrontHook.CoinMustSortBelowQuote.selector);
        router.launch(params, 0, 0);
    }

    function test_launch_creatorBuysFirstInTheSameTransaction_matchesV1() public {
        (Coin coin, uint256 coinOut) = _launch(creator, 1000 * ONE_USDC);
        IV1Coin v1Coin = _createV1Coin(creator, 1000 * ONE_USDC);

        // v1 mints the creation buy to Core, which keeps one coin and forwards the rest
        assertApproxEqRel(coinOut, v1Coin.totalSupply(), PARITY, "coins out");
        assertEq(coin.balanceOf(creator), coinOut);
        assertEq(quote.balanceOf(creator), 0, "the creator's quote was spent");
        _assertParity(coin, v1Coin, "after creation buy");
    }

    function test_launch_firstBuyRevertsOnSlippage() public {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        _mineSalt(creator, params);
        quote.mint(creator, 1000 * ONE_USDC);
        vm.startPrank(creator);
        quote.approve(address(router), 1000 * ONE_USDC);
        vm.expectRevert(WavefrontRouter.Slippage.selector);
        router.launch(params, 1000 * ONE_USDC, COIN_SUPPLY);
        vm.stopPrank();
    }

    /// @notice Someone who sees a pending launch cannot take its address or buy ahead of the creator.
    function test_launch_cannotBeFrontRun() public {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        _mineSalt(creator, params);
        address expected = router.predictCoin(creator, params);

        // the attacker replays the creator's exact parameters, through the router and directly
        vm.startPrank(bob);
        try router.launch(params, 0, 0) returns (address replayed, uint256) {
            assertTrue(replayed != expected);
        } catch {}
        try hook.launch(params) returns (address direct) {
            assertTrue(direct != expected);
        } catch {}
        vm.stopPrank();

        quote.mint(creator, 1000 * ONE_USDC);
        vm.startPrank(creator);
        quote.approve(address(router), 1000 * ONE_USDC);
        (address coin, uint256 coinOut) = router.launch(params, 1000 * ONE_USDC, 0);
        vm.stopPrank();
        assertEq(coin, expected);
        // the creator bought at the untouched launch price
        assertGt(coinOut, 9_700_000e18);
    }

    function test_launch_creatorChoosesSupplyAndVirtualLiquidity() public {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.supply = 21_000_000e18;
        params.virtualQuote = 42_000e6;
        (Coin coin,) = _launchWith(creator, params, 0);

        assertApproxEqRel(coin.totalSupply(), 21_000_000e18, 1e9);
        // launch price = virtual liquidity / supply = 0.002 USDC per coin
        assertApproxEqRel(lens.getCoinData(address(coin), address(0)).floorPrice, 2e15, PARITY);

        // a deeper curve moves less for the same buy
        params.virtualQuote = 420_000e6;
        (Coin deep,) = _launchWith(creator, params, 0);
        _buy(coin, alice, 1000 * ONE_USDC);
        _buy(deep, alice, 1000 * ONE_USDC);
        uint256 shallowMove = (uint256(hook.sqrtPriceX96(address(coin))) * 1e18) / _market(coin).sqrtFloorX96;
        uint256 deepMove = (uint256(hook.sqrtPriceX96(address(deep))) * 1e18) / _market(deep).sqrtFloorX96;
        assertGt(shallowMove, deepMove);
    }

    function test_launch_revertsOnInvalidParams() public {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);

        params.supply = 1e20;
        vm.expectRevert(IWavefrontHook.InvalidLaunchParams.selector);
        hook.launch(params);

        params = _defaultParams(creator);
        params.virtualQuote = 0;
        vm.expectRevert(IWavefrontHook.InvalidLaunchParams.selector);
        hook.launch(params);

        // more liquidity than the hook lets a position hold
        params = _defaultParams(creator);
        params.supply = 1e38;
        params.virtualQuote = 1e30;
        _mineSalt(creator, params);
        vm.expectRevert(IWavefrontHook.InvalidLaunchParams.selector);
        vm.prank(creator);
        router.launch(params, 0, 0);

        params = _defaultParams(creator);
        params.quote = address(0);
        vm.expectRevert(IWavefrontHook.InvalidLaunchParams.selector);
        hook.launch(params);
    }

    function test_launch_anyStandardErc20CanBeTheQuote() public {
        MockQuote weth = new MockQuote("Wrapped Ether", "WETH", 18);
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.quote = address(weth);
        params.virtualQuote = 30 ether;
        (Coin coin,) = _launchWith(creator, params, 0);

        assertEq(_market(coin).quote, address(weth));
        // 30 WETH / 1B coins, reported per whole token whatever the decimals
        assertApproxEqRel(lens.getCoinData(address(coin), address(0)).floorPrice, 30e9, PARITY);

        // the whole lifecycle works against an 18-decimal quote
        uint256 bought = _buy(coin, alice, 5 ether);
        uint256 debt = (hook.creditOf(address(coin), alice) * 95) / 100;
        _borrow(coin, alice, debt);
        assertEq(weth.balanceOf(alice), debt);
        _repay(coin, alice, debt);
        assertGt(_sell(coin, alice, bought), 0);
        assertGt(hook.feesOwed(address(weth), creator), 0);
        assertEq(hook.feesOwed(address(quote), creator), 0, "fees are kept per quote token");
    }

    function test_pool_onlyTheHookCanInitializeOrAddLiquidity() public {
        (Coin coin,) = _launch(creator, 0);
        PoolKey memory key = hook.poolKey(address(coin));
        IWavefrontHook.Market memory m = _market(coin);

        // a second pool on the same hook
        PoolKey memory other = PoolKey(key.currency0, key.currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(other, m.sqrtFloorX96);

        // outside liquidity on the real pool
        LiquidityProbe probe = new LiquidityProbe(manager);
        vm.expectRevert();
        probe.tryAdd(key, m.floorTick, m.floorTick + 10 * TICK_SPACING);
    }

    /*//////////////////////////////////////////////////////////////
                                  TRADING
    //////////////////////////////////////////////////////////////*/

    function testFuzz_buy_matchesV1(uint256 quoteIn) public {
        quoteIn = bound(quoteIn, ONE_USDC, 1_000_000 * ONE_USDC);
        (Coin coin, IV1Coin v1Coin) = _launchBoth(1000 * ONE_USDC);

        uint256 coinOut = _buy(coin, alice, quoteIn);
        uint256 expected = _v1Buy(v1Coin, alice, quoteIn);

        assertApproxEqRel(coinOut, expected, PARITY, "coins out");
        _assertParity(coin, v1Coin, "after buy");
    }

    function testFuzz_buyThenSell_matchesV1(uint256 quoteIn, uint256 sellBps) public {
        quoteIn = bound(quoteIn, 10 * ONE_USDC, 1_000_000 * ONE_USDC);
        sellBps = bound(sellBps, 1, 10_000);
        (Coin coin, IV1Coin v1Coin) = _launchBoth(1000 * ONE_USDC);

        uint256 bought = _buy(coin, alice, quoteIn);
        uint256 v1Bought = _v1Buy(v1Coin, alice, quoteIn);
        // sell the same absolute amount on both
        uint256 coinIn = ((bought < v1Bought ? bought : v1Bought) * sellBps) / 10_000;

        uint256 quoteOut = _sell(coin, alice, coinIn);
        uint256 expected = _v1Sell(v1Coin, alice, coinIn);

        assertApproxEqRel(quoteOut, expected, PARITY, "quote out");
        _assertSameBacking(coin, v1Coin, quoteIn);
        // After selling most of a position, what is left is a small remainder of two large numbers, so
        // the sub-step lag between v4 and v1 is magnified in relative terms. State is compared only
        // while at least half the position remains.
        if (sellBps <= 5000) _assertParity(coin, v1Coin, "after sell");
    }

    /// @dev Both systems hold the same quote for the coin, to within PARITY of the volume traded. On v4
    ///      that is everything in the PoolManager; on v1 it is the coin's balance plus fees already paid.
    function _assertSameBacking(Coin coin, IV1Coin v1Coin, uint256 volume) internal view {
        coin;
        uint256 v4Backing = quote.balanceOf(address(manager));
        uint256 v1Backing =
            v1Quote.balanceOf(address(v1Coin)) + v1Quote.balanceOf(creator) + v1Quote.balanceOf(v1Treasury);
        assertApproxEqAbs(v4Backing, v1Backing, (volume * PARITY) / 1e18 + 10, "quote held for the coin");
    }

    function testFuzz_tradeSequence_matchesV1(uint256[8] memory amounts) public {
        (Coin coin, IV1Coin v1Coin) = _launchBoth(1000 * ONE_USDC);
        uint256 volume = 1000 * ONE_USDC;
        for (uint256 i; i < amounts.length; ++i) {
            address trader = i % 2 == 0 ? alice : bob;
            uint256 balance = coin.balanceOf(trader);
            uint256 v1Balance = v1Coin.balanceOf(trader);
            if (amounts[i] % 3 == 0 && balance != 0 && v1Balance != 0) {
                // sells are capped at half a position: near-total exits magnify the sub-step lag between
                // the two systems (see buyThenSell) and are covered by the tests around this one
                uint256 coinIn = ((balance < v1Balance ? balance : v1Balance) * (1 + (amounts[i] % 50))) / 100;
                uint256 quoteOut = _sell(coin, trader, coinIn);
                assertApproxEqRel(quoteOut, _v1Sell(v1Coin, trader, coinIn), SEQUENCE_PARITY, "quote out");
                volume += quoteOut;
            } else {
                uint256 quoteIn = bound(amounts[i], ONE_USDC, 200_000 * ONE_USDC);
                assertApproxEqRel(
                    _buy(coin, trader, quoteIn), _v1Buy(v1Coin, trader, quoteIn), SEQUENCE_PARITY, "coin out"
                );
                volume += quoteIn;
            }
        }
        _assertSameBacking(coin, v1Coin, volume);
    }

    /// @notice The only holder of a coin can always sell every coin they hold, however small the position.
    function testFuzz_soleHolderCanSellEverything(uint256 quoteIn) public {
        quoteIn = bound(quoteIn, ONE_USDC / 100, 1_000_000 * ONE_USDC);
        (Coin coin,) = _launch(creator, 0);

        uint256 bought = _buy(coin, alice, quoteIn);
        uint256 quoteOut = _sell(coin, alice, bought);

        assertEq(coin.balanceOf(alice), 0, "every coin was sold");
        // a round trip costs the 2% fee twice; the seller gets back at least what the curve math says
        assertGe(quoteOut + 2, (quoteIn * 98 * 98) / 10_000 - quoteIn / 1000);
        assertLe(quoteOut, quoteIn);
    }

    function test_swap_isAStandardPoolManagerSwap() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);

        vm.recordLogs();
        uint256 coinOut = _buy(coin, alice, 5000 * ONE_USDC);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != IPoolManager.Swap.selector) continue;
            (int128 amount0, int128 amount1,, uint128 liquidity,,) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            if (swaps == 0) {
                // the trade itself: real amounts against real liquidity, as any indexer expects
                assertEq(uint256(uint128(amount0)), coinOut);
                assertEq(uint256(uint128(-amount1)), 5000 * ONE_USDC);
                assertGt(liquidity, 0);
            } else {
                // a floor step's price move: no tokens change hands
                assertEq(amount0, 0);
                assertEq(amount1, 0);
            }
            ++swaps;
        }
        assertGe(swaps, 1);
        assertLe(swaps, 2);
    }

    /// @notice Most trades only collect the fee; the position is re-created only when the floor can step.
    function test_swap_smallTradesDoNotRecreateThePosition() public {
        (Coin coin,) = _launch(creator, 100_000 * ONE_USDC);
        _buy(coin, alice, 10_000 * ONE_USDC);
        IWavefrontHook.Market memory before = _market(coin);

        vm.recordLogs();
        _buy(coin, alice, ONE_USDC);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        IWavefrontHook.Market memory m = _market(coin);
        assertEq(m.floorTick, before.floorTick);
        assertEq(m.liquidity, before.liquidity);
        assertGt(m.pendingHeal, before.pendingHeal, "the fee waits for the next step");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IWavefrontHook.Rebalanced.selector, "no rebalance on a small trade");
        }
    }

    function test_router_revertsAfterDeadline() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        vm.warp(1000);
        quote.mint(alice, ONE_USDC);
        vm.startPrank(alice);
        quote.approve(address(router), ONE_USDC);
        vm.expectRevert(WavefrontRouter.Expired.selector);
        router.buy(address(coin), ONE_USDC, 0, 999);
        vm.stopPrank();
    }

    function test_router_revertsOnSlippage() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        quote.mint(alice, ONE_USDC);
        vm.startPrank(alice);
        quote.approve(address(router), ONE_USDC);
        vm.expectRevert(WavefrontRouter.Slippage.selector);
        router.buy(address(coin), ONE_USDC, COIN_SUPPLY, 0);
        vm.stopPrank();
    }

    function testFuzz_lens_quotesMatchExecution(uint256 quoteIn, uint256 sellBps) public {
        quoteIn = bound(quoteIn, ONE_USDC, 1_000_000 * ONE_USDC);
        sellBps = bound(sellBps, 1, 10_000);
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);

        // the pool fills a trade in several internal steps, each rounding by a wei, so quotes agree
        // to a part in a billion rather than exactly
        uint256 quotedBuy = lens.quoteBuy(address(coin), quoteIn);
        uint256 bought = _buy(coin, alice, quoteIn);
        assertApproxEqRel(bought, quotedBuy, 1e9, "buy quote");

        uint256 coinIn = (bought * sellBps) / 10_000;
        uint256 quotedSell = lens.quoteSell(address(coin), coinIn);
        assertApproxEqAbs(_sell(coin, alice, coinIn), quotedSell, 2 + quotedSell / 1e9, "sell quote");
    }

    /*//////////////////////////////////////////////////////////////
                                   FEES
    //////////////////////////////////////////////////////////////*/

    function test_fees_buyCreditsTeamAndTreasury_restHeals() public {
        (Coin coin,) = _launch(creator, 0);
        uint256 quoteIn = 1000 * ONE_USDC;
        _buy(coin, alice, quoteIn);

        // 2% fee = 20 USDC; team and treasury 20% of it each = 4 USDC; the other 12 USDC heals
        assertApproxEqAbs(hook.feesOwed(address(quote), creator), 4 * ONE_USDC, 2);
        assertApproxEqAbs(hook.feesOwed(address(quote), treasury), 4 * ONE_USDC, 2);
        // nothing left the system: the PoolManager holds the full 1,000 USDC
        assertEq(quote.balanceOf(address(manager)), quoteIn);
        IWavefrontHook.Market memory m = _market(coin);
        // the hook's claims are exactly what it accounts for
        assertEq(
            _claims(address(quote)),
            m.idleQuote + m.pendingHeal + hook.feesOwed(address(quote), creator)
                + hook.feesOwed(address(quote), treasury)
        );
    }

    function test_fees_claimPaysOutOnce() public {
        (Coin coin,) = _launch(creator, 0);
        _buy(coin, alice, 1000 * ONE_USDC);

        uint256 owed = hook.feesOwed(address(quote), creator);
        uint256 treasuryOwed = hook.feesOwed(address(quote), treasury);
        assertEq(hook.claimFees(address(quote), creator), owed);
        assertEq(quote.balanceOf(creator), owed);
        assertEq(hook.feesOwed(address(quote), creator), 0);
        assertEq(hook.claimFees(address(quote), creator), 0, "second claim pays nothing");
        assertEq(hook.feesOwed(address(quote), treasury), treasuryOwed, "the treasury's share is untouched");
    }

    function test_fees_sellCreditsCoinsToTeamAndTreasury() public {
        (Coin coin,) = _launch(creator, 0);
        uint256 bought = _buy(coin, alice, 1000 * ONE_USDC);
        _sell(coin, alice, bought);

        // 2% of the coins sold is the fee; team and treasury get 20% of it each
        uint256 share = (bought * 2 * 20) / 10_000;
        assertApproxEqRel(hook.feesOwed(address(coin), creator), share, 1e9);
        assertApproxEqRel(hook.feesOwed(address(coin), treasury), share, 1e9);

        uint256 claimed = hook.claimFees(address(coin), creator);
        assertEq(coin.balanceOf(creator), claimed);
        assertApproxEqRel(claimed, share, 1e9);
    }

    function test_fees_unsetTeam_matchesV1() public {
        (Coin coin, IV1Coin v1Coin) = _launchBoth(1000 * ONE_USDC);
        vm.prank(creator);
        coin.setTeam(address(0));
        vm.prank(creator);
        v1Coin.setTeam(address(0));

        uint256 owedBefore = hook.feesOwed(address(quote), creator);
        _buy(coin, alice, 10_000 * ONE_USDC);
        _v1Buy(v1Coin, alice, 10_000 * ONE_USDC);

        assertEq(hook.feesOwed(address(quote), creator), owedBefore, "team is off");
        assertApproxEqAbs(hook.feesOwed(address(quote), treasury), 44 * ONE_USDC, 4);
        _assertParity(coin, v1Coin, "team share healed");
    }

    function test_fees_teamCanBeOffFromLaunch() public {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.team = address(0);
        (Coin coin,) = _launchWith(creator, params, 0);
        _buy(coin, alice, 1000 * ONE_USDC);

        assertEq(coin.team(), address(0));
        assertEq(hook.feesOwed(address(quote), creator), 0);
        assertApproxEqAbs(hook.feesOwed(address(quote), treasury), 4 * ONE_USDC, 2);
    }

    function test_fees_unsetTreasury_routesShareToHeal() public {
        vm.prank(owner);
        hook.setTreasury(address(0));
        (Coin coin,) = _launch(creator, 0);
        _buy(coin, alice, 1000 * ONE_USDC);

        assertEq(hook.feesOwed(address(quote), treasury), 0);
        assertApproxEqAbs(hook.feesOwed(address(quote), creator), 4 * ONE_USDC, 2);
        // 16 of the 20 USDC fee went to the curve instead of 12
        IWavefrontHook.Market memory m = _market(coin);
        assertEq(_claims(address(quote)), m.idleQuote + m.pendingHeal + hook.feesOwed(address(quote), creator));
    }

    function test_coin_ownerControlsTeamAndUri() public {
        (Coin coin,) = _launch(creator, 0);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        coin.setTeam(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        coin.setContractURI("ipfs://hijack");
        vm.stopPrank();

        vm.startPrank(creator);
        coin.setTeam(bob);
        vm.expectEmit(address(coin));
        emit Coin.ContractURIUpdated();
        coin.setContractURI("ipfs://wave-v2");
        vm.stopPrank();

        assertEq(coin.team(), bob);
        assertEq(coin.contractURI(), "ipfs://wave-v2");
        _buy(coin, alice, 1000 * ONE_USDC);
        assertApproxEqAbs(hook.feesOwed(address(quote), bob), 4 * ONE_USDC, 2);
    }

    /*//////////////////////////////////////////////////////////////
                                HEAL / BURN
    //////////////////////////////////////////////////////////////*/

    function testFuzz_heal_matchesV1(uint256 healAmount) public {
        healAmount = bound(healAmount, ONE_USDC, 500_000 * ONE_USDC);
        (Coin coin, IV1Coin v1Coin) = _launchBoth(1000 * ONE_USDC);

        _heal(coin, bob, healAmount);

        v1Quote.mint(bob, healAmount);
        vm.startPrank(bob);
        v1Quote.approve(address(v1Coin), healAmount);
        v1Coin.heal(healAmount);
        vm.stopPrank();

        _assertParity(coin, v1Coin, "after heal");
    }

    function testFuzz_burn_matchesV1(uint256 burnBps) public {
        // burning nearly everything leaves a small remainder, which magnifies the launch rounding
        // between the two systems; the invariant suite covers extreme burns on v4 alone
        burnBps = bound(burnBps, 1, 5000);
        (Coin coin, IV1Coin v1Coin) = _launchBoth(1000 * ONE_USDC);
        uint256 balance = coin.balanceOf(creator);
        uint256 v1Balance = v1Coin.balanceOf(creator);
        uint256 amount = ((balance < v1Balance ? balance : v1Balance) * burnBps) / 10_000;

        _burn(coin, creator, amount);
        vm.prank(creator);
        v1Coin.burn(amount);

        assertEq(coin.balanceOf(creator), balance - amount);
        WavefrontLens.CoinData memory data = lens.getCoinData(address(coin), address(0));
        assertApproxEqRel(data.marketPrice, v1Coin.getMarketPrice(), PARITY, "market price");
        assertApproxEqRel(data.floorPrice, v1Coin.getFloorPrice(), PARITY, "floor price");
        // coins given up but not yet applied to the curve still count as supply until the next step
        assertApproxEqRel(data.supply - data.pendingBurn, v1Coin.maxSupply(), PARITY, "supply");
    }

    function test_heal_onACurveNobodyHasBoughtWaitsForTheFirstBuyer() public {
        (Coin coin,) = _launch(creator, 0);
        int24 floorTick = _market(coin).floorTick;

        _heal(coin, bob, 100 * ONE_USDC);
        assertEq(_market(coin).pendingHeal, 100 * ONE_USDC);
        assertEq(_market(coin).floorTick, floorTick, "nothing to heal into yet");

        _buy(coin, alice, 1000 * ONE_USDC);
        assertGt(_market(coin).floorTick, floorTick, "the donation lifted the floor once there was a holder");
    }

    /// @notice A donation too large for a v4 position to represent is not applied; it must not stop
    ///         trading either.
    function test_heal_beyondTheLiquidityCeiling_staysPendingAndTradingContinues() public {
        MockQuote big = new MockQuote("Big", "BIG", 18);
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.quote = address(big);
        params.supply = 1e38;
        params.virtualQuote = 1e27;
        (Coin coin,) = _launchWith(creator, params, 0);
        _buy(coin, alice, 1e25);
        IWavefrontHook.Market memory before = _market(coin);
        assertLe(before.liquidity, hook.maxLiquidity());

        _heal(coin, bob, 1e29);
        IWavefrontHook.Market memory m = _market(coin);
        assertGe(m.pendingHeal, 1e29, "the donation waits");
        assertEq(m.floorTick, before.floorTick);
        assertEq(m.liquidity, before.liquidity);

        _buy(coin, bob, 1e24);
        assertGt(_sell(coin, alice, coin.balanceOf(alice)), 0);
        m = _market(coin);
        assertGe(m.pendingHeal, 1e29, "and keeps waiting");
        assertLe(m.liquidity, hook.maxLiquidity());
    }

    /// @notice When nearly everyone leaves, what the leavers' fees left behind belongs to whoever
    ///         remains, as on v1. The market must survive that: the last holder can sell, and what no
    ///         holder was left to receive goes to the next buyer instead of being stranded.
    function testFuzz_massExit_leavesAWorkingMarket(uint256 dustBuy, uint256 whaleBuy) public {
        dustBuy = bound(dustBuy, ONE_USDC / 100, 10 * ONE_USDC);
        whaleBuy = bound(whaleBuy, 1000 * ONE_USDC, 5_000_000 * ONE_USDC);
        (Coin coin,) = _launch(creator, 0);
        _buy(coin, bob, dustBuy);
        _buy(coin, alice, whaleBuy);
        int24 floorTick = _market(coin).floorTick;

        _sell(coin, alice, coin.balanceOf(alice));
        uint256 bobOut = _sell(coin, bob, coin.balanceOf(bob));
        // bob paid a 2% fee each way and is owed at least the rest of his money back
        assertGe(bobOut, (dustBuy * 96) / 100 - 1, "the last holder lost money to the exit");

        IWavefrontHook.Market memory m = _market(coin);
        assertGe(m.floorTick, floorTick);
        assertEq(m.totalDebt, 0);
        assertLe(m.liquidity, hook.maxLiquidity());

        address newcomer = makeAddr("newcomer");
        uint256 bought = _buy(coin, newcomer, 100 * ONE_USDC);
        m = _market(coin);
        uint256 real = lens.getCoinData(address(coin), address(0)).realQuote;
        assertLe(m.idleQuote + m.pendingHeal, (real + m.idleQuote) / 999 + 2, "quote stranded outside the position");
        assertGt(_sell(coin, newcomer, bought), 95 * ONE_USDC, "the market no longer works");
    }

    /// @notice The coins backing a debt depend only on the floor and the supply, so nothing other
    ///         traders or donors do can make a borrower's lock grow past their balance.
    /// @dev Found by the invariant suite at 100,000 calls: an earlier version let fees smaller than a
    ///      tick thicken the position at an unchanged floor, which made the same debt need more coins.
    function testFuzz_borrow_lockNeverGrows(uint256[12] memory amounts) public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, 50_000 * ONE_USDC);
        _borrow(coin, alice, hook.creditOf(address(coin), alice));
        uint256 locked = hook.lockedOf(address(coin), alice);
        assertLe(locked, coin.balanceOf(alice));

        for (uint256 i; i < amounts.length; ++i) {
            uint256 kind = amounts[i] % 3;
            if (kind == 0) {
                _buy(coin, bob, bound(amounts[i], ONE_USDC / 100, 20_000 * ONE_USDC));
            } else if (kind == 1 && coin.balanceOf(bob) != 0) {
                _sell(coin, bob, (coin.balanceOf(bob) * (1 + (amounts[i] % 100))) / 100);
            } else {
                _heal(coin, bob, bound(amounts[i], 1, 1000 * ONE_USDC));
            }
            uint256 lockedNow = hook.lockedOf(address(coin), alice);
            // re-creating the position rounds its liquidity, which moves a lock by parts in 1e15
            assertLe(lockedNow, locked + locked / 1e15 + 1e6, "the lock grew");
            if (lockedNow < locked) locked = lockedNow;
        }
        assertLe(hook.lockedOf(address(coin), alice), coin.balanceOf(alice) + coin.balanceOf(alice) / 1e15 + 1e6);
    }

    /// @notice Re-creating a position with nothing to apply puts back what was there: the price moves
    ///         by rounding only.
    function testFuzz_rebalance_withNothingPending_keepsThePrice(uint256 buyIn, uint256 borrowBps) public {
        buyIn = bound(buyIn, 100 * ONE_USDC, 1_000_000 * ONE_USDC);
        borrowBps = bound(borrowBps, 1, 9900);
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, buyIn);
        // a first loan applies whatever the last trade left pending
        _borrow(coin, alice, 1);

        uint160 price = hook.sqrtPriceX96(address(coin));
        uint256 amount = (hook.creditOf(address(coin), alice) * borrowBps) / 10_000;
        vm.assume(amount != 0);
        _borrow(coin, alice, amount);
        assertApproxEqRel(hook.sqrtPriceX96(address(coin)), price, 1e9, "borrow moved the price");

        price = hook.sqrtPriceX96(address(coin));
        _repay(coin, alice, amount + 1);
        assertApproxEqRel(hook.sqrtPriceX96(address(coin)), price, 1e9, "repay moved the price");
        assertEq(_market(coin).lowerTick, _market(coin).floorTick);
    }

    function testFuzz_ratchet_floorNeverFallsAndStaysOnATick(uint256[10] memory amounts) public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        int24 floorTick = _market(coin).floorTick;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 balance = coin.balanceOf(alice);
            if (amounts[i] % 2 == 0 || balance == 0) {
                _buy(coin, alice, bound(amounts[i], ONE_USDC, 100_000 * ONE_USDC));
            } else {
                _sell(coin, alice, (balance * (1 + (amounts[i] % 100))) / 100);
            }

            IWavefrontHook.Market memory m = _market(coin);
            assertGe(m.floorTick, floorTick, "floor never falls");
            assertEq(m.floorTick % TICK_SPACING, 0);
            assertEq(m.sqrtFloorX96, TickMath.getSqrtPriceAtTick(m.floorTick));
            assertGe(hook.sqrtPriceX96(address(coin)), m.sqrtFloorX96, "price never below the floor");
            floorTick = m.floorTick;
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  LENDING
    //////////////////////////////////////////////////////////////*/

    function test_borrow_creditMatchesV1_andQuoteLeavesThePool() public {
        (Coin coin, IV1Coin v1Coin) = _launchBoth(1000 * ONE_USDC);
        _buy(coin, alice, 50_000 * ONE_USDC);
        _v1Buy(v1Coin, alice, 50_000 * ONE_USDC);

        // v4 credit is v1's less a fixed margin of one tick-spacing of coins, here about 0.2%
        uint256 credit = hook.creditOf(address(coin), alice);
        assertApproxEqRel(credit, v1Coin.getAccountCredit(alice), 2 * PARITY, "credit");
        assertLe(credit, (v1Coin.getAccountCredit(alice) * (1e18 + PARITY)) / 1e18);

        uint256 amount = (credit * 99) / 100;
        uint256 poolQuote = quote.balanceOf(address(manager));
        uint160 price = hook.sqrtPriceX96(address(coin));
        int24 lowerBefore = _market(coin).lowerTick;

        _borrow(coin, alice, amount);

        assertEq(quote.balanceOf(alice), amount, "borrower received the quote");
        assertEq(poolQuote - quote.balanceOf(address(manager)), amount, "and it left the PoolManager");
        // the position is re-created from its reserves, which v4 rounds by a raw unit
        assertApproxEqRel(hook.sqrtPriceX96(address(coin)), price, 1e9, "price did not move");
        assertGt(_market(coin).lowerTick, lowerBefore, "position's lower tick moved up");
        assertEq(hook.debtOf(address(coin), alice), amount);
        assertEq(_market(coin).totalDebt, amount);
    }

    function test_borrow_locksCollateral() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, 50_000 * ONE_USDC);
        _borrow(coin, alice, (hook.creditOf(address(coin), alice) * 99) / 100);

        uint256 balance = coin.balanceOf(alice);
        uint256 locked = hook.lockedOf(address(coin), alice);
        assertGt(locked, 0);
        assertLe(locked, balance);

        vm.startPrank(alice);
        vm.expectRevert(Coin.CollateralLocked.selector);
        coin.transfer(bob, balance);
        coin.approve(address(router), balance);
        vm.expectRevert();
        router.sell(address(coin), balance, 0, 0);
        coin.approve(address(hook), balance);
        vm.expectRevert(Coin.CollateralLocked.selector);
        hook.burn(address(coin), balance);
        // the unlocked remainder still moves
        coin.transfer(bob, balance - locked);
        vm.stopPrank();
        assertEq(coin.balanceOf(bob), balance - locked);
    }

    function test_borrow_revertsPastTheCreditLimit() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, 50_000 * ONE_USDC);
        uint256 credit = hook.creditOf(address(coin), alice);

        vm.startPrank(alice);
        vm.expectRevert();
        hook.borrow(address(coin), (credit * 102) / 100, alice);
        vm.expectRevert(IWavefrontHook.ZeroAmount.selector);
        hook.borrow(address(coin), 0, alice);
        vm.stopPrank();

        // someone with no coins has no credit
        vm.prank(bob);
        vm.expectRevert();
        hook.borrow(address(coin), ONE_USDC, bob);
    }

    function test_repay_unlocksAndRestoresThePosition() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, 50_000 * ONE_USDC);
        uint256 amount = (hook.creditOf(address(coin), alice) * 99) / 100;
        _borrow(coin, alice, amount);

        _repay(coin, alice, amount);

        IWavefrontHook.Market memory m = _market(coin);
        assertEq(m.totalDebt, 0);
        assertEq(m.lowerTick, m.floorTick);
        assertEq(hook.lockedOf(address(coin), alice), 0);
        uint256 balance = coin.balanceOf(alice);
        vm.prank(alice);
        coin.transfer(bob, balance);
        assertEq(coin.balanceOf(bob), balance);
    }

    function test_repay_anyoneCanRepayForAnAccount() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, 50_000 * ONE_USDC);
        uint256 amount = hook.creditOf(address(coin), alice) / 2;
        _borrow(coin, alice, amount);

        quote.mint(bob, amount);
        vm.startPrank(bob);
        quote.approve(address(hook), amount);
        hook.repay(address(coin), alice, amount);
        vm.stopPrank();
        assertEq(hook.debtOf(address(coin), alice), 0);
    }

    /// @notice The property that makes zero-interest, no-liquidation lending safe: with a loan open,
    ///         every other holder can still sell everything, and afterwards the loan unwinds cleanly.
    function testFuzz_solvency_everyoneElseExitsWhileLoanIsOpen(uint256 aliceIn, uint256 bobIn, uint256 borrowBps)
        public
    {
        aliceIn = bound(aliceIn, 20_000 * ONE_USDC, 500_000 * ONE_USDC);
        bobIn = bound(bobIn, 100 * ONE_USDC, 500_000 * ONE_USDC);
        borrowBps = bound(borrowBps, 1000, 9800);
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, aliceIn);
        _buy(coin, bob, bobIn);

        uint256 amount = (hook.creditOf(address(coin), alice) * borrowBps) / 10_000;
        _borrow(coin, alice, amount);

        // every non-borrower sells out completely
        _sell(coin, bob, coin.balanceOf(bob));
        _sell(coin, creator, coin.balanceOf(creator));
        assertEq(coin.balanceOf(bob), 0);
        assertEq(coin.balanceOf(creator), 0);

        IWavefrontHook.Market memory m = _market(coin);
        assertGt(m.liquidity, 0, "pool is still live");
        assertGe(hook.sqrtPriceX96(address(coin)), m.sqrtFloorX96, "price is at or above the floor");

        // the borrower repays and exits too
        _repay(coin, alice, amount);
        _sell(coin, alice, coin.balanceOf(alice));
        assertEq(coin.balanceOf(alice), 0);

        m = _market(coin);
        assertEq(m.totalDebt, 0);
        assertEq(m.lowerTick, m.floorTick);
        // the hook's claims are exactly what it accounts for
        assertEq(
            _claims(address(quote)),
            m.idleQuote + m.pendingHeal + hook.feesOwed(address(quote), creator)
                + hook.feesOwed(address(quote), treasury)
        );
    }

    function test_lending_twoBorrowersAtOnce() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        _buy(coin, alice, 20_000 * ONE_USDC);
        _buy(coin, bob, 10_000 * ONE_USDC);

        uint256 aliceDebt = (hook.creditOf(address(coin), alice) * 98) / 100;
        _borrow(coin, alice, aliceDebt);
        uint256 bobDebt = (hook.creditOf(address(coin), bob) * 98) / 100;
        _borrow(coin, bob, bobDebt);

        assertEq(_market(coin).totalDebt, aliceDebt + bobDebt);
        assertLe(hook.lockedOf(address(coin), alice), coin.balanceOf(alice));
        assertLe(hook.lockedOf(address(coin), bob), coin.balanceOf(bob));

        // a third party trades through both loans
        uint256 bought = _buy(coin, creator, 5000 * ONE_USDC);
        _sell(coin, creator, bought);

        _repay(coin, alice, aliceDebt);
        _repay(coin, bob, bobDebt);
        _sell(coin, alice, coin.balanceOf(alice));
        _sell(coin, bob, coin.balanceOf(bob));
        assertEq(_market(coin).totalDebt, 0);
    }

    /// @notice Markets are isolated: activity and debt in one coin never touch another coin's quote.
    function test_markets_areIsolated() public {
        (Coin first,) = _launch(creator, 1000 * ONE_USDC);
        (Coin second,) = _launch(creator, 1000 * ONE_USDC);
        _buy(first, alice, 50_000 * ONE_USDC);
        IWavefrontHook.Market memory before = _market(second);
        uint160 price = hook.sqrtPriceX96(address(second));

        _borrow(first, alice, (hook.creditOf(address(first), alice) * 95) / 100);
        _sell(first, creator, first.balanceOf(creator));

        IWavefrontHook.Market memory m = _market(second);
        assertEq(m.liquidity, before.liquidity);
        assertEq(m.lowerTick, before.lowerTick);
        assertEq(m.idleQuote, before.idleQuote);
        assertEq(m.pendingHeal, before.pendingHeal);
        assertEq(hook.sqrtPriceX96(address(second)), price);
        // and the second coin's only holder can still exit in full
        _sell(second, creator, second.balanceOf(creator));
        assertEq(second.balanceOf(creator), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_setTreasury_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setTreasury(alice);
    }

    function test_unknownCoin_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(IWavefrontHook.UnknownCoin.selector);
        hook.borrow(address(quote), ONE_USDC, alice);
        vm.expectRevert(IWavefrontHook.UnknownCoin.selector);
        hook.heal(address(quote), ONE_USDC);
        vm.stopPrank();
    }

    function test_coin_onlyTheHookCanBurn() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        vm.prank(creator);
        vm.expectRevert(Coin.OnlyHook.selector);
        coin.burn(1);
    }

    function test_unlockCallback_onlyThePoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_lens_getCoinData() public {
        (Coin coin,) = _launch(creator, 1000 * ONE_USDC);
        WavefrontLens.CoinData memory data = lens.getCoinData(address(coin), creator);

        assertEq(data.index, 1);
        assertEq(data.coin, address(coin));
        assertEq(data.quote, address(quote));
        assertEq(data.name, "Wave");
        assertEq(data.uri, "ipfs://wave");
        assertEq(data.owner, creator);
        assertEq(data.team, creator);
        assertGt(data.marketPrice, data.floorPrice);
        assertEq(data.accountCoinBalance, coin.balanceOf(creator));
        assertEq(data.accountTransferable, data.accountCoinBalance);
        assertGt(data.accountCredit, 0);
        assertGt(data.realQuote, 0);
    }
}

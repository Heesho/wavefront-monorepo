// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {USDC} from "./mocks/USDC.sol";
import {Coin} from "../src/Coin.sol";
import {Core} from "../src/Core.sol";
import {Router} from "../src/Router.sol";
import {Multicall} from "../src/Multicall.sol";

contract WavefrontTest is Test {
    USDC internal usdc;
    Core internal core;
    Router internal router;
    Multicall internal multicall;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal affiliate = makeAddr("affiliate");

    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant MILLION_USDC = 1_000_000 * ONE_USDC;

    function setUp() public {
        usdc = new USDC();

        for (uint256 i = 0; i < 6; i++) {
            address signer = [owner, creator, alice, bob, affiliate, treasury][i];
            usdc.mint(signer, MILLION_USDC);
        }

        vm.startPrank(owner);
        core = new Core(address(usdc));
        router = new Router(address(core));
        multicall = new Multicall(address(core));
        core.setTreasury(treasury);
        vm.stopPrank();
    }

    function _createCoin(address asCreator, uint256 initialUSDC) internal returns (Coin coin) {
        vm.startPrank(asCreator);
        usdc.approve(address(router), initialUSDC);
        address coinAddr = router.createCoin("Wave", "WAVE", initialUSDC);
        vm.stopPrank();
        return Coin(coinAddr);
    }

    function test_createCoin_registersInCore() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);
        assertEq(core.index(), 1);
        assertEq(core.index_Coin(1), address(coin));
        assertEq(core.coin_Index(address(coin)), 1);
    }

    function test_createCoin_retainsOneCoinInCore_andForwardsRest() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);
        assertEq(coin.balanceOf(address(core)), 1e18);
        assertGt(coin.balanceOf(creator), 0);
    }

    function test_createCoin_setsOwnerAndInitialTeam() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);
        assertEq(coin.owner(), creator);
        assertEq(coin.team(), creator);
    }

    function test_buy_splitsFees_provider_team_treasury_heal() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);

        uint256 buyAmt = 1000 * ONE_USDC;
        uint256 feePool = (buyAmt * 100) / 10_000; // 1% of trade
        uint256 perRecipient = (feePool * 2_000) / 10_000; // 20% of fee pool

        uint256 teamBefore = usdc.balanceOf(creator);
        uint256 affiliateBefore = usdc.balanceOf(affiliate);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 virtBefore = coin.reserveVirtQuoteWad();

        vm.startPrank(alice);
        usdc.approve(address(coin), buyAmt);
        coin.buy(buyAmt, 0, 0, alice, affiliate);
        vm.stopPrank();

        assertEq(usdc.balanceOf(creator) - teamBefore, perRecipient);
        assertEq(usdc.balanceOf(affiliate) - affiliateBefore, perRecipient);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, perRecipient);
        assertGt(coin.reserveVirtQuoteWad(), virtBefore);
    }

    function test_buy_revertsOnMinTradeSize() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);

        vm.startPrank(alice);
        usdc.approve(address(coin), 999);
        vm.expectRevert(Coin.Coin__MinTradeSize.selector);
        coin.buy(999, 0, 0, alice, address(0));
        vm.stopPrank();
    }

    function test_buy_revertsAfterDeadline() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);

        // Warp forward so block.timestamp - 1 is non-zero (deadline=0 means "no expiry")
        vm.warp(100);

        vm.startPrank(alice);
        usdc.approve(address(coin), 100 * ONE_USDC);
        vm.expectRevert(Coin.Coin__Expired.selector);
        coin.buy(100 * ONE_USDC, 0, block.timestamp - 1, alice, address(0));
        vm.stopPrank();
    }

    function test_sell_burnsCoinsAndTransfersQuote() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);

        vm.startPrank(alice);
        usdc.approve(address(coin), 1000 * ONE_USDC);
        coin.buy(1000 * ONE_USDC, 0, 0, alice, address(0));
        uint256 coinBalance = coin.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        coin.sell(coinBalance, 0, 0, alice, address(0));
        vm.stopPrank();

        assertEq(coin.balanceOf(alice), 0);
        assertGt(usdc.balanceOf(alice), usdcBefore);
    }

    function test_borrow_lockCollateral_repay_unlocks() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);

        vm.startPrank(alice);
        usdc.approve(address(coin), 1000 * ONE_USDC);
        coin.buy(1000 * ONE_USDC, 0, 0, alice, address(0));

        uint256 credit = coin.getAccountCredit(alice);
        coin.borrow(alice, credit);
        assertEq(coin.account_DebtRaw(alice), credit);

        uint256 fullBalance = coin.balanceOf(alice);
        vm.expectRevert(Coin.Coin__CollateralLocked.selector);
        coin.transfer(bob, fullBalance);

        usdc.approve(address(coin), credit);
        coin.repay(alice, credit);
        assertEq(coin.account_DebtRaw(alice), 0);
        coin.transfer(bob, fullBalance);
        vm.stopPrank();

        assertEq(coin.balanceOf(bob), fullBalance);
    }

    function test_heal_shiftsReserves() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);

        uint256 realBefore = coin.reserveRealQuoteWad();
        uint256 virtBefore = coin.reserveVirtQuoteWad();

        vm.startPrank(alice);
        usdc.approve(address(coin), 100 * ONE_USDC);
        coin.heal(100 * ONE_USDC);
        vm.stopPrank();

        assertGt(coin.reserveRealQuoteWad(), realBefore);
        assertGt(coin.reserveVirtQuoteWad(), virtBefore);
    }

    function test_burn_shiftsReserves() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);

        vm.startPrank(alice);
        usdc.approve(address(coin), 1000 * ONE_USDC);
        coin.buy(1000 * ONE_USDC, 0, 0, alice, address(0));

        uint256 balance = coin.balanceOf(alice);
        uint256 maxBefore = coin.maxSupply();
        coin.burn(balance / 2);
        vm.stopPrank();

        assertLt(coin.maxSupply(), maxBefore);
        assertEq(coin.balanceOf(alice), balance - balance / 2);
    }

    function test_setTeam_zeroAddress_routesToHeal() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);
        vm.prank(creator);
        coin.setTeam(address(0));
        assertEq(coin.team(), address(0));

        // With team zero, the team-fee branch is skipped on buy and the
        // share goes to heal instead. Virt reserves should still grow.
        uint256 virtBefore = coin.reserveVirtQuoteWad();

        vm.startPrank(alice);
        usdc.approve(address(coin), 1000 * ONE_USDC);
        coin.buy(1000 * ONE_USDC, 0, 0, alice, address(0));
        vm.stopPrank();

        assertGt(coin.reserveVirtQuoteWad(), virtBefore);
    }

    function test_setTeam_revertsForNonOwner() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);
        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        coin.setTeam(bob);
    }

    function test_setTeam_routesFeesToNewTeam() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);
        vm.prank(creator);
        coin.setTeam(bob);

        uint256 buyAmt = 1000 * ONE_USDC;
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.startPrank(alice);
        usdc.approve(address(coin), buyAmt);
        coin.buy(buyAmt, 0, 0, alice, address(0));
        vm.stopPrank();

        uint256 feePool = (buyAmt * 100) / 10_000;
        uint256 perRecipient = (feePool * 2_000) / 10_000;
        assertEq(usdc.balanceOf(bob) - bobBefore, perRecipient);
    }

    function test_router_buy_routesAffiliateFromMapping() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);

        // First buy seeds affiliate
        vm.startPrank(alice);
        usdc.approve(address(router), 10 * ONE_USDC);
        router.buy(address(coin), affiliate, 10 * ONE_USDC, 0, 0);
        vm.stopPrank();

        assertEq(router.account_Affiliate(alice), affiliate);

        // Second buy: explicit affiliate=0 but mapping should still pay affiliate
        uint256 affiliateBefore = usdc.balanceOf(affiliate);
        vm.startPrank(alice);
        usdc.approve(address(router), 1000 * ONE_USDC);
        router.buy(address(coin), address(0), 1000 * ONE_USDC, 0, 0);
        vm.stopPrank();

        uint256 feePool = (1000 * ONE_USDC * 100) / 10_000;
        uint256 perRecipient = (feePool * 2_000) / 10_000;
        assertEq(usdc.balanceOf(affiliate) - affiliateBefore, perRecipient);
    }

    function test_multicall_getCoinData() public {
        Coin coin = _createCoin(creator, 1000 * ONE_USDC);
        Multicall.CoinData memory data = multicall.getCoinData(address(coin), alice);

        assertEq(data.coin, address(coin));
        assertEq(data.quote, address(usdc));
        assertEq(data.team, creator);
        assertEq(data.owner, creator);
        assertEq(data.index, 1);
        assertGt(data.marketPrice, 0);
        assertGt(data.floorPrice, 0);
        assertEq(data.accountQuoteBalance, MILLION_USDC);
    }

    function test_core_setTreasury_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        core.setTreasury(alice);
    }

    function test_core_create_revertsOnInsufficientCoreAmt() public {
        vm.startPrank(creator);
        usdc.approve(address(core), 1000 * ONE_USDC);
        vm.expectRevert(Core.Core__InsufficientCoreAmtRequired.selector);
        core.create("Wave", "WAVE", creator, 1000 * ONE_USDC, 0);
        vm.stopPrank();
    }
}

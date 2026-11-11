// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Coin} from "../src/Coin.sol";
import {IWavefrontHook} from "../src/interfaces/IWavefrontHook.sol";
import {MockCallbackToken, MockFeeOnTransferToken, MockHookedToken, MockNoReturnToken} from "./mocks/MockOddTokens.sol";
import {WavefrontFixture} from "./utils/WavefrontFixture.sol";

/// @notice Quote tokens that do not behave like the textbook ERC20.
contract TokenShapesTest is WavefrontFixture {
    function setUp() public {
        _deployV4();
    }

    function _launchAgainst(address token) internal returns (Coin coin) {
        IWavefrontHook.LaunchParams memory params = _defaultParams(creator);
        params.quote = token;
        _mineSalt(creator, params);
        vm.prank(creator);
        (address coinAddress,) = router.launch(params, 0, 0);
        coin = Coin(coinAddress);
    }

    /// @notice A quote whose transfer functions return nothing (USDT on mainnet) works throughout:
    ///         trading, lending, donating and claiming fees.
    function test_noReturnQuote_worksEndToEnd() public {
        MockNoReturnToken token = new MockNoReturnToken();
        Coin coin = _launchAgainst(address(token));

        token.mint(alice, 60_000e6);
        vm.startPrank(alice);
        token.approve(address(router), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
        uint256 bought = router.buy(address(coin), 50_000e6, 0, 0);
        assertGt(bought, 0);

        uint256 credit = hook.creditOf(address(coin), alice);
        hook.borrow(address(coin), credit / 2, alice);
        assertEq(token.balanceOf(alice), 10_000e6 + credit / 2, "borrowed quote arrived");
        hook.repay(address(coin), alice, credit / 2);
        hook.heal(address(coin), 1000e6);

        coin.approve(address(router), bought);
        uint256 out = router.sell(address(coin), bought, 0, 0);
        assertGt(out, 45_000e6, "sold back for the money less fees");
        vm.stopPrank();

        uint256 owed = hook.feesOwed(address(token), creator);
        assertGt(owed, 0);
        hook.claimFees(address(token), creator);
        assertEq(token.balanceOf(creator), owed, "team fee paid out");
    }

    /// @notice A fee-on-transfer quote is not supported. It fails safely: a coin can be launched against
    ///         it, but an ordinary buy and a donation revert, so nothing can be lost or stuck.
    function test_feeOnTransferQuote_cannotBeTraded() public {
        MockFeeOnTransferToken token = new MockFeeOnTransferToken();
        Coin coin = _launchAgainst(address(token));

        token.mint(alice, 10_000e6);
        vm.startPrank(alice);
        token.approve(address(router), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
        vm.expectRevert();
        router.buy(address(coin), 1000e6, 0, 0);
        vm.expectRevert();
        hook.heal(address(coin), 1000e6);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 10_000e6, "nothing left alice's wallet");
        assertEq(IERC20(address(token)).balanceOf(address(manager)), 0);
        assertEq(coin.balanceOf(alice), 0);
    }

    /// @notice A quote token that calls the payer back mid-transfer (ERC-777 style) gives a borrower a
    ///         window inside their own repayment. In that window the market must still show the debt as
    ///         outstanding, so that nothing done there sees money that has not arrived, and the hook
    ///         itself cannot be re-entered.
    /// @dev Found while triaging Slither's reentrancy reports: `repay` used to write the debt down
    ///      before pulling the payment.
    function test_callbackQuote_repaymentWindowSeesConsistentState() public {
        MockCallbackToken token = new MockCallbackToken();
        Coin coin = _launchAgainst(address(token));
        ReentrantBorrower borrower = new ReentrantBorrower(hook, address(router), coin, token);
        token.mint(address(borrower), 50_000e6);
        borrower.buyAndBorrow(50_000e6);

        uint256 debt = hook.debtOf(address(coin), address(borrower));
        assertGt(debt, 0);
        borrower.repay(debt);

        assertTrue(borrower.called(), "the token called the payer back");
        assertEq(borrower.totalDebtSeen(), debt, "debt was written down before the payment arrived");
        assertEq(borrower.ownDebtSeen(), debt, "the account's debt was written down before the payment arrived");
        assertTrue(borrower.reentryBlocked(), "the hook could be re-entered mid-payment");
        assertEq(hook.debtOf(address(coin), address(borrower)), 0);
        assertEq(hook.market(address(coin)).totalDebt, 0);
    }

    /// @notice Someone determined can still buy with a fee-on-transfer quote, by sending the pool
    ///         enough extra to cover the token's cut, and can then borrow. What they cannot do is pay
    ///         the hook short: a repayment or donation that arrives lighter than it was written is
    ///         refused, so the market never counts quote it does not hold.
    /// @dev Found in review: the hook used to mint itself the full amount whatever arrived, and the
    ///      rebalance absorbed the difference, so a repayment of 1,000,000 was credited for 990,000.
    function test_feeOnTransferQuote_shortPaymentsAreRefused() public {
        MockFeeOnTransferToken token = new MockFeeOnTransferToken();
        Coin coin = _launchAgainst(address(token));
        GrossUpBuyer buyer = new GrossUpBuyer(manager);

        token.mint(alice, 200_000e6);
        vm.startPrank(alice);
        token.approve(address(buyer), type(uint256).max);
        token.approve(address(hook), type(uint256).max);
        buyer.buy(hook.poolKey(address(coin)), 100_000e6);
        assertGt(coin.balanceOf(alice), 0, "bought by covering the token's cut");
        hook.borrow(address(coin), hook.creditOf(address(coin), alice) / 2, alice);
        uint256 debt = hook.debtOf(address(coin), alice);
        IWavefrontHook.Market memory before = hook.market(address(coin));

        vm.expectRevert(IWavefrontHook.PaymentNotReceived.selector);
        hook.repay(address(coin), alice, 1e6);
        vm.expectRevert(IWavefrontHook.PaymentNotReceived.selector);
        hook.repay(address(coin), alice, debt);
        vm.expectRevert(IWavefrontHook.PaymentNotReceived.selector);
        hook.heal(address(coin), 50_000e6);
        vm.stopPrank();

        assertEq(hook.debtOf(address(coin), alice), debt, "debt untouched");
        IWavefrontHook.Market memory m = hook.market(address(coin));
        assertEq(m.totalDebt, before.totalDebt);
        assertEq(m.idleQuote, before.idleQuote);
        assertEq(m.pendingHeal, before.pendingHeal);
    }

    /// @notice While the hook collects a payment the PoolManager is unlocked, and open to anyone. A
    ///         quote token that calls the payer back mid-transfer lets them reach it: before their
    ///         balance moves they can clear the PoolManager's note of what is being paid; after it
    ///         moves they can claim the payment as their own and take it back out. Either way the
    ///         hook must see that it was not credited and refuse.
    /// @dev Found in review: the debt used to be written down regardless. With a callback after the
    ///      move that was a repayment for free; with one before it, the payment was stranded in the
    ///      PoolManager and the market lost it.
    function test_callbackQuote_payerCannotTakeTheirPaymentBack() public {
        _payerCannotInterceptTheirPayment(true);
    }

    function test_callbackQuote_payerCannotStrandTheirPayment() public {
        _payerCannotInterceptTheirPayment(false);
    }

    function _payerCannotInterceptTheirPayment(bool afterMove) internal {
        MockHookedToken token = new MockHookedToken(afterMove);
        Coin coin = _launchAgainst(address(token));

        // an honest holder whose quote backs the market
        token.mint(alice, 100_000e6);
        vm.startPrank(alice);
        token.approve(address(router), type(uint256).max);
        router.buy(address(coin), 100_000e6, 0, 0);
        vm.stopPrank();

        SettleInterceptor thief = new SettleInterceptor(hook, manager, address(router), coin, token);
        token.mint(address(thief), 50_000e6);
        thief.buyAndBorrow(50_000e6);
        uint256 debt = hook.debtOf(address(coin), address(thief));
        uint256 balance = token.balanceOf(address(thief));
        uint256 held = token.balanceOf(address(manager));
        IWavefrontHook.Market memory before = hook.market(address(coin));

        // small enough to fit inside one tick, where the rebalance used to hide the shortfall
        vm.expectRevert(IWavefrontHook.PaymentNotReceived.selector);
        thief.repay(1e6);
        vm.expectRevert(IWavefrontHook.PaymentNotReceived.selector);
        thief.repay(debt);
        vm.expectRevert(IWavefrontHook.PaymentNotReceived.selector);
        thief.heal(1e6);

        assertEq(hook.debtOf(address(coin), address(thief)), debt, "debt was written down");
        assertEq(token.balanceOf(address(thief)), balance, "the payer's balance changed");
        assertEq(token.balanceOf(address(manager)), held, "quote was stranded in the PoolManager");
        IWavefrontHook.Market memory m = hook.market(address(coin));
        assertEq(m.totalDebt, before.totalDebt);
        assertEq(m.idleQuote, before.idleQuote);

        // an honest repayment in the same token still works
        thief.disarm();
        thief.repay(debt);
        assertEq(hook.debtOf(address(coin), address(thief)), 0);
        assertEq(hook.market(address(coin)).totalDebt, 0);
    }
}

/// @dev Buys with a fee-on-transfer quote by sending the pool enough extra to cover the token's cut.
contract GrossUpBuyer is IUnlockCallback {
    IPoolManager internal immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function buy(PoolKey memory key, uint256 quoteIn) external {
        manager.unlock(abi.encode(msg.sender, key, quoteIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address payer, PoolKey memory key, uint256 quoteIn) = abi.decode(data, (address, PoolKey, uint256));
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(quoteIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 owed = uint256(uint128(-delta.amount1()));
        manager.sync(key.currency1);
        MockFeeOnTransferToken(Currency.unwrap(key.currency1))
            .transferFrom(payer, address(manager), owed * 100 / 99 + 2);
        uint256 paid = manager.settle();
        if (paid > owed) manager.take(key.currency1, payer, paid - owed);
        manager.take(key.currency0, payer, uint256(uint128(delta.amount0())));
        return "";
    }
}

/// @dev A payer that, from inside the transfer of its own payment, settles with the PoolManager itself
///      and takes out whatever it is credited.
contract SettleInterceptor {
    IWavefrontHook internal immutable hook;
    IPoolManager internal immutable manager;
    address internal immutable router;
    Coin internal immutable coin;
    MockHookedToken internal immutable token;
    bool internal armed = true;
    bool internal paying;

    constructor(IWavefrontHook hook_, IPoolManager manager_, address router_, Coin coin_, MockHookedToken token_) {
        hook = hook_;
        manager = manager_;
        router = router_;
        coin = coin_;
        token = token_;
        token_.approve(router_, type(uint256).max);
        token_.approve(address(hook_), type(uint256).max);
    }

    function buyAndBorrow(uint256 quoteIn) external {
        (bool ok,) =
            router.call(abi.encodeWithSignature("buy(address,uint256,uint256,uint256)", address(coin), quoteIn, 0, 0));
        require(ok, "buy failed");
        hook.borrow(address(coin), hook.creditOf(address(coin), address(this)) / 2, address(this));
    }

    function disarm() external {
        armed = false;
    }

    function repay(uint256 amount) external {
        paying = true;
        hook.repay(address(coin), address(this), amount);
        paying = false;
    }

    function heal(uint256 amount) external {
        paying = true;
        hook.heal(address(coin), amount);
        paying = false;
    }

    function onTransfer() external {
        if (!armed || !paying) return;
        uint256 paid = manager.settle();
        if (paid != 0) manager.take(Currency.wrap(address(token)), address(this), paid);
    }
}

/// @dev A borrower contract that looks at the market, and tries to re-enter the hook, from inside the
///      transfer that pays its own debt.
contract ReentrantBorrower {
    IWavefrontHook internal immutable hook;
    address internal immutable router;
    Coin internal immutable coin;
    MockCallbackToken internal immutable token;

    bool internal armed;
    bool public called;
    bool public reentryBlocked;
    uint256 public totalDebtSeen;
    uint256 public ownDebtSeen;

    constructor(IWavefrontHook hook_, address router_, Coin coin_, MockCallbackToken token_) {
        hook = hook_;
        router = router_;
        coin = coin_;
        token = token_;
        token_.approve(router_, type(uint256).max);
        token_.approve(address(hook_), type(uint256).max);
    }

    function buyAndBorrow(uint256 quoteIn) external {
        (bool ok,) =
            router.call(abi.encodeWithSignature("buy(address,uint256,uint256,uint256)", address(coin), quoteIn, 0, 0));
        require(ok, "buy failed");
        hook.borrow(address(coin), hook.creditOf(address(coin), address(this)) / 2, address(this));
    }

    function repay(uint256 amount) external {
        armed = true;
        hook.repay(address(coin), address(this), amount);
        armed = false;
    }

    function onTokensToSend() external {
        if (!armed) return;
        called = true;
        totalDebtSeen = hook.market(address(coin)).totalDebt;
        ownDebtSeen = hook.debtOf(address(coin), address(this));
        try hook.heal(address(coin), 1) {}
        catch {
            reentryBlocked = true;
        }
    }
}

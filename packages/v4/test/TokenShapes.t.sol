// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Coin} from "../src/Coin.sol";
import {IWavefrontHook} from "../src/interfaces/IWavefrontHook.sol";
import {MockCallbackToken, MockFeeOnTransferToken, MockNoReturnToken} from "./mocks/MockOddTokens.sol";
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
    ///         it, but every action that would move the token reverts, so nothing can be lost or stuck.
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

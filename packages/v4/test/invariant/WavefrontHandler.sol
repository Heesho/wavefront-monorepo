// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

import {Coin} from "../../src/Coin.sol";
import {WavefrontHook} from "../../src/WavefrontHook.sol";
import {WavefrontRouter} from "../../src/WavefrontRouter.sol";
import {IWavefrontHook} from "../../src/interfaces/IWavefrontHook.sol";
import {MockQuote} from "../mocks/MockQuote.sol";

/// @notice Drives random user actions against the v4 system for the invariant suite.
/// @dev Inputs are bounded to what a real user could attempt; calls that can legitimately revert (for
///      example borrowing the last sliver of credit) are wrapped so the run continues, and counted.
contract WavefrontHandler is Test {
    WavefrontHook public immutable hook;
    WavefrontRouter public immutable router;
    address public immutable hookOwner;
    address public immutable treasury;

    Coin[] public coins;
    address[] public actors;

    /// @notice Set if any action ever lowered a coin's floor.
    bool public floorFell;
    /// @notice Set if a holder with no debt was ever unable to sell coins the pool should absorb.
    bool public sellFailed;
    mapping(bytes32 action => uint256) public calls;
    mapping(bytes32 action => uint256) public reverts;

    constructor(
        WavefrontHook hook_,
        WavefrontRouter router_,
        address hookOwner_,
        address treasury_,
        Coin[] memory coins_,
        address[] memory actors_
    ) {
        hook = hook_;
        router = router_;
        hookOwner = hookOwner_;
        treasury = treasury_;
        coins = coins_;
        actors = actors_;
    }

    function coinCount() external view returns (uint256) {
        return coins.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    /*//////////////////////////////////////////////////////////////
                                  ACTIONS
    //////////////////////////////////////////////////////////////*/

    function buy(uint256 actorSeed, uint256 coinSeed, uint256 amount) external {
        (address actor, Coin coin, MockQuote quote, int24 floorBefore) = _pick("buy", actorSeed, coinSeed);
        uint256 unit = 10 ** quote.decimals();
        amount = bound(amount, unit / 100, _maxBuy(quote, unit));

        quote.mint(actor, amount);
        vm.startPrank(actor);
        quote.approve(address(router), amount);
        router.buy(address(coin), amount, 0, 0);
        vm.stopPrank();
        _after(coin, floorBefore);
    }

    function sell(uint256 actorSeed, uint256 coinSeed, uint256 bps) external {
        (address actor, Coin coin,, int24 floorBefore) = _pick("sell", actorSeed, coinSeed);
        uint256 amount = (_transferable(coin, actor) * bound(bps, 1, 10_000)) / 10_000;
        if (amount == 0) return;
        bool hasDebt = hook.debtOf(address(coin), actor) != 0;

        vm.startPrank(actor);
        coin.approve(address(router), amount);
        try router.sell(address(coin), amount, 0, 0) {}
        catch {
            _revert("sell");
            // A borrower's lock can move by a tick's worth of coins when the sale itself re-creates the
            // position, so their "max" sale may legitimately fail. Nobody without debt should ever fail.
            if (!hasDebt) sellFailed = true;
        }
        vm.stopPrank();
        _after(coin, floorBefore);
    }

    function borrow(uint256 actorSeed, uint256 coinSeed, uint256 bps) external {
        (address actor, Coin coin,, int24 floorBefore) = _pick("borrow", actorSeed, coinSeed);
        uint256 amount = (hook.creditOf(address(coin), actor) * bound(bps, 1, 9999)) / 10_000;
        if (amount == 0) return;

        vm.prank(actor);
        try hook.borrow(address(coin), amount, actor) {}
        catch {
            _revert("borrow");
        }
        _after(coin, floorBefore);
    }

    function repay(uint256 actorSeed, uint256 coinSeed, uint256 bps) external {
        (address actor, Coin coin, MockQuote quote, int24 floorBefore) = _pick("repay", actorSeed, coinSeed);
        uint256 amount = (hook.debtOf(address(coin), actor) * bound(bps, 1, 10_000)) / 10_000;
        if (amount == 0) return;

        quote.mint(actor, amount);
        vm.startPrank(actor);
        quote.approve(address(hook), amount);
        hook.repay(address(coin), actor, amount);
        vm.stopPrank();
        _after(coin, floorBefore);
    }

    function heal(uint256 actorSeed, uint256 coinSeed, uint256 amount) external {
        (address actor, Coin coin, MockQuote quote, int24 floorBefore) = _pick("heal", actorSeed, coinSeed);
        uint256 unit = 10 ** quote.decimals();
        amount = bound(amount, 1, _maxBuy(quote, unit) / 10);

        quote.mint(actor, amount);
        vm.startPrank(actor);
        quote.approve(address(hook), amount);
        hook.heal(address(coin), amount);
        vm.stopPrank();
        _after(coin, floorBefore);
    }

    function burn(uint256 actorSeed, uint256 coinSeed, uint256 bps) external {
        (address actor, Coin coin,, int24 floorBefore) = _pick("burn", actorSeed, coinSeed);
        uint256 amount = (_transferable(coin, actor) * bound(bps, 1, 10_000)) / 10_000;
        if (amount == 0) return;

        vm.startPrank(actor);
        coin.approve(address(hook), amount);
        try hook.burn(address(coin), amount) {}
        catch {
            _revert("burn");
        }
        vm.stopPrank();
        _after(coin, floorBefore);
    }

    function transfer(uint256 actorSeed, uint256 toSeed, uint256 coinSeed, uint256 bps) external {
        (address actor, Coin coin,, int24 floorBefore) = _pick("transfer", actorSeed, coinSeed);
        address to = actors[toSeed % actors.length];
        uint256 amount = (_transferable(coin, actor) * bound(bps, 1, 10_000)) / 10_000;
        if (amount == 0 || to == actor) return;

        vm.prank(actor);
        coin.transfer(to, amount);
        _after(coin, floorBefore);
    }

    function claimFees(uint256 coinSeed, bool quoteSide, bool forTreasury) external {
        Coin coin = coins[coinSeed % coins.length];
        calls["claimFees"]++;
        address token = quoteSide ? hook.market(address(coin)).quote : address(coin);
        address recipient = forTreasury ? treasury : coin.owner();
        hook.claimFees(token, recipient);
    }

    /// @notice The coin's owner turns the team fee off or back on.
    function toggleTeam(uint256 coinSeed) external {
        Coin coin = coins[coinSeed % coins.length];
        calls["toggleTeam"]++;
        address coinOwner = coin.owner();
        address newTeam = coin.team() == address(0) ? coinOwner : address(0);
        vm.prank(coinOwner);
        coin.setTeam(newTeam);
    }

    /// @notice The protocol owner turns the treasury fee off or back on.
    function toggleTreasury() external {
        calls["toggleTreasury"]++;
        address newTreasury = hook.treasury() == address(0) ? treasury : address(0);
        vm.prank(hookOwner);
        hook.setTreasury(newTreasury);
    }

    /*//////////////////////////////////////////////////////////////
                                  HELPERS
    //////////////////////////////////////////////////////////////*/

    function _pick(bytes32 action, uint256 actorSeed, uint256 coinSeed)
        internal
        returns (address actor, Coin coin, MockQuote quote, int24 floorBefore)
    {
        calls[action]++;
        actor = actors[actorSeed % actors.length];
        coin = coins[coinSeed % coins.length];
        IWavefrontHook.Market memory m = hook.market(address(coin));
        quote = MockQuote(m.quote);
        floorBefore = m.floorTick;
    }

    function _after(Coin coin, int24 floorBefore) internal {
        if (hook.market(address(coin)).floorTick < floorBefore) floorFell = true;
    }

    function _revert(bytes32 action) internal {
        reverts[action]++;
    }

    function _transferable(Coin coin, address actor) internal view returns (uint256) {
        uint256 balance = coin.balanceOf(actor);
        uint256 locked = hook.lockedOf(address(coin), actor);
        return balance > locked ? balance - locked : 0;
    }

    /// @dev Up to 500,000 units of a 6-decimal quote, or 200 units of an 18-decimal one.
    function _maxBuy(MockQuote quote, uint256 unit) internal view returns (uint256) {
        return IERC20Metadata(address(quote)).decimals() == 18 ? 200 * unit : 500_000 * unit;
    }
}

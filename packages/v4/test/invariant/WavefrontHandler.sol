// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Test} from "forge-std/Test.sol";

import {Coin} from "../../src/Coin.sol";
import {WavefrontHook} from "../../src/WavefrontHook.sol";
import {WavefrontRouter} from "../../src/WavefrontRouter.sol";
import {IWavefrontHook} from "../../src/interfaces/IWavefrontHook.sol";
import {MockQuote} from "../mocks/MockQuote.sol";

/// @notice Drives random user actions against the v4 system for the invariant suite.
/// @dev Inputs are bounded to what a real user could attempt. Actions that must never fail (buying,
///      repaying, donating, claiming, launching within the documented bounds) record a failure instead
///      of reverting, so the suite can assert that none happened. Calls that can legitimately revert
///      (for example borrowing the last sliver of credit) are wrapped so the run continues, and counted.
contract WavefrontHandler is Test {
    /// @dev Coins a run may hold in total when it launches its own.
    uint256 internal constant MAX_COINS = 5;

    WavefrontHook public immutable hook;
    WavefrontRouter public immutable router;
    address public immutable hookOwner;
    address public immutable treasury;
    /// @dev Owner and team of every coin, as in the fixture.
    address public immutable launcher;

    Coin[] public coins;
    address[] public actors;
    /// @dev Quote tokens a run may launch new coins against; empty if it launches none.
    MockQuote[] public launchQuotes;

    /// @notice Supply each coin was launched with.
    mapping(address coin => uint256) public launchSupply;
    /// @dev Virtual quote each coin was launched with; trade sizes are scaled to it.
    mapping(address coin => uint256) internal _virtualQuote;

    /// @notice Set if any action ever lowered a coin's floor.
    bool public floorFell;
    /// @notice Set if a holder with no debt was ever unable to sell coins the pool should absorb.
    bool public sellFailed;
    /// @notice First action that reverted although it never should; empty if none did.
    bytes32 public failedAction;
    mapping(bytes32 action => uint256) public calls;
    mapping(bytes32 action => uint256) public reverts;

    constructor(
        WavefrontHook hook_,
        WavefrontRouter router_,
        address hookOwner_,
        address treasury_,
        address launcher_,
        Coin[] memory coins_,
        address[] memory actors_,
        MockQuote[] memory launchQuotes_
    ) {
        hook = hook_;
        router = router_;
        hookOwner = hookOwner_;
        treasury = treasury_;
        launcher = launcher_;
        actors = actors_;
        launchQuotes = launchQuotes_;
        for (uint256 i; i < coins_.length; ++i) {
            _register(coins_[i]);
        }
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

    /// @notice Launches a new coin with a random supply, curve depth and fee against a random quote token.
    function launch(uint256 quoteSeed, uint256 supplySeed, uint256 virtualSeed, uint256 feeSeed, uint256 saltSeed)
        external
    {
        if (launchQuotes.length == 0 || coins.length >= MAX_COINS) return;
        calls["launch"]++;
        MockQuote quote = launchQuotes[quoteSeed % launchQuotes.length];
        IWavefrontHook.LaunchParams memory params = IWavefrontHook.LaunchParams({
            name: "Fuzz",
            symbol: "FUZZ",
            uri: "",
            quote: address(quote),
            owner: launcher,
            team: launcher,
            // every combination below is inside the hook's launch bounds
            supply: _logUniform(supplySeed, 21, 33),
            virtualQuote: _logUniform(virtualSeed, 6, 30),
            fee: uint24(bound(feeSeed, 10_000, 50_000)),
            salt: bytes32(0)
        });
        // The coin must sort below its quote; try salts the way a front end would. A salt is never
        // reused: the same creator launching the same coin twice with one salt collides, by design.
        for (uint256 i; i < 256; ++i) {
            params.salt = keccak256(abi.encode(saltSeed, coins.length, i));
            if (router.predictCoin(launcher, params) < address(quote)) break;
        }
        if (router.predictCoin(launcher, params) >= address(quote)) return;

        vm.prank(launcher);
        try router.launch(params, 0, 0) returns (address coin, uint256) {
            _register(Coin(coin));
        } catch {
            _fail("launch");
        }
    }

    function buy(uint256 actorSeed, uint256 coinSeed, uint256 amount) external {
        (address actor, Coin coin, MockQuote quote, int24 floorBefore) = _pick("buy", actorSeed, coinSeed);
        amount = bound(amount, _minBuy(coin), _maxBuy(coin));

        quote.mint(actor, amount);
        vm.startPrank(actor);
        quote.approve(address(router), amount);
        try router.buy(address(coin), amount, 0, 0) {}
        catch {
            _fail("buy");
        }
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
        try hook.repay(address(coin), actor, amount) {}
        catch {
            _fail("repay");
        }
        vm.stopPrank();
        _after(coin, floorBefore);
    }

    function heal(uint256 actorSeed, uint256 coinSeed, uint256 amount) external {
        (address actor, Coin coin, MockQuote quote, int24 floorBefore) = _pick("heal", actorSeed, coinSeed);
        amount = bound(amount, 1, _maxBuy(coin) / 10);

        quote.mint(actor, amount);
        vm.startPrank(actor);
        quote.approve(address(hook), amount);
        try hook.heal(address(coin), amount) {}
        catch {
            _fail("heal");
        }
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

        bool hasDebt = hook.debtOf(address(coin), actor) != 0;
        vm.prank(actor);
        try coin.transfer(to, amount) {}
        catch {
            // as with selling, only a borrower's "max" can legitimately fail
            _revert("transfer");
            if (!hasDebt) _fail("transfer");
        }
        _after(coin, floorBefore);
    }

    function claimFees(uint256 coinSeed, bool quoteSide, bool forTreasury) external {
        Coin coin = coins[coinSeed % coins.length];
        calls["claimFees"]++;
        address token = quoteSide ? hook.market(address(coin)).quote : address(coin);
        address recipient = forTreasury ? treasury : coin.owner();
        try hook.claimFees(token, recipient) {}
        catch {
            _fail("claimFees");
        }
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

    /// @dev Trades are sized to the coin's curve: from a ten-millionth of its virtual quote...
    function _minBuy(Coin coin) internal view returns (uint256 amount) {
        amount = _virtualQuote[address(coin)] / 1e7;
        if (amount == 0) amount = 1;
    }

    /// @dev ...to ten times it, which multiplies the price more than a hundredfold.
    function _maxBuy(Coin coin) internal view returns (uint256) {
        return _virtualQuote[address(coin)] * 10;
    }

    function _register(Coin coin) internal {
        coins.push(coin);
        launchSupply[address(coin)] = coin.totalSupply();
        // virtual quote = liquidity * floor, straight after launch
        IWavefrontHook.Market memory m = hook.market(address(coin));
        _virtualQuote[address(coin)] = FullMath.mulDiv(m.liquidity, m.sqrtFloorX96, 1 << 96);
    }

    function _fail(bytes32 action) internal {
        reverts[action]++;
        if (failedAction == bytes32(0)) failedAction = action;
    }

    /// @dev A value between 10^minExp and 10^maxExp, evenly spread across orders of magnitude.
    function _logUniform(uint256 seed, uint256 minExp, uint256 maxExp) internal pure returns (uint256 value) {
        uint256 magnitude = 10 ** (minExp + (seed % (maxExp - minExp)));
        value = magnitude * (1 + ((seed >> 64) % 9)) + ((seed >> 128) % magnitude);
    }
}

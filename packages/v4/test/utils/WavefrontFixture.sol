// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {Coin} from "../../src/Coin.sol";
import {CoinDeployer} from "../../src/CoinDeployer.sol";
import {WavefrontHook} from "../../src/WavefrontHook.sol";
import {WavefrontLens} from "../../src/WavefrontLens.sol";
import {WavefrontRouter} from "../../src/WavefrontRouter.sol";
import {IWavefrontHook} from "../../src/interfaces/IWavefrontHook.sol";
import {MockQuote} from "../mocks/MockQuote.sol";
import {IV1Coin, V1Fixture} from "../reference/V1.sol";

/// @notice Deploys the v4 system the way production would (mined hook address, CREATE2) next to v1.
abstract contract WavefrontFixture is V1Fixture {
    int24 internal constant TICK_SPACING = 10;
    /// @dev v1's launch constants, so that v4 coins launched with the defaults are comparable to v1 coins.
    uint256 internal constant VIRTUAL_QUOTE = 100_000e6;
    uint256 internal constant COIN_SUPPLY = 1_000_000_000e18;

    /// @dev v4 keeps the floor on a tick and moves it in whole steps of TICK_SPACING ticks (0.1% of
    ///      price), where v1 moves it continuously. The two therefore agree to within a step for the
    ///      launch rounding plus a step for heal or burn still pending. Forge's scale: 1e18 = 100%.
    uint256 internal constant PARITY = 2.5e15;

    PoolManager internal manager;
    MockQuote internal quote;
    CoinDeployer internal coinDeployer;
    WavefrontHook internal hook;
    WavefrontRouter internal router;
    WavefrontLens internal lens;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 private _saltNonce;

    function _deployV4() internal {
        manager = new PoolManager(owner);
        quote = new MockQuote("USD Coin", "USDC", 6);
        coinDeployer = new CoinDeployer();

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(IPoolManager(manager), coinDeployer, TICK_SPACING, owner);
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, type(WavefrontHook).creationCode, args);
        hook = new WavefrontHook{salt: salt}(manager, coinDeployer, TICK_SPACING, owner);
        assertEq(address(hook), expected, "hook address was not the mined one");

        router = new WavefrontRouter(manager, hook);
        lens = new WavefrontLens(hook);

        vm.prank(owner);
        hook.setTreasury(treasury);
    }

    /// @dev Launch parameters matching v1's constants, owned by `launcher`. The salt is left unset.
    function _defaultParams(address launcher) internal view returns (IWavefrontHook.LaunchParams memory) {
        return IWavefrontHook.LaunchParams({
            name: "Wave",
            symbol: "WAVE",
            uri: "ipfs://wave",
            quote: address(quote),
            owner: launcher,
            team: launcher,
            supply: COIN_SUPPLY,
            virtualQuote: VIRTUAL_QUOTE,
            salt: bytes32(0)
        });
    }

    /// @dev Sets a salt whose coin sorts below the quote token, the way a front end would find one.
    function _mineSalt(address launcher, IWavefrontHook.LaunchParams memory params) internal {
        while (true) {
            params.salt = bytes32(_saltNonce++);
            if (router.predictCoin(launcher, params) < params.quote) return;
        }
    }

    function _launchWith(address launcher, IWavefrontHook.LaunchParams memory params, uint256 quoteIn)
        internal
        returns (Coin coin, uint256 coinOut)
    {
        _mineSalt(launcher, params);
        MockQuote(params.quote).mint(launcher, quoteIn);
        vm.startPrank(launcher);
        IERC20(params.quote).approve(address(router), quoteIn);
        address coinAddress;
        (coinAddress, coinOut) = router.launch(params, quoteIn, 0);
        vm.stopPrank();
        coin = Coin(coinAddress);
    }

    /// @dev Launches a coin with v1's constants and a first buy of `quoteIn` by `launcher`.
    function _launch(address launcher, uint256 quoteIn) internal returns (Coin coin, uint256 coinOut) {
        return _launchWith(launcher, _defaultParams(launcher), quoteIn);
    }

    function _quoteOf(Coin coin) internal view returns (MockQuote) {
        return MockQuote(hook.market(address(coin)).quote);
    }

    function _buy(Coin coin, address buyer, uint256 quoteIn) internal returns (uint256 coinOut) {
        MockQuote token = _quoteOf(coin);
        token.mint(buyer, quoteIn);
        vm.startPrank(buyer);
        token.approve(address(router), quoteIn);
        coinOut = router.buy(address(coin), quoteIn, 0, 0);
        vm.stopPrank();
    }

    function _sell(Coin coin, address seller, uint256 coinIn) internal returns (uint256 quoteOut) {
        vm.startPrank(seller);
        coin.approve(address(router), coinIn);
        quoteOut = router.sell(address(coin), coinIn, 0, 0);
        vm.stopPrank();
    }

    function _borrow(Coin coin, address account, uint256 amount) internal {
        vm.prank(account);
        hook.borrow(address(coin), amount, account);
    }

    function _repay(Coin coin, address account, uint256 amount) internal {
        MockQuote token = _quoteOf(coin);
        vm.startPrank(account);
        token.approve(address(hook), amount);
        hook.repay(address(coin), account, amount);
        vm.stopPrank();
    }

    function _heal(Coin coin, address from, uint256 amount) internal {
        MockQuote token = _quoteOf(coin);
        token.mint(from, amount);
        vm.startPrank(from);
        token.approve(address(hook), amount);
        hook.heal(address(coin), amount);
        vm.stopPrank();
    }

    function _burn(Coin coin, address from, uint256 amount) internal {
        vm.startPrank(from);
        coin.approve(address(hook), amount);
        hook.burn(address(coin), amount);
        vm.stopPrank();
    }

    function _market(Coin coin) internal view returns (IWavefrontHook.Market memory) {
        return hook.market(address(coin));
    }

    /// @dev Market price, floor price and supply agree between the v4 coin and the v1 coin.
    function _assertParity(Coin coin, IV1Coin v1Coin, string memory label) internal view {
        WavefrontLens.CoinData memory data = lens.getCoinData(address(coin), address(0));
        assertApproxEqRel(data.marketPrice, v1Coin.getMarketPrice(), PARITY, string.concat(label, ": market price"));
        assertApproxEqRel(data.floorPrice, v1Coin.getFloorPrice(), PARITY, string.concat(label, ": floor price"));
        assertApproxEqRel(data.supply, v1Coin.maxSupply(), PARITY, string.concat(label, ": supply"));
    }

    /// @dev `token` the PoolManager holds on the hook's behalf as claims.
    function _claims(address token) internal view returns (uint256) {
        return manager.balanceOf(address(hook), uint256(uint160(token)));
    }
}

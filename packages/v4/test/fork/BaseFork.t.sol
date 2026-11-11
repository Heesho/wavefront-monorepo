// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Test} from "forge-std/Test.sol";

import {Coin} from "../../src/Coin.sol";
import {CoinDeployer} from "../../src/CoinDeployer.sol";
import {WavefrontHook} from "../../src/WavefrontHook.sol";
import {WavefrontLens} from "../../src/WavefrontLens.sol";
import {WavefrontRouter} from "../../src/WavefrontRouter.sol";
import {IWavefrontHook} from "../../src/interfaces/IWavefrontHook.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @notice Wavefront against the Uniswap contracts that are live on Base: the real PoolManager, the real
///         USDC, Uniswap's own Quoter and Uniswap's own Universal Router. None of them know anything
///         about wavefront, which is the point: a wavefront coin must trade through them unmodified.
/// @dev Skipped unless BASE_RPC_URL is set:
///        BASE_RPC_URL=https://mainnet.base.org forge test --match-contract BaseForkTest
contract BaseForkTest is Test {
    IPoolManager internal constant MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IUniversalRouter internal constant UNIVERSAL_ROUTER = IUniversalRouter(0x6fF5693b99212Da76ad316178A184AB56D299b43);
    IV4Quoter internal constant QUOTER = IV4Quoter(0xE1A6C5803e3c44368b171BD680c7D32dfc92CA47);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @dev Universal Router command for a v4 swap.
    uint8 internal constant V4_SWAP = 0x10;
    int24 internal constant TICK_SPACING = 10;
    uint256 internal constant ONE_USDC = 1e6;

    WavefrontHook internal hook;
    WavefrontRouter internal router;
    WavefrontLens internal lens;
    Coin internal coin;
    PoolKey internal key;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        // the live periphery really is wired to this PoolManager
        assertEq(address(QUOTER.poolManager()), address(MANAGER));

        CoinDeployer coinDeployer = new CoinDeployer();
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(MANAGER, coinDeployer, TICK_SPACING, owner);
        (address expected, bytes32 salt) = HookMiner.find(address(this), flags, type(WavefrontHook).creationCode, args);
        hook = new WavefrontHook{salt: salt}(MANAGER, coinDeployer, TICK_SPACING, owner);
        assertEq(address(hook), expected);
        router = new WavefrontRouter(MANAGER, hook);
        lens = new WavefrontLens(hook);
        vm.prank(owner);
        hook.setTreasury(treasury);

        // launch against real USDC, with the creator buying first through wavefront's own router
        IWavefrontHook.LaunchParams memory params = IWavefrontHook.LaunchParams({
            name: "Wave",
            symbol: "WAVE",
            uri: "ipfs://wave",
            quote: address(USDC),
            owner: creator,
            team: creator,
            supply: 1_000_000_000e18,
            virtualQuote: 100_000 * ONE_USDC,
            fee: 20_000,
            salt: bytes32(0)
        });
        for (uint256 i;; ++i) {
            params.salt = bytes32(i);
            if (router.predictCoin(creator, params) < address(USDC)) break;
        }
        deal(address(USDC), creator, 1000 * ONE_USDC);
        vm.startPrank(creator);
        USDC.approve(address(router), 1000 * ONE_USDC);
        (address coinAddress,) = router.launch(params, 1000 * ONE_USDC, 0);
        vm.stopPrank();
        coin = Coin(coinAddress);
        key = hook.poolKey(coinAddress);
    }

    /// @dev An exact-input swap through Uniswap's Universal Router, paid via Permit2 like any Uniswap user.
    function _universalRouterSwap(address user, bool sellCoin, uint128 amountIn) internal returns (uint256 received) {
        (Currency currencyIn, Currency currencyOut) =
            sellCoin ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        IERC20 tokenOut = IERC20(Currency.unwrap(currencyOut));
        uint256 before = tokenOut.balanceOf(user);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key, zeroForOne: sellCoin, amountIn: amountIn, amountOutMinimum: 0, hookData: bytes("")
            })
        );
        params[1] = abi.encode(currencyIn, uint256(amountIn));
        params[2] = abi.encode(currencyOut, uint256(0));
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        vm.startPrank(user);
        IERC20(Currency.unwrap(currencyIn)).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(Currency.unwrap(currencyIn), address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);
        UNIVERSAL_ROUTER.execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 60);
        vm.stopPrank();

        received = tokenOut.balanceOf(user) - before;
    }

    function _quote(bool sellCoin, uint128 amountIn) internal returns (uint256 amountOut) {
        (amountOut,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: sellCoin, exactAmount: amountIn, hookData: ""})
        );
    }

    function test_fork_universalRouterBuysAtTheQuotersPrice() public {
        uint128 quoteIn = uint128(5000 * ONE_USDC);
        uint256 quoted = _quote(false, quoteIn);
        uint256 lensQuote = lens.quoteBuy(address(coin), quoteIn);
        uint256 teamBefore = hook.feesOwed(address(USDC), creator);

        deal(address(USDC), alice, quoteIn);
        uint256 bought = _universalRouterSwap(alice, false, quoteIn);

        assertEq(bought, quoted, "Uniswap's router delivered exactly what Uniswap's quoter promised");
        assertApproxEqRel(bought, lensQuote, 1e9, "and it agrees with wavefront's own lens");
        // the hook ran behind Uniswap's router: 2% fee, a fifth of it to the team
        assertApproxEqAbs(hook.feesOwed(address(USDC), creator) - teamBefore, 20 * ONE_USDC, 2);
    }

    function test_fork_universalRouterSellsAtTheQuotersPrice() public {
        deal(address(USDC), alice, 5000 * ONE_USDC);
        uint256 bought = _universalRouterSwap(alice, false, uint128(5000 * ONE_USDC));

        uint128 coinIn = uint128(bought / 2);
        uint256 quoted = _quote(true, coinIn);
        uint256 received = _universalRouterSwap(alice, true, coinIn);

        assertEq(received, quoted);
        assertGt(hook.feesOwed(address(coin), creator), 0, "sell fee accrued in coin");
    }

    function test_fork_floorRatchetsBehindUniswapsRouter() public {
        IWavefrontHook.Market memory before = hook.market(address(coin));
        deal(address(USDC), alice, 50_000 * ONE_USDC);
        _universalRouterSwap(alice, false, uint128(50_000 * ONE_USDC));

        IWavefrontHook.Market memory m = hook.market(address(coin));
        assertGt(m.floorTick, before.floorTick, "floor stepped up");
        assertGt(m.liquidity, before.liquidity, "and the curve deepened, as on v1");
    }

    function test_fork_soleHolderExitsThroughUniswapsRouter() public {
        // the creator is the only holder; they sell everything through Uniswap's router
        uint256 balance = coin.balanceOf(creator);
        uint256 received = _universalRouterSwap(creator, true, uint128(balance));
        assertEq(coin.balanceOf(creator), 0);
        assertGt(received, 900 * ONE_USDC, "most of the 1,000 USDC comes back after two 2% fees");
    }

    function test_fork_lendingWithRealUsdc() public {
        deal(address(USDC), alice, 50_000 * ONE_USDC);
        uint256 bought = _universalRouterSwap(alice, false, uint128(50_000 * ONE_USDC));

        uint256 debt = (hook.creditOf(address(coin), alice) * 95) / 100;
        vm.prank(alice);
        hook.borrow(address(coin), debt, alice);
        assertEq(USDC.balanceOf(alice), debt, "borrowed real USDC out of the live PoolManager");

        // collateral is locked even against Uniswap's router
        (Currency currencyIn,) = (key.currency0, key.currency1);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currencyIn)).approve(address(PERMIT2), type(uint256).max);
        PERMIT2.approve(address(coin), address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);
        vm.stopPrank();
        vm.expectRevert();
        this.externalSwap(alice, true, uint128(bought));

        // other holders exit through Uniswap's router while the loan is open
        _universalRouterSwap(creator, true, uint128(coin.balanceOf(creator)));
        assertEq(coin.balanceOf(creator), 0);

        vm.startPrank(alice);
        USDC.approve(address(hook), debt);
        hook.repay(address(coin), alice, debt);
        vm.stopPrank();
        _universalRouterSwap(alice, true, uint128(coin.balanceOf(alice)));
        assertEq(coin.balanceOf(alice), 0);

        // the team claims its fees in real USDC
        uint256 owed = hook.feesOwed(address(USDC), creator);
        uint256 creatorBefore = USDC.balanceOf(creator);
        hook.claimFees(address(USDC), creator);
        assertEq(USDC.balanceOf(creator) - creatorBefore, owed);
        assertGt(owed, 0);
    }

    /// @dev External wrapper so that `vm.expectRevert` applies to the whole router call.
    function externalSwap(address user, bool sellCoin, uint128 amountIn) external returns (uint256) {
        return _universalRouterSwap(user, sellCoin, amountIn);
    }
}

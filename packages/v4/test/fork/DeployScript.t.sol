// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Test} from "forge-std/Test.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {Launch} from "../../script/Launch.s.sol";
import {Coin} from "../../src/Coin.sol";
import {IWavefrontHook} from "../../src/interfaces/IWavefrontHook.sol";

/// @notice The deploy script, run on a fork of Base against the live PoolManager, produces a working
///         system. Named so that it runs with the other fork tests; skipped unless BASE_RPC_URL is set.
contract BaseForkTestDeployScript is Test {
    IPoolManager internal constant MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    IERC20 internal constant USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    address internal hookOwner = makeAddr("multisig");
    address internal creator = makeAddr("creator");

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
    }

    function test_fork_deployScriptProducesAWorkingSystem() public {
        Deploy.Deployment memory d = new Deploy().deploy(MANAGER, hookOwner, 10);

        // the mined address carries exactly the permissions the hook implements
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
        assertEq(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK, flags, "hook address permissions");
        assertEq(address(d.hook.poolManager()), address(MANAGER));
        assertEq(address(d.hook.coinDeployer()), address(d.coinDeployer));
        assertEq(d.hook.owner(), hookOwner);
        assertEq(d.hook.treasury(), address(0), "no treasury until the owner sets one");
        assertEq(address(d.router.hook()), address(d.hook));

        // launch against real USDC with a first buy, the way Launch.s.sol does, then sell back
        IWavefrontHook.LaunchParams memory params = IWavefrontHook.LaunchParams({
            name: "Wave",
            symbol: "WAVE",
            uri: "ipfs://wave",
            quote: address(USDC),
            owner: creator,
            team: creator,
            supply: 1_000_000_000e18,
            virtualQuote: 100_000e6,
            salt: bytes32(0)
        });
        params.salt = new Launch().findSalt(d.router, creator, params);
        deal(address(USDC), creator, 100e6);
        vm.startPrank(creator);
        USDC.approve(address(d.router), 100e6);
        (address coin, uint256 bought) = d.router.launch(params, 100e6, 0);
        assertGt(bought, 0);
        Coin(coin).approve(address(d.router), bought);
        assertGt(d.router.sell(coin, bought, 0, 0), 95e6);
        vm.stopPrank();
    }
}

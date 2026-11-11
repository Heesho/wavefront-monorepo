// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {CoinDeployer} from "../src/CoinDeployer.sol";
import {WavefrontHook} from "../src/WavefrontHook.sol";
import {WavefrontLens} from "../src/WavefrontLens.sol";
import {WavefrontRouter} from "../src/WavefrontRouter.sol";

/// @notice Deploys wavefront's v4 contracts: the coin deployer, the hook at a mined address, the router
///         and the lens.
/// @dev A v4 hook's permissions are encoded in the low bits of its address, so the hook is deployed
///      with CREATE2 through the canonical deterministic deployer, using a salt found by {HookMiner}.
///
///      Environment:
///        HOOK_OWNER    required  admin that may set the treasury; meant to be a multisig
///        POOL_MANAGER  optional  Uniswap v4 PoolManager; defaults to the live one on Base mainnet
///        TREASURY      optional  set as the treasury if the broadcaster is HOOK_OWNER
///        TICK_SPACING  optional  defaults to 10
///
///      Dry run (nothing is sent):
///        HOOK_OWNER=0x... forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL
///      For real, with a key held in Foundry's encrypted keystore (`cast wallet import`):
///        HOOK_OWNER=0x... forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --account <name> --broadcast
contract Deploy is Script {
    /// @dev The hook callbacks WavefrontHook implements; must match its getHookPermissions().
    uint160 internal constant HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_SWAP_FLAG);
    address internal constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    struct Deployment {
        CoinDeployer coinDeployer;
        WavefrontHook hook;
        WavefrontRouter router;
        WavefrontLens lens;
    }

    error PoolManagerRequired();
    error NotAPoolManager(address poolManager);
    error HookDeploymentFailed();

    function run() external returns (Deployment memory d) {
        address hookOwner = vm.envAddress("HOOK_OWNER");
        address poolManager = vm.envOr("POOL_MANAGER", block.chainid == BASE_CHAIN_ID ? BASE_POOL_MANAGER : address(0));
        address treasury = vm.envOr("TREASURY", address(0));
        int24 tickSpacing = int24(vm.envOr("TICK_SPACING", int256(10)));
        if (poolManager == address(0)) revert PoolManagerRequired();

        vm.startBroadcast();
        d = deploy(IPoolManager(poolManager), hookOwner, tickSpacing);
        if (treasury != address(0) && hookOwner == msg.sender) d.hook.setTreasury(treasury);
        vm.stopBroadcast();
        if (treasury != address(0) && hookOwner != msg.sender) {
            console2.log("NOTE: TREASURY was not set: only HOOK_OWNER can set it. Until it does,");
            console2.log("      the treasury's share of every fee goes to the coin's floor.");
        }

        console2.log("chain id        ", block.chainid);
        console2.log("PoolManager     ", poolManager);
        console2.log("CoinDeployer    ", address(d.coinDeployer));
        console2.log("WavefrontHook   ", address(d.hook));
        console2.log("WavefrontRouter ", address(d.router));
        console2.log("WavefrontLens   ", address(d.lens));
        console2.log("hook owner      ", hookOwner);
        console2.log("treasury        ", d.hook.treasury());

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _record(d, poolManager);
    }

    /// @notice Deploys everything from whoever is the current sender.
    /// @param poolManager The Uniswap v4 PoolManager the hook attaches to.
    /// @param hookOwner Admin of the hook.
    /// @param tickSpacing Tick spacing of every pool.
    function deploy(IPoolManager poolManager, address hookOwner, int24 tickSpacing)
        public
        returns (Deployment memory d)
    {
        if (address(poolManager).code.length == 0) {
            revert NotAPoolManager(address(poolManager));
        }
        d.coinDeployer = new CoinDeployer();

        bytes memory args = abi.encode(poolManager, d.coinDeployer, tickSpacing, hookOwner);
        (address hook, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, HOOK_FLAGS, type(WavefrontHook).creationCode, args);
        // the deterministic deployer takes `salt ++ initCode` and deploys with CREATE2
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, type(WavefrontHook).creationCode, args));
        if (!ok || hook.code.length == 0) revert HookDeploymentFailed();
        d.hook = WavefrontHook(hook);

        d.router = new WavefrontRouter(poolManager, d.hook);
        d.lens = new WavefrontLens(d.hook);
    }

    function _record(Deployment memory d, address poolManager) internal {
        string memory json = "deployment";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "poolManager", poolManager);
        vm.serializeAddress(json, "coinDeployer", address(d.coinDeployer));
        vm.serializeAddress(json, "hook", address(d.hook));
        vm.serializeAddress(json, "router", address(d.router));
        string memory out = vm.serializeAddress(json, "lens", address(d.lens));
        vm.writeJson(out, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}

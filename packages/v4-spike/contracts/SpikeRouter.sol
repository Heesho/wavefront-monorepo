// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
// Pulls PoolManager into the Hardhat build so tests can deploy the real one.
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

/// @notice Minimal exact-input swap router. Stands in for any third-party v4 router: it knows
///         nothing about wavefront and only talks to the PoolManager.
contract SpikeRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    struct Call {
        address payer;
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        bytes hookData;
    }

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function swapExactIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn, bytes calldata hookData)
        external
        returns (uint256 amountOut)
    {
        bytes memory res = manager.unlock(abi.encode(Call(msg.sender, key, zeroForOne, amountIn, hookData)));
        amountOut = abi.decode(res, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Call memory c = abi.decode(data, (Call));

        BalanceDelta delta = manager.swap(
            c.key,
            SwapParams({
                zeroForOne: c.zeroForOne,
                amountSpecified: -int256(c.amountIn),
                sqrtPriceLimitX96: c.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            c.hookData
        );

        (Currency inCur, Currency outCur) =
            c.zeroForOne ? (c.key.currency0, c.key.currency1) : (c.key.currency1, c.key.currency0);
        int128 inAmt = c.zeroForOne ? delta.amount0() : delta.amount1();
        int128 outAmt = c.zeroForOne ? delta.amount1() : delta.amount0();

        manager.sync(inCur);
        require(
            IERC20(Currency.unwrap(inCur)).transferFrom(c.payer, address(manager), uint256(uint128(-inAmt))),
            "pay failed"
        );
        manager.settle();
        manager.take(outCur, c.payer, uint256(uint128(outAmt)));

        return abi.encode(uint256(uint128(outAmt)));
    }
}

/// @notice Test helper: an outsider trying to add liquidity to a wavefront pool.
contract LiquidityProbe is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function tryAdd(PoolKey calldata key, int24 tickLower, int24 tickUpper) external {
        manager.unlock(abi.encode(key, tickLower, tickUpper));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper) = abi.decode(data, (PoolKey, int24, int24));
        manager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1e18, salt: 0}), ""
        );
        return "";
    }
}

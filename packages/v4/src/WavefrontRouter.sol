// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IWavefrontHook} from "./interfaces/IWavefrontHook.sol";

/// @title WavefrontRouter
/// @notice Convenience router for wavefront's own app: launch a coin with the creator's first buy in the
///         same transaction, and exact-input buys and sells with slippage and deadline protection.
/// @dev Wavefront pools are ordinary v4 pools, so any v4 router works; nothing in the protocol depends on
///      this contract. It holds no funds between calls.
contract WavefrontRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable poolManager;
    /// @notice The wavefront hook whose coins this router trades.
    IWavefrontHook public immutable hook;

    /// @notice Emitted on a buy, with the quote actually spent.
    event Bought(address indexed coin, address indexed account, uint256 quoteIn, uint256 coinOut);
    /// @notice Emitted on a sell, with the coins actually sold.
    event Sold(address indexed coin, address indexed account, uint256 coinIn, uint256 quoteOut);

    /// @notice Thrown when a trade is submitted after its deadline.
    error Expired();
    /// @notice Thrown when a trade returns less than the caller's minimum.
    error Slippage();
    /// @notice Thrown when the unlock callback is not called by the PoolManager.
    error NotPoolManager();

    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param hook_ The wavefront hook.
    constructor(IPoolManager poolManager_, IWavefrontHook hook_) {
        poolManager = poolManager_;
        hook = hook_;
    }

    /// @notice Launches a coin and, in the same transaction, makes the creator's first buy.
    /// @dev The coin's address depends on the caller of this function, so nobody can replay a pending
    ///      launch to take its address or buy ahead of its creator.
    /// @param params The launch choices; `params.owner` is usually the caller.
    /// @param quoteIn Quote the caller spends on the first buy; may be zero. Needs approval to this router.
    /// @param minCoinOut Minimum coins that buy must return.
    /// @return coin The new coin.
    /// @return coinOut Coins the caller received.
    function launch(IWavefrontHook.LaunchParams calldata params, uint256 quoteIn, uint256 minCoinOut)
        external
        returns (address coin, uint256 coinOut)
    {
        IWavefrontHook.LaunchParams memory bound = params;
        bound.salt = _salt(msg.sender, params.salt);
        coin = hook.launch(bound);
        if (quoteIn != 0) {
            uint256 paid;
            (paid, coinOut) = _swap(coin, false, quoteIn, minCoinOut, 0);
            emit Bought(coin, msg.sender, paid, coinOut);
        }
    }

    /// @notice Address {launch} would deploy to for `creator` with these parameters.
    /// @param creator The account that will call {launch}.
    /// @param params The launch choices.
    /// @return The coin's address. It must sort below `params.quote` for the launch to succeed.
    function predictCoin(address creator, IWavefrontHook.LaunchParams calldata params) external view returns (address) {
        IWavefrontHook.LaunchParams memory bound = params;
        bound.salt = _salt(creator, params.salt);
        return hook.predictCoin(address(this), bound);
    }

    /// @notice Buys `coin` with exactly `quoteIn` quote.
    /// @param coin Coin to buy.
    /// @param quoteIn Quote to spend; the caller must have approved this router.
    /// @param minCoinOut Minimum coins to receive.
    /// @param deadline Latest timestamp the trade may execute at; zero for no deadline.
    /// @return coinOut Coins received.
    function buy(address coin, uint256 quoteIn, uint256 minCoinOut, uint256 deadline)
        external
        returns (uint256 coinOut)
    {
        uint256 paid;
        (paid, coinOut) = _swap(coin, false, quoteIn, minCoinOut, deadline);
        emit Bought(coin, msg.sender, paid, coinOut);
    }

    /// @notice Sells exactly `coinIn` of `coin` for quote.
    /// @param coin Coin to sell.
    /// @param coinIn Coins to sell; the caller must have approved this router.
    /// @param minQuoteOut Minimum quote to receive.
    /// @param deadline Latest timestamp the trade may execute at; zero for no deadline.
    /// @return quoteOut Quote received.
    function sell(address coin, uint256 coinIn, uint256 minQuoteOut, uint256 deadline)
        external
        returns (uint256 quoteOut)
    {
        uint256 paid;
        (paid, quoteOut) = _swap(coin, true, coinIn, minQuoteOut, deadline);
        emit Sold(coin, msg.sender, paid, quoteOut);
    }

    /// @notice Executes the swap inside the PoolManager's unlock.
    /// @param data ABI-encoded `(payer, coin, zeroForOne, amountIn)`.
    /// @return ABI-encoded `(paid, received)`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (address payer, address coin, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (address, address, bool, uint256));

        PoolKey memory key = hook.poolKey(coin);
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        (Currency currencyIn, Currency currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        // only what the pool actually consumed is charged, so a sell that exhausts the range fills partially
        uint256 paid = uint256(uint128(-(zeroForOne ? delta.amount0() : delta.amount1())));
        uint256 received = uint256(uint128(zeroForOne ? delta.amount1() : delta.amount0()));

        poolManager.sync(currencyIn);
        // `payer` is always the caller of the buy or sell that started this unlock
        // slither-disable-next-line arbitrary-send-erc20
        IERC20(Currency.unwrap(currencyIn)).safeTransferFrom(payer, address(poolManager), paid);
        poolManager.settle();
        poolManager.take(currencyOut, payer, received);

        return abi.encode(paid, received);
    }

    /// @dev A trade the pool cannot fill completely is charged only for the part it filled.
    /// @return paid Input the pool consumed, at most `amountIn`.
    /// @return amountOut Output received.
    function _swap(address coin, bool zeroForOne, uint256 amountIn, uint256 minOut, uint256 deadline)
        internal
        returns (uint256 paid, uint256 amountOut)
    {
        if (deadline != 0 && block.timestamp > deadline) revert Expired();
        (paid, amountOut) =
            abi.decode(poolManager.unlock(abi.encode(msg.sender, coin, zeroForOne, amountIn)), (uint256, uint256));
        if (amountOut < minOut) revert Slippage();
    }

    /// @dev Binds a launch salt to its creator.
    function _salt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }
}

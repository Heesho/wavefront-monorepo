// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @title TickRounding
/// @notice Rounds sqrt prices to usable ticks.
library TickRounding {
    /// @notice Smallest tick that is a multiple of `tickSpacing` and whose sqrt price is at least `sqrtPriceX96`.
    /// @dev Rounding the position's lower bound up means the pool never promises liquidity it cannot back.
    function ceil(uint160 sqrtPriceX96, int24 tickSpacing) internal pure returns (int24 tick) {
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        if (TickMath.getSqrtPriceAtTick(tick) < sqrtPriceX96) ++tick;
        int24 remainder = tick % tickSpacing;
        if (remainder > 0) {
            tick += tickSpacing - remainder;
        } else if (remainder < 0) {
            tick -= remainder;
        }
    }

    /// @notice Largest tick that is a multiple of `tickSpacing` and whose sqrt price is at most `sqrtPriceX96`.
    function floor(uint160 sqrtPriceX96, int24 tickSpacing) internal pure returns (int24 tick) {
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int24 remainder = tick % tickSpacing;
        if (remainder > 0) {
            tick -= remainder;
        } else if (remainder < 0) {
            tick -= tickSpacing + remainder;
        }
    }
}

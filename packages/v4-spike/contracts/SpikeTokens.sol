// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ICollateralLock {
    function lockedOf(address coin, address account) external view returns (uint256);
}

/// @notice Spike coin: whole supply minted to the hook at launch. Keeps wavefront's rule that coins
///         backing debt cannot be moved; the locked amount is asked from the hook.
contract SpikeCoin is ERC20 {
    address public immutable hook;

    error CollateralLocked();

    constructor(uint256 supply) ERC20("Spike Coin", "SPIKE") {
        hook = msg.sender;
        _mint(msg.sender, supply);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function _beforeTokenTransfer(address from, address, uint256 amount) internal view override {
        if (from == address(0)) return;
        uint256 locked = ICollateralLock(hook).lockedOf(address(this), from);
        if (locked > 0 && balanceOf(from) < amount + locked) revert CollateralLocked();
    }
}

/// @notice 6-decimal quote mock (stands in for USDC).
contract SpikeQuote is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

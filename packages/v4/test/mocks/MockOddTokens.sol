// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice A token whose `transfer`, `transferFrom` and `approve` return nothing, like mainnet USDT.
contract MockNoReturnToken {
    string public constant name = "No Return";
    string public constant symbol = "NORET";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice A token that keeps 1% of every transfer, so the recipient gets less than was sent.
contract MockFeeOnTransferToken is MockNoReturnToken {
    function _move(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}

/// @notice A token that calls the sender back before moving their balance, like ERC-777's `tokensToSend`.
contract MockCallbackToken is MockNoReturnToken {
    function _move(address from, address to, uint256 amount) internal override {
        if (from.code.length != 0) {
            (bool ok,) = from.call(abi.encodeWithSignature("onTokensToSend()"));
            ok;
        }
        super._move(from, to, amount);
    }
}

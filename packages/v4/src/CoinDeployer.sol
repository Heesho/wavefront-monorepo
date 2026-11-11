// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Coin} from "./Coin.sol";

/// @title CoinDeployer
/// @notice Deploys wavefront coins on behalf of a hook.
/// @dev Exists only to keep the coin's creation code out of the hook, which would otherwise exceed the
///      contract size limit. Anyone may call it: the caller becomes the new coin's hook and receives its
///      supply, and the caller's address is part of the CREATE2 address, so a foreign call can neither
///      mint real wavefront coins nor take an address a real launch would use.
contract CoinDeployer {
    /// @notice Constructor arguments of a coin, other than its hook.
    struct CoinParams {
        string name;
        string symbol;
        string uri;
        address owner;
        address team;
        uint256 supply;
    }

    /// @notice Deploys a coin whose hook is the caller.
    /// @param params The coin's constructor arguments.
    /// @param salt CREATE2 salt.
    /// @return coin The new coin.
    function deploy(CoinParams calldata params, bytes32 salt) external returns (address coin) {
        coin = address(
            new Coin{salt: salt}(
                params.name, params.symbol, params.uri, params.owner, params.team, msg.sender, params.supply
            )
        );
    }

    /// @notice Address {deploy} would return for a call from `hook` with these arguments.
    /// @param hook The caller of {deploy}.
    /// @param params The coin's constructor arguments.
    /// @param salt CREATE2 salt.
    /// @return The coin's address.
    function predict(address hook, CoinParams calldata params, bytes32 salt) external view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(Coin).creationCode,
                abi.encode(params.name, params.symbol, params.uri, params.owner, params.team, hook, params.supply)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}

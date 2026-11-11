// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

import {IWavefrontHook} from "./interfaces/IWavefrontHook.sol";

/// @title Coin
/// @notice A wavefront coin: ERC20 with permit and votes whose whole supply is minted to the hook at launch.
/// @dev The curve, fees and lending live in the hook. The coin keeps only what must sit on the token:
///      the collateral lock, the team address that receives the coin's fee share, and its owner.
contract Coin is ERC20, ERC20Permit, ERC20Votes, Ownable {
    /// @notice The wavefront hook that launched this coin.
    address public immutable hook;

    /// @notice Recipient of this coin's team fee share. Zero routes the share to heal / burn.
    address public team;

    /// @dev Metadata URI: a JSON document with the coin's image, description and links.
    string internal _contractURI;

    /// @notice Emitted when the team address changes.
    event TeamSet(address indexed newTeam);
    /// @notice Emitted when the metadata URI changes (ERC-7572).
    event ContractURIUpdated();

    /// @notice Thrown when a transfer would move coins that back the sender's debt.
    error CollateralLocked();
    /// @notice Thrown when anyone but the hook calls a hook-only function.
    error OnlyHook();

    /// @param name_ Coin name.
    /// @param symbol_ Coin symbol.
    /// @param uri_ Metadata URI.
    /// @param owner_ Initial owner.
    /// @param team_ Initial team fee recipient; may be zero.
    /// @param hook_ The wavefront hook; receives the whole supply.
    /// @param supply Total supply, minted once.
    constructor(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        address owner_,
        address team_,
        address hook_,
        uint256 supply
    ) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(owner_) {
        hook = hook_;
        team = team_;
        _contractURI = uri_;
        _mint(hook_, supply);
    }

    /// @notice Metadata URI of the coin (ERC-7572).
    /// @return The URI.
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Sets the metadata URI.
    /// @param newURI New URI.
    function setContractURI(string calldata newURI) external onlyOwner {
        _contractURI = newURI;
        emit ContractURIUpdated();
    }

    /// @notice Sets the team fee recipient.
    /// @param newTeam New recipient; zero routes the team's share to heal / burn.
    function setTeam(address newTeam) external onlyOwner {
        team = newTeam;
        emit TeamSet(newTeam);
    }

    /// @notice Burns `amount` of the hook's own coins. Supply only ever changes through the hook.
    /// @param amount Coins to burn.
    function burn(uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        _burn(msg.sender, amount);
    }

    /// @inheritdoc ERC20Permit
    function nonces(address account) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(account);
    }

    /// @dev Coins backing debt cannot leave the account, whether by transfer, sale or burn.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        if (from != address(0)) {
            uint256 locked = IWavefrontHook(hook).lockedOf(address(this), from);
            if (locked != 0 && balanceOf(from) < value + locked) revert CollateralLocked();
        }
        super._update(from, to, value);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ICore {
    function INITIAL_SUPPLY() external view returns (uint256);
    function RESERVE_VIRT_QUOTE_RAW() external view returns (uint256);
    function MINIMUM_CORE_AMT_REQUIRED() external view returns (uint256);

    function quote() external view returns (address);
    function treasury() external view returns (address);

    function index() external view returns (uint256);
    function index_Coin(uint256) external view returns (address);
    function coin_Index(address) external view returns (uint256);

    function create(
        string memory name,
        string memory symbol,
        address owner,
        uint256 quoteRawIn,
        uint256 coreCoinAmtRequired
    ) external returns (address coin);

    function setTreasury(address) external;
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface ICoin {
    function PRECISION() external view returns (uint256);
    function FEE() external view returns (uint256);
    function FEE_AMOUNT() external view returns (uint256);
    function DIVISOR() external view returns (uint256);
    function MIN_TRADE_SIZE() external view returns (uint256);

    function core() external view returns (address);
    function quote() external view returns (address);
    function team() external view returns (address);

    function maxSupply() external view returns (uint256);
    function reserveRealQuoteWad() external view returns (uint256);
    function reserveVirtQuoteWad() external view returns (uint256);
    function reserveCoinAmt() external view returns (uint256);

    function totalDebtRaw() external view returns (uint256);
    function account_DebtRaw(address) external view returns (uint256);

    function buy(uint256 quoteRawIn, uint256 minCoinAmtOut, uint256 deadline, address to, address provider) external returns (uint256 coinAmtOut);
    function sell(uint256 coinAmtIn, uint256 minQuoteRawOut, uint256 deadline, address to, address provider) external returns (uint256 quoteRawOut);
    function borrow(address to, uint256 quoteRaw) external;
    function repay(address to, uint256 quoteRaw) external;
    function heal(uint256 quoteRaw) external;
    function burn(uint256 coinAmt) external;
    function setTeam(address newTeam) external;

    function rawToWad(uint256 raw) external view returns (uint256);
    function wadToRaw(uint256 wad) external view returns (uint256);

    function getMarketPrice() external view returns (uint256 price);
    function getFloorPrice() external view returns (uint256 price);
    function getAccountCredit(address account) external view returns (uint256 creditRaw);
    function getAccountTransferrable(address account) external view returns (uint256 coinAmt);
}

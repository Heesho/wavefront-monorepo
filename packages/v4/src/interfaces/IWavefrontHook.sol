// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IWavefrontHook
/// @notice Launcher, curve manager and lender for wavefront coins on Uniswap v4.
interface IWavefrontHook {
    /// @notice State of one coin's market.
    /// @param quote The token this coin trades against.
    /// @param fee Trade fee of the coin's pool, in hundredths of a bip (20,000 is 2%). Fixed at launch.
    /// @param sqrtFloorX96 Floor sqrt price (quote per coin, Q64.96). Always exactly on `floorTick`.
    /// @param floorTick Tick of the floor: a multiple of the tick spacing that only ever moves up.
    /// @param lowerTick Lower tick of the live position. Above `floorTick` while quote is lent out.
    /// @param liquidity Liquidity of the live position.
    /// @param totalDebt Quote lent out against this coin.
    /// @param idleQuote Quote held for this market outside the position: what a raised lower tick freed and
    ///        nobody has borrowed, and what is not yet enough to lift the floor by a tick spacing.
    /// @param pendingHeal Quote waiting to join the curve's reserves. Applied, together with `pendingBurn`,
    ///        as soon as the two lift the floor by a tick spacing, and whenever a loan re-creates the position.
    /// @param pendingBurn Coins waiting to be burned out of circulation.
    /// @param burnQueue Coins already removed from the curve that are destroyed at the next action.
    /// @param index 1-based position in the coin registry; 0 if the coin was not launched here.
    struct Market {
        address quote;
        uint24 fee;
        uint160 sqrtFloorX96;
        int24 floorTick;
        int24 lowerTick;
        uint128 liquidity;
        uint256 totalDebt;
        uint256 idleQuote;
        uint256 pendingHeal;
        uint256 pendingBurn;
        uint256 burnQueue;
        uint256 index;
    }

    /// @notice Everything chosen at launch.
    /// @param name Coin name.
    /// @param symbol Coin symbol.
    /// @param uri Metadata URI (image, description, links); the coin's owner can change it later.
    /// @param quote Token the coin trades against. Any standard ERC20: no fee-on-transfer, no rebasing.
    /// @param owner Owner of the coin: may change its URI and team.
    /// @param team Recipient of the coin's team fee share; zero routes that share to heal / burn.
    /// @param supply Total supply of the coin, in raw units.
    /// @param virtualQuote Virtual quote reserve, in raw quote units. The launch price is
    ///        `virtualQuote / supply`, and the larger it is the more quote it takes to move the price.
    /// @param fee Fee charged on every trade of this coin, in hundredths of a bip: between 10,000 (1%)
    ///        and 50,000 (5%). It can never be changed. A fifth of it goes to the team, a fifth to the
    ///        treasury, and the rest raises the floor.
    /// @param salt Caller-chosen salt. The resulting coin address must sort below `quote`.
    struct LaunchParams {
        string name;
        string symbol;
        string uri;
        address quote;
        address owner;
        address team;
        uint256 supply;
        uint256 virtualQuote;
        uint24 fee;
        bytes32 salt;
    }

    /// @notice Emitted when a coin is launched.
    event Launched(
        address indexed coin,
        address indexed creator,
        address indexed quote,
        uint256 index,
        uint256 supply,
        uint256 virtualQuote,
        uint24 fee,
        string name,
        string symbol,
        string uri
    );
    /// @notice Emitted whenever a market's position is re-created.
    event Rebalanced(
        address indexed coin, uint160 sqrtPriceX96, uint160 sqrtFloorX96, int24 lowerTick, uint128 liquidity
    );
    /// @notice Emitted when a share of a trade fee is credited to a recipient.
    event FeeAccrued(address indexed coin, address indexed recipient, address indexed token, uint256 amount);
    /// @notice Emitted when accrued fees are paid out.
    event FeesClaimed(address indexed token, address indexed recipient, uint256 amount);
    /// @notice Emitted when quote is donated to a coin's curve.
    event Healed(address indexed coin, address indexed from, uint256 quoteAmount);
    /// @notice Emitted when coins are burned out of the circulating supply.
    event Burned(address indexed coin, address indexed from, uint256 coinAmount);
    /// @notice Emitted when an account borrows quote against its coins.
    event Borrowed(address indexed coin, address indexed account, address indexed to, uint256 quoteAmount);
    /// @notice Emitted when debt is repaid.
    event Repaid(address indexed coin, address indexed account, address indexed payer, uint256 quoteAmount);
    /// @notice Emitted when the protocol treasury changes.
    event TreasurySet(address indexed treasury);

    /// @notice Thrown when the mined coin address does not sort below the quote token.
    error CoinMustSortBelowQuote();
    /// @notice Thrown when a coin was not launched by this hook.
    error UnknownCoin();
    /// @notice Thrown when anyone but the hook tries to create a pool or add liquidity.
    error HookOwnedLiquidityOnly();
    /// @notice Thrown when a borrow would leave the account with fewer coins than it must lock.
    error CreditExceeded();
    /// @notice Thrown when the freed quote does not cover a borrow.
    error InsufficientIdleQuote();
    /// @notice Thrown when the PoolManager was not credited exactly the amount a payer was asked for.
    error PaymentNotReceived();
    /// @notice Thrown on a zero amount.
    error ZeroAmount();
    /// @notice Thrown when a launch's supply or virtual quote is outside the allowed bounds.
    error InvalidLaunchParams();

    /// @notice Deploys a coin and places its whole supply on the curve at the launch price.
    /// @dev The coin's address depends on the caller, so a launch cannot be front-run by replaying it.
    /// @param params The launch choices; see {LaunchParams}.
    /// @return coin The new coin.
    function launch(LaunchParams calldata params) external returns (address coin);

    /// @notice Borrows quote against the caller's coins at zero interest.
    function borrow(address coin, uint256 quoteAmount, address to) external;

    /// @notice Repays `account`'s debt with the caller's quote. An amount above the debt repays it in
    ///         full; the `Repaid` event carries what was actually paid.
    function repay(address coin, address account, uint256 quoteAmount) external;

    /// @notice Donates quote to a coin's curve. It raises the price and floor as soon as it is enough to
    ///         lift the floor by a tick spacing; until then it waits as `pendingHeal`.
    function heal(address coin, uint256 quoteAmount) external;

    /// @notice Gives up the caller's coins to be burned. It raises the price and floor as soon as it is
    ///         enough to lift the floor by a tick spacing; until then the coins wait as `pendingBurn`.
    ///         The caller must have approved the hook.
    function burn(address coin, uint256 coinAmount) external;

    /// @notice Pays `recipient` the fees it has accrued in `token`.
    function claimFees(address token, address recipient) external returns (uint256 amount);

    /// @notice Sets the protocol treasury. Zero routes the treasury's share to heal / burn.
    function setTreasury(address newTreasury) external;

    /// @notice Coins `account` cannot move while it has debt: the coins backing the debt plus a fixed
    ///         margin of one tick-spacing of coins at the floor. Zero when the account has no debt.
    function lockedOf(address coin, address account) external view returns (uint256);

    /// @notice Quote `account` can still borrow against its coins, after the tick margin.
    function creditOf(address coin, address account) external view returns (uint256);

    /// @notice Debt of `account` against `coin`.
    function debtOf(address coin, address account) external view returns (uint256);

    /// @notice Fees accrued to `recipient` in `token` and not yet claimed.
    function feesOwed(address token, address recipient) external view returns (uint256);

    /// @notice Market state of `coin`.
    function market(address coin) external view returns (Market memory);

    /// @notice Current pool sqrt price of `coin` (quote per coin, Q64.96).
    function sqrtPriceX96(address coin) external view returns (uint160);

    /// @notice Total supply of `coin` net of coins already removed from the curve and awaiting destruction.
    function effectiveSupply(address coin) external view returns (uint256);

    /// @notice The v4 pool key of `coin`.
    function poolKey(address coin) external view returns (PoolKey memory);

    /// @notice Number of coins launched.
    function coinCount() external view returns (uint256);

    /// @notice Coin at `index` (1-based, in launch order).
    function coinAt(uint256 index) external view returns (address);

    /// @notice Address a launch by `caller` with these parameters would deploy to.
    function predictCoin(address caller, LaunchParams calldata params) external view returns (address);
}

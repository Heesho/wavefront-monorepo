// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

import {Coin} from "./Coin.sol";
import {CoinDeployer} from "./CoinDeployer.sol";
import {IWavefrontHook} from "./interfaces/IWavefrontHook.sol";
import {CurveMath} from "./libraries/CurveMath.sol";
import {TickRounding} from "./libraries/TickRounding.sol";

/// @title WavefrontHook
/// @notice Wavefront's bonding curve, floor ratchet and zero-interest lending on Uniswap v4.
/// @dev Each coin trades in one v4 pool against the quote token chosen at launch. The pool's only
///      liquidity is a single position owned by this hook, from the coin's floor price to the top of the
///      tick range; that position is the wavefront curve (see {CurveMath}).
///
///      - Buys and sells are ordinary v4 swaps through any router, paying the pool's LP fee.
///      - After every swap the hook collects the fee and credits the team and treasury shares. The rest
///        waits as pending heal (quote) or pending burn (coin).
///      - The hook tracks v1's own three numbers: the real quote backing the curve, the coins in the
///        pool, and the supply. A heal adds to the first; a burn takes coins out of the pool in the
///        proportion they leave circulation. The floor follows from those reserves by v1's own
///        formula (see {CurveMath-sqrtFloorFor}) and is rounded down to a tick; the position is v1's
///        curve at that floor. It is re-created whenever the pending amounts are enough to lift the
///        floor by a tick spacing.
///      - A loan raises the position's lower tick: the quote below it is unreachable while the borrower's
///        coins are locked, so it can be lent at zero interest with no liquidations.
///
///      The coin must be currency0 (sort below its quote token) so that price is quote per coin.
///      Tokens the hook is owed inside a swap are held as PoolManager ERC-6909 claims, because the swapper
///      has not paid yet when `afterSwap` runs. Every operation is O(1).
contract WavefrontHook is BaseHook, IUnlockCallback, IWavefrontHook, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice LP fee of every pool, in hundredths of a bip (2%).
    uint24 public constant LP_FEE = 20_000;
    /// @notice Share of each trade fee paid to the team and, separately, to the treasury (20% each).
    uint256 public constant RECIPIENT_SHARE_BPS = 2000;
    /// @notice Smallest supply a coin may launch with.
    uint256 public constant MIN_SUPPLY = 1e21;
    /// @notice Smallest virtual quote reserve a coin may launch with.
    uint256 public constant MIN_VIRTUAL_QUOTE = 1e3;
    /// @notice Lowest tick a launch floor may sit on.
    int24 public constant MIN_FLOOR_TICK = -800_000;
    /// @notice Highest tick a launch floor may sit on; leaves room for the price to rise.
    int24 public constant MAX_FLOOR_TICK = 400_000;
    /// @notice Coins a burn always leaves in circulation, so that burning cannot collapse a market.
    /// @dev v1 gets the same protection from the one coin its launcher keeps for ever.
    uint256 public constant MIN_CIRCULATING = 1e18;
    /// @notice A burn is left pending if it would thin the position out to less liquidity than this.
    uint128 public constant MIN_LIQUIDITY = 1e9;
    /// @dev A heal or burn lifts the price with the floor; this many ticks are kept clear below `maxTick`.
    int24 internal constant PRICE_HEADROOM_TICKS = 100_000;
    uint256 internal constant BPS = 10_000;

    /// @notice Deploys the coins; kept separate so the hook fits the contract size limit.
    CoinDeployer public immutable coinDeployer;
    /// @notice Tick spacing of every pool, and the grid the floor is rounded down to.
    int24 public immutable tickSpacing;
    /// @notice Upper tick of every position.
    int24 public immutable maxTick;
    /// @dev Sqrt price at `maxTick`.
    uint160 internal immutable sqrtMaxX96;
    /// @dev Sqrt price a heal or burn may not push the pool price past.
    uint160 internal immutable sqrtPriceCapX96;
    /// @notice Most liquidity a launch, heal or burn may give a position: half of what v4 allows on one
    ///         tick, so that re-creating the position can never be refused by the PoolManager.
    uint128 public immutable maxLiquidity;

    /// @notice Protocol fee recipient. Zero routes the treasury's share to heal / burn.
    address public treasury;

    /// @inheritdoc IWavefrontHook
    mapping(address coin => mapping(address account => uint256)) public debtOf;
    /// @inheritdoc IWavefrontHook
    mapping(address token => mapping(address recipient => uint256)) public feesOwed;

    mapping(address coin => Market) internal _markets;
    address[] internal _coins;

    /// @dev What the hook does inside a PoolManager unlock.
    enum Action {
        LAUNCH,
        BORROW,
        REPAY,
        HEAL,
        BURN,
        CLAIM
    }

    /// @dev The curve as v1 describes it, and the position that holds it.
    struct Curve {
        uint256 quote; // real quote backing the curve: in the position, idle, or lent out
        uint256 coins; // coins in the position
        uint256 circulating; // coins outside the position
        uint256 healed; // pending heal applied to `quote`
        uint256 burned; // pending burn applied to `circulating`
        int24 floorTick;
        uint160 sqrtFloorX96;
        uint160 sqrtPriceX96;
    }

    /// @param poolManager_ The Uniswap v4 PoolManager.
    /// @param coinDeployer_ Deployer of the coin contracts.
    /// @param tickSpacing_ Tick spacing of every pool.
    /// @param owner_ Admin that may set the treasury; intended to be a multisig.
    constructor(IPoolManager poolManager_, CoinDeployer coinDeployer_, int24 tickSpacing_, address owner_)
        BaseHook(poolManager_)
        Ownable(owner_)
    {
        coinDeployer = coinDeployer_;
        tickSpacing = tickSpacing_;
        maxTick = TickMath.maxUsableTick(tickSpacing_);
        sqrtMaxX96 = TickMath.getSqrtPriceAtTick(maxTick);
        sqrtPriceCapX96 = TickMath.getSqrtPriceAtTick(maxTick - PRICE_HEADROOM_TICKS);
        // v4 spreads uint128 liquidity evenly over the usable ticks (see Pool.tickSpacingToMaxLiquidityPerTick)
        maxLiquidity = type(uint128).max / uint128(uint24(2 * (maxTick / tickSpacing_) + 1)) / 2;
    }

    /*//////////////////////////////////////////////////////////////
                              USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IWavefrontHook
    function launch(LaunchParams calldata params) external nonReentrant returns (address coin) {
        if (
            params.quote == address(0) || params.supply < MIN_SUPPLY || params.supply > type(uint128).max
                || params.virtualQuote < MIN_VIRTUAL_QUOTE || params.virtualQuote > type(uint128).max
        ) revert InvalidLaunchParams();

        coin = coinDeployer.deploy(_coinParams(params), _salt(msg.sender, params.salt));
        if (coin >= params.quote) revert CoinMustSortBelowQuote();

        // the floor always sits exactly on a tick, starting with the launch price
        int24 floorTick =
            TickRounding.ceil(CurveMath.floorSqrtPriceX96(params.virtualQuote, params.supply), tickSpacing);
        if (floorTick < MIN_FLOOR_TICK || floorTick > MAX_FLOOR_TICK) revert InvalidLaunchParams();

        _coins.push(coin);
        Market storage m = _markets[coin];
        m.quote = params.quote;
        m.index = _coins.length;
        m.floorTick = floorTick;
        m.lowerTick = floorTick;
        m.sqrtFloorX96 = TickMath.getSqrtPriceAtTick(floorTick);

        poolManager.initialize(_poolKey(coin, params.quote), m.sqrtFloorX96);
        poolManager.unlock(abi.encode(Action.LAUNCH, coin, address(0), params.supply));

        emit Launched(
            coin,
            params.owner,
            params.quote,
            m.index,
            params.supply,
            params.virtualQuote,
            params.name,
            params.symbol,
            params.uri
        );
    }

    /// @inheritdoc IWavefrontHook
    function borrow(address coin, uint256 quoteAmount, address to) external nonReentrant {
        if (quoteAmount == 0) revert ZeroAmount();
        Market storage m = _market(coin);
        debtOf[coin][msg.sender] += quoteAmount;
        m.totalDebt += quoteAmount;

        poolManager.unlock(abi.encode(Action.BORROW, coin, to, quoteAmount));

        if (lockedOf(coin, msg.sender) > IERC20(coin).balanceOf(msg.sender)) revert CreditExceeded();
        emit Borrowed(coin, msg.sender, to, quoteAmount);
    }

    /// @inheritdoc IWavefrontHook
    function repay(address coin, address account, uint256 quoteAmount) external nonReentrant {
        if (quoteAmount == 0) revert ZeroAmount();
        Market storage m = _market(coin);
        debtOf[coin][account] -= quoteAmount;
        m.totalDebt -= quoteAmount;

        poolManager.unlock(abi.encode(Action.REPAY, coin, msg.sender, quoteAmount));
        emit Repaid(coin, account, msg.sender, quoteAmount);
    }

    /// @inheritdoc IWavefrontHook
    function heal(address coin, uint256 quoteAmount) external nonReentrant {
        if (quoteAmount == 0) revert ZeroAmount();
        _market(coin);
        poolManager.unlock(abi.encode(Action.HEAL, coin, msg.sender, quoteAmount));
        emit Healed(coin, msg.sender, quoteAmount);
    }

    /// @inheritdoc IWavefrontHook
    function burn(address coin, uint256 coinAmount) external nonReentrant {
        if (coinAmount == 0) revert ZeroAmount();
        _market(coin);
        poolManager.unlock(abi.encode(Action.BURN, coin, msg.sender, coinAmount));
        emit Burned(coin, msg.sender, coinAmount);
    }

    /// @inheritdoc IWavefrontHook
    function claimFees(address token, address recipient) external nonReentrant returns (uint256 amount) {
        amount = feesOwed[token][recipient];
        if (amount == 0) return 0;
        feesOwed[token][recipient] = 0;
        poolManager.unlock(abi.encode(Action.CLAIM, token, recipient, amount));
        emit FeesClaimed(token, recipient, amount);
    }

    /// @inheritdoc IWavefrontHook
    function setTreasury(address newTreasury) external onlyOwner {
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    /*//////////////////////////////////////////////////////////////
                           POOL MANAGER CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Runs the action encoded by one of the user functions above.
    /// @dev The PoolManager only calls back the contract that called `unlock`, so `data` is always ours.
    /// @param data ABI-encoded `(Action, target, account, amount)`.
    /// @return Always empty.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, address target, address account, uint256 amount) =
            abi.decode(data, (Action, address, address, uint256));

        if (action == Action.CLAIM) {
            _payOut(Currency.wrap(target), account, amount);
            return "";
        }

        Market storage m = _markets[target];
        PoolKey memory key = _poolKey(target, m.quote);

        if (action == Action.LAUNCH) {
            _addInitialPosition(m, key, amount);
        } else if (action == Action.BORROW) {
            _rebalance(m, key, amount);
            if (m.idleQuote < amount) revert InsufficientIdleQuote();
            m.idleQuote -= amount;
            _payOut(key.currency1, account, amount);
        } else if (action == Action.REPAY) {
            _payIn(key.currency1, account, amount);
            m.idleQuote += amount;
            _rebalance(m, key, 0);
        } else {
            // a donation waits as pending heal / burn until it can lift the floor by a tick spacing
            if (action == Action.HEAL) {
                _payIn(key.currency1, account, amount);
                m.pendingHeal += amount;
            } else {
                // reverts if the coins back the account's debt
                _payIn(key.currency0, account, amount);
                m.pendingBurn += amount;
            }
            if (_ratchetDue(m, key)) _rebalance(m, key, 0);
        }
        return "";
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Only the hook creates pools. Its own calls skip hook callbacks, so every call here is foreign.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert HookOwnedLiquidityOnly();
    }

    /// @dev Only the hook provides liquidity, for the same reason.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert HookOwnedLiquidityOnly();
    }

    /// @dev Collects the swap fee after every trade and lifts the floor when enough has accumulated.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        Market storage m = _markets[Currency.unwrap(key.currency0)];
        _flushBurnQueue(m, key.currency0);

        // touching the position with a zero delta pays out the fees it has earned
        (BalanceDelta fees,) = poolManager.modifyLiquidity(key, _positionParams(m.lowerTick, 0), "");
        _accountFees(m, key, uint256(uint128(fees.amount0())), uint256(uint128(fees.amount1())));

        if (_ratchetDue(m, key)) _rebalance(m, key, 0);
        return (IHooks.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 REBALANCE
    //////////////////////////////////////////////////////////////*/

    /// @dev Places the whole supply into a single-sided position at the floor.
    function _addInitialPosition(Market storage m, PoolKey memory key, uint256 supply) internal {
        uint128 liquidity = CurveMath.liquidityForCoin(supply, m.sqrtFloorX96, sqrtMaxX96);
        if (liquidity > maxLiquidity) revert InvalidLaunchParams();
        poolManager.modifyLiquidity(key, _positionParams(m.lowerTick, int256(uint256(liquidity))), "");
        m.liquidity = liquidity;

        uint256 owed = (-poolManager.currencyDelta(address(this), key.currency0)).toUint256();
        poolManager.sync(key.currency0);
        IERC20(Currency.unwrap(key.currency0)).safeTransfer(address(poolManager), owed);
        poolManager.settle();

        // rounding dust of the supply that did not fit the position
        if (supply != owed) Coin(Currency.unwrap(key.currency0)).burn(supply - owed);

        emit Rebalanced(Currency.unwrap(key.currency0), m.sqrtFloorX96, m.sqrtFloorX96, m.lowerTick, liquidity);
    }

    /// @dev Credits the recipients' shares of collected fees and queues the rest as pending heal / burn.
    ///      The fees are a positive delta of the hook at this point; they are kept as claims.
    function _accountFees(Market storage m, PoolKey memory key, uint256 coinFee, uint256 quoteFee) internal {
        address coin = Currency.unwrap(key.currency0);
        if (quoteFee != 0) {
            m.pendingHeal += quoteFee - _accrueFees(coin, Currency.unwrap(key.currency1), quoteFee);
            poolManager.mint(address(this), key.currency1.toId(), quoteFee);
        }
        if (coinFee != 0) {
            m.pendingBurn += coinFee - _accrueFees(coin, coin, coinFee);
            poolManager.mint(address(this), key.currency0.toId(), coinFee);
        }
    }

    /// @dev Whether a rebalance would change anything: the price fell out of the position, or applying
    ///      the pending heal and burn would lift the floor by at least one tick spacing.
    function _ratchetDue(Market storage m, PoolKey memory key) internal view returns (bool) {
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);
        if (sqrtPrice < sqrtLower) return true;
        if (sqrtPrice >= sqrtPriceCapX96) return false;

        uint128 liquidity = m.liquidity;
        Curve memory c;
        c.coins = SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtMaxX96, liquidity, false);
        c.quote = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, liquidity, false) + m.idleQuote + m.totalDebt;
        c.circulating = _supply(m, key.currency0) - c.coins;
        return _applyPending(m, c) >= TickMath.getSqrtPriceAtTick(m.floorTick + tickSpacing);
    }

    /// @dev Removes the position, applies the pending heal and burn to the reserves, and re-creates the
    ///      position that holds them, with its lower tick raised for the current debt.
    ///      Must run while the PoolManager is unlocked and with the hook's deltas at zero.
    /// @param lent Quote about to be paid out to a borrower: already in `totalDebt`, not yet out of the
    ///        market.
    function _rebalance(Market storage m, PoolKey memory key, uint256 lent) internal {
        _flushBurnQueue(m, key.currency0);
        (uint160 poolSqrtPrice,,,) = poolManager.getSlot0(key.toId());

        // v1's three numbers: real quote, coins in the pool, and (through `circulating`) the supply
        Curve memory c;
        (c.coins, c.quote) = _removePosition(m, key);
        if (c.coins == 0) revert CurveMath.EmptyCurve();
        c.quote += m.idleQuote + m.totalDebt - lent;
        c.circulating = _supply(m, key.currency0) - c.coins;

        // the floor those reserves support, rounded down to a tick; it never falls
        uint256 sqrtTarget = _applyPending(m, c);
        c.floorTick = m.floorTick;
        c.sqrtFloorX96 = m.sqrtFloorX96;
        if (sqrtTarget > c.sqrtFloorX96) {
            int24 tick = TickRounding.floor(uint160(sqrtTarget), tickSpacing);
            if (tick > c.floorTick) {
                c.floorTick = tick;
                c.sqrtFloorX96 = TickMath.getSqrtPriceAtTick(tick);
                m.floorTick = tick;
                m.sqrtFloorX96 = c.sqrtFloorX96;
            }
        }
        // and the price of v1's curve at that floor, given the coins in the pool
        c.sqrtPriceX96 = CurveMath.sqrtPriceFor(c.quote, c.coins, c.circulating + c.coins, c.sqrtFloorX96, sqrtMaxX96);

        _addPosition(m, key, c, poolSqrtPrice);
        m.pendingHeal -= c.healed;
        m.pendingBurn -= c.burned;

        // Coins the position no longer holds are the pool's side of a burn (plus rounding dust). With
        // the pending burn just applied they wait in the burn queue: inside a swap the PoolManager may
        // not physically hold them yet.
        uint256 coinDelta = poolManager.currencyDelta(address(this), key.currency0).toUint256();
        if (coinDelta != 0) poolManager.mint(address(this), key.currency0.toId(), coinDelta);
        m.burnQueue += coinDelta + c.burned;

        // Quote the position does not hold stays idle for this market: what a raised lower tick freed
        // for borrowers, and what was not yet enough to lift the floor a tick. The next rebalance counts
        // it again.
        int256 quoteDelta = poolManager.currencyDelta(address(this), key.currency1);
        if (quoteDelta > 0) {
            poolManager.mint(address(this), key.currency1.toId(), uint256(quoteDelta));
        } else if (quoteDelta < 0) {
            poolManager.burn(address(this), key.currency1.toId(), uint256(-quoteDelta));
        }
        m.idleQuote = ((m.idleQuote + c.healed).toInt256() + quoteDelta).toUint256();

        emit Rebalanced(Currency.unwrap(key.currency0), c.sqrtPriceX96, c.sqrtFloorX96, m.lowerTick, m.liquidity);
    }

    /// @dev Applies the pending heal and burn to the reserves in `c`, exactly as v1 does: a heal adds
    ///      quote; a burn takes coins out of the pool in the proportion they leave circulation.
    ///      They are applied together or not at all: they stay pending while nobody holds a coin to
    ///      benefit, or while applying them would leave the range the pool can represent.
    /// @return sqrtTargetX96 Floor the reserves in `c` support; zero if nothing was applied.
    function _applyPending(Market storage m, Curve memory c) internal view returns (uint256 sqrtTargetX96) {
        uint256 coins = c.coins;
        uint256 circulating = c.circulating;
        if (circulating <= MIN_CIRCULATING || coins == 0) return 0;

        uint256 burn = m.pendingBurn;
        if (burn > circulating - MIN_CIRCULATING) burn = circulating - MIN_CIRCULATING;
        // a burn scales liquidity by sqrt(1 - burn / circulating); it may not thin the position to nothing
        uint256 liquidity = m.liquidity;
        if (
            FullMath.mulDiv(liquidity * liquidity, circulating - burn, circulating)
                < uint256(MIN_LIQUIDITY) * MIN_LIQUIDITY
        ) burn = 0;
        if (burn != 0) {
            coins -= FullMath.mulDiv(coins, burn, circulating);
            circulating -= burn;
        }
        uint256 quote = c.quote + m.pendingHeal;
        if (quote > type(uint128).max) return 0;

        sqrtTargetX96 = CurveMath.sqrtFloorFor(quote, coins, circulating);
        // price = floor * supply / coins and liquidity = floor * supply: both must stay in range
        uint256 supply = circulating + coins;
        if (
            sqrtTargetX96 > FullMath.mulDiv(sqrtPriceCapX96, coins, supply)
                || FullMath.mulDiv(sqrtTargetX96, supply, CurveMath.Q96) > maxLiquidity
        ) return 0;

        c.quote = quote;
        c.coins = coins;
        c.circulating = circulating;
        c.healed = m.pendingHeal;
        c.burned = burn;
    }

    /// @dev Destroys coins set aside by an earlier rebalance. They are physically in the PoolManager by
    ///      now, which they may not have been while the swap that produced them was still unpaid.
    function _flushBurnQueue(Market storage m, Currency coin) internal {
        uint256 amount = m.burnQueue;
        if (amount == 0) return;
        m.burnQueue = 0;
        _payOut(coin, address(this), amount);
        Coin(Currency.unwrap(coin)).burn(amount);
    }

    /// @dev Removes the whole position, leaving its principal as a positive delta of the hook. Any fees
    ///      that come with it (only possible after a donation, as every swap collects its own) are
    ///      accounted like swap fees.
    function _removePosition(Market storage m, PoolKey memory key) internal returns (uint256 coins, uint256 quote) {
        (BalanceDelta delta, BalanceDelta fees) =
            poolManager.modifyLiquidity(key, _positionParams(m.lowerTick, -int256(uint256(m.liquidity))), "");
        uint256 coinFee = uint256(uint128(fees.amount0()));
        uint256 quoteFee = uint256(uint128(fees.amount1()));
        coins = uint256(uint128(delta.amount0())) - coinFee;
        quote = uint256(uint128(delta.amount1())) - quoteFee;
        if (coinFee != 0 || quoteFee != 0) _accountFees(m, key, coinFee, quoteFee);
    }

    /// @dev Sizes the position for its coins, raises its lower tick for the debt, moves the pool price
    ///      and adds it. The hook's deltas afterwards are the principal removed minus what was put back.
    function _addPosition(Market storage m, PoolKey memory key, Curve memory c, uint160 poolSqrtPrice) internal {
        uint160 sqrtPrice = c.sqrtPriceX96;
        uint128 liquidity = CurveMath.liquidityForCoin(c.coins, sqrtPrice, sqrtMaxX96);

        // the quote below the lower tick is what has been lent out
        int24 lowerTick = c.floorTick;
        uint256 totalDebt = m.totalDebt;
        if (totalDebt != 0 && liquidity != 0) {
            int24 debtTick = TickRounding.ceil(
                CurveMath.debtBoundarySqrtPriceX96(liquidity, c.sqrtFloorX96, totalDebt), tickSpacing
            );
            if (debtTick > lowerTick) lowerTick = debtTick;
        }

        if (TickMath.getSqrtPriceAtTick(lowerTick) > sqrtPrice) {
            // Tick rounding left the price a hair below the lower bound. Park it on the bound, where
            // the position is all coin and needs no quote. A real over-borrow is caught by {borrow}.
            sqrtPrice = TickMath.getSqrtPriceAtTick(lowerTick);
            liquidity = CurveMath.liquidityForCoin(c.coins, sqrtPrice, sqrtMaxX96);
        }

        // The pool has no liquidity at this point, so moving the price costs nothing.
        if (sqrtPrice != poolSqrtPrice) {
            poolManager.swap(
                key,
                SwapParams({zeroForOne: sqrtPrice < poolSqrtPrice, amountSpecified: -1, sqrtPriceLimitX96: sqrtPrice}),
                ""
            );
        }
        if (liquidity != 0) {
            poolManager.modifyLiquidity(key, _positionParams(lowerTick, int256(uint256(liquidity))), "");
        }

        c.sqrtPriceX96 = sqrtPrice;
        m.liquidity = liquidity;
        m.lowerTick = lowerTick;
    }

    /// @dev Credits the team and treasury shares of `fee`. An unset recipient's share is not credited
    ///      and so falls through to heal / burn, as in v1.
    /// @return owed Total credited to recipients.
    function _accrueFees(address coin, address token, uint256 fee) internal returns (uint256 owed) {
        uint256 share = (fee * RECIPIENT_SHARE_BPS) / BPS;
        if (share == 0) return 0;

        address team = Coin(coin).team();
        if (team != address(0)) {
            feesOwed[token][team] += share;
            owed += share;
            emit FeeAccrued(coin, team, token, share);
        }
        address treasury_ = treasury;
        if (treasury_ != address(0)) {
            feesOwed[token][treasury_] += share;
            owed += share;
            emit FeeAccrued(coin, treasury_, token, share);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev Pulls `amount` from `payer` into the PoolManager and holds it as claims.
    function _payIn(Currency currency, address payer, uint256 amount) internal {
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
        poolManager.settle();
        poolManager.mint(address(this), currency.toId(), amount);
    }

    /// @dev Redeems `amount` of the hook's claims and sends the tokens to `to`.
    function _payOut(Currency currency, address to, uint256 amount) internal {
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IWavefrontHook
    function lockedOf(address coin, address account) public view returns (uint256) {
        uint256 debt = debtOf[coin][account];
        if (debt == 0) return 0;
        Market storage m = _markets[coin];
        if (m.liquidity == 0) return type(uint256).max;
        return CurveMath.lockedCoins(m.liquidity, m.sqrtFloorX96, debt) + _tickMargin(m);
    }

    /// @inheritdoc IWavefrontHook
    function creditOf(address coin, address account) external view returns (uint256) {
        Market storage m = _markets[coin];
        uint256 balance = IERC20(coin).balanceOf(account);
        uint256 margin = _tickMargin(m);
        if (balance <= margin) return 0;
        uint256 limit = CurveMath.creditLimit(m.liquidity, m.sqrtFloorX96, balance - margin);
        uint256 debt = debtOf[coin][account];
        return limit > debt ? limit - debt : 0;
    }

    /// @inheritdoc IWavefrontHook
    function market(address coin) external view returns (Market memory) {
        return _markets[coin];
    }

    /// @inheritdoc IWavefrontHook
    function sqrtPriceX96(address coin) external view returns (uint160 sqrtPrice) {
        (sqrtPrice,,,) = poolManager.getSlot0(_poolKey(coin, _markets[coin].quote).toId());
    }

    /// @inheritdoc IWavefrontHook
    function effectiveSupply(address coin) external view returns (uint256) {
        return _supply(_markets[coin], Currency.wrap(coin));
    }

    /// @inheritdoc IWavefrontHook
    function poolKey(address coin) external view returns (PoolKey memory) {
        return _poolKey(coin, _market(coin).quote);
    }

    /// @inheritdoc IWavefrontHook
    function coinCount() external view returns (uint256) {
        return _coins.length;
    }

    /// @inheritdoc IWavefrontHook
    function coinAt(uint256 index) external view returns (address) {
        return _coins[index - 1];
    }

    /// @inheritdoc IWavefrontHook
    function predictCoin(address caller, LaunchParams calldata params) external view returns (address) {
        return coinDeployer.predict(address(this), _coinParams(params), _salt(caller, params.salt));
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Extra coins every borrower locks on top of what backs their debt. The position's lower tick
    ///      is the debt boundary rounded up to a tick, so up to one tick-spacing of coins above the exact
    ///      boundary cannot be absorbed; one borrower's margin always covers it. Measured at the floor,
    ///      where a tick holds the most coins, so it depends on nobody else and never grows.
    function _tickMargin(Market storage m) internal view returns (uint256) {
        return
            CurveMath.coinsBetween(m.liquidity, m.sqrtFloorX96, TickMath.getSqrtPriceAtTick(m.floorTick + tickSpacing));
    }

    function _market(address coin) internal view returns (Market storage m) {
        m = _markets[coin];
        if (m.index == 0) revert UnknownCoin();
    }

    /// @dev Supply the curve counts: everything except coins already queued for destruction.
    function _supply(Market storage m, Currency coin) internal view returns (uint256) {
        return IERC20(Currency.unwrap(coin)).totalSupply() - m.burnQueue;
    }

    function _poolKey(address coin, address quote) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(coin),
            currency1: Currency.wrap(quote),
            fee: LP_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
    }

    function _positionParams(int24 lowerTick, int256 liquidityDelta)
        internal
        view
        returns (ModifyLiquidityParams memory)
    {
        return
            ModifyLiquidityParams({tickLower: lowerTick, tickUpper: maxTick, liquidityDelta: liquidityDelta, salt: 0});
    }

    function _coinParams(LaunchParams calldata params) internal pure returns (CoinDeployer.CoinParams memory) {
        return CoinDeployer.CoinParams({
            name: params.name,
            symbol: params.symbol,
            uri: params.uri,
            owner: params.owner,
            team: params.team,
            supply: params.supply
        });
    }

    /// @dev Binds the salt to the caller so a launch cannot be replayed by someone else to take its address.
    function _salt(address caller, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(caller, salt));
    }
}

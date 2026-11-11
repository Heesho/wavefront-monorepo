// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpikeCoin} from "./SpikeTokens.sol";

/// @title WavefrontHook (feasibility spike, NOT production code)
/// @notice Re-expresses wavefront's bonding curve, floor ratchet and zero-interest borrowing on real
///         Uniswap v4 liquidity. Each coin is one v4 pool whose only liquidity is a single position
///         owned by this hook, ranging from the floor price to the max tick. That position is
///         mathematically the same curve as Coin.sol's `(virt + real) * coinReserve = k`.
///
///         - buy / sell   : ordinary v4 swaps (real PoolManager Swap events, 2% LP fee)
///         - heal / burn  : afterSwap re-creates the position at a scaled price and floor
///         - borrow/repay : raises / lowers the position's lower tick, freeing quote that locked
///                          collateral makes unreachable
///
///         Requires coin < quote by address so that coin is currency0 (price = quote per coin).
contract WavefrontHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    uint256 public constant SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant VIRT_QUOTE_RAW = 100_000 * 1e6;
    uint24 public constant LP_FEE = 20_000; // 2%
    uint256 public constant SHARE_BPS = 2_000; // 20% of the fee per recipient
    uint256 public constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q96 = FixedPoint96.Q96;

    IPoolManager public immutable poolManager;
    address public immutable quote;
    int24 public immutable tickSpacing;
    int24 public immutable maxTick;

    struct Market {
        PoolKey key;
        address team;
        uint160 floorSqrt; // exact floor sqrt price (accounting value)
        int24 floorTick; // floorSqrt rounded up to a usable tick
        int24 lowerTick; // lower tick of the live position (>= floorTick while debt is out)
        uint128 liquidity; // liquidity of the live position
        uint256 totalDebt; // quote lent out
        uint256 idleQuote; // quote held for this market, as ERC-6909 claims on the PoolManager
        uint256 pendingBurn; // coins already removed from the curve, burned at the next rebalance
    }

    enum Action {
        REBALANCE,
        BORROW,
        REPAY,
        CLAIM
    }

    address public treasury;
    /// @notice Quote fees owed to recipients (pull-based; held as ERC-6909 claims until claimed).
    mapping(address recipient => uint256) public feesOwed;
    /// @notice Coin fees owed to recipients (pull-based, same reason).
    mapping(address coin => mapping(address recipient => uint256)) public coinFeesOwed;
    mapping(address coin => Market) internal _markets;
    mapping(address coin => mapping(address account => uint256)) public debtOf;

    error OnlyPoolManager();
    error HookOwnedLiquidityOnly();
    error CoinMustSortBelowQuote();
    error UnknownMarket();
    error CreditExceeded();
    error InsufficientIdleQuote();

    event Launched(address indexed coin, PoolId indexed id, int24 floorTick, uint128 liquidity);
    event Ratchet(address indexed coin, uint160 sqrtPriceX96, uint160 floorSqrtX96, int24 lowerTick, uint128 liquidity);
    event FeePaid(address indexed coin, address indexed to, address token, uint256 amount);
    event Borrow(address indexed coin, address indexed account, uint256 quoteRaw);
    event Repay(address indexed coin, address indexed account, uint256 quoteRaw);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _quote, int24 _tickSpacing) {
        poolManager = _poolManager;
        quote = _quote;
        tickSpacing = _tickSpacing;
        maxTick = TickMath.maxUsableTick(_tickSpacing);
    }

    /// @dev Spike only: unrestricted. Production would be owner-gated like Core.setTreasury.
    function setTreasury(address _treasury) external {
        treasury = _treasury;
    }

    /*//////////////////////////////////////////////////////////////
                                LAUNCH
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys a coin, mints the whole supply into a single-sided v4 position at the floor.
    function launch(bytes32 salt) external returns (address coin) {
        coin = address(new SpikeCoin{salt: salt}(SUPPLY));
        if (coin >= quote) revert CoinMustSortBelowQuote();

        Market storage m = _markets[coin];
        m.key = PoolKey({
            currency0: Currency.wrap(coin),
            currency1: Currency.wrap(quote),
            fee: LP_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(this))
        });
        m.team = msg.sender;

        // floor price = virtQuote / supply  (same as Coin.getFloorPrice at launch)
        uint160 rawFloor = uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(VIRT_QUOTE_RAW, 1 << 192, SUPPLY)));
        m.floorTick = _ceilTick(rawFloor);
        m.floorSqrt = TickMath.getSqrtPriceAtTick(m.floorTick);
        m.lowerTick = m.floorTick;

        poolManager.initialize(m.key, m.floorSqrt);
        poolManager.unlock(abi.encode(Action.REBALANCE, coin, address(0), uint256(0)));

        emit Launched(coin, m.key.toId(), m.floorTick, m.liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                            BORROW / REPAY
    //////////////////////////////////////////////////////////////*/

    function borrow(address coin, uint256 quoteRaw, address to) external {
        Market storage m = _market(coin);
        debtOf[coin][msg.sender] += quoteRaw;
        m.totalDebt += quoteRaw;

        // raises the position's lower tick and pays out the quote that frees up
        poolManager.unlock(abi.encode(Action.BORROW, coin, to, quoteRaw));

        if (lockedOf(coin, msg.sender) > IERC20(coin).balanceOf(msg.sender)) revert CreditExceeded();
        emit Borrow(coin, msg.sender, quoteRaw);
    }

    function repay(address coin, uint256 quoteRaw, address account) external {
        Market storage m = _market(coin);
        debtOf[coin][account] -= quoteRaw;
        m.totalDebt -= quoteRaw;

        // pulls the quote from the payer and lowers the position's lower tick again
        poolManager.unlock(abi.encode(Action.REPAY, coin, msg.sender, quoteRaw));
        emit Repay(coin, account, quoteRaw);
    }

    /// @notice Pays out accrued quote fees to `recipient`.
    function claimFees(address recipient) external {
        poolManager.unlock(abi.encode(Action.CLAIM, address(0), recipient, uint256(0)));
    }

    /// @notice Pays out accrued fees denominated in `coin` to `recipient`.
    function claimCoinFees(address coin, address recipient) external {
        poolManager.unlock(abi.encode(Action.CLAIM, coin, recipient, uint256(0)));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, address coin, address who, uint256 amount) =
            abi.decode(data, (Action, address, address, uint256));
        Currency q = Currency.wrap(quote);

        if (action == Action.CLAIM) {
            Currency c = coin == address(0) ? q : Currency.wrap(coin);
            uint256 owed;
            if (coin == address(0)) {
                owed = feesOwed[who];
                feesOwed[who] = 0;
            } else {
                owed = coinFeesOwed[coin][who];
                coinFeesOwed[coin][who] = 0;
            }
            poolManager.burn(address(this), c.toId(), owed);
            poolManager.take(c, who, owed);
            return "";
        }

        Market storage m = _markets[coin];
        if (action == Action.REPAY) {
            poolManager.sync(q);
            _safeTransferFrom(quote, who, address(poolManager), amount);
            poolManager.settle();
            poolManager.mint(address(this), q.toId(), amount);
            m.idleQuote += amount;
        }

        _rebalance(m, coin, false);

        if (action == Action.BORROW) {
            if (m.idleQuote < amount) revert InsufficientIdleQuote();
            m.idleQuote -= amount;
            poolManager.burn(address(this), q.toId(), amount);
            poolManager.take(q, who, amount);
        }
        return "";
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Pools may only be created by this hook (self-calls skip hook callbacks in v4).
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookOwnedLiquidityOnly();
    }

    /// @dev Only the hook may provide liquidity (self-calls skip hook callbacks in v4).
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookOwnedLiquidityOnly();
    }

    /// @notice Runs after every real swap: collects the 2% fee, pays recipients, ratchets the floor.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        address coin = Currency.unwrap(key.currency0);
        _rebalance(_markets[coin], coin, true);
        return (IHooks.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               REBALANCE
    //////////////////////////////////////////////////////////////*/

    struct Plan {
        uint160 sqrtP; // pool price before
        uint160 newSqrtP; // pool price after the ratchet
        uint256 coinP; // coin principal removed from the position
        uint256 quoteP; // quote principal removed from the position
        uint256 fee0; // coin fees collected (sells)
        uint256 fee1; // quote fees collected (buys)
        uint256 paid; // fee owed to team/treasury
        uint256 coinTarget; // coin to put back into the position
        uint256 quoteBudget; // quote available for the position
    }

    /// @dev Removes the hook's position, optionally applies the heal/burn scaling, and re-adds it.
    ///      Must be called while the PoolManager is unlocked.
    function _rebalance(Market storage m, address coin, bool ratchet) internal {
        PoolKey memory key = m.key;
        Plan memory p;
        (p.sqrtP,,,) = poolManager.getSlot0(key.toId());
        p.newSqrtP = p.sqrtP;

        uint128 liq = m.liquidity;
        if (liq == 0) {
            // launch: the hook holds the whole supply
            p.coinTarget = IERC20(coin).balanceOf(address(this));
            p.quoteBudget = m.idleQuote;
        } else {
            // Coins set aside by the previous rebalance are physically in the PoolManager by now.
            if (m.pendingBurn > 0) {
                uint256 burnNow = m.pendingBurn;
                m.pendingBurn = 0;
                poolManager.burn(address(this), key.currency0.toId(), burnNow);
                poolManager.take(key.currency0, address(this), burnNow);
                SpikeCoin(coin).burn(burnNow);
            }
            (BalanceDelta d, BalanceDelta fees) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: m.lowerTick,
                    tickUpper: maxTick,
                    liquidityDelta: -int256(uint256(liq)),
                    salt: 0
                }),
                ""
            );
            p.fee0 = uint256(uint128(fees.amount0()));
            p.fee1 = uint256(uint128(fees.amount1()));
            p.coinP = uint256(uint128(d.amount0())) - p.fee0;
            p.quoteP = uint256(uint128(d.amount1())) - p.fee1;
            m.liquidity = 0;

            p.coinTarget = p.coinP;
            p.quoteBudget = p.quoteP + p.fee1 + m.idleQuote;
            // A sell that exhausts the range leaves the pool price below the position, where there is
            // no liquidity. Economically the price is the position's lower bound, so value it there.
            uint160 sqrtLowerOld = TickMath.getSqrtPriceAtTick(m.lowerTick);
            if (p.newSqrtP < sqrtLowerOld) p.newSqrtP = sqrtLowerOld;
            if (ratchet) _applyRatchet(m, coin, liq, p);
        }

        (uint160 finalSqrtP, int24 lower, uint256 newLiq) = _plan(m, p.newSqrtP, p.coinTarget, p.quoteBudget);
        p.newSqrtP = finalSqrtP;

        // The pool has no liquidity right now, so moving the price is free.
        if (p.newSqrtP != p.sqrtP) {
            poolManager.swap(
                key,
                SwapParams({zeroForOne: p.newSqrtP < p.sqrtP, amountSpecified: -1, sqrtPriceLimitX96: p.newSqrtP}),
                ""
            );
        }

        if (newLiq > 0) {
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: lower, tickUpper: maxTick, liquidityDelta: int256(newLiq), salt: 0}),
                ""
            );
        }
        m.liquidity = uint128(newLiq);
        m.lowerTick = lower;

        // Resolve whatever the PoolManager and the hook owe each other. Anything the hook is owed is
        // kept as ERC-6909 claims: inside afterSwap the swapper has not paid yet, so the PoolManager
        // may not physically hold it.
        int256 d0 = poolManager.currencyDelta(address(this), key.currency0);
        int256 d1 = poolManager.currencyDelta(address(this), key.currency1);
        _resolve(key.currency0, d0);
        _resolve(key.currency1, d1);

        // quote: whatever is not owed to fee recipients stays idle for this market
        m.idleQuote = uint256(int256(m.idleQuote) + d1) - (p.fee1 > 0 ? p.paid : 0);
        if (p.fee1 > 0) _creditFees(coin, quote, p.fee1);

        // coin: whatever is not owed to fee recipients is the burn (reserve burn + fee burn + dust)
        if (d0 > 0) m.pendingBurn += uint256(d0) - (p.fee0 > 0 ? p.paid : 0);
        if (p.fee0 > 0) _creditFees(coin, coin, p.fee0);

        // launch only: rounding dust of the minted supply that did not fit the position
        uint256 leftover = IERC20(coin).balanceOf(address(this));
        if (leftover > 0) SpikeCoin(coin).burn(leftover);

        emit Ratchet(coin, p.newSqrtP, m.floorSqrt, m.lowerTick, m.liquidity);
    }

    /// @dev Heal (buy) and burn (sell) are pure scalings of the position:
    ///        heal q : L, sqrtP, sqrtFloor all scale by f = sqrt(1 + q / realQuote)
    ///        burn c : L scales by g, sqrtP and sqrtFloor by 1/g, g = sqrt(1 - c / circulating)
    ///      These are algebraically identical to Coin._healQuoteReserves / Coin._burnCoinReserves.
    function _applyRatchet(Market storage m, address coin, uint128 liq, Plan memory p) internal {
        if (p.fee1 > 0) {
            p.paid = _paidShares(m, p.fee1);
            uint256 heal = p.fee1 - p.paid;
            p.quoteBudget -= p.paid;
            if (p.newSqrtP > m.floorSqrt && heal > 0) {
                uint256 realQuote = FullMath.mulDiv(liq, p.newSqrtP - m.floorSqrt, Q96);
                if (realQuote > 0) {
                    uint256 f = FixedPointMathLib.sqrt(FullMath.mulDiv(realQuote + heal, WAD * WAD, realQuote));
                    p.newSqrtP = uint160(FullMath.mulDiv(p.newSqrtP, f, WAD));
                    m.floorSqrt = uint160(FullMath.mulDiv(m.floorSqrt, f, WAD));
                }
            }
        } else if (p.fee0 > 0) {
            p.paid = _paidShares(m, p.fee0);
            uint256 burnFee = p.fee0 - p.paid;
            // pendingBurn was flushed at the top of this rebalance, so totalSupply is exact here
            uint256 circulating = IERC20(coin).totalSupply() - p.coinP;
            if (burnFee > 0 && circulating > burnFee) {
                uint256 g = FixedPointMathLib.sqrt(FullMath.mulDiv(circulating - burnFee, WAD * WAD, circulating));
                p.newSqrtP = uint160(FullMath.mulDiv(p.newSqrtP, WAD, g));
                m.floorSqrt = uint160(FullMath.mulDiv(m.floorSqrt, WAD, g));
                p.coinTarget = FullMath.mulDiv(p.coinP, circulating - burnFee, circulating);
            }
        }
        m.floorTick = _ceilTick(m.floorSqrt);
    }

    /// @dev Decides the next position: final price, lower tick and liquidity.
    function _plan(Market storage m, uint160 sqrtP, uint256 coinTarget, uint256 quoteBudget)
        internal
        view
        returns (uint160, int24 lower, uint256 liq)
    {
        uint160 sqrtMax = TickMath.getSqrtPriceAtTick(maxTick);
        // liquidity such that the position holds `coinTarget` coins above the current price
        liq = _liquidityForCoin(coinTarget, sqrtP, sqrtMax);

        lower = m.floorTick;
        if (m.totalDebt > 0 && liq > 0) {
            // quote below `lower` is what has been lent out: L * (sqrtLower - sqrtFloorTick) >= totalDebt
            uint160 sqrtFloorTick = TickMath.getSqrtPriceAtTick(m.floorTick);
            uint160 target = uint160(sqrtFloorTick + FullMath.mulDivRoundingUp(m.totalDebt, Q96, liq));
            int24 debtTick = _ceilTick(target);
            if (debtTick > lower) lower = debtTick;
        }
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        if (sqrtLower > sqrtP) {
            // Tick rounding (or a sell that ran through the whole range) left the price below the
            // position's lower bound. Park the price on the bound: the position is then all coin
            // and needs no quote. A real over-borrow is still caught by borrow()'s credit check.
            sqrtP = sqrtLower;
            liq = _liquidityForCoin(coinTarget, sqrtP, sqrtMax);
        }

        uint256 quoteNeed = FullMath.mulDivRoundingUp(liq, sqrtP - sqrtLower, Q96);
        if (quoteNeed > quoteBudget) liq = FullMath.mulDiv(quoteBudget, Q96, sqrtP - sqrtLower);
        return (sqrtP, lower, liq);
    }

    function _liquidityForCoin(uint256 coinAmount, uint160 sqrtP, uint160 sqrtMax) internal pure returns (uint256) {
        return FullMath.mulDiv(coinAmount, FullMath.mulDiv(sqrtP, sqrtMax, Q96), sqrtMax - sqrtP);
    }

    function _resolve(Currency currency, int256 delta) internal {
        if (delta > 0) {
            poolManager.mint(address(this), currency.toId(), uint256(delta));
        } else if (delta < 0) {
            uint256 owed = uint256(-delta);
            uint256 claims = poolManager.balanceOf(address(this), currency.toId());
            if (claims >= owed) {
                poolManager.burn(address(this), currency.toId(), owed);
            } else {
                // launch: the hook pays the minted supply in physically
                poolManager.sync(currency);
                _safeTransfer(Currency.unwrap(currency), address(poolManager), owed);
                poolManager.settle();
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 FEES
    //////////////////////////////////////////////////////////////*/

    /// @dev Same rule as Coin.sol: an unset recipient's share falls through to heal / burn.
    function _recipients(Market storage m) internal view returns (address[2] memory r) {
        r[0] = m.team;
        r[1] = treasury;
    }

    function _paidShares(Market storage m, uint256 fee) internal view returns (uint256 paid) {
        address[2] memory r = _recipients(m);
        uint256 share = (fee * SHARE_BPS) / BPS;
        for (uint256 i; i < 2; i++) {
            if (r[i] != address(0)) paid += share;
        }
    }

    function _creditFees(address coin, address token, uint256 fee) internal {
        address[2] memory r = _recipients(_markets[coin]);
        uint256 share = (fee * SHARE_BPS) / BPS;
        for (uint256 i; i < 2; i++) {
            if (r[i] != address(0)) {
                if (token == quote) feesOwed[r[i]] += share;
                else coinFeesOwed[coin][r[i]] += share;
                emit FeePaid(coin, r[i], token, share);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Coins an account cannot move while it has debt. Called by the coin on every transfer.
    /// @dev base = coins that would have to be sold to push the price from P(debt) down to the floor.
    ///      gap  = slack between the exact total-debt price and the tick the position was rounded up to.
    function lockedOf(address coin, address account) public view returns (uint256) {
        uint256 debt = debtOf[coin][account];
        if (debt == 0) return 0;
        Market storage m = _markets[coin];
        uint256 liq = m.liquidity;
        if (liq == 0) return type(uint256).max;

        uint256 sqrtFloorTick = TickMath.getSqrtPriceAtTick(m.floorTick);
        uint256 sqrtDebt = sqrtFloorTick + FullMath.mulDivRoundingUp(debt, Q96, liq);
        uint256 base = FullMath.mulDivRoundingUp(liq, Q96, sqrtFloorTick) - FullMath.mulDiv(liq, Q96, sqrtDebt);

        uint256 sqrtTotal = sqrtFloorTick + FullMath.mulDiv(m.totalDebt, Q96, liq);
        uint256 sqrtLower = TickMath.getSqrtPriceAtTick(m.lowerTick);
        uint256 gap =
            sqrtLower > sqrtTotal ? FullMath.mulDivRoundingUp(liq, Q96, sqrtTotal) - FullMath.mulDiv(liq, Q96, sqrtLower) : 0;
        return base + gap;
    }

    /// @notice Approximate remaining credit, same closed form as Coin.getAccountCredit:
    ///         virt * balance / (maxSupply - balance) - debt, with virt = L*sqrtFloor and maxSupply = L/sqrtFloor.
    function creditOf(address coin, address account) external view returns (uint256) {
        Market storage m = _markets[coin];
        uint256 liq = m.liquidity;
        if (liq == 0) return 0;
        uint256 sqrtFloorTick = TickMath.getSqrtPriceAtTick(m.floorTick);
        uint256 virt = FullMath.mulDiv(liq, sqrtFloorTick, Q96);
        uint256 maxSupply = FullMath.mulDiv(liq, Q96, sqrtFloorTick);
        uint256 balance = IERC20(coin).balanceOf(account);
        if (balance >= maxSupply) return 0;
        uint256 limit = FullMath.mulDiv(virt, balance, maxSupply - balance);
        uint256 debt = debtOf[coin][account];
        return limit > debt ? limit - debt : 0;
    }

    /// @notice Supply net of coins that are queued to burn.
    function effectiveSupply(address coin) external view returns (uint256) {
        return IERC20(coin).totalSupply() - _markets[coin].pendingBurn;
    }

    function market(address coin)
        external
        view
        returns (
            PoolKey memory key,
            uint160 sqrtPriceX96,
            uint160 floorSqrtX96,
            int24 floorTick,
            int24 lowerTick,
            uint128 liquidity,
            uint256 totalDebt,
            uint256 idleQuote
        )
    {
        Market storage m = _markets[coin];
        key = m.key;
        (sqrtPriceX96,,,) = poolManager.getSlot0(m.key.toId());
        return (key, sqrtPriceX96, m.floorSqrt, m.floorTick, m.lowerTick, m.liquidity, m.totalDebt, m.idleQuote);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _market(address coin) internal view returns (Market storage m) {
        m = _markets[coin];
        if (address(m.key.hooks) == address(0)) revert UnknownMarket();
    }

    /// @dev Smallest usable tick whose sqrt price is >= sqrtP.
    function _ceilTick(uint160 sqrtP) internal view returns (int24 tick) {
        tick = TickMath.getTickAtSqrtPrice(sqrtP);
        if (TickMath.getSqrtPriceAtTick(tick) < sqrtP) tick++;
        int24 rem = tick % tickSpacing;
        if (rem != 0) tick = rem > 0 ? tick + (tickSpacing - rem) : tick - rem;
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        require(IERC20(token).transfer(to, amount), "transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        require(IERC20(token).transferFrom(from, to, amount), "transferFrom failed");
    }

    /*//////////////////////////////////////////////////////////////
                    UNUSED HOOKS (no permission flags set)
    //////////////////////////////////////////////////////////////*/

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}

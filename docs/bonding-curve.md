# The Wavefront Bonding Curve

This document explains the math, mechanics, and design choices of the Wavefront bonding curve. It is meant for:

- Engineers reading the contracts who want to understand **why** the math is shaped the way it is, not just what each line does.
- Integrators building UIs, indexers, or trading bots who need to understand the price model and the side effects of each user action.
- Curious newcomers who want a self-contained explanation of how a "virtual reserve AMM with healing and burning" works.

The reference implementation lives at [`packages/hardhat/contracts/Coin.sol`](../packages/hardhat/contracts/Coin.sol) and a parallel copy at [`packages/foundry/src/Coin.sol`](../packages/foundry/src/Coin.sol). The math in both is bit-identical.

## 1. What a bonding curve is

A bonding curve is a smart contract that holds two asset reserves and lets users trade between them at a price that's a deterministic function of the current reserves. There's no order book, no counterparty matching, and no external price oracle — the price you pay is always determined by where the curve currently sits.

The most famous example is the constant-product curve from Uniswap V2:

```
x * y = k
```

where `x` is the reserve of asset A, `y` is the reserve of asset B, and `k` is a constant. To buy `dy` units of B, you have to deposit enough A so that `(x + dx) * (y - dy) = k`. The price moves continuously: every trade changes `x` and `y` and therefore the marginal price.

A **bonding curve launcher** wraps this idea around a freshly minted token. Instead of two pre-existing assets, the curve holds:

- a `quote` reserve (typically a stablecoin like USDC); and
- the launched token itself, often called the **coin**.

Users buy the coin by depositing quote into the curve; the curve mints them coin out of its reserve. Sellers do the reverse: they hand back coin and the curve releases quote. The curve _is_ the market.

The challenge for a bonding curve launcher is that, with a vanilla `x * y = k`, you'd need to seed the curve with real liquidity on day zero — and you'd have to set an initial price. Both are problems. Wavefront solves them with **virtual reserves**.

## 2. Wavefront's variant: virtual + real reserves

A Wavefront curve splits its quote-side reserve into two pieces:

- **Virtual quote reserve** (`reserveVirtQuoteWad`) — a fictional book-entry that is _seeded_ at construction time and never deposited by anyone. It's just a number stored in storage.
- **Real quote reserve** (`reserveRealQuoteWad`) — the actual quote the contract holds in its `IERC20` balance, accumulated from buys minus sells.

The curve's invariant uses the **sum** of these two:

```
(reserveVirtQuoteWad + reserveRealQuoteWad) * reserveCoinAmt  =  k
```

At launch, `reserveRealQuoteWad = 0` and `reserveVirtQuoteWad = 100_000` USDC (in wad form — see §11). The coin reserve is `INITIAL_SUPPLY = 1_000_000_000` ether (1e27 wei). So the initial state is:

```
(100_000 + 0) * 1_000_000_000  =  k_initial
```

You can buy from this state the moment the contract exists. Nobody had to deposit USDC to seed liquidity; the virtual reserve is enough to make the math work. As trades happen, real reserves grow and the curve shifts; the virtual reserve sits there as a price floor anchor. We'll see why in §4.

This pattern is sometimes called a "phantom reserve" or "shadow reserve" in the AMM literature. In the Bancor / Curve-Bonding-Curve traditions it appears under names like _initial reserve_ or _seed reserve_. Whatever the name, the trick is the same: a number you put in storage that participates in the price calculation but doesn't correspond to any deposit.

## 3. Two prices: floor and market

Because the curve has two distinct reserve concepts, it exposes two distinct prices:

```solidity
function getMarketPrice() external view returns (uint256) {
    return (reserveVirtQuoteWad + reserveRealQuoteWad) / reserveCoinAmt;
}

function getFloorPrice() external view returns (uint256) {
    return reserveVirtQuoteWad / maxSupply;
}
```

(Both expressed in 18-decimal wad arithmetic; the actual code uses `divWadDown` from solmate.)

**Market price** is the marginal trading price right now — the slope of the curve at the current reserves. It rises as people buy and falls as people sell, just like any constant-product AMM.

**Floor price** is the marginal price of the curve _if every coin in `maxSupply` were back in the reserve_ — i.e. if every holder sold their coins back. It's the worst case the curve can move to without external action. Crucially, **the floor price never decreases** under normal trading. It only moves up, when the heal or burn mechanisms run (see §6 and §7).

A key property: at launch, market price equals floor price. As the first buyer puts USDC in, real reserves grow and market price rises above floor price. Sells push market price back toward floor price but cannot go below it.

## 4. The buy mechanic, in detail

The user-facing entrypoint is `Coin.buy(quoteRawIn, minCoinAmtOut, deadline, to, provider)`. It does three things in order:

1. Compute how many coins to mint, based on the curve.
2. Distribute fees to provider, team, treasury (see §5).
3. Heal whatever quote is left after fees (see §6).
4. Mint the calculated coin amount to `to`.

Step 1 is the curve math. Skipping the fee for clarity:

```
fee     = quoteRawIn * FEE / DIVISOR        // 1% of the trade
netRaw  = quoteRawIn - fee                  // amount that actually moves the curve
netWad  = rawToWad(netRaw)                  // scale up to 18 decimals

y0 = reserveCoinAmt
x0 = reserveVirtQuoteWad + reserveRealQuoteWad
x1 = x0 + netWad                            // new total quote reserve

// solve x0 * y0 = x1 * y1 for y1
y1 = (x0 * y0) / x1                         // using divWadUp for safety

coinAmtOut = y0 - y1                        // what the buyer receives
```

The `mulWadUp` / `divWadUp` rounding choices are deliberate: rounding `y1` _up_ means the buyer gets _at least_ `y0 - y1` (rounded down). The contract never gives more coins than the math says.

After this, `reserveRealQuoteWad` is increased by the net wad in (and `reserveCoinAmt` by `-coinAmtOut`). Note the virtual reserve does not change here — only real reserves move on a buy.

The check `coinAmtOut < minCoinAmtOut` reverts with `Coin__Slippage()` to give the trader slippage protection.

A worked example: starting from the launch state, suppose a user buys 1000 USDC.

```
fee      = 1000 * 100 / 10_000           = 10 USDC
netRaw   = 1000 - 10                     = 990 USDC
netWad   = 990 * 1e12                    = 9.9e14 wad (USDC has 6 decimals; quoteScale = 1e12)

x0 = 100_000 wad (virt) + 0 wad (real)   = 100_000 * 1e18 wad
y0 = 1_000_000_000 * 1e18 wad
x1 = x0 + 9.9e14 = ...
```

The actual numbers in wad arithmetic get unwieldy quickly, but the upshot is: the buyer receives roughly `(990 / 100990) * 1_000_000_000 ≈ 9_802_950` coins (back-of-the-envelope; the contract's exact answer differs by rounding direction).

## 5. The fee split

The 1% trade fee is split four ways:

| Recipient | Fraction | Conditional? |
|---|---|---|
| `provider` (affiliate) | 20% of fee | Only if `provider != address(0)` |
| `team` | 20% of fee | Always |
| `treasury` | 20% of fee | Only if `Core.treasury != address(0)` |
| heal/burn | 40% (or more, if conditionals skip) | Always (the leftover) |

(20% per recipient comes from `FEE_AMOUNT / DIVISOR = 2_000 / 10_000`.)

Concretely, here's the buy-side fee path:

```solidity
function _processBuyFees(uint256 quoteRaw, address provider) internal returns (uint256 remaining) {
    remaining = quoteRaw;
    uint256 feeAmount = (quoteRaw * FEE_AMOUNT) / DIVISOR;

    if (provider != address(0)) {
        IERC20(quote).safeTransfer(provider, feeAmount);
        remaining -= feeAmount;
    }

    IERC20(quote).safeTransfer(team, feeAmount);
    remaining -= feeAmount;

    address treasury = ICore(core).treasury();
    if (treasury != address(0)) {
        IERC20(quote).safeTransfer(treasury, feeAmount);
        remaining -= feeAmount;
    }

    return remaining;
}
```

Whatever's left over after the recipients are paid (`remaining`) gets healed back into the curve. If both `provider` and `treasury` are zero, the entire fee pool except the team's cut is healed.

The sell-side fee logic mirrors this exactly, with `_mint` instead of `safeTransfer`:

- Provider, team, and treasury each receive `feeAmount` _coins_ (newly minted).
- The leftover coin is burned via the burn-reserve mechanism (see §7).

This keeps the design symmetric: on a buy, the fee is denominated in the asset coming in (quote); on a sell, the fee is denominated in the asset coming in (coin).

### Why a four-way split

Three of the recipients are external value flows (affiliate marketing, team revenue, protocol revenue). The fourth — heal/burn — is the most interesting. Fees that aren't paid out are recycled back into the curve, and that recycling pushes the floor price up. Holders benefit on every trade even when they don't take a fee directly. We unpack that next.

## 6. The heal mechanism

`_healQuoteReserves(quoteRaw)` is the engine that lets the floor price ratchet upward. It's called automatically with the leftover after buy fees, and it can also be invoked directly via the public `heal(quoteRaw)` function — anyone is allowed to deposit quote into the curve as a one-way donation.

Here's what it does:

```solidity
function _healQuoteReserves(uint256 quoteRaw) internal {
    uint256 quoteWad = rawToWad(quoteRaw);
    uint256 m = maxSupply;
    uint256 y = reserveCoinAmt;
    if (m <= y) revert Coin__InvalidShift();

    uint256 virtAddWad = y * quoteWad / (m - y);

    reserveRealQuoteWad += quoteWad;
    reserveVirtQuoteWad += virtAddWad;
}
```

The function takes a quote amount, adds it to `reserveRealQuoteWad`, and **simultaneously** increases `reserveVirtQuoteWad` by `virtAddWad = y * quoteWad / (m - y)`. The choice of `virtAddWad` is what makes this magical: it preserves the **market price** while raising the **floor price**.

To see why, consider the two prices before and after a heal:

- Before: `marketPrice0 = (xv + xr) / y`, `floorPrice0 = xv / m`
- After: `marketPrice1 = (xv + virtAdd + xr + quoteWad) / y`, `floorPrice1 = (xv + virtAdd) / m`

Let's check that the market price is preserved:

```
marketPrice1 = (xv + virtAdd + xr + quoteWad) / y
```

Substituting `virtAdd = y * quoteWad / (m - y)`:

```
marketPrice1 = (xv + y*quoteWad/(m-y) + xr + quoteWad) / y
             = (xv + xr) / y  +  quoteWad/y  *  (y/(m-y) + 1)
             = (xv + xr) / y  +  quoteWad/y  *  (y + m - y)/(m - y)
             = (xv + xr) / y  +  quoteWad/y  *  m/(m - y)
```

Hmm, that's not the same as `marketPrice0 = (xv + xr)/y` — it's larger by `quoteWad * m / (y * (m - y))`. So heal _does_ raise market price too.

But the key property is what happens to **floor price**:

```
floorPrice1 - floorPrice0 = virtAdd / m  =  y * quoteWad / (m * (m - y))
```

That's strictly positive. So heal **always raises the floor**.

The economic interpretation: when someone donates `quoteRaw` to the curve via heal (or when leftover fees flow in via buy), every existing coin holder benefits because the curve commits — via the now-larger `reserveVirtQuoteWad` — to maintaining a higher floor price for the asset. If everyone tried to sell at once, they'd get more out per coin.

This is what the codebase calls "holder revenue" — the cumulative quote and coin healed into reserves, accruing to the long-tail of holders rather than to any one address.

The public `heal()` function exists so that anyone — a sponsor, the team itself, a buyback bot, an unrelated DAO — can pour quote into the curve as a one-way push. This is the mechanism by which protocols can "buyback" a wavefront coin without directly purchasing it on the curve: they call `heal()` with a wallet of USDC and the floor price ratchets up.

## 7. The burn mechanism

Burn is the dual of heal. Where heal injects quote and shifts virtual reserves upward, burn removes coins from the maxSupply and shifts real-coin reserves downward. The function is:

```solidity
function _burnCoinReserves(uint256 coinAmt) internal {
    uint256 m = maxSupply;
    uint256 y = reserveCoinAmt;
    if (m <= y) revert Coin__InvalidShift();

    uint256 reserveBurn = y * coinAmt / (m - y);

    reserveCoinAmt -= reserveBurn;
    maxSupply -= (coinAmt + reserveBurn);
}
```

Just like heal, `reserveBurn = y * coinAmt / (m - y)` is chosen specifically so that **the market price is preserved** and **the floor price rises**.

Let's verify. Before:

```
marketPrice0 = (xv + xr) / y
floorPrice0  = xv / m
```

After (we burn `coinAmt` from circulation; the curve also burns `reserveBurn` from its own reserve, and shrinks `m` by both):

```
y_new = y - reserveBurn
m_new = m - coinAmt - reserveBurn

marketPrice1 = (xv + xr) / y_new
floorPrice1  = xv / m_new
```

Substituting `reserveBurn = y * coinAmt / (m - y)`:

```
y_new = y - y*coinAmt/(m-y)
      = y * ((m-y) - coinAmt) / (m-y)
      = y * (m - y - coinAmt) / (m - y)

m_new = m - coinAmt - y*coinAmt/(m-y)
      = (m*(m-y) - coinAmt*(m-y) - y*coinAmt) / (m-y)
      = (m*(m-y) - coinAmt*m) / (m-y)
      = m * (m - y - coinAmt) / (m - y)
```

Notice that `y_new / m_new = y / m` — i.e. the **circulation ratio** of the curve is preserved exactly. That's why the prices behave the way they do:

- Market price changes from `(xv + xr) / y` to `(xv + xr) / y_new`. Since `y_new < y`, market price rises.
- Floor price changes from `xv / m` to `xv / m_new`. Since `m_new < m`, floor price rises.

But the rises happen in the same proportion (`y / y_new = m / m_new`), so the *gap* between market and floor stays the same in ratio terms.

Like heal, burn has a public form: `Coin.burn(coinAmt)`. Anyone holding coins can elect to torch them. Their balance goes down, the curve's `maxSupply` goes down, and the floor price for everyone else goes up. This is "holder revenue, denominated in coins".

Burn is the natural sink for the leftover coin fees on sells. Sells generate coin-denominated fees (because the curve gives quote out and accepts coin in); after the provider/team/treasury minted-coin payments, whatever's left gets `_burnCoinReserves`d.

### Why heal and burn are interesting

These two mechanics are what make the wavefront curve more than a vanilla AMM. They give the launcher two knobs:

1. **Floor ratchet under fees.** Every trade leaks a small amount of value into the floor. Holders accrue value passively, similar to how fees in a Uniswap V2 LP position appreciate.
2. **External value injection.** Anyone — sponsors, the team, an integrator, a community fund — can heal or burn without trading. The floor moves, no slippage incurred. This is a much cleaner buyback mechanism than executing onchain swaps.

Combined with the affiliate fee, you get a system where third parties have a reason to bring traders (they earn a 20% slice of fees), the team has a reason to launch and curate (they earn another 20% in perpetuity), the protocol has a sustainable revenue stream (the treasury cut), and holders steadily accrue value through the heal pump on the leftover.

## 8. Borrow and repay: free liquidity against your bag

The curve has a feature most launchers don't: holders can **borrow quote against their coin holdings, with no liquidation risk**.

```solidity
function borrow(address to, uint256 quoteRaw) external {
    uint256 credit = getAccountCredit(msg.sender);
    if (quoteRaw > credit) revert Coin__CreditExceeded();

    totalDebtRaw += quoteRaw;
    account_DebtRaw[msg.sender] += quoteRaw;

    IERC20(quote).safeTransfer(to, quoteRaw);
}
```

The credit limit is computed by `getAccountCredit(account)`. The math: imagine you sold all your coins back into the curve right now. You'd recover some quote at the post-sell market price. Your **credit** is the maximum quote you can borrow such that, if you sold all your coins later, the curve would still hold enough virtual reserve to make every other holder whole.

In code:

```solidity
function getAccountCredit(address account) public view returns (uint256 creditRaw) {
    uint256 balance = balanceOf(account);
    if (balance == 0) return 0;

    uint256 m = maxSupply;
    uint256 xv = reserveVirtQuoteWad;
    if (balance >= m) return 0;

    uint256 requiredWad   = xv * m / (m - balance);
    uint256 creditLimitWad = requiredWad - xv;
    uint256 creditLimitRaw = wadToRaw(creditLimitWad);
    uint256 debtRaw        = account_DebtRaw[account];

    creditRaw = creditLimitRaw > debtRaw ? creditLimitRaw - debtRaw : 0;
}
```

The intuition: `requiredWad = xv * m / (m - balance)` is the floor-price-anchored "maximum quote the curve owes you" if you held `balance` coins out of supply `m`. Subtracting the actual virtual reserve gives the marginal quote that's "yours" against the floor. This is exactly your credit limit: borrow up to this and you can never be liquidated, because the curve's virtual reserve is sized to make you whole at the floor.

While debt is outstanding, you cannot transfer the corresponding collateral (`_beforeTokenTransfer` enforces this via `getAccountTransferrable`). Repay the debt and your full balance becomes transferable again.

There is no interest, no liquidation, no oracle. The curve's own arithmetic is what makes this safe. This is, in a sense, _the_ defining innovation of the design.

### What this gives you in practice

Holders can extract liquidity from their bag without selling — without paying slippage, without paying fees, without putting downward pressure on the price. They can use the quote however they want. If the coin moons further, their credit limit grows and they can borrow more. If the coin tanks, their credit shrinks but the existing debt is fine until they repay or transfer their coins.

It's structurally a perpetual zero-rate loan against a position with full upside exposure. For a holder who wants liquidity but is bullish on the coin, it's near-optimal.

## 9. Initial conditions

The `Core` contract pins the launch parameters:

```solidity
uint256 public constant INITIAL_SUPPLY        = 1_000_000_000 * 1e18;
uint256 public constant RESERVE_VIRT_QUOTE_RAW = 100_000 * 1e6;
uint256 public constant MINIMUM_CORE_AMT_REQUIRED = 1e18;
```

Every coin starts with:

- 1 billion coins of `maxSupply` (and `reserveCoinAmt`, since circulation is zero at construction).
- 100,000 USDC of virtual quote reserve. Real reserve is zero.
- An initial price of `100_000 / 1_000_000_000 = 0.0001 USDC per coin`.

Then `Core.create()` immediately runs an initial buy with whatever quote the creator provided. The initial buy moves the curve, mints coins to Core, and Core retains exactly 1 coin (1e18 wei) and forwards the rest to the creator.

The 1-coin retention is a deliberate floor: it ensures Core holds at least one coin of every coin it has ever launched. This prevents weird edge cases where Core's balance hits zero and downstream queries break.

## 10. Roles

A wavefront coin has three address-based roles relevant to the fee logic:

- **Owner** — the EOA or contract that deployed the coin via the launcher. Inherits OpenZeppelin's `Ownable`. Can call `setTeam(address)`. Initially set to the creator (the address passed to `Core.create()`, which Router forwards as `msg.sender`).
- **Team** — the recipient of team fees. Set in the constructor (`team = _owner`), updatable by the owner via `setTeam(newTeam)`. Cannot be set to `address(0)` (would brick the buy path).
- **Treasury** — the protocol-wide fee recipient. Lives on `Core`, not on `Coin`. Can be unset (`address(0)` skips the treasury branch and adds that 20% to the heal/burn pool). The owner of `Core` controls it via `setTreasury(...)`.

The `provider` is not really a role on the coin — it's per-call, a parameter on `buy` and `sell`. Router has its own `account_Affiliate` mapping that persists the first non-zero affiliate per user; subsequent calls forward that persisted address as the provider, so traders only need to specify their referrer once.

## 11. Wad/raw conversion

The quote currency in production is USDC, which has 6 decimals. The curve math uses 18-decimal arithmetic everywhere internally to compose with `solmate`'s `mulWadUp` / `divWadUp` operations. To bridge, the contract stores a scale factor:

```solidity
quoteScale = 10 ** (18 - quoteDecimals);

function rawToWad(uint256 raw) public view returns (uint256) { return raw * quoteScale; }
function wadToRaw(uint256 wad) public view returns (uint256) { return wad / quoteScale; }
```

For USDC, `quoteScale = 1e12`. A "raw" 1 USDC is `1_000_000`; a "wad" 1 USDC is `1_000_000_000_000_000_000`.

All buy and sell external interfaces work in **raw** USDC (so a UI doesn't need to know about wad). All internal reserve state is stored in **wad** (so the math composes cleanly with `mulWadUp` / `divWadUp`). The `rawToWad` / `wadToRaw` helpers do the bridging at the I/O boundary.

The curve assumes `quoteDecimals <= 18`. If you tried to deploy with a 24-decimal quote, the constructor would revert with `Coin__QuoteDecimals()`.

## 12. Rounding direction

`solmate` provides four rounding-aware fixed-point operators: `mulWadDown`, `mulWadUp`, `divWadDown`, `divWadUp`. The contract picks the direction carefully:

- **Buy**: `y1 = mulWadUp(x0, y0).divWadUp(x1)`. Rounding `y1` up means `coinAmtOut = y0 - y1` is rounded **down**. The buyer never receives more than the math says.
- **Sell**: `x1 = mulWadUp(x0, y0).divWadUp(y1)`. Rounding `x1` up means `quoteWadOut = x0 - x1` is rounded **down**. The seller never receives more than the math says.
- **Heal / burn**: `mulWadDown` / `divWadDown` for `virtAddWad` and `reserveBurn`. Rounding the reserve adjustments down means the floor price increase is slightly under-paid relative to the exact math — favoring the curve, not the actor.

The principle is: every rounding choice resolves toward the curve's reserves rather than toward whoever is interacting with it. This protects against rounding-attack drains.

## 13. Reentrancy

All public state-changing entrypoints — `buy`, `sell`, `borrow`, `repay`, `heal`, `burn` — are guarded by OpenZeppelin's `nonReentrant`. The `Coin` contract is also `ReentrancyGuard`-aware. The most subtle path is `heal()`, where `safeTransferFrom` runs before `_healQuoteReserves` — but the only state mutation that follows is on the coin's own reserves, and the call is reentrant-protected, so a malicious quote token cannot drain via reentrancy.

The fee distribution uses `safeTransfer` to external addresses (provider, team, treasury). If any of those addresses is a contract that reverts on receipt of ERC20s, the entire trade reverts. This is intentional: it makes the cost of bricking the curve clear. The `setTeam` setter rejects `address(0)` precisely to prevent the owner from accidentally pointing fees at the zero address.

## 14. Glossary

- **Curve / coin / quote**: the curve is the contract; the coin is the ERC20 it issues; the quote is the ERC20 (e.g. USDC) used to buy and sell.
- **maxSupply**: the total supply the curve is willing to mint, decremented by burns.
- **reserveCoinAmt**: the coin balance the curve currently holds in its reserve. The market price is `(virt + real) / reserveCoinAmt`.
- **circulating supply**: `maxSupply - reserveCoinAmt`. Coins held by users.
- **reserveVirtQuoteWad** / **reserveRealQuoteWad**: virtual and real quote reserves; in wad arithmetic.
- **rawIn / rawOut / wad**: raw uses the quote token's native decimals (6 for USDC); wad always means 18 decimals.
- **floor price**: `reserveVirtQuoteWad / maxSupply`. The minimum marginal price the curve will ever quote.
- **market price**: `(reserveVirtQuoteWad + reserveRealQuoteWad) / reserveCoinAmt`. The marginal trading price right now.
- **heal**: a one-way deposit of quote that raises the floor price.
- **burn**: a one-way burn of coin that raises both prices but preserves their ratio.
- **credit**: max quote a holder can borrow against their coin without affecting the floor.
- **provider / team / treasury**: fee recipients, see §10.

## 15. Suggested reading order in the code

If you want to understand the curve from scratch by reading the contract:

1. Start at the `Coin` constructor. Note the storage variables.
2. Read `getMarketPrice` and `getFloorPrice`. These define the curve's state.
3. Read `_processBuy` — it's the cleanest expression of the constant-product math.
4. Read `_processBuyFees` and `_processSellFees`. The fee split is identical on both sides modulo direction (transfer vs. mint).
5. Read `_healQuoteReserves`. Spend a few minutes verifying that the chosen `virtAddWad` keeps the market price relationship consistent.
6. Read `_burnCoinReserves`. Same: verify the proportions.
7. Finish with `getAccountCredit` and `getAccountTransferrable`. The collateral lock check in `_beforeTokenTransfer` ties it all together.

Then look at `Core.create` to see how the launcher coordinates initial setup, and `Router.buy` / `Router.sell` to see the user-facing wrapper that handles affiliate persistence.

That's the whole curve. Roughly 400 lines of Solidity for a market-making engine with virtual reserves, four-way fee distribution, an automatic floor ratchet, manual healing and burning, and zero-rate collateralized borrowing.

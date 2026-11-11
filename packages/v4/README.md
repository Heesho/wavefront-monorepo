# @wavefront/v4

Wavefront rebuilt on Uniswap v4, with feature parity to the v1 contracts in `packages/hardhat` and
`packages/foundry`. Each coin trades in a standard v4 pool whose only liquidity is one position owned by
the wavefront hook, so routers and indexers that understand v4 need no wavefront-specific support.

The v1 contracts are the reference oracle: tests deploy the real v1 build and assert the v4 code agrees.

**Status: unaudited. Do not deploy with real funds.**

## Contracts

| Contract | Role |
|---|---|
| `WavefrontHook` | Launches coins, owns each pool's position, collects fees, ratchets the floor, lends quote |
| `Coin` | ERC20 with permit and votes; holds the collateral lock, team address and metadata URI |
| `CoinDeployer` | Deploys coins for the hook (keeps the hook under the contract size limit) |
| `WavefrontRouter` | Optional convenience router: launch with the creator's first buy, buy, sell |
| `WavefrontLens` | Read-only aggregator and quotes for front ends |
| `libraries/CurveMath` | The position that holds a set of reserves; credit and lock formulas |
| `libraries/TickRounding` | Rounding sqrt prices to usable ticks |

## Launching a coin

`WavefrontRouter.launch(params, quoteIn, minCoinOut)` deploys the coin and makes the creator's first buy
in the same transaction. The creator chooses:

- `name`, `symbol` and a metadata `uri` (ERC-7572 `contractURI`; the coin's owner can change it later).
- `quote`: any standard ERC20. No fee-on-transfer or rebasing tokens; native ETH goes in as WETH.
- `supply` and `virtualQuote`: the launch price is `virtualQuote / supply`, and a larger `virtualQuote`
  means it takes more quote to move the price. At least 1,000 coins of supply and 1,000,000 raw units
  of virtual quote (1 USDC), so that a raw unit of rounding is never more than a millionth of the curve.
- `owner` and `team`: the owner controls the URI and team; the team receives the coin's fee share.
- `salt`: the coin's address must sort below the quote token's, so a front end tries salts with
  `predictCoin` until one does. The address also depends on the caller, so a pending launch cannot be
  replayed by someone else to take its address or buy ahead of the creator.

## How the curve is kept

v1 never stores a price. Its state is three reserves: the real quote backing the curve, the coins in the
pool, and the supply. A buy fee adds to the first (a heal); a sell fee removes coins from circulation and,
in the same proportion, from the pool (a burn). Price and floor follow from the reserves.

The hook keeps the same three numbers and nothing else about the curve. Whenever it re-creates its
position it derives it from them. `CurveMath.sqrtFloorFor` gives the floor
(`sqrt(quote * coins / (circulating * supply))`, v1's own floor), which is rounded down to a tick. The
position is then v1's curve at that floor: the one that would hold the whole supply there, at the price
the pool's coins put it at (`CurveMath.sqrtPriceFor`). There is no separate heal or burn formula.

## How it differs from v1

- **The floor sits on a tick.** v1's floor can be any price. v4 rounds it down to the nearest tick
  spacing (0.1% of price), so the floor is at most 0.1% under v1's. The quote that rounding leaves over
  (less than 0.1% of what the market holds) waits outside the position as `idleQuote` and is counted
  again every time, so it lifts the floor as soon as it is worth a tick.
- **Fees are applied when they are worth a tick.** Re-creating a position costs gas, so heal and burn
  fees wait as `pendingHeal` / `pendingBurn` until together they lift the floor by a tick spacing. Over
  400-trade random paths the market price stays within 1% of v1's (0.25% to 0.4% on average) and the
  total paid out to sellers within 0.003% (`test/LongPath.t.sol`).
- **Fees are claimed, not pushed.** Team and treasury shares accrue in the hook and are paid by
  `claimFees`, because inside a swap the hook cannot move tokens the trader has not paid yet.
- **Borrowers lock a small fixed margin.** On top of the coins backing a debt, each borrower locks one
  tick-spacing of coins at the floor (about 0.05% of supply). Positions smaller than that cannot borrow.
- **Fees and donations need holders.** A heal or burn goes to whoever holds the coin. While holders
  have less than 0.1% of the supply it waits as pending instead of being applied, so that a few cents'
  worth of coins cannot capture a donation and lift the floor many times over, and a burn cannot take
  nearly the whole supply with it. v1 applies both at once. A donation into a coin nobody holds
  therefore goes to the first buyers of that 0.1%. This raises the cost of inflating an empty coin's
  floor from nothing to the fees on a real purchase; a creator's own first buy at launch raises it
  further.
- **Limits of the tick range.** A heal or burn that would push the price within 100,000 ticks of the top
  of v4's range, or the position past half of v4's per-tick liquidity limit, stays pending rather than
  being applied. A launch above that liquidity is refused.
- **No minimum trade size and no per-coin deadline**: slippage and deadlines live in the router.

## Run

Foundry must be on your `PATH` (`export PATH="$PATH:$HOME/.foundry/bin"`).

```bash
git submodule update --init packages/v4/lib/forge-std
yarn install
yarn workspace @wavefront/v4 test      # builds v1 first, then runs the v4 suite
yarn workspace @wavefront/v4 fmt:check
yarn workspace @wavefront/v4 lint
```

Heavier runs:

```bash
yarn workspace @wavefront/v4 test:ci   # 10,000 fuzz runs per test, 100,000 calls per invariant
yarn workspace @wavefront/v4 test:deep # invariants only, each run a thousand actions long
yarn workspace @wavefront/v4 test:fork # against Uniswap's live contracts on a fork of Base
yarn workspace @wavefront/v4 slither   # needs `pip install slither-analyzer`
```

`.github/workflows/ci.yml` runs the v1 suites, formatting, lint, the contract size check, `test:ci`
and Slither on every pull request, and the fork tests on pushes to `main`.

## Tests

- `test/CurveMath.t.sol`: every formula fuzzed against the deployed v1 `Coin`. v1's floor and price are
  reproduced from its reserves alone after trades, heals and burns; the position derived from a set of
  reserves is checked, with the PoolManager's own rounding, to fit them and to absorb exactly the
  circulating coins.
- `test/WavefrontHook.t.sol`: launch, trading, fees, heal, burn, lending and access control, with v1
  parity wherever v1 has an equivalent.
- `test/LongPath.t.sol`: 400 random trades on v1 and v4 side by side, then everyone exits.
- `test/TokenShapes.t.sol`: quote tokens that are not textbook ERC20s (see "Quote tokens" below).
- `test/invariant/`: a handler drives random buys, sells, borrows, repays, heals, burns, transfers, fee
  claims and recipient toggles by five actors. After every call the suite checks that the floor never
  falls, sits on a tick and is v1's floor for the market's reserves rounded down to that tick, the
  hook's claims equal exactly what it accounts for, debt is covered by the range below the position,
  borrowers hold their collateral, every unlocked coin can be absorbed by the pool, and no action that
  must always work (buying, repaying, donating, claiming, launching) ever reverted. After every run all
  debts are repaid and every holder sells out. It runs in three configurations:
  - v1's own launch parameters against a 6-decimal quote, and a deeper coin against an 18-decimal one;
  - the edges of what a launch allows: 2- and 8-decimal quotes, a thousand-coin supply priced above its
    quote, a quadrillion-coin supply, and the smallest curve permitted;
  - runs that launch their own coins mid-run, with supply and curve depth drawn from the whole
    permitted range against quotes of 2, 6, 8 and 18 decimals.
- `test/invariant/Regression.t.sol`: sequences the invariant suite once broke, kept as fixed tests.
- `test/fork/`: on a fork of Base against the live `PoolManager` and real USDC. `BaseFork.t.sol` trades
  through Uniswap's own Universal Router and checks against Uniswap's own Quoter;
  `DeployScript.t.sol` runs the deploy script and trades on what it deployed. Skipped unless
  `BASE_RPC_URL` is set.

## Quote tokens

Any standard ERC20 works, including ones whose transfer functions return nothing (USDT on mainnet).

- **Fee-on-transfer tokens are not supported and fail safely.** A coin can be launched against one, but
  every action that would move the token reverts, so nothing can be lost or stuck.
- **Tokens that call the sender or recipient back mid-transfer (ERC-777 style)** get no opening: the
  hook's entry points cannot be re-entered, swaps never move the quote token inside the hook, and the
  one place a payment is pulled before state is settled (`repay`) writes the debt down only after the
  payment has arrived.
- **Rebasing tokens are not supported.** The PoolManager holds the balances, and v4 itself does not
  account for balances that change on their own.

## Static analysis

Slither runs clean with the configuration in `slither.config.json`. What it excludes, and why:

| Finding | Why it is accepted |
|---|---|
| `reentrancy-*` (29) | Every flagged call goes to the PoolManager or the hook's own coin. User entry points are `nonReentrant`, and the only calls into untrusted code (quote token transfers) come after state is settled; `test/TokenShapes.t.sol` checks this with a token that calls back mid-transfer. |
| `unused-return` (18) | PoolManager return values the hook reads back from its own deltas instead. |
| `arbitrary-send-erc20` (2, annotated inline) | The payer is always the caller of the action that opened the unlock. |
| `uninitialized-local` (2) | Memory structs that are meant to start zeroed. |
| `missing-zero-check` (4) | A zero team or treasury is how those fees are switched off. |
| `divide-before-multiply` (1, annotated inline) | Counting ticks: the division is exact. |
| `timestamp`, `too-many-digits` | The router's deadline; a false positive on creation code. |

Triaging the reentrancy reports by hand did find one real ordering issue, in `repay`, which is fixed
and tested.

## Deploying

`script/Deploy.s.sol` deploys the coin deployer, the hook (at an address mined so that its low bits
encode its permissions, through the canonical CREATE2 deployer), the router and the lens.
`script/Launch.s.sol` launches a coin with the broadcaster's first buy. Both document their environment
variables at the top of the file.

```bash
# dry run: simulates against the chain and sends nothing
HOOK_OWNER=0x... forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL

# for real, signing with a key in Foundry's encrypted keystore (cast wallet import <name> --interactive)
HOOK_OWNER=0x... forge script script/Deploy.s.sol --rpc-url $BASE_RPC_URL --account <name> --broadcast
```

A real run records the addresses in `deployments/<chain id>.json`. Deploying costs about 14M gas.
**The contracts are unaudited: anything deployed is permissionless and immutable, so treat a
deployment as an experiment with money you can afford to lose.**

## Design rules

- **Constant-time.** No operation loops over users, borrowers, coins or history.
- **Rounding favours the pool.** What the pool pays or promises rounds down; what it is owed rounds up.
- **Immutable.** No proxies. Admin is limited to the treasury address and is meant for a multisig.
- **Audited building blocks.** `BaseHook`, `SafeERC20`, `SafeCast`, `FullMath`, OpenZeppelin tokens.

## Not yet in place

- External audit. Uniswap's hook Security Framework requires a maths-specialist audit for this design.
- A live deployment. The scripts are tested on a fork; nothing has been sent to a chain, so how
  scanners display these pools is still unverified.
- Subgraph for the v4 events.
- Complete NatSpec tags (the linter reports about 100 missing `@param` / `@return` tags).

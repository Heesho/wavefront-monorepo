# Wavefront — Design Doc

**Date:** 2026-05-01
**Status:** Approved (brainstorming phase complete)

## 1. Goal

Wavefront is a bonding-curve token launcher. This monorepo extracts the bonding-curve mechanics from the stickrnet codebase ([hardhat](https://github.com/Heesho/stickrnet-hardhat), [foundry](https://github.com/Heesho/stickrnet-foundry), [subgraph](https://github.com/Heesho/stickrnet-subgraph)) and removes the content + rewarder systems built on top of it. The remaining package-level pieces:

- `packages/hardhat` — Solidity contracts with Hardhat tooling
- `packages/foundry` — same contracts (independently maintained) with Foundry tooling
- `packages/subgraph` — a Graph Protocol subgraph that indexes them

## 2. Naming: token → coin

The bonding-curve ERC20 the launcher deploys is renamed `Token` → `Coin` throughout the project: contract files, interfaces, events, errors, struct fields, variable names, subgraph entities and handlers, ABIs, schema fields, mapping handlers, and test files all use "Coin" or "coin".

Exceptions:
- "quote" — the pricing currency (e.g. USDC) keeps the term `quote` / `IERC20`.
- ERC20 standard concepts (`totalSupply`, `balanceOf`, `transfer`, etc.) inherited from OpenZeppelin keep their standard names.

## 3. Repo structure

```
wavefront-monorepo/
├── package.json              (yarn workspaces root)
├── README.md
├── LICENSE                   (MIT)
├── .gitignore
├── .gitmodules               (foundry submodules under packages/foundry/lib/)
├── docs/
│   └── plans/
│       └── 2026-05-01-wavefront-design.md
├── scripts/
│   └── sync-abis.js
└── packages/
    ├── hardhat/
    ├── foundry/
    └── subgraph/
```

Yarn workspaces with three packages: `@wavefront/hardhat`, `@wavefront/foundry`, `@wavefront/subgraph`. Single `yarn install` at the root. Contracts are duplicated in `packages/hardhat/contracts/` and `packages/foundry/src/` and maintained independently — the originals already differ slightly (solmate import path, naming conventions) and that pattern carries through.

## 4. Contracts

### 4.1 Files (per package)

```
contracts/                    # packages/hardhat/contracts (or packages/foundry/src)
├── Coin.sol                  bonding curve ERC20 (Ownable + Permit + Votes + ReentrancyGuard)
├── Core.sol                  registry, treasury, Coin deployer
├── Router.sol                user-facing entry: createCoin, buy, sell
├── Multicall.sol             read aggregator: getCoinData + buyQuoteIn/sellCoinIn helpers
├── interfaces/
│   ├── ICoin.sol
│   └── ICore.sol
└── mocks/
    └── USDC.sol
```

Deleted from the original: `ContentFactory.sol`, `RewarderFactory.sol`, `IContent.sol`, `IContentFactory.sol`, `IRewarder.sol`, `IRewarderFactory.sol`, `ITokenFactory.sol`, the `TokenFactory` contract (its single function is folded into `Core`).

### 4.2 Coin.sol

Bonding curve ERC20. All curve mechanics from the original `Token` are preserved.

**Inheritance:** `ERC20`, `ERC20Permit`, `ERC20Votes`, `ReentrancyGuard`, **`Ownable`** (new — original `Token` was not `Ownable`; the constructor's `owner` param was forwarded into Content).

**External / public API kept:**
- `buy(quoteRawIn, minCoinAmtOut, deadline, to, provider)` — virtual + real reserves, x*y=k math
- `sell(coinAmtIn, minQuoteRawOut, deadline, to, provider)` — same curve in reverse
- `borrow(to, quoteRaw)` / `repay(to, quoteRaw)` — collateralized lending against held coins
- `heal(quoteRaw)` — anyone deposits quote, virtual reserves shift
- `burn(coinAmt)` — anyone burns coins, max supply shifts
- `setTeam(address newTeam) external onlyOwner` — new
- View functions: `getMarketPrice`, `getFloorPrice`, `getAccountCredit`, `getAccountTransferrable`, `rawToWad`, `wadToRaw`

**Internal helpers kept:**
- `_processBuyFees`, `_processSellFees` — see fee split below
- `_healQuoteReserves`, `_burnTokenReserves` — reserve-shift math

**Storage:**
- Constants: `PRECISION`, `FEE`, `FEE_AMOUNT`, `DIVISOR`, `MIN_TRADE_SIZE` (unchanged)
- Immutables: `core`, `quote`, `quoteDecimals`, `quoteScale`
- Mutable: `team` (new — set in constructor, updatable via `setTeam`), `maxSupply`, `reserveRealQuoteWad`, `reserveVirtQuoteWad`, `reserveCoinAmt` (renamed from `reserveTokenAmt`), `totalDebtRaw`, `account_DebtRaw`

**Constructor:**
```solidity
constructor(
    string memory name,
    string memory symbol,
    address _core,
    address _quote,
    address _owner,             // becomes Ownable owner + initial team
    uint256 _initialSupply,
    uint256 _virtQuoteRaw
) ERC20(name, symbol) ERC20Permit(name)
```

Drops `uri`, `contentFactory`, `rewarderFactory`, `minInitPrice`, `isModerated` from the original signature, plus the `IContentFactory.create(...)` call and the `content` / `rewarder` immutables.

**Fee split (4-way) on buy:**
```
fee = quoteIn * FEE / DIVISOR                            // 1% of trade
feeAmount = fee * FEE_AMOUNT / DIVISOR                   // 20% per recipient

if (provider != 0) → feeAmount to provider               (Coin__ProviderFee)
if (team != 0)     → feeAmount to team                   (Coin__TeamFee)
if (treasury != 0) → feeAmount to treasury (read from Core)  (Coin__TreasuryFee)
leftover            → heal back into reserves             (Coin__HealReserves)
```

All three recipient branches are conditional on a non-zero address; if any is zero, that 20% slice rolls into the leftover and gets healed (on buy) or burned (on sell). Sell mirrors the structure with `_mint` instead of `safeTransfer`. The original "content" branch is removed; the team branch replaces it. Treasury still reads dynamically from `Core`.

**Events kept (renamed `Token__` → `Coin__`):** `Swap`, `SyncReserves`, `HealReserves`, `BurnReserves`, `ProviderFee`, `TeamFee` (replaces `ContentFee`), `TreasuryFee`, `Heal`, `Burn`, `Borrow`, `Repay`, `TeamSet` (new).

**Errors:** all original errors kept, prefix renamed `Token__` → `Coin__`.

### 4.3 Core.sol

```solidity
contract Core is Ownable {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant RESERVE_VIRT_QUOTE_RAW = 100_000 * 1e6;
    uint256 public constant MINIMUM_CORE_AMT_REQUIRED = 1e18;

    address public immutable quote;
    address public treasury;

    uint256 public index;
    mapping(uint256 => address) public index_Coin;
    mapping(address => uint256) public coin_Index;

    function create(
        string memory name,
        string memory symbol,
        address owner,
        uint256 quoteRawIn,
        uint256 coreCoinAmtRequired
    ) external returns (address coin);

    function setTreasury(address) external onlyOwner;
}
```

`Core.create()` deploys `new Coin(...)` directly (no factory), runs an initial buy with `quoteRawIn`, retains `coreCoinAmtRequired` (defaults to 1e18 from the Router), and forwards the rest to the owner. Emits `Core__CoinCreated(name, symbol, index, coin, owner)`.

Dropped from the original: `tokenFactory`, `contentFactory`, `rewarderFactory`, `CONTENT_MIN_INIT_PRICE`, `isModerated`, `uri` parameter, `Core__ContentFactorySet`, `Core__RewarderFactorySet`, `Core__SaleFactorySet`, `Core__TokenFactorySet` events.

### 4.4 Router.sol

```solidity
contract Router is ReentrancyGuard, Ownable {
    uint256 public constant CORE_COIN_AMT_REQUIRED = 1e18;
    address public immutable core;

    mapping(address => address) public account_Affiliate;

    function createCoin(string calldata name, string calldata symbol, uint256 amountQuoteIn) external returns (address coin);
    function buy(address coin, address affiliate, uint256 amountQuoteIn, uint256 minAmountCoinOut, uint256 expireTimestamp) external;
    function sell(address coin, address affiliate, uint256 amountCoinIn, uint256 minAmountQuoteOut, uint256 expireTimestamp) external;
    function withdrawStuckTokens(address _token, address _to) external onlyOwner;
}
```

Events: `Router__CoinCreated`, `Router__Buy`, `Router__Sell`, `Router__AffiliateSet`. Dropped: `createContent`, `collectContent`, `getContentReward`, `notifyContentRewardAmount`, `Router__ContentCreated`, `Router__ContentCollected`, `isModerated` parameter. Affiliate mapping kept (provider fees still route through here).

### 4.5 Multicall.sol

Read-only aggregator. `CoinData` struct keeps the curve-relevant fields:

```solidity
struct CoinData {
    uint256 index;
    address coin;
    address quote;
    address team;
    address owner;
    string name;
    string symbol;
    uint256 marketCap;
    uint256 liquidity;
    uint256 floorPrice;
    uint256 marketPrice;
    uint256 circulatingSupply;
    uint256 maxSupply;
    uint256 accountQuoteBalance;
    uint256 accountCoinBalance;
    uint256 accountDebt;
    uint256 accountCredit;
    uint256 accountTransferrable;
}
```

Drops `accountContentOwned`, `accountContentStaked`, `accountQuoteEarned`, `accountTokenEarned`, `accountIsModerator`, `contentApr`, `isModerated`, `uri`, `content`, `rewarder`. Drops `getContentData` entirely. Keeps `buyQuoteIn` and `sellCoinIn` (renamed from `sellTokenIn`) helpers for slippage estimation.

### 4.6 mocks/USDC.sol

Unchanged. Used by tests as the quote currency.

## 5. Subgraph

### 5.1 Schema

```graphql
type Directory @entity(immutable: false) {
  id: ID!
  index: BigInt!
  txCount: BigInt!
  swapVolume: BigDecimal!
  liquidity: BigDecimal!
}

type User @entity(immutable: false) {
  id: ID!
  txCount: BigInt!
  coinsOwned: [Coin!]! @derivedFrom(field: "owner")
  coinsTeamed: [Coin!]! @derivedFrom(field: "team")
  coinPositions: [CoinPosition!]! @derivedFrom(field: "user")
  swaps: [Swap!]! @derivedFrom(field: "user")
}

type Coin @entity(immutable: false) {
  id: ID!
  name: String!
  symbol: String!
  owner: User!
  team: User!

  txCount: BigInt!
  swapVolume: BigDecimal!
  liquidity: BigDecimal!
  totalSupply: BigDecimal!
  marketCap: BigDecimal!
  quoteVirtReserve: BigDecimal!
  quoteRealReserve: BigDecimal!
  coinReserve: BigDecimal!
  marketPrice: BigDecimal!
  floorPrice: BigDecimal!
  holders: BigInt!

  holderRevenueQuote: BigDecimal!
  holderRevenueCoin: BigDecimal!
  teamRevenueQuote: BigDecimal!
  teamRevenueCoin: BigDecimal!
  treasuryRevenueQuote: BigDecimal!
  treasuryRevenueCoin: BigDecimal!

  createdAtTimestamp: BigInt!
  createdAtBlockNumber: BigInt!

  coinPositions: [CoinPosition!]! @derivedFrom(field: "coin")
  swaps: [Swap!]! @derivedFrom(field: "coin")
  coinDayData: [CoinDayData!]! @derivedFrom(field: "coin")
  coinHourData: [CoinHourData!]! @derivedFrom(field: "coin")
  coinMinuteData: [CoinMinuteData!]! @derivedFrom(field: "coin")
}

type CoinPosition @entity(immutable: false) {
  id: ID!
  coin: Coin!
  user: User!
  balance: BigDecimal!
  debt: BigDecimal!
  affiliateRevenueQuote: BigDecimal!
  affiliateRevenueCoin: BigDecimal!
}

type Swap @entity(immutable: false) {
  id: ID!
  coin: Coin!
  user: User!
  blockNumber: BigInt!
  timestamp: BigInt!
  quoteIn: BigDecimal!
  quoteOut: BigDecimal!
  coinIn: BigDecimal!
  coinOut: BigDecimal!
  marketPrice: BigDecimal!
  floorPrice: BigDecimal!
}

type CoinDayData   @entity(immutable: false) { id: ID! coin: Coin! timestamp: BigInt! marketPrice: BigDecimal! floorPrice: BigDecimal! volume: BigDecimal! }
type CoinHourData  @entity(immutable: false) { id: ID! coin: Coin! timestamp: BigInt! marketPrice: BigDecimal! floorPrice: BigDecimal! volume: BigDecimal! }
type CoinMinuteData @entity(immutable: false) { id: ID! coin: Coin! timestamp: BigInt! marketPrice: BigDecimal! floorPrice: BigDecimal! volume: BigDecimal! }
```

Dropped from original: `ContentPosition`, `Collect`, `ContentDayData`, `ContentHourData`, `ContentMinuteData`, `Moderator`, `Content`, `Rewarder` entities. On `User`: `referrer`, `referrals`, `moderator`, `contentOwned`, `contentCreated`, `collects`. On the main coin entity: `uri`, `isModerated`, `contents`, `contentValue`, `collectVolume`, `creatorEarned`, `holderEarned`, `collectorSpent`, `collectorEarned`, `contentRevenueQuote`, `contentRevenueToken`, plus all derived content/collect fields.

### 5.2 Data sources & event handlers

| Source | Events |
|---|---|
| `Core` (mainnet) | `Core__CoinCreated`, `Core__TreasurySet` |
| `Coin` (template) | `Coin__Swap`, `Coin__SyncReserves`, `Coin__HealReserves`, `Coin__BurnReserves`, `Coin__ProviderFee`, `Coin__TeamFee`, `Coin__TreasuryFee`, `Coin__Heal`, `Coin__Burn`, `Coin__Borrow`, `Coin__Repay`, `Coin__TeamSet`, `Transfer` |

Mapping files: `src/core.ts`, `src/coin.ts` (renamed from `token.ts`), `src/helpers.ts`, `src/constants.ts`. Original `content.ts` and `rewarder.ts` deleted. The `handleApproval`, `handleDelegateChanged`, `handleDelegateVotesChanged`, `handleEIP712DomainChanged` no-op handlers from the original are dropped.

### 5.3 ABI sync flow

Root-level `scripts/sync-abis.js` (run manually after `yarn compile`):
- Read `packages/hardhat/artifacts/contracts/Core.sol/Core.json` → write `packages/subgraph/abis/Core.json` (just the `abi` field)
- Read `packages/hardhat/artifacts/contracts/Coin.sol/Coin.json` → write `packages/subgraph/abis/Coin.json`

Documented in `packages/subgraph/README.md`.

### 5.4 Network targeting

`networks.json` ships with placeholder entries for `localhost`, `base_sepolia`, and `base`. Addresses + start blocks filled in after deployment. `subgraph.template.yaml` + `prepare.js` pattern preserved from the original.

## 6. Tooling

### 6.1 Root `package.json`

```json
{
  "name": "wavefront-monorepo",
  "private": true,
  "workspaces": ["packages/*"],
  "packageManager": "yarn@1.22.22",
  "scripts": {
    "compile": "yarn workspace @wavefront/hardhat compile",
    "build": "yarn workspace @wavefront/foundry build",
    "test:hardhat": "yarn workspace @wavefront/hardhat test",
    "test:foundry": "yarn workspace @wavefront/foundry test",
    "test:subgraph": "yarn workspace @wavefront/subgraph test",
    "test": "yarn test:hardhat && yarn test:foundry && yarn test:subgraph",
    "sync-abis": "node scripts/sync-abis.js",
    "subgraph:prepare": "yarn workspace @wavefront/subgraph prepare",
    "subgraph:build": "yarn workspace @wavefront/subgraph build"
  }
}
```

### 6.2 `packages/hardhat`

Deps cloned from the original: `hardhat ^2.12.0`, `@openzeppelin/contracts ^4.8.0`, `solmate ^6.8.0`, `ethers ^5.6.4`, `@nomiclabs/hardhat-ethers`, `@nomiclabs/hardhat-waffle`, `chai`, `ethereum-waffle`, `@nomicfoundation/hardhat-verify`, `@nomicfoundation/hardhat-chai-matchers`, `@nomicfoundation/hardhat-network-helpers`, `solidity-coverage`, `dotenv`. Scripts: `compile`, `test`, `coverage`, `deploy:sepolia`. `hardhat.config.js` matches the original (solc 0.8.19, viaIR, base_sepolia network) plus a `localhost` network for `npx hardhat node`.

### 6.3 `packages/foundry`

`foundry.toml` matches the original (solc 0.8.19, viaIR, optimizer 200, base_sepolia rpc + etherscan). Submodules in `packages/foundry/lib/`: `forge-std`, `solmate`, `openzeppelin-contracts`. Tracked from the monorepo root via `.gitmodules`. Thin `package.json` so it shows up in the workspace:

```json
{
  "name": "@wavefront/foundry",
  "private": true,
  "scripts": {
    "build": "forge build",
    "test": "forge test -vv",
    "coverage": "forge coverage"
  }
}
```

### 6.4 `packages/subgraph`

Deps `@graphprotocol/graph-cli`, `@graphprotocol/graph-ts`, `matchstick-as`. Scripts:

```json
{
  "scripts": {
    "prepare": "node prepare.js",
    "codegen": "graph codegen",
    "build": "yarn prepare && yarn codegen && graph build",
    "test": "graph test",
    "deploy:base": "graph deploy --node https://api.studio.thegraph.com/deploy/ wavefront",
    "create-local": "graph create --node http://localhost:8020/ wavefront",
    "deploy-local": "graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 wavefront"
  }
}
```

`subgraph.yaml` is a generated, gitignored file produced by `prepare.js` from `subgraph.template.yaml` + `networks.json`.

### 6.5 `.gitignore` (root)

```
node_modules/
.env
.env.*
!.env.example

# hardhat
packages/hardhat/cache/
packages/hardhat/artifacts/
packages/hardhat/coverage/
packages/hardhat/coverage.json

# foundry
packages/foundry/out/
packages/foundry/cache/
packages/foundry/broadcast/

# subgraph
packages/subgraph/build/
packages/subgraph/generated/
packages/subgraph/subgraph.yaml
```

## 7. Tests

### 7.1 Hardhat

Extract bonding-curve test cases from the original `test0.js`/`test1.js`/`test2.js`:

- `tests/Coin.test.js` — buy/sell, slippage, fee splits (provider/team/treasury/heal), borrow/repay/credit, manual heal, manual burn, reserve underflow, deadline, min-trade-size, ERC20Votes weight, ownership + setTeam.
- `tests/Core.test.js` — coin creation flow, `1e18` retention, treasury setter.
- `tests/Router.test.js` — affiliate persistence, deadline propagation, fee distribution end-to-end.

Drop everything content/rewarder/auction/moderation related.

### 7.2 Foundry

- `test/Coin.t.sol` — keep & trim from the original `Token.t.sol` (~27 KB), focused on curve mechanics.
- `test/Core.t.sol` — keep & trim.
- `test/Integration.t.sol` — slimmed to the curve flows.
- `test/mocks/` — keep mocks needed for tests (USDC, etc.).

Delete `Content.t.sol` and `Rewarder.t.sol`.

### 7.3 Subgraph

Matchstick tests in `packages/subgraph/tests/`: keep `coin.test.ts` and `core.test.ts` (extracted from `token.test.ts` / `core.test.ts`). Update for the new schema. Delete `content.test.ts` and `rewarder.test.ts`.

## 8. Open / future

- `referrer` on `User` in the subgraph is dropped for v1. Adding it later means adding `Router` as a data source and indexing `Router__AffiliateSet`.
- Coin metadata URI is dropped. Frontends that need it can add it later as either an immutable on `Coin` or an off-chain registry.
- A `packages/sdk` (TypeScript client wrapping the contracts + a typed subgraph client) is a likely future package; the workspace structure already accommodates it.

## 9. Implementation phasing (hint for writing-plans)

Likely order:
1. `git init`, root scaffolding (`package.json`, workspaces, `.gitignore`, `LICENSE`, README skeleton).
2. `packages/hardhat` — write contracts (Coin, Core, Router, Multicall, mocks, interfaces) by extracting from the original `stickrnet-hardhat`, applying the rename and stripping content/rewarder. Wire hardhat config & deps. Get `yarn compile` clean.
3. `packages/foundry` — same contracts, independently extracted from `stickrnet-foundry`. `foundry.toml` + remappings, lib submodules. Get `forge build` clean.
4. Tests — extract bonding-curve cases from each original suite into `Coin.test.js`/`Coin.t.sol` etc.
5. `packages/subgraph` — schema, mappings, `prepare.js`, `networks.json`, ABIs synced from hardhat. Get `yarn build` clean.
6. Root scripts: `sync-abis.js`, top-level `yarn` commands.
7. Top-level README.

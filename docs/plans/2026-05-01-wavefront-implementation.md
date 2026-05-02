# Wavefront Monorepo Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the wavefront-monorepo: a yarn-workspaces project with three packages (`@wavefront/hardhat`, `@wavefront/foundry`, `@wavefront/subgraph`) that extracts the bonding-curve mechanics from stickrnet, drops the content/rewarder systems, and renames `Token` → `Coin` throughout.

**Architecture:** Three packages live under `packages/`. The hardhat and foundry packages each carry their own copy of the same Solidity contracts (independently maintained). The subgraph indexes the deployed contracts via committed ABIs that are manually synced from hardhat's compile output. Full curve mechanics from the original `Token` are preserved (buy/sell, borrow/repay, heal/burn, reserve shifts). Fees split four ways: provider / team / treasury / heal.

**Tech Stack:** Solidity 0.8.19 (viaIR, optimizer 200), OpenZeppelin Contracts 4.8, solmate 6.8, Hardhat 2.x + ethers 5 + waffle, Foundry (forge-std), The Graph CLI + matchstick-as, yarn 1 workspaces.

**Reference design doc:** [`docs/plans/2026-05-01-wavefront-design.md`](2026-05-01-wavefront-design.md). Read this first — it has the full schema, contract API, and naming rules.

**Source repos (stickrnet, pre-strip):**
- https://github.com/Heesho/stickrnet-hardhat
- https://github.com/Heesho/stickrnet-foundry
- https://github.com/Heesho/stickrnet-subgraph

**Rename rules (apply throughout):** "Token" → "Coin" / "token" → "coin" in contract names, file names, struct fields, function params, local variables, events (`Token__*` → `Coin__*`), errors (`Token__*` → `Coin__*`), interfaces (`IToken` → `ICoin`), subgraph entities, schema fields, handler functions. Two exceptions: keep `quote` (the pricing currency) as-is, and keep ERC20 standard concepts (`totalSupply`, `balanceOf`, `transfer`, `_mint`, `_burn`) untouched.

**Stripping rules (apply to source files):** delete every reference to Content, ContentFactory, Rewarder, RewarderFactory, isModerated, uri, minInitPrice/initialContentPrice, content fee branch in fee distribution, IContentFactory.create() call in Token constructor.

---

## Phase 0: Source repos for reference

Clone the three stickrnet repos to `/tmp/sources/` so subsequent tasks can reference them. Already cloned in the brainstorming session, but a fresh agent may not have them.

### Task 0.1: Clone source repos

**Step 1: Clone**

```bash
mkdir -p /tmp/sources
git clone --depth 1 https://github.com/Heesho/stickrnet-hardhat.git /tmp/sources/stickrnet-hardhat
git clone --depth 1 https://github.com/Heesho/stickrnet-foundry.git /tmp/sources/stickrnet-foundry
git clone --depth 1 https://github.com/Heesho/stickrnet-subgraph.git /tmp/sources/stickrnet-subgraph
```

**Step 2: Verify**

```bash
ls /tmp/sources/stickrnet-hardhat/contracts/
ls /tmp/sources/stickrnet-foundry/src/
ls /tmp/sources/stickrnet-subgraph/src/
```

Expected: each lists the source `.sol`/`.ts` files. No commit needed (these aren't in the working tree).

---

## Phase 1: Root scaffolding

### Task 1.1: Root `package.json`

**Files:**
- Create: `package.json`

**Content:**

```json
{
  "name": "wavefront-monorepo",
  "private": true,
  "version": "0.1.0",
  "description": "Bonding curve token launcher",
  "license": "MIT",
  "workspaces": ["packages/*"],
  "packageManager": "yarn@1.22.22",
  "scripts": {
    "compile": "yarn workspace @wavefront/hardhat compile",
    "build:foundry": "yarn workspace @wavefront/foundry build",
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

**Commit:** `git add package.json && git commit -m "chore: yarn workspaces root"`

### Task 1.2: Root `.gitignore`

**Files:**
- Create: `.gitignore`

**Content:**

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

# misc
.DS_Store
.vscode/
.idea/
```

**Commit:** `git add .gitignore && git commit -m "chore: gitignore"`

### Task 1.3: LICENSE

**Files:**
- Create: `LICENSE`

**Content:** MIT license, copyright "2026 Wavefront contributors". Use the standard MIT template.

**Commit:** `git add LICENSE && git commit -m "chore: MIT license"`

### Task 1.4: Top-level README skeleton

**Files:**
- Modify: `README.md`

**Content:** Replace the stub with:

```markdown
# wavefront-monorepo

Bonding curve token launcher.

## Packages

- [`packages/hardhat`](packages/hardhat) — Solidity contracts with Hardhat tooling
- [`packages/foundry`](packages/foundry) — same contracts with Foundry tooling (independently maintained)
- [`packages/subgraph`](packages/subgraph) — Graph Protocol subgraph

## Quickstart

```bash
yarn install
yarn compile          # hardhat compile
yarn build:foundry    # forge build
yarn test             # all packages
```

## Design doc

See [`docs/plans/2026-05-01-wavefront-design.md`](docs/plans/2026-05-01-wavefront-design.md).
```

**Commit:** `git add README.md && git commit -m "docs: README skeleton with package map"`

### Task 1.5: Verify yarn workspaces wiring

**Step 1:** `yarn install` (will install nothing yet — no packages).

**Expected:** `success Already up-to-date.` or similar with no errors.

**No commit (no file changes).**

---

## Phase 2: `packages/hardhat` setup

### Task 2.1: `packages/hardhat/package.json`

**Files:**
- Create: `packages/hardhat/package.json`

**Content (copy deps from `/tmp/sources/stickrnet-hardhat/package.json`, add scripts):**

```json
{
  "name": "@wavefront/hardhat",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "compile": "hardhat compile",
    "test": "hardhat test",
    "coverage": "hardhat coverage",
    "deploy:sepolia": "hardhat run ./scripts/deploy.js --network base_sepolia",
    "node": "hardhat node"
  },
  "dependencies": {
    "@nomicfoundation/hardhat-verify": "^1.1.1",
    "@nomiclabs/hardhat-etherscan": "^3.1.7",
    "@openzeppelin/contracts": "^4.8.0",
    "axios": "^1.3.2",
    "dotenv": "^16.0.3",
    "hardhat": "^2.12.0",
    "solmate": "^6.8.0"
  },
  "devDependencies": {
    "@nomicfoundation/hardhat-chai-matchers": "^1.0.3",
    "@nomicfoundation/hardhat-network-helpers": "^1.0.9",
    "@nomiclabs/hardhat-ethers": "^2.0.5",
    "@nomiclabs/hardhat-waffle": "^2.0.5",
    "chai": "^4.3.6",
    "ethereum-waffle": "^3.4.4",
    "ethers": "^5.6.4",
    "solidity-coverage": "^0.8.15"
  }
}
```

**Commit:** `git add packages/hardhat/package.json && git commit -m "chore(hardhat): package.json"`

### Task 2.2: `packages/hardhat/hardhat.config.js`

**Files:**
- Create: `packages/hardhat/hardhat.config.js`

**Content (copy `/tmp/sources/stickrnet-hardhat/hardhat.config.js`, rename `mainnet` network to `base_sepolia`, add `localhost`):**

```js
const { config } = require("dotenv");

require("@nomiclabs/hardhat-waffle");
require("@nomicfoundation/hardhat-verify");
require("solidity-coverage");

config();
const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x" + "0".repeat(64);
const SCAN_API_KEY = process.env.SCAN_API_KEY || "";
const RPC_URL = process.env.RPC_URL || "https://sepolia.base.org";

module.exports = {
  solidity: {
    version: "0.8.19",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true,
    },
  },
  networks: {
    base_sepolia: {
      url: RPC_URL,
      chainId: 84532,
      accounts: [PRIVATE_KEY],
    },
    localhost: { url: "http://127.0.0.1:8545" },
    hardhat: {},
  },
  etherscan: {
    apiKey: SCAN_API_KEY,
    customChains: [
      {
        network: "base_sepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api.etherscan.io/v2/api?chainid=84532",
          browserURL: "https://sepolia.basescan.org/",
        },
      },
    ],
  },
  paths: {
    sources: "./contracts",
    tests: "./tests",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  mocha: { timeout: 300000 },
};
```

**Commit:** `git add packages/hardhat/hardhat.config.js && git commit -m "chore(hardhat): hardhat.config.js"`

### Task 2.3: `packages/hardhat/.env.example`

**Files:**
- Create: `packages/hardhat/.env.example`

**Content:**

```
PRIVATE_KEY=
RPC_URL=https://sepolia.base.org
SCAN_API_KEY=
```

**Commit:** `git add packages/hardhat/.env.example && git commit -m "chore(hardhat): env example"`

### Task 2.4: `yarn install` to populate dependencies

**Step 1:** Run `yarn install` at the repo root.

**Expected:** populates `node_modules/`, no errors. Hardhat should be installed under `node_modules/hardhat`.

**No commit (only `yarn.lock` is created — commit that):**

```bash
git add yarn.lock && git commit -m "chore: lockfile"
```

---

## Phase 3: `packages/hardhat` interfaces

### Task 3.1: `ICoin.sol` interface

**Files:**
- Create: `packages/hardhat/contracts/interfaces/ICoin.sol`

**Source reference:** `/tmp/sources/stickrnet-hardhat/contracts/interfaces/IToken.sol`.

**Transformation:**
- Rename interface `IToken` → `ICoin`.
- Drop functions: `content()`, `rewarder()`.
- Rename `reserveTokenAmt` → `reserveCoinAmt`.
- Rename param/return types containing `tokenAmt*` → `coinAmt*`.
- Add `function team() external view returns (address);`
- Add `function setTeam(address newTeam) external;`

**Content:**

```solidity
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
```

**Commit:** `git add packages/hardhat/contracts/interfaces/ICoin.sol && git commit -m "feat(hardhat): ICoin interface"`

### Task 3.2: `ICore.sol` interface

**Files:**
- Create: `packages/hardhat/contracts/interfaces/ICore.sol`

**Source reference:** `/tmp/sources/stickrnet-hardhat/contracts/interfaces/ICore.sol`.

**Transformation:**
- Drop `tokenFactory()`, `contentFactory()`, `rewarderFactory()` getters and their setters.
- Rename `index_Token`/`token_Index` → `index_Coin`/`coin_Index`.
- Rename `create(...)` signature to drop `uri`, `isModerated`; renamed return value from `token` to `coin`.

**Content:**

```solidity
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
```

**Commit:** `git add packages/hardhat/contracts/interfaces/ICore.sol && git commit -m "feat(hardhat): ICore interface"`

---

## Phase 4: `packages/hardhat` mocks

### Task 4.1: USDC mock

**Files:**
- Create: `packages/hardhat/contracts/mocks/USDC.sol`

**Source reference:** Copy verbatim from `/tmp/sources/stickrnet-hardhat/contracts/mocks/USDC.sol`.

**Commit:** `git add packages/hardhat/contracts/mocks/USDC.sol && git commit -m "feat(hardhat): USDC mock"`

---

## Phase 5: `packages/hardhat` Coin.sol

The most important contract. Take the original `Token` contract from `/tmp/sources/stickrnet-hardhat/contracts/TokenFactory.sol`, apply these transformations:

1. Move `Token` contract into its own file `packages/hardhat/contracts/Coin.sol`. Drop the standalone `TokenFactory` contract entirely (no longer needed).
2. Rename contract `Token` → `Coin`.
3. Add `Ownable` to inheritance list.
4. Rename storage `reserveTokenAmt` → `reserveCoinAmt`.
5. Add storage: `address public team;`
6. Constructor: drop `uri`, `contentFactory`, `rewarderFactory`, `owner`, `minInitPrice`, `isModerated` params. Add new param `address _owner`. Drop `IContentFactory(contentFactory).create(...)` call. Drop `content` and `rewarder` immutables. Add `team = _owner; _transferOwnership(_owner);` to constructor body.
7. New external function `setTeam(address newTeam) external onlyOwner` + event `Coin__TeamSet(address newTeam)`.
8. Rename all references in errors, events, params, locals from `token`/`tokenAmt` to `coin`/`coinAmt`. Specifically: events `Token__*` → `Coin__*`, errors `Token__*` → `Coin__*`. Drop `Token__ContentFee` event.
9. In `_processBuyFees` and `_processSellFees`: drop the content fee branch. Replace with team fee branch — sends `feeAmount` to `team` (state var, not address(0) check needed since constructor always sets it). Emit `Coin__TeamFee` instead of `Coin__ContentFee`.
10. Drop import of `IContentFactory`.
11. Add import of `Ownable`.

### Task 5.1: Stub `Coin.sol`

Create the file with the contract scaffold (just enough to compile against the imports), then expand step-by-step.

**Files:**
- Create: `packages/hardhat/contracts/Coin.sol`

**Content (full file):** Copy `/tmp/sources/stickrnet-hardhat/contracts/TokenFactory.sol`, then apply the transformations above. Result should match this skeleton (key parts highlighted; copy reserve math etc. unchanged):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {ERC20, ERC20Permit, ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {ICore} from "./interfaces/ICore.sol";

contract Coin is ERC20, ERC20Permit, ERC20Votes, ReentrancyGuard, Ownable {
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant PRECISION = 1e18;
    uint256 public constant FEE = 100;
    uint256 public constant FEE_AMOUNT = 2_000;
    uint256 public constant DIVISOR = 10_000;
    uint256 public constant MIN_TRADE_SIZE = 1_000;

    address public immutable core;
    address public immutable quote;

    uint8 public immutable quoteDecimals;
    uint256 public immutable quoteScale;

    address public team;

    uint256 public maxSupply;

    uint256 public reserveRealQuoteWad;
    uint256 public reserveVirtQuoteWad;
    uint256 public reserveCoinAmt;

    uint256 public totalDebtRaw;
    mapping(address => uint256) public account_DebtRaw;

    error Coin__QuoteDecimals();
    error Coin__ZeroInput();
    error Coin__ZeroTo();
    error Coin__Expired();
    error Coin__MinTradeSize();
    error Coin__Slippage();
    error Coin__CollateralLocked();
    error Coin__CreditExceeded();
    error Coin__InvalidShift();
    error Coin__DivideByZero();
    error Coin__ReserveUnderflow();

    event Coin__Swap(address indexed from, uint256 quoteInRaw, uint256 coinIn, uint256 quoteOutRaw, uint256 coinOut, address indexed to);
    event Coin__SyncReserves(uint256 reserveRealQuoteWad, uint256 reserveVirtQuoteWad, uint256 reserveCoinAmt);
    event Coin__HealReserves(uint256 quoteWad, uint256 virtAddWad);
    event Coin__BurnReserves(uint256 coinAmt, uint256 reserveBurn);
    event Coin__ProviderFee(address indexed to, uint256 quoteRaw, uint256 coinAmt);
    event Coin__TeamFee(address indexed to, uint256 quoteRaw, uint256 coinAmt);
    event Coin__TreasuryFee(address indexed to, uint256 quoteRaw, uint256 coinAmt);
    event Coin__Heal(address indexed who, uint256 quoteRaw);
    event Coin__Burn(address indexed who, uint256 coinAmt);
    event Coin__Borrow(address indexed who, address indexed to, uint256 quoteRaw);
    event Coin__Repay(address indexed who, address indexed to, uint256 quoteRaw);
    event Coin__TeamSet(address indexed newTeam);

    modifier notZeroInput(uint256 amount) { if (amount == 0) revert Coin__ZeroInput(); _; }
    modifier notZeroTo(address account) { if (account == address(0)) revert Coin__ZeroTo(); _; }
    modifier notExpired(uint256 expireTimestamp) { if (expireTimestamp != 0 && expireTimestamp < block.timestamp) revert Coin__Expired(); _; }
    modifier minTradeSize(uint256 amount) { if (amount < MIN_TRADE_SIZE) revert Coin__MinTradeSize(); _; }

    constructor(
        string memory name,
        string memory symbol,
        address _core,
        address _quote,
        address _owner,
        uint256 _initialSupply,
        uint256 _virtQuoteRaw
    ) ERC20(name, symbol) ERC20Permit(name) {
        core = _core;
        quote = _quote;

        uint8 _quoteDecimals = IERC20Metadata(_quote).decimals();
        if (_quoteDecimals > 18) revert Coin__QuoteDecimals();
        quoteDecimals = _quoteDecimals;
        quoteScale = 10 ** (18 - _quoteDecimals);

        maxSupply = _initialSupply;
        reserveCoinAmt = _initialSupply;
        reserveVirtQuoteWad = rawToWad(_virtQuoteRaw);

        team = _owner;
        _transferOwnership(_owner);
    }

    function setTeam(address newTeam) external onlyOwner {
        team = newTeam;
        emit Coin__TeamSet(newTeam);
    }

    // buy / sell / borrow / repay / heal / burn
    // (Copy the bodies from the original Token contract verbatim, applying these renames:
    //   - Token__Swap → Coin__Swap, etc. for all events
    //   - Token__... errors → Coin__...
    //   - tokenAmt → coinAmt, minTokenAmtOut → minCoinAmtOut, etc.
    //   - reserveTokenAmt → reserveCoinAmt
    // Keep the math identical.)

    // _processBuyFees: replace the content-fee branch with team-fee branch
    function _processBuyFees(uint256 quoteRaw, address provider) internal returns (uint256 remainingRaw) {
        remainingRaw = quoteRaw;
        uint256 feeRaw = (quoteRaw * FEE_AMOUNT) / DIVISOR;

        if (provider != address(0)) {
            IERC20(quote).safeTransfer(provider, feeRaw);
            emit Coin__ProviderFee(provider, feeRaw, 0);
            remainingRaw -= feeRaw;
        }

        IERC20(quote).safeTransfer(team, feeRaw);
        emit Coin__TeamFee(team, feeRaw, 0);
        remainingRaw -= feeRaw;

        address treasury = ICore(core).treasury();
        if (treasury != address(0)) {
            IERC20(quote).safeTransfer(treasury, feeRaw);
            emit Coin__TreasuryFee(treasury, feeRaw, 0);
            remainingRaw -= feeRaw;
        }

        return remainingRaw;
    }

    // _processSellFees: same shape, _mint instead of safeTransfer, emit (0, feeAmt) parameter ordering
    function _processSellFees(uint256 coinAmt, address provider) internal returns (uint256 remainingAmt) {
        remainingAmt = coinAmt;
        uint256 feeAmt = (coinAmt * FEE_AMOUNT) / DIVISOR;

        if (provider != address(0)) {
            _mint(provider, feeAmt);
            emit Coin__ProviderFee(provider, 0, feeAmt);
            remainingAmt -= feeAmt;
        }

        _mint(team, feeAmt);
        emit Coin__TeamFee(team, 0, feeAmt);
        remainingAmt -= feeAmt;

        address treasury = ICore(core).treasury();
        if (treasury != address(0)) {
            _mint(treasury, feeAmt);
            emit Coin__TreasuryFee(treasury, 0, feeAmt);
            remainingAmt -= feeAmt;
        }

        return remainingAmt;
    }

    // _healQuoteReserves, _burnTokenReserves, _afterTokenTransfer, _beforeTokenTransfer, _mint, _burn
    // (Copy verbatim from the original; only rename references to reserveCoinAmt and Coin__... events.)

    // View functions: getMarketPrice, getFloorPrice, getAccountCredit, getAccountTransferrable
    // (Copy verbatim, rename reserveTokenAmt → reserveCoinAmt, return name `tokenAmt` → `coinAmt`.)

    // rawToWad, wadToRaw: copy verbatim.
}
```

**Step 1:** Compile.

```bash
yarn compile
```

**Expected:** `Compiled X Solidity files successfully` (no errors). If errors mention missing `_processBuyFees` body, copy the body from the original `Token` and apply the renames.

**Step 2:** Commit.

```bash
git add packages/hardhat/contracts/Coin.sol
git commit -m "feat(hardhat): Coin contract (bonding curve ERC20)"
```

### Task 5.2: Verify all `Token__` references have been renamed

**Step 1:**

```bash
grep -n "Token__" packages/hardhat/contracts/Coin.sol || echo "no matches — clean"
```

**Expected:** "no matches — clean".

If matches, fix with `Edit` (replace `Token__` with `Coin__`), then recompile and re-grep.

**No commit unless changes were made.**

### Task 5.3: Verify no content/rewarder references

**Step 1:**

```bash
grep -in -E "content|rewarder|moderat" packages/hardhat/contracts/Coin.sol || echo "no matches — clean"
```

**Expected:** "no matches — clean".

If matches, remove and recompile.

---

## Phase 6: `packages/hardhat` Core.sol

### Task 6.1: `Core.sol`

**Files:**
- Create: `packages/hardhat/contracts/Core.sol`

**Source reference:** `/tmp/sources/stickrnet-hardhat/contracts/Core.sol`.

**Transformation:**
- Drop imports of `ITokenFactory`. Add import of `Coin`.
- Drop storage: `tokenFactory`, `contentFactory`, `rewarderFactory`, `CONTENT_MIN_INIT_PRICE`.
- Rename `index_Token` → `index_Coin`, `token_Index` → `coin_Index`.
- Drop setters for the dropped factories (`setTokenFactory`, `setContentFactory`, `setRewarderFactory`).
- Constructor: drop `_tokenFactory`, `_contentFactory`, `_rewarderFactory` params. Now just takes `(address _quote)`.
- `create(...)`: drop `uri`, `isModerated` params. Add `address owner` (was implicit before). Deploy `new Coin(...)` directly instead of calling `TokenFactory`. Update event signature.
- Event `Core__TokenCreated` → `Core__CoinCreated` with new field set: `(string name, string symbol, uint256 index, address coin, address indexed owner)` (drop `uri`, `content`, `rewarder`, `isModerated`).
- Drop `Core__ContentFactorySet`, `Core__RewarderFactorySet`, `Core__SaleFactorySet`, `Core__TokenFactorySet` events.

**Content:**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Coin} from "./Coin.sol";
import {ICoin} from "./interfaces/ICoin.sol";

contract Core is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant RESERVE_VIRT_QUOTE_RAW = 100_000 * 1e6;
    uint256 public constant MINIMUM_CORE_AMT_REQUIRED = 1e18;

    address public immutable quote;
    address public treasury;

    uint256 public index;
    mapping(uint256 => address) public index_Coin;
    mapping(address => uint256) public coin_Index;

    error Core__InsufficientCoreAmtRequired();

    event Core__CoinCreated(string name, string symbol, uint256 index, address coin, address indexed owner);
    event Core__TreasurySet(address newTreasury);

    constructor(address _quote) Ownable() {
        quote = _quote;
    }

    function create(
        string memory name,
        string memory symbol,
        address owner,
        uint256 quoteRawIn,
        uint256 coreCoinAmtRequired
    ) external returns (address coin) {
        if (coreCoinAmtRequired < MINIMUM_CORE_AMT_REQUIRED) revert Core__InsufficientCoreAmtRequired();

        index++;

        coin = address(new Coin(
            name,
            symbol,
            address(this),
            quote,
            owner,
            INITIAL_SUPPLY,
            RESERVE_VIRT_QUOTE_RAW
        ));

        index_Coin[index] = coin;
        coin_Index[coin] = index;

        IERC20(quote).safeTransferFrom(msg.sender, address(this), quoteRawIn);
        IERC20(quote).safeApprove(coin, 0);
        IERC20(quote).safeApprove(coin, quoteRawIn);
        ICoin(coin).buy(quoteRawIn, 0, 0, address(this), address(0));
        IERC20(coin).safeTransfer(owner, IERC20(coin).balanceOf(address(this)) - coreCoinAmtRequired);

        emit Core__CoinCreated(name, symbol, index, coin, owner);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit Core__TreasurySet(_treasury);
    }
}
```

**Step 1:** Compile.

```bash
yarn compile
```

**Expected:** clean compile.

**Step 2:** Commit.

```bash
git add packages/hardhat/contracts/Core.sol
git commit -m "feat(hardhat): Core launcher"
```

---

## Phase 7: `packages/hardhat` Router.sol

### Task 7.1: `Router.sol`

**Files:**
- Create: `packages/hardhat/contracts/Router.sol`

**Source reference:** `/tmp/sources/stickrnet-hardhat/contracts/Router.sol`.

**Transformation:**
- Drop imports of `IContent`, `IRewarder`. Drop `IToken` import → use `ICoin`.
- Rename `CORE_TOKEN_AMT_REQUIRED` → `CORE_COIN_AMT_REQUIRED`.
- Drop `Router__TokenCreated` → `Router__CoinCreated` (event payload: drop `uri`, `isModerated`, keep `(string name, string symbol, address indexed coin, address indexed creator, uint256 amountQuoteIn)`).
- Drop events: `Router__ContentCreated`, `Router__ContentCollected`.
- Rename `Router__Buy`/`Router__Sell` payloads: `address indexed token` → `address indexed coin`.
- Drop functions: `createContent`, `collectContent`, `getContentReward`, `notifyContentRewardAmount`, `_distributeFees`.
- Rename `createToken(...)` → `createCoin(...)`. Drop `uri`, `isModerated` params. Signature: `(string calldata name, string calldata symbol, uint256 amountQuoteIn)`.
- `buy`/`sell`: change first param `address token` → `address coin`. Body uses `ICoin` instead of `IToken`. Drop the `_distributeFees(token)` call (no content distribute).
- Keep `account_Affiliate` mapping, `_setAffiliate`, `Router__AffiliateSet`, `_safeApprove`, `withdrawStuckTokens`.

**Content:**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ICoin} from "./interfaces/ICoin.sol";

contract Router is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant CORE_COIN_AMT_REQUIRED = 1e18;

    address public immutable core;

    mapping(address => address) public account_Affiliate;

    event Router__CoinCreated(string name, string symbol, address indexed coin, address indexed creator, uint256 amountQuoteIn);
    event Router__Buy(address indexed coin, address indexed account, address indexed affiliate, uint256 amountQuoteIn, uint256 amountCoinOut);
    event Router__Sell(address indexed coin, address indexed account, address indexed affiliate, uint256 amountCoinIn, uint256 amountQuoteOut);
    event Router__AffiliateSet(address indexed account, address indexed affiliate);

    constructor(address _core) {
        core = _core;
    }

    function createCoin(string calldata name, string calldata symbol, uint256 amountQuoteIn) external nonReentrant returns (address coin) {
        address quote = ICore(core).quote();
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountQuoteIn);
        _safeApprove(quote, core, amountQuoteIn);
        coin = ICore(core).create(name, symbol, msg.sender, amountQuoteIn, CORE_COIN_AMT_REQUIRED);
        emit Router__CoinCreated(name, symbol, coin, msg.sender, amountQuoteIn);
    }

    function buy(address coin, address affiliate, uint256 amountQuoteIn, uint256 minAmountCoinOut, uint256 expireTimestamp) external nonReentrant {
        _setAffiliate(affiliate);
        address quote = ICore(core).quote();
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountQuoteIn);
        _safeApprove(quote, coin, amountQuoteIn);

        uint256 amountCoinOut = ICoin(coin).buy(amountQuoteIn, minAmountCoinOut, expireTimestamp, msg.sender, account_Affiliate[msg.sender]);

        uint256 remainingQuote = IERC20(quote).balanceOf(address(this));
        if (remainingQuote > 0) IERC20(quote).safeTransfer(msg.sender, remainingQuote);

        emit Router__Buy(coin, msg.sender, affiliate, amountQuoteIn, amountCoinOut);
    }

    function sell(address coin, address affiliate, uint256 amountCoinIn, uint256 minAmountQuoteOut, uint256 expireTimestamp) external nonReentrant {
        _setAffiliate(affiliate);
        IERC20(coin).safeTransferFrom(msg.sender, address(this), amountCoinIn);
        uint256 amountQuoteOut = ICoin(coin).sell(amountCoinIn, minAmountQuoteOut, expireTimestamp, msg.sender, account_Affiliate[msg.sender]);
        emit Router__Sell(coin, msg.sender, affiliate, amountCoinIn, amountQuoteOut);
    }

    function _setAffiliate(address affiliate) internal {
        if (account_Affiliate[msg.sender] == address(0) && affiliate != address(0)) {
            account_Affiliate[msg.sender] = affiliate;
            emit Router__AffiliateSet(msg.sender, affiliate);
        }
    }

    function _safeApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).safeApprove(spender, 0);
        IERC20(token).safeApprove(spender, amount);
    }

    function withdrawStuckTokens(address _token, address _to) external onlyOwner {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(_to, balance);
    }
}
```

**Step 1:** Compile. **Step 2:** Commit `feat(hardhat): Router`.

---

## Phase 8: `packages/hardhat` Multicall.sol

### Task 8.1: `Multicall.sol`

**Files:**
- Create: `packages/hardhat/contracts/Multicall.sol`

**Source reference:** `/tmp/sources/stickrnet-hardhat/contracts/Multicall.sol`.

**Transformation:**
- Rename `TokenData` struct → `CoinData`. Drop fields: `content`, `rewarder`, `isModerated`, `uri`, `contentApr`, `accountContentOwned`, `accountContentStaked`, `accountQuoteEarned`, `accountTokenEarned`, `accountIsModerator`. Rename `token` field → `coin`. Rename `accountTokenBalance` → `accountCoinBalance`.
- Add `address team;` field to `CoinData`, populated from `ICoin(coin).team()`.
- Drop `ContentData` struct entirely.
- Rename `getTokenData(address token, ...)` → `getCoinData(address coin, ...)`. Body uses `ICoin` instead of `IToken`. Drop all content/rewarder reads.
- Drop `getContentData(...)` entirely.
- Rename `sellTokenIn(...)` → `sellCoinIn(...)`. Body uses `ICoin`.
- Rename local `tokenAmtOut` → `coinAmtOut`, etc.

**Skeleton:**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {ICoin} from "./interfaces/ICoin.sol";
import {ICore} from "./interfaces/ICore.sol";

contract Multicall {
    using FixedPointMathLib for uint256;

    address public immutable core;

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

    constructor(address _core) {
        core = _core;
    }

    function getCoinData(address coin, address account) external view returns (CoinData memory data) {
        // (Copy the body of getTokenData from the source, drop all content/rewarder reads,
        // populate the new fields, use ICoin instead of IToken.)
        // Owner field comes from Ownable: data.owner = Ownable(coin).owner(); — or import IOwnable
        // (Solidity has no IOwnable in OZ; cast as `Ownable` from OZ or define a tiny interface.)
    }

    function buyQuoteIn(address coin, uint256 quoteRawIn, uint256 slippageTolerance) external view returns (uint256 coinAmtOut, uint256 slippage, uint256 minCoinAmtOut, uint256 autoMinCoinAmtOut) {
        // (Copy from source, rename tokenAmtOut → coinAmtOut, IToken → ICoin, reserveTokenAmt → reserveCoinAmt.)
    }

    function sellCoinIn(address coin, uint256 coinAmtIn, uint256 slippageTolerance) external view returns (uint256 quoteRawOut, uint256 slippage, uint256 minQuoteRawOut, uint256 autoMinQuoteRawOut) {
        // (Same — rename and use ICoin.)
    }
}
```

**Note on `data.owner`:** the original used `IContent(content).owner()` — for wavefront, the owner is on `Coin` itself (now `Ownable`). Use `Ownable(coin).owner()` or define a minimal `IOwnable` interface. Easiest:

```solidity
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
...
data.owner = Ownable(coin).owner();
```

**Step 1:** Compile. **Step 2:** Commit `feat(hardhat): Multicall read aggregator`.

---

## Phase 9: Hardhat compile sanity check

### Task 9.1: All-clean compile

**Step 1:** From repo root:

```bash
yarn compile
```

**Expected:** all four contracts compile (`Coin`, `Core`, `Router`, `Multicall`) plus `USDC` mock. No errors, no warnings beyond the expected `viaIR` notices.

**Step 2 (if ABI artifacts exist):**

```bash
ls packages/hardhat/artifacts/contracts/
```

Expected to contain `Coin.sol/`, `Core.sol/`, `Router.sol/`, `Multicall.sol/`, `mocks/`, `interfaces/`.

**No commit (artifacts are gitignored).**

---

## Phase 10: `packages/hardhat` tests

Each task: extract bonding-curve test cases from the originals (`test0.js`, `test1.js`, `test2.js`) into a focused test file. **Drop** any test logic that touches Content, Rewarder, auctions, moderation, or affiliate-on-content.

### Task 10.1: Test fixture helper

**Files:**
- Create: `packages/hardhat/tests/fixtures.js`

A reusable `deployWavefront()` async helper that:
1. Deploys USDC mock.
2. Deploys `Core` with USDC as `quote`.
3. Deploys `Router` with `core` as constructor arg.
4. Sets a treasury via `Core.setTreasury(...)`.
5. Returns `{ usdc, core, router, owner, signers }`.

**Commit:** `git add packages/hardhat/tests/fixtures.js && git commit -m "test(hardhat): deployment fixture"`

### Task 10.2: `Coin.test.js` — buy/sell

**Files:**
- Create: `packages/hardhat/tests/Coin.test.js`

**Tests to write (refer to `/tmp/sources/stickrnet-hardhat/tests/test1.js` for inspiration on amounts and flows):**
- "buy reverts on min trade size"
- "buy reverts after deadline"
- "buy reverts on slippage"
- "buy mints expected coin amount and updates reserves"
- "buy splits fees: provider, team, treasury, heal"
- "buy without provider sends provider's share to heal"
- "buy without treasury sends treasury's share to heal"
- "sell reverts on min trade size / deadline / slippage"
- "sell burns sender's coins, transfers quote, updates reserves"
- "sell splits fees identically to buy (mint to recipients)"

Use ethers v5 + waffle's `expectEvent` / chai matchers. Structure each test ~20 lines.

**Step 1:** Run `yarn test:hardhat` after writing each batch and verify they pass.

**Commit when full file passes:** `git add packages/hardhat/tests/Coin.test.js && git commit -m "test(hardhat): Coin buy/sell + fee split"`

### Task 10.3: `Coin.test.js` — borrow/repay/heal/burn (same file)

**Tests to add:**
- "borrow reverts when amount exceeds credit"
- "borrow transfers quote, updates debt, locks collateral (transfer fails)"
- "repay reduces debt, unlocks collateral"
- "heal accepts quote, shifts virt+real reserves"
- "burn reduces user balance, shifts maxSupply and reserves"

Run + commit `test(hardhat): borrow/repay/heal/burn`.

### Task 10.4: `Coin.test.js` — ownership + setTeam (same file)

**Tests:**
- "owner is creator after constructor"
- "team initial value equals owner"
- "setTeam reverts when called by non-owner"
- "setTeam updates team and emits event"
- "team fees route to current team after setTeam"

Run + commit `test(hardhat): ownership + setTeam`.

### Task 10.5: `Core.test.js`

**Files:**
- Create: `packages/hardhat/tests/Core.test.js`

**Tests:**
- "create reverts when coreCoinAmtRequired < MINIMUM_CORE_AMT_REQUIRED"
- "create deploys a new Coin and increments index"
- "create runs initial buy and forwards balance minus 1 coin to creator"
- "create emits Core__CoinCreated"
- "setTreasury onlyOwner; emits Core__TreasurySet"

Run + commit `test(hardhat): Core launcher`.

### Task 10.6: `Router.test.js`

**Files:**
- Create: `packages/hardhat/tests/Router.test.js`

**Tests:**
- "createCoin transfers quote in, deploys via Core, refunds dust"
- "buy sets affiliate on first call (only)"
- "buy passes account_Affiliate[msg.sender] as provider to Coin"
- "sell same"
- "expired deadline propagates"

Run + commit `test(hardhat): Router`.

---

## Phase 11: `packages/hardhat` deploy script

### Task 11.1: `scripts/deploy.js`

**Files:**
- Create: `packages/hardhat/scripts/deploy.js`

**Source reference:** `/tmp/sources/stickrnet-hardhat/scripts/deploy.js` is the template. Replace its multi-step deploy of `TokenFactory + ContentFactory + RewarderFactory + Core + Router + Multicall` with a simpler flow:

1. Deploy USDC mock (skip on real networks — use real USDC address).
2. Deploy `Core(quote)`.
3. Deploy `Router(core)`.
4. Deploy `Multicall(core)`.
5. `Core.setTreasury(<treasury address from env>)`.
6. Console-log all deployed addresses + verify on basescan with `hardhat verify`.

Pull the verification + retry-on-rate-limit pattern from the original.

**Commit:** `git add packages/hardhat/scripts/deploy.js && git commit -m "chore(hardhat): deploy script"`

### Task 11.2: `packages/hardhat/README.md`

Brief readme: how to install, compile, test, deploy. Reference design doc.

**Commit:** `git add packages/hardhat/README.md && git commit -m "docs(hardhat): readme"`

---

## Phase 12: `packages/foundry` setup

### Task 12.1: `foundry.toml`

**Files:**
- Create: `packages/foundry/foundry.toml`

**Source:** copy from `/tmp/sources/stickrnet-foundry/foundry.toml` verbatim.

**Commit:** `git add packages/foundry/foundry.toml && git commit -m "chore(foundry): foundry.toml"`

### Task 12.2: `packages/foundry/package.json`

**Files:**
- Create: `packages/foundry/package.json`

```json
{
  "name": "@wavefront/foundry",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "build": "forge build",
    "test": "forge test -vv",
    "coverage": "forge coverage"
  }
}
```

**Commit:** `git add packages/foundry/package.json && git commit -m "chore(foundry): package.json"`

### Task 12.3: Add submodules

**Step 1:**

```bash
git submodule add https://github.com/foundry-rs/forge-std packages/foundry/lib/forge-std
git submodule add https://github.com/transmissions11/solmate packages/foundry/lib/solmate
git submodule add https://github.com/OpenZeppelin/openzeppelin-contracts packages/foundry/lib/openzeppelin-contracts
```

**Step 2:** verify `.gitmodules` was created at the repo root.

**Commit:** `git add .gitmodules packages/foundry/lib && git commit -m "chore(foundry): forge-std, solmate, openzeppelin-contracts submodules"`

### Task 12.4: `remappings.txt` (if foundry.toml doesn't include them inline)

The source `foundry.toml` already has remappings inline. No separate file needed. Skip if `foundry.toml` already has:

```
remappings = [
    "solmate/=lib/solmate/src/",
    "@openzeppelin/=lib/openzeppelin-contracts/"
]
```

### Task 12.5: Foundry build sanity check (empty)

```bash
yarn build:foundry
```

Expected: `forge` runs but compiles nothing yet (no src files). No errors.

---

## Phase 13: `packages/foundry` contracts

Same logical files as the hardhat package, but extracted from `/tmp/sources/stickrnet-foundry/src/` (which has slightly different solmate import paths and naming — preserve those differences).

### Task 13.1: `interfaces/ICoin.sol`, `interfaces/ICore.sol`

Mirror Phase 3, but place in `packages/foundry/src/interfaces/`. Same content as hardhat versions (interfaces are pure ABI declarations and don't depend on import paths).

**Commit:** `git add packages/foundry/src/interfaces/ && git commit -m "feat(foundry): ICoin, ICore interfaces"`

### Task 13.2: `mocks/USDC.sol`

Foundry repo had no `mocks/` in `src/` — mocks lived in `test/mocks/`. Match that: create `packages/foundry/test/mocks/USDC.sol` (copy from `/tmp/sources/stickrnet-foundry/test/mocks/` if present, otherwise port the hardhat USDC mock).

**Commit:** `git add packages/foundry/test/mocks/USDC.sol && git commit -m "test(foundry): USDC mock"`

### Task 13.3: `Coin.sol`

Same transformation as Phase 5, but:
- Source: `/tmp/sources/stickrnet-foundry/src/TokenFactory.sol` (note the slightly different solmate import path).
- Solmate import: `import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";` (no `src/` prefix — that's the foundry-style remapping).

**Commit:** `git add packages/foundry/src/Coin.sol && git commit -m "feat(foundry): Coin contract"`

### Task 13.4: `Core.sol`, `Router.sol`, `Multicall.sol`

Mirror Phases 6/7/8 with the foundry-style imports.

**Commit each file separately:** `feat(foundry): Core`, `feat(foundry): Router`, `feat(foundry): Multicall`.

### Task 13.5: Foundry build check

```bash
yarn build:foundry
```

**Expected:** all contracts compile.

---

## Phase 14: `packages/foundry` tests

### Task 14.1: `test/Coin.t.sol`

**Source reference:** `/tmp/sources/stickrnet-foundry/test/Token.t.sol`. Extract test cases that exercise:
- buy / sell / fees / heal-after-buy / burn-after-sell
- borrow / repay / credit
- manual heal / manual burn
- ownership + setTeam

Apply the renames (`Token` → `Coin`, `tokenAmt` → `coinAmt`, `Token__*` events → `Coin__*`, swap content fee assertions with team fee assertions). Drop tests that touch content/rewarder/affiliate-on-content/moderation.

**Commit:** `git add packages/foundry/test/Coin.t.sol && git commit -m "test(foundry): Coin"`

### Task 14.2: `test/Core.t.sol`

Source: `/tmp/sources/stickrnet-foundry/test/Core.t.sol`. Same pattern.

**Commit:** `test(foundry): Core`

### Task 14.3: `test/Integration.t.sol`

Slim from `/tmp/sources/stickrnet-foundry/test/Integration.t.sol`. Keep flows: deploy stack → create coin → multiple buys/sells → borrow/repay → heal → burn. Drop any content/rewarder integration.

**Commit:** `test(foundry): integration`

### Task 14.4: Run all foundry tests

```bash
yarn test:foundry
```

**Expected:** all tests pass.

---

## Phase 15: `packages/foundry` deploy script

### Task 15.1: `script/Deploy.s.sol`

Source: `/tmp/sources/stickrnet-foundry/script/Deploy.s.sol`. Same simplified flow as hardhat: USDC (skip on prod) → Core → Router → Multicall → setTreasury.

**Commit:** `chore(foundry): deploy script`

### Task 15.2: `packages/foundry/README.md`

Brief readme with `forge build` / `forge test` / `forge script Deploy` instructions.

**Commit:** `docs(foundry): readme`

---

## Phase 16: `packages/subgraph` setup

### Task 16.1: `package.json`

**Files:**
- Create: `packages/subgraph/package.json`

```json
{
  "name": "@wavefront/subgraph",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "prepare": "node prepare.js",
    "codegen": "graph codegen",
    "build": "yarn prepare && yarn codegen && graph build",
    "test": "graph test",
    "deploy:base": "graph deploy --node https://api.studio.thegraph.com/deploy/ wavefront",
    "create-local": "graph create --node http://localhost:8020/ wavefront",
    "deploy-local": "graph deploy --node http://localhost:8020/ --ipfs http://localhost:5001 wavefront"
  },
  "devDependencies": {
    "@graphprotocol/graph-cli": "^0.79.0",
    "@graphprotocol/graph-ts": "^0.35.1",
    "matchstick-as": "^0.6.0"
  }
}
```

**Commit:** `chore(subgraph): package.json`

### Task 16.2: `tsconfig.json`, `docker-compose.yml`, `networks.json`, `prepare.js`

Copy from `/tmp/sources/stickrnet-subgraph/` verbatim, then:
- `networks.json`: replace network entries with placeholders for `localhost`, `base_sepolia`, `base` (set Core address to `0x0000...0000` and `startBlock: 0` initially).
- `prepare.js`: should already work as-is — it reads `networks.json` and templates `subgraph.template.yaml` → `subgraph.yaml`. If the source only handles a single network, leave as-is (it picks the first or matches an env var).

**Commit:** `chore(subgraph): tsconfig + networks + prepare script`

---

## Phase 17: `packages/subgraph` schema

### Task 17.1: `schema.graphql`

**Files:**
- Create: `packages/subgraph/schema.graphql`

Use the schema from §5.1 of the design doc verbatim. Key entities: `Directory`, `User`, `Coin`, `CoinPosition`, `Swap`, `CoinDayData`, `CoinHourData`, `CoinMinuteData`.

**Commit:** `feat(subgraph): schema`

---

## Phase 18: ABI sync (manual first time)

### Task 18.1: Run hardhat compile to produce artifacts

```bash
yarn compile
```

### Task 18.2: Copy ABIs into subgraph

**Files:**
- Create: `packages/subgraph/abis/Core.json`
- Create: `packages/subgraph/abis/Coin.json`

Manually for now (the sync script comes in Phase 22):

```bash
node -e 'const fs=require("fs"); const a=JSON.parse(fs.readFileSync("packages/hardhat/artifacts/contracts/Core.sol/Core.json")); fs.writeFileSync("packages/subgraph/abis/Core.json", JSON.stringify(a.abi, null, 2));'
node -e 'const fs=require("fs"); const a=JSON.parse(fs.readFileSync("packages/hardhat/artifacts/contracts/Coin.sol/Coin.json")); fs.writeFileSync("packages/subgraph/abis/Coin.json", JSON.stringify(a.abi, null, 2));'
```

**Commit:** `chore(subgraph): seed ABIs from hardhat`

---

## Phase 19: `packages/subgraph` template + mappings

### Task 19.1: `subgraph.template.yaml`

**Files:**
- Create: `packages/subgraph/subgraph.template.yaml`

**Source reference:** `/tmp/sources/stickrnet-subgraph/subgraph.template.yaml`.

**Transformation:**
- Drop `Content` template and `Rewarder` template entirely.
- In `Core` data source: drop event handlers `Core__ContentFactorySet`, `Core__RewarderFactorySet`, `Core__SaleFactorySet`, `Core__TokenFactorySet`. Rename `Core__TokenCreated` → `Core__CoinCreated` with new signature `(string,string,uint256,address,indexed address)` (no `uri`, no `content`, no `rewarder`, no `isModerated`).
- Rename `Token` template → `Coin` template. Update file paths and ABI ref. Drop event handlers `Approval`, `DelegateChanged`, `DelegateVotesChanged`, `EIP712DomainChanged`, `Token__ContentFee`. Rename remaining `Token__*` events to `Coin__*`. Add `Coin__TeamFee` and `Coin__TeamSet` handlers.
- Update entity lists per the new schema.

**Commit:** `feat(subgraph): subgraph template`

### Task 19.2: `src/constants.ts`

**Source:** `/tmp/sources/stickrnet-subgraph/src/constants.ts`.

**Transformation:**
- Drop content/initial-content related constants (`INITIAL_PRICE`, `INITIAL_TOTAL_SUPPLY`, `INITIAL_TOKEN_RESERVE` should keep names — these are coin reserves now). Rename references token → coin where appropriate.
- Keep `CORE_ADDRESS`, `ZERO_BD`, `ZERO_BI`, `ONE_BI`, `ALMOST_ZERO_BD`, `ADDRESS_ZERO`.
- Update `INITIAL_QUOTE_VIRT_RESERVE`, `INITIAL_LIQUIDITY`, `INITIAL_MARKET_CAP` to match new contract constants.

**Commit:** `feat(subgraph): constants`

### Task 19.3: `src/helpers.ts`

Copy verbatim from source.

**Commit:** `feat(subgraph): helpers`

### Task 19.4: `src/core.ts`

**Source:** `/tmp/sources/stickrnet-subgraph/src/core.ts`.

**Transformation:**
- Drop handlers: `handleCore__ContentFactorySet`, `handleCore__RewarderFactorySet`, `handleCore__SaleFactorySet`, `handleCore__TokenFactorySet`.
- Rename `handleCore__TokenCreated` → `handleCore__CoinCreated`. Body: drop creation of `Content` / `Rewarder` entities. Drop reads of `event.params.content`, `event.params.rewarder`, `event.params.uri`, `event.params.isModerated`. Use the new entity field set on `Coin` (initialize all the new revenue counters to ZERO_BD, drop dropped fields).
- Drop import of `Content as ContentTemplate`, `Rewarder as RewarderTemplate`. Rename `Token as TokenTemplate` → `Coin as CoinTemplate`.

**Commit:** `feat(subgraph): core mapping`

### Task 19.5: `src/coin.ts` (renamed from `token.ts`)

**Source:** `/tmp/sources/stickrnet-subgraph/src/token.ts`.

**Transformation:**
- Rename file: `token.ts` → `coin.ts`.
- Drop handlers: `handleApproval`, `handleDelegateChanged`, `handleDelegateVotesChanged`, `handleEIP712DomainChanged`, `handleToken__ContentFee`.
- Rename all remaining `handleToken__*` → `handleCoin__*`.
- Add `handleCoin__TeamFee` (writes `teamRevenueQuote`/`teamRevenueCoin` on the `Coin` entity).
- Add `handleCoin__TeamSet` (updates `Coin.team`).
- Rename event imports from `../generated/templates/Token/Token` → `../generated/templates/Coin/Coin`.
- Update field name references on entities: `tokenReserve` → `coinReserve`, `holderRevenueToken` → `holderRevenueCoin`, `treasuryRevenueToken` → `treasuryRevenueCoin`, `contentRevenue*` → `teamRevenue*`, drop `creatorEarned`, `holderEarned`, etc.
- In `handleCoin__Swap`: rename `swap.tokenIn` → `swap.coinIn`, `swap.tokenOut` → `swap.coinOut`. Rename day/hour/minute entities `TokenDayData` → `CoinDayData` etc.
- In `handleTransfer`: rename position field `whoTokenPosition` → `whoCoinPosition` (style only, but consistent), drop content/affiliate field initializations no longer in schema.

**Commit:** `feat(subgraph): coin mapping`

### Task 19.6: Generate types and check build

```bash
yarn workspace @wavefront/subgraph prepare
yarn workspace @wavefront/subgraph codegen
yarn workspace @wavefront/subgraph build
```

**Expected:** `Build completed: ...` with no type errors.

If type errors, fix the mappings (most likely a leftover field reference to a dropped entity or a renamed field).

---

## Phase 20: `packages/subgraph` tests

### Task 20.1: `tests/coin-utils.ts` and `tests/core-utils.ts`

Source: `/tmp/sources/stickrnet-subgraph/tests/token-utils.ts` and `core-utils.ts`. Apply renames + drop content/rewarder/affiliate-on-content references.

**Commit:** `test(subgraph): test utils`

### Task 20.2: `tests/coin.test.ts`

Source: `/tmp/sources/stickrnet-subgraph/tests/token.test.ts`. Rename + drop content tests.

**Commit:** `test(subgraph): coin handlers`

### Task 20.3: `tests/core.test.ts`

Source + transformation as above.

**Commit:** `test(subgraph): core handlers`

### Task 20.4: Run subgraph tests

```bash
yarn test:subgraph
```

**Expected:** all matchstick tests pass.

---

## Phase 21: `packages/subgraph` README

### Task 21.1: README

Document: networks.json filling, ABI sync command, prepare/codegen/build/deploy flow, how to query the resulting subgraph.

**Commit:** `docs(subgraph): readme`

---

## Phase 22: Root scripts

### Task 22.1: `scripts/sync-abis.js`

**Files:**
- Create: `scripts/sync-abis.js`

```js
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const ARTIFACT_DIR = path.join(__dirname, "..", "packages", "hardhat", "artifacts", "contracts");
const ABI_DIR = path.join(__dirname, "..", "packages", "subgraph", "abis");

const TARGETS = [
  { artifact: "Coin.sol/Coin.json", abi: "Coin.json" },
  { artifact: "Core.sol/Core.json", abi: "Core.json" },
];

if (!fs.existsSync(ABI_DIR)) fs.mkdirSync(ABI_DIR, { recursive: true });

let synced = 0;
for (const t of TARGETS) {
  const src = path.join(ARTIFACT_DIR, t.artifact);
  if (!fs.existsSync(src)) {
    console.error(`✖ missing ${src}. Run \`yarn compile\` first.`);
    process.exit(1);
  }
  const json = JSON.parse(fs.readFileSync(src, "utf8"));
  const out = path.join(ABI_DIR, t.abi);
  fs.writeFileSync(out, JSON.stringify(json.abi, null, 2));
  console.log(`✓ ${t.abi}`);
  synced++;
}
console.log(`Synced ${synced} ABIs to ${ABI_DIR}.`);
```

**Step 1:** Verify it works:

```bash
yarn compile
yarn sync-abis
```

**Expected:** `✓ Coin.json` and `✓ Core.json` printed; `packages/subgraph/abis/Coin.json` and `Core.json` updated.

**Commit:** `chore: sync-abis script`

---

## Phase 23: End-to-end check + final README polish

### Task 23.1: Full test run

```bash
yarn test
```

**Expected:** hardhat tests pass, foundry tests pass, subgraph tests pass.

If any fail, fix in place (root cause, not bypass), commit fix, re-run.

### Task 23.2: README polish

Refine the top-level `README.md` with quickstart, architecture summary, links, deployment instructions, badges (optional).

**Commit:** `docs: top-level README polish`

### Task 23.3: Push final state

```bash
git push origin main
```

If submodules were added: ensure `git submodule update --init --recursive` is documented in the README.

---

## Conventions reminder (apply throughout every task)

- **Compile / test before committing.** Never commit code that doesn't compile or whose tests fail.
- **Frequent commits.** One logical change per commit. Use the conventional-commit prefixes (`feat:`, `chore:`, `docs:`, `test:`).
- **Apply both rename rules every time:** `Token` → `Coin` AND drop content/rewarder/moderation. After writing each file, grep for `Token__`, `Content`, `Rewarder`, `Moderator`, `isModerated`, `uri` and confirm the only matches are intentional ones (`tokenURI` is fine if inherited from ERC721 — but no ERC721 in wavefront).
- **No new abstractions.** This is a port-and-strip. Don't refactor the curve math, don't add helpers, don't introduce upgradeability.
- **No comments narrating what.** The contracts and mappings should read cleanly without `// extracted from stickrnet` style annotations. The git history records the provenance.

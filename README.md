# wavefront-monorepo

A bonding-curve token launcher.

A user calls one function and gets a fresh ERC20 with built-in market-making, a four-way fee split, an automatic floor-price ratchet, and zero-rate collateralized borrowing against held coins. No external liquidity needed at launch.

## Packages

- [`packages/hardhat`](packages/hardhat) — Solidity contracts with Hardhat tooling. 35 tests.
- [`packages/foundry`](packages/foundry) — same contracts, independently maintained, with Foundry tooling. 17 tests.
- [`packages/subgraph`](packages/subgraph) — The Graph subgraph indexing the deployed contracts. Matchstick test passing.

## Quickstart

```bash
git clone https://github.com/Heesho/wavefront-monorepo.git
cd wavefront-monorepo
git submodule update --init --recursive   # for foundry deps
yarn install
yarn compile          # hardhat compile
yarn build:foundry    # forge build
yarn test             # all three test suites
```

## How the bonding curve works

Read [`docs/bonding-curve.md`](docs/bonding-curve.md) for the full math, mechanics, and design rationale. Summary:

- Virtual + real reserves on the quote side. The virtual reserve is a price floor anchor; the real reserve grows from buys.
- Constant-product invariant `(virt + real) * coinReserve = k` for trade math.
- 1% fee per trade, split 20/20/20 to **provider** (affiliate), **team** (per-coin), **treasury** (per-protocol). The remaining 40% is **healed** (buys) or **burned** (sells), pushing the floor up.
- Public `heal(quoteAmount)` and `burn(coinAmount)` lets anyone donate to the curve, ratcheting the floor.
- Holders can **borrow** quote against their coins at zero interest with no liquidations — the credit limit is bounded by what the curve owes at floor price.

## Repo layout

```
wavefront-monorepo/
├── package.json              yarn workspaces root
├── README.md                 this file
├── LICENSE                   MIT
├── .gitignore
├── .gitmodules               foundry submodules
├── docs/
│   ├── bonding-curve.md      detailed mechanics walkthrough
│   └── plans/
│       ├── 2026-05-01-wavefront-design.md
│       └── 2026-05-01-wavefront-implementation.md
├── scripts/
│   └── sync-abis.js          syncs hardhat ABIs into the subgraph
└── packages/
    ├── hardhat/              JS tests, ethers v5, deploy script
    ├── foundry/              Solidity tests via forge-std, deploy script
    └── subgraph/             AssemblyScript mappings, matchstick tests
```

## Top-level scripts

| Command | What it does |
|---|---|
| `yarn compile` | Hardhat compile |
| `yarn build:foundry` | `forge build` |
| `yarn test` | Run hardhat + foundry + subgraph tests |
| `yarn test:hardhat` | Just hardhat |
| `yarn test:foundry` | Just foundry |
| `yarn test:subgraph` | Just matchstick |
| `yarn sync-abis` | Refresh `packages/subgraph/abis/` from hardhat artifacts |
| `yarn subgraph:prepare` | Generate `subgraph.yaml` from `subgraph.template.yaml` + `networks.json` |
| `yarn subgraph:build` | Build the subgraph |

## Deploying

See per-package READMEs:

- [`packages/hardhat/README.md`](packages/hardhat/README.md) — Hardhat deploy to Base Sepolia
- [`packages/foundry/README.md`](packages/foundry/README.md) — Forge script deploy
- [`packages/subgraph/README.md`](packages/subgraph/README.md) — The Graph deployment, ABI sync, network targeting

## Contracts at a glance

- `Coin.sol` — bonding curve ERC20 (`Ownable` + `Permit` + `Votes` + `ReentrancyGuard`). Buy / sell / borrow / repay / heal / burn. Mutable `team` address, set by `Ownable` owner.
- `Core.sol` — owner-controlled launcher. Holds the quote token, registry of created coins, treasury address. Deploys `Coin` instances directly.
- `Router.sol` — user-facing entry. `createCoin`, `buy`, `sell`. Persists per-account affiliate.
- `Multicall.sol` — read aggregator with slippage helpers (`buyQuoteIn`, `sellCoinIn`).
- `mocks/USDC.sol` — 6-decimal mock for tests and dev deployments.

Interfaces in `interfaces/ICoin.sol` and `interfaces/ICore.sol`.

## Origin

This monorepo extracts the bonding-curve mechanics from the [stickrnet](https://github.com/Heesho/stickrnet-hardhat) codebase, drops the content + rewarder + moderation systems built on top of it, and renames `Token` → `Coin` throughout. The full design rationale is in [`docs/plans/2026-05-01-wavefront-design.md`](docs/plans/2026-05-01-wavefront-design.md); the task-by-task implementation plan is in [`docs/plans/2026-05-01-wavefront-implementation.md`](docs/plans/2026-05-01-wavefront-implementation.md).

## License

MIT. See [`LICENSE`](LICENSE).

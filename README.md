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

## How the bonding curve works

A detailed walkthrough of the math, virtual reserves, fee split, heal/burn mechanics, and collateralized borrowing is in [`docs/bonding-curve.md`](docs/bonding-curve.md).

## Design doc

See [`docs/plans/2026-05-01-wavefront-design.md`](docs/plans/2026-05-01-wavefront-design.md).

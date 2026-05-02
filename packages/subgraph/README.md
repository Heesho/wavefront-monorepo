# @wavefront/subgraph

Graph Protocol subgraph for the Wavefront contracts.

Indexes `Core` and `Coin` instances created via the launcher: directory stats, per-coin reserves and prices, swaps, holder positions, day/hour/minute price snapshots.

See [`schema.graphql`](schema.graphql) for the full entity model and [`subgraph.template.yaml`](subgraph.template.yaml) for the data-source/event mapping.

## Setup

From the monorepo root:

```bash
yarn install
```

This package uses `nohoist` so the matchstick test runner can find its AssemblyScript dependencies inside `packages/subgraph/node_modules/`.

## ABI sync

The subgraph indexes events from `Core.sol` and `Coin.sol`. The committed ABIs in `abis/` must match the deployed bytecode. After any change to those contracts, regenerate the ABIs from the hardhat artifacts:

```bash
# From the repo root:
yarn compile
yarn sync-abis
```

That overwrites `abis/Core.json` and `abis/Coin.json` with the latest ABIs.

## Network targeting

`networks.json` ships with placeholder entries for `localhost`, `base-sepolia`, and `base`. Fill in the deployed `Core` address and start block for whichever network you want to deploy on:

```json
{
  "base-sepolia": {
    "Core": {
      "address": "0xYourDeployedCoreAddress",
      "startBlock": 12345678
    }
  }
}
```

Then run the corresponding prepare script to generate `subgraph.yaml`:

```bash
yarn workspace @wavefront/subgraph prepare:base-sepolia
yarn workspace @wavefront/subgraph prepare:base
yarn workspace @wavefront/subgraph prepare:localhost
```

`subgraph.yaml` is gitignored — it's a generated file and should not be edited by hand.

## Codegen, build, test

```bash
yarn workspace @wavefront/subgraph codegen   # generate AssemblyScript types from schema + ABIs
yarn workspace @wavefront/subgraph build     # runs prepare + codegen + graph build
yarn workspace @wavefront/subgraph test      # matchstick unit tests
```

The root has shortcuts: `yarn subgraph:prepare` (defaults to base-sepolia via the package.json script), `yarn subgraph:build`, `yarn test:subgraph`.

## Deploy

To The Graph Studio:

```bash
yarn workspace @wavefront/subgraph deploy:base
```

To a local Graph Node:

```bash
yarn workspace @wavefront/subgraph create-local
yarn workspace @wavefront/subgraph deploy-local
```

## Adding handlers

When you add a new event to `Coin.sol` (or `Core.sol`):

1. Re-run `yarn compile` and `yarn sync-abis` to refresh the ABIs.
2. Add a new `eventHandlers` entry in `subgraph.template.yaml`.
3. Implement the handler function in `src/coin.ts` (or `src/core.ts`).
4. If the handler reads or writes a new entity, add it to `schema.graphql`.
5. Re-run `yarn workspace @wavefront/subgraph build` and verify it completes.
6. Add a matchstick test in `tests/`.

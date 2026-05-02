# @wavefront/foundry

Wavefront Solidity contracts with Foundry tooling. Same contracts as `@wavefront/hardhat`, independently maintained — solmate import path differs because of the lib remapping.

## Contracts

- `src/Coin.sol`
- `src/Core.sol`
- `src/Router.sol`
- `src/Multicall.sol`
- `src/interfaces/ICoin.sol`
- `src/interfaces/ICore.sol`
- `test/mocks/USDC.sol`

## Submodules

This package uses git submodules pinned at the monorepo root:

- `lib/forge-std` — Foundry's standard library
- `lib/solmate` — `FixedPointMathLib`
- `lib/openzeppelin-contracts` — pinned to **v4.9.6** (do not bump to 5.x — breaking)

After cloning the monorepo, initialize submodules:

```bash
git submodule update --init --recursive
```

## Build / test

```bash
yarn workspace @wavefront/foundry build       # forge build
yarn workspace @wavefront/foundry test        # forge test -vv
yarn workspace @wavefront/foundry coverage    # forge coverage
```

The root has `yarn build:foundry` and `yarn test:foundry` shortcuts.

## Deploy

Set environment variables (e.g. via `.env` loaded into your shell):

```
PRIVATE_KEY=0x...
TREASURY_ADDRESS=0x...    # optional
QUOTE_ADDRESS=0x...       # optional; if unset, deploys a USDC mock
ETHERSCAN_API_KEY=...     # for verification
```

Deploy to Base Sepolia:

```bash
cd packages/foundry
forge script script/Deploy.s.sol:Deploy \
  --rpc-url base_sepolia \
  --broadcast \
  --verify
```

The script prints each deployed address to stdout.

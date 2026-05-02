# @wavefront/hardhat

Wavefront Solidity contracts with Hardhat tooling.

## Contracts

- `Coin.sol` — bonding curve ERC20 (Ownable + Permit + Votes + ReentrancyGuard). Buy / sell / borrow / repay / heal / burn.
- `Core.sol` — owner-controlled launcher. Deploys `Coin` instances, holds the protocol treasury.
- `Router.sol` — user-facing entry. `createCoin`, `buy`, `sell`, with affiliate.
- `Multicall.sol` — read aggregator with slippage helpers.
- `mocks/USDC.sol` — 6-decimal mock for tests and dev deployments.

See [`../../docs/plans/2026-05-01-wavefront-design.md`](../../docs/plans/2026-05-01-wavefront-design.md) for the design.

## Install

From the monorepo root:

```bash
yarn install
```

## Scripts

```bash
yarn workspace @wavefront/hardhat compile        # hardhat compile
yarn workspace @wavefront/hardhat test           # run tests
yarn workspace @wavefront/hardhat coverage       # coverage report
yarn workspace @wavefront/hardhat node           # start a local hardhat node
yarn workspace @wavefront/hardhat deploy:sepolia # deploy to Base Sepolia
```

The root also has shortcuts: `yarn compile`, `yarn test:hardhat`.

## Deploy

Copy `.env.example` to `.env` and fill in:

```
PRIVATE_KEY=0x...
RPC_URL=https://sepolia.base.org
SCAN_API_KEY=...
TREASURY_ADDRESS=0x...     # optional; sets Core.treasury after deploy
QUOTE_ADDRESS=0x...        # optional; if unset, deploys a USDC mock as quote
```

Then:

```bash
yarn workspace @wavefront/hardhat deploy:sepolia
```

The script deploys (in order): USDC mock (only if `QUOTE_ADDRESS` is unset) → `Core` → `Router` → `Multicall`, verifies each on basescan, and finally calls `Core.setTreasury(...)` if `TREASURY_ADDRESS` is provided.

## Sync ABIs to subgraph

After contract changes, regenerate the subgraph ABIs from the root:

```bash
yarn compile && yarn sync-abis
```

This copies `Core.json` and `Coin.json` into `packages/subgraph/abis/`.

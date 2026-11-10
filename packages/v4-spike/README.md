# @wavefront/v4-spike

Feasibility spike, **not production code**: can wavefront's bonding curve, floor ratchet and
zero-interest borrowing run on real Uniswap v4 liquidity, so that coins trade through the standard
`PoolManager` instead of a custom contract?

## What is here

- `contracts/WavefrontHook.sol` — one v4 pool per coin; the hook owns the pool's only liquidity
  position (floor price → max tick), re-creates it after every swap to apply heal/burn, and moves its
  lower tick to lend quote.
- `contracts/SpikeTokens.sol` — coin with the collateral transfer lock, and a 6-decimal quote mock.
- `contracts/SpikeRouter.sol` — a minimal swap router that knows nothing about wavefront.
- `test/spike.test.js` — runs one trade sequence against both the real v4 `PoolManager` + hook and
  the current `Core`/`Router`/`Coin` (loaded from `packages/hardhat/artifacts`) and compares them.

## Run

```bash
yarn workspace @wavefront/hardhat compile   # the reference artifacts
yarn workspace @wavefront/v4-spike test
TICK_SPACING=60 yarn workspace @wavefront/v4-spike test
```

## Known gaps

- No audit, no fuzzing, no reentrancy review; rounding is only argued, not proven.
- Tick spacing 1 and 10 pass everything; 60 and 200 fail the borrowing-under-stress cases.
- Hook address and coin address are placed with test cheats; production needs CREATE2 salt mining.
- Fees are pull-based (`claimFees`, `claimCoinFees`) and burns are deferred by one rebalance, because
  the hook cannot physically move tokens the swapper has not paid yet inside `afterSwap`.
- Swap gas grows with the size of the price move at tick spacing 1 (2.6M gas to sell the whole range);
  at spacing 10 it stays near-constant (0.43M to 0.64M).
- Public `heal`/`burn`, exact-output swaps, Permit/Votes and multi-coin isolation are not covered.

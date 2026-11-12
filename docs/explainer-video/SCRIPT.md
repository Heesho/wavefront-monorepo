# Wavefront on Uniswap v4: narration script

Spoken text is what the narrator reads; captions are what is burned into the video (they show exact numbers where the narration rounds them). Times are from the final render. Code references are read from the repository by anchor text at render time (2026-11-12).

Numbers come from `test/Scenario.t.sol` run in a scratch copy of `packages/v4` whose `WavefrontHook.sol`, `libraries/CurveMath.sol` and `Coin.sol` are identical to the repository's. Launch: 1,000,000,000 WAVE, 100,000 USDC virtual quote, 2% fee, tick spacing 10, creator's first buy 10,000 USDC.

## 0:00 · Introduction

_How one hook keeps v1's bonding curve inside an ordinary v4 pool_

**0:00** · On screen: Title card

- **0:00** How Wavefront works on Uniswap v4, deeply enough that you can open the hook's source code and follow it.
  - caption: How Wavefront works on Uniswap v4, deeply enough that you can open WavefrontHook.sol and follow it.
- **0:06** Every number was recorded from a real run of the contracts. Every snippet shows its file and line.


## 0:12 · 1. v1 in a minute

_Reserves, the curve, the floor, heal and burn_

**0:12** · Title card (silent, 3.2 s)

**0:16** · On screen: v1 curve diagram (illustrative reserves, exaggerated where noted) · `packages/foundry/src/Coin.sol:30-34`, `packages/foundry/src/Coin.sol:339-348`

- **0:16** Version one is one contract, Coin dot sol. It stores no price, only reserves: real quote paid in, a virtual quote that sets the depth, coins in the pool, and the max supply.
  - caption: v1 is one contract, Coin.sol. It stores no price, only reserves: real quote paid in, a virtual quote that sets the depth, coins in the pool, and the max supply.
- **0:30** The price is virtual plus real quote, over the coins in the pool. A buy moves along a constant-product curve.
- **0:39** The floor is virtual quote over max supply: roughly what the last seller gets once everyone else has sold.

**0:47** · On screen: v1 curve diagram (illustrative reserves, exaggerated where noted) · `packages/foundry/src/Coin.sol:289-301`

- **0:47** Each trade pays a two percent fee. A fifth goes to the team, and a fifth to the treasury. On a buy, the rest is a heal: quote added to the reserves, which lifts the whole curve.
  - caption: Each trade pays a 2% fee. A fifth goes to the team, a fifth to the treasury. On a buy, the rest is a heal: quote added to the reserves, which lifts the whole curve.

**1:03** · On screen: v1 curve diagram (illustrative reserves, exaggerated where noted) · `packages/foundry/src/Coin.sol:303-314`

- **1:04** On a sell, the rest is a burn: coins leave circulation, the pool gives up coins in the same proportion, and the floor rises again.
- **1:13** Remember three numbers: the real quote, the coins in the pool, and the supply. Version four keeps exactly those.
  - caption: Remember three numbers: the real quote, the coins in the pool, and the supply. v4 keeps exactly those.


## 1:22 · 2. Uniswap v4 in two minutes

_PoolManager, unlock and deltas, ticks, positions, hooks, claims_

**1:22** · Title card (silent, 3.2 s)

**1:26** · On screen: PoolManager diagram with the deltas of Alice's buy

- **1:26** Version four keeps every pool inside one contract, the PoolManager. Routers, wallets and hooks all call into it.
  - caption: v4 keeps every pool inside one contract, the PoolManager. Routers, wallets and hooks all call into it.
- **1:36** Nothing happens until a caller unlocks it. Inside, every swap and liquidity change is recorded as a delta: a tab of who owes what.
- **1:47** Tokens go in with settle and out with take. When the unlock ends, every tab must be zero, or the whole transaction reverts.
- **1:57** A credit can also be kept as an E R C sixty-nine oh nine claim: a balance held inside the PoolManager. The hook uses these a lot.
  - caption: A credit can also be kept as an ERC-6909 claim, a balance held inside the PoolManager. The hook uses these a lot.

**2:10** · On screen: Tick ruler near the recorded floor and a liquidity position

- **2:11** Prices live on ticks, one basis point apart. With a tick spacing of ten, a position's edges sit on a grid about a tenth of a percent apart.
  - caption: Prices live on ticks, each a factor of 1.0001. With a tick spacing of 10, a position's edges sit on a grid about 0.1% apart.
- **2:22** A position covers a range of ticks. Below the price it holds the quote token, above it the coin. A swap walks the price along it.

**2:34** · On screen: Hook permissions card · `packages/v4/src/WavefrontHook.sol:308-325`, `packages/v4/src/WavefrontHook.sol:327-330`

- **2:34** A hook is called by the pool at fixed points. This one asks for three. Two just revert, so only the hook can create these pools or add liquidity. The third, after swap, does all the work.
  - caption: A hook is called by the pool at fixed points. This one asks for three: two just revert, so only the hook can create these pools or add liquidity. The third, afterSwap, does all the work.
- **2:49** One practical cost: Uniswap Labs' router only routes through after swap hooks once they are allow-listed by hand.
  - caption: One practical cost: Uniswap Labs' router only routes through afterSwap hooks once they are allowlisted by hand.


## 2:58 · 3. The key idea

_v1's curve is one liquidity position_

**2:58** · Title card (silent, 3.2 s)

**3:01** · On screen: v1 reserves as one position · `packages/v4/src/libraries/CurveMath.sol:11-17`

- **3:01** Everything rests on this: v1's curve is exactly one concentrated-liquidity position, from the floor price to the top of v4's range.
- **3:11** With liquidity L, s the square root of the price, and a the square root of the floor: virtual quote is L times a, max supply is L over a, real quote is L times s minus a, and pool coins are L over s.
  - caption: With liquidity L, s the square root of the price and a that of the floor: virtual quote is L·a, max supply L/a, real quote L·(s − a), and pool coins L/s.
- **3:25** So the hook owns a single position, and any v4 router or scanner sees an ordinary pool.

**3:32** · On screen: Floor formula and its derivation · `packages/v4/src/libraries/CurveMath.sol:76-94`

- **3:32** From three reserves, real quote X, pool coins Y, and circulating coins C, the function sqrt floor for gives v1's floor: the square root of X times Y, over C times S.
  - caption: From three reserves, real quote X, pool coins y and circulating coins C, sqrtFloorFor gives v1's floor: √(X·y / (C·S)), where S = C + y.
- **3:49** A heal grows X; a burn shrinks C and y together. Neither needs a formula of its own: change the reserves and the floor follows.


## 3:59 · 4. A buy, step by step

__afterSwap · _accountFees · _ratchetDue_

**3:59** · Title card (silent, 3.2 s)

**4:02** · On screen: The recorded market · The hook's books for WAVE (recorded)

- **4:03** The recorded coin, WAVE: one billion supply, a hundred thousand dollars of virtual quote, a two percent fee, and a ten thousand dollar buy by its creator at launch.
  - caption: The recorded coin, WAVE: one billion supply, 100,000 USDC of virtual quote, a 2% fee, and a 10,000 USDC buy by its creator at launch.

**4:16** · On screen: Call order inside Alice's buy · The hook's books for WAVE (recorded)

- **4:16** Alice buys with two hundred dollars. She calls the router, which unlocks the PoolManager and, in its callback, swaps.
  - caption: Alice buys with 200 USDC. She calls the router, which unlocks the PoolManager and, in its callback, swaps.
- **4:25** Plain v4 maths: the pool keeps two percent, four dollars, as the position's fee, and the rest buys one point six million WAVE. Nothing has been paid yet.
  - caption: Plain v4 maths: the pool keeps 2%, 4.00 USDC, as the position's fee, and the rest buys 1,603,254 WAVE. Nothing has been paid yet.
- **4:36** Then the PoolManager calls the hook's after swap.
  - caption: Then the PoolManager calls the hook's afterSwap.

**4:40** · On screen: Call order inside Alice's buy · `packages/v4/src/WavefrontHook.sol:342-357`

- **4:41** After swap first destroys coins an earlier rebalance left in the burn queue. Here, that is only rounding dust.
  - caption: afterSwap first destroys coins an earlier rebalance left in the burn queue; here, only rounding dust.
- **4:49** Then it touches its position with a liquidity change of zero, which makes v4 pay out the fees the position earned.

**4:58** · On screen: Fee split · `packages/v4/src/WavefrontHook.sol:382-394`

- **4:59** Account fees credits twenty percent each to the team and the treasury, to claim later. The other sixty percent, two dollars forty, becomes pending heal.
  - caption: _accountFees credits 20% each to the team and the treasury, to claim later. The other 60%, 2.40 USDC, becomes pending heal.
- **5:09** It keeps the fee as claims, not tokens. Alice has not paid yet, so the money is not in the PoolManager to take.
  - caption: It keeps the fee as claims, not tokens: Alice has not paid yet, so the USDC is not in the PoolManager to take.

**5:18** · On screen: Recorded _ratchetDue / _applyPending numbers · `packages/v4/src/WavefrontHook.sol:396-410`

- **5:18** Ratchet due rebuilds v1's three numbers, adds what is pending, and finds the floor they would support.
  - caption: _ratchetDue rebuilds v1's three numbers, adds what is pending, and finds the floor they would support: tick −368,305.9.
- **5:25** That is only four ticks above the floor, which moves in steps of ten. Not yet, so nothing else happens.
  - caption: The floor is on −368,310 and moves only in steps of 10. Not yet, so nothing else happens.

**5:33** · On screen: Call order inside Alice's buy · `packages/v4/src/WavefrontRouter.sol:144-155`

- **5:34** Back in the router, two hundred dollars is pulled from Alice and settled.
  - caption: Back in the router: 200 USDC is pulled from Alice and settled.
- **5:38** Her coins are taken out, every delta is zero, and the unlock closes. A buy like this costs about eighty thousand gas.
  - caption: Her coins are taken out, every delta is zero, and the unlock closes. A buy like this costs about 80k gas.


## 5:49 · 5. The rebalance

__rebalance · _applyPending · _removePosition · _addPosition_

**5:49** · Title card (silent, 3.2 s)

**5:52** · On screen: Recorded _ratchetDue / _applyPending numbers · The hook's books for WAVE (recorded)

- **5:52** Bob buys with three thousand dollars. The pool keeps sixty, and pending heal grows to thirty-eight forty. This time, it is worth a step.
  - caption: Bob buys with 3,000 USDC. The pool keeps 60, and pending heal grows to 38.40 USDC: this time, worth a step.

**6:01** · On screen: Position diagram (broken tick axis) · `packages/v4/src/WavefrontHook.sol:419-447`

- **6:01** Rebalance first removes the whole position, because v4 cannot move a position's edge or depth in place. For a moment, the pool holds no liquidity.
  - caption: _rebalance first removes the whole position: v4 cannot move a position's edge or depth in place. For a moment the pool holds no liquidity.
- **6:12** Apply pending adds the heal to the reserves, as v1 would. The new floor rounds down to the grid: three steps up.
  - caption: _applyPending adds the heal to the reserves, as v1 would. The new floor rounds down to the grid: −368,280, three steps up.
- **6:20** Down, because rounding up would promise the last sellers more than the pool holds.
- **6:26** Sqrt price for then finds where v1's curve at that floor puts the price, given the coins in the pool.
  - caption: sqrtPriceFor then finds where v1's curve at that floor puts the price, given the coins in the pool.

**6:32** · On screen: Position diagram (broken tick axis) · `packages/v4/src/WavefrontHook.sol:563-581`

- **6:33** Add position moves the price there with a swap that trades nothing, since the pool is empty. Indexers see a zero-amount swap.
  - caption: _addPosition moves the price there with a swap that trades nothing, since the pool is empty. Indexers see a zero-amount Swap.
- **6:43** Then it adds the new, deeper position. It takes every coin back, plus thirty-nine dollars more than came out: the heal entering the curve.
  - caption: Then it adds the new, deeper position. It takes every coin back, plus 39.22 USDC more than came out: the heal entering the curve.

**6:54** · On screen: Rebalance result · `packages/v4/src/WavefrontHook.sol:448-469`

- **6:54** Of the forty dollars ten that was waiting, eighty-eight cents stays idle: too little for another step. It is counted again next time.
  - caption: Of the 40.10 USDC waiting, 0.88 stays idle, too little for another step. It is counted again next time.
- **7:03** Floor and price both stepped up about point three percent, inside Bob's swap. This trade cost about three hundred and fifty-seven thousand gas.
  - caption: Floor and price both stepped up about 0.3%, inside Bob's swap. This trade cost about 357k gas.


## 7:13 · 6. A sell and a burn

_Coin fees, the burn queue, _flushBurnQueue_

**7:13** · Title card (silent, 3.2 s)

**7:16** · On screen: Fee split · Recorded _ratchetDue / _applyPending numbers

- **7:17** A sell mirrors a buy, except the fee is in coins, and the hook's share is burned rather than added.
- **7:25** Alice sells four hundred thousand WAVE. Of the eight-thousand-coin fee, sixteen hundred each go to the team and the treasury, and forty-eight hundred become pending burn.
  - caption: Alice sells 400,813 WAVE. Of the 8,016-coin fee, 1,603 each go to team and treasury, and 4,810 become pending burn.
- **7:36** A burn lifts the floor by about its share of the circulating coins, and a step needs about a tenth of a percent. This one waits.
  - caption: A burn lifts the floor by about its share of circulating coins; a step needs about 0.1%. This one waits.

**7:46** · On screen: v1 curve diagram (illustrative reserves, exaggerated where noted) · Recorded _ratchetDue / _applyPending numbers

- **7:46** Bob sells all his coins. Pending burn reaches two hundred and eighty-five thousand: point three one percent of circulation. Worth a step.
  - caption: Bob sells all his coins. Pending burn reaches 285,476 WAVE, 0.314% of circulation: worth a step.
- **7:56** Apply pending takes it out of circulation, and the pool gives up two point eight five million coins in the same proportion.
  - caption: _applyPending takes it out of circulation, and the pool gives up 2,854,564 coins in the same proportion.
- **8:04** Fewer pool coins means a higher price, and a smaller supply means a thinner curve. The floor still rises, three steps.
  - caption: Fewer pool coins means a higher price; a smaller supply means a thinner curve. The floor rounds down to −368,250, three steps up.

**8:12** · On screen: Burn queue steps · `packages/v4/src/WavefrontHook.sol:451-456`, `packages/v4/src/WavefrontHook.sol:704-707`, `packages/v4/src/WavefrontHook.sol:512-520`

- **8:12** Those coins cannot be destroyed yet. Bob has not paid, so the PoolManager may not hold them. Three point one four million wait in the burn queue.
  - caption: Those coins cannot be destroyed yet: Bob has not paid, so the PoolManager may not hold them. 3,140,041 WAVE wait in the burn queue.
- **8:22** Queued coins stop counting as supply at once, so the curve already treats them as gone.
- **8:28** The next swap's flush burn queue redeems the claims and burns them. Supply falls from one billion to about nine hundred and ninety-seven million.
  - caption: The next swap's _flushBurnQueue redeems the claims and burns them. Supply falls from one billion to 996,859,959 WAVE.


## 8:38 · 7. Lending

_Raising the lower tick · the collateral lock · the tick margin_

**8:38** · Title card (silent, 3.2 s)

**8:41** · On screen: Position diagram (broken tick axis) · `packages/v4/src/libraries/CurveMath.sol:152-165`

- **8:41** Alice holds about two million WAVE. Her credit is what they would fetch if sold last, at the bottom of the curve: about a hundred and fifty-three dollars. She borrows half.
  - caption: Alice holds 1,997,041 WAVE. Her credit is what they would fetch if sold last, at the bottom of the curve: 152.86 USDC. She borrows half.
- **8:52** The quote in the lowest slice of the position can only be reached by selling the coins Alice now locks. Locked coins cannot be sold.

**9:00** · On screen: Position diagram (broken tick axis) · `packages/v4/src/WavefrontHook.sol:201-211`, `packages/v4/src/WavefrontHook.sol:282-286`, `packages/v4/src/WavefrontHook.sol:546-554`

- **9:01** Borrow records the debt and rebalances. The floor and the depth stay put; only the position's lower edge moves.
  - caption: borrow records the debt and rebalances. Floor and depth stay put; only the position's lower edge moves.
- **9:08** The debt boundary, floor plus debt over liquidity, rounds up to the grid: two steps up. Starting there, the position needs about a hundred and one dollars less.
  - caption: The debt boundary, floor plus debt over liquidity, rounds up to the grid: two steps up. Starting there, the position needs 101.56 USDC less.
- **9:18** Alice receives seventy-six dollars, and the other twenty-eight stays idle. Then borrow checks she still holds every coin that must be locked.
  - caption: Alice receives 76.43 USDC; the other 28.68 stays idle. Then borrow checks she still holds every coin that must be locked.

**9:28** · On screen: Alice's locked and free coins · `packages/v4/src/Coin.sol:90-97`, `packages/v4/src/WavefrontHook.sol:632-638`

- **9:28** The lock lives in the coin: every transfer asks the hook how many of the sender's coins are locked, and will not move them.
- **9:35** Alice locks one point two five million coins: the ones backing her debt, plus a fixed margin of one grid step at the floor, which covers the tick rounding.
  - caption: Alice locks 1,248,225 WAVE: the coins backing her debt, plus a fixed margin of one grid step at the floor that covers the tick rounding.
- **9:45** No interest, and no liquidations. Repaying rebuilds the position from the floor. Borrow costs about four hundred and five thousand gas, and repay about three hundred and thirteen thousand.
  - caption: No interest and no liquidations. Repaying rebuilds the position from the floor. Borrow costs about 405k gas, repay about 313k.


## 9:57 · 8. Differences, limits, next

_From packages/v4/README.md_

**9:57** · Title card (silent, 3.2 s)

**10:01** · On screen: List

- **10:01** Unlike v1, the fee is chosen per coin, one to five percent, fixed for good. And the floor sits on a tick, at most a tenth of a percent under v1's.
  - caption: Unlike v1, the fee is chosen per coin, 1% to 5%, fixed for good, and the floor sits on a tick, at most 0.1% under v1's.
- **10:13** Fees wait until they are worth a step, and team and treasury fees are claimed, not pushed, because inside a swap the trader has not paid yet.
- **10:23** On four-hundred-trade random paths, the price was observed within one percent of v1's. The test itself requires two.
  - caption: On 400-trade random paths the price was observed within 1% of v1's. The test itself requires 2%.

**10:32** · On screen: List

- **10:33** Known limits: a sell into an empty range can cost millions of gas, and zero-amount Swap events can look like wicks on a chart.
- **10:41** Waiting fees go to whoever first takes holders past a tenth of a percent. The hook is close to the contract size limit, and it is unaudited.
  - caption: Waiting fees go to whoever first takes holders past 0.1%. The hook is 23,528 of 24,576 bytes, and it is unaudited.

**10:51** · On screen: List

- **10:51** Read next: the curve math header, then after swap, ratchet due, rebalance, apply pending, add position, borrow, and the coin's update.
  - caption: Read next: the CurveMath header, then _afterSwap, _ratchetDue, _rebalance, _applyPending, _addPosition, borrow and Coin._update.
- **11:01** Then the tests, which check every formula against the real v1 contract.
  - caption: Then the tests: CurveMath.t.sol checks every formula against the real v1 contract.

**11:06** · End card (silent, 5.0 s)


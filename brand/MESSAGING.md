# Wavefront messaging

What to say about Wavefront, what proves it, and what not to claim. Every point here is tied to what the contracts do. Numbers come from the protocol's own formulas (`brand/src/liquidity.mjs`, which matches v1's math) on a coin with about $149k in its pool and a 2% fee; they are examples, not promises.

## Positioning

**Wavefront by GlazeCorp.** A coin launcher where the floor only rises.

One sentence: *Wavefront launches coins whose liquidity belongs to the coin itself, so every trade, donation and burn pushes the floor up, and holders can borrow that floor without selling.*

"Wavefront by GlazeCorp" is the full name on first mention and in footers. After that it is Wavefront.

## What sets it apart

| | An ordinary pool | A launch curve that graduates | Wavefront |
|---|---|---|---|
| Who owns the liquidity | Outside providers, who can leave | The launchpad, until it moves to a pool | The coin. Only the contract can add or remove it |
| Liquidity at launch | Someone has to deposit it | Built up by early buyers | None needed: a virtual reserve makes it tradable at once |
| Where trading fees go | To liquidity providers | To the launchpad | To the floor, the team and the treasury. No outside providers to pay |
| A floor | None | None | Yes, and no code path lowers it |
| What a sell-off does | Price falls | Price falls | Price falls to the floor and stops; coins are burned on the way down |
| Borrowing | Needs a lending market, an oracle and liquidations | Not offered | Built in: no interest, no oracle, no liquidation |
| What happens later | Nothing | It migrates to a pool | Nothing to migrate. The coin stays on its curve |

## The pillars

### 1. A floor that only rises
Every coin has a floor price, and nothing in the contracts can lower it. Sells stop at it.

- **Proof:** the floor is only ever raised (`WavefrontHook.sol`, where `floorTick` is set; in v1 the virtual reserve only grows and the supply only shrinks). A sell that would go under it is stopped: v1 reverts it, v4 fills only the part above.
- **Say:** "The floor only rises." "The price can fall back to the floor, and never through it."
- **Careful:** the floor is far below the market price for a coin that has run up. It is a guarantee about the worst case, not about the price.

### 2. Liquidity that reshapes itself
A normal pool's curve stays where it is. Wavefront's moves up as it is used: part of every fee goes back into the curve.

- **Proof:** on a buy, 60% of the fee is added to the reserves (a heal). On a sell, 60% of the fee is burned. Both raise the floor.
- **Number:** buying $20,000 of a coin and selling it straight back leaves the floor 0.20% higher and the price 0.49% higher than before. A hundred such round trips, about $2M of volume, lift the floor 10%.
- **Say:** "Volume lifts the floor." "The curve moves up as it's traded."
- **Careful:** on Uniswap v4 fees are applied in steps, once they are worth one tick, not on literally every trade. Say "as it trades", not "on every trade".

### 3. Sell-offs burn supply
On a sell the fee is paid in coins, and most of it is destroyed. So the supply shrinks fastest when people are selling.

- **Proof:** the sell fee is taken in coins and the holders' share is burned (v1 `Coin.sol`, `_burnCoinReserves`; v4 queues it and applies it at the next step).
- **Number:** in a sell-off of 40% of the coins held, the price fell 59%, 2.8M coins were burned and the floor rose 0.6%.
- **Say:** "Even a sell-off raises the floor." "Selling burns coins."
- **Careful:** the burn is 1.2% of the coins sold at a 2% fee. It is steady, not dramatic. Don't say burns "surge".

### 4. Revenue that can't be undone
A project with revenue has two ways to send it to holders, and neither can be sold back down.

| $10,000 of revenue, spent as | Floor | Price | Supply |
|---|---|---|---|
| A donation into the curve | +6.7% | +6.7% | unchanged |
| A buy, then a burn of the coins bought | +2.7% | +10.8% | −2.5% |
| An ordinary buyback (buy and keep), for comparison | +0.08% | +8.0% | unchanged |

- **Proof:** anyone can call `heal` (donate quote) or `burn` (destroy coins) without trading. Both exist in v1 and v4.
- **Say:** "A buyback lifts the price until someone sells. A donation lifts the floor for good." "Donate for the most floor. Buy and burn for the most price."
- **Careful:** these figures are for one coin at one moment. The effect is larger on a small coin and smaller on a large one.

### 5. Borrow your floor
A holder can borrow the floor value of their coins, with no interest, no price oracle and nothing to liquidate. As the floor rises, so does what they can borrow.

- **Proof:** `borrow` and `repay` on the hook (v1: on the coin). The loan is limited to what the coins would fetch if sold last, at the bottom of the curve, so the pool always holds enough to cover it. The coins backing a loan can't be moved, sold or burned until it is repaid; the rest stay free.
- **Number:** a holder of 1% of the coins held could borrow $612 against coins worth $3,642 at market. After the $10,000 donation above, that limit is 6.7% higher.
- **Say:** "Borrow your floor without selling." "No interest. No liquidation. Repay when you like."
- **Careful:** the loan is the floor value, not the market value. Never "borrow against your bag". On v4 a small margin is held back and very small balances can't borrow.

### 6. The coin owns its market
There are no outside liquidity providers to leave, no migration to wait for, and no switches for anyone to flip.

- **Proof:** only the hook can create a Wavefront pool or add liquidity to it. The whole supply is minted once and can only shrink. There is no pause, no allowlist and no upgrade proxy in the contracts.
- **Say:** "Liquidity that can't be pulled." "No graduation. The curve is the market."
- **Careful:** it is not "no admin at all". The protocol owner can change the treasury address and a coin's owner can change its team address, which changes who receives those two fee shares.

## Lines to use

**Headlines**
- The floor only rises.
- Launch a coin with a rising floor.
- Liquidity that can't be pulled.
- Borrow your floor. Keep your coins.
- Even a sell-off raises the floor.
- A buyback that can't be sold back down.

**Short descriptions**
- Wavefront by GlazeCorp launches coins that own their own liquidity. Every trade pays into a floor that only rises, and holders can borrow that floor with no interest and no liquidations.
- On Wavefront, volume, donations and burns all push the floor up. Nothing pushes it down.

## Claims to avoid

| Don't say | Because | Say instead |
|---|---|---|
| "No taxes on borrowing" or anything about tax | It depends on the country and the person, and it is not ours to promise | "Get liquidity without selling" |
| "The price can't go down" | Only the floor can't. The price can fall all the way to it | "The floor can't go down" |
| "Every trade raises the floor" | On v4, fees are applied in steps | "The floor rises as the coin trades" |
| "2% fee" for every coin | v4 coins choose 1% to 5% at launch, and Uniswap may add up to 0.1% | "A fee set at launch, between 1% and 5%" |
| "Borrow against your bag" or "borrow your full value" | The loan is the floor value, less a small margin on v4 | "Borrow your floor" |
| "No admin", "fully trustless" | Two addresses can be changed by owners | "No pause, no allowlist, no upgrades" |
| "Audited", "live", "safe" | The v4 contracts are unaudited and not deployed | Nothing until that changes |
| "Trade it in the Uniswap app" | That needs Uniswap to allowlist the hook | "Trades on Uniswap v4" once deployed; name specific apps only when confirmed |
| "Risk-free", "guaranteed returns", "can't lose" | A buyer above the floor can lose down to it | Describe the mechanism and let it speak |

## Before any of this goes public

- The v4 contracts are unaudited and carry a "do not deploy with real funds" notice.
- There is no live deployment yet.
- Routing through Uniswap's own apps depends on an allowlist that Uniswap grants at its discretion.

Messaging that describes how the protocol works is fine now. Messaging that invites people to put money in should wait for the first two.

/*
 * Wavefront's curve as a picture made of blocks. Used by the animated graphic (graphics/liquidity.html) and by the
 * stills build.mjs draws, so both show the same thing.
 *
 * The picture is not a metaphor. Lay the square root of the price along the bottom and the liquidity L up the side.
 * Then, from docs/bonding-curve.md and packages/v4/src/libraries/CurveMath.sol:
 *
 *   virtual quote = L × √floor            the rectangle left of the floor: counted, never deposited
 *   real quote    = L × (√price − √floor) the rectangle between the floor and the price: what the pool holds
 *   pool coins    = L ÷ √price            everything right of the price, thinning as the price climbs
 *
 * So one block is a fixed amount of quote, the price is the front where quote meets coins, and every mechanic is a
 * change of that shape: a buy pushes the front right, a heal makes the shape taller and moves its left wall in, a
 * burn makes it shorter and moves both walls right, and a loan lifts out the slice at the floor.
 */

const FEE = 0.02; // of every trade
const HOLDER_SHARE = 0.6; // of the fee: healed on a buy, burned on a sell. Team and treasury take 20% each.

/** The recorded launch: 1,000,000,000 coins against 100,000 of virtual quote, nothing deposited. */
export function launch() {
  return { virtualQuote: 100_000, realQuote: 0, poolCoins: 1e9, maxSupply: 1e9, debt: 0 };
}

/** Everything the picture needs, worked out from the four reserves and the debt. */
export function read(market) {
  const liquidity = Math.sqrt(market.virtualQuote * market.maxSupply);
  const floorRoot = Math.sqrt(market.virtualQuote / market.maxSupply);
  const priceRoot = (market.virtualQuote + market.realQuote) / liquidity;
  const lentRoot = floorRoot + market.debt / liquidity;
  const circulating = market.maxSupply - market.poolCoins;
  // Coins that must stay locked: the ones whose sale would walk the price down into the lent slice.
  const locked = market.debt > 0 ? liquidity * (1 / floorRoot - 1 / lentRoot) : 0;
  return {
    liquidity,
    floorRoot,
    priceRoot,
    lentRoot,
    floor: floorRoot ** 2,
    price: priceRoot ** 2,
    circulating,
    locked,
    free: Math.max(0, circulating - locked),
  };
}

/** A heal: quote added to the reserves. The virtual side grows with it, which is what lifts the floor. */
export function heal(market, quote) {
  const circulating = market.maxSupply - market.poolCoins;
  if (circulating <= 0 || quote <= 0) return 0;
  market.virtualQuote += (market.poolCoins * quote) / circulating;
  market.realQuote += quote;
  return quote;
}

/** A burn: coins leave circulation and the pool gives up coins in the same proportion. */
export function burn(market, coins) {
  const circulating = market.maxSupply - market.poolCoins;
  const amount = Math.min(coins, circulating * 0.9);
  if (amount <= 0) return 0;
  const fromPool = (market.poolCoins * amount) / circulating;
  market.poolCoins -= fromPool;
  market.maxSupply -= amount + fromPool;
  return amount;
}

/** A buy along the constant-product curve. The holders' share of the fee is healed straight back in. */
export function buy(market, quote) {
  const fee = quote * FEE;
  const before = market.virtualQuote + market.realQuote;
  const after = before + (quote - fee);
  const poolCoins = (before * market.poolCoins) / after;
  const coinsOut = market.poolCoins - poolCoins;
  market.realQuote += quote - fee;
  market.poolCoins = poolCoins;
  const healed = heal(market, fee * HOLDER_SHARE);
  return { quote, coinsOut, healed };
}

/** A sell. It stops at the bottom of the position: the floor, or the top of the lent slice when there is debt. */
export function sell(market, coins) {
  const { liquidity, priceRoot, lentRoot, free } = read(market);
  const room = (liquidity * (1 / lentRoot - 1 / priceRoot)) / (1 - FEE);
  const amount = Math.min(coins, free, room * 0.999);
  if (amount <= 0) return { coins: 0, quoteOut: 0, burned: 0 };
  const fee = amount * FEE;
  const before = market.virtualQuote + market.realQuote;
  const poolCoins = market.poolCoins + (amount - fee);
  const after = (before * market.poolCoins) / poolCoins;
  market.realQuote -= before - after;
  market.poolCoins = poolCoins;
  const burned = burn(market, fee * HOLDER_SHARE);
  return { coins: amount, quoteOut: before - after, burned };
}

/** What a holder of `coins` can borrow: what those coins would fetch if they were the last ones sold. */
export function credit(market, coins) {
  if (coins <= 0 || coins >= market.maxSupply) return 0;
  return (market.virtualQuote * market.maxSupply) / (market.maxSupply - coins) - market.virtualQuote;
}

export function borrow(market, quote) {
  const { free, priceRoot, floorRoot, liquidity } = read(market);
  // Never more than the free coins could back, and never past the price: the lent slice sits below it.
  const limit = Math.min(credit(market, free), liquidity * (priceRoot - floorRoot) * 0.9 - market.debt);
  const amount = Math.max(0, Math.min(quote, limit));
  market.debt += amount;
  return amount;
}

export function repay(market) {
  const amount = market.debt;
  market.debt = 0;
  return amount;
}

/* ---------------------------------------------------------------- layout */

/** How the reserves map onto a grid of blocks: `cols` wide, with the launch standing `launchRows` tall. */
export function view(cols = 56, launchRows = 7, floorCol = 9) {
  const start = read(launch());
  return { cols, rootPerCol: start.floorRoot / floorCol, liquidityPerRow: start.liquidity / launchRows };
}

/** The shape to draw, in block units: how tall, and where the floor, the lent slice and the price fall. */
export function shape(market, grid) {
  const now = read(market);
  return {
    rows: now.liquidity / grid.liquidityPerRow,
    floorCol: now.floorRoot / grid.rootPerCol,
    lentCol: now.lentRoot / grid.rootPerCol,
    priceCol: now.priceRoot / grid.rootPerCol,
  };
}

/** The quote one block stands for. */
export const blockValue = (grid) => grid.rootPerCol * grid.liquidityPerRow;

function hash(seed) {
  let value = 0x811c9dc5;
  for (let index = 0; index < seed.length; index += 1) {
    value ^= seed.charCodeAt(index);
    value = Math.imul(value, 0x01000193) >>> 0;
  }
  return value >>> 0;
}
export const chance = (seed) => (hash(seed) % 10000) / 10000;

const LEAN = 2.4; // how many columns the top of the front runs ahead of the bottom: a wave leaning into its travel

/**
 * Every block of the picture, bottom row first. Each has a column and a row, a `kind`, and for blocks on the front a
 * `quote` share between 0 and 1 so the renderer can blend the two sides as the front passes through.
 *
 *   virtual  left of the floor: an outline, because nothing was ever deposited there
 *   lent     the slice of the position at the floor, borrowed out
 *   quote    real quote in the pool; `depth` counts down from the surface, 0 being the wave line and -1 spray
 *   coin     coins in the pool; `strength` thins with the price, as L ÷ √price does
 */
export function blocks(form, grid, { ripple = () => 0 } = {}) {
  const out = [];
  for (let col = 0; col < grid.cols; col += 1) {
    const centre = col + 0.5;
    const inWater = centre >= form.lentCol && centre < form.priceCol;
    const height = Math.max(1, form.rows + (inWater ? ripple(col) : 0));
    const full = Math.floor(height + 1e-9);
    const top = Math.ceil(height - 1e-9);
    for (let row = 0; row < top; row += 1) {
      // A fraction of a row still shows: it sits above the wave line as spray (depth -1), fading in as the shape grows.
      const cover = row < full ? 1 : height - full;
      const depth = full - 1 - row;
      const base = { col, row, depth, cover };
      if (centre < form.floorCol) {
        out.push({ ...base, kind: 'virtual' });
        continue;
      }
      if (centre < form.lentCol) {
        out.push({ ...base, kind: 'lent' });
        continue;
      }
      const front = form.priceCol + LEAN * ((row + 0.5) / form.rows - 0.5);
      const quote = Math.max(0, Math.min(1, front - col));
      // The far right loosens: the position runs on to the top of v4's range, further than any picture can show.
      const edge = (col - (grid.cols - 9)) / 9;
      if (quote === 0 && edge > 0 && chance(`${col},${row}`) < edge ** 1.4) continue;
      const strength = Math.max(0.16, Math.min(1, (form.priceCol / centre) ** 2));
      out.push({ ...base, kind: quote >= 0.5 ? 'quote' : 'coin', quote, strength });
    }
  }
  return out;
}

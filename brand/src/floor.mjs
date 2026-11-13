/*
 * The rising floor, as a history: a coin's price and its floor over time, from a market run with the protocol's own
 * formulas (liquidity.mjs). Used by the animated graphic (graphics/floor.html) and by the still build.mjs draws.
 *
 * Nothing here decides that the floor goes up. It goes up because every buy heals 60% of its fee into the curve and
 * every sell burns 60% of its fee, and the price stays above it because a sell stops at the bottom of the pool.
 */
import { buy, launch, read, sell } from './liquidity.mjs';

/** A small seeded random source, so a still comes out the same every build. */
export function seeded(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let mixed = Math.imul(state ^ (state >>> 15), 1 | state);
    mixed = (mixed + Math.imul(mixed ^ (mixed >>> 7), 61 | mixed)) ^ mixed;
    return ((mixed ^ (mixed >>> 14)) >>> 0) / 4294967296;
  };
}

/** A coin a few buys after launch, so there is something to sell. */
export function opened(random) {
  const market = launch();
  for (let count = 0; count < 4; count += 1) buy(market, 15_000 + random() * 20_000);
  return market;
}

/**
 * One column of history: fourteen trades on a very busy coin. `pressure` runs from -1 (everyone selling) to 1 (everyone
 * buying). Traders also lean against the price: they sell more when it is far above the floor and buy more when it is
 * close, which keeps the two in one picture. Returns where the price and the floor ended up, and the quote traded.
 */
export function column(market, random, pressure) {
  let volume = 0;
  for (let trade = 0; trade < 14; trade += 1) {
    const now = read(market);
    // At full pressure nobody leans against it: a pump is all buys, and a dump is all sells.
    const lean = Math.abs(pressure) >= 0.95 ? pressure * 1.25 : pressure - 1.0 * Math.tanh(Math.log(now.price / now.floor / 3.2));
    if (random() < 0.5 + 0.4 * lean) {
      // A buy is sized against the pool, so the market behaves the same however far the coin has come.
      const quote = (market.virtualQuote + market.realQuote) * (0.04 + random() * 0.14);
      buy(market, quote);
      volume += quote;
    } else {
      const result = sell(market, now.free * (0.03 + random() * 0.09));
      volume += result.quoteOut;
    }
  }
  const now = read(market);
  return { price: now.price, floor: now.floor, volume };
}

/** The mood the market drifts through when nobody is steering it: slow swings with a slight lean toward buying. */
export const drift = (index) => 0.05 + 0.5 * Math.sin(index / 6.5) + 0.25 * Math.sin(index / 2.3 + 1);

/** A whole history at once, for stills. `steer(index)` may return a pressure to override the drift. */
export function history(length, seed, steer = () => undefined) {
  const random = seeded(seed);
  const market = opened(random);
  return Array.from({ length }, (_, index) => column(market, random, steer(index) ?? drift(index)));
}

/**
 * The price range a stretch of history needs, with a little air above and below. The scale is logarithmic, so a
 * doubling is the same height anywhere: that is what lets a slow floor and a fast price share one picture.
 */
export function range(points) {
  const low = Math.min(...points.map((point) => point.floor)) * 0.8;
  const high = Math.max(...points.map((point) => point.price)) * 1.18;
  return { low, high };
}

/** Where a price sits between the bottom (0) and the top (`rows`) of the picture. */
export const rowOf = (value, scale, rows) => (Math.log(value / scale.low) / Math.log(scale.high / scale.low)) * rows;

/**
 * A smooth line through points, as cubic Bézier segments after the first point: [[c1x, c1y, c2x, c2y, x, y], ...].
 * Used for the price, which is fluid and so is drawn as a line, never as blocks.
 */
export function smooth(points) {
  const out = [];
  for (let index = 0; index < points.length - 1; index += 1) {
    const before = points[Math.max(0, index - 1)];
    const from = points[index];
    const to = points[index + 1];
    const after = points[Math.min(points.length - 1, index + 2)];
    out.push([
      from[0] + (to[0] - before[0]) / 6,
      from[1] + (to[1] - before[1]) / 6,
      to[0] - (after[0] - from[0]) / 6,
      to[1] - (after[1] - from[1]) / 6,
      to[0],
      to[1],
    ]);
  }
  return out;
}

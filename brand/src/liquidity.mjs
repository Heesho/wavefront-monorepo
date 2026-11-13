/*
 * Wavefront's market as pictures, drawn to scale by the brand's rules: blocks are the floor, fluid is the market
 * above it, and price runs up the side. Used by the live graphic (graphics/liquidity.html), by the stills build.mjs
 * draws and by the guidelines page, so all three show the same thing.
 *
 * Nothing here is a metaphor. The formulas are the protocol's, from docs/bonding-curve.md and
 * packages/v4/src/libraries/CurveMath.sol. With liquidity L:
 *
 *   virtual quote = L × √floor            counted in the price, never deposited
 *   real quote    = L × (√price − √floor) what the pool holds
 *   pool coins    = L ÷ √price            thinning as the price climbs
 *
 * The picture is the curve (curveSvg, further down): price up the side against coins held along the bottom.
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

/* ----------------------------------------------------------------- curve */

/*
 * The curve picture, the one every mechanic is explained with: price up the side against coins held along the
 * bottom. With k = virtual quote × supply, the price when `held` coins are out is k ÷ (supply − held)².
 *
 *   the floor     blocks under the floor price, across the coins held. Real quote: every coin bought was paid for at
 *                 the floor or more, and this is the part that guarantees it. Loans come out of here, so the blocks
 *                 under coins borrowed against are hollow.
 *   the market    fluid, from the floor up to the curve: what buyers paid above the floor.
 *   ahead         one row of empty blocks along the floor, out to the end of the supply, and the curve as a line.
 */

/** The price when `held` coins are out. */
export const priceAt = (market, held) => (market.virtualQuote * market.maxSupply) / Math.max(1, market.maxSupply - held) ** 2;

/** How many coins a loan of `debt` hollows the floor under: the loan divided by the floor price. */
export const hollowed = (market) => market.debt / (market.virtualQuote / market.maxSupply);

/**
 * The curve picture as SVG markup, one unit a block, `cols` across (the launch supply) and `rows` tall, with
 * `ceiling` the price at the top. Pick a ceiling that makes the floor a whole number of rows and its blocks are
 * square. `ghost` is an earlier state of the market, drawn as a dotted curve to show what changed.
 */
export function curveSvg(market, { cols, rows, ceiling, colours, ghost = null, launchSupply = 1e9, id = 'above-floor' }) {
  const cut = (value) => String(+value.toFixed(3));
  const now = read(market);
  const perCol = launchSupply / cols;
  const px = (coins) => coins / perCol;
  const py = (value) => rows - (value / ceiling) * rows;
  const gap = 0.14;

  // The floor, in blocks.
  const floorTall = (now.floor / ceiling) * rows;
  const floorRows = Math.max(1, Math.round(floorTall));
  const rowTall = floorTall / floorRows;
  const heldCols = Math.round(now.circulating / perCol);
  const hollowCols = Math.min(heldCols, Math.round(hollowed(market) / perCol));
  const block = (col, row, rest) =>
    `<rect x="${cut(col + gap / 2)}" y="${cut(rows - (row + 1) * rowTall + (rowTall * gap) / 2)}" width="${cut(1 - gap)}" height="${cut(rowTall * (1 - gap))}" rx="${cut((1 - gap) * 0.22)}" ${rest}/>`;
  let out = '';
  for (let col = 0; col < cols; col += 1) {
    for (let row = 0; row < floorRows; row += 1) {
      const below = floorRows - 1 - row;
      if (col < hollowCols) out += block(col, row, `fill="none" stroke="${colours.surf}" stroke-width="0.06" stroke-dasharray="0.2 0.14"`);
      else if (col < heldCols) out += block(col, row, `fill="${below === 0 ? colours.surf : below <= 2 ? colours.tide : below <= 6 ? colours.deep : colours.trench}"`);
      else if (below === 0 && (col + 1) * perCol <= market.maxSupply) out += block(col, row, `fill="none" stroke="${colours.surf}" stroke-opacity="0.45" stroke-width="0.06"`);
    }
  }

  // The market, fluid: from just above the floor up to the curve, over every coin held.
  const trace = (from, until, drop, state = market) => {
    const points = [];
    for (let step = 0; step <= 80; step += 1) {
      const coins = from + ((until - from) * step) / 80;
      const y = py(priceAt(state, coins)) + drop;
      points.push(`${cut(px(coins))} ${cut(y)}`);
      if (y < -0.3) break; // off the top of the picture
    }
    return points.join('L');
  };
  const held = now.circulating;
  if (held > 0) {
    const top = rows - floorTall - 0.45;
    out += `<clipPath id="${id}"><rect x="0" y="-2" width="${cols}" height="${cut(top + 2)}"/></clipPath><g clip-path="url(#${id})">`;
    for (const [drop, name] of [[0, 'surf'], [0.7, 'tide'], [2.4, 'deep'], [5, 'trench']]) {
      out += `<path d="M0 ${rows}L${trace(0, held, drop)}L${cut(px(held))} ${rows}Z" fill="${colours[name]}"/>`;
    }
    out += '</g>';
  }

  // Where the curve was, where it goes, and where the market sits on it.
  const line = (state, until, rest) => `<path d="M${trace(0, until, 0, state)}" fill="none" stroke-linejoin="round" stroke-linecap="round" ${rest}/>`;
  if (ghost) {
    out += line(ghost, ghost.maxSupply * 0.999, `stroke="${colours.surf}" stroke-opacity="0.7" stroke-width="0.08" stroke-dasharray="0.25 0.35"`);
    const was = read(ghost);
    out += `<circle cx="${cut(px(was.circulating))}" cy="${cut(py(was.price))}" r="0.3" fill="${colours.ground}" stroke="${colours.surf}" stroke-width="0.08"/>`;
  }
  out += line(market, market.maxSupply * 0.999, `stroke="${colours.foam}" stroke-opacity="0.35" stroke-width="0.1"`);
  if (held > 0) out += line(market, held, `stroke="${colours.foam}" stroke-width="0.16"`);
  if (market.maxSupply < launchSupply * 0.998) {
    out += `<path d="M${cut(px(market.maxSupply))} 0V${rows}" stroke="${colours.muted}" stroke-width="0.05" stroke-dasharray="0.25 0.25"/>`;
  }
  out += `<circle cx="${cut(px(held))}" cy="${cut(py(now.price))}" r="0.5" fill="${colours.ground}"/><circle cx="${cut(px(held))}" cy="${cut(py(now.price))}" r="0.32" fill="${colours.foam}"/>`;
  return out;
}

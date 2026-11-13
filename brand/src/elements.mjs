/*
 * Wavefront's block elements, as functions that return SVG markup. No dependencies: import this file in the site, or
 * copy the function you need. Everything here is drawn with the one block: a gap of 14% of the cell, corners at 22%.
 *
 *   glyph(seed)          a picture for a coin or wallet that has none, always the same for the same seed
 *   icon(name)           the block icon set; see ICONS for the names
 *   meter(value)         a share of something, counted in whole blocks
 *   spark(points)        a price line in blocks, for cards and tables
 */

const GAP = 0.14;
const ROUND = 0.22;

/** The Afterglow palette. build.mjs checks this against the brand tokens, so the two can't drift apart. */
export const palette = {
  ground: '#0b0b0b',
  surface2: '#1e1e1e',
  ink: '#ebebeb',
  trench: '#1b1464',
  deep: '#3d5afe',
  tide: '#b14cff',
  surf: '#ff5fb8',
  foam: '#ffc56b',
};

const cut = (value) => String(+value.toFixed(3));

function block(x, y, fill, opacity) {
  const size = 1 - GAP;
  const alpha = opacity === undefined ? '' : ` opacity="${cut(opacity)}"`;
  return `<rect x="${cut(x + GAP / 2)}" y="${cut(y + GAP / 2)}" width="${cut(size)}" height="${cut(size)}" rx="${cut(size * ROUND)}" fill="${fill}"${alpha}/>`;
}

export function hash(seed) {
  let value = 0x811c9dc5;
  for (let index = 0; index < seed.length; index += 1) {
    value ^= seed.charCodeAt(index);
    value = Math.imul(value, 0x01000193) >>> 0;
  }
  return value >>> 0;
}

/**
 * An identity made of blocks: a mirrored 5 by 5 pattern from an address or a name, lit like the logo, warm at the top
 * and cool at the bottom. For coins and wallets with no picture of their own.
 */
export function glyph(seed, { size = 40, round = false } = {}) {
  const bits = hash(String(seed).toLowerCase());
  const ramp = [palette.foam, palette.surf, palette.tide, palette.deep];
  const shift = (bits >>> 20) % 3;
  const cells = [];
  for (let y = 0; y < 5; y += 1) {
    for (let x = 0; x < 3; x += 1) {
      if ((bits >>> (y * 3 + x)) & 1) {
        cells.push([x, y]);
        if (x < 2) cells.push([4 - x, y]);
      }
    }
  }
  // Never empty, and never a single dot: the middle column always carries its centre.
  if (!cells.some(([x, y]) => x === 2 && y === 2)) cells.push([2, 2]);
  const body = cells.map(([x, y]) => block(x, y, ramp[Math.min(3, (y + shift) >> 1)])).join('');
  const ground = round
    ? `<circle cx="2.5" cy="2.5" r="3.5" fill="${palette.ground}"/>`
    : `<rect x="-1" y="-1" width="7" height="7" rx="1.54" fill="${palette.ground}"/>`;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-1 -1 7 7" width="${size}" height="${size}" aria-hidden="true">${ground}${body}</svg>`;
}

/** The block icon set, each on a 9 by 9 grid. */
export const ICONS = {
  buy: ['....X....', '...XXX...', '..XXXXX..', '.XXXXXXX.', '...XXX...', '...XXX...', '...XXX...', '...XXX...', '.........'],
  sell: ['.........', '...XXX...', '...XXX...', '...XXX...', '...XXX...', '.XXXXXXX.', '..XXXXX..', '...XXX...', '....X....'],
  heal: ['.........', '...XXX...', '...XXX...', '.XXXXXXX.', '.XXXXXXX.', '.XXXXXXX.', '...XXX...', '...XXX...', '.........'],
  burn: ['....X....', '....XX...', '...XXX...', '..XXXX.X.', '..XXXXXX.', '.XXX.XXX.', '.XX...XX.', '.XXX.XXX.', '..XXXXX..'],
  borrow: ['...XXX...', '..X...X..', '..X...X..', '.XXXXXXX.', '.XXXXXXX.', '.XXX.XXX.', '.XXX.XXX.', '.XXXXXXX.', '.........'],
  floor: ['.........', '......XXX', '......XXX', '...XXXXXX', '...XXXXXX', 'XXXXXXXXX', 'XXXXXXXXX', '.........', '.........'],
  curve: ['........X', '........X', '.......XX', '.......X.', '......XX.', '.....XX..', '...XXX...', 'XXXX.....', '.........'],
  coin: ['..XXXXX..', '.XXXXXXX.', 'XXX...XXX', 'XX.XXX.XX', 'XX.XXX.XX', 'XX.XXX.XX', 'XXX...XXX', '.XXXXXXX.', '..XXXXX..'],
  launch: ['....X....', '...XXX...', '..XX.XX..', '.XX...XX.', '....X....', '...XXX...', '..XX.XX..', '.XX...XX.', '.........'],
  fee: ['.XX....X.', '.XX...XX.', '.....XX..', '....XX...', '...XX....', '..XX.....', '.XX...XX.', '.X....XX.', '.........'],
  holder: ['...XXX...', '..XXXXX..', '..XXXXX..', '...XXX...', '.........', '.XXXXXXX.', 'XXXXXXXXX', 'XXXXXXXXX', '.........'],
  wave: ['.........', '.........', '..XX.....', '.XXXX...X', 'XX..XX.XX', 'X....XXX.', '......X..', '.........', '.........'],
  check: ['.........', '........X', '.......XX', '......XX.', 'X....XX..', 'XX..XX...', '.XXXX....', '..XX.....', '.........'],
};

/** One icon. It takes the text colour around it unless given one. */
export function icon(name, { size = 24, colour = 'currentColor' } = {}) {
  const rows = ICONS[name];
  if (!rows) throw new Error(`No icon called ${name}`);
  let body = '';
  rows.forEach((row, y) => {
    [...row].forEach((mark, x) => {
      if (mark === 'X') body += block(x, y, colour);
    });
  });
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 9 9" width="${size}" height="${size}" aria-hidden="true">${body}</svg>`;
}

/** A share from 0 to 1, counted in blocks. The leading block is Foam, the way the wave line is. */
export function meter(value, { blocks = 24, label = '' } = {}) {
  const filled = Math.round(Math.max(0, Math.min(1, value)) * blocks);
  let body = '';
  for (let x = 0; x < blocks; x += 1) {
    body += block(x, 0, x === filled - 1 ? palette.foam : x < filled ? palette.tide : palette.surface2);
  }
  const name = label ? `role="img" aria-label="${label}"` : 'aria-hidden="true"';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${blocks} 1" ${name} style="display:block;width:100%;height:auto">${body}</svg>`;
}

/** A price line in blocks: one column a period, stacked to its level, the latest one lit. */
export function spark(points, { rows = 6, label = '' } = {}) {
  const low = Math.min(...points);
  const high = Math.max(...points);
  const level = (value) => (high === low ? Math.ceil(rows / 2) : 1 + Math.round(((value - low) / (high - low)) * (rows - 1)));
  let body = '';
  points.forEach((value, x) => {
    const height = level(value);
    const latest = x === points.length - 1;
    for (let step = 0; step < height; step += 1) {
      const top = step === height - 1;
      body += latest
        ? block(x, rows - 1 - step, top ? palette.foam : palette.surf)
        : block(x, rows - 1 - step, top ? palette.surf : palette.tide, top ? 1 : 0.32);
    }
  });
  const name = label ? `role="img" aria-label="${label}"` : 'aria-hidden="true"';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${points.length} ${rows}" ${name} style="display:block;height:100%;width:auto">${body}</svg>`;
}

/*
 * The front: where fluid meets blocks. Left of `at` the water is smooth, in the brand's layers; right of it, blocks.
 * Across `spread` columns the two break into each other: the fluid's edge is bitten into block-shaped notches, more
 * of them the nearer the front, and beyond the front loose blocks gather into solid rows. Nothing fades: every part
 * of the picture is fluid, a block, or empty. Move `at` and cells flip one at a time, blocks melting or setting.
 * This is the brand's signature, and it is what a trade does at the price: quote on one side, coins on the other.
 *
 * Returns shapes rather than markup, so a canvas can animate it (see drawFront) and an SVG can hold it still:
 *   polygons   the fluid: { fill, points }
 *   holes      notches to cut out of the fluid: { x, y, w, h, r }
 *   rects      the blocks: { x, y, w, h, r, fill, alpha, col, row }
 * `surface(x)` is the height of the water at a distance x from the left, in the same units as `width` and `height`.
 */
const FLUID = [0.22, 0.9, 2.6, 5.2]; // where each band ends, in units below the surface

export function front({ width, height, unit, at, spread = 10, surface, sample = 6 }) {
  const tones = [palette.foam, palette.surf, palette.tide, palette.deep, palette.trench];
  const cols = Math.ceil(width / unit);
  const turn = Math.max(0, Math.min(cols, Math.round(at))); // the column where fluid ends and blocks begin
  // How far through the break-up a column is: 0 where it starts, 1 where it ends, a half at the front itself.
  const through = (col) => Math.max(0, Math.min(1, (col + 0.5 - (at - spread / 2)) / spread));
  const roll = (col, row) => (hash(`${col},${row}`) % 10000) / 10000; // fixed for each cell, so nothing flickers

  const polygons = [];
  const end = Math.min(width, turn * unit);
  if (end > 0) {
    const xs = [];
    for (let x = 0; x < end; x += sample) xs.push(x);
    xs.push(end);
    [0, ...FLUID].forEach((drop, index) => {
      const line = xs.map((x) => [x, Math.min(height, height - surface(x) + drop * unit)]);
      polygons.push({ fill: tones[index], points: [[0, height], ...line, [end, height]] });
    });
  }

  const holes = [];
  const rects = [];
  for (let col = Math.max(0, Math.floor(at - spread / 2)); col < cols; col += 1) {
    const share = through(col);
    const depth = Math.min(height, surface((col + 0.5) * unit)) / unit;
    if (col < turn) {
      // Fluid side: block-shaped notches, up to about four cells in ten at the front.
      for (let row = 0; row < Math.ceil(depth) + 1; row += 1) {
        if (roll(col, row) < share * 0.85) {
          // Exactly the size and place of a block, so a notch reads as a block that has come out of the fluid.
          const gap = GAP * unit;
          const size = unit - gap;
          holes.push({ x: col * unit + gap / 2, y: height - (row + 1) * unit + gap / 2, w: size, h: size, r: size * ROUND });
        }
      }
      continue;
    }
    // Block side: loose at the front, every block present by the end of the spread.
    const snapped = Math.max(1, Math.round(depth));
    const gap = GAP * unit;
    const size = unit - gap;
    for (let row = 0; row < snapped; row += 1) {
      if (roll(col, row) >= 0.5 + (share - 0.5) * 1.1) continue;
      const below = snapped - 1 - row;
      const fill = tones[below <= 0 ? 0 : below === 1 ? 1 : below <= 3 ? 2 : below <= 6 ? 3 : 4];
      rects.push({ x: col * unit + gap / 2, y: height - (row + 1) * unit + gap / 2, w: size, h: size, r: size * ROUND, fill, alpha: 1, col, row });
    }
  }
  return { polygons, holes, rects };
}

/**
 * Draw what front() returns onto a canvas. `tweak` may move, fade or drop a block: it gets each of `rects` and
 * returns the shape to draw, or nothing to skip it. Draw anything that sits behind the water after this, not before:
 * the notches are cut clean through.
 */
export function drawFront(context, { polygons, holes, rects }, tweak = (shape) => shape) {
  const alpha = context.globalAlpha;
  for (const { fill, points } of polygons) {
    context.beginPath();
    points.forEach(([x, y], index) => (index ? context.lineTo(x, y) : context.moveTo(x, y)));
    context.closePath();
    context.fillStyle = fill;
    context.fill();
  }
  if (holes.length) {
    context.save();
    context.globalCompositeOperation = 'destination-out';
    context.globalAlpha = 1;
    for (const hole of holes) {
      context.beginPath();
      context.roundRect(hole.x, hole.y, hole.w, hole.h, hole.r);
      context.fill();
    }
    context.restore();
  }
  for (const shape of rects) {
    const drawn = tweak(shape);
    if (!drawn) continue;
    context.globalAlpha = alpha * (drawn.alpha ?? 1);
    context.beginPath();
    context.roundRect(drawn.x, drawn.y, drawn.w, drawn.h, Math.max(0, drawn.r));
    context.fillStyle = drawn.fill;
    context.fill();
  }
  context.globalAlpha = alpha;
}

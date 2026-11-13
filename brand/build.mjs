#!/usr/bin/env node
/*
 * Wavefront brand kit generator. No dependencies.
 *
 *   node brand/build.mjs          writes every SVG and the token files
 *   node brand/build.mjs --png    also renders the PNGs, using a local Chrome (set CHROME_PATH if it isn't found)
 *
 * Everything is drawn in the block language Wavefront shares with GlazeCorp: rounded blocks with a gap of 14% of the
 * cell and corners at 22% of the block. The mark is the Tide: a coin made of blocks, filled to a wave line.
 *
 * Text is never set from a font here. The wordmark and the two lines used on social images are outlines read from
 * src/text-paths.json; run src/outline-text.py to change them.
 */
import { execFile } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

import * as curve from './src/liquidity.mjs';
import * as elements from './src/elements.mjs';
import * as rising from './src/floor.mjs';

const ROOT = dirname(fileURLToPath(import.meta.url));
const TEXT = JSON.parse(readFileSync(join(ROOT, 'src/text-paths.json'), 'utf8'));

/* ---------------------------------------------------------------- tokens */

const GAP = 0.14;
const ROUND = 0.22;

const COLOR = {
  ground: '#0b0b0b',
  surface: '#151515',
  surface2: '#1e1e1e',
  ink: '#ebebeb',
  ink2: '#d8d8d8',
  muted: '#a3a3a3',
  hairline: 'rgb(255 255 255 / 0.12)',
  // The wave ramp, Afterglow: sea floor to foam, always used in this order. Tide is the brand accent.
  trench: '#1b1464',
  deep: '#3d5afe',
  tide: '#b14cff',
  surf: '#ff5fb8',
  foam: '#ffc56b',
  white: '#ffffff',
  onAccent: '#0b0b0b',
  up: '#6fd3a0',
  down: '#ff8fa3',
  warn: '#e2c07a',
};

const LIGHT = {
  ground: '#f6f6f6',
  surface: '#ffffff',
  surface2: '#efeff0',
  ink: '#131313',
  muted: '#545454',
  hairline: 'rgb(19 19 19 / 0.14)',
  // On light grounds Tide is too pale for text; this darker violet takes its place for text and links.
  accentText: '#9c43e0',
};

const FONT = {
  display: "'Funnel Display', 'Helvetica Neue', Helvetica, sans-serif",
  body: "'Geist', 'Helvetica Neue', Helvetica, Arial, sans-serif",
  mono: "'Geist Mono', ui-monospace, 'SF Mono', Menlo, monospace",
};

/* ------------------------------------------------------------------ mark */

/*
 * The Tide at three sizes. D is an empty block, T is water, I is the wave line. Each smaller grid is redrawn, not
 * scaled down, so the blocks stay large enough to read.
 */
const TIDE = {
  // 48px and up.
  full: {
    pad: 1.2,
    rows: [
      '...DDD...',
      '.DDDDDDD.',
      '.DDDDDDD.',
      'DDIIDDDDI',
      'DITTIDDIT',
      'ITTTTIITT',
      '.TTTTTTT.',
      '.TTTTTTT.',
      '...TTT...',
    ],
  },
  // 24px to 47px.
  small: {
    pad: 0.95,
    rows: ['..DDD..', '.DDDDD.', 'DIIDDDI', 'ITTIDIT', 'TTTTITT', '.TTTTT.', '..TTT..'],
  },
  // 16px to 23px. Drawn on a 16-unit canvas so that at 16, 32 and 48 pixels every block lands on whole pixels: blocks
  // of 2 units with 1 unit between them. The wider gap is the one exception to the 14% rule.
  micro: {
    pixel: true,
    rows: ['.DDD.', 'DIDDI', 'ITIIT', 'TTTTT', '.TTT.'],
  },
};

const PAINT = {
  // Layered: the wave line is Foam, and the water under it shades by depth, Surf then Tide then Deep.
  colour: (ch, depth) =>
    ({
      D: { fill: COLOR.surface2 },
      I: { fill: COLOR.foam },
      T: { fill: depth <= 1 ? COLOR.surf : depth <= 3 ? COLOR.tide : COLOR.deep },
    })[ch],
  // One flat colour, for where only one ink is available.
  mono: (fill) => ({ D: { fill, opacity: 0.14 }, T: { fill, opacity: 0.58 }, I: { fill } }),
};

const n = (value) => String(+value.toFixed(3));

function rect(x, y, size, radius, { fill, opacity }) {
  const alpha = opacity === undefined ? '' : ` opacity="${opacity}"`;
  return `<rect x="${n(x)}" y="${n(y)}" width="${n(size)}" height="${n(size)}" rx="${n(radius)}" fill="${fill}"${alpha}/>`;
}

/**
 * Blocks for a grid of rows, one unit per cell. `paint` is either a table of styles by letter, or a function of the
 * letter and how many rows the block sits below the wave line in its column.
 */
function blocks(rows, paint, { gap = GAP, round = ROUND } = {}) {
  const size = 1 - gap;
  const waveLine = [...rows[0]].map((_, x) => rows.findIndex((row) => row[x] === 'I'));
  let out = '';
  rows.forEach((row, y) => {
    [...row].forEach((ch, x) => {
      const style = typeof paint === 'function' ? paint(ch, y - waveLine[x]) : paint[ch];
      if (style) out += rect(x + gap / 2, y + gap / 2, size, size * round, style);
    });
  });
  return out;
}

/**
 * The mark as { size, body }: a square of `size` units. With a disc, the blocks sit inside it with room around them;
 * without one (`disc: null`, for dark grounds) the square is cropped to the blocks.
 */
function tide(level, { paint = PAINT.colour, disc = COLOR.ground } = {}) {
  const { rows, pixel } = TIDE[level];
  const pad = disc ? TIDE[level].pad : 0;
  if (pixel) {
    const body = `<g transform="translate(0.5 0.5) scale(3)">${blocks(rows, paint, { gap: 1 / 3, round: 0.15 })}</g>`;
    return { size: 16, body: (disc ? `<circle cx="8" cy="8" r="8" fill="${disc}"/>` : '') + body };
  }
  const size = rows.length + 2 * pad;
  const ground = disc ? `<circle cx="${n(size / 2)}" cy="${n(size / 2)}" r="${n(size / 2)}" fill="${disc}"/>` : '';
  return { size, body: `${ground}<g transform="translate(${pad} ${pad})">${blocks(rows, paint)}</g>` };
}

/** Place a mark in a box of `box` units with its top-left corner at (x, y). */
function place(mark, x, y, box) {
  return `<g transform="translate(${n(x)} ${n(y)}) scale(${n(box / mark.size)})">${mark.body}</g>`;
}

function text(key, x, baseline, fontSize, fill) {
  return `<path transform="translate(${n(x)} ${n(baseline)}) scale(${n(fontSize)})" fill="${fill}" d="${TEXT[key].d}"/>`;
}

function svg(width, height, body, title = 'Wavefront') {
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n(width)} ${n(height)}" width="${n(width)}" height="${n(height)}" role="img" aria-label="${title}">` +
    `<title>${title}</title>${body}</svg>\n`
  );
}

function markFile(level, options) {
  const mark = tide(level, options);
  return svg(mark.size, mark.size, mark.body);
}

/* --------------------------------------------------------------- lockups */

const WORD = TEXT.wordmark;

/** Mark and wordmark side by side, in GlazeCorp's proportions: the gap is 28% of the mark, the type 86%. */
function lockup({ markOptions, ink }) {
  const mark = 100;
  const fontSize = mark * 0.86;
  const left = mark + mark * 0.28;
  const baseline = mark / 2 + (WORD.capHeight * fontSize) / 2;
  const width = left + WORD.bounds[2] * fontSize;
  return svg(width, mark, place(tide('full', markOptions), 0, 0, mark) + text('wordmark', left, baseline, fontSize, ink));
}

function stacked({ markOptions, ink }) {
  const fontSize = 46;
  const mark = 128;
  const gap = 24;
  const width = WORD.bounds[2] * fontSize;
  const top = mark + gap;
  const baseline = top - WORD.bounds[1] * fontSize;
  const height = baseline + WORD.bounds[3] * fontSize;
  return svg(
    width,
    height,
    place(tide('full', markOptions), (width - mark) / 2, 0, mark) + text('wordmark', 0, baseline, fontSize, ink),
  );
}

function wordmark(ink) {
  const fontSize = 100;
  const [, top, right, bottom] = WORD.bounds;
  return svg(right * fontSize, (bottom - top) * fontSize, text('wordmark', 0, -top * fontSize, fontSize, ink));
}

/* ---------------------------------------------------------- by GlazeCorp */

/*
 * Wavefront is a GlazeCorp product. The GlazeCorp mark is GlazeCorp's own artwork, kept in logo/glazecorp/ and never
 * redrawn here: it is placed as it is, in one of its approved flat fills (Ash on dark, Ink on light).
 */
const GLAZE_MARK = readFileSync(join(ROOT, 'logo/glazecorp/glazecorp-mark-128.png')).toString('base64');
const GLAZE_RATIO = 525 / 512; // the mark's width over its height
let glazeMarks = 0;

/** The GlazeCorp mark, `height` tall with its top-left corner at (x, y), in one flat colour. */
function glazeMark(x, y, height, colour) {
  const id = `glaze-${(glazeMarks += 1)}`;
  const [red, green, blue] = [1, 3, 5].map((at) => n(parseInt(colour.slice(at, at + 2), 16) / 255));
  return (
    `<filter id="${id}" color-interpolation-filters="sRGB"><feColorMatrix type="matrix" values="0 0 0 0 ${red} 0 0 0 0 ${green} 0 0 0 0 ${blue} 0 0 0 1 0"/></filter>` +
    `<image href="data:image/png;base64,${GLAZE_MARK}" x="${n(x)}" y="${n(y)}" width="${n(height * GLAZE_RATIO)}" height="${n(height)}" filter="url(#${id})"/>`
  );
}

/** "by [mark] GlazeCorp" on one line, starting at x with its baseline at `baseline`. Returns the markup and its width. */
function endorsement(x, baseline, size, { quiet, strong }) {
  const by = TEXT['endorse-by'];
  const name = TEXT['endorse-glazecorp'];
  const markTall = size * 0.92;
  const markX = x + by.width * size + size * 0.34;
  const nameX = markX + markTall * GLAZE_RATIO + size * 0.22;
  return {
    markup:
      text('endorse-by', x, baseline, size, quiet) +
      glazeMark(markX, baseline - (name.capHeight * size) / 2 - markTall / 2, markTall, strong) +
      text('endorse-glazecorp', nameX, baseline, size, strong),
    width: nameX - x + name.bounds[2] * size,
  };
}

/** The Wavefront lockup with "by GlazeCorp" under the name: for first mention, footers and launch material. */
function byGlazeCorp({ markOptions, ink, quiet }) {
  const mark = 100;
  const fontSize = mark * 0.86;
  const left = mark * 1.28;
  const small = 30;
  const line = mark + 14 + small * 0.72;
  const signed = endorsement(left + 2, line, small, { quiet, strong: ink });
  const width = Math.max(left + WORD.bounds[2] * fontSize, left + 2 + signed.width);
  return svg(
    width,
    line + small * 0.26,
    place(tide('full', markOptions), 0, 0, mark) +
      text('wordmark', left, mark / 2 + (WORD.capHeight * fontSize) / 2, fontSize, ink) +
      signed.markup,
    'Wavefront by GlazeCorp',
  );
}

/* ----------------------------------------------------------------- icons */

/** A full-bleed square for app icons and avatars. `scale` is the mark's box as a share of the square. */
function appIcon(scale) {
  const size = 512;
  const box = size * scale;
  const inset = (size - box) / 2;
  return svg(
    size,
    size,
    `<rect width="${size}" height="${size}" fill="${COLOR.ground}"/>` + place(tide('full', { disc: null }), inset, inset, box),
  );
}

/* --------------------------------------------------------------- pattern */

function hash(seed) {
  let value = 0x811c9dc5;
  for (let index = 0; index < seed.length; index += 1) {
    value ^= seed.charCodeAt(index);
    value = Math.imul(value, 0x01000193) >>> 0;
  }
  return value >>> 0;
}
const chance = (seed) => (hash(seed) % 10000) / 10000;

/*
 * Fluid: how the market is drawn. A line in Foam with
 * water under it in section: Surf, Tide, Deep, then Trench, each band following the line and roughly twice as thick
 * as the one above. `drop` is how far below the line a band starts, in units of `step`.
 */
const LAYERS = [
  [0, 'surf'],
  [0.7, 'tide'],
  [2.4, 'deep'],
  [5, 'trench'],
];

/** Bands under the line y = `line(x)`, across `width`, down to `height`. */
function layers(line, width, height, step) {
  const xs = Array.from({ length: Math.ceil(width / 8) + 1 }, (_, index) => Math.min(width, index * 8));
  const under = (drop) => `M0 ${height}${xs.map((x) => `L${n(x)} ${n(Math.min(height, line(x) + drop))}`).join('')}L${width} ${height}Z`;
  return (
    LAYERS.map(([drop, name]) => `<path d="${under(drop * step)}" fill="${COLOR[name]}"/>`).join('') +
    `<path d="M${xs.map((x) => `${n(x)} ${n(line(x))}`).join('L')}" fill="none" stroke="${COLOR.foam}" stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/>`
  );
}

/*
 * The sea over the floor, the kit's pattern: the market as fluid, a line with water under it, over a floor of blocks
 * that steps up from left to right. Blocks below, fluid above, and a clear band between them.
 */
let seaBands = 0;
function seaFloorBand({ width, height, unit, steps, lift }) {
  const cols = Math.ceil(width / unit);
  const floorRows = (col) => 1 + Math.floor((col / cols) * steps);
  // The water stands `lift` blocks over the floor on average, and rolls gently, never touching it.
  const tall = (x) =>
    unit * (1 + steps * (x / width) + lift + 1.3 * Math.sin((x / width) * Math.PI * 2 * 1.25 + 0.9) + 0.4 * Math.sin((x / width) * Math.PI * 2 * 3.1 + 2));
  let floor = '';
  let above = '';
  for (let col = 0; col < cols; col += 1) {
    const rows = floorRows(col);
    for (let row = 0; row < rows; row += 1) {
      const below = rows - 1 - row;
      const fill = below === 0 ? COLOR.surf : below <= 2 ? COLOR.tide : below <= 6 ? COLOR.deep : COLOR.trench;
      floor += rect(col * unit + (unit * GAP) / 2, height - (row + 1) * unit + (unit * GAP) / 2, unit * (1 - GAP), unit * (1 - GAP) * ROUND, { fill });
    }
    above += `<rect x="${n(col * unit)}" y="0" width="${n(unit + 0.5)}" height="${n(height - (rows + 0.45) * unit)}"/>`;
  }
  const id = `sea-${(seaBands += 1)}`;
  return `<clipPath id="${id}">${above}</clipPath><g clip-path="url(#${id})">${layers((x) => height - tall(x), width, height, unit)}</g>${floor}`;
}

function seaFloorFile() {
  const width = 1200;
  const height = 208;
  return svg(width, height, seaFloorBand({ width, height, unit: 16, steps: 5, lift: 3.4 }), 'The sea over the floor: fluid above, blocks below');
}

function layerSwellFile() {
  const width = 1200;
  const height = 192;
  const line = (x) => 78 + 30 * Math.sin((x / width) * Math.PI * 2 * 1.25 + 0.9) + 9 * Math.sin((x / width) * Math.PI * 2 * 3.1 + 2);
  return svg(width, height, layers(line, width, height, 13), 'Layer swell');
}

/** The section rule: a solid run of blocks that comes loose at its end. */
function ruleFile() {
  const cols = 60;
  let out = '';
  for (let x = 0; x < cols; x += 1) {
    const tail = x < 42 ? 0 : (x - 42) / (cols - 42);
    if (tail > 0 && chance(`r${x}`) < tail) continue;
    const opacity = tail > 0 ? 0.35 + chance(`o${x}`) * 0.6 : undefined;
    out += rect(x + GAP / 2, GAP / 2, 1 - GAP, (1 - GAP) * ROUND, { fill: COLOR.tide, opacity });
  }
  return svg(cols * 12, 12, `<g transform="scale(12)">${out}</g>`, 'Block rule');
}

/* ---------------------------------------------------------------- social */

function og() {
  const width = 1200;
  const height = 630;
  const mark = 84;
  const fontSize = mark * 0.86;
  const cell = 24;
  const rows = 8;
  return svg(
    width,
    height,
    `<rect width="${width}" height="${height}" fill="${COLOR.ground}"/>` +
      place(tide('full', { disc: null }), 72, 64, mark) +
      text('wordmark', 72 + mark * 1.28, 64 + mark / 2 + (WORD.capHeight * fontSize) / 2, fontSize, COLOR.ink) +
      endorsement(72 + mark * 1.28 + 2, 64 + mark + 30, 24, { quiet: COLOR.muted, strong: COLOR.ink }).markup +
      text('tagline', 72, 312, 60, COLOR.ink) +
      text('descriptor', 74, 358, 17, COLOR.muted) +
      `<g transform="translate(0 ${height - 192})">${seaFloorBand({ width, height: 192, unit: cell, steps: 3, lift: 2.6 })}</g>`,
    'Wavefront: launch a coin with a rising floor',
  );
}

function banner() {
  const width = 1500;
  const height = 500;
  const mark = 120;
  const fontSize = mark * 0.86;
  const cell = 25;
  const rows = 6;
  const lockupWidth = mark * 1.28 + WORD.bounds[2] * fontSize;
  const left = (width - lockupWidth) / 2;
  const top = 96;
  const descriptorSize = 18;
  return svg(
    width,
    height,
    `<rect width="${width}" height="${height}" fill="${COLOR.ground}"/>` +
      place(tide('full', { disc: null }), left, top, mark) +
      text('wordmark', left + mark * 1.28, top + mark / 2 + (WORD.capHeight * fontSize) / 2, fontSize, COLOR.ink) +
      endorsement(left + mark * 1.28 + 3, top + mark + 34, 30, { quiet: COLOR.muted, strong: COLOR.ink }).markup +
      text('descriptor', (width - TEXT.descriptor.width * descriptorSize) / 2, top + mark + 96, descriptorSize, COLOR.muted) +
      `<g transform="translate(0 ${height - 150})">${seaFloorBand({ width, height: 150, unit: cell, steps: 2, lift: 1.8 })}</g>`,
    'Wavefront',
  );
}

/* ------------------------------------------------------------- mechanics */

/*
 * Stills of what each action does, on the one picture every mechanic is explained with: the price curve, with the
 * floor as blocks and the market as fluid above it (curveSvg in src/liquidity.mjs). Each shows the market after the
 * action, with a dotted line and a hollow dot for where the curve and the price were before.
 */
const STILL = { cols: 56, rows: 18 };

function traded() {
  const market = curve.launch();
  curve.buy(market, 40_000);
  curve.buy(market, 40_000);
  return market;
}

const STILLS = {
  buy: (market) => curve.buy(market, 60_000),
  sell: (market) => curve.sell(market, curve.read(market).free * 0.5),
  heal: (market) => curve.heal(market, 60_000),
  burn: (market) => curve.burn(market, curve.read(market).circulating * 0.3),
  // Many ordinary holders, not one large one: a hundred equal wallets each take their own credit.
  borrow: (market) => curve.borrow(market, 100 * curve.credit(market, (curve.read(market).free * 0.5) / 100)),
};

/** Before and after one action, and the price at the top of the picture. */
function stillPair(name) {
  const before = traded();
  const after = traded();
  STILLS[name](after);
  const floor = curve.read(after).floor;
  const peak = Math.max(curve.read(before).price, curve.read(after).price);
  // The floor stands as many whole blocks tall as still leaves the price room under the top.
  const floorRows = [4, 3, 2, 1].find((count) => peak <= (0.86 * floor * STILL.rows) / count) ?? 1;
  return { before, after, ceiling: (floor * STILL.rows) / floorRows };
}
const STILL_PAIRS = Object.fromEntries(Object.keys(STILLS).map((name) => [name, stillPair(name)]));
const CURVE_COLOURS = { ground: COLOR.ground, muted: COLOR.muted, foam: COLOR.foam, surf: COLOR.surf, tide: COLOR.tide, deep: COLOR.deep, trench: COLOR.trench };

function still(name) {
  const width = 1200;
  const height = 675;
  const margin = 64;
  const top = 176;
  const cell = (width - 2 * margin) / STILL.cols;
  const { before, after, ceiling } = STILL_PAIRS[name];
  const now = curve.read(after);
  const priceX = margin + (now.circulating / (1e9 / STILL.cols)) * cell;
  const priceY = top + (STILL.rows - (now.price / ceiling) * STILL.rows) * cell;
  const floorY = top + (STILL.rows - (now.floor / ceiling) * STILL.rows) * cell;
  const priceWide = TEXT['label-price'].width * 12;
  return svg(
    width,
    height,
    `<rect width="${width}" height="${height}" fill="${COLOR.ground}"/>` +
      place(tide('full', { disc: null }), width - margin - 44, 66, 44) +
      text(`still-${name}`, margin, 108, 42, COLOR.ink) +
      `<g transform="translate(${margin} ${top}) scale(${n(cell)})">${curve.curveSvg(after, { ...STILL, ceiling, colours: CURVE_COLOURS, ghost: before, id: `above-${name}` })}</g>` +
      text('label-price', priceX - priceWide - 16 > margin ? priceX - priceWide - 16 : priceX + 16, priceY - 12, 12, COLOR.foam) +
      text('label-floor', width - margin - TEXT['label-floor'].width * 12, floorY - 10, 12, COLOR.surf),
    TEXT[`still-${name}`].text,
  );
}

/* ----------------------------------------------------------------- floor */

/**
 * The rising floor as a still: one run of the simulation in src/floor.mjs, with a sell-off in the middle so the price
 * is seen landing on the floor and stopping. Same seed every build, so the picture doesn't change under you.
 */
function floorStill() {
  const width = 1200;
  const height = 675;
  const margin = 64;
  const cols = 56;
  const rows = 21;
  const cell = (width - 2 * margin) / cols;
  const points = rising.history(cols, 11, (index) => (index >= 30 && index < 40 ? -1 : undefined));
  const scale = rising.range(points);
  const floorRows = (point) => Math.max(1, Math.floor(rising.rowOf(point.floor, scale, rows)));
  const priceRow = (point) => Math.max(floorRows(point), Math.round(rising.rowOf(point.price, scale, rows)));
  const at = (col, row, style) => rect(col + GAP / 2, rows - 1 - row + GAP / 2, 1 - GAP, (1 - GAP) * ROUND, style);
  // The floor has set: blocks, a row taller wherever it has ratcheted.
  let floorBlocks = '';
  points.forEach((point, col) => {
    const base = floorRows(point);
    for (let row = 0; row < base; row += 1) {
      const depth = base - 1 - row;
      floorBlocks += at(col, row, { fill: depth === 0 ? COLOR.surf : depth <= 2 ? COLOR.tide : depth <= 6 ? COLOR.deep : COLOR.trench });
    }
  });
  // The price is fluid: a line with water under it, shown only above the floor.
  // The water stops a little short of the floor, so the two never run together.
  const level = (point) => Math.max(floorRows(point) + 0.45, Math.min(rows, rising.rowOf(point.price, scale, rows)));
  const line = points.map((point, col) => [col + 0.5, rows - level(point)]);
  const bends = rising.smooth(line);
  const trace = (drop) => `M${n(line[0][0])} ${n(line[0][1] + drop)}${bends.map(([a, b, c, d, x, y]) => `C${n(a)} ${n(b + drop)} ${n(c)} ${n(d + drop)} ${n(x)} ${n(y + drop)}`).join('')}`;
  const water =
    LAYERS.map(([drop, name]) => `<path d="${trace(drop)}L${n(line.at(-1)[0])} ${rows}L${n(line[0][0])} ${rows}Z" fill="${COLOR[name]}"/>`).join('') +
    `<path d="${trace(0)}" fill="none" stroke="${COLOR.foam}" stroke-width="0.16" stroke-linejoin="round" stroke-linecap="round"/>`;
  const above = points.map((point, col) => `<rect x="${col}" y="-1" width="1.02" height="${rows + 1 - floorRows(point) - 0.45}"/>`).join('');
  const body = `<clipPath id="above-floor">${above}</clipPath><g clip-path="url(#above-floor)">${water}</g>${floorBlocks}`;
  const topOf = 150;
  const last = points.at(-1);
  const rowY = (row) => topOf + (rows - 1 - row) * cell;
  const right = width - margin;
  // A label in a pill, sitting just above the row it names, at the right edge.
  const tag = (key, middle, colour) => {
    const wide = TEXT[key].width * 12 + 24;
    return (
      `<rect x="${n(right - wide)}" y="${n(middle - 13)}" width="${n(wide)}" height="26" rx="13" fill="${COLOR.ground}" stroke="${colour}"/>` +
      text(key, right - wide + 12, middle + (TEXT[key].capHeight * 12) / 2, 12, colour)
    );
  };
  return svg(
    width,
    height,
    `<rect width="${width}" height="${height}" fill="${COLOR.ground}"/>` +
      place(tide('full', { disc: null }), width - margin - 44, 66, 44) +
      text('still-floor', margin, 108, 42, COLOR.ink) +
      `<g transform="translate(${margin} ${topOf}) scale(${n(cell)})">${body}</g>` +
      tag('label-price', rowY(priceRow(last)) - 22, COLOR.foam) +
      tag('label-floor', rowY(floorRows(last) - 1) - 22, COLOR.surf),
    'The floor only rises: a price over time with its floor rising in steps beneath it',
  );
}

/* ---------------------------------------------------------------- tokens */

const kebab = (key) => key.replace(/[A-Z0-9]+/gu, (match) => `-${match.toLowerCase()}`);

function tokensCss() {
  const vars = (object, indent = '  ') =>
    Object.entries(object)
      .map(([key, value]) => `${indent}--wf-${kebab(key)}: ${value};`)
      .join('\n');
  const face = (family, file, range) =>
    `@font-face {\n  font-family: '${family}';\n  src: url('../fonts/${file}') format('woff2');\n  font-weight: ${range};\n  font-style: normal;\n  font-display: swap;\n}`;
  return `/* Wavefront brand tokens. Generated by brand/build.mjs: edit the tokens there, not here. */

${face('Funnel Display', 'funnel-display-latin.woff2', '300 800')}
${face('Geist', 'geist-latin.woff2', '100 900')}
${face('Geist Mono', 'geist-mono-latin.woff2', '100 900')}

:root {
${vars(COLOR)}
  --wf-accent: var(--wf-tide);
  --wf-accent-text: var(--wf-tide);
  --wf-accent-on-light: ${LIGHT.accentText};

  --wf-font-display: ${FONT.display};
  --wf-font-body: ${FONT.body};
  --wf-font-mono: ${FONT.mono};
  --wf-tracking-display: -0.035em;
  --wf-tracking-label: 0.08em;

  /* Block geometry: the gap is a share of the cell, the corner a share of the block. */
  --wf-block-gap: ${GAP};
  --wf-block-round: ${ROUND};
  --wf-radius: 14px;
}

:root[data-theme='light'] {
${vars({ ground: LIGHT.ground, surface: LIGHT.surface, surface2: LIGHT.surface2, ink: LIGHT.ink, muted: LIGHT.muted, hairline: LIGHT.hairline })}
  --wf-accent-text: var(--wf-accent-on-light);
}
`;
}

function tokensJson() {
  return `${JSON.stringify(
    {
      color: { dark: COLOR, light: LIGHT },
      font: FONT,
      tracking: { display: '-0.035em', label: '0.08em' },
      block: { gap: GAP, round: ROUND },
      radius: '14px',
      mark: Object.fromEntries(Object.entries(TIDE).map(([level, { rows }]) => [level, rows])),
    },
    null,
    2,
  )}\n`;
}

/* ----------------------------------------------------------------- write */

const onDark = { markOptions: { disc: null }, ink: COLOR.ink };
const onLight = { markOptions: {}, ink: LIGHT.ink };

const FILES = {
  'logo/wavefront-mark.svg': markFile('full'),
  'logo/wavefront-mark-bare.svg': markFile('full', { disc: null }),
  'logo/wavefront-mark-small.svg': markFile('small'),
  'logo/wavefront-mark-micro.svg': markFile('micro'),
  'logo/wavefront-mark-mono-ink.svg': markFile('full', { disc: null, paint: PAINT.mono(LIGHT.ink) }),
  'logo/wavefront-mark-mono-white.svg': markFile('full', { disc: null, paint: PAINT.mono(COLOR.white) }),
  'logo/wavefront-wordmark-ash.svg': wordmark(COLOR.ink),
  'logo/wavefront-wordmark-ink.svg': wordmark(LIGHT.ink),
  'logo/wavefront-lockup-on-dark.svg': lockup(onDark),
  'logo/wavefront-lockup-on-light.svg': lockup(onLight),
  'logo/wavefront-stacked-on-dark.svg': stacked(onDark),
  'logo/wavefront-stacked-on-light.svg': stacked(onLight),
  'logo/wavefront-by-glazecorp-on-dark.svg': byGlazeCorp({ ...onDark, quiet: COLOR.muted }),
  'logo/wavefront-by-glazecorp-on-light.svg': byGlazeCorp({ ...onLight, quiet: LIGHT.muted }),
  'icons/favicon.svg': markFile('micro'),
  'icons/app-icon.svg': appIcon(0.66),
  'icons/app-icon-maskable.svg': appIcon(0.56),
  'pattern/block-rule.svg': ruleFile(),
  'pattern/layer-swell.svg': layerSwellFile(),
  'pattern/sea-floor.svg': seaFloorFile(),
  'social/og.svg': og(),
  'social/x-banner.svg': banner(),
  ...Object.fromEntries(Object.keys(STILLS).map((name) => [`graphics/${name}.svg`, still(name)])),
  'graphics/floor.svg': floorStill(),
  'tokens/tokens.css': tokensCss(),
  'tokens/tokens.json': tokensJson(),
};

// [output, source SVG, width, height]. A null width is worked out from the source's proportions.
const PNGS = [
  ['icons/token-256.png', 'logo/wavefront-mark.svg', 256, 256],
  ['icons/token-512.png', 'logo/wavefront-mark.svg', 512, 512],
  ['icons/token-1024.png', 'logo/wavefront-mark.svg', 1024, 1024],
  ['icons/favicon-16.png', 'logo/wavefront-mark-micro.svg', 16, 16],
  ['icons/favicon-32.png', 'logo/wavefront-mark-micro.svg', 32, 32],
  ['icons/favicon-48.png', 'logo/wavefront-mark-micro.svg', 48, 48],
  ['icons/apple-touch-icon.png', 'icons/app-icon.svg', 180, 180],
  ['icons/icon-192.png', 'icons/app-icon.svg', 192, 192],
  ['icons/icon-512.png', 'icons/app-icon.svg', 512, 512],
  ['icons/icon-maskable-512.png', 'icons/app-icon-maskable.svg', 512, 512],
  ['logo/png/wavefront-lockup-on-dark.png', 'logo/wavefront-lockup-on-dark.svg', null, 200],
  ['logo/png/wavefront-lockup-on-light.png', 'logo/wavefront-lockup-on-light.svg', null, 200],
  ['logo/png/wavefront-by-glazecorp-on-dark.png', 'logo/wavefront-by-glazecorp-on-dark.svg', null, 288],
  ['logo/png/wavefront-by-glazecorp-on-light.png', 'logo/wavefront-by-glazecorp-on-light.svg', null, 288],
  ['social/avatar-400.png', 'icons/app-icon.svg', 400, 400],
  ['social/og-1200x630.png', 'social/og.svg', 1200, 630],
  ['social/x-banner-1500x500.png', 'social/x-banner.svg', 1500, 500],
  ...Object.keys(STILLS).map((name) => [`graphics/png/${name}-1200x675.png`, `graphics/${name}.svg`, 1200, 675]),
  ['graphics/png/floor-1200x675.png', 'graphics/floor.svg', 1200, 675],
];

/*
 * A page as one file with nothing beside it: the stylesheet, the fonts and every image its template points at are
 * written into the page itself. It then opens anywhere, including previews that can't follow a relative path.
 * `inject` swaps markers in the template for text, which is how the liquidity page gets its model.
 */
function page(template, inject = {}) {
  const dataUri = (type, content) => `data:${type};base64,${Buffer.from(content).toString('base64')}`;
  const css = FILES['tokens/tokens.css'].replace(/url\('\.\.\/fonts\/([^']+)'\)/gu, (_, file) =>
    `url('${dataUri('font/woff2', readFileSync(join(ROOT, 'fonts', file)))}')`,
  );
  let html = readFileSync(join(ROOT, template), 'utf8')
    .replace('<!doctype html>', () => `<!doctype html>\n<!-- Generated by brand/build.mjs from ${template}. Edit the template, not this file. -->`)
    .replace('<link rel="stylesheet" href="tokens/tokens.css" />', () => `<style>\n${css}</style>`)
    .replace(/<link rel="stylesheet" href="(elements\/[^"]+\.css)" \/>/gu, (_, path) => `<style>\n${FILES[path]}</style>`)
    .replace(/(src|href)="((?:logo|icons|pattern|social|graphics)\/[^"]+\.svg)"/gu, (_, attribute, path) => {
      if (!FILES[path]) throw new Error(`${template} points at ${path}, which build.mjs does not make`);
      return `${attribute}="${dataUri('image/svg+xml', FILES[path])}"`;
    });
  for (const [marker, text] of Object.entries(inject)) {
    if (!html.includes(marker)) throw new Error(`${template} has no ${marker} marker`);
    html = html.replace(marker, () => text);
  }
  return html;
}
// The site elements: the module and stylesheet as files a site can import, one SVG an icon, and a gallery page.
for (const [key, value] of Object.entries(elements.palette)) {
  if (COLOR[key] !== value) throw new Error(`src/elements.mjs palette.${key} is ${value}, but the brand token is ${COLOR[key]}`);
}
const ELEMENTS = readFileSync(join(ROOT, 'src/elements.mjs'), 'utf8');
FILES['elements/wavefront-elements.mjs'] = `// Copied from brand/src/elements.mjs by brand/build.mjs. Edit the source, not this file.\n${ELEMENTS}`;
FILES['elements/wavefront.css'] = readFileSync(join(ROOT, 'src/elements.css'), 'utf8');
for (const name of Object.keys(elements.ICONS)) {
  FILES[`elements/icons/${name}.svg`] = `${elements.icon(name, { size: 36, colour: COLOR.ink })}\n`;
}
FILES['elements.html'] = page('src/elements.template.html', { '/*__ELEMENTS_MODULE__*/': ELEMENTS.replace(/^export /gmu, '') });

const MODEL = readFileSync(join(ROOT, 'src/liquidity.mjs'), 'utf8').replace(/^export /gmu, '');
// The guidelines page draws its mechanics pictures itself, from the same before-and-after markets as the stills.
const STILL_DATA = `const STILL = ${JSON.stringify(STILL)};\n      const STILL_PAIRS = ${JSON.stringify(STILL_PAIRS)};`;
FILES['guidelines.html'] = page('src/guidelines.template.html', {
  '/*__LIQUIDITY_MODULE__*/': MODEL,
  '/*__STILL_SHAPES__*/': STILL_DATA,
});
FILES['graphics/liquidity.html'] = page('src/liquidity.template.html', { '/*__LIQUIDITY_MODULE__*/': MODEL });
const FLOOR = readFileSync(join(ROOT, 'src/floor.mjs'), 'utf8').replace(/^import .*$/gmu, '').replace(/^export /gmu, '');
FILES['graphics/floor.html'] = page('src/floor.template.html', { '/*__FLOOR_MODULES__*/': `${MODEL}\n${FLOOR}` });

/*
 * The whole kit on one page: the guidelines, the site elements, the rising floor, the curve and the social images,
 * one after another. It is put together from the same templates as the separate pages. Each template's styles are
 * nested under a class of its own, so the pages can't restyle each other, and each keeps its own script.
 */
function part(name, template, inject = {}) {
  const dataUri = (path) => `data:image/svg+xml;base64,${Buffer.from(FILES[path]).toString('base64')}`;
  let html = readFileSync(join(ROOT, template), 'utf8').replace(
    /(src|href)="((?:logo|icons|pattern|social|graphics)\/[^"]+\.svg)"/gu,
    (_, attribute, path) => `${attribute}="${dataUri(path)}"`,
  );
  for (const [marker, text] of Object.entries(inject)) html = html.replace(marker, () => text);
  const own = /<style>([\s\S]*?)<\/style>/u.exec(html)[1].replace(/(^|[\s,}])body(\s*\{)/gu, '$1&$2');
  const body = /<body>([\s\S]*?)<\/body>/u.exec(html)[1];
  return { css: `.kit-${name} {\n${own}\n}`, body: `<div class="kit-${name}" id="kit-${name}">${body}</div>` };
}

function kit({ bare = false } = {}) {
  const dataUri = (type, content) => `data:${type};base64,${Buffer.from(content).toString('base64')}`;
  const image = (path) => dataUri('image/svg+xml', FILES[path]);
  // The kit commits to the dark look, so the light-theme token block is left out: a viewer set to light would
  // otherwise get a half-switched page.
  const fonts = FILES['tokens/tokens.css']
    .replace(/url\('\.\.\/fonts\/([^']+)'\)/gu, (_, file) => `url('${dataUri('font/woff2', readFileSync(join(ROOT, 'fonts', file)))}')`)
    .replace(/:root\[data-theme='light'\] \{[\s\S]*?\n\}\n/u, '');
  const parts = [
    part('guidelines', 'src/guidelines.template.html', {
      '/*__LIQUIDITY_MODULE__*/': MODEL,
      '/*__STILL_SHAPES__*/': STILL_DATA,
    }),
    part('elements', 'src/elements.template.html', { '/*__ELEMENTS_MODULE__*/': ELEMENTS.replace(/^export /gmu, '') }),
    part('floor', 'src/floor.template.html', { '/*__FLOOR_MODULES__*/': `${MODEL}\n${FLOOR}` }),
    part('liquidity', 'src/liquidity.template.html', { '/*__LIQUIDITY_MODULE__*/': MODEL }),
  ];
  // Every SVG the kit makes, on one shelf per kind.
  const KINDS = [
    ['Logo', (file) => file.startsWith('logo/'), false],
    ['Icons', (file) => file.startsWith('icons/') || file.startsWith('elements/icons/'), false],
    ['Mechanics', (file) => file.startsWith('graphics/'), true],
    ['Patterns', (file) => file.startsWith('pattern/'), true],
    ['Social', (file) => file.startsWith('social/'), true],
  ];
  const onLight = (file) => /on-light|mono-ink|wordmark-ink/u.test(file);
  const shelves = KINDS.map(([kind, belongs, wide]) => {
    const files = Object.keys(FILES).filter((file) => file.endsWith('.svg') && belongs(file));
    const items = files
      .map((file) => `<figure><div class="kit-stage${onLight(file) ? ' light' : ''}"><img src="${image(file)}" alt="" /></div><figcaption>${file}</figcaption></figure>`)
      .join('');
    return `<h3>${kind}</h3><div class="kit-shelf${wide ? ' wide' : ''}">${items}</div>`;
  }).join('\n      ');
  const stops = [
    ['Logo', 'mark'], ['Colour', 'colour'], ['Type', 'type'], ['Rules', 'rules'], ['Blocks', 'blocks'], ['Mechanics', 'mechanics'], ['Messaging', 'messaging'],
    ['Hero', 'kit-elements'], ['Glyphs and icons', 'glyphs'], ['Rising floor', 'kit-floor'], ['Curve', 'kit-liquidity'], ['Every graphic', 'kit-social'],
  ];
  const full = `<!doctype html>
<!-- Generated by brand/build.mjs from the templates in src/. Edit those, not this file. -->
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Wavefront brand kit</title>
    <link rel="icon" href="${image('icons/favicon.svg')}" />
    <style>
${fonts}
${FILES['elements/wavefront.css']}
:root { color-scheme: dark; }
html { scroll-behavior: smooth; }
body { margin: 0; background: var(--wf-ground); color: var(--wf-ink); }
body::before { content: ""; position: fixed; inset: 0 0 auto; height: env(safe-area-inset-top, 0px); z-index: 10; background: var(--wf-ground); }
.kit-nav {
  position: sticky; top: env(safe-area-inset-top, 0px); z-index: 10; display: flex; gap: 4px; align-items: center; overflow-x: auto;
  padding-block: 10px; padding-left: max(16px, env(safe-area-inset-left, 0px)); padding-right: max(16px, env(safe-area-inset-right, 0px)); background: rgb(11 11 11 / 0.92); border-bottom: 1px solid var(--wf-hairline);
}
.kit-nav img { height: 22px; margin-right: 12px; flex: none; }
.kit-nav button {
  flex: none; font: 500 13px/1 var(--wf-font-body); color: var(--wf-ink-2); background: none; border: 0;
  border-radius: 8px; padding: 8px 10px; cursor: pointer;
}
.kit-nav button:hover { background: var(--wf-surface-2); color: var(--wf-ink); }
.kit-nav button:focus-visible { outline: 2px solid var(--wf-foam); outline-offset: 1px; }
[id] { scroll-margin-top: 64px; }
.kit-guidelines > main { padding-bottom: 40px; }
.kit-guidelines header { padding-top: 48px; }
.kit-liquidity header, .kit-elements .hero-copy img, .kit-floor .copy img { display: none; }
.kit-elements, .kit-floor, .kit-liquidity, .kit-social { border-top: 1px solid var(--wf-hairline); }
.kit-social { max-width: 1120px; margin: 0 auto; padding: 56px 24px 96px; color: var(--wf-ink); font: 400 15px/1.5 var(--wf-font-body); border-top: 0; }
.kit-social h2 { margin: 0 0 8px; font: 500 34px/1.1 var(--wf-font-display); letter-spacing: var(--wf-tracking-display); }
.kit-social p { margin: 0 0 24px; max-width: 66ch; color: var(--wf-muted); }
.kit-social h3 { margin: 32px 0 12px; font: 500 16px/1.3 var(--wf-font-body); }
.kit-shelf { display: grid; gap: 16px; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); }
.kit-shelf.wide { grid-template-columns: repeat(auto-fill, minmax(min(100%, 340px), 1fr)); }
.kit-shelf figure { margin: 0; min-width: 0; }
.kit-stage { display: flex; align-items: center; justify-content: center; min-height: 132px; padding: 18px; border: 1px solid var(--wf-hairline); border-radius: var(--wf-radius); background: var(--wf-ground); }
.kit-stage.light { background: #ffffff; border-color: transparent; }
.kit-shelf .kit-stage img { display: block; width: 100%; height: 96px; object-fit: contain; border: 0; border-radius: 0; }
.kit-shelf.wide .kit-stage { padding: 0; min-height: 0; overflow: hidden; }
.kit-shelf.wide .kit-stage img { height: auto; }
.kit-shelf figcaption { overflow-wrap: anywhere; }
.kit-social figure { margin: 0 0 24px; }
.kit-social figure img { display: block; width: 100%; border: 1px solid var(--wf-hairline); border-radius: var(--wf-radius); }
.kit-social figcaption { margin-top: 8px; font: 500 11px/1.4 var(--wf-font-mono); letter-spacing: var(--wf-tracking-label); text-transform: uppercase; color: var(--wf-muted); }
.kit-social .icons { display: flex; gap: 24px; flex-wrap: wrap; align-items: flex-end; }
.kit-social .icons img { width: auto; border-radius: 0; border: 0; }
${parts.map((piece) => piece.css).join('\n')}
/* One side gutter for every part, clear of a phone's system bars. */
.kit-guidelines main, .kit-elements main, .kit-liquidity main, .kit-social, .kit-floor .bar, .kit-floor .foot,
.kit-floor .copy, .kit-elements .hero-copy, .kit-elements .hero-bar {
  padding-left: max(24px, env(safe-area-inset-left, 0px));
  padding-right: max(24px, env(safe-area-inset-right, 0px));
}
    </style>
  </head>
  <body>
    <nav class="kit-nav" aria-label="Brand kit sections">
      <img src="${image('logo/wavefront-lockup-on-dark.svg')}" alt="Wavefront" />
      ${stops.map(([label, id]) => `<button type="button" data-go="${id}">${label}</button>`).join('')}
    </nav>
    ${parts.map((piece) => piece.body).join('\n')}
    <hr style="border: 0; border-top: 1px solid var(--wf-hairline); margin: 0" />
    <div class="kit-social" id="kit-social">
      <h2>Every graphic</h2>
      <p>Everything in the kit, by file name. PNG versions of the icons, lockups, stills and social images sit beside these in the same folders. All the files are in the <a href="https://github.com/Heesho/wavefront-monorepo/tree/main/brand" style="color: var(--wf-accent-text)">brand folder of the Wavefront repository</a>.</p>
      ${shelves}
    </div>
    <script>
      for (const button of document.querySelectorAll('[data-go]')) {
        button.addEventListener('click', () => document.getElementById(button.dataset.go).scrollIntoView());
      }
    </script>
  </body>
</html>
`;
  if (!bare) return full;
  // For publishing as a Claude Artifact, which supplies the document around the page: title, styles and content only.
  const styles = /<style>([\s\S]*?)<\/style>\n {2}<\/head>/u.exec(full)[1];
  const content = /<body>([\s\S]*)<\/body>/u.exec(full)[1];
  return `<title>Wavefront brand kit</title>\n<meta name="claude:viewport-fit-sides" content="cover">\n<style>${styles}</style>\n${content}`;
}
FILES['index.html'] = kit();
FILES['share/wavefront-brand-kit.html'] = kit({ bare: true });

for (const [path, content] of Object.entries(FILES)) {
  mkdirSync(dirname(join(ROOT, path)), { recursive: true });
  writeFileSync(join(ROOT, path), content);
}
console.log(`wrote ${Object.keys(FILES).length} files`);

/* ------------------------------------------------------------------- png */

function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ];
  return candidates.find((candidate) => candidate && existsSync(candidate));
}

/*
 * Chrome will not open a window narrower than a few hundred pixels, so a small PNG can't be a screenshot of a small
 * window. Instead the page draws the SVG onto a canvas of the exact size and Chrome prints the page's DOM, which
 * carries the PNG as a data URL.
 */
function render(chrome, scratch, [output, source, givenWidth, height], index) {
  const [, , boxWidth, boxHeight] = /viewBox="([^"]+)"/u.exec(FILES[source])[1].split(' ').map(Number);
  const width = givenWidth ?? Math.round((height * boxWidth) / boxHeight);
  const page = join(scratch, `${index}.html`);
  writeFileSync(
    page,
    `<!doctype html><title>pending</title><script>
const image = new Image();
image.onload = () => {
  const canvas = Object.assign(document.createElement('canvas'), { width: ${width}, height: ${height} });
  canvas.getContext('2d').drawImage(image, 0, 0, ${width}, ${height});
  document.body.textContent = canvas.toDataURL('image/png');
  document.title = 'done';
};
image.src = ${JSON.stringify(`data:image/svg+xml;base64,${Buffer.from(FILES[source]).toString('base64')}`)};
</script><body></body>`,
  );
  const args = [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--force-device-scale-factor=1',
    `--user-data-dir=${join(scratch, `profile-${index}`)}`,
    '--virtual-time-budget=5000',
    '--dump-dom',
    pathToFileURL(page).href,
  ];
  return new Promise((resolve, reject) => {
    execFile(chrome, args, { maxBuffer: 256 * 1024 * 1024 }, (error, stdout) => {
      if (error) return reject(error);
      const match = /data:image\/png;base64,([A-Za-z0-9+/=]+)/u.exec(stdout);
      if (!match) return reject(new Error(`Chrome did not return an image for ${output}`));
      mkdirSync(dirname(join(ROOT, output)), { recursive: true });
      writeFileSync(join(ROOT, output), Buffer.from(match[1], 'base64'));
      resolve(output);
    });
  });
}

if (process.argv.includes('--png')) {
  const chrome = findChrome();
  if (!chrome) {
    console.error('No Chrome found, so no PNGs were rendered. Set CHROME_PATH to a Chrome or Chromium binary.');
    process.exit(1);
  }
  const scratch = mkdtempSync(join(tmpdir(), 'wavefront-brand-'));
  try {
    // A few at a time: each render is its own short-lived Chrome.
    for (let start = 0; start < PNGS.length; start += 4) {
      const batch = PNGS.slice(start, start + 4);
      await Promise.all(batch.map((job, offset) => render(chrome, scratch, job, start + offset)));
    }
    console.log(`rendered ${PNGS.length} PNGs`);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

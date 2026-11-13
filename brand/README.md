# Wavefront brand kit

Logos, icons, social images, colours and type for Wavefront. Open [`guidelines.html`](guidelines.html) in a browser for the rules and a look at everything.

Wavefront is drawn in the block language it shares with GlazeCorp: rounded blocks with a gap of 14% of the cell and corners at 22% of the block. The mark is the Tide, a coin made of blocks and filled to a wave line. The palette is Afterglow: indigo, blue, violet, pink and amber, running from the deepest water up to the wave line, on a `#0b0b0b` ground. The accent is the violet, `#b14cff`.

Every picture follows the same rules. Blocks are the floor: anything at or below the floor price, locked in. Fluid is the market: anything above it. Up is price, so the floor sits at the bottom and the market over it. A filled block holds money and an outline is empty. Fluid sets into blocks and never the reverse, and the two never touch. The logo, glyphs, icons and meters are blocks too. The guidelines page has the full table.

## What to use

| Need | File |
|---|---|
| Logo on a dark page | `logo/wavefront-lockup-on-dark.svg` |
| Logo on a light page | `logo/wavefront-lockup-on-light.svg` |
| Mark alone, 48px and up | `logo/wavefront-mark.svg` |
| Mark alone, 24 to 47px | `logo/wavefront-mark-small.svg` |
| Mark alone, 16 to 23px | `logo/wavefront-mark-micro.svg` |
| Token icon for wallets, scanners and token lists | `icons/token-256.png`, `token-512.png`, `token-1024.png` |
| Favicon | `icons/favicon.svg`, `favicon-16.png`, `favicon-32.png`, `favicon-48.png` |
| App and home-screen icons | `icons/apple-touch-icon.png`, `icon-192.png`, `icon-512.png`, `icon-maskable-512.png` |
| Social profile picture | `social/avatar-400.png` |
| Link preview image | `social/og-1200x630.png` |
| X header | `social/x-banner-1500x500.png` |
| Background patterns, in blocks and in layers | `pattern/sea-floor.svg`, `pattern/layer-swell.svg`, `pattern/block-rule.svg` |
| Glyphs, icons, meters and price lines for the site | `elements/wavefront-elements.mjs`, `elements/wavefront.css`, `elements/icons/`; gallery in `elements.html` |
| The floor rising under the price, live and as a still | `graphics/floor.html`, `graphics/floor.svg`, `graphics/png/floor-1200x675.png` |
| The protocol's mechanics, animated | `graphics/liquidity.html` |
| A still of one mechanic | `graphics/buy.svg`, `sell.svg`, `heal.svg`, `burn.svg`, `borrow.svg`, and PNGs in `graphics/png/` |
| Colours, fonts and block geometry in code | `tokens/tokens.css`, `tokens/tokens.json` |

The logo folder also has stacked lockups, the wordmark alone, the mark without its disc (`-bare`, for dark grounds only) and one-colour marks.

## Changing it

Everything except the fonts and this file is generated. Edit [`build.mjs`](build.mjs), or [`src/guidelines.template.html`](src/guidelines.template.html) for the guidelines page, then:

```bash
yarn brand
```

That rewrites the SVGs and token files and renders the PNGs with a local Chrome. Set `CHROME_PATH` if Chrome isn't in its usual place; `node brand/build.mjs` without `--png` skips the PNGs and needs nothing installed.

The wordmark and the two lines of text on the social images are stored as outlines in `src/text-paths.json`, so no file depends on an installed font. To change that text, edit the strings in [`src/outline-text.py`](src/outline-text.py) and run it; the file's header says how.

## Mechanics graphics

The pictures in `graphics/` are drawn to scale from the protocol's formulas by [`src/liquidity.mjs`](src/liquidity.mjs). The main one is the price curve: price up the side against coins held along the bottom, with blocks under the floor price (the quote that guarantees the floor for the coins held) and fluid above it up to the curve. A loan hollows the floor blocks under the coins borrowed against. `graphics/liquidity.html` is that picture live, with buttons for buy, sell, heal, burn, borrow and repay.

The hero at the top of `elements.html` is different: a sea of blocks moved by a wave equation. Its level stands for the price and its bed for the floor, but it is a mood piece and not to scale.

`graphics/floor.html` shows the floor through time: a simulated coin's price over a floor that climbs in steps, run by [`src/floor.mjs`](src/floor.mjs) on the same formulas. It is fast-forwarded (each column is fourteen trades on a very busy coin, and a new coin starts once the floor has risen thirtyfold) and drawn on a logarithmic scale.

One simplification: heals and burns land at once, as in v1. On Uniswap v4 they wait until they are worth one tick step.

## Fonts

Funnel Display, Geist and Geist Mono, Latin subsets, each under the SIL Open Font License. The licence for each sits beside it in `fonts/`.

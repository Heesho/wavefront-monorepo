#!/usr/bin/env python3
"""Turn the brand's set text into SVG outlines, so no logo or social image depends on an installed font.

Writes text-paths.json next to this file. build.mjs reads it and never touches a font itself, so this only needs
running when a string below, its face, its weight or its tracking changes.

    python3 -m venv .venv && .venv/bin/pip install fonttools brotli uharfbuzz
    .venv/bin/python brand/src/outline-text.py

Each entry is drawn at a font size of 1: x runs right from 0, y runs down, and the baseline sits at y = 0.
"""
import io
import json
from pathlib import Path

import uharfbuzz as hb
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

HERE = Path(__file__).resolve().parent
FONTS = HERE.parent / "fonts"

# key: (font file, weight, tracking in em, text)
STRINGS = {
    "wordmark": ("funnel-display-latin.woff2", 500, -0.035, "Wavefront"),
    "tagline": ("funnel-display-latin.woff2", 500, -0.02, "Launch a coin with a rising floor."),
    "descriptor": ("geist-mono-latin.woff2", 500, 0.08, "BONDING-CURVE COIN LAUNCHER"),
    # The mechanics stills in graphics/.
    "still-buy": ("funnel-display-latin.woff2", 500, -0.02, "A buy moves up the curve"),
    "still-sell": ("funnel-display-latin.woff2", 500, -0.02, "A sell moves back down, never under the floor"),
    "still-heal": ("funnel-display-latin.woff2", 500, -0.02, "A heal lifts the curve and the floor"),
    "still-burn": ("funnel-display-latin.woff2", 500, -0.02, "A burn shrinks the supply and lifts the floor"),
    "still-borrow": ("funnel-display-latin.woff2", 500, -0.02, "A loan hollows the floor under its coins"),
    # "by GlazeCorp", under the Wavefront lockup.
    "endorse-by": ("funnel-display-latin.woff2", 500, -0.02, "by"),
    "endorse-glazecorp": ("funnel-display-latin.woff2", 500, -0.035, "GlazeCorp"),
    "still-floor": ("funnel-display-latin.woff2", 500, -0.02, "The floor only rises"),
    "label-before": ("geist-mono-latin.woff2", 500, 0.08, "BEFORE"),
    "label-after": ("geist-mono-latin.woff2", 500, 0.08, "AFTER"),
    "label-floor": ("geist-mono-latin.woff2", 500, 0.08, "FLOOR"),
    "label-price": ("geist-mono-latin.woff2", 500, 0.08, "PRICE"),
    "label-virtual": ("geist-mono-latin.woff2", 500, 0.08, "VIRTUAL QUOTE"),
    "label-quote": ("geist-mono-latin.woff2", 500, 0.08, "QUOTE IN THE POOL"),
    "label-coins": ("geist-mono-latin.woff2", 500, 0.08, "COINS IN THE POOL"),
    "label-lent": ("geist-mono-latin.woff2", 500, 0.08, "LENT OUT"),
}


def instance(file: str, weight: int) -> bytes:
    font = TTFont(FONTS / file)
    if "fvar" in font:
        font = instancer.instantiateVariableFont(font, {"wght": weight})
    font.flavor = None
    out = io.BytesIO()
    font.save(out)
    return out.getvalue()


def outline(file: str, weight: int, tracking: float, text: str) -> dict:
    data = instance(file, weight)
    font = TTFont(io.BytesIO(data))
    upem = font["head"].unitsPerEm
    glyphs = font.getGlyphSet()
    order = font.getGlyphOrder()

    hb_font = hb.Font(hb.Face(data))
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hb_font, buf, {"kern": True, "liga": True})

    pen = SVGPathPen(glyphs, ntos=lambda v: f"{v:.4f}".rstrip("0").rstrip("."))
    bounds = BoundsPen(glyphs)
    x = 0.0
    last = len(buf.glyph_infos) - 1
    for index, (info, pos) in enumerate(zip(buf.glyph_infos, buf.glyph_positions)):
        scale = 1 / upem
        # Flip y so the path is in SVG's coordinate system, baseline at 0.
        transform = (scale, 0, 0, -scale, x + pos.x_offset * scale, -pos.y_offset * scale)
        glyphs[order[info.codepoint]].draw(TransformPen(pen, transform))
        glyphs[order[info.codepoint]].draw(TransformPen(bounds, transform))
        x += pos.x_advance * scale + (tracking if index < last else 0)

    os2 = font["OS/2"]
    return {
        "text": text,
        "font": file,
        "weight": weight,
        "tracking": tracking,
        "width": round(x, 4),
        "capHeight": round(os2.sCapHeight / upem, 4),
        "xHeight": round(os2.sxHeight / upem, 4),
        # Ink bounds: [left, top, right, bottom]. Top is negative (above the baseline).
        "bounds": [round(v, 4) for v in bounds.bounds],
        "d": pen.getCommands(),
    }


if __name__ == "__main__":
    result = {key: outline(*spec) for key, spec in STRINGS.items()}
    (HERE / "text-paths.json").write_text(json.dumps(result, indent=1) + "\n")
    for key, entry in result.items():
        print(f"{key}: width {entry['width']} em, {len(entry['d'])} chars")

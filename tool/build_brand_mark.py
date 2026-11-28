#!/usr/bin/env python3
"""Render the Mithka X mark into the Android cold-start rasters.

In the app the mark is painted (`lib/components/brand_mark.dart`), so it can
follow the theme's brand colour and the light/dark appearance. Android's
starting window is a native drawable and cannot: it gets baked copies instead,
AZURE on the white launch colour and a lifted AZURE under
`drawable-night-*`, one per density bucket. Both appearances are blue: the
frost (near-white) night fill is gone, so no baked Mithka X mark reads as a
white glyph.

`tool/app_icons/mithkax_mark.svg` is the canonical geometry; every raster here
is generated from it.
"""

import argparse
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tool/app_icons/mithkax_mark.svg"
ANDROID_RES = ROOT / "android/app/src/main/res"
CANVAS = 1024

# Ink height as a share of the canvas. The square master keeps the weight the
# old mascot art had (73% of the canvas); the native splash sits inside the
# Android 12 circle mask, which reserves the outer third.
MASTER_INK_HEIGHT = 0.72
SPLASH_INK_HEIGHT = 0.62

# Stops sampled from the launcher icon's mark (assets/app_icons/
# mithkax_default{,_night}.png), top-left to bottom-right.
AZURE = ((0x2B, 0xA7, 0xF9), (0x0A, 0x8B, 0xF9), (0x01, 0x68, 0xF1))

# The night fill is the same brand hue, lifted so it carries on the near-black
# starting window. It stays saturated blue on purpose: FROST (a near-white
# ladder) made the cold-start mark look like a white glyph.
NIGHT_AZURE = ((0x7C, 0xC7, 0xFB), (0x47, 0xAC, 0xF7), (0x24, 0x8F, 0xEE))

DENSITIES = {
    "mdpi": 192,
    "hdpi": 288,
    "xhdpi": 384,
    "xxhdpi": 576,
    "xxxhdpi": 768,
}

# The supplied glyph, verbatim: a 768 box whose path is shifted by -128.
ORIGINAL_PATH = (
    "M 179.03 440.27 C 179.03 428.85 179.03 417.43 183.62 405.49 "
    "A 60.00 60.00 0 0 1 193.00 389.23 C 201.05 379.28 210.95 373.57 "
    "220.84 367.86 L 501.49 205.83 C 520.92 194.61 540.35 183.39 "
    "559.93 187.55 A 40.00 40.00 0 0 1 581.33 199.91 C 594.72 214.78 "
    "594.72 237.22 594.72 259.66 L 594.72 327.41 C 594.72 340.87 594.72 354.33 "
    "602.76 363.25 A 24.00 24.00 0 0 0 615.60 370.67 C 627.34 373.17 "
    "639.00 366.43 650.66 359.70 L 709.34 325.83 C 728.77 314.61 748.20 303.39 "
    "767.77 307.55 A 40.00 40.00 0 0 1 789.18 319.91 C 802.57 334.78 "
    "802.57 357.22 802.57 379.66 L 802.57 703.73 C 802.57 715.15 802.57 726.57 "
    "797.98 738.51 A 60.00 60.00 0 0 1 788.60 754.77 C 780.55 764.72 "
    "770.65 770.43 760.76 776.14 L 687.96 818.17 C 668.52 829.39 649.09 840.61 "
    "629.52 836.45 A 40.00 40.00 0 0 1 608.11 824.09 C 594.72 809.22 "
    "594.72 786.78 594.72 764.34 L 594.72 696.59 C 594.72 683.13 594.72 669.67 "
    "586.69 660.75 A 24.00 24.00 0 0 0 573.84 653.33 C 562.10 650.83 "
    "550.44 657.57 538.78 664.30 L 480.11 698.17 C 460.68 709.39 441.25 720.61 "
    "421.67 716.45 A 40.00 40.00 0 0 1 400.27 704.09 C 386.88 689.22 "
    "386.88 666.78 386.88 644.34 L 386.88 576.59 C 386.88 563.13 386.88 549.67 "
    "378.84 540.75 A 24.00 24.00 0 0 0 366.00 533.33 C 354.26 530.83 "
    "342.60 537.57 330.94 544.30 L 272.26 578.17 C 252.83 589.39 233.40 600.61 "
    "213.83 596.45 A 40.00 40.00 0 0 1 192.42 584.09 C 179.03 569.22 "
    "179.03 546.78 179.03 524.34 Z"
)


def write_master():
    """Write the canonical SVG from the supplied glyph, glyph centred."""
    import cairosvg
    from PIL import Image

    with tempfile.TemporaryDirectory(prefix="brand-mark-") as directory:
        raw_svg = Path(directory) / "raw.svg"
        raw_png = Path(directory) / "raw.png"
        raw_svg.write_text(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 768 768"'
            ' width="768" height="768">'
            f'<path transform="translate(-128 -128)" d="{ORIGINAL_PATH}" />'
            "</svg>"
        )
        cairosvg.svg2png(
            url=str(raw_svg), write_to=str(raw_png), output_width=2048,
            output_height=2048,
        )
        box = Image.open(raw_png).getbbox()
    # getbbox() is in 2048 raster pixels; map it back to the 768 box.
    x0, y0, x1, y1 = (value * 768 / 2048 for value in box)
    width, height = x1 - x0, y1 - y0
    scale = CANVAS * MASTER_INK_HEIGHT / height
    tx = (CANVAS - width * scale) / 2 - x0 * scale
    ty = (CANVAS - height * scale) / 2 - y0 * scale
    SOURCE.parent.mkdir(parents=True, exist_ok=True)
    SOURCE.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"'
        ' width="1024" height="1024">\n'
        "  <!-- Mithka X mark, 1024 square with the glyph centred and its ink at"
        f" {MASTER_INK_HEIGHT:.0%} of the height. -->\n"
        f'  <g transform="translate({tx:.3f} {ty:.3f}) scale({scale:.6f})">\n'
        '    <path transform="translate(-128 -128)" fill="#000000"'
        f' d="{ORIGINAL_PATH}" />\n'
        "  </g>\n"
        "</svg>\n"
    )


def render_master(size):
    """Rasterise the canonical SVG on a transparent square canvas."""
    import cairosvg
    from PIL import Image

    with tempfile.TemporaryDirectory(prefix="brand-mark-") as directory:
        png = Path(directory) / "master.png"
        cairosvg.svg2png(
            url=str(SOURCE), write_to=str(png), output_width=size,
            output_height=size,
        )
        return Image.open(png).convert("RGBA")


def fit(ink, height):
    """Scale cropped ink to [height], keeping its aspect."""
    from PIL import Image

    return ink.resize(
        (max(1, round(height * ink.width / ink.height)), max(1, height)),
        Image.Resampling.LANCZOS,
    )


def gradient_plate(size, stops):
    """Diagonal (top-left → bottom-right) gradient of [stops] at [size]."""
    from PIL import Image

    side = 256
    plate = Image.new("RGB", (side, side))
    pixels = plate.load()
    for y in range(side):
        for x in range(side):
            t = (x / (side - 1) + y / (side - 1)) / 2
            if t <= 0.5:
                a, b, local = stops[0], stops[1], t * 2
            else:
                a, b, local = stops[1], stops[2], (t - 0.5) * 2
            pixels[x, y] = tuple(
                round(a[i] + (b[i] - a[i]) * local) for i in range(3)
            )
    return plate.resize(size, Image.Resampling.BICUBIC)


def compose(ink, canvas, stops):
    """Centre the glyph, filled with [stops], on a transparent square canvas."""
    from PIL import Image

    art = gradient_plate(ink.size, stops).convert("RGBA")
    art.putalpha(ink.getchannel("A"))
    plate = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    plate.paste(art, ((canvas - ink.width) // 2, (canvas - ink.height) // 2), art)
    return plate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the master renders and fills the expected share of the canvas",
    )
    args = parser.parse_args()

    write_master()
    if args.check:
        master = render_master(CANVAS)
        box = master.getbbox()
        share = (box[3] - box[1]) / CANVAS
        if abs(share - MASTER_INK_HEIGHT) > 0.01:
            raise SystemExit(f"ink height {share:.3f} != {MASTER_INK_HEIGHT}")
        left, right = box[0], CANVAS - box[2]
        if abs(left - right) > 2:
            raise SystemExit(f"glyph off centre: {left} vs {right}")
        print(f"ok: ink {box[2] - box[0]}x{box[3] - box[1]} in {CANVAS}")
        return

    master = render_master(4096)
    ink = master.crop(master.getbbox())

    # Android cold-start art: AZURE on the light launch colour, the lifted
    # blue on the night one, sized per density so no bucket upscales.
    for qualifier, size in DENSITIES.items():
        target = round(size * SPLASH_INK_HEIGHT)
        for name in ("penguin_launch", "penguin_splash"):
            for bucket, stops in (
                (f"drawable-{qualifier}", AZURE),
                (f"drawable-night-{qualifier}", NIGHT_AZURE),
            ):
                (ANDROID_RES / bucket).mkdir(exist_ok=True)
                compose(fit(ink, target), size, stops).save(
                    ANDROID_RES / bucket / f"{name}.png", optimize=True
                )
    for bucket, stops in (
        ("drawable", AZURE),
        ("drawable-night", NIGHT_AZURE),
    ):
        (ANDROID_RES / bucket).mkdir(exist_ok=True)
        compose(
            fit(ink, round(CANVAS * SPLASH_INK_HEIGHT)), CANVAS, stops
        ).save(ANDROID_RES / bucket / "penguin_launch.png", optimize=True)
    print("ok")


if __name__ == "__main__":
    main()

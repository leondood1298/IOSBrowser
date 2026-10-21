#!/usr/bin/env python3
"""Draws the 1024 px app icon with Pillow: a white globe with a download badge on a blue
gradient, with a soft shadow. The arrow and the ring around the badge are cut out, so the
gradient shows through them.

Usage: python scripts/make_icon.py
Writes App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.
"""

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # draw large, then downsample for smooth edges
TOP_LEFT = (18, 64, 190)
BOTTOM_RIGHT = (36, 150, 240)
WHITE = (255, 255, 255, 255)
CLEAR = (0, 0, 0, 0)
OUTPUT = Path(__file__).resolve().parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def gradient(size):
    """A diagonal gradient from the top left to the bottom right."""
    small = 256
    image = Image.new("RGB", (small, small))
    pixels = image.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * (small - 1))
            pixels[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(TOP_LEFT, BOTTOM_RIGHT))
    return image.resize((size, size), Image.BICUBIC)


def glyph(s):
    """The white globe and badge on a transparent layer."""
    layer = Image.new("RGBA", (s, s), CLEAR)
    draw = ImageDraw.Draw(layer)
    cx, cy = s // 2, int(s * 0.47)
    r = int(s * 0.30)
    stroke = int(s * 0.034)
    thin = int(s * 0.024)

    # Globe outline, meridian and latitude lines.
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=WHITE, width=stroke)
    meridian = int(r * 0.48)
    draw.ellipse([cx - meridian, cy - r, cx + meridian, cy + r], outline=WHITE, width=thin)
    draw.line([cx, cy - r, cx, cy + r], fill=WHITE, width=thin)
    inner = r - stroke // 2  # keep line ends inside the outline
    draw.line([cx - inner, cy, cx + inner, cy], fill=WHITE, width=thin)
    for offset in (-0.5, 0.5):
        y = cy + int(r * offset)
        half = int((inner**2 - (r * offset) ** 2) ** 0.5) - thin // 2
        draw.line([cx - half, y, cx + half, y], fill=WHITE, width=thin)

    # Download badge, bottom right: a gap around it, a white disc, and a cut-out arrow.
    br = int(s * 0.135)
    bx, by = cx + int(r * 0.78), cy + int(r * 0.78)
    draw.ellipse([bx - br - stroke, by - br - stroke, bx + br + stroke, by + br + stroke], fill=CLEAR)
    draw.ellipse([bx - br, by - br, bx + br, by + br], fill=WHITE)
    shaft = int(br * 0.16)
    draw.rectangle([bx - shaft, by - int(br * 0.55), bx + shaft, by + int(br * 0.15)], fill=CLEAR)
    head = int(br * 0.48)
    draw.polygon([(bx - head, by + int(br * 0.02)), (bx + head, by + int(br * 0.02)), (bx, by + int(br * 0.58))],
                 fill=CLEAR)
    return layer


def main():
    s = SIZE * SCALE
    background = gradient(s).convert("RGBA")
    shape = glyph(s)

    # A soft shadow under the glyph.
    alpha = shape.getchannel("A")
    shadow_alpha = alpha.filter(ImageFilter.GaussianBlur(s * 0.012)).point(lambda value: value * 0.28)
    shadow = Image.new("RGBA", (s, s), (8, 24, 80, 255))
    shadow.putalpha(ImageChops.offset(shadow_alpha, 0, int(s * 0.012)))

    icon = Image.alpha_composite(Image.alpha_composite(background, shadow), shape).convert("RGB")
    icon = icon.resize((SIZE, SIZE), Image.LANCZOS)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUTPUT, "PNG")
    print("Wrote", OUTPUT)


if __name__ == "__main__":
    main()

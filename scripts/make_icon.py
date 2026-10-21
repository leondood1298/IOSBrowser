#!/usr/bin/env python3
"""Draws the 1024 px app icon (a white globe with a download arrow on blue) with Pillow.

Usage: python scripts/make_icon.py
Writes App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png.
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
SCALE = 4  # draw large, then downsample for smooth edges
BACKGROUND = (24, 98, 214)
WHITE = (255, 255, 255)
OUTPUT = Path(__file__).resolve().parent.parent / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"


def main():
    s = SIZE * SCALE
    image = Image.new("RGB", (s, s), BACKGROUND)
    draw = ImageDraw.Draw(image)

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

    # Download badge: a white circle with a blue arrow, bottom right.
    br = int(s * 0.135)
    bx, by = cx + int(r * 0.78), cy + int(r * 0.78)
    draw.ellipse([bx - br - stroke, by - br - stroke, bx + br + stroke, by + br + stroke], fill=BACKGROUND)
    draw.ellipse([bx - br, by - br, bx + br, by + br], fill=WHITE)
    shaft = int(br * 0.16)
    draw.rectangle([bx - shaft, by - int(br * 0.55), bx + shaft, by + int(br * 0.15)], fill=BACKGROUND)
    head = int(br * 0.48)
    draw.polygon([(bx - head, by + int(br * 0.02)), (bx + head, by + int(br * 0.02)), (bx, by + int(br * 0.58))],
                 fill=BACKGROUND)

    icon = image.resize((SIZE, SIZE), Image.LANCZOS)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    icon.save(OUTPUT, "PNG")
    print("Wrote", OUTPUT)


if __name__ == "__main__":
    main()

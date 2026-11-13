#!/usr/bin/env python3
"""Builds the Android adaptive icon from the iPhone icon (ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png):
the white artwork (TV, stand, "purio", the screen's light fill) becomes the foreground layer, recovered from the
icon as white over its diagonal gradient; the gradient itself is the vector background (ic_launcher_background)."""
import pathlib
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
src = Image.open(ROOT / "ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png").convert("RGB")
W = src.width
TOP, BOTTOM = 14, 33          # red channel of the gradient at the top-left and bottom-right corners
alpha = Image.new("L", src.size)
px, out = src.load(), alpha.load()
for y in range(W):
    for x in range(W):
        base = TOP + (BOTTOM - TOP) * (x + y) / (2 * (W - 1))
        out[x, y] = max(0, min(255, round(255 * (px[x, y][0] - base) / (255 - base))))
art = Image.new("RGBA", src.size, (255, 255, 255, 0))
art.putalpha(alpha)
# 108 dp canvas, xxxhdpi (4x). The artwork spans ~80% of the iPhone icon; at 80% scale it fits the 66 dp safe zone.
canvas = Image.new("RGBA", (432, 432), (255, 255, 255, 0))
size = round(432 * 0.80)
canvas.alpha_composite(art.resize((size, size), Image.LANCZOS), ((432 - size) // 2, (432 - size) // 2))
res = ROOT / "android/app/src/main/res"
for folder, px_size in [("mipmap-mdpi", 108), ("mipmap-hdpi", 162), ("mipmap-xhdpi", 216), ("mipmap-xxhdpi", 324), ("mipmap-xxxhdpi", 432)]:
    (res / folder).mkdir(parents=True, exist_ok=True)
    canvas.resize((px_size, px_size), Image.LANCZOS).save(res / folder / "ic_launcher_foreground.png", optimize=True)
print("foreground written")

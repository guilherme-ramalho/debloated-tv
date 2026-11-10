#!/usr/bin/env python3
"""App Store frames: each raw screenshot from scripts/store-shots-auto.sh on the app's navy with a glow in the icon's
colours, a label and a two-line headline (scripts/store-frames.json), the phone cropped at the bottom.

    python3 scripts/store-frames.py            every language and size found in ios/build/store-shots-auto

Output: ios/build/store-shots-auto/framed/<size>/<lang>/NN-<shot>.jpg, numbered in store order, JPEG without alpha
(App Store Connect refuses an alpha channel). Needs Pillow and macOS's SF Pro (/System/Library/Fonts/SFNS.ttf).
"""
import json
import os
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, 'ios/build/store-shots-auto')
OUT = os.path.join(SHOTS, 'framed')
SPEC = json.load(open(os.path.join(ROOT, 'scripts/store-frames.json'), encoding='utf-8'))
SIZES = {'6.9': (1320, 2868), '6.3': (1206, 2622)}
NAVY, NAVY2 = (11, 19, 40), (16, 29, 50)
DEEP, TEAL, LABEL = (14, 58, 122), (33, 180, 200), (110, 214, 228)


def font(weight, size):
    f = ImageFont.truetype('/System/Library/Fonts/SFNS.ttf', size)
    f.set_variation_by_name(weight)
    return f


def background(w, h):
    bg = Image.new('RGB', (w, h))
    d = ImageDraw.Draw(bg)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(NAVY[i] + (NAVY2[i] - NAVY[i]) * t) for i in range(3)))
    glow = Image.new('RGB', (w, h), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    cy = h * 0.125
    g.ellipse([w * -0.25, cy - w * 0.55, w * 0.75, cy + w * 0.35], fill=tuple(int(c * 0.55) for c in DEEP))
    g.ellipse([w * 0.35, cy - w * 0.45, w * 1.25, cy + w * 0.4], fill=tuple(int(c * 0.45) for c in TEAL))
    return ImageChops.add(bg, glow.filter(ImageFilter.GaussianBlur(w * 0.18)))


def rounded(img, r):
    mask = Image.new('L', img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], r, fill=255)
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def fitted(d, lines, weight, size, max_w):
    """The largest size up to `size` at which every line fits `max_w`."""
    while size > 40:
        f = font(weight, size)
        if all(d.textlength(line, font=f) <= max_w for line in lines):
            return f
        size -= 4
    return font(weight, size)


def frame(shot_path, label, headline, w, h):
    s = w / 1320
    img = background(w, h)
    d = ImageDraw.Draw(img)
    # label: spaced capitals
    lf = fitted(d, [label.upper()], 'Semibold', int(46 * s), w * 0.8)
    text, gap = label.upper(), 6 * s
    total = sum(d.textlength(c, font=lf) for c in text) + gap * (len(text) - 1)
    x, y = (w - total) / 2, 250 * s
    for c in text:
        d.text((x, y), c, font=lf, fill=LABEL)
        x += d.textlength(c, font=lf) + gap
    # headline: two lines, shrunk to fit the longest language
    lines = headline.split('\n')
    hf = fitted(d, lines, 'Bold', int(124 * s), w * 0.9)
    y = 250 * s + lf.size * 1.3 + 30 * s
    for line in lines:
        d.text(((w - d.textlength(line, font=hf)) / 2, y), line, font=hf, fill=(255, 255, 255))
        y += hf.size * 1.08
    # the phone, cropped by the bottom edge
    phone_w, bezel, r = int(w * 0.80), int(22 * s), int(150 * s)
    screen = Image.open(shot_path).convert('RGB')
    screen = screen.resize((phone_w, int(screen.height * phone_w / screen.width)), Image.LANCZOS)
    body = rounded(Image.new('RGB', (phone_w + 2 * bezel, screen.height + 2 * bezel), (30, 38, 56)), r)
    inner = rounded(screen, int(128 * s))
    body.paste(inner, (bezel, bezel), inner)
    ImageDraw.Draw(body).rounded_rectangle([1, 1, body.width - 2, body.height - 2], r, outline=(70, 84, 110), width=max(2, int(3 * s)))
    top = int(760 * s)
    shadow = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([(w - body.width) / 2, top + 30 * s, (w + body.width) / 2, top + body.height], r, fill=(0, 0, 0, 150))
    img = Image.alpha_composite(img.convert('RGBA'), shadow.filter(ImageFilter.GaussianBlur(40 * s)))
    img.paste(body, ((w - body.width) // 2, top), body)
    return img.convert('RGB')


def main():
    made = 0
    for size, (w, h) in SIZES.items():
        for lang, texts in SPEC['text'].items():
            src = os.path.join(SHOTS, size, lang)
            if not os.path.isdir(src):
                continue
            dst = os.path.join(OUT, size, lang)
            os.makedirs(dst, exist_ok=True)
            for n, (shot, (label, headline)) in enumerate(zip(SPEC['order'], texts), start=1):
                path = os.path.join(src, shot + '.png')
                if not os.path.exists(path):
                    print(f'missing {size}/{lang}/{shot}.png')
                    continue
                frame(path, label, headline, w, h).save(os.path.join(dst, f'{n:02d}-{shot[3:]}.jpg'), quality=92)
                made += 1
    print(f'{made} frames in {OUT}')


if __name__ == '__main__':
    main()

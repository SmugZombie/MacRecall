#!/usr/bin/env python3
"""Builds the macOS app icon sizes from full-bleed square artwork.

Usage: scripts/make-app-icon.py docs/images/app-icon.png RecallForMac/Assets.xcassets/AppIcon.appiconset
The artwork is placed on Apple's macOS icon grid (824px rounded square on a 1024 canvas, with a shadow),
because macOS does not round app icons itself. Requires Pillow.
"""
import sys
from PIL import Image, ImageDraw, ImageFilter
src, out = sys.argv[1], sys.argv[2]
art = Image.open(src).convert("RGB")
C, B, R, SS = 1024, 824, 185, 4          # canvas, body, corner radius (Apple macOS grid), supersampling
off = (C - B) // 2
mask = Image.new("L", (B * SS, B * SS), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, B * SS - 1, B * SS - 1), radius=R * SS, fill=255)
mask = mask.resize((B, B), Image.LANCZOS)
body = art.resize((B, B), Image.LANCZOS).convert("RGBA")
body.putalpha(mask)
canvas = Image.new("RGBA", (C, C), (0, 0, 0, 0))
shadow = Image.new("RGBA", (C, C), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 90), (off, off + 10), mask)
canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
canvas.alpha_composite(body, (off, off))
for pts in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = pts * scale
        name = f"icon_{pts}x{pts}{'@2x' if scale == 2 else ''}.png"
        img = canvas if px == C else canvas.resize((px, px), Image.LANCZOS)
        img.save(f"{out}/{name}", optimize=True)
print("ok")

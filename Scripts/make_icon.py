#!/usr/bin/env python3
"""Generates the placeholder app icon (1024x1024 PNG) with PIL.

Teal-to-navy gradient with a white waveform glyph. Run from anywhere:
    python3 Scripts/make_icon.py
"""
import os

from PIL import Image, ImageDraw

W = H = 1024

TOP = (26, 188, 156)      # turquoise
BOTTOM = (12, 18, 36)     # dark navy
WHITE = (245, 250, 252)

img = Image.new("RGB", (W, H))
draw = ImageDraw.Draw(img)
for y in range(H):
    t = y / (H - 1)
    color = tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    draw.line([(0, y), (W, y)], fill=color)

# Centered waveform bars (x-center, half-width, half-height)
bars = [
    (332, 26, 120),
    (422, 26, 210),
    (512, 26, 280),
    (602, 26, 210),
    (692, 26, 120),
]
for cx, hw, hh in bars:
    draw.rounded_rectangle(
        [cx - hw, H // 2 - hh, cx + hw, H // 2 + hh],
        radius=hw,
        fill=WHITE,
    )

out = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "App", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon1024.png",
)
img.save(os.path.abspath(out), "PNG")
print("wrote", os.path.abspath(out))

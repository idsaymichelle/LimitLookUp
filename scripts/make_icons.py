#!/usr/bin/env python3
"""Draws the app icons from the logo's three arcs. Run: python3 scripts/make_icons.py (needs Pillow)."""
import json, math, os
from PIL import Image, ImageDraw

N, K = 4096, 4096 / 1024
ARCS = [(348.16, .75, (219, 51, 26)), (240.64, .5, (204, 72, 11)), (133.12, .25, (253, 139, 73))]  # radius, length, colour
LIGHT, DARK = (237, 235, 228, 255), (30, 28, 26, 255)


def art(bg, colors=None):
    im = Image.new('RGBA', (N, N), bg)
    d, w, c = ImageDraw.Draw(im), 76.8 * K, N / 2
    for i, (r, ln, col) in enumerate(ARCS):
        col, r = (colors[i] if colors else col), r * K
        d.arc((c - r, c - r, c + r, c + r), -90, -90 + 360 * ln, fill=col, width=int(w))
        for a in (-90, -90 + 360 * ln):  # round caps
            t = math.radians(a); x, y = c + (r - w / 2) * math.cos(t), c + (r - w / 2) * math.sin(t)
            d.ellipse((x - w / 2, y - w / 2, x + w / 2, y + w / 2), fill=col)
    return im.resize((1024, 1024), Image.LANCZOS)


root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
light, dark_full = art(LIGHT).convert('RGB'), art(DARK).convert('RGB')
A = f'{root}/App/Assets.xcassets/AppIcon.appiconset'
light.save(f'{A}/icon.png')
art((0, 0, 0, 0)).save(f'{A}/icon-dark.png')  # iOS adds its own dark backdrop
art((0, 0, 0, 0), [(255, 255, 255), (200, 200, 200), (150, 150, 150)]).save(f'{A}/icon-tinted.png')
M = f'{root}/Mac/Assets.xcassets/AppIcon.appiconset'
imgs = []
for pt in (16, 32, 128, 256, 512):
    for sc in (1, 2):
        fn = f'icon{pt}@{sc}x.png'
        light.resize((pt * sc, pt * sc), Image.LANCZOS).save(f'{M}/{fn}')
        imgs.append({"filename": fn, "idiom": "mac", "scale": f"{sc}x", "size": f"{pt}x{pt}"})
json.dump({"images": imgs, "info": {"author": "xcode", "version": 1}}, open(f'{M}/Contents.json', 'w'), indent=2)
dark_full.save(f'{root}/Watch/Assets.xcassets/AppIcon.appiconset/icon.png')  # the watch is always dark
print('icons written')

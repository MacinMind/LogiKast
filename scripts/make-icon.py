#!/usr/bin/env python3
"""Builds the iceKast app icon from the Radiologik icon: adds a blue/white icicle ceiling
across the top third and two blue sine waves across the centre, clipped to the icon's
rounded square.
Usage: make-icon.py [out.png]    (needs: pip install pillow numpy)"""
import math, random, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "Design" / "radiologik-icon-source.webp"
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Design" / "icekast-icon-1024.png"

S = 2                       # supersampling factor
N = 1024 * S
L, T, R, B = 100, 100, 924, 924          # icon square in 1024 space
W = R - L
BAND = 76                   # solid ice thickness above the icicles
THIRD = T + W // 3          # lowest point icicles may reach (top third)

base = Image.open(SRC).convert("RGBA")
alpha = np.array(base)[..., 3].astype(np.float32) / 255.0

rng = random.Random(7)
mask = Image.new("L", (N, N), 0)
d = ImageDraw.Draw(mask)

def sc(v): return v * S

# solid band along the top
d.rectangle([sc(L - 10), sc(T - 10), sc(R + 10), sc(T + BAND)], fill=255)

# icicles: longer at the edges, shorter in the middle so the microphone stays visible
count = 9
xs = [L + W * (i + 0.5) / count for i in range(count)]
icicles = []
for i, x in enumerate(xs):
    u = abs((i + 0.5) / count - 0.5) * 2          # 0 centre .. 1 edge
    length = 75 + 150 * (u ** 1.2) + rng.uniform(-10, 14)
    length = min(length, THIRD - (T + BAND) + 14)
    icicles.append((x + rng.uniform(-5, 5), length, W / count * rng.uniform(1.0, 1.15), rng.uniform(-5, 5)))
# smaller icicles hanging in the gaps
for i in range(count - 1):
    x = (xs[i] + xs[i + 1]) / 2 + rng.uniform(-4, 4)
    icicles.append((x, rng.uniform(34, 80), W / count * 0.55, rng.uniform(-3, 3)))

def profile(t):
    """Half-width factor along an icicle: thick at the root, curving to a rounded point."""
    return (1 - t) ** 0.62

Y0 = T + BAND - 24
for x, length, width, lean in icicles:
    left, right = [], []
    steps = 80
    for k in range(steps + 1):
        t = k / steps
        half = max(width / 2 * profile(t), 2.6 if t < 1 else 0)
        cx = x + lean * t
        y = Y0 + length * t
        left.append((sc(cx - half), sc(y)))
        right.append((sc(cx + half), sc(y)))
    d.polygon(left + right[::-1], fill=255)

mask = mask.filter(ImageFilter.GaussianBlur(S * 1.2))      # soften into organic ice
m = np.array(mask).astype(np.float32) / 255.0
m = np.clip((m - 0.5) * 6 + 0.5, 0, 1)                    # re-sharpen the soft edge slightly

# --- lighting: treat the blurred mask as a height field lit from the upper left ---
hmap = np.array(Image.fromarray((m * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(S * 9))).astype(np.float32) / 255.0
gy, gx = np.gradient(hmap)
light = np.clip(-(gx * 0.8 + gy * 0.5) * S * 9, -1, 1)        # +1 lit side, -1 shaded side

yy = (np.arange(N, dtype=np.float32) / S)[:, None] * np.ones((1, N), np.float32)
tt = np.clip((yy - T) / (THIRD - T), 0, 1)[..., None]
white = np.array([252, 254, 255], np.float32)
pale = np.array([186, 224, 250], np.float32)
deep = np.array([58, 148, 226], np.float32)
col = np.where(tt < 0.5, white + (pale - white) * (tt / 0.5), pale + (deep - pale) * ((tt - 0.5) / 0.5))
lit = np.clip(light, 0, 1)[..., None]
shade = np.clip(-light, 0, 1)[..., None]
col = col + (white - col) * (lit * 0.85)                       # glossy highlight side
col = col + (np.array([28, 104, 196], np.float32) - col) * (shade * 0.55)   # cold shaded side

# crisp rim around the whole ice shape
core = np.array(Image.fromarray((m * 255).astype(np.uint8)).filter(ImageFilter.MinFilter(S * 2 + 1))).astype(np.float32) / 255.0
rim = np.clip(m - core, 0, 1)[..., None]
col = col + (np.array([30, 110, 200], np.float32) - col) * (rim * 0.65)

# sparkles (4-point glints)
glints = Image.new("L", (N, N), 0)
gd = ImageDraw.Draw(glints)
def glint(cx, cy, r):
    pts = []
    for k in range(8):
        ang = k * math.pi / 4
        rr = r if k % 2 == 0 else r * 0.16
        pts.append((sc(cx + rr * math.cos(ang)), sc(cy + rr * math.sin(ang))))
    gd.polygon(pts, fill=255)
glint(L + 150, T + 58, 30)
glint(R - 210, T + 40, 22)
glint(L + 520, T + 52, 18)
glints = np.array(glints.filter(ImageFilter.GaussianBlur(S * 0.8))).astype(np.float32)[..., None] / 255.0

# soft shadow of the ice onto the artwork
shadow = Image.fromarray((m * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(S * 9))
shadow = np.roll(np.array(shadow).astype(np.float32) / 255.0, S * 10, axis=0) * 0.45

# composite at supersampled size, clipped to the icon's rounded square
big = base.resize((N, N), Image.LANCZOS)
rgb = np.array(big)[..., :3].astype(np.float32)
a_big = np.array(Image.fromarray((alpha * 255).astype(np.uint8)).resize((N, N), Image.LANCZOS)).astype(np.float32) / 255.0

rgb = rgb * (1 - shadow[..., None] * a_big[..., None] * 0.9)            # shadow, only on the icon
ice_a = (m * 0.95 * a_big)[..., None]
rgb = rgb * (1 - ice_a) + col * ice_a
rgb = rgb + (255 - rgb) * (glints * a_big[..., None])

# two blue sine waves across the centre: a strong one and a lighter one, apexes offset
def wave(amp, cycles, phase, width, colour, opacity, cy=(T + B) / 2):
    layer = Image.new("L", (N, N), 0)
    ld = ImageDraw.Draw(layer)
    pts = []
    x0, x1 = L - 4, R + 4
    for k in range(2401):
        x = x0 + (x1 - x0) * k / 2400
        u = (x - L) / W
        y = cy + amp * (0.7 + 0.5 * u) * math.sin(2 * math.pi * cycles * u + phase)   # swell left to right: no mirror symmetry
        pts.append((sc(x), sc(y)))
    r = sc(width) / 2
    for px, py in pts:                       # round dabs along the path: smooth edges at any slope
        ld.ellipse([px - r, py - r, px + r, py + r], fill=255)
    a = np.array(layer.filter(ImageFilter.GaussianBlur(S * 0.7))).astype(np.float32)[..., None] / 255.0
    return a * opacity * a_big[..., None], np.array(colour, np.float32)

# each wave gets a contrasting halo so it reads on both the dark headphones and the grey ground
for amp, cyc, ph, wd, colr, op, halo in [(96, 1.3, 1.9, 18, (120, 214, 255), 0.85, (8, 40, 110)),
                                         (120, 1.3, 0.5, 26, (20, 110, 255), 1.0, (255, 255, 255))]:
    ha, hc = wave(amp, cyc, ph, wd + 12, halo, 0.9)
    rgb = rgb * (1 - ha) + hc * ha
    wa, wc = wave(amp, cyc, ph, wd, colr, op)
    rgb = rgb * (1 - wa) + wc * wa

out = np.dstack([np.clip(rgb, 0, 255), a_big * 255]).astype(np.uint8)
Image.fromarray(out, "RGBA").resize((1024, 1024), Image.LANCZOS).save(OUT)
print("wrote", OUT)

"""Original sprites for the katana skills (procedural, no source art).

`python3 textures.py` writes assets/katana/*.png and a dark-background
contact sheet (previews/textures.png). Upload them (Studio: Asset Manager ->
Bulk Import, or tools/katana/upload.py) and paste each image id into
Config.KatanaTextures; until then KatanaFX falls back to existing textures.

Conventions:
  particle sprites are square, white (or baked colour) with the shape in the
  alpha channel, because the effects render them additively
  beam ribbons run along U (image width = along the beam) and across V
  (image height = across the beam's width)
"""
import math
import os
import random

import numpy as np
from PIL import Image

import rig

OUT = os.path.join(rig.ROOT, "assets", "katana")
PREVIEW = os.path.join(rig.ROOT, "previews", "textures.png")


def grid(n, m=None):
    m = m or n
    y, x = np.mgrid[0:m, 0:n].astype(np.float64)
    return (x + 0.5) / n * 2 - 1, (y + 0.5) / m * 2 - 1  # -1..1, y down


def save(name, rgb, alpha):
    rgb = np.clip(np.nan_to_num(rgb, nan=1.0), 0, 1)
    alpha = np.nan_to_num(alpha, nan=0.0)
    alpha = np.clip(alpha, 0, 1)
    if rgb.ndim == 2:
        rgb = np.repeat(rgb[..., None], 3, axis=2)
    img = np.dstack([rgb, alpha[..., None]])
    os.makedirs(OUT, exist_ok=True)
    Image.fromarray((img * 255 + 0.5).astype(np.uint8), "RGBA").save(os.path.join(OUT, name + ".png"))
    return name


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def white(shape):
    return np.ones(shape)


def hue_rgb(h):
    """h 0..1 -> rgb arrays (full saturation spectrum)."""
    h = (h % 1.0) * 6
    c = np.ones_like(h)
    x = 1 - np.abs(h % 2 - 1)
    z = np.zeros_like(h)
    r = np.select([h < 1, h < 2, h < 3, h < 4, h < 5], [c, x, z, z, x], c)
    g = np.select([h < 1, h < 2, h < 3, h < 4, h < 5], [x, c, c, x, z], z)
    b = np.select([h < 1, h < 2, h < 3, h < 4, h < 5], [z, z, x, c, c], x)
    return np.dstack([r, g, b])


# ---------------------------------------------------------------------------


def glow():
    x, y = grid(512)
    r = np.sqrt(x * x + y * y)
    a = np.exp(-(r / 0.42) ** 2) * 0.85 + np.exp(-r / 0.2) * 0.25
    a *= smoothstep(1.0, 0.82, r)  # reaches zero inside the square
    return save("glow", white(r.shape), a)


def core():
    x, y = grid(512)
    r = np.sqrt(x * x + y * y)
    a = np.clip(np.exp(-r / 0.07) * 1.3 + np.exp(-(r / 0.3) ** 2) * 0.55 + np.exp(-(r / 0.7) ** 2) * 0.12, 0, 1)
    a *= smoothstep(1.0, 0.85, r)
    return save("core", white(r.shape), a)


def ray(x, y, length, width, power=1.6):
    """A tapered ray along +x/-x from the centre (both directions)."""
    u = np.abs(x) / length
    w = width * np.clip(1 - u, 0, 1) ** power + 1e-4
    return np.exp(-np.abs(y) / w) * smoothstep(1.0, 0.0, u) * (u < 1)


def rotate(x, y, a):
    c, s = math.cos(a), math.sin(a)
    return x * c + y * s, -x * s + y * c


def star():
    """Four-point flare: long anamorphic horizontal pair, shorter vertical,
    faint diagonals, hot core."""
    x, y = grid(1024)
    r = np.sqrt(x * x + y * y)
    a = ray(x, y, 0.98, 0.022, 1.3) * 1.0
    a += ray(y, x, 0.62, 0.02, 1.4) * 0.85
    for ang in (math.pi / 4, -math.pi / 4):
        xr, yr = rotate(x, y, ang)
        a += ray(xr, yr, 0.34, 0.012, 1.5) * 0.35
    a += np.exp(-r / 0.035) * 1.2 + np.exp(-(r / 0.16) ** 2) * 0.45
    a = 1 - np.exp(-a * 1.6)  # soft clip keeps the core round and hot
    a *= smoothstep(1.0, 0.9, r)
    return save("star", white(r.shape), a)


def burst():
    """Starburst: 18 rays of varied length and width, warm-cool tinted tips."""
    x, y = grid(1024)
    r = np.sqrt(x * x + y * y)
    theta = np.arctan2(y, x)
    rng = random.Random(4)
    a = np.zeros_like(r)
    tint = np.zeros(r.shape + (3,))
    for i in range(18):
        ang = i / 18 * 2 * math.pi + rng.uniform(-0.12, 0.12)
        length = rng.uniform(0.45, 0.97) if i % 2 == 0 else rng.uniform(0.25, 0.55)
        width = rng.uniform(0.008, 0.02)
        xr, yr = rotate(x, y, ang)
        one = ray(np.maximum(xr, 0), yr, length, width, 1.3) * (xr > 0)
        a += one
        warm = rng.random() < 0.5
        tip = np.array([1.0, 0.86, 0.72]) if warm else np.array([0.74, 0.9, 1.0])
        t = np.clip(np.maximum(xr, 0) / length, 0, 1)[..., None]
        tint += one[..., None] * ((1 - t) * 1.0 + t * tip)
    a += np.exp(-r / 0.04) * 1.2 + np.exp(-(r / 0.2) ** 2) * 0.35
    ring = np.exp(-((r - 0.36) / 0.012) ** 2) * 0.18 * (0.6 + 0.4 * np.cos(theta * 9))
    a += ring
    centre = np.exp(-r / 0.04) * 1.2 + np.exp(-(r / 0.2) ** 2) * 0.35 + ring
    a += 0  # (centre already included above)
    rgb = (tint + centre[..., None]) / np.maximum(a[..., None], 1e-5)
    a = 1 - np.exp(-a * 1.5)
    a *= smoothstep(1.0, 0.9, r)
    return save("burst", rgb, a)


def prism():
    """Rainbow halo: a dispersion ring (violet inside, red outside) with soft
    angular streaks, like the light ring around the reference's flashes."""
    x, y = grid(1024)
    r = np.sqrt(x * x + y * y)
    theta = np.arctan2(y, x)
    centre, half = 0.66, 0.12
    t = (r - (centre - half)) / (2 * half)  # 0 inner .. 1 outer
    band = np.exp(-((r - centre) / (half * 0.95)) ** 2)
    hue = 0.78 - np.clip(t, 0, 1) * 0.78  # violet -> blue -> green -> yellow -> red
    rgb = hue_rgb(hue) * 0.62 + 0.38
    streaks = 0.65 + 0.35 * np.cos(theta * 23 + np.sin(theta * 5) * 2) * np.cos(theta * 7)
    a = band * streaks * 0.62
    a += np.exp(-((r - 0.42) / 0.05) ** 2) * 0.12  # faint inner ring, white
    rgb = np.where((np.exp(-((r - 0.42) / 0.05) ** 2) > band)[..., None], 1.0, rgb)
    a *= smoothstep(1.0, 0.92, r)
    return save("prism", rgb, a)


def streak():
    """Anamorphic horizontal streak: a razor line with a soft halo, cyan
    fringes above and below."""
    x, y = grid(1024)
    taper = np.clip(1 - np.abs(x), 0, 1) ** 1.2
    line = np.exp(-np.abs(y) / (0.006 + 0.004 * taper)) * taper
    halo = np.exp(-(y / 0.06) ** 2) * taper ** 2 * 0.35
    fringe = (np.exp(-((np.abs(y) - 0.03) / 0.012) ** 2)) * taper ** 1.5 * 0.25
    a = np.clip(line + halo + fringe, 0, 1)
    rgb = np.dstack([np.ones_like(x), np.ones_like(x), np.ones_like(x)])
    cyan = np.array([0.6, 0.92, 1.0])
    mix = np.clip(fringe / np.maximum(a, 1e-5), 0, 1)[..., None]
    rgb = rgb * (1 - mix) + cyan * mix
    r = np.sqrt(x * x + y * y)
    a *= smoothstep(1.0, 0.95, np.abs(x))
    return save("streak", rgb, a)


def crescent():
    """The slash silhouette: chord horizontal, bulge up. A razor white
    leading edge (outer rim), a lavender body that fades toward the inner
    rim with flow lines curving along the arc, tapered tips, and a faint
    prismatic split (cyan just inside the edge, pink just outside)."""
    n = 1024
    x, y = grid(n)
    y = -y  # up
    R, sag = 1.35, 0.62  # outer arc
    cy = sag - R  # outer circle centre (apex at y = sag... shifted to centre the shape)
    shift = -0.15
    yy = y - shift
    r = np.sqrt(x * x + (yy - cy) ** 2)
    theta = np.arctan2(yy - cy, x)  # pi/2 at the apex
    half = math.asin(0.95 / R)
    s = (theta - (math.pi / 2 - half)) / (2 * half)  # 0..1 tip to tip
    inside = (s > 0) & (s < 1)
    prof = np.where(inside, np.clip(np.sin(np.clip(s, 0, 1) * math.pi), 0, 1) ** 1.15, 0)
    thickness = 0.5 * prof + 1e-4
    d = R - r  # depth below the outer rim
    edge = np.exp(-np.abs(d) / (0.006 + 0.01 * prof)) * prof ** 0.6
    body_t = np.clip(d / thickness, 0, 1.0)
    body = np.where((d > 0) & inside, (1 - body_t) ** 1.6, 0) * prof
    flow = 0.72 + 0.28 * np.sin(body_t * 34 + s * 6 + np.sin(s * 19) * 1.5)
    spill = np.where(d > 0, np.exp(-d / 0.22) * 0.3, np.exp(d / 0.035) * 0.22) * prof
    pink = np.exp(-((d + 0.025) / 0.012) ** 2) * prof * 0.45
    cyan = np.exp(-((d - 0.03) / 0.014) ** 2) * prof * 0.5
    a = edge * 1.0 + body * flow * 0.8 + spill + pink + cyan
    lav = np.array([0.8, 0.7, 1.0])
    rgb = np.zeros(x.shape + (3,))
    rgb += edge[..., None] * 1.0
    rgb += (body * flow * 0.8)[..., None] * lav
    rgb += spill[..., None] * np.array([0.72, 0.6, 1.0])
    rgb += pink[..., None] * np.array([1.0, 0.62, 0.9])
    rgb += cyan[..., None] * np.array([0.55, 0.92, 1.0])
    rgb = rgb / np.maximum(a[..., None], 1e-5)
    a = 1 - np.exp(-a * 1.7)
    a *= smoothstep(1.0, 0.94, np.abs(x)) * smoothstep(1.0, 0.94, np.abs(y))
    return save("crescent", rgb, a)


def spark():
    """Velocity-aligned spark: vertical (particles align their height with
    the velocity), hot head, tapering tail."""
    x, y = grid(512)
    v = (y + 1) / 2  # 0 top .. 1 bottom
    tail = np.clip(1 - np.abs(y), 0, 1) ** 0.8
    width = 0.012 + 0.05 * tail
    a = np.exp(-np.abs(x) / width) * tail
    a += np.exp(-np.sqrt(x * x + (y + 0.0) ** 2) / 0.05) * 0.6
    a = np.clip(a, 0, 1) * smoothstep(1.0, 0.9, np.abs(y))
    return save("spark", white(x.shape), a)


def glint():
    x, y = grid(256)
    r = np.sqrt(x * x + y * y)
    a = ray(x, y, 0.95, 0.04, 1.5) + ray(y, x, 0.95, 0.04, 1.5) + np.exp(-r / 0.08) * 1.2
    xr, yr = rotate(x, y, math.pi / 4)
    a += ray(xr, yr, 0.45, 0.025, 1.5) * 0.4 + ray(yr, xr, 0.45, 0.025, 1.5) * 0.4
    a = (1 - np.exp(-a * 1.5)) * smoothstep(1.0, 0.9, r)
    return save("glint", white(r.shape), a)


def periodic_noise(n_u, n_v, seed, octaves=((6, 1.0), (13, 0.5), (29, 0.25))):
    """Streaks along U: smooth noise in V, periodic in U so it scrolls seamlessly."""
    rng = np.random.default_rng(seed)
    u = np.arange(n_u)[None, :] / n_u
    v = np.arange(n_v)[:, None] / n_v
    out = np.zeros((n_v, n_u))
    for freq_v, amp in octaves:
        for _ in range(4):
            fu = rng.integers(1, 4)
            phase = rng.uniform(0, 2 * math.pi)
            pv = rng.uniform(0, 2 * math.pi)
            out += amp * np.sin(2 * math.pi * fu * u + phase + np.sin(2 * math.pi * freq_v * v + pv) * 2.2)
    out = (out - out.min()) / (out.max() - out.min())
    return out


def ribbons():
    # core: a crisp line with a soft shoulder (V across)
    n_u, n_v = 256, 128
    _, v = grid(n_u, n_v)
    a = np.exp(-(v / 0.14) ** 2) * 0.85 + np.exp(-np.abs(v) / 0.3) * 0.3
    save("ribbonCore", white(v.shape), np.clip(a, 0, 1) * smoothstep(1.0, 0.85, np.abs(v)))
    # soft: wide gaussian
    a = np.exp(-(v / 0.5) ** 2) * smoothstep(1.0, 0.7, np.abs(v))
    save("ribbonSoft", white(v.shape), a)
    # flow: streaks running along the beam, tiling seamlessly along U
    n_u, n_v = 512, 128
    _, v = grid(n_u, n_v)
    noise = periodic_noise(n_u, n_v, 7)
    streaks = 0.35 + 0.65 * noise ** 1.6
    profile = np.exp(-(v / 0.55) ** 2) * smoothstep(1.0, 0.75, np.abs(v))
    save("ribbonFlow", white(v.shape), np.clip(streaks * profile, 0, 1))
    # blade trail: symmetric across V (works whichever attachment is which),
    # bright fine streaks in a soft body
    noise = periodic_noise(n_u, n_v, 11, ((9, 1.0), (21, 0.6)))
    body = np.exp(-(v / 0.75) ** 2)
    a = np.clip(body * (0.45 + 0.55 * noise ** 2.2), 0, 1) * smoothstep(1.0, 0.85, np.abs(v))
    save("bladeTrail", white(v.shape), a)


ALL = [glow, core, star, burst, prism, streak, crescent, spark, glint, ribbons]
NAMES = ["glow", "core", "star", "burst", "prism", "streak", "crescent", "spark", "glint", "ribbonCore", "ribbonFlow", "ribbonSoft", "bladeTrail"]


def contact_sheet():
    tiles = []
    for name in NAMES:
        img = Image.open(os.path.join(OUT, name + ".png")).convert("RGBA")
        tile = Image.new("RGB", (256, 256), (14, 16, 26))
        im = img.resize((256, 256 if img.width == img.height else 64))
        rgb = np.asarray(im, np.float32) / 255
        out = np.asarray(Image.new("RGB", im.size, (14, 16, 26)), np.float32) / 255
        out = out + rgb[..., :3] * rgb[..., 3:4] * 1.3
        im2 = Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8))
        tile.paste(im2, (0, (256 - im2.height) // 2))
        tiles.append(tile)
    sheet = Image.new("RGB", (256 * 5, 256 * math.ceil(len(tiles) / 5)), (0, 0, 0))
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % 5) * 256, (i // 5) * 256))
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    sheet.save(PREVIEW)


if __name__ == "__main__":
    for f in ALL:
        f()
    contact_sheet()
    print("wrote", OUT)

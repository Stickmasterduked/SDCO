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




# ---------------------------------------------------------------------------
# Round 2: flipbooks and thick shapes (no thin lines). 4x4 flipbooks are
# 1024px (256px cells), played OneShot over a particle's life.

def blur_noise(n, sigma, seed):
    from PIL import ImageFilter
    rng = np.random.default_rng(seed)
    a = rng.random((n, n))
    img = Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(sigma))
    b = np.asarray(img, np.float64) / 255
    return (b - b.min()) / (b.max() - b.min() + 1e-9)


def flipbook(name, cell_fn, cells=4, size=256):
    sheet_rgb = np.zeros((size * cells, size * cells, 3))
    sheet_a = np.zeros((size * cells, size * cells))
    for i in range(cells * cells):
        u = i / (cells * cells - 1)
        rgb, a = cell_fn(u, i, size)
        r, c = divmod(i, cells)
        if rgb.ndim == 2:
            rgb = np.repeat(rgb[..., None], 3, axis=2)
        sheet_rgb[r * size:(r + 1) * size, c * size:(c + 1) * size] = rgb
        sheet_a[r * size:(r + 1) * size, c * size:(c + 1) * size] = a
    return save(name, sheet_rgb, sheet_a)


def explosion():
    """Energy explosion: hot white core -> spiky expanding ball -> a ring of
    lavender energy licks -> smoky dissolve."""
    n1 = blur_noise(256, 6, 1)
    n2 = blur_noise(256, 3, 2)

    def cell(u, i, size):
        x, y = grid(size)
        r = np.sqrt(x * x + y * y)
        th = np.arctan2(y, x)
        grow = 0.3 + 0.62 * (1 - (1 - u) ** 2.2)
        wob = (n1 - 0.5) * 0.55 + (n2 - 0.5) * 0.2
        edge = grow * (1 + wob * (0.4 + u))
        ball = smoothstep(edge, edge * 0.55, r)  # filled ball
        hollow = smoothstep(0.4, 0.9, u)
        inner = smoothstep(edge * (0.2 + 0.6 * hollow), edge * (0.45 + 0.45 * hollow), r)
        body = ball * (1 - hollow + hollow * inner)
        breakup = smoothstep(0.5, 1.0, u)
        body *= 1 - breakup * smoothstep(0.35, 0.75, n2 + (1 - u) * 0.2) * 1.0
        fade = (1 - smoothstep(0.65, 1.0, u)) * 0.85 + 0.15 * (1 - u)
        core = np.exp(-(r / (0.15 + 0.3 * grow)) ** 2) * (1 - smoothstep(0.0, 0.6, u))
        a = np.clip(body * fade + core, 0, 1)
        heat = np.clip(core * 1.5 + (1 - r / np.maximum(edge, 1e-3)) * (1 - u) * 1.6, 0, 1)[..., None]
        lav = np.array([0.78, 0.66, 1.0])
        cyan = np.array([0.6, 0.92, 1.0])
        rim = np.clip(r / np.maximum(edge, 1e-3), 0, 1)[..., None]
        col = lav * (1 - rim * 0.4) + cyan * rim * 0.4
        rgb = col * (1 - heat) + heat
        return rgb, a * smoothstep(1.0, 0.92, r)
    return flipbook("explosion", cell)


def smoke():
    """Billowing energy smoke puff (white, tinted at runtime), fading out."""
    n1 = blur_noise(256, 9, 3)
    n2 = blur_noise(256, 4, 4)

    def cell(u, i, size):
        x, y = grid(size)
        r = np.sqrt(x * x + y * y)
        grow = 0.35 + 0.6 * (1 - (1 - u) ** 2)
        lump = (n1 - 0.5) * 0.5 + (n2 - 0.5) * 0.25
        a = smoothstep(grow * (1 + lump), grow * 0.4, r)
        a *= 0.85 * (1 - u) ** 1.3 + 0.0
        a *= 0.55 + 0.45 * n2
        shade = 0.75 + 0.25 * (1 - y) / 2
        return np.clip(shade, 0, 1), np.clip(a, 0, 1) * smoothstep(1.0, 0.9, r)
    return flipbook("smoke", cell)


def slash():
    """A slash flash: a razor crescent tears in, flares wide, then splits and
    scatters. Chord horizontal."""
    n2 = blur_noise(256, 2, 5)

    def cell(u, i, size):
        x, y = grid(size)
        y = -y
        R = 1.6
        cy = 0.18 - R
        rr = np.sqrt(x * x + (y - cy) ** 2)
        th = np.arctan2(y - cy, x)
        half = math.asin(0.92 / R)
        s = (th - (math.pi / 2 - half)) / (2 * half)
        inside = (s > 0) & (s < 1)
        reveal = min(1.0, u / 0.25)
        prof = np.where(inside & (1 - s <= reveal), np.sin(np.clip(s, 0, 1) * math.pi) ** 1.2, 0)
        thick = (0.04 + 0.22 * math.sin(min(u, 0.6) / 0.6 * math.pi / 2)) * prof + 1e-4
        d = R - rr
        body = np.where((d > -0.01) & (d < thick), 1.0, 0.0) * smoothstep(thick, thick * 0.3, d)
        edge = np.exp(-np.abs(d) / 0.012) * prof
        glow = np.exp(-np.abs(d - thick / 2) / (0.08 + 0.15 * u)) * prof * 0.5
        split = smoothstep(0.55, 1.0, u)
        crack = smoothstep(0.4, 0.6, n2) * split
        a = (body * 0.85 + edge + glow) * (1 - crack) * (1 - smoothstep(0.75, 1.0, u))
        a = np.clip(a, 0, 1)
        hot = np.clip(edge + body * (1 - u) * 0.8, 0, 1)[..., None]
        rgb = np.array([0.78, 0.68, 1.0]) * (1 - hot) + hot
        return rgb, a * smoothstep(1.0, 0.92, np.abs(x))
    return flipbook("slash", cell)


def shock():
    """Shockwave ring: a bright crisp front with a soft energy wake inside."""
    x, y = grid(1024)
    r = np.sqrt(x * x + y * y)
    th = np.arctan2(y, x)
    noise = 0.8 + 0.2 * np.sin(th * 17) * np.sin(th * 5 + 1)
    front = np.exp(-((r - 0.86) / 0.025) ** 2)
    wake = np.where(r < 0.86, np.exp(-(0.86 - r) / 0.16), 0) * 0.55 * noise
    a = np.clip(front + wake, 0, 1) * smoothstep(1.0, 0.95, r)
    rgb = np.dstack([np.ones_like(r), np.ones_like(r), np.ones_like(r)])
    return save("shock", rgb, a)


def spike():
    """Impact star: thick tapered spikes (manga impact), not hairlines."""
    x, y = grid(1024)
    r = np.sqrt(x * x + y * y)
    th = np.arctan2(y, x)
    rng = random.Random(9)
    a = np.zeros_like(r)
    for k in range(12):
        ang = k / 12 * 2 * math.pi + rng.uniform(-0.15, 0.15)
        length = rng.uniform(0.55, 0.97)
        width = rng.uniform(0.09, 0.16)
        d = np.angle(np.exp(1j * (th - ang)))
        w = width * np.clip(1 - r / length, 0, 1)
        a = np.maximum(a, smoothstep(w, w * 0.6, np.abs(d)) * (r < length) * smoothstep(0.0, 0.08, r))
    a = np.clip(a + np.exp(-(r / 0.22) ** 2), 0, 1) * smoothstep(1.0, 0.95, r)
    return save("spike", white(r.shape), a)


def energy():
    """Swirling energy blob (auras, charge-ups)."""
    x, y = grid(512)
    r = np.sqrt(x * x + y * y)
    th = np.arctan2(y, x)
    swirl = 0.6 + 0.4 * np.sin(th * 3 + r * 9)
    a = np.exp(-(r / 0.5) ** 2) * swirl + np.exp(-(r / 0.18) ** 2) * 0.6
    a = np.clip(a, 0, 1) * smoothstep(1.0, 0.85, r)
    return save("energy", white(r.shape), a)


ALL += [explosion, smoke, slash, shock, spike, energy]
NAMES += ["explosion", "smoke", "slash", "shock", "spike", "energy"]


# ---------------------------------------------------------------------------
# Round 3: sakura petals (they replace the star sparkles). Colour is baked
# (pale pink, white tips, a deeper base) and they render with low light
# emission, so they read as petals over the explosions, not as more glow.

PETAL_BASE = np.array([1.0, 0.56, 0.78])
PETAL_MID = np.array([1.0, 0.84, 0.93])
PETAL_TIP = np.array([1.0, 0.97, 0.99])
PETAL_BACK = np.array([0.93, 0.62, 0.84])


def petal_shape(px, py):
    """A sakura petal in its own frame: base at py = 0, tip (notched) at
    py = 1, half-width about 0.32. Returns (alpha, v) with v = 0 at the base."""
    v = py
    lobe = (px / 0.33) ** 2 + ((v - 0.6) / 0.42) ** 2  # the broad, round outer half
    stem_w = 0.33 * np.sin(np.clip(v / 0.6, 0, 1) * math.pi / 2) ** 1.1  # tapering to the base
    d_lobe = 1 - np.sqrt(lobe)  # > 0 inside
    d_stem = np.where((v > 0) & (v < 0.6), (stem_w - np.abs(px)) / 0.34, -1)
    d = np.maximum(d_lobe, d_stem)
    # the notch at the tip
    notch = 1.02 - 0.17 * np.clip(1 - np.abs(px) / 0.13, 0, 1) ** 1.3
    d = np.minimum(d, (notch - v) * 3)
    alpha = smoothstep(-0.006, 0.014, d)
    return alpha, np.clip(v, 0, 1), d


def petal_color(v, d, px, back=False):
    t = np.clip(v, 0, 1)[..., None]
    base = PETAL_BACK if back else PETAL_BASE
    col = np.where(t < 0.5, base + (PETAL_MID - base) * (t / 0.5), PETAL_MID + (PETAL_TIP - PETAL_MID) * ((t - 0.5) / 0.5))
    # a faint centre vein and brighter rim (light through the edge)
    vein = np.exp(-(px / 0.02) ** 2)[..., None] * (1 - t) * 0.12
    rim = (1 - smoothstep(0.0, 0.12, d))[..., None] * 0.1
    return np.clip(col - vein + rim, 0, 1)


def petal_layer(x, y, cx, cy, scale, angle, sx=1.0, sy=1.0, back=False):
    """One petal drawn into the grid: centred at (cx, cy), pointing along
    `angle` (0 = up), foreshortened by sx / sy (tumbling)."""
    xr, yr = rotate(x - cx, y - cy, -angle)
    px = xr / (scale * max(abs(sx), 1e-3))
    py = -yr / (scale * max(abs(sy), 1e-3)) + 0.5  # petal centre at the middle of its length
    a, v, d = petal_shape(px, py)
    shade = 0.82 + 0.18 * min(abs(sx), 1)  # edge-on is a little darker
    return petal_color(v, d, px, back) * shade, a


def petal():
    """A single petal, upright."""
    x, y = grid(512)
    rgb, a = petal_layer(x, y, 0, 0, 1.75, 0)
    return save("petal", rgb, a)


def petals():
    """4x4 flipbook of a petal tumbling twice through its life (spins about
    its length and pitches, showing the paler back as it turns over)."""
    def cell(u, i, size):
        x, y = grid(size)
        turn = u * 2 * math.tau
        sx = math.cos(turn)
        sy = 0.65 + 0.35 * math.cos(u * math.tau * 1.3 + 0.8)
        rgb, a = petal_layer(x, y, 0, 0, 1.6, math.radians(25 * math.sin(u * math.tau)), sx, sy, back=sx < 0)
        return rgb, a
    return flipbook("petals", cell)


def blossom():
    """A five-petal sakura flower with a soft pink heart and stamens."""
    x, y = grid(1024)
    rgb = np.zeros(x.shape + (3,))
    a = np.zeros(x.shape)
    for k in range(5):
        ang = k * math.tau / 5
        cx, cy = math.sin(ang) * 0.47, -math.cos(ang) * 0.47
        prgb, pa = petal_layer(x, y, cx, cy, 0.98, -ang)
        rgb = rgb * (1 - pa[..., None]) + prgb * pa[..., None]
        a = np.maximum(a, pa)
    r = np.sqrt(x * x + y * y)
    heart = np.exp(-(r / 0.16) ** 2)[..., None]
    rgb = rgb * (1 - heart * 0.55) + np.array([1.0, 0.45, 0.7]) * heart * 0.55
    a = np.maximum(a, np.exp(-(r / 0.14) ** 2))
    rng = random.Random(9)
    for _ in range(14):
        ang = rng.uniform(0, math.tau)
        rr = rng.uniform(0.09, 0.2)
        sx, sy = math.cos(ang) * rr, math.sin(ang) * rr
        dot = np.exp(-(((x - sx) ** 2 + (y - sy) ** 2) / 0.012 ** 2))[..., None]
        rgb = rgb * (1 - dot) + np.array([1.0, 0.93, 0.7]) * dot
    return save("blossom", np.clip(rgb, 0, 1), a)


ALL += [petal, petals, blossom]
NAMES += ["petal", "petals", "blossom"]


if __name__ == "__main__":
    for f in ALL:
        f()
    contact_sheet()
    print("wrote", OUT)

"""Renders the Void Wings sprite sheets and particle sprites with numpy.

    python3 tools/voidwings/render.py            # everything -> assets/voidwings/
    python3 tools/voidwings/render.py --quick    # 256 px cells, for iterating

Galaxy: tileable FFT noise (periodic on a torus) -> fbm spectrum -> domain
warp -> colour ramp, sampled in each feather's own (along, across)
coordinates so the nebula follows the curve. The along coordinate scrolls by
exactly one period (fast layer: two) over the 16 frames, so the loop is
seamless and the galaxy streams base -> tip. Stars ride the same flow and
twinkle with whole-number cycles per loop.

Feather: Bezier centreline + width profile -> per-pixel (t, signed lateral
distance) -> signed distance to the edge -> hard magenta/violet rim inside,
exponential purple halo outside.

Outputs
  feather_R_{0..3}.png  right-wing atlases (1024^2, 2x2 cells of 512^2)
  feather_L_{0..3}.png  left-wing atlases: every cell mirrored in place
  sparkle.png mote.png wisp.png  particle sprites (white; tinted in Roblox)
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout as L  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "assets", "voidwings")


def hex_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)])


VOID = hex_rgb("08041A")
INDIGO = hex_rgb("280A5A")
VIOLET = hex_rgb("8C28DC")
MAGENTA = hex_rgb("FF50DC")
BLUE = hex_rgb("5A8CFF")
RIM_TIP = hex_rgb("FF78FF")
RIM_BASE = hex_rgb("B450FF")
HALO = hex_rgb("9A3CF0")


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


# --- periodic noise ------------------------------------------------------------

def periodic_field(rng, n, beta, fmin=1.0, fmax=None):
    """Tileable n x n noise with a 1/f^beta spectrum (an fbm in one shot).
    Only integer frequencies exist on the grid, so it wraps exactly."""
    fy = np.fft.fftfreq(n)[:, None] * n
    fx = np.fft.rfftfreq(n)[None, :] * n
    f = np.sqrt(fx * fx + fy * fy)
    amp = np.where(f >= fmin, 1.0 / np.maximum(f, 1e-6) ** beta, 0.0)
    if fmax:
        amp *= np.exp(-(f / fmax) ** 2)
    phase = rng.uniform(0, 2 * np.pi, amp.shape)
    spec = amp * np.exp(1j * phase) * rng.rayleigh(1.0, amp.shape)
    field = np.fft.irfft2(spec, s=(n, n))
    return (field - field.mean()) / field.std()


def sample(field, a, c):
    """Bilinear lookup with wrap-around; a, c in periods (any real value)."""
    n = field.shape[0]
    x = (a % 1.0) * n
    y = (c % 1.0) * n
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx = x - x0
    fy = y - y0
    x0 %= n
    y0 %= n
    x1 = (x0 + 1) % n
    y1 = (y0 + 1) % n
    top = field[y0, x0] * (1 - fx) + field[y0, x1] * fx
    bot = field[y1, x0] * (1 - fx) + field[y1, x1] * fx
    return top * (1 - fy) + bot * fy


# --- feather geometry --------------------------------------------------------------

def bezier(t):
    p0, p1, p2, p3 = (np.array(p) for p in L.CENTRELINE)
    t = t[:, None]
    return ((1 - t) ** 3) * p0 + 3 * ((1 - t) ** 2) * t * p1 + 3 * (1 - t) * t * t * p2 + t ** 3 * p3


def half_width(t):
    """Thin base, widest about a third of the way up, needle tip."""
    t = np.clip(t, 0, 1)
    shape = t ** 0.8 * (1 - t) ** 1.2
    peak = (0.8 / 2.0) ** 0.8 * (1 - 0.8 / 2.0) ** 1.2
    return L.BASE_HALF_WIDTH * (1 - t) + L.HALF_WIDTH * shape / peak


class Feather:
    """Per-pixel feather coordinates for one cell, computed once."""

    def __init__(self, cell):
        self.cell = cell
        xs = L.FRAME_X[0] + (np.arange(cell) + 0.5) / cell * L.FRAME_W
        ys = L.FRAME_Y[1] - (np.arange(cell) + 0.5) / cell * L.FRAME_H
        self.px, self.py = np.meshgrid(xs, ys)
        self.pixel = max(L.FRAME_W, L.FRAME_H) / cell  # coarser axis, for AA

        n = 900
        ts = np.linspace(0, 1, n)
        pts = bezier(ts)
        tang = np.gradient(pts, axis=0)
        tang /= np.linalg.norm(tang, axis=1, keepdims=True)
        self.curve_t, self.curve_p, self.curve_tan = ts, pts, tang
        normal = np.stack([-tang[:, 1], tang[:, 0]], axis=1)  # left of travel
        self.curve_n = normal

        flat = np.stack([self.px.ravel(), self.py.ravel()], axis=1)
        best = np.empty(len(flat), dtype=np.int64)
        for i in range(0, len(flat), 8192):
            chunk = flat[i:i + 8192]
            d2 = ((chunk[:, None, :] - pts[None, :, :]) ** 2).sum(-1)
            best[i:i + 8192] = d2.argmin(1)
        rel = flat - pts[best]
        along_off = (rel * tang[best]).sum(1)
        # extend past the ends along the tangent, so base/tip close smoothly
        t = ts[best] + np.where((best == 0) | (best == n - 1), along_off, 0.0)
        s = (rel * normal[best]).sum(1)  # signed lateral distance, + = left
        self.t = t.reshape(cell, cell)
        self.s = s.reshape(cell, cell)
        hw = half_width(self.t)
        beyond = np.maximum(-self.t, 0) * 6 + np.maximum(self.t - 1, 0) * 6
        self.hw = hw
        self.dist = np.abs(self.s) - hw + beyond  # <0 inside
        self.u = np.clip(self.s / np.maximum(hw, 1e-4), -1.5, 1.5)

    def point(self, t, u):
        """Display-space point at along t, across u (-1..1 of the half width)."""
        t = np.clip(t, 0, 1)
        i = np.clip((t * (len(self.curve_t) - 1)).round().astype(int), 0, len(self.curve_t) - 1)
        return self.curve_p[i] + self.curve_n[i] * (u * half_width(t))[:, None]

    def to_pixel(self, xy):
        col = (xy[:, 0] - L.FRAME_X[0]) / L.FRAME_W * self.cell - 0.5
        row = (L.FRAME_Y[1] - xy[:, 1]) / L.FRAME_H * self.cell - 0.5
        return col, row


# --- galaxy ---------------------------------------------------------------------------

class Galaxy:
    def __init__(self, seed=7, n=256):
        rng = np.random.default_rng(seed)
        self.dense = periodic_field(rng, n, 1.45, fmin=1, fmax=40)
        self.fast = periodic_field(rng, n, 1.05, fmin=2, fmax=60)
        self.warp_a = periodic_field(rng, n, 1.6, fmin=1, fmax=16)
        self.warp_c = periodic_field(rng, n, 1.6, fmin=1, fmax=16)
        self.wisp = periodic_field(rng, n, 1.4, fmin=1, fmax=24)
        self.flicker = periodic_field(rng, n, 1.8, fmin=1, fmax=8)

        stars = []
        for _ in range(140):
            stars.append((rng.uniform(0, 1), rng.uniform(-0.88, 0.88), rng.integers(1, 3),
                          rng.integers(1, 4), rng.uniform(0, 1), rng.uniform(0.6, 1.4), rng.uniform(0.5, 1.4)))
        self.stars = stars
        sparkles = []
        for _ in range(8):
            sparkles.append((rng.uniform(0, 1), rng.uniform(-0.5, 0.5), 1, rng.integers(1, 3),
                             rng.uniform(0, 1), rng.uniform(0.7, 1.0)))
        self.sparkles = sparkles

    def frame(self, f, k, phase):
        """RGBA float image of loop frame k (0..FRAMES-1)."""
        p = k / L.FRAMES  # one full period of scroll over the loop
        a = f.t * 1.0
        c = f.s * 4.2 + 0.31

        wa = sample(self.warp_a, a - p, c) * 0.09
        wc = sample(self.warp_c, a - p + 0.5, c + 0.25) * 0.06
        # second-order warp gives the swirling knots
        wa2 = sample(self.warp_a, a + wa * 1.7 - p + 0.21, c + wc * 1.7 + 0.6) * 0.06
        aw = a + wa + wa2
        cw = c + wc

        slow = sample(self.dense, aw - p, cw)
        fast = sample(self.fast, aw * 1.0 - 2 * p, cw * 1.3 + 0.5)
        dens = 0.62 * slow + 0.38 * fast
        dens = 1 / (1 + np.exp(-1.7 * (dens - 0.05)))  # 0..1

        ramp_x = np.array([0.0, 0.33, 0.58, 0.8, 0.95, 1.0])
        ramp_c = np.stack([VOID, VOID * 0.6 + INDIGO * 0.4, INDIGO, VIOLET, MAGENTA, MAGENTA * 0.6 + 0.4])
        rgb = np.stack([np.interp(dens, ramp_x, ramp_c[:, i]) for i in range(3)], axis=-1)

        # magenta hot streaks on the ridges of the fast layer
        ridge = np.clip(1 - np.abs(fast) * 1.6, 0, 1) ** 7
        rgb += MAGENTA * (ridge * smoothstep(0.35, 0.75, dens))[..., None] * 0.75
        # rare electric-blue wisps
        wisp = sample(self.wisp, aw - p + 0.37, cw * 0.8 + 0.13)
        wisp = smoothstep(1.35, 2.1, wisp)
        rgb = rgb * (1 - 0.45 * wisp[..., None]) + BLUE * wisp[..., None] * 0.8
        # deep void toward the spine, a little lift toward the base
        rgb *= (0.78 + 0.22 * np.abs(f.u).clip(0, 1))[..., None]

        star = np.zeros(f.t.shape)
        rows, cols = np.mgrid[0:f.cell, 0:f.cell]
        sc = f.cell / 512
        for t0, u0, speed, tw, ph, size, bright in self.stars:
            t = (t0 + p * speed) % 1.0
            env = np.sin(np.pi * t) ** 0.6
            twinkle = 0.5 + 0.5 * np.cos(2 * np.pi * (p * tw + ph))
            xy = f.point(np.array([t]), np.array([u0]))
            cx, cy = f.to_pixel(xy)
            sig = size * sc
            star += bright * env * (0.25 + 0.75 * twinkle ** 2) * np.exp(
                -((cols - cx[0]) ** 2 + ((rows - cy[0]) * 0.75) ** 2) / (2 * sig * sig))
        spark = np.zeros(f.t.shape)
        for t0, u0, speed, tw, ph, bright in self.sparkles:
            t = (t0 + p * speed) % 1.0
            env = np.sin(np.pi * t) ** 0.8
            twinkle = np.clip(np.cos(2 * np.pi * (p * tw + ph)), 0, 1) ** 2
            xy = f.point(np.array([t]), np.array([u0]))
            cx, cy = f.to_pixel(xy)
            dx = np.abs(cols - cx[0]) / sc
            dy = np.abs(rows - cy[0]) / sc
            arm = np.exp(-dx / 7.0) * np.exp(-dy / 0.9) + np.exp(-dy / 5.0) * np.exp(-dx / 0.9)
            core = np.exp(-(dx * dx + dy * dy) / 6.0)
            spark += bright * env * twinkle * (arm * 0.9 + core)
        rgb += (star + spark)[..., None] * np.array([1.0, 0.92, 1.0])

        # rim + halo from the signed distance
        d = f.dist
        aa = f.pixel * 1.1
        inside = smoothstep(aa, -aa, d)
        rim_w = 0.0042
        rim = np.exp(-np.maximum(-d, 0) / rim_w) * inside
        rim_col = RIM_BASE[None, None] * (1 - f.t.clip(0, 1))[..., None] + RIM_TIP[None, None] * f.t.clip(0, 1)[..., None]
        rgb = rgb * (1 - 0.85 * rim[..., None]) + rim_col * rim[..., None] * 1.25

        flick = 0.78 + 0.22 * sample(self.flicker, a - p, c * 0.5 + phase)
        halo = np.exp(-np.maximum(d, 0) / 0.019) * (1 - inside) * flick
        halo *= smoothstep(-0.06, 0.04, f.t) * smoothstep(1.08, 0.9, f.t)

        # keep cell borders transparent so mip levels don't bleed between frames
        edge = np.minimum.reduce([f.px - L.FRAME_X[0], L.FRAME_X[1] - f.px,
                                  f.py - L.FRAME_Y[0], L.FRAME_Y[1] - f.py])
        border = smoothstep(0.0, 0.012, edge)

        alpha = (inside + halo * 0.62 * (1 - inside)) * border
        col = rgb * inside[..., None] + HALO * (1 - inside)[..., None] * (1 + 0.4 * halo[..., None])
        return np.concatenate([np.clip(col, 0, 1), np.clip(alpha, 0, 1)[..., None]], axis=-1)


def to_u8(img):
    return (np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8)


def render_atlases(cell, out):
    f = Feather(cell)
    gal = Galaxy()
    frames = []
    for k in range(L.FRAMES):
        frames.append(to_u8(gal.frame(f, k, 0.0)))
        print(f"  frame {k + 1}/{L.FRAMES}", end="\r", flush=True)
    print()
    per = L.GRID * L.GRID
    for side in ("R", "L"):
        for a in range(L.ATLASES):
            atlas = np.zeros((cell * L.GRID, cell * L.GRID, 4), np.uint8)
            for sub in range(per):
                k = a * per + sub
                _, col, row = L.frame_cell(k)
                img = frames[k] if side == "R" else frames[k][:, ::-1]
                atlas[row * cell:(row + 1) * cell, col * cell:(col + 1) * cell] = img
            Image.fromarray(atlas, "RGBA").save(os.path.join(out, f"feather_{side}_{a}.png"), optimize=True)
    return frames


def render_particles(out, size=128):
    g = (np.arange(size) + 0.5) / size * 2 - 1
    x, y = np.meshgrid(g, g)
    r = np.sqrt(x * x + y * y)

    # 4-point sparkle
    ax, ay = np.abs(x), np.abs(y)
    arms = np.exp(-ax / 0.32) * np.exp(-ay / 0.035) + np.exp(-ay / 0.32) * np.exp(-ax / 0.035)
    diag = (np.exp(-np.abs(x - y) / 0.03) + np.exp(-np.abs(x + y) / 0.03)) * np.exp(-r / 0.18) * 0.35
    core = np.exp(-r * r / 0.012)
    glow = np.exp(-r * r / 0.09) * 0.35
    a = np.clip(arms + diag + core + glow, 0, 1) * smoothstep(1.0, 0.85, r)
    save_sprite(out, "sparkle", a)

    # void mote: soft dot with a halo
    a = np.clip(np.exp(-r * r / 0.05) + np.exp(-r * r / 0.35) * 0.4, 0, 1) * smoothstep(1.0, 0.8, r)
    save_sprite(out, "mote", a, size=64)

    # wisp: soft streak with a little curl
    rng = np.random.default_rng(3)
    field = periodic_field(rng, size, 1.7, fmin=1, fmax=10)
    yy = y + 0.18 * np.sin(x * 2.6) + 0.06 * field
    a = np.exp(-(yy / 0.16) ** 2) * smoothstep(1.0, 0.25, np.abs(x)) * (0.7 + 0.3 * field.clip(-1, 1))
    save_sprite(out, "wisp", np.clip(a, 0, 1))


def save_sprite(out, name, alpha, size=None):
    img = np.ones(alpha.shape + (4,))
    img[..., 3] = alpha
    im = Image.fromarray(to_u8(img), "RGBA")
    if size:
        im = im.resize((size, size), Image.LANCZOS)
    im.save(os.path.join(out, name + ".png"), optimize=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="256 px cells")
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    cell = 256 if args.quick else L.CELL
    print(f"rendering {L.FRAMES} frames at {cell}px ...")
    render_atlases(cell, args.out)
    render_particles(args.out)
    print("wrote", args.out)


if __name__ == "__main__":
    main()

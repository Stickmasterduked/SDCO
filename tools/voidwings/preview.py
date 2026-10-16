"""Offline preview of the Void Wings rig: composites the real atlases onto an R6
silhouette with the same feather transforms the Luau rig uses, so mirroring
and spread can be checked without Studio.

    python3 tools/voidwings/preview.py                 # previews/voidwings_{back,quarter}.png + .gif
    python3 tools/voidwings/preview.py --assets DIR    # read atlases from DIR
"""
import argparse
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout as L  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def rx(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0, 0], [0, c, -s, 0], [0, s, c, 0], [0, 0, 0, 1]])


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s, 0], [0, 1, 0, 0], [-s, 0, c, 0], [0, 0, 0, 1]])


def rz(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0, 0], [s, c, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])


def tr(x, y, z):
    m = np.eye(4)
    m[:3, 3] = (x, y, z)
    return m


def feather_cframes(t, scale=L.SCALE):
    """[(side, feather, 4x4 torso-space cframe, (width, height))] at time t.
    Mirrors VoidWings.luau's feather transform exactly."""
    rad = math.radians
    beat = math.sin(2 * math.pi * L.BEAT_HZ * t)
    breathe = L.BREATHE_STUDS * math.sin(2 * math.pi * L.BREATHE_HZ * t)
    out = []
    for side in (1, -1):
        rootx, rooty, rootz = L.WING_ROOT
        wing = (tr(side * rootx * scale, rooty * scale + breathe, rootz * scale)
                @ ry(-side * rad(L.SWEEP_DEG + L.BEAT_DEG * beat))
                @ rx(rad(L.TILT_DEG))
                @ rz(side * rad(L.BEAT_LIFT_DEG * beat)))
        for fe in L.FEATHERS:
            length = fe["length"] * scale
            w, h = L.FRAME_W * length, L.FRAME_H * length
            flutter = fe["flutter"] * math.sin(2 * math.pi * L.BEAT_HZ * 2 * t - fe["phase"])
            bx, by = fe["base"]
            cf = (wing
                  @ tr(side * bx * scale, by * scale, fe["depth"] * scale)
                  @ rz(-side * rad(fe["angle"] + flutter))
                  @ tr(side * (0.5 - L.BASE_U) * w, (L.BASE_V - 0.5) * h, 0))
            out.append((side, fe, cf, (w, h)))
    return out


class Camera:
    def __init__(self, yaw_deg, pitch_deg, size, ppu, centre=(0, 0.8)):
        # camera behind the character (+Z), turned by yaw around Y
        self.view = rx(math.radians(pitch_deg)) @ ry(math.radians(-yaw_deg))
        self.size = size
        self.ppu = ppu
        self.centre = centre

    def project(self, p):
        v = self.view @ np.array([p[0], p[1], p[2], 1.0])
        x = self.size[0] / 2 + (v[0] - self.centre[0]) * self.ppu
        y = self.size[1] / 2 - (v[1] - self.centre[1]) * self.ppu
        return np.array([x, y]), v[2]  # larger z = nearer the camera

    def facing(self, direction):
        return (self.view[:3, :3] @ direction)[2]


def box_faces(cf, size, colour):
    """Visible-agnostic quads of a box: (corners, normal, colour)."""
    sx, sy, sz = (s / 2 for s in size)
    faces = []
    for axis in range(3):
        for sign in (-1, 1):
            n = np.zeros(3)
            n[axis] = sign
            u = np.zeros(3)
            v = np.zeros(3)
            u[(axis + 1) % 3] = 1
            v[(axis + 2) % 3] = 1
            half = np.array([sx, sy, sz])
            c = n * half
            du = u * half
            dv = v * half
            corners = [c - du - dv, c + du - dv, c + du + dv, c - du + dv]
            corners = [(cf @ np.append(p, 1))[:3] for p in corners]
            shade = 0.75 + 0.25 * max(0, n @ np.array([0.3, 0.8, 0.5]))
            faces.append((corners, cf[:3, :3] @ n, tuple(int(ch * shade) for ch in colour)))
    return faces


def r6_parts(breathe=0.0):
    torso = np.eye(4)
    skin = (165, 200, 230)
    shirt = (24, 36, 70)
    parts = [
        (torso, (2, 2, 1), shirt),
        (tr(0, 1.5, 0), (1.2, 1.2, 1.2), skin),
        (tr(1.5, 0, 0), (1, 2, 1), skin),
        (tr(-1.5, 0, 0), (1, 2, 1), skin),
        (tr(0.5, -2, 0), (1, 2, 1), shirt),
        (tr(-0.5, -2, 0), (1, 2, 1), shirt),
    ]
    return parts


def load_atlases(folder):
    atl = {}
    for side in ("R", "L"):
        atl[side] = [Image.open(os.path.join(folder, f"feather_{side}_{a}.png")).convert("RGBA") for a in range(L.ATLASES)]
    return atl


def cell_image(atl, side, k):
    a, col, row = L.frame_cell(k)
    img = atl[side][a]
    c = img.width // L.GRID
    return img.crop((col * c, row * c, (col + 1) * c, (row + 1) * c))


def draw_quad_texture(canvas, cam, corners_img, tex):
    """corners_img: world points for image (0,0), (1,0), (0,1)."""
    p0, _ = cam.project(corners_img[0])
    pu, _ = cam.project(corners_img[1])
    pv, _ = cam.project(corners_img[2])
    eu, ev = pu - p0, pv - p0
    m = np.array([[eu[0], ev[0]], [eu[1], ev[1]]])
    if abs(np.linalg.det(m)) < 1e-3:
        return
    inv = np.linalg.inv(m)
    tw, th = tex.size
    a, b = inv[0] * tw
    d, e = inv[1] * th
    c = -(a * p0[0] + b * p0[1])
    f = -(d * p0[0] + e * p0[1])
    warped = tex.transform(canvas.size, Image.AFFINE, (a, b, c, d, e, f), resample=Image.BILINEAR)
    canvas.alpha_composite(warped)


def render(atl, t, cam, background=(78, 160, 215)):
    canvas = Image.new("RGBA", cam.size, background + (255,))
    ground = ImageDraw.Draw(canvas)
    gy = cam.project((0, -3, 0))[0][1]
    ground.rectangle((0, gy, cam.size[0], cam.size[1]), fill=(28, 34, 52, 255))

    items = []  # (depth, kind, payload)
    for cf, size, colour in r6_parts():
        for corners, normal, shade in box_faces(cf, size, colour):
            if cam.facing(normal) <= 0:
                continue
            pts = [cam.project(p) for p in corners]
            depth = sum(z for _, z in pts) / 4
            items.append((depth, "poly", ([tuple(p) for p, _ in pts], shade)))

    k_now = int(t * L.FPS)
    for side, fe, cf, (w, h) in feather_cframes(t):
        back = cam.facing(cf[:3, 2]) > 0  # part's +Z (Back face) toward camera
        if back:
            img_side = "R" if side == 1 else "L"
            o = (-w / 2, h / 2)
            ux = 1
        else:
            img_side = "L" if side == 1 else "R"
            o = (w / 2, h / 2)
            ux = -1
        z = 0.025 if back else -0.025
        p00 = (cf @ np.array([o[0], o[1], z, 1]))[:3]
        p10 = (cf @ np.array([o[0] + ux * w, o[1], z, 1]))[:3]
        p01 = (cf @ np.array([o[0], o[1] - h, z, 1]))[:3]
        centre = (cf @ np.array([0, 0, 0, 1]))[:3]
        depth = cam.project(centre)[1]
        frame = (k_now + fe["frame"]) % L.FRAMES
        items.append((depth, "tex", ((p00, p10, p01), cell_image(atl, img_side, frame))))

    items.sort(key=lambda it: it[0])
    for _, kind, payload in items:
        if kind == "poly":
            layer = Image.new("RGBA", cam.size, (0, 0, 0, 0))
            ImageDraw.Draw(layer).polygon(payload[0], fill=payload[1] + (255,))
            canvas.alpha_composite(layer)
        else:
            draw_quad_texture(canvas, cam, *payload)
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--assets", default=os.path.join(ROOT, "assets", "voidwings"))
    ap.add_argument("--out", default=os.path.join(ROOT, "previews"))
    ap.add_argument("--no-gif", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    atl = load_atlases(args.assets)
    size = (900, 640)
    views = {
        "back": Camera(0, 8, size, 62, centre=(0, 1.0)),
        "quarter": Camera(38, 10, size, 62, centre=(0, 1.0)),
        "side": Camera(90, 4, size, 62, centre=(0, 1.0)),
    }
    for name, cam in views.items():
        render(atl, 0.4, cam).convert("RGB").save(os.path.join(args.out, f"voidwings_{name}.png"))
        print("wrote", f"voidwings_{name}.png")
    if not args.no_gif:
        cam = Camera(20, 8, (640, 460), 44, centre=(0, 1.0))
        frames = [render(atl, i / L.FPS, cam).convert("RGB") for i in range(int(L.FPS / L.BEAT_HZ))]
        frames[0].save(os.path.join(args.out, "voidwings.gif"), save_all=True, append_images=frames[1:],
                       duration=int(1000 / L.FPS), loop=0)
        print("wrote voidwings.gif")


if __name__ == "__main__":
    main()

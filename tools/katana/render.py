"""Tiny software renderer for previews: R6 boxes + katana, a ground grid and
additive glowing VFX (strokes, glows, particles) with bloom.

Not Roblox, but the same geometry: rigs come from rig.fk, VFX layers from
fxscore (the data KatanaFX plays in game), so silhouettes, timing and
contact alignment can be judged frame by frame.
"""
import math

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

import cf
import rig

BODY_COLORS = {
    "attacker": {"Torso": (34, 36, 44), "Head": (226, 222, 230), "RightArm": (226, 222, 230), "LeftArm": (226, 222, 230), "RightLeg": (232, 232, 236), "LeftLeg": (232, 232, 236)},
    "target": {"Torso": (200, 92, 60), "Head": (230, 190, 150), "RightArm": (200, 92, 60), "LeftArm": (200, 92, 60), "RightLeg": (60, 56, 70), "LeftLeg": (60, 56, 70)},
}
LIGHT = cf.unit(np.array([-0.4, 0.85, 0.35]))


class Camera:
    def __init__(self, eye, target, fov=70, size=(640, 360)):
        self.size = size
        self.fov = fov
        self.set(eye, target)

    def set(self, eye, target):
        eye, target = np.asarray(eye, float), np.asarray(target, float)
        f = cf.unit(target - eye)
        r = cf.unit(np.cross(f, [0, 1, 0]))
        u = np.cross(r, f)
        self.cf = cf.from_matrix(eye, r, u, -f)
        self.inv = cf.inv(self.cf)
        self.eye = eye

    def project(self, p):
        """(x, y, depth) in pixels; depth <= 0 is behind the camera."""
        q = cf.point(self.inv, p)
        z = -q[2]
        w, h = self.size
        if z <= 0.05:
            return None
        s = (h / 2) / math.tan(math.radians(self.fov) / 2)
        return (w / 2 + q[0] / z * s, h / 2 - q[1] / z * s, z)

    def scale_at(self, p):
        q = cf.point(self.inv, p)
        z = max(-q[2], 0.05)
        return (self.size[1] / 2) / math.tan(math.radians(self.fov) / 2) / z


class Frame:
    def __init__(self, camera, ground_y=0.0):
        self.cam = camera
        w, h = camera.size
        self.w, self.h = w, h
        self.polys = []  # (depth, points, rgb)
        self.add = np.zeros((h, w, 3), np.float32)
        self.ground_y = ground_y
        self.flash = 0.0
        self.flash_color = (1, 1, 1)
        self.labels = []

    # -- solid geometry ---------------------------------------------------
    def box(self, m, size, color, alpha=1.0):
        sx, sy, sz = [s / 2 for s in size]
        corners = {}
        for x in (-1, 1):
            for y in (-1, 1):
                for z in (-1, 1):
                    corners[(x, y, z)] = cf.point(m, (x * sx, y * sy, z * sz))
        faces = [
            ((1, 0, 0), [(1, -1, -1), (1, 1, -1), (1, 1, 1), (1, -1, 1)]),
            ((-1, 0, 0), [(-1, -1, -1), (-1, -1, 1), (-1, 1, 1), (-1, 1, -1)]),
            ((0, 1, 0), [(-1, 1, -1), (-1, 1, 1), (1, 1, 1), (1, 1, -1)]),
            ((0, -1, 0), [(-1, -1, -1), (1, -1, -1), (1, -1, 1), (-1, -1, 1)]),
            ((0, 0, 1), [(-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]),
            ((0, 0, -1), [(-1, -1, -1), (-1, 1, -1), (1, 1, -1), (1, -1, -1)]),
        ]
        for normal, idx in faces:
            n = cf.vec(m, normal)
            centre = sum(corners[i] for i in idx) / 4
            if np.dot(n, self.cam.eye - centre) <= 0:
                continue
            pts = [self.cam.project(corners[i]) for i in idx]
            if any(p is None for p in pts):
                continue
            shade = 0.45 + 0.55 * max(0.0, float(np.dot(n, LIGHT)))
            rgb = tuple(int(c * shade) for c in color)
            depth = sum(p[2] for p in pts) / 4
            self.polys.append((depth, [(p[0], p[1]) for p in pts], rgb, alpha))

    def rig(self, pose, root, grip, palette="attacker", blade_glow=1.0, ghost=None):
        frames = rig.fk(pose, root, grip)
        colors = BODY_COLORS[palette]
        for j in ("Torso",) + rig.LIMBS:
            col = colors[j] if ghost is None else ghost
            self.box(frames[j], rig.SIZE[j], col, 1.0 if ghost is None else 0.35)
        if grip is not None and "Blade" in frames:
            b = frames["Blade"]
            pts = rig.blade_points(frames, grip)
            # handle and guard as solid boxes, the blade as glowing light
            hl = grip.handle_back + grip.blade[0]
            self.box(b @ cf.new(0, 0, (grip.handle_back - grip.blade[0]) / 2), (0.22, 0.26, hl), (30, 28, 40))
            self.box(b @ cf.new(0, 0, -grip.blade[0]), (0.55, 0.55, 0.08), (200, 196, 210))
            if blade_glow > 0:
                self.stroke([pts["guard"], pts["tip"]], [0.32, 0.12], [(1, 1, 1)] * 2, [blade_glow, blade_glow * 0.9])
                self.stroke([pts["guard"], pts["tip"]], [1.0, 0.5], [(0.72, 0.62, 1.0)] * 2, [0.35 * blade_glow, 0.25 * blade_glow])
        return frames

    # -- additive light ---------------------------------------------------
    def _quad_mask(self, pts):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        x0, x1 = max(int(min(xs)) - 1, 0), min(int(max(xs)) + 2, self.w)
        y0, y1 = max(int(min(ys)) - 1, 0), min(int(max(ys)) + 2, self.h)
        if x1 <= x0 or y1 <= y0:
            return None
        img = Image.new("L", (x1 - x0, y1 - y0), 0)
        ImageDraw.Draw(img).polygon([(x - x0, y - y0) for x, y in pts], fill=255)
        return x0, y0, np.asarray(img, np.float32) / 255

    def stroke(self, points, widths, colors, alphas, face_camera=True):
        """Face-camera tapered polyline (one Beam per segment in game)."""
        proj = [self.cam.project(p) for p in points]
        for i in range(len(points) - 1):
            a, b = proj[i], proj[i + 1]
            if a is None or b is None:
                continue
            d = np.array([b[0] - a[0], b[1] - a[1]])
            n = np.linalg.norm(d)
            if n < 1e-6:
                continue
            perp = np.array([-d[1], d[0]]) / n
            wa = widths[i] * self.cam.scale_at(points[i]) / 2
            wb = widths[i + 1] * self.cam.scale_at(points[i + 1]) / 2
            if wa + wb < 0.15:
                continue
            quad = [tuple(np.array(a[:2]) + perp * wa), tuple(np.array(b[:2]) + perp * wb),
                    tuple(np.array(b[:2]) - perp * wb), tuple(np.array(a[:2]) - perp * wa)]
            m = self._quad_mask(quad)
            if m is None:
                continue
            x0, y0, mask = m
            col = (np.array(colors[i], np.float32) + np.array(colors[i + 1], np.float32)) / 2
            al = (alphas[i] + alphas[i + 1]) / 2
            if al <= 0.001:
                continue
            region = self.add[y0:y0 + mask.shape[0], x0:x0 + mask.shape[1]]
            region += mask[..., None] * col * al

    def glow(self, p, radius, color, alpha, star=0.0, star_angle=0.0):
        q = self.cam.project(p)
        if q is None or alpha <= 0.001:
            return
        r = max(radius * self.cam.scale_at(p), 0.5)
        x0, x1 = int(max(q[0] - r * 2.5, 0)), int(min(q[0] + r * 2.5 + 1, self.w))
        y0, y1 = int(max(q[1] - r * 2.5, 0)), int(min(q[1] + r * 2.5 + 1, self.h))
        if x1 <= x0 or y1 <= y0:
            return
        yy, xx = np.mgrid[y0:y1, x0:x1]
        dx, dy = (xx - q[0]) / r, (yy - q[1]) / r
        d2 = dx * dx + dy * dy
        g = np.exp(-d2 * 2.2)
        if star > 0:
            ca, sa = math.cos(star_angle), math.sin(star_angle)
            u, v = dx * ca + dy * sa, -dx * sa + dy * ca
            g = g + star * (np.exp(-np.abs(v) * 14 - np.abs(u) * 0.9) + np.exp(-np.abs(u) * 14 - np.abs(v) * 0.9))
        self.add[y0:y1, x0:x1] += g[..., None].astype(np.float32) * np.array(color, np.float32) * alpha

    def screen_flash(self, amount, color=(1, 1, 1)):
        if amount > self.flash:
            self.flash = amount
            self.flash_color = color

    def label(self, text):
        self.labels.append(text)

    # -- output -------------------------------------------------------------
    def render(self, background=True):
        w, h = self.w, self.h
        img = Image.new("RGB", (w, h))
        d = ImageDraw.Draw(img)
        # sky / ground
        horizon = None
        p = self.cam.project(self.cam.eye + cf.look(self.cam.cf) * 400 * np.array([1, 0, 1]) + np.array([0, self.ground_y - self.cam.eye[1], 0]))
        horizon = p[1] if p else h * 0.35
        for y in range(h):
            if y < horizon:
                t = y / max(horizon, 1)
                c = (int(20 + 30 * t), int(26 + 36 * t), int(40 + 46 * t))
            else:
                t = (y - horizon) / max(h - horizon, 1)
                c = (int(26 - 8 * t), int(29 - 8 * t), int(38 - 10 * t))
            d.line([(0, y), (w, y)], fill=c)
        # grid
        cx, cz = round(self.cam.eye[0] / 4) * 4, round(self.cam.eye[2] / 4) * 4
        for i in range(-24, 25):
            for a, b in (((cx + i * 4, self.ground_y, cz - 96), (cx + i * 4, self.ground_y, cz + 96)),
                         ((cx - 96, self.ground_y, cz + i * 4), (cx + 96, self.ground_y, cz + i * 4))):
                pa, pb = self._clip_line(np.array(a, float), np.array(b, float))
                if pa is not None:
                    d.line([pa, pb], fill=(40, 44, 56), width=1)
        for depth, pts, rgb, alpha in sorted(self.polys, key=lambda x: -x[0]):
            if alpha >= 1:
                d.polygon(pts, fill=rgb)
            else:
                over = Image.new("RGBA", (w, h), (0, 0, 0, 0))
                ImageDraw.Draw(over).polygon(pts, fill=rgb + (int(255 * alpha),))
                img = Image.alpha_composite(img.convert("RGBA"), over).convert("RGB")
                d = ImageDraw.Draw(img)
        base = np.asarray(img, np.float32) / 255
        add = self.add
        # bloom: two blur radii of the light layer
        bloom = np.zeros_like(add)
        for radius, weight in ((4, 0.55), (14, 0.45)):
            for c in range(3):
                ch = Image.fromarray(np.clip(add[..., c] * 64, 0, 255).astype(np.uint8))
                bloom[..., c] += np.asarray(ch.filter(ImageFilter.GaussianBlur(radius)), np.float32) / 64 * weight
        out = base + add * 0.9 + bloom
        if self.flash > 0:
            out = out + np.array(self.flash_color, np.float32) * self.flash
        # soft clip (filmic-ish): keeps hot cores white instead of flat
        out = 1 - np.exp(-np.maximum(out, 0) * 1.25)
        out = np.clip(out / (1 - math.exp(-1.25)), 0, 1)
        img = Image.fromarray((out * 255).astype(np.uint8))
        if self.labels:
            dr = ImageDraw.Draw(img)
            for i, text in enumerate(self.labels):
                dr.text((8, 8 + 14 * i), text, fill=(235, 235, 245))
        return img

    def _clip_line(self, a, b):
        qa, qb = cf.point(self.cam.inv, a), cf.point(self.cam.inv, b)
        near = -0.2
        if qa[2] > near and qb[2] > near:
            return None, None
        if qa[2] > near or qb[2] > near:
            t = (near - qa[2]) / (qb[2] - qa[2])
            m = a + (b - a) * t
            if qa[2] > near:
                a = m
            else:
                b = m
        pa, pb = self.cam.project(a), self.cam.project(b)
        if pa is None or pb is None:
            return None, None
        return (pa[0], pa[1]), (pb[0], pb[1])


def sheet(images, cols, scale=1.0):
    w, h = images[0].size
    w2, h2 = int(w * scale), int(h * scale)
    rows = math.ceil(len(images) / cols)
    out = Image.new("RGB", (w2 * cols, h2 * rows), (0, 0, 0))
    for i, im in enumerate(images):
        out.paste(im.resize((w2, h2)), ((i % cols) * w2, (i // cols) * h2))
    return out

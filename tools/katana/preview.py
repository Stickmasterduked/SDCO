"""Renders the katana skills in motion: the baked animation, the dash, the
travelling crescent and the VFX score (the same data KatanaFX plays, drawn
with the same geometry and the generated sprites).

    python3 preview.py                 # both moves, game + side camera
    python3 preview.py --slow 4        # slow motion (x4)
    python3 preview.py --move Katana_Rush --sheet 0.55 0.95 16

Writes previews/<move>_<camera>[_slow].gif and contact sheets.
"""
import argparse
import math
import os
import random

import numpy as np
from PIL import Image

import anim
import bake
import cf
import fxscore
import motionprofile
import render
import rig

OUT = os.path.join(rig.ROOT, "previews")
TEX = os.path.join(rig.ROOT, "assets", "katana")
FPS = 60
SKIN_ALPHA = {"core": 1.0, "flow": 0.85, "soft": 0.55}

RUSH_TARGET = 21.0
RUSH_STOP = 5.2
RUSH_DURATION = 0.3
HITSTOP = 0.16
CRESCENT_TARGET = 34.0


def ev(keys, t):
    if not isinstance(keys, list):
        return keys
    if t <= keys[0][0]:
        return keys[0][1]
    for a, b in zip(keys, keys[1:]):
        if t <= b[0]:
            al = (t - a[0]) / (b[0] - a[0]) if b[0] > a[0] else 1
            va, vb = a[1], b[1]
            if isinstance(va, (list, tuple)):
                return [va[i] + (vb[i] - va[i]) * al for i in range(3)]
            return va + (vb - va) * al
    return keys[-1][1]


def c01(c):
    return tuple(x / 255 for x in c)


def frame_xy(origin, x, y):
    x = cf.unit(x)
    y = np.asarray(y, float) - x * np.dot(y, x)
    if np.linalg.norm(y) < 1e-4:
        y = np.array([0.0, 1.0, 0.0]) if abs(x[1]) < 0.9 else np.array([0.0, 0.0, 1.0])
        y = y - x * np.dot(y, x)
    y = cf.unit(y)
    return cf.from_matrix(origin, x, y, np.cross(x, y))


def billboard(frame, amount, eye):
    if not amount:
        return frame
    x = cf.right(frame)
    to = eye - cf.pos(frame)
    to = to - x * np.dot(to, x)
    if np.linalg.norm(to) < 1e-3:
        return frame
    to = cf.unit(to)
    z = frame[:3, 2].copy()
    if np.dot(z, to) < 0:
        z = -z
    angle = math.atan2(np.dot(np.cross(z, to), x), np.dot(z, to))
    return frame @ cf.axis_angle([1, 0, 0], angle * amount)


def profile(s, taper):
    if not taper:
        return 1.0
    a, b = taper
    if s <= 0 or s >= 1:
        return 0.0
    peak = a / (a + b)
    return (s / peak) ** a * ((1 - s) / (1 - peak)) ** b


def chord_to_arc(chord, sag):
    sag = max(sag, 0.05)
    r = (chord * chord / 4 + sag * sag) / (2 * sag)
    half = math.asin(max(-1, min(1, chord / (2 * r))))
    return r, math.degrees(2 * half)


def shape_points(layer, u, s0, s1, count):
    pos, nrm, ss = [], [], []
    shape = layer["shape"]
    off = np.array(layer.get("offset", [0, 0, 0]), float)
    if "move" in layer:
        off = off + np.array(layer["move"], float) * u
    if shape in ("arc", "chord"):
        if shape == "chord":
            sag = ev(layer["sagitta"], u)
            radius, span = chord_to_arc(layer["chord"], sag)
            apex = sag
        else:
            radius = layer["radius"] * (ev(layer["radiusScale"], u) if "radiusScale" in layer else 1)
            span, apex = layer["span"], 0.0
        mid = math.radians(layer.get("mid", 90))
        half = math.radians(span) / 2
        for i in range(count):
            s = s0 + (s1 - s0) * i / (count - 1)
            th = mid + half - s * 2 * half
            c, sn = math.cos(th), math.sin(th)
            pos.append(np.array([c * radius, sn * radius - radius + apex, 0]) + off)
            nrm.append(np.array([c, sn, 0.0]))
            ss.append(s)
    elif shape == "ring":
        radius = ev(layer["radius"], u)
        ground = layer.get("plane") == "ground"
        for i in range(count):
            s = s0 + (s1 - s0) * i / (count - 1)
            th = s * 2 * math.pi
            c, sn = math.cos(th), math.sin(th)
            n = np.array([c, 0, sn]) if ground else np.array([c, sn, 0])
            pos.append(n * radius + off)
            nrm.append(n)
            ss.append(s)
    elif shape == "line":
        pts = layer["points"]
        seg = len(pts) - 1
        for i in range(count):
            s = s0 + (s1 - s0) * i / (count - 1)
            x = s * seg
            k = min(max(int(math.floor(x)), 0), seg - 1)
            f = x - k
            a, b = np.array(pts[k], float), np.array(pts[k + 1], float)
            d = b - a
            n = np.array([-d[1], d[0], 0]) / max(np.linalg.norm(d), 1e-4)
            pos.append(a + (b - a) * f + off)
            nrm.append(n)
            ss.append(s)
    return pos, nrm, ss


def hue(t):
    import colorsys
    r, g, b = colorsys.hsv_to_rgb(t % 1, 0.55, 1)
    return (r * 255, g * 255, b * 255)


SPRITES = {}


def sprite_img(name):
    if name not in SPRITES:
        path = os.path.join(TEX, name + ".png")
        SPRITES[name] = Image.open(path).convert("RGBA") if os.path.exists(path) else None
    return SPRITES[name]


def bright(b):
    return 0.35 + 0.22 * (b or 1)


class Scene:
    """One playback of a move: bodies, live layers, camera cues."""

    def __init__(self, move, grip, clips, idle):
        self.move = move
        self.grip = grip
        self.clip = clips[move]
        self.idle = idle
        self.spec = fxscore.SCORE[move]
        self.layers = []  # (spawn real time, layer, ctx)
        self.live = []
        self.trail_hist = []
        self.wake_hist = []
        self.ghosts = []
        self.tip_hist = []
        self.flash = 0.0
        self.shake = 0.0
        self.punch = np.zeros(3)
        self.punch_v = np.zeros(3)
        self.target_root = cf.new(0, 3, -(RUSH_TARGET if move == "Katana_Rush" else CRESCENT_TARGET)) @ cf.ry(math.pi)
        self.target_vel = np.zeros(3)
        self.hit = None
        self.hitstop_until = -1
        self.clip_time = 0.0
        self.cast_index = 0
        self.cast = sorted(self.spec["cast"], key=lambda l: l["at"])
        self.projectile = None
        self.start_delay = 0.25

    # -- bodies ---------------------------------------------------------------
    def root(self, t):
        if self.move == "Katana_Rush":
            start = self.clip["markers"]["Dash"]
            dist = max(4.0, RUSH_TARGET - RUSH_STOP)
            return cf.new(0, 3, -dist * motionprofile.fraction((t - start) / RUSH_DURATION))
        return cf.new(0, 3, 0)

    def pose(self, t):
        if t < 0 or t > self.clip["length"]:
            return self.idle
        return bake.sample_pose(self.clip, t)

    def blade(self, t):
        fr = rig.fk(self.pose(t), self.root(t), self.grip)
        pts = rig.blade_points(fr, self.grip)
        return pts["guard"], pts["tip"]

    # -- frames ------------------------------------------------------------------
    def frames(self, t):
        root = self.root(t)
        base, tip = self.blade(t)
        sweep = self.sweep if hasattr(self, "sweep") else cf.right(root)
        feet = cf.pos(root) - np.array([0, 3, 0])
        return {
            "tip": frame_xy(tip, sweep, tip - base),
            "root": root,
            "feet": cf.from_matrix(feet, cf.right(root), [0, 1, 0], np.cross(cf.right(root), [0, 1, 0])),
            "release": cf.from_matrix(tip, cf.right(root), [0, 1, 0], np.cross(cf.right(root), [0, 1, 0])),
        }

    # -- spawning ----------------------------------------------------------------
    def spawn(self, layer, frames, real, role="attacker"):
        f = frames.get(layer.get("frame", "root"), frames.get("root"))
        kind = layer["type"]
        item = {"layer": layer, "frame": f, "start": real, "role": role, "frames": frames}
        if kind == "camera":
            cue = layer.get(role) if role in layer else None
            if role == "attacker" and "attacker" in layer:
                cue = layer["attacker"]
            if cue:
                self.shake = min(1, self.shake + cue.get("shake", 0))
                if "punch" in cue:
                    p = cue["punch"]
                    self.punch_v += cf.vec(f, p[:3]) * p[3] * 9
                if "flash" in cue:
                    self.flash = max(self.flash, cue["flash"])
            return
        if kind in ("sound",):
            return
        if kind == "converge":
            rng = random.Random(layer.get("seed", 1))
            item["streaks"] = []
            for i in range(layer["count"]):
                d = cf.unit([rng.uniform(-1, 1), rng.uniform(-0.4, 1), rng.uniform(-1, 1)])
                item["streaks"].append((i / layer["count"] * layer["life"] * 0.6, d, rng.uniform(0.35, 1)))
        if kind == "sparks":
            rng = random.Random(hash(str(layer)) & 0xffff)
            d = cf.unit(cf.vec(f, layer["dir"]))
            parts = []
            dirs = [d] if not layer.get("mirror") else [d, -d]
            for i in range(layer["count"]):
                dd = dirs[i % len(dirs)]
                spread = math.radians(layer["spread"])
                # random direction in a cone
                rnd = cf.unit(np.cross(dd, [0.3, 1, 0.2]))
                rnd2 = np.cross(dd, rnd)
                a, b = rng.uniform(0, 2 * math.pi), rng.uniform(0, spread)
                v = cf.unit(dd * math.cos(b) + (rnd * math.cos(a) + rnd2 * math.sin(a)) * math.sin(b))
                parts.append((v * rng.uniform(*layer["speed"]), rng.uniform(*layer["life"])))
            item["parts"] = parts
        if kind == "risers":
            rng = random.Random(layer.get("seed", 1))
            item["risers"] = []
            for _ in range(layer["count"]):
                a = rng.uniform(0, 2 * math.pi)
                r = rng.uniform(*layer["radius"])
                item["risers"].append((np.array([math.cos(a) * r, 0, math.sin(a) * r]), rng.uniform(*layer["height"]),
                                       rng.uniform(*layer["speed"]), rng.uniform(*layer["life"]), rng.uniform(0, 0.08)))
        if kind == "bladewisps":
            rng = random.Random(layer.get("seed", 1))
            base, tip = self.blade(self.clip_time)
            fr = frame_xy(base, tip - base, [0, 1, 0])
            length = np.linalg.norm(tip - base)
            item["frame"] = fr
            item["layer"] = {"type": "wisps", "billboard": 0, "color": (255, 255, 255), "tint": fxscore.LAVENDER,
                             "wisps": [{"p": [rng.uniform(0.3, 1) * length, 0, 0], "v": [rng.uniform(-0.5, 0.5), rng.uniform(2, 4), rng.uniform(-0.8, 0.8)],
                                        "curl": rng.uniform(-1.5, 1.5), "length": rng.uniform(0.8, 1.4), "width": rng.uniform(0.12, 0.22),
                                        "life": layer["life"] * rng.uniform(0.7, 1), "delay": rng.uniform(0, 0.15)} for _ in range(layer["count"])]}
        if kind == "sprite" or kind == "glow":
            item["rotation"] = layer.get("rotation", 0)
        self.live.append(item)

    # -- drawing -----------------------------------------------------------------
    def draw_chain(self, fr, pts, widths, alphas, skin, colors=None):
        a = skin.get("alpha", 1) * SKIN_ALPHA.get(skin.get("tex", "core"), 1)
        b = bright(skin.get("brightness", 1))
        col = c01(skin["color"])
        cs = [c01(c) for c in colors] if colors else [col] * len(pts)
        if skin.get("tex") == "soft":
            # soft ribbon: a feathered pair of quads
            fr.stroke(pts, [w for w in widths], cs, [x * a * b * 0.5 for x in alphas])
            fr.stroke(pts, [w * 0.55 for w in widths], cs, [x * a * b * 0.5 for x in alphas])
        else:
            fr.stroke(pts, [w * 0.45 for w in widths], cs, [x * a * b for x in alphas])
            fr.stroke(pts, widths, cs, [x * a * b * 0.4 for x in alphas])

    def draw_item(self, fr, item, real, eye):
        layer, kind = item["layer"], item["layer"]["type"]
        age = real - item["start"]
        life = layer.get("life", 1)
        if kind == "stroke":
            if age >= life:
                return False
            u = age / life
            frame = billboard(item["frame"], layer.get("billboard", 0), eye)
            closed = layer["shape"] == "ring"
            head = ev(layer["reveal"], u) if "reveal" in layer else 1
            tail = ev(layer["erase"], u) if ("erase" in layer and layer.get("eraseMode") != "centre") else 0
            if closed:
                head, tail = 1, 0
            if head - tail < 1e-3:
                return True
            count = layer.get("segments", 16) + 1
            pos, nrm, ss = shape_points(layer, u, tail, head, count)
            width = layer["width"] * (ev(layer["widthScale"], u) if "widthScale" in layer else 1)
            alpha = ev(layer["alpha"], u)
            gap = ev(layer["erase"], u) if layer.get("eraseMode") == "centre" else 0
            for skin in layer["skins"]:
                pts, ws, als, cs = [], [], [], [] if layer.get("rainbow") else None
                for p, n, s in zip(pos, nrm, ss):
                    w = width * (1 if closed else profile(s, layer.get("taper")))
                    if not closed:
                        if head < 1:
                            w *= min(max((head - s) / 0.12, 0), 1) ** 0.6
                        if tail > 0:
                            w *= min(max((s - tail) / 0.12, 0), 1) ** 0.6
                    pts.append(cf.point(frame, p - n * skin.get("inset", 0) * w))
                    ws.append(w * skin["w"])
                    a = alpha
                    if gap > 0:
                        a *= min(max((abs(s - 0.5) - gap / 2) / 0.06, 0), 1)
                    als.append(a)
                    if cs is not None:
                        h = hue(s)
                        cs.append([h[i] * 0.75 + skin["color"][i] * 0.25 for i in range(3)])
                self.draw_chain(fr, pts, ws, als, skin, cs)
            return True
        if kind in ("glow", "sprite"):
            if age >= life:
                return False
            u = age / life
            img = sprite_img(layer["sprite"])
            f = item["frame"]
            if layer.get("frame") == "tip":
                f = self.frames(self.clip_time)["tip"]
            p = cf.pos(f) + cf.vec(f, layer.get("offset", [0, 0, 0]))
            size = ev(layer["size"], u)
            trans = ev(layer["transparency"], u)
            col = c01(ev(layer["color"], u))
            rot = item["rotation"] + layer.get("spin", 0) * age
            if layer.get("alignX"):
                rot += screen_angle(fr.cam, p, cf.right(f))
            elif layer.get("alignY"):
                rot += screen_angle(fr.cam, p, cf.up(f)) + 90
            if img is not None:
                draw_sprite(fr, img, p, size, col, (1 - trans) * bright(layer.get("brightness", 1)), rot)
            return True
        if kind == "rays":
            if age >= life:
                return False
            f = item["frame"]
            origin = np.array(layer.get("origin", [0, 0, 0]), float)
            for ray in layer["rays"]:
                u = min(max((age - ray["delay"]) / max(life - ray["delay"], 1e-3), 0), 1)
                a_, e_ = math.radians(ray["angle"]), math.radians(ray["elevation"])
                if layer.get("plane") == "XZ":
                    d = np.array([math.cos(a_) * math.cos(e_), math.sin(e_), math.sin(a_) * math.cos(e_)])
                else:
                    d = np.array([math.cos(a_) * math.cos(e_), math.sin(a_) * math.cos(e_), math.sin(e_)])
                ln = ray["length"] * ev(layer["length"], u)
                al = 0 if age < ray["delay"] else ev(layer["alpha"], u)
                p0 = cf.point(f, origin + d * ray["start"])
                p1 = cf.point(f, origin + d * (ray["start"] + ln * 0.3))
                p2 = cf.point(f, origin + d * (ray["start"] + ln))
                w = ray["width"]
                self.draw_chain(fr, [p0, p1, p2], [w * 0.5, w, 0], [al, al, al * 0.6], {"w": 1, "color": (255, 255, 255), "alpha": 1, "tex": "core", "brightness": 4})
                self.draw_chain(fr, [p0, p1, p2], [w * 1.25, w * 2.5, 0], [al, al, 0], {"w": 1, "color": layer.get("tint", layer["color"]), "alpha": 0.45, "tex": "soft", "brightness": 2})
            return True
        if kind == "wisps":
            longest = max(w["delay"] + w["life"] for w in layer["wisps"])
            if age >= longest:
                return False
            f = billboard(item["frame"], layer.get("billboard", 0), eye)
            for w in layer["wisps"]:
                tau = age - w["delay"]
                if not (0 < tau < w["life"]):
                    continue
                u = tau / w["life"]
                v = np.array(w["v"], float)
                speed = max(np.linalg.norm(v), 0.1)
                span = w["length"] / speed
                pts, ws, als = [], [], []
                for k in range(6):
                    t = max(0.0, tau - span * k / 5)
                    pts.append(cf.point(f, wisp_path(w, t)))
                    along = 1 - k / 5
                    ws.append(w["width"] * (1 - u * 0.6) * along ** 0.8 * min(1, k / 1.5 + 0.35))
                    als.append((1 - u ** 1.5) * along)
                self.draw_chain(fr, pts, ws, als, {"w": 0.3, "color": layer["color"], "alpha": 1, "tex": "core", "brightness": 2.5})
                self.draw_chain(fr, pts, ws, als, {"w": 1.0, "color": layer.get("tint", layer["color"]), "alpha": 0.35, "tex": "soft", "brightness": 1.5})
            return True
        if kind == "sparks":
            done = True
            f = item["frame"]
            o = cf.pos(f)
            drag = layer.get("drag", 0)
            for v, lf in item["parts"]:
                if age >= lf:
                    continue
                done = False
                u = age / lf
                dist = (1 - math.exp(-drag * age)) / drag if drag > 0 else age
                p = o + v * dist
                vel = v * math.exp(-drag * age)
                tail = p - vel * 0.025
                col = [layer["color"][i] + (layer.get("tint", layer["color"])[i] - layer["color"][i]) * u for i in range(3)]
                self.draw_chain(fr, [tail, p], [layer["size"] * 0.6 * (1 - u), layer["size"] * (1 - u)], [1 - u ** 2, 1 - u ** 2], {"w": 1, "color": col, "alpha": 1, "tex": "core", "brightness": 3})
            return not done
        if kind == "dust":
            if age >= 0.8:
                return False
            u = age / 0.8
            f = item["frame"]
            o = cf.pos(f)
            o = np.array([o[0], 0.4, o[2]])
            rng = random.Random(7)
            for i in range(layer["count"]):
                a = rng.uniform(0, 2 * math.pi)
                d = np.array([math.cos(a), 0.15, math.sin(a)])
                p = o + d * layer["speed"] * 0.18 * (1 - math.exp(-5 * age)) / 1
                fr.glow(p, 0.8 + 2.2 * u, (0.55, 0.53, 0.6), 0.22 * (1 - u))
            return True
        if kind == "light":
            if age >= life:
                return False
            u = age / life
            o = cf.pos(item["frame"])
            g = np.array([o[0], 0.05, o[2]])
            fr.glow(g, ev(layer["range"], u) * 0.35, c01(layer["color"]), 0.03 * ev(layer["brightness"], u))
            return True
        if kind == "risers":
            longest = max(r[4] + r[3] for r in item["risers"])
            if age >= longest:
                return False
            f = item["frame"]
            for base, height, speed, lf, delay in item["risers"]:
                tau = age - delay
                if not (0 < tau < lf):
                    continue
                u = tau / lf
                top = min(height + 6, speed * tau)
                length = height * (0.35 + 0.65 * (1 - u))
                bottom = max(0, top - length)
                a = (1 - u) ** 1.3
                p0, p1, p2 = (cf.point(f, base + np.array([0, y, 0])) for y in (bottom, (bottom + top) / 2, top))
                w = layer["width"]
                self.draw_chain(fr, [p0, p1, p2], [0, w, w * 0.2], [a * 0.5, a, a], {"w": 1, "color": layer["color"], "alpha": 1, "tex": "core", "brightness": 3})
                self.draw_chain(fr, [p0, p1, p2], [0, w * 2.5, 0], [a * 0.5, a, a], {"w": 1, "color": layer.get("tint", layer["color"]), "alpha": 0.35, "tex": "soft", "brightness": 1.5})
            return True
        if kind == "converge":
            if age >= life:
                return False
            base, tip = self.blade(self.clip_time)
            for delay, d, along in item["streaks"]:
                tau = age - delay
                lf = life * 0.55
                if not (0 <= tau < lf):
                    continue
                u = tau / lf
                target = base + (tip - base) * along
                eased = 1 - (1 - u) ** 2.2
                head = target + d * layer["radius"] * (1 - eased)
                tail = target + d * min(layer["radius"], layer["radius"] * (1 - eased) + 1.6 * (1 - u))
                a = math.sin(math.pi * u)
                w = layer["width"]
                self.draw_chain(fr, [tail, (tail + head) / 2, head], [0, w, w * 0.4], [0, a, a], {"w": 1, "color": (255, 255, 255), "alpha": 1, "tex": "core", "brightness": 2.5})
                self.draw_chain(fr, [tail, (tail + head) / 2, head], [0, w * 3, w], [0, a, a], {"w": 1, "color": layer["color"], "alpha": 0.4, "tex": "soft", "brightness": 1.5})
            return True
        return False

    # -- the projectile ---------------------------------------------------------
    def draw_projectile(self, fr, real, eye):
        p = self.projectile
        P = self.spec["projectile"]
        age = real - p["start"]
        if not p["stopped"]:
            p["travelled"] = min(P["speed"] * age, P["range"])
            if p["travelled"] >= P["range"]:
                p["stopped"], p["stopped_at"] = "range", real
                self.play_dissolve(real)
            elif self.hit is None and p["travelled"] + ev(P["sagitta"], age) >= np.linalg.norm(cf.pos(self.target_root) * [1, 0, 1]) - 3 - 0.5:
                self.on_projectile_hit(real)
        fade = 1.0
        if p["stopped"]:
            fade = 1 - (real - p["stopped_at"]) / P["fade"]
            if fade <= 0:
                self.projectile = None
                return
        grow = ev(P["grow"], age)
        chord = P["chord"] * grow
        sag = ev(P["sagitta"], age) * grow
        base = self.proj_frame()
        centre = base @ cf.new(chord / 2, 0, 0)
        frame = billboard(centre, P["billboard"], eye)
        pulse = 1 + P["pulse"][0] * math.sin(age * P["pulse"][1])
        width = P["width"] * grow * pulse
        count = P["segments"] + 1
        pos, nrm, ss = shape_points({"shape": "chord", "chord": chord, "sagitta": sag}, 0, 0, 1, count)

        def draw(skin, inset, shift, scale, amul):
            pts, ws, als = [], [], []
            for q, n, s in zip(pos, nrm, ss):
                w = width * profile(s, P["taper"]) * scale
                pts.append(cf.point(frame, q * scale - n * inset * w + np.array([0, shift, 0])))
                ws.append(w * skin["w"])
                als.append(amul * fade)
            self.draw_chain(fr, pts, ws, als, skin)

        for k in range(P["wake"]["count"], 0, -1):
            a = 1 - k / (P["wake"]["count"] + 1)
            draw({"w": 0.9 * a, "color": P["wake"]["color"], "alpha": P["wake"]["alpha"], "tex": "soft", "brightness": 1.2}, 0.3, -P["wake"]["spacing"] * k, 1 - P["wake"]["shrink"] * k, a * a)
        for skin in reversed(P["skins"]):
            draw(skin, skin.get("inset", 0), 0, 1, 1)
        for fringe in P["fringes"]:
            draw({"w": fringe["w"], "color": fringe["color"], "alpha": fringe["alpha"], "tex": "core", "brightness": 2}, 0, fringe["offset"], 1, 1)
        # groove
        now_floor = cf.pos(base) * [1, 0, 1] + [0, 0.12, 0]
        if not p["stopped"]:
            p["hist"].append((real, now_floor))
        p["hist"] = [h for h in p["hist"] if real - h[0] < P["groove"]["life"]]
        if len(p["hist"]) >= 2:
            pts = [h[1] for h in p["hist"]]
            us = [(real - h[0]) / P["groove"]["life"] for h in p["hist"]]
            self.draw_chain(fr, pts, [P["groove"]["width"] * (1 - u) * fade for u in us], [(1 - u) * fade for u in us], {"w": 1, "color": P["groove"]["color"], "alpha": 0.6, "tex": "soft", "brightness": 1.5})
            self.draw_chain(fr, pts, [P["groove"]["width"] * (1 - u) * fade for u in us], [(1 - u) * fade for u in us], {"w": 0.3, "color": (255, 255, 255), "alpha": 0.8, "tex": "core", "brightness": 2})
        fr.glow(cf.pos(centre) * [1, 0, 1] + [0, 0.05, 0], 7, c01(P["light"]["color"]), 0.08 * fade)

    def proj_frame(self):
        p = self.projectile
        o = p["origin"] + p["dir"] * p["travelled"]
        d = p["dir"]
        return cf.from_matrix(o, [0, 1, 0], d, np.cross([0, 1, 0], d))

    def proj_frames(self):
        P = self.spec["projectile"]
        base = self.proj_frame()
        centre = base @ cf.new(P["chord"] / 2, 0, 0)
        floor = cf.pos(base) * [1, 0, 1]
        d = self.projectile["dir"]
        ground = cf.from_matrix(floor, d, [0, 1, 0], np.cross(d, [0, 1, 0]))
        return {"proj": centre, "ground": ground, "root": centre}

    def on_projectile_hit(self, real):
        p = self.projectile
        p["stopped"], p["stopped_at"] = "hit", real
        self.hit = real
        frames = self.proj_frames()
        for layer in self.spec["impact"]:
            self.layers.append((real + layer["at"], layer, frames))
        self.hitstop_until = -1  # the attacker isn't frozen by a projectile hit
        self.target_vel = cf.unit(self.projectile["dir"]) * 55 + np.array([0, 18, 0])

    def play_dissolve(self, real):
        frames = self.proj_frames()
        for layer in self.spec["dissolve"]:
            self.layers.append((real + layer["at"], layer, frames))

    # -- main step ---------------------------------------------------------------
    def step(self, real, dt):
        """Advance to real time `real`."""
        t_clip_prev = self.clip_time
        if real < self.hitstop_until:
            pass  # bodies frozen, effects run on
        else:
            self.clip_time += dt
        t = self.clip_time - self.start_delay
        self.t = t
        # cast layers on the clip clock
        frames = self.frames(t)
        while self.cast_index < len(self.cast) and t >= self.cast[self.cast_index]["at"]:
            self.spawn(self.cast[self.cast_index], frames, real)
            self.cast_index += 1
        # blade sweep
        base, tip = self.blade(t)
        if self.tip_hist:
            v = tip - self.tip_hist[-1]
            if np.linalg.norm(v) > 0.05:
                self.sweep = cf.unit(v)
        self.tip_hist.append(tip)
        # hit marker
        hit_at = self.clip["markers"]["Hit"]
        if t >= hit_at and not getattr(self, "marked", False):
            self.marked = True
            if self.move == "Katana_Rush":
                contact = cf.pos(self.target_root) + np.array([0, 0.6, 0])
                contact = contact + (cf.pos(self.root(t)) - contact) * 0.4 * np.array([1, 0, 1])
                blade_dir = cf.unit(tip - base)
                cut = frame_xy(contact, self.sweep, blade_dir)
                floor = contact * [1, 0, 1]
                xg = cf.unit(cf.right(cut) * [1, 0, 1])
                ground = cf.from_matrix(floor, xg, [0, 1, 0], np.cross(xg, [0, 1, 0]))
                fr = {"cut": cut, "ground": ground, "root": cut}
                for layer in self.spec["impact"]:
                    self.layers.append((real + layer["at"], layer, fr))
                self.hit = real
                self.hitstop_until = real + HITSTOP
                self.target_vel = -cf.look(self.target_root) * 0 + cf.look(self.root(t)) * 46 + np.array([0, 10, 0])
                self.shake = min(1, self.shake + 0.0)
            else:
                root = self.root(t)
                d = cf.unit(cf.look(root) * [1, 0, 1])
                origin = cf.pos(root) * [1, 0, 1] + d * 3 + [0, self.spec["projectile"]["height"], 0]
                self.projectile = {"origin": origin, "dir": d, "start": real, "travelled": 0, "stopped": False, "hist": []}
        # timed impact layers
        rest = []
        for at, layer, fr in self.layers:
            if real >= at:
                self.spawn(layer, fr, at)
            else:
                rest.append((at, layer, fr))
        self.layers = rest
        # target knockback (after hit-stop)
        if self.hit is not None and real >= self.hitstop_until:
            pos = cf.pos(self.target_root) + self.target_vel * dt
            pos[1] = max(3.0, pos[1])
            self.target_vel = self.target_vel * math.exp(-4 * dt) + np.array([0, -60 * dt, 0])
            self.target_root = cf.at(pos) @ cf.rot(self.target_root)
        # trails / wake / ghosts history
        spec = self.spec
        on, life = False, 0.2
        for a, b, lf in spec.get("trails", []):
            if a <= t <= b:
                on, life = True, lf
        if on:
            self.trail_hist.append((real, base, tip))
        self.trail_life = life
        self.trail_hist = [h for h in self.trail_hist if real - h[0] < max(life, 0.22)]
        wake = spec.get("wake")
        if wake:
            if wake["from"] <= t <= wake["to"]:
                self.wake_hist.append((real, cf.pos(self.root(t)) + [0, wake["height"], 0]))
            self.wake_hist = [h for h in self.wake_hist if real - h[0] < wake["history"]]
        ai = spec.get("afterimages")
        if ai and ai["from"] <= t <= ai["to"] and (not self.ghosts or t - self.ghosts[-1][2] >= ai["every"]):
            self.ghosts.append((real, self.pose(t), t, self.root(t)))
        if ai:
            self.ghosts = [g for g in self.ghosts if real - g[0] < ai["life"]]
        # camera springs
        self.flash = max(0.0, self.flash - dt * 7)
        self.shake = max(0.0, self.shake - dt * 1.7)
        acc = -self.punch * 220 - self.punch_v * 18
        self.punch_v += acc * dt
        self.punch += self.punch_v * dt

    def render(self, real, cam_fn, labels=True):
        t = self.t
        cam = cam_fn(self)
        # shake
        s = self.shake ** 2
        jitter = np.array([math.sin(real * 61) , math.sin(real * 47 + 1), 0]) * 0.35 * s + self.punch * 0.12
        cam.set(cam.eye + cf.vec(cam.cf, jitter), cf.pos(cam.cf) + cf.look(cam.cf) * 10 + cf.vec(cam.cf, jitter))
        fr = render.Frame(cam)
        eye = cam.eye
        # shadows
        for r in (self.root(t), self.target_root):
            p = cf.pos(r) * [1, 0, 1] + [0, 0.02, 0]
            fr.box(cf.at(p), (2.6, 0.01, 1.6), (16, 18, 24))
        fr.rig(self.idle, self.target_root, None, palette="target")
        glow = ev(self.spec["blade"]["glow"], t) if 0 <= t <= self.clip["length"] else 0.35
        fr.rig(self.pose(t), self.root(t), self.grip, blade_glow=0)
        base, tip = self.blade(t)
        halo = ev(self.spec["blade"]["halo"], t) if 0 <= t <= self.clip["length"] else 1
        mid = base + (tip - base) * 0.55
        self.draw_chain(fr, [base, mid, tip], [0.22 * glow, 0.2 * glow, 0.06], [glow, glow, glow * 0.8], {"w": 1, "color": (255, 255, 255), "alpha": 1, "tex": "core", "brightness": 3})
        self.draw_chain(fr, [base, mid, tip], [0.9 * halo * glow, 1.0 * halo * glow, 0.3 * halo], [0.55, 0.6, 0.3], {"w": 1, "color": fxscore.LAVENDER, "alpha": 1, "tex": "soft", "brightness": 1.6})
        light = ev(self.spec["blade"]["light"], t) if 0 <= t <= self.clip["length"] else 0
        fr.glow(mid * [1, 0, 1] + [0, 0.05, 0], 4.5, c01(fxscore.LAVENDER), 0.05 * light)
        # ghosts
        ai = self.spec.get("afterimages")
        for g in self.ghosts:
            u = (real - g[0]) / ai["life"]
            a = ai["alpha"] * (1 - u) ** 1.6
            before = len(fr.polys)
            fr.rig(g[1], g[3], None, ghost=tuple(int(c * 0.9) for c in ai["color"]))
            n_ghost = sum(1 for _ in fr.polys) - before
            fr.polys[-n_ghost:] = [(d, p, c, a) for d, p, c, _ in fr.polys[-n_ghost:]]
        # trail: swept surface between consecutive blade samples
        hist = self.trail_hist
        for (r0, b0, t0), (r1, b1, t1) in zip(hist, hist[1:]):
            u = (real - r1) / max(self.trail_life, 1e-3)
            if u >= 1:
                continue
            a = (1 - u)
            edge0, edge1 = b0 + (t0 - b0) * 0.62, b1 + (t1 - b1) * 0.62
            fr_quad(fr, [b0, t0, t1, b1], c01((214, 196, 255)), 0.32 * a)
            fr_quad(fr, [edge0, t0, t1, edge1], (1, 1, 1), 0.55 * a)
        # wake
        if self.wake_hist and len(self.wake_hist) >= 2:
            wake = self.spec["wake"]
            pts = [h[1] for h in self.wake_hist][::-1]
            us = [(real - h[0]) / wake["history"] for h in self.wake_hist][::-1]
            for skin in wake["skins"]:
                self.draw_chain(fr, pts, [wake["width"] * skin["w"] * (1 - u) ** 1.2 for u in us], [1 - u for u in us], skin)
        # live layers
        self.live = [item for item in self.live if self.draw_item(fr, item, real, eye)]
        if self.projectile:
            self.draw_projectile(fr, real, eye)
        fr.screen_flash(self.flash ** 2 * 0.55, (0.93, 0.9, 1.0))
        if labels:
            mark = [m for m, mt in self.clip["markers"].items() if abs(mt - t) < 0.009]
            fr.label(f"{self.move}  t={t:5.3f} {' '.join(mark)}")
        return fr.render()


def fr_quad(fr, quad, color, alpha):
    proj = [fr.cam.project(p) for p in quad]
    if any(p is None for p in proj):
        return
    m = fr._quad_mask([(p[0], p[1]) for p in proj])
    if m is None:
        return
    x0, y0, mask = m
    fr.add[y0:y0 + mask.shape[0], x0:x0 + mask.shape[1]] += mask[..., None] * np.array(color, np.float32) * alpha


def wisp_path(w, tau):
    p = np.array(w["p"], float)
    v = np.array(w["v"], float)
    side = np.cross([0, 0, 1], v)
    side = cf.unit(side) if np.linalg.norm(side) > 1e-4 else np.array([1.0, 0, 0])
    return p + v * tau + side * (w["curl"] * tau * tau * 6)


def screen_angle(cam, p, d):
    a, b = cam.project(p), cam.project(p + d)
    if a is None or b is None:
        return 0.0
    return math.degrees(math.atan2(b[1] - a[1], b[0] - a[0]))


def draw_sprite(fr, img, p, size, color, intensity, rotation):
    q = fr.cam.project(p)
    if q is None or intensity <= 0.002:
        return
    px = int(max(2, size * fr.cam.scale_at(p)))
    if px > 2000:
        px = 2000
    im = img.resize((px, px), Image.BILINEAR).rotate(-rotation, resample=Image.BILINEAR, expand=False)
    arr = np.asarray(im, np.float32) / 255
    contrib = arr[..., :3] * arr[..., 3:4] * np.array(color, np.float32) * intensity
    x0, y0 = int(q[0] - px / 2), int(q[1] - px / 2)
    xs0, ys0 = max(0, -x0), max(0, -y0)
    xe, ye = min(px, fr.w - x0), min(px, fr.h - y0)
    if xe <= xs0 or ye <= ys0:
        return
    fr.add[y0 + ys0:y0 + ye, x0 + xs0:x0 + xe] += contrib[ys0:ye, xs0:xe]


# ---------------------------------------------------------------------------
# Cameras


def game_cam(scene):
    """The attacker's third-person view: behind and above their start,
    following a little as they dash."""
    r = cf.pos(scene.root(scene.t))
    follow = np.array([r[0], 0, r[2] * 0.75])
    eye = follow + np.array([3.5, 7.5, 14])
    target = follow + np.array([0, 2.5, -10])
    return render.Camera(eye, target, fov=70, size=SIZE)


def side_cam(scene):
    if scene.move == "Katana_Rush":
        return render.Camera((24, 6, -11), (0, 3.5, -11), fov=62, size=SIZE)
    return render.Camera((30, 9, -18), (0, 6, -16), fov=62, size=SIZE)


SIZE = (640, 360)


def run(move, cam_fn, slow=1.0, duration=None, every=1):
    grip = rig.load_grip()
    clips = anim.load_clips()
    idle = anim.idle_pose()
    scene = Scene(move, grip, clips, idle)
    length = scene.clip["length"] + scene.start_delay + (0.6 if move == "Katana_Rush" else 1.2)
    duration = duration or length
    frames = []
    dt = 1 / FPS / slow
    real = 0.0
    i = 0
    while real < duration:
        scene.step(real, dt)
        if i % every == 0:
            frames.append(scene.render(real, cam_fn))
        real += dt
        i += 1
    return frames


def save_gif(frames, path, fps):
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=int(1000 / fps), loop=0, optimize=False)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--move", default=None)
    ap.add_argument("--slow", type=float, default=1.0)
    ap.add_argument("--cam", default="both")
    ap.add_argument("--sheet", nargs=3, type=float, default=None, help="from to count (clip-relative real seconds)")
    args = ap.parse_args()
    moves = [args.move] if args.move else list(fxscore.SCORE)
    cams = {"game": game_cam, "side": side_cam}
    if args.cam != "both":
        cams = {args.cam: cams[args.cam]}
    os.makedirs(OUT, exist_ok=True)
    for move in moves:
        for cname, fn in cams.items():
            frames = run(move, fn, args.slow)
            suffix = f"_slow{int(args.slow)}" if args.slow != 1 else ""
            if args.sheet:
                a, b, n = args.sheet
                total = len(frames)
                idx = [min(total - 1, int((a + (b - a) * k / (n - 1)) * FPS * args.slow)) for k in range(int(n))]
                render.sheet([frames[k] for k in idx], 4, 0.5).save(os.path.join(OUT, f"{move}_{cname}{suffix}_sheet.png"))
            else:
                save_gif(frames, os.path.join(OUT, f"{move}_{cname}{suffix}.gif"), 30 if args.slow == 1 else 30)
            print("rendered", move, cname, len(frames))


if __name__ == "__main__":
    main()

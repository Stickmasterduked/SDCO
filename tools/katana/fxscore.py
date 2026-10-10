"""The VFX score for the katana skills: every layer's timing, shape, colour
and lifespan, as data. `python3 fxscore.py` writes
src/ReplicatedStorage/Combat/KatanaFX/KatanaFXData.luau, which KatanaFX
plays in game; preview.py plays the same data for review.

Frames (where a layer is anchored, resolved when it spawns):
  tip      blade tip; X = blade sweep direction, Y = blade direction
  root     attacker root (X right, Y up, -Z forward)
  feet     the floor under the attacker, root's yaw
  cut      impact: origin = contact, X = sweep (cut) direction, Y = outward
           (away from the attacker, the crescent's bulge), Z = X x Y
  ground   floor under the contact, X = cut direction flattened, Y = up
  release  Crescent launch point (in front of the blade, chest height),
           X = up, Y = forward
  proj     the travelling crescent: origin = chord centre, X = up (chord),
           Y = forward (bulge / travel), moves every frame

Shapes live in the frame's X-Y plane. `billboard` (0..1) turns a shape
about its X axis toward the camera so it never reads edge-on.

Time keys are (t, value) with t = 0..1 over the layer's life. Colours are
0..255 RGB. Every layer has an `at` (seconds after its trigger) and `life`.
"""
import math
import os
import random

import rig

OUT = os.path.join(rig.ROOT, "src/ReplicatedStorage/Combat/KatanaFX/KatanaFXData.luau")

WHITE = (255, 255, 255)
HOT = (255, 250, 255)
LAVENDER = (200, 176, 255)
VIOLET = (146, 104, 255)
DEEP = (98, 70, 210)
CYAN = (128, 228, 255)
PINK = (255, 150, 222)
PEACH = (255, 214, 176)

# Skins: one stroke = several polylines sharing a path. `w` scales the
# stroke's width, `inset` pulls a skin toward the arc centre by that many
# widths (so the body sits behind the white cutting edge).
EDGE = {"w": 0.16, "color": HOT, "alpha": 1.0, "tex": "core", "brightness": 3.0}
EDGE_SOFT = {"w": 0.3, "color": WHITE, "alpha": 0.42, "tex": "core", "brightness": 1.8}
BODY = {"w": 1.0, "inset": 0.42, "color": LAVENDER, "alpha": 0.42, "tex": "flow", "brightness": 1.4}
SPILL = {"w": 2.1, "inset": 0.55, "color": VIOLET, "alpha": 0.12, "tex": "soft", "brightness": 1.0}


def keys(*pairs):
    return [list(p) for p in pairs]


def fade(hold=0.0, start=1.0):
    return keys((0, start), (hold, start), (1, 0)) if hold > 0 else keys((0, start), (1, 0))


# ---------------------------------------------------------------------------
# Deterministic scatter (exported as explicit lists so game and preview match)

def rays(seed, count, base_angles, spread, length, width, elevation=8, start=(0.4, 1.4)):
    rng = random.Random(seed)
    out = []
    for i in range(count):
        a = base_angles[i % len(base_angles)] + rng.uniform(-spread, spread)
        out.append({
            "angle": round(a, 2),
            "elevation": round(rng.uniform(-elevation, elevation), 2),
            "length": round(length * rng.uniform(0.55, 1.0), 2),
            "width": round(width * rng.uniform(0.6, 1.0), 3),
            "delay": round(rng.uniform(0, 0.025), 3),
            "start": round(rng.uniform(*start), 2),
        })
    return out


def wisps(seed, count, spawn, drift, curl, length, width, life, delay=(0.0, 0.08)):
    """spawn(rng) -> frame-local point; drift(rng, p) -> velocity."""
    rng = random.Random(seed)
    out = []
    for _ in range(count):
        p = spawn(rng)
        v = drift(rng, p)
        out.append({
            "p": [round(x, 3) for x in p],
            "v": [round(x, 3) for x in v],
            "curl": round(rng.uniform(-curl, curl), 3),
            "length": round(length * rng.uniform(0.6, 1.0), 3),
            "width": round(width * rng.uniform(0.6, 1.0), 3),
            "life": round(life * rng.uniform(0.7, 1.0), 3),
            "delay": round(rng.uniform(*delay), 3),
        })
    return out


def on_arc(radius, span, mid=90.0):
    def f(rng):
        a = math.radians(mid + rng.uniform(-span / 2, span / 2))
        return (math.cos(a) * radius, math.sin(a) * radius - radius, rng.uniform(-0.4, 0.4))
    return f


# ---------------------------------------------------------------------------
# Lumen Rush (Z): forward dash into an explosive slice

RUSH_ARC = {"radius": 13.0, "span": 112}

RUSH = {
    # continuous blade energy over the clip (clip seconds -> value)
    "blade": {
        # glow strength; the halo width tightens as the energy builds
        "glow": keys((0, 0.35), (0.06, 0.45), (0.28, 1.0), (0.3, 1.25), (0.36, 1.0), (0.585, 1.1), (0.66, 1.35), (0.8, 0.9), (1.15, 0.45), (1.32, 0.35)),
        "halo": keys((0, 1.6), (0.06, 1.7), (0.28, 0.55), (0.36, 0.7), (0.585, 0.8), (0.66, 1.2), (0.9, 1.0), (1.32, 0.9)),
        "light": keys((0, 0.0), (0.06, 0.4), (0.3, 2.2), (0.36, 1.6), (0.66, 3.0), (0.9, 1.2), (1.32, 0.0)),
    },
    # Trail windows: [from, to, lifetime] in clip seconds
    "trails": [[0.585, 0.74, 0.2]],
    "afterimages": {"from": 0.39, "to": 0.6, "every": 0.055, "life": 0.18, "alpha": 0.42, "color": LAVENDER},
    "wake": {"from": 0.36, "to": 0.66, "history": 0.13, "width": 2.3, "height": 0.4,
             "skins": [EDGE_SOFT, {"w": 1.0, "color": LAVENDER, "alpha": 0.32, "tex": "flow", "brightness": 1.3}, {"w": 1.9, "color": VIOLET, "alpha": 0.1, "tex": "soft"}]},
    "cast": [
        {"type": "sound", "at": 0.04, "name": "KatanaGather", "volume": 0.45, "pitch": 1.15},
        # energy tightens: thin streaks converge onto the blade and vanish into it
        {"type": "converge", "at": 0.07, "life": 0.22, "count": 5, "radius": 4.5, "width": 0.14, "color": LAVENDER, "seed": 3},
        # the glint announcing the release
        {"type": "glow", "at": 0.29, "life": 0.17, "frame": "tip", "sprite": "star", "size": keys((0, 0.5), (0.25, 4.6), (1, 0.2)),
         "alpha": keys((0, 0.2), (0.25, 0), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)), "rotation": 0, "spin": 140, "brightness": 4},
        {"type": "glow", "at": 0.29, "life": 0.2, "frame": "tip", "sprite": "glow", "size": keys((0, 1.0), (0.3, 2.6), (1, 1.2)),
         "alpha": keys((0, 0.4), (0.3, 0.1), (1, 1)), "color": keys((0, LAVENDER), (1, VIOLET)), "brightness": 2},
        {"type": "sound", "at": 0.29, "name": "KatanaGlint", "volume": 0.4, "pitch": 1.6},
        {"type": "camera", "at": 0.29, "attacker": {"fov": -1.6}},
        # launch: a punch of air off the back foot, speed rays thrown backwards
        {"type": "stroke", "at": 0.36, "life": 0.26, "frame": "feet", "shape": "ring", "plane": "ground", "radius": keys((0, 0.8), (1, 5.5)),
         "width": 0.5, "alpha": keys((0, 0.7), (1, 0)), "skins": [EDGE_SOFT, {"w": 1.0, "color": LAVENDER, "alpha": 0.35, "tex": "soft"}], "segments": 20},
        {"type": "rays", "at": 0.36, "life": 0.2, "frame": "root", "plane": "XZ", "origin": [0, -1.2, 0.8],
         "rays": rays(11, 7, [90], 26, 6.5, 0.32, elevation=12), "length": keys((0, 0.2), (0.35, 1), (1, 1.15)), "alpha": keys((0, 0.9), (0.4, 0.7), (1, 0)), "color": WHITE, "tint": LAVENDER},
        {"type": "dust", "at": 0.36, "frame": "feet", "count": 7, "speed": 14, "spread": 70, "back": True},
        {"type": "sound", "at": 0.36, "name": "KatanaRushWind", "volume": 0.6, "pitch": 0.95},
        {"type": "camera", "at": 0.36, "attacker": {"fov": 9, "punch": [0, 0, -1, 0.35], "blur": 6}},
        # the sword rush
        {"type": "sound", "at": 0.585, "name": "KatanaSwing", "volume": 0.85, "pitch": 0.78},
        # the finishing pose: a cool shimmer down the blade, wisps peel off
        {"type": "glow", "at": 0.8, "life": 0.22, "frame": "tip", "sprite": "star", "size": keys((0, 0.4), (0.3, 2.2), (1, 0.1)),
         "alpha": keys((0, 0.4), (0.3, 0.15), (1, 1)), "color": keys((0, WHITE), (1, CYAN)), "rotation": 45, "spin": -90, "brightness": 3},
        {"type": "bladewisps", "at": 0.82, "count": 4, "life": 0.55, "seed": 7},
        {"type": "sound", "at": 0.82, "name": "KatanaTail", "volume": 0.35, "pitch": 1.2},
    ],
    # the hit: everything in the cut frame, in successive beats
    "impact": [
        # beat 0: concentrated contact flash
        {"type": "glow", "at": 0.0, "life": 0.08, "frame": "cut", "sprite": "core", "size": keys((0, 2.5), (0.3, 4.5), (1, 3)),
         "alpha": keys((0, 0), (0.35, 0.05), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)), "brightness": 6},
        {"type": "glow", "at": 0.0, "life": 0.11, "frame": "cut", "sprite": "star", "size": keys((0, 5), (0.25, 11), (1, 3)),
         "alpha": keys((0, 0), (0.3, 0.1), (1, 1)), "color": keys((0, WHITE), (1, PEACH)), "alignX": True, "brightness": 5},
        {"type": "sound", "at": 0.0, "name": "KatanaCrack", "volume": 0.9, "pitch": 1.0},
        {"type": "camera", "at": 0.0,
         "attacker": {"shake": 0.3, "punch": [1, 0, 0, 0.55], "fov": -5, "impact": 0.45, "flash": 0.22},
         "victim": {"shake": 0.55, "punch": [1, 0, 0, 0.9], "fov": 6, "impact": 0.6, "flash": 0.3, "roll": 5},
         "near": {"shake": 0.35, "radius": 55}},
        # beat 0: the razor crescent tears across
        {"type": "stroke", "at": 0.0, "life": 0.34, "frame": "cut", "shape": "arc", **RUSH_ARC, "billboard": 0.45,
         "reveal": keys((0, 0.05), (0.14, 1)), "erase": keys((0, 0), (0.45, 0), (1, 1)),
         "width": 2.6, "taper": [1.6, 0.9], "widthScale": keys((0, 0.7), (0.2, 1.0), (1, 0.55)), "radiusScale": keys((0, 0.96), (1, 1.06)),
         "alpha": keys((0, 1), (0.55, 0.85), (1, 0)), "skins": [EDGE, EDGE_SOFT, BODY], "segments": 22},
        {"type": "sprite", "at": 0.0, "life": 0.22, "frame": "cut", "sprite": "crescent", "size": keys((0, 21), (0.2, 24), (1, 26)),
         "alpha": keys((0, 0.45), (0.25, 0.4), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)), "alignY": True, "offset": [0, -5.8, 0], "brightness": 1.1},
        # beat 1: prismatic starburst (fringes split off the edge, rainbow halo)
        {"type": "stroke", "at": 0.03, "life": 0.18, "frame": "cut", "shape": "arc", **RUSH_ARC, "billboard": 0.45, "offset": [0, 0.35, 0.15],
         "width": 1.0, "taper": [1.6, 0.9], "alpha": keys((0, 0.55), (1, 0)),
         "skins": [{"w": 0.3, "color": CYAN, "alpha": 0.8, "tex": "core", "brightness": 2}], "segments": 18},
        {"type": "stroke", "at": 0.03, "life": 0.18, "frame": "cut", "shape": "arc", **RUSH_ARC, "billboard": 0.45, "offset": [0, -0.32, -0.15],
         "width": 1.0, "taper": [1.6, 0.9], "alpha": keys((0, 0.5), (1, 0)),
         "skins": [{"w": 0.3, "color": PINK, "alpha": 0.8, "tex": "core", "brightness": 2}], "segments": 18},
        {"type": "glow", "at": 0.03, "life": 0.14, "frame": "cut", "sprite": "burst", "size": keys((0, 5), (0.3, 11), (1, 12)),
         "alpha": keys((0, 0), (0.35, 0.2), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)), "rotation": 12, "spin": 40, "brightness": 4},
        {"type": "glow", "at": 0.04, "life": 0.32, "frame": "cut", "sprite": "prism", "size": keys((0, 7), (1, 15)),
         "alpha": keys((0, 0.2), (0.4, 0.45), (1, 1)), "color": keys((0, WHITE), (1, WHITE)), "brightness": 2},
        {"type": "sound", "at": 0.04, "name": "KatanaBurst", "volume": 0.85, "pitch": 0.9},
        # beat 2: broad eruption, curved energy sheets, rays along the cut
        {"type": "glow", "at": 0.06, "life": 0.34, "frame": "cut", "sprite": "glow", "size": keys((0, 8), (0.35, 15), (1, 18)),
         "alpha": keys((0, 0.72), (0.3, 0.8), (1, 1)), "color": keys((0, LAVENDER), (0.3, CYAN), (1, VIOLET)), "brightness": 1.2},
        {"type": "stroke", "at": 0.06, "life": 0.4, "frame": "cut", "shape": "arc", "radius": 15.5, "span": 96, "mid": 94, "billboard": 0.4, "offset": [0, 1.2, 1.4],
         "reveal": keys((0, 0.2), (0.2, 1)), "erase": keys((0, 0), (0.3, 0), (1, 1)), "width": 3.4, "taper": [1.3, 1.3],
         "radiusScale": keys((0, 0.9), (1, 1.22)), "widthScale": keys((0, 0.6), (0.3, 1), (1, 0.5)), "alpha": keys((0, 0.9), (1, 0)),
         "skins": [EDGE_SOFT, {"w": 1.0, "inset": 0.4, "color": CYAN, "alpha": 0.3, "tex": "flow", "brightness": 1.5}, {"w": 1.8, "inset": 0.5, "color": VIOLET, "alpha": 0.1, "tex": "soft"}], "segments": 18},
        {"type": "stroke", "at": 0.08, "life": 0.42, "frame": "cut", "shape": "arc", "radius": 14, "span": 90, "mid": 86, "billboard": 0.4, "offset": [0, 0.8, -1.4],
         "reveal": keys((0, 0.2), (0.2, 1)), "erase": keys((0, 0), (0.3, 0), (1, 1)), "width": 2.8, "taper": [1.3, 1.3],
         "radiusScale": keys((0, 0.9), (1, 1.18)), "widthScale": keys((0, 0.6), (0.3, 1), (1, 0.5)), "alpha": keys((0, 0.8), (1, 0)),
         "skins": [EDGE_SOFT, {"w": 1.0, "inset": 0.4, "color": VIOLET, "alpha": 0.3, "tex": "flow", "brightness": 1.5}], "segments": 18},
        {"type": "rays", "at": 0.05, "life": 0.24, "frame": "cut", "plane": "XY",
         "rays": rays(21, 9, [0, 180, 8, 172, -8], 7, 13, 0.4, elevation=6, start=(1.5, 3.0)),
         "length": keys((0, 0.15), (0.3, 1), (1, 1.1)), "alpha": keys((0, 1), (0.45, 0.8), (1, 0)), "color": WHITE, "tint": PEACH},
        # beat 3: shockwaves
        {"type": "stroke", "at": 0.08, "life": 0.36, "frame": "cut", "shape": "ring", "plane": "frame", "radius": keys((0, 2), (0.6, 9.5), (1, 12)), "billboard": 0.6,
         "width": 0.55, "widthScale": keys((0, 1.4), (1, 0.4)), "alpha": keys((0, 0.7), (1, 0)), "skins": [EDGE_SOFT, {"w": 1.0, "color": LAVENDER, "alpha": 0.3, "tex": "soft"}], "segments": 28},
        {"type": "stroke", "at": 0.12, "life": 0.3, "frame": "cut", "shape": "ring", "plane": "frame", "radius": keys((0, 1), (1, 8.5)), "billboard": 0.6, "rainbow": True,
         "width": 0.5, "widthScale": keys((0, 1.2), (1, 0.3)), "alpha": keys((0, 0.6), (1, 0)), "skins": [{"w": 1.0, "color": WHITE, "alpha": 0.7, "tex": "core", "brightness": 2}], "segments": 28},
        {"type": "stroke", "at": 0.1, "life": 0.42, "frame": "ground", "shape": "ring", "plane": "ground", "radius": keys((0, 1), (0.5, 8), (1, 11)),
         "width": 0.7, "widthScale": keys((0, 1.4), (1, 0.4)), "alpha": keys((0, 0.65), (1, 0)), "skins": [EDGE_SOFT, {"w": 1.0, "color": LAVENDER, "alpha": 0.3, "tex": "soft"}], "segments": 28},
        # beat 4: break-up into wisps and fading fragments, ground disturbance
        {"type": "wisps", "at": 0.1, "frame": "cut", "billboard": 0.45, "color": WHITE, "tint": LAVENDER,
         "wisps": wisps(31, 10, on_arc(13.0, 100), lambda r, p: (p[0] * 0.35 + r.uniform(-2, 2), r.uniform(2, 6), r.uniform(-2, 2)), 2.5, 3.2, 0.5, 0.55, (0.0, 0.12))},
        {"type": "sparks", "at": 0.03, "frame": "cut", "count": 16, "dir": [1, 0.15, 0], "spread": 28, "speed": [30, 70], "life": [0.25, 0.6], "size": 0.35, "drag": 6, "color": WHITE, "tint": CYAN, "sprite": "spark", "mirror": True},
        {"type": "sparks", "at": 0.06, "frame": "cut", "count": 10, "dir": [0, 1, 0], "spread": 60, "speed": [12, 30], "life": [0.4, 0.8], "size": 0.22, "drag": 4, "color": LAVENDER, "tint": PINK, "sprite": "glint"},
        {"type": "stroke", "at": 0.08, "life": 0.55, "frame": "ground", "shape": "line", "points": [[-7, 0.08, 0], [0, 0.08, 0], [7, 0.08, 0]],
         "width": 0.9, "taper": [1.0, 1.0], "alpha": keys((0, 0.9), (0.4, 0.5), (1, 0)), "widthScale": keys((0, 1), (1, 0.4)),
         "skins": [EDGE_SOFT, {"w": 1.0, "color": LAVENDER, "alpha": 0.35, "tex": "soft"}], "segments": 8, "billboard": 0},
        {"type": "dust", "at": 0.1, "frame": "ground", "count": 10, "speed": 16, "spread": 85},
        {"type": "light", "at": 0.0, "life": 0.45, "frame": "cut", "color": LAVENDER, "brightness": keys((0, 8), (0.2, 6), (1, 0)), "range": keys((0, 18), (1, 26))},
        {"type": "sound", "at": 0.2, "name": "KatanaTail", "volume": 0.55, "pitch": 0.9},
    ],
    # a whiff still cuts the air: the slash shape without the explosion
    "whiff": [
        {"type": "stroke", "at": 0.0, "life": 0.26, "frame": "cut", "shape": "arc", **RUSH_ARC, "billboard": 0.45,
         "reveal": keys((0, 0.05), (0.18, 1)), "erase": keys((0, 0), (0.4, 0), (1, 1)),
         "width": 1.8, "taper": [1.6, 0.9], "widthScale": keys((0, 0.7), (0.2, 1.0), (1, 0.5)), "alpha": keys((0, 0.85), (1, 0)),
         "skins": [EDGE, EDGE_SOFT, BODY], "segments": 20},
        {"type": "wisps", "at": 0.08, "frame": "cut", "billboard": 0.45, "color": WHITE, "tint": LAVENDER,
         "wisps": wisps(41, 5, on_arc(13.0, 96), lambda r, p: (p[0] * 0.25, r.uniform(1, 3), r.uniform(-1, 1)), 2, 2.4, 0.4, 0.45)},
    ],
}

# ---------------------------------------------------------------------------
# Moonfall Crescent (X): overhead cut that launches a huge slash

CHORD = 17.0  # the travelling crescent's height (tip to tip)

CRESCENT = {
    "blade": {
        "glow": keys((0, 0.35), (0.28, 0.6), (0.6, 1.25), (0.665, 1.35), (0.705, 1.1), (0.765, 1.4), (0.9, 0.7), (1.25, 0.4), (1.42, 0.35)),
        "halo": keys((0, 1.6), (0.28, 1.8), (0.6, 0.55), (0.705, 0.8), (0.765, 1.3), (1.0, 1.0), (1.42, 0.9)),
        "light": keys((0, 0.0), (0.28, 0.8), (0.665, 3.2), (0.765, 3.6), (1.0, 1.0), (1.42, 0.0)),
    },
    "trails": [[0.68, 0.84, 0.22]],
    "cast": [
        {"type": "dust", "at": 0.1, "frame": "feet", "count": 6, "speed": 9, "spread": 85},
        {"type": "stroke", "at": 0.1, "life": 0.28, "frame": "feet", "shape": "ring", "plane": "ground", "radius": keys((0, 1), (1, 4.5)),
         "width": 0.35, "alpha": keys((0, 0.45), (1, 0)), "skins": [EDGE_SOFT], "segments": 20},
        {"type": "sound", "at": 0.28, "name": "KatanaGather", "volume": 0.55, "pitch": 0.92},
        {"type": "converge", "at": 0.3, "life": 0.34, "count": 7, "radius": 5.5, "width": 0.15, "color": LAVENDER, "seed": 5},
        {"type": "glow", "at": 0.6, "life": 0.2, "frame": "tip", "sprite": "star", "size": keys((0, 0.5), (0.3, 5.2), (1, 0.3)),
         "alpha": keys((0, 0.2), (0.3, 0), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)), "rotation": 0, "spin": 120, "brightness": 4},
        {"type": "sound", "at": 0.6, "name": "KatanaGlint", "volume": 0.45, "pitch": 1.4},
        {"type": "camera", "at": 0.6, "attacker": {"fov": -2}},
        {"type": "sound", "at": 0.705, "name": "KatanaSwing", "volume": 0.9, "pitch": 0.7},
        # release: a hot flash where the blade lets go, a ring of displaced air
        {"type": "glow", "at": 0.765, "life": 0.12, "frame": "release", "sprite": "core", "size": keys((0, 3), (0.3, 7), (1, 3)),
         "alpha": keys((0, 0.1), (0.3, 0.05), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)), "brightness": 5},
        {"type": "glow", "at": 0.765, "life": 0.14, "frame": "release", "sprite": "streak", "size": keys((0, 6), (0.3, 16), (1, 10)),
         "alpha": keys((0, 0.2), (0.3, 0.1), (1, 1)), "color": keys((0, WHITE), (1, CYAN)), "rotation": 90, "brightness": 4},
        {"type": "stroke", "at": 0.765, "life": 0.28, "frame": "release", "shape": "ring", "plane": "frame", "radius": keys((0, 1.5), (1, 7)), "billboard": 0.35,
         "width": 0.45, "widthScale": keys((0, 1.3), (1, 0.4)), "alpha": keys((0, 0.75), (1, 0)), "skins": [EDGE_SOFT, {"w": 1.0, "color": LAVENDER, "alpha": 0.3, "tex": "soft"}], "segments": 24},
        {"type": "sound", "at": 0.765, "name": "KatanaCrack", "volume": 0.75, "pitch": 1.15},
        {"type": "sound", "at": 0.765, "name": "KatanaRushWind", "volume": 0.7, "pitch": 0.8},
        {"type": "camera", "at": 0.765, "attacker": {"shake": 0.22, "punch": [0, 0, -1, 0.5], "fov": -4, "blur": 4}},
        {"type": "bladewisps", "at": 0.9, "count": 4, "life": 0.6, "seed": 9},
        {"type": "sound", "at": 0.9, "name": "KatanaTail", "volume": 0.3, "pitch": 1.25},
    ],
    # the travelling blade of light
    "projectile": {
        "speed": 92, "range": 72, "height": 0.4,  # chord bottom this far above the floor
        "chord": CHORD,
        "grow": keys((0, 0.45), (0.12, 1.0)),  # scale over age (seconds)
        "sagitta": keys((0, 2.0), (0.25, 4.2), (0.8, 5.0)),  # bulge over age: the curve deepens as it flies
        "width": 4.6, "taper": [1.25, 1.25],
        "pulse": [0.08, 11],  # width breathing: amplitude, rad/s
        "billboard": 0.55,
        "skins": [EDGE, EDGE_SOFT,
                  {"w": 1.0, "inset": 0.45, "color": LAVENDER, "alpha": 0.4, "tex": "flow", "brightness": 1.5, "flow": 2.6},
                  {"w": 0.7, "inset": 0.75, "color": CYAN, "alpha": 0.22, "tex": "flow", "brightness": 1.3, "flow": -1.8},
                  {"w": 2.0, "inset": 0.55, "color": VIOLET, "alpha": 0.12, "tex": "soft"}],
        # prismatic fringes riding the edge
        "fringes": [{"offset": 0.28, "color": PINK, "alpha": 0.45, "w": 0.22}, {"offset": -0.3, "color": CYAN, "alpha": 0.45, "w": 0.22}],
        # wake: fading echoes of the arc left behind, tapered
        "wake": {"count": 4, "spacing": 1.7, "shrink": 0.1, "alpha": 0.55, "color": LAVENDER},
        "groove": {"life": 0.24, "width": 0.8, "color": LAVENDER},
        "light": {"color": LAVENDER, "brightness": 3, "range": 20},
        "sparkEvery": 0.03,
        "fade": 0.18,  # dissolving at the end of its range
        "segments": 22,
    },
    # hitting someone: tall splitting flash, a vertical eruption that keeps
    # going forward, ground shockwave, rising streaks
    "impact": [
        {"type": "stroke", "at": 0.0, "life": 0.16, "frame": "proj", "shape": "line", "points": [[-13, 0, 0], [0, 0, 0], [13, 0, 0]], "billboard": 1,
         "width": 1.6, "taper": [1.0, 1.0], "widthScale": keys((0, 0.4), (0.25, 1.3), (1, 0.1)), "alpha": keys((0, 1), (0.5, 0.9), (1, 0)),
         "skins": [{"w": 0.25, "color": HOT, "alpha": 1, "tex": "core", "brightness": 6}, {"w": 1.0, "color": WHITE, "alpha": 0.5, "tex": "soft", "brightness": 3}, {"w": 2.4, "color": CYAN, "alpha": 0.15, "tex": "soft"}], "segments": 6},
        {"type": "glow", "at": 0.0, "life": 0.12, "frame": "proj", "sprite": "core", "size": keys((0, 5), (0.3, 10), (1, 6)),
         "alpha": keys((0, 0), (0.35, 0.05), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)), "brightness": 6},
        {"type": "glow", "at": 0.0, "life": 0.16, "frame": "proj", "sprite": "star", "size": keys((0, 7), (0.3, 15), (1, 5)),
         "alpha": keys((0, 0), (0.3, 0.1), (1, 1)), "color": keys((0, WHITE), (1, PEACH)), "rotation": 0, "brightness": 5},
        {"type": "sound", "at": 0.0, "name": "KatanaCrack", "volume": 1.0, "pitch": 0.85},
        {"type": "camera", "at": 0.0,
         "attacker": {"shake": 0.32, "impact": 0.4, "flash": 0.18},
         "victim": {"shake": 0.7, "punch": [0, 1, 0, 1.0], "fov": 7, "impact": 0.65, "flash": 0.32, "roll": -4},
         "near": {"shake": 0.45, "radius": 70}},
        {"type": "glow", "at": 0.03, "life": 0.36, "frame": "proj", "sprite": "prism", "size": keys((0, 8), (1, 18)),
         "alpha": keys((0, 0.2), (0.4, 0.45), (1, 1)), "color": keys((0, WHITE), (1, WHITE)), "brightness": 2},
        {"type": "sound", "at": 0.04, "name": "KatanaBurst", "volume": 1.0, "pitch": 0.75},
        # the eruption: the crescent bursts forward, bigger, and splits
        {"type": "stroke", "at": 0.02, "life": 0.42, "frame": "proj", "shape": "chord", "chord": CHORD * 1.25, "sagitta": keys((0, 5), (1, 8)), "billboard": 0.55,
         "move": [0, 14, 0], "width": 5.5, "taper": [1.2, 1.2], "widthScale": keys((0, 1.1), (1, 0.4)), "alpha": keys((0, 1), (0.5, 0.7), (1, 0)),
         "erase": keys((0, 0), (0.5, 0), (1, 0.5)), "skins": [EDGE, EDGE_SOFT, BODY, SPILL], "segments": 22, "eraseMode": "centre"},
        {"type": "stroke", "at": 0.06, "life": 0.4, "frame": "proj", "shape": "chord", "chord": CHORD * 1.5, "sagitta": keys((0, 4), (1, 9)), "billboard": 0.5, "offset": [0, -1.5, 1.6],
         "move": [0, 9, 0], "width": 3.6, "taper": [1.3, 1.3], "widthScale": keys((0, 0.5), (0.3, 1), (1, 0.4)), "alpha": keys((0, 0.85), (1, 0)),
         "skins": [EDGE_SOFT, {"w": 1.0, "inset": 0.4, "color": CYAN, "alpha": 0.3, "tex": "flow", "brightness": 1.5}], "segments": 20},
        {"type": "stroke", "at": 0.09, "life": 0.42, "frame": "proj", "shape": "chord", "chord": CHORD * 1.7, "sagitta": keys((0, 4), (1, 10)), "billboard": 0.5, "offset": [0, -2.5, -1.6],
         "move": [0, 6, 0], "width": 3.0, "taper": [1.3, 1.3], "widthScale": keys((0, 0.5), (0.3, 1), (1, 0.4)), "alpha": keys((0, 0.75), (1, 0)),
         "skins": [EDGE_SOFT, {"w": 1.0, "inset": 0.4, "color": VIOLET, "alpha": 0.3, "tex": "flow", "brightness": 1.5}], "segments": 20},
        {"type": "glow", "at": 0.05, "life": 0.28, "frame": "proj", "sprite": "glow", "size": keys((0, 9), (0.35, 18), (1, 22)),
         "alpha": keys((0, 0.6), (0.3, 0.75), (1, 1)), "color": keys((0, LAVENDER), (0.3, LAVENDER), (1, DEEP)), "brightness": 1.4},
        # ground shockwave
        {"type": "stroke", "at": 0.06, "life": 0.5, "frame": "ground", "shape": "ring", "plane": "ground", "radius": keys((0, 1.5), (0.5, 12), (1, 16)),
         "width": 0.9, "widthScale": keys((0, 1.4), (1, 0.4)), "alpha": keys((0, 0.75), (1, 0)), "skins": [EDGE_SOFT, {"w": 1.0, "color": LAVENDER, "alpha": 0.32, "tex": "soft"}], "segments": 32},
        {"type": "stroke", "at": 0.12, "life": 0.42, "frame": "ground", "shape": "ring", "plane": "ground", "radius": keys((0, 1), (1, 9)), "rainbow": True,
         "width": 0.5, "widthScale": keys((0, 1.2), (1, 0.3)), "alpha": keys((0, 0.55), (1, 0)), "skins": [{"w": 1.0, "color": WHITE, "alpha": 0.7, "tex": "core", "brightness": 2}], "segments": 32},
        {"type": "dust", "at": 0.06, "frame": "ground", "count": 14, "speed": 20, "spread": 88},
        # rising energy streaks
        {"type": "risers", "at": 0.05, "frame": "ground", "count": 12, "radius": [1.0, 6.5], "height": [6, 16], "speed": [40, 80],
         "life": [0.25, 0.45], "width": 0.35, "color": WHITE, "tint": LAVENDER, "seed": 13},
        {"type": "wisps", "at": 0.12, "frame": "proj", "billboard": 0.5, "color": WHITE, "tint": LAVENDER,
         "wisps": wisps(51, 10, lambda r: (r.uniform(-CHORD / 2, CHORD / 2), r.uniform(1, 4), r.uniform(-0.6, 0.6)),
                        lambda r, p: (p[0] * 0.25 + r.uniform(0, 3), r.uniform(4, 9), r.uniform(-2, 2)), 2.5, 3.0, 0.5, 0.6, (0, 0.12))},
        {"type": "sparks", "at": 0.03, "frame": "proj", "count": 18, "dir": [0, 1, 0], "spread": 50, "speed": [30, 70], "life": [0.3, 0.7], "size": 0.35, "drag": 5, "color": WHITE, "tint": CYAN, "sprite": "spark"},
        {"type": "light", "at": 0.0, "life": 0.5, "frame": "proj", "color": LAVENDER, "brightness": keys((0, 9), (0.2, 6), (1, 0)), "range": keys((0, 22), (1, 30))},
        {"type": "sound", "at": 0.25, "name": "KatanaTail", "volume": 0.6, "pitch": 0.8},
    ],
    # out of range (or into a wall): the blade of light comes apart
    "dissolve": [
        {"type": "wisps", "at": 0.0, "frame": "proj", "billboard": 0.5, "color": WHITE, "tint": LAVENDER,
         "wisps": wisps(61, 8, lambda r: (r.uniform(-CHORD / 2, CHORD / 2), r.uniform(2, 4.5), 0),
                        lambda r, p: (p[0] * 0.15, r.uniform(6, 14), r.uniform(-1.5, 1.5)), 1.5, 3.0, 0.45, 0.5, (0, 0.1))},
        {"type": "sound", "at": 0.0, "name": "KatanaTail", "volume": 0.35, "pitch": 1.1},
    ],
}

SCORE = {"Katana_Rush": RUSH, "Katana_Crescent": CRESCENT}


def _normalise():
    """Sprite layers fade by transparency (like ParticleEmitter); strokes by alpha."""
    for spec in SCORE.values():
        for key in ("cast", "impact", "whiff", "dissolve"):
            for layer in spec.get(key, []):
                if layer["type"] in ("glow", "sprite") and "alpha" in layer:
                    layer["transparency"] = layer.pop("alpha")


_normalise()


# ---------------------------------------------------------------------------
# Luau export


def lua(v, indent=0):
    pad = "\t" * indent
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return "%g" % round(v, 4)
    if isinstance(v, str):
        return '"' + v + '"'
    if isinstance(v, (list, tuple)):
        flat = all(not isinstance(x, (dict, list, tuple)) for x in v)
        if flat:
            return "{ " + ", ".join(lua(x) for x in v) + " }"
        inner = ",\n".join(pad + "\t" + lua(x, indent + 1) for x in v)
        return "{\n" + inner + ",\n" + pad + "}"
    if isinstance(v, dict):
        items = []
        for k, x in v.items():
            key = k if k.isidentifier() else '["' + k + '"]'
            items.append(pad + "\t" + key + " = " + lua(x, indent + 1))
        return "{\n" + ",\n".join(items) + ",\n" + pad + "}"
    raise TypeError(type(v))


def write():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("-- Generated by tools/katana/fxscore.py: the katana skills' VFX score.\n")
        f.write("-- Edit the score there (it also drives the previews), not this file.\n")
        f.write("return " + lua(SCORE) + "\n")


if __name__ == "__main__":
    write()
    print("wrote", OUT)

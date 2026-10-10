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
# Particle looks (every effect is real sprites: flipbook explosions, smoke,
# slash flashes, flat shockwaves, sparks; no thin lines)

SMOKE_COLOR = keys((0, (232, 226, 255)), (0.5, (176, 160, 230)), (1, (110, 96, 160)))


def burst(at, frame, sprite, **kw):
    layer = {"type": "burst", "at": at, "frame": frame, "sprite": sprite}
    layer.update(kw)
    return layer


EXPLO_COLOR = keys((0, (236, 228, 255)), (0.35, (196, 172, 255)), (0.7, (140, 120, 240)), (1, (110, 200, 255)))


def explo(at, frame, size, offset=(0, 0, 0), count=1, life=(0.5, 0.65), bright=1.9, color=EXPLO_COLOR):
    return burst(at, frame, "explosion", flip="4x4", count=count, life=list(life), offset=list(offset),
                 size=keys((0, size * 0.45), (0.5, size * 0.9), (1, size)), transparency=keys((0, 0.12), (0.75, 0.25), (1, 1)),
                 color=color, rotation=[0, 360], brightness=bright, zoffset=1)


def smoke(at, frame, count, size, speed=(6, 16), spread=70, dirv=(0, 1, 0), offset=(0, 0, 0), radius=None, life=(0.8, 1.3)):
    kw = dict(flip="4x4", count=count, life=list(life), offset=list(offset), dir=list(dirv), speed=list(speed), spread=spread,
              drag=3, accel=[0, 3, 0], size=keys((0, size * 0.35), (1, size)), transparency=keys((0, 0.3), (0.6, 0.55), (1, 1)),
              color=SMOKE_COLOR, rotation=[0, 360], spin=[-40, 40], emission=0.45, brightness=1.4)
    if radius:
        kw["radius"] = radius
    return burst(at, frame, "smoke", **kw)


def shock_flat(at, frame, size, life=0.42, offset=(0, 0.25, 0), color=WHITE, bright=3):
    return burst(at, frame, "shock", count=1, life=life, offset=list(offset), worldUp=True, speed=0.01, orientation="flat",
                 size=keys((0, size * 0.08), (0.4, size * 0.75), (1, size)), transparency=keys((0, 0), (0.5, 0.2), (1, 1)),
                 color=color, rotation=[0, 360], brightness=bright)


def shock_cam(at, frame, size, life=0.32, color=LAVENDER, bright=2):
    return burst(at, frame, "shock", count=1, life=life, size=keys((0, size * 0.1), (0.5, size * 0.8), (1, size)),
                 transparency=keys((0, 0.45), (0.5, 0.65), (1, 1)), color=color, rotation=[0, 360], brightness=bright, zoffset=1)


def sparks(at, frame, count, speed=(40, 100), dirv=(0, 1, 0), spread=180, size=0.45, life=(0.3, 0.7), tint=CYAN, radius=None, mirror=False):
    kw = dict(count=count, life=list(life), speed=list(speed), dir=list(dirv), spread=spread, drag=4, orientation="velocity",
              size=keys((0, size), (0.7, size * 0.7), (1, 0)), transparency=keys((0, 0), (0.7, 0.2), (1, 1)),
              color=keys((0, WHITE), (1, tint)), squash=-1.4, brightness=4)
    if radius:
        kw["radius"] = radius
    return burst(at, frame, "spark", **kw)


def embers(at, frame, count, spread_r=4, life=(0.8, 1.4), tint=LAVENDER):
    return burst(at, frame, "glint", count=count, life=list(life), radius=spread_r, speed=[3, 9], spread=180, drag=2, accel=[0, 6, 0],
                 size=keys((0, 0.2), (0.3, 0.7), (1, 0)), transparency=keys((0, 0), (0.8, 0.2), (1, 1)),
                 color=keys((0, WHITE), (1, tint)), rotation=[0, 360], spin=[-200, 200], brightness=3)


def flash(at, frame, sprite, size, life=0.14, color=WHITE, tint=LAVENDER, rotation=0, bright=5, **kw):
    layer = {"type": "glow", "at": at, "life": life, "frame": frame, "sprite": sprite,
             "size": keys((0, size * 0.4), (0.3, size), (1, size * 0.5)), "transparency": keys((0, 0), (0.35, 0.05), (1, 1)),
             "color": keys((0, color), (1, tint)), "rotation": rotation, "brightness": bright}
    layer.update(kw)
    return layer


def inward(at, frame, count, radius, size=1.6, life=(0.3, 0.45), offset=(0, 0, 0)):
    """Energy pulled in from all around (a charge-up)."""
    return burst(at, frame, "energy", count=count, life=list(life), radius=radius, inward=True, surface=True, speed=[radius * 2.2, radius * 3],
                 offset=list(offset), size=keys((0, size * 0.3), (0.5, size), (1, size * 0.2)), transparency=keys((0, 0.6), (0.5, 0.1), (1, 1)),
                 color=keys((0, LAVENDER), (1, WHITE)), rotation=[0, 360], spin=[-180, 180], brightness=2.5)


def shake(at, attacker=None, victim=None, near=None, radius=90):
    layer = {"type": "camera", "at": at}
    if attacker:
        layer["attacker"] = attacker
    if victim:
        layer["victim"] = victim
    if near:
        layer["near"] = dict(near, radius=radius)
    return layer


def sound(at, name, volume=0.8, pitch=1.0):
    return {"type": "sound", "at": at, "name": name, "volume": volume, "pitch": pitch}


def light(at, frame, life, bright, rng):
    return {"type": "light", "at": at, "life": life, "frame": frame, "color": LAVENDER,
            "brightness": keys((0, bright), (0.25, bright * 0.7), (1, 0)), "range": keys((0, rng), (1, rng * 1.4))}


# blade aura while charging (pours from the blade)
def aura(start, stop, rate=45):
    return {"attach": "tip", "from": start, "to": stop, "sprite": "energy", "rate": rate, "life": [0.25, 0.4], "speed": [1, 3],
            "spread": 180, "size": keys((0, 1.6), (1, 0)), "transparency": keys((0, 0.35), (1, 1)),
            "color": keys((0, WHITE), (1, LAVENDER)), "rotation": [0, 360], "spin": [-120, 120], "brightness": 2.5}


# ---------------------------------------------------------------------------
# Lumen Rush (Z): a bent dash THROUGH them, a flurry of cuts, then it blows

RUSH_ARC = {"radius": 14.0, "span": 112}
THICK_EDGE = {"w": 0.22, "color": HOT, "alpha": 1.0, "tex": "core", "brightness": 3.5}

RUSH = {
    "blade": {
        "glow": keys((0, 0.35), (0.06, 0.6), (0.28, 1.3), (0.3, 1.6), (0.36, 1.2), (0.585, 1.4), (0.66, 1.7), (0.8, 1.0), (1.15, 0.45), (1.32, 0.35)),
        "halo": keys((0, 1.6), (0.06, 1.9), (0.28, 0.7), (0.36, 0.9), (0.585, 1.0), (0.66, 1.5), (0.9, 1.1), (1.32, 0.9)),
        "light": keys((0, 0.0), (0.06, 0.8), (0.3, 3.0), (0.36, 2.2), (0.66, 4.0), (0.9, 1.4), (1.32, 0.0)),
    },
    "trails": [[0.585, 0.74, 0.22]],
    "afterimages": {"from": 0.38, "to": 0.62, "every": 0.04, "life": 0.22, "alpha": 0.5, "color": LAVENDER},
    "emitters": [
        aura(0.04, 0.36),
        # the dash pours smoke and embers off the body
        {"attach": "root", "offset": [0, -1.5, 0.5], "dir": [0, 0.4, 1], "from": 0.36, "to": 0.64, "sprite": "smoke", "flip": "4x4",
         "rate": 110, "life": [0.45, 0.8], "speed": [4, 12], "spread": 45, "drag": 3, "size": keys((0, 2.5), (1, 7)),
         "transparency": keys((0, 0.35), (1, 1)), "color": SMOKE_COLOR, "rotation": [0, 360], "spin": [-60, 60], "emission": 0.5, "brightness": 1.5},
        {"attach": "root", "offset": [0, 0, 0.5], "dir": [0, 0.2, 1], "from": 0.36, "to": 0.66, "sprite": "glint",
         "rate": 90, "life": [0.3, 0.6], "speed": [6, 18], "spread": 60, "drag": 3, "size": keys((0, 0.6), (1, 0)),
         "transparency": keys((0, 0), (1, 1)), "color": keys((0, WHITE), (1, CYAN)), "rotation": [0, 360], "spin": [-200, 200], "brightness": 3},
    ],
    "cast": [
        sound(0.04, "KatanaGather", 0.55, 1.15),
        inward(0.06, "tip", 16, 6),
        inward(0.18, "tip", 12, 4.5),
        flash(0.29, "tip", "star", 7, life=0.18, spin=160),
        flash(0.3, "tip", "spike", 4.5, life=0.16, rotation=20),
        sound(0.29, "KatanaGlint", 0.5, 1.6),
        shake(0.29, attacker={"fov": -2.5, "shake": 0.1}),
        # launch: the floor blows out behind the feet
        explo(0.36, "feet", 9, offset=(0, 0.5, 1.5)),
        smoke(0.36, "feet", 12, 9, speed=(10, 26), spread=60, dirv=(0, 0.5, 1)),
        shock_flat(0.36, "feet", 16, life=0.35),
        sparks(0.36, "feet", 18, speed=(30, 70), dirv=(0, 0.6, 1), spread=50),
        sound(0.36, "KatanaRushWind", 0.8, 0.9),
        sound(0.36, "KatanaBurst", 0.5, 1.3),
        shake(0.36, attacker={"fov": 11, "punch": [0, 0, -1, 0.5], "blur": 8, "shake": 0.35}, near={"shake": 0.25}, radius=40),
        sound(0.585, "KatanaSwing", 1.0, 0.75),
        # finish: a puff where the feet skid to a stop, a cold glint down the blade
        smoke(0.66, "feet", 8, 7, speed=(6, 14), spread=80),
        flash(0.8, "tip", "star", 4, life=0.22, rotation=45, spin=-120, bright=3),
        sound(0.82, "KatanaTail", 0.4, 1.2),
    ],
    "impact": [
        # the cut lands: flash, the big crescent, the first slash
        flash(0.0, "cut", "core", 12, life=0.09, bright=6),
        flash(0.0, "cut", "star", 34, life=0.13, tint=PEACH, alignX=True),
        flash(0.0, "cut", "spike", 26, life=0.16, rotation=15, spin=90),
        sound(0.0, "KatanaCrack", 1.0, 1.0),
        sound(0.0, "KatanaBurst", 0.9, 1.1),
        shake(0.0, attacker={"shake": 0.55, "punch": [1, 0, 0, 0.8], "fov": -7, "impact": 0.6, "flash": 0.25, "blur": 6},
              victim={"shake": 0.85, "punch": [1, 0, 0, 1.2], "fov": 9, "impact": 0.7, "flash": 0.35, "roll": 7},
              near={"shake": 0.5}, radius=70),
        {"type": "stroke", "at": 0.0, "life": 0.36, "frame": "cut", "shape": "arc", **RUSH_ARC, "billboard": 0.45,
         "reveal": keys((0, 0.05), (0.12, 1)), "erase": keys((0, 0), (0.45, 0), (1, 1)),
         "width": 5.0, "taper": [1.4, 0.9], "widthScale": keys((0, 0.7), (0.2, 1.0), (1, 0.6)), "radiusScale": keys((0, 0.96), (1, 1.08)),
         "alpha": keys((0, 1), (0.55, 0.85), (1, 0)), "skins": [THICK_EDGE, EDGE_SOFT, BODY, SPILL], "segments": 24},
        {"type": "sprite", "at": 0.0, "life": 0.26, "frame": "cut", "sprite": "crescent", "size": keys((0, 26), (0.2, 30), (1, 34)),
         "alpha": keys((0, 0.2), (0.3, 0.15), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)), "alignY": True, "offset": [0, -7, 0], "brightness": 2},
        # the flurry: the cuts keep landing
        {"type": "flurry", "at": 0.03, "frame": "cut", "count": 9, "every": 0.04, "sprite": "slash", "size": [13, 24], "life": 0.22,
         "spread": 2.6, "sparks": 8, "shake": 0.22, "brightness": 3.5, "tint": CYAN},
        # the eruption
        explo(0.03, "cut", 22),
        explo(0.07, "cut", 14, offset=(-7, 1, 0)),
        explo(0.1, "cut", 14, offset=(7, -1, 0)),
        flash(0.04, "cut", "burst", 34, life=0.2, rotation=12, spin=50, bright=4),
        flash(0.05, "cut", "prism", 30, life=0.4, bright=2.4),
        shock_cam(0.05, "cut", 30, life=0.3),
        shock_flat(0.06, "ground", 44, life=0.5),
        shock_flat(0.14, "ground", 28, life=0.4, color=CYAN),
        sparks(0.04, "cut", 50, speed=(50, 130), dirv=(1, 0.15, 0), spread=35, mirror=True),
        sparks(0.07, "cut", 30, speed=(30, 80), radius=2),
        embers(0.08, "cut", 30, 5),
        smoke(0.08, "cut", 16, 13, speed=(8, 22), spread=180, radius=3),
        smoke(0.1, "ground", 14, 11, speed=(10, 24), spread=85),
        light(0.0, "cut", 0.6, 12, 26),
        # the finisher pop when the flurry ends: everything blows outward
        explo(0.4, "cut", 28, life=(0.55, 0.7)),
        flash(0.4, "cut", "spike", 36, life=0.18, rotation=-10, spin=-80),
        flash(0.4, "cut", "core", 14, life=0.1, bright=6),
        shock_cam(0.41, "cut", 36, life=0.36),
        shock_flat(0.42, "ground", 60, life=0.6),
        sparks(0.41, "cut", 60, speed=(60, 150), radius=2),
        smoke(0.43, "ground", 18, 16, speed=(14, 30), spread=85),
        embers(0.45, "cut", 40, 7),
        light(0.4, "cut", 0.6, 14, 34),
        sound(0.4, "KatanaBurst", 1.0, 0.7),
        sound(0.4, "KatanaCrack", 0.9, 0.8),
        shake(0.4, attacker={"shake": 0.8, "fov": -5, "impact": 0.5, "flash": 0.2},
              victim={"shake": 0.95, "punch": [0, 1, 0, 1.3], "fov": 10, "impact": 0.6, "flash": 0.3},
              near={"shake": 0.65}, radius=90),
        sound(0.7, "KatanaTail", 0.6, 0.85),
    ],
    # a whiff still slashes the air
    "whiff": [
        {"type": "stroke", "at": 0.0, "life": 0.26, "frame": "cut", "shape": "arc", **RUSH_ARC, "billboard": 0.45,
         "reveal": keys((0, 0.05), (0.16, 1)), "erase": keys((0, 0), (0.4, 0), (1, 1)),
         "width": 3.2, "taper": [1.4, 0.9], "widthScale": keys((0, 0.7), (0.2, 1.0), (1, 0.5)), "alpha": keys((0, 0.9), (1, 0)),
         "skins": [THICK_EDGE, EDGE_SOFT, BODY], "segments": 22},
        burst(0.0, "cut", "slash", flip="4x4", count=2, life=0.22, size=keys((0, 16), (1, 22)), transparency=keys((0, 0), (1, 1)), rotation=[-20, 20], alignX=True, brightness=3),
        smoke(0.05, "cut", 8, 9, speed=(6, 14), spread=180, radius=2),
        sparks(0.02, "cut", 20, speed=(40, 90), dirv=(1, 0, 0), spread=30, mirror=True),
    ],
}

# ---------------------------------------------------------------------------
# Moonfall Crescent (X): a grounded cross slash, two crescents, both blow up

CHORD = 17.0


def explosion(k=1.0, victim=True):
    """The crescent detonating: flash, a ball of fire-light, satellites,
    rings across the floor, a smoke column, sparks, secondary pops."""
    layers = [
        flash(0.0, "proj", "streak", 44 * k, life=0.16, rotation=90, tint=CYAN),
        flash(0.0, "proj", "core", 16 * k, life=0.11, bright=6),
        flash(0.0, "proj", "star", 38 * k, life=0.16, tint=PEACH),
        flash(0.01, "proj", "spike", 34 * k, life=0.18, rotation=8, spin=70),
        sound(0.0, "KatanaCrack", 1.0, 0.8),
        sound(0.0, "KatanaBurst", 1.0, 0.6),
        explo(0.02, "proj", 30 * k, life=(0.6, 0.75)),
        explo(0.05, "proj", 16 * k, offset=(6 * k, 4 * k, 0)),
        explo(0.07, "proj", 16 * k, offset=(-5 * k, 5 * k, 2)),
        explo(0.09, "proj", 15 * k, offset=(2 * k, -3, -3)),
        explo(0.08, "ground", 22 * k, offset=(0, 2, 0)),
        flash(0.03, "proj", "burst", 42 * k, life=0.22, rotation=8, spin=50, bright=4),
        flash(0.04, "proj", "prism", 40 * k, life=0.45, bright=2.4),
        {"type": "stroke", "at": 0.02, "life": 0.42, "frame": "proj", "shape": "chord", "chord": CHORD * 1.3 * k, "sagitta": keys((0, 5 * k), (1, 9 * k)), "billboard": 0.55,
         "move": [0, 16 * k, 0], "width": 7 * k, "taper": [1.2, 1.2], "widthScale": keys((0, 1.1), (1, 0.4)), "alpha": keys((0, 1), (0.5, 0.7), (1, 0)),
         "erase": keys((0, 0), (0.45, 0), (1, 0.6)), "skins": [THICK_EDGE, EDGE_SOFT, BODY, SPILL], "segments": 22, "eraseMode": "centre"},
        shock_flat(0.05, "ground", 70 * k, life=0.6),
        shock_flat(0.12, "ground", 46 * k, life=0.5, color=CYAN),
        shock_flat(0.2, "ground", 30 * k, life=0.4, color=PINK),
        shock_cam(0.05, "proj", 40 * k, life=0.36),
        smoke(0.06, "ground", int(20 * k) + 4, 18 * k, speed=(16, 34), spread=88),
        smoke(0.08, "proj", int(16 * k) + 4, 16 * k, speed=(8, 24), spread=180, radius=4 * k),
        smoke(0.1, "ground", int(12 * k) + 2, 14 * k, speed=(20, 40), spread=12, life=(1.0, 1.6)),  # the column
        sparks(0.03, "proj", int(70 * k), speed=(60, 150), radius=2.5),
        sparks(0.06, "ground", int(40 * k), speed=(30, 90), spread=70, tint=PINK),
        embers(0.1, "proj", int(40 * k), 8 * k),
        light(0.0, "proj", 0.8, 14, 34 * k),
        # secondary pops as it burns out
        explo(0.18, "proj", 14 * k, offset=(4, -2, 3)),
        explo(0.25, "proj", 14 * k, offset=(-5, 3, -2)),
        explo(0.32, "ground", 16 * k, offset=(3, 1.5, 3)),
        sound(0.18, "KatanaBurst", 0.6, 1.2),
        sound(0.35, "KatanaTail", 0.7, 0.75),
        shake(0.0, attacker={"shake": 0.85 * k, "fov": -5, "impact": 0.5 * k, "flash": 0.25 * k},
              victim={"shake": 1.0, "punch": [0, 1, 0, 1.4], "fov": 11, "impact": 0.75, "flash": 0.4, "roll": -7} if victim else None,
              near={"shake": 0.9 * k}, radius=130),
        shake(0.18, attacker={"shake": 0.4 * k}, near={"shake": 0.45 * k}, radius=110),
    ]
    return layers


def release(at, scale):
    """The blade striking the floor as a crescent leaves."""
    return [
        flash(at, "release", "core", 10 * scale, life=0.12, bright=6),
        flash(at, "release", "streak", 26 * scale, life=0.16, rotation=90, tint=CYAN),
        flash(at, "release", "spike", 16 * scale, life=0.15, rotation=25),
        explo(at, "feet", 12 * scale, offset=(0, 0.5, -3.5)),
        shock_flat(at, "feet", 22 * scale, life=0.4, offset=(0, 0.25, -3)),
        smoke(at + 0.01, "feet", 12, 10 * scale, speed=(12, 28), spread=60, dirv=(0, 0.5, -1), offset=(0, 0.3, -3)),
        sparks(at, "release", 26, speed=(40, 100), dirv=(0, 0.4, -1), spread=55),
        light(at, "release", 0.4, 9, 22),
        sound(at, "KatanaCrack", 0.95, 1.05),
        sound(at, "KatanaBurst", 0.75, 1.15),
        sound(at, "KatanaRushWind", 0.7, 0.8),
        shake(at, attacker={"shake": 0.6 * scale, "punch": [0, -0.3, -1, 0.8], "fov": -6, "impact": 0.35, "blur": 6}, near={"shake": 0.45}, radius=50),
    ]


CRESCENT = {
    "blade": {
        "glow": keys((0, 0.35), (0.08, 0.6), (0.2, 0.9), (0.36, 1.6), (0.44, 1.4), (0.52, 1.8), (0.6, 1.3), (0.68, 1.8), (0.85, 0.9), (1.2, 0.4), (1.32, 0.35)),
        "halo": keys((0, 1.6), (0.2, 2.0), (0.36, 0.6), (0.44, 0.9), (0.52, 1.6), (0.68, 1.6), (0.95, 1.1), (1.32, 0.9)),
        "light": keys((0, 0.0), (0.2, 1.4), (0.36, 4.0), (0.52, 5.0), (0.68, 5.0), (0.95, 1.4), (1.32, 0.0)),
    },
    "trails": [[0.42, 0.78, 0.24]],
    "emitters": [aura(0.18, 0.46, 60)],
    "cast": [
        # sink: weight slams into the floor
        smoke(0.08, "feet", 10, 8, speed=(8, 18), spread=85),
        shock_flat(0.08, "feet", 12, life=0.3),
        sound(0.08, "KatanaGather", 0.65, 0.85),
        shake(0.08, attacker={"shake": 0.15}),
        # the charge overhead: energy dragged in from all around
        inward(0.2, "tip", 20, 7),
        inward(0.2, "feet", 18, 8, size=2.4, offset=(0, 1, 0)),
        inward(0.3, "tip", 14, 5),
        flash(0.34, "tip", "prism", 8, life=0.2, bright=2),
        flash(0.36, "tip", "star", 9, life=0.2, spin=160),
        flash(0.36, "tip", "spike", 6, life=0.18, rotation=20),
        sound(0.35, "KatanaGlint", 0.65, 1.3),
        shake(0.35, attacker={"fov": -3, "shake": 0.15}),
        sound(0.44, "KatanaSwing", 1.0, 0.65),
        *release(0.52, 1.0),
        sound(0.6, "KatanaSwing", 1.0, 0.8),
        *release(0.68, 1.25),
        smoke(0.86, "feet", 8, 8, speed=(6, 12), spread=85),
        flash(0.9, "tip", "star", 4, life=0.22, rotation=45, spin=-120, bright=3),
        sound(0.9, "KatanaTail", 0.4, 1.2),
    ],
    "projectile": {
        "speed": 92, "range": 72, "height": 0.4,
        "chord": CHORD,
        "grow": keys((0, 0.5), (0.1, 1.0)),
        "sagitta": keys((0, 2.4), (0.25, 4.8), (0.8, 5.8)),
        "width": 6.0, "taper": [1.2, 1.2],
        "pulse": [0.12, 15],
        "billboard": 0.55,
        "skins": [THICK_EDGE, EDGE_SOFT,
                  {"w": 1.0, "inset": 0.45, "color": LAVENDER, "alpha": 0.5, "tex": "flow", "brightness": 1.8, "flow": 2.6},
                  {"w": 0.7, "inset": 0.75, "color": CYAN, "alpha": 0.3, "tex": "flow", "brightness": 1.5, "flow": -1.8},
                  {"w": 2.4, "inset": 0.55, "color": VIOLET, "alpha": 0.16, "tex": "soft"}],
        "light": {"color": LAVENDER, "brightness": 5, "range": 26},
        # pouring off it in flight
        "emitters": [
            {"sprite": "smoke", "flip": "4x4", "rate": 140, "life": [0.5, 0.9], "speed": [3, 10], "spread": 180, "drag": 3,
             "size": keys((0, 4), (1, 11)), "transparency": keys((0, 0.4), (1, 1)), "color": SMOKE_COLOR, "rotation": [0, 360],
             "spin": [-60, 60], "emission": 0.55, "brightness": 1.6},
            {"sprite": "energy", "rate": 50, "life": [0.25, 0.45], "speed": [2, 6], "spread": 180,
             "size": keys((0, 7), (1, 2)), "transparency": keys((0, 0.45), (1, 1)), "color": keys((0, WHITE), (1, LAVENDER)),
             "rotation": [0, 360], "spin": [-90, 90], "brightness": 2.5},
            {"sprite": "glint", "rate": 90, "life": [0.4, 0.8], "speed": [6, 16], "spread": 180, "drag": 2, "accel": [0, 5, 0],
             "size": keys((0, 0.8), (1, 0)), "transparency": keys((0, 0), (1, 1)), "color": keys((0, WHITE), (1, CYAN)),
             "rotation": [0, 360], "spin": [-200, 200], "brightness": 3},
            {"sprite": "spark", "rate": 70, "life": [0.25, 0.5], "speed": [20, 50], "spread": 180, "drag": 4, "orientation": "velocity",
             "size": keys((0, 0.45), (1, 0)), "transparency": keys((0, 0), (1, 1)), "color": keys((0, WHITE), (1, PINK)), "squash": -1.3, "brightness": 4},
        ],
        # on a hit it keeps driving through them, then detonates
        "carry": {"time": 0.22, "speed": 0.45},
        "fade": 0.16,
        "segments": 24,
    },
    "impact": explosion(1.0, True),
    "dissolve": explosion(0.65, False),
}

SCORE = {"Katana_Rush": RUSH, "Katana_Crescent": CRESCENT}


def _normalise():
    """Sprite layers fade by transparency (like ParticleEmitter); strokes by alpha."""
    for spec in SCORE.values():
        lists = [spec.get(key, []) for key in ("cast", "impact", "whiff", "dissolve")]
        trail = spec.get("projectile", {}).get("trail")
        if trail:
            lists.append(trail["layers"])
        for layers in lists:
            for layer in layers:
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

"""Void Wings geometry, shared by the texture renderer, the offline rig preview
and the generated Luau data module, so the three always agree.

Coordinates
-----------
Feather frame ("display units"): the feather's centreline runs from its base
at y=0 to its tip near y=1; x is across. The frame rectangle FRAME_X x
FRAME_Y is what one sprite-sheet cell covers, and it is mapped 1:1 onto the
feather Part (width FRAME_W * L, height FRAME_H * L studs for a feather of
length L).

The *right* wing's image is drawn as seen from behind the character (the
Part's Back face): image right is the Part's +X. Its tip curls toward image
left (-X), which after the wing's roll points up and in, giving the crescent.
The left wing uses the per-frame mirror image, so the two wings are true
mirror images instead of the same fan rotated (the old pinwheel).

Rig (torso space, R6 Torso is 2 x 2 x 1, back face at z = +0.5, character's
right is +X): each wing hangs off WING_ROOT (x mirrored per side). Feathers
sit along an arc in the wing's plane and fan from near-vertical (inner) to
near-horizontal (outer). The plane is swept back and tilted back so the
wings have depth instead of reading as a flat disc.
"""
import math

# --- feather frame --------------------------------------------------------
FRAME_X = (-0.16, 0.16)
FRAME_Y = (-0.04, 1.04)
FRAME_W = FRAME_X[1] - FRAME_X[0]
FRAME_H = FRAME_Y[1] - FRAME_Y[0]

# Cubic Bezier centreline (display units), base -> tip. The tip curls left.
CENTRELINE = ((0.045, 0.0), (0.06, 0.36), (0.035, 0.74), (-0.085, 0.975))
HALF_WIDTH = 0.054  # widest half-width, about a third of the way up
BASE_HALF_WIDTH = 0.006  # thin base

# Base point as a fraction of the cell (u from the left, v from the top), for
# the right wing's (unmirrored) image.
BASE_U = (CENTRELINE[0][0] - FRAME_X[0]) / FRAME_W
BASE_V = (FRAME_Y[1] - CENTRELINE[0][1]) / FRAME_H

# --- sprite sheet -----------------------------------------------------------
CELL = 512  # px per frame
GRID = 2  # 2 x 2 frames per atlas
ATLASES = 4  # 4 atlases x 4 = 16 loop frames
FRAMES = GRID * GRID * ATLASES
FPS = 14

# --- rig ----------------------------------------------------------------------
WING_ROOT = (0.22, 0.42, 0.56)  # right wing; x is mirrored for the left
SWEEP_DEG = 15  # outer end of each wing swept back
TILT_DEG = 14  # wing plane leans back (tips behind the shoulders)
SCALE = 1.0


def _main_feathers():
    out = []
    n = 6
    lengths = (3.0, 3.6, 4.1, 4.4, 4.3, 3.8)
    for i in range(n):
        s = i / (n - 1)
        out.append({
            "base": (0.08 + 1.55 * s, 0.1 + 0.95 * math.sin(s * math.pi * 0.5)),
            "angle": 24 + 72 * s,  # degrees from straight up, toward the outside
            "length": lengths[i],
            "depth": 0.035 * i,  # outer feathers sit a touch further back
            "frame": (i * 5) % FRAMES,
            "phase": i * 0.55,  # flutter ripple travels outward
            "flutter": 2.2 + 0.5 * s,
        })
    return out


FEATHERS = _main_feathers() + [
    # two short under-feathers curling down by the hips
    {"base": (0.08, -0.78), "angle": 148, "length": 1.85, "depth": 0.02,
     "frame": 3, "phase": 3.6, "flutter": 3.2},
    {"base": (0.2, -0.95), "angle": 163, "length": 1.45, "depth": 0.05,
     "frame": 11, "phase": 4.2, "flutter": 3.6},
]

# --- motion -------------------------------------------------------------------
BEAT_HZ = 0.45
BEAT_DEG = 12  # whole-wing sweep (fold / spread)
BEAT_LIFT_DEG = 5  # and a little roll with it
BREATHE_HZ = 0.22
BREATHE_STUDS = 0.06


def frame_cell(k):
    """(atlas index, column, row) of loop frame k."""
    atlas, sub = divmod(k % FRAMES, GRID * GRID)
    return atlas, sub % GRID, sub // GRID

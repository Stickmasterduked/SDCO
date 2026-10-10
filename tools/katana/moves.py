"""Choreography for the two katana skills, written as blade specs (the same
method as KatanaChoreoSpec) and solved onto the R6 rig.

Everything here is in ROOT space (X right, Y up, -Z forward) unless noted:
  torso  = [pitch, yaw, roll, x, z]   (y is solved so the feet meet the floor)
  head   = [pitch, yaw, roll] added on top of an automatic "eyes on target"
           counter-turn (the head undoes most of the torso's yaw and pitch)
  legs   = (fwd, splay) world angles in degrees per leg: fwd + swings the
           foot forward, splay + takes it outward
  aim    = shoulder -> right fist direction
  blade  = handle -> tip direction
  axis   = the swing's rotation axis; the cutting edge is axis x blade, so
           the edge always leads the cut (or give `edge` directly)
  lift   = extra torso height (airborne moments); `float` skips grounding

`python3 moves.py` writes src/.../KatanaSkillPoses.luau and prints the
foot heights so stances can be checked.
"""
import math
import os

import numpy as np

import cf
import luatable
import rig

OUT = os.path.join(rig.ROOT, "src/ReplicatedStorage/Combat/KatanaSkillAnimations/KatanaSkillPoses.luau")
FLOOR = -3.3  # lowest corner of a planted leg, root space (matches the katana idle)

READY = luatable.load(rig.POSES_PATH)["Katana_Idle"]["keys"][0]["pose"]

OVERHEAD = (-1, 0, 0)  # overhead cut: the tip goes back -> up -> forward -> down


# Move 1: forward dash into an explosive slice --------------------------------
# A diagonal cut: the sweep axis leans right and back, so the blade travels
# high on the right and finishes low on the left.
CUT_AXIS = tuple(cf.unit([-0.42, 1.0, 0.18]))

RUSH = {
    "name": "Katana_Rush",
    "length": 1.32,
    "recover": 1.0,
    "markers": {"Gather": 0.06, "Glint": 0.3, "Dash": 0.36, "Swing": 0.585, "Hit": 0.645, "Finish": 0.8, "Settle": 1.04},
    "keys": [
        {"t": 0.0, "ready": True},
        # counter-movement: a small rise and turn the other way before loading
        {"t": 0.09, "torso": [-3, 22, 3, 0.05, 0.05], "legs": ((10, 7), (-9, 9)),
         "aim": (0.18, -0.02, -0.98), "blade": (0.05, 0.62, -0.78), "axis": CUT_AXIS},
        # coil: lowered stance, shoulders turned right, katana drawn to the right hip
        {"t": 0.22, "torso": [-19, -34, 5, 0.1, 0.1], "legs": ((-30, 10), (30, 11)), "head": [0, 0, -2],
         "aim": (0.72, -0.48, 0.5), "blade": (0.42, -0.2, 0.88), "axis": CUT_AXIS},
        # glint: the coil tightens, blade level and still
        {"t": 0.3, "torso": [-23, -42, 6, 0.12, 0.12], "legs": ((-34, 11), (33, 12)), "head": [2, 0, -3],
         "aim": (0.76, -0.4, 0.5), "blade": (0.4, -0.12, 0.91), "axis": CUT_AXIS},
        # launch: drive off the back leg, body pitched into the dash
        {"t": 0.36, "torso": [-36, -36, 4, 0.08, -0.2], "legs": ((-52, 6), (34, 7)), "head": [-4, 0, 0],
         "aim": (0.64, -0.62, 0.44), "blade": (0.3, -0.36, 0.88), "axis": CUT_AXIS},
        # dash stride: legs scissor, blade trailing low
        {"t": 0.43, "torso": [-42, -38, -3, 0.05, -0.25], "legs": ((30, 6), (-48, 8)), "lift": 0.25, "head": [-6, 0, 0],
         "aim": (0.6, -0.66, 0.45), "blade": (0.28, -0.4, 0.87), "axis": CUT_AXIS},
        {"t": 0.5, "torso": [-41, -42, 4, 0.06, -0.25], "legs": ((-44, 7), (36, 7)), "lift": 0.18, "head": [-6, 0, 0],
         "aim": (0.66, -0.58, 0.47), "blade": (0.32, -0.3, 0.9), "axis": CUT_AXIS},
        # arriving: plant the left foot, the coil peaks, blade comes level behind
        {"t": 0.555, "torso": [-30, -56, 7, 0.1, -0.15], "legs": ((-40, 10), (40, 12)), "head": [-3, 0, -3],
         "aim": (0.84, -0.06, 0.5), "blade": (0.5, 0.12, 0.86), "axis": CUT_AXIS},
        # the cut: hips and shoulders unwind, the blade sweeps right -> front -> left
        {"t": 0.585, "torso": [-27, -44, 6, 0.08, -0.15], "legs": ((-42, 10), (42, 12)), "head": [-2, 0, -2],
         "aim": (0.96, 0.12, 0.22), "blade": (0.93, 0.2, 0.3), "axis": CUT_AXIS},
        {"t": 0.615, "torso": [-24, -16, 2, 0.04, -0.2], "legs": ((-44, 10), (44, 12)),
         "aim": (0.62, 0.02, -0.78), "blade": (0.66, 0.08, -0.75), "axis": CUT_AXIS},
        {"t": 0.645, "torso": [-23, 18, -3, -0.02, -0.25], "legs": ((-46, 10), (46, 12)),
         "aim": (-0.22, -0.1, -0.97), "blade": (-0.32, -0.1, -0.94), "axis": CUT_AXIS},
        {"t": 0.675, "torso": [-25, 42, -6, -0.08, -0.25], "legs": ((-47, 10), (47, 12)),
         "aim": (-0.8, -0.24, -0.55), "blade": (-0.86, -0.24, -0.45), "axis": CUT_AXIS},
        {"t": 0.73, "torso": [-27, 54, -8, -0.1, -0.25], "legs": ((-42, 13), (40, 16)), "head": [2, 0, 2],
         "aim": (-0.93, -0.18, 0.1), "blade": (-0.86, -0.22, 0.42), "axis": CUT_AXIS},
        # finishing pose: blade held out low behind on the left, deep lunge
        {"t": 0.8, "torso": [-28, 58, -8, -0.1, -0.25], "legs": ((-42, 13), (40, 16)), "head": [3, 0, 3],
         "aim": (-0.92, -0.22, 0.24), "blade": (-0.78, -0.28, 0.56), "axis": CUT_AXIS},
        {"t": 0.96, "torso": [-25, 55, -6, -0.08, -0.22], "legs": ((-40, 13), (38, 16)), "head": [2, 0, 2],
         "aim": (-0.9, -0.26, 0.27), "blade": (-0.76, -0.32, 0.56), "axis": CUT_AXIS},
        # recovery: rise, the blade circles up and over back to the guard
        {"t": 1.08, "torso": [-15, 36, -1, -0.02, -0.1], "legs": ((-22, 9), (24, 10)),
         "aim": (-0.3, 0.05, -0.95), "blade": (-0.42, 0.42, -0.8), "edge": (0.1, -0.8, -0.5)},
        {"t": 1.2, "torso": [-8, 18, 2, 0, 0], "legs": ((-6, 7), (14, 9)),
         "aim": (0.08, -0.02, -0.99), "blade": (-0.12, 0.54, -0.83), "edge": (-0.02, -0.83, -0.55)},
        {"t": 1.32, "ready": True},
    ],
}

# Move 2: overhead cut that launches a huge slash ------------------------------
CRESCENT = {
    "name": "Katana_Crescent",
    "length": 1.42,
    "recover": 1.1,
    "markers": {"Plant": 0.1, "Gather": 0.3, "Swing": 0.705, "Hit": 0.765, "Finish": 0.88, "Settle": 1.1},
    "keys": [
        {"t": 0.0, "ready": True},
        # plant: feet spread, weight settles, blade dips to the middle guard
        {"t": 0.1, "torso": [-11, 6, 1, 0, 0.05], "legs": ((-26, 12), (26, 11)),
         "aim": (0.12, -0.12, -0.98), "blade": (0.0, 0.32, -0.95), "axis": OVERHEAD},
        # rising: chest opens, arms lift the blade straight up
        {"t": 0.28, "torso": [0, 2, 0, 0, 0.1], "legs": ((-24, 11), (25, 11)), "head": [6, 0, 0],
         "aim": (0.1, 0.72, -0.68), "blade": (0.02, 0.99, 0.12), "axis": OVERHEAD},
        # overhead: torso extended, blade back over the head
        {"t": 0.44, "torso": [13, 0, 0, 0, 0.18], "legs": ((-24, 11), (26, 11)), "head": [-8, 0, 0],
         "aim": (0.05, 0.98, 0.12), "blade": (0.02, 0.48, 0.88), "axis": OVERHEAD},
        # anticipation: a breath held at the top while the blade charges
        {"t": 0.6, "torso": [16, 0, 0, 0, 0.2], "legs": ((-24, 11), (26, 11)), "head": [-10, 0, 0],
         "aim": (0.05, 0.98, 0.18), "blade": (0.02, 0.32, 0.95), "axis": OVERHEAD},
        {"t": 0.665, "torso": [17, 0, 0, 0, 0.22], "legs": ((-24, 11), (26, 11)), "head": [-10, 0, 0],
         "aim": (0.05, 0.98, 0.2), "blade": (0.02, 0.27, 0.96), "axis": OVERHEAD},
        # the cut: arms whip over, torso folds, front leg drives the lunge
        {"t": 0.705, "torso": [5, 0, 0, 0, 0.1], "legs": ((-30, 11), (32, 11)), "head": [-4, 0, 0],
         "aim": (0.04, 0.98, -0.18), "blade": (0.0, 0.92, -0.38), "axis": OVERHEAD},
        {"t": 0.735, "torso": [-14, -2, 0, 0, -0.1], "legs": ((-38, 11), (40, 11)),
         "aim": (0.03, 0.62, -0.78), "blade": (0.0, 0.66, -0.75), "axis": OVERHEAD},
        {"t": 0.765, "torso": [-31, -3, 0, 0, -0.35], "legs": ((-44, 11), (46, 11)),
         "aim": (0.02, 0.02, -1.0), "blade": (0.0, -0.1, -0.99), "axis": OVERHEAD},
        {"t": 0.81, "torso": [-41, -3, 0, 0, -0.45], "legs": ((-46, 11), (48, 11)), "head": [4, 0, 0],
         "aim": (0.02, -0.46, -0.89), "blade": (0.0, -0.72, -0.69), "axis": OVERHEAD},
        # finishing pose: folded deep over the front knee, tip near the floor
        {"t": 0.88, "torso": [-45, -4, 0, 0, -0.5], "legs": ((-47, 11), (49, 11)), "head": [6, 0, 0],
         "aim": (0.02, -0.58, -0.81), "blade": (0.0, -0.84, -0.54), "axis": OVERHEAD},
        {"t": 1.06, "torso": [-41, -4, 0, 0, -0.46], "legs": ((-46, 11), (48, 11)), "head": [5, 0, 0],
         "aim": (0.02, -0.56, -0.83), "blade": (0.0, -0.8, -0.6), "axis": OVERHEAD},
        # recovery: straighten up, the blade lifts back into the guard
        {"t": 1.22, "torso": [-20, 6, 1, 0, -0.2], "legs": ((-28, 10), (30, 10)),
         "aim": (0.1, -0.2, -0.97), "blade": (0.0, 0.12, -0.99), "edge": (0.0, -0.99, -0.12)},
        {"t": 1.42, "ready": True},
    ],
}

MOVES = [RUSH, CRESCENT]


# ---------------------------------------------------------------------------


def leg_direction(side, fwd, splay):
    sx = 1 if side == "RightLeg" else -1
    return cf.unit([sx * math.tan(math.radians(splay)), -1.0, -math.tan(math.radians(fwd))])


def to_torso_space(frames, v):
    return cf.vec(cf.inv(cf.rot(frames["Torso"])), cf.unit(v))


def unwrap(prev, value):
    if prev is None:
        return value
    out = list(value)
    for c in range(min(3, len(out))):
        while out[c] - prev[c] > 180:
            out[c] -= 360
        while out[c] - prev[c] < -180:
            out[c] += 360
    return out


def solve_key(key, grip, prev_local):
    t = key["torso"]
    pose = {"Torso": [t[0], t[1], t[2], t[3], 0.0, t[4]]}
    # head keeps the eyes forward: undo most of the torso's yaw / pitch / roll
    h = key.get("head", [0, 0, 0])
    pose["Head"] = [-t[0] * 0.6 + h[0], -t[1] * 0.78 + h[1], -t[2] * 0.7 + h[2]]
    (rf, rs), (lf, ls) = key["legs"]
    spec = {"RightLeg": (rf, rs), "LeftLeg": (lf, ls)}
    twist = {"RightLeg": -8, "LeftLeg": 10}

    def place(side, scale):
        f, s = spec[side]
        pose[side] = rig.leg_for(pose, side, leg_direction(side, f * scale, s * scale), twist=twist[side])

    for side in spec:
        place(side, 1.0)
    frames = rig.fk(pose)
    soles = {s: rig.sole_y(frames, s) for s in spec}
    # drop the body until the more spread (higher) foot meets the floor ...
    high = max(soles, key=soles.get)
    pose["Torso"][4] = FLOOR - soles[high]
    if "lift" in key:
        # airborne: the lower foot just clears the floor
        pose["Torso"][4] = FLOOR - min(soles.values()) + key["lift"]
    else:
        # ... then widen the other leg until it lands as well
        other = "LeftLeg" if high == "RightLeg" else "RightLeg"
        f, sp = spec[other]
        lo, hi = 1.0, max(1.0, 72 / max(abs(f), abs(sp), 1e-3))
        for _ in range(30):
            mid = (lo + hi) / 2
            place(other, mid)
            if rig.sole_y(rig.fk(pose), other) < FLOOR:
                lo = mid
            else:
                hi = mid
        place(other, (lo + hi) / 2)
        # couldn't reach (stance too deep): lift the body so it stands on
        # that foot instead and the other only hovers a touch
        miss = FLOOR - rig.sole_y(rig.fk(pose), other)
        if miss > 0.02:
            pose["Torso"][4] += miss
    pose["Torso"][4] = round(pose["Torso"][4], 3)
    frames = rig.fk(pose)
    aim = to_torso_space(frames, key["aim"])
    blade = to_torso_space(frames, key["blade"])
    if "edge" in key:
        edge = to_torso_space(frames, key["edge"])
    else:
        edge = to_torso_space(frames, np.cross(np.asarray(key["axis"], float), cf.unit(key["blade"])))
    ra, ka, err, local = rig.solve_blade(pose, aim, blade, edge, grip, prev_local)
    pose["RightArm"], pose["Katana"] = ra, ka
    pose["LeftArm"] = rig.left_ik(pose, grip)
    return pose, err, local


def solve_move(move, grip, verbose=True):
    keys, prev_local, last = [], None, {}
    for key in move["keys"]:
        if key.get("ready"):
            pose = {j: list(v) for j, v in READY.items()}
        else:
            pose, err, prev_local = solve_key(key, grip, prev_local)
            if verbose:
                fr = rig.fk(pose)
                feet = [round(rig.sole_y(fr, s), 2) for s in ("RightLeg", "LeftLeg")]
                print(f"  {move['name']} t={key['t']:.3f} wrist={err:5.1f}deg feet={feet} torsoY={pose['Torso'][4]}")
        for j in pose:
            pose[j] = unwrap(last.get(j), [round(x, 3) for x in pose[j]])
            last[j] = pose[j]
        keys.append({"t": key["t"], "pose": pose})
    return keys


def fmt(v):
    return "{ " + ", ".join(("%g" % round(x, 3)) for x in v) + " }"


ORDER = ("Torso", "RightLeg", "LeftLeg", "RightArm", "LeftArm", "Katana", "Head")


def write(solved):
    lines = [
        "-- Generated by tools/katana/moves.py: katana skill pose keys, solved on an",
        "-- R6 rig (both fists on the handle). Edit the specs there, not this file.",
        "return {",
    ]
    for move, keys in solved:
        lines.append(f"\t{move['name']} = {{")
        lines.append(f"\t\tlength = {move['length']},")
        lines.append(f"\t\trecover = {move['recover']},")
        marks = ", ".join(f"{k} = {v}" for k, v in sorted(move["markers"].items(), key=lambda kv: kv[1]))
        lines.append(f"\t\tmarkers = {{ {marks} }},")
        lines.append("\t\tkeys = {")
        for key in keys:
            body = ", ".join(f"{j} = {fmt(key['pose'][j])}" for j in ORDER)
            lines.append(f"\t\t\t{{ t = {key['t']}, pose = {{ {body} }} }},")
        lines.append("\t\t},")
        lines.append("\t},")
    lines.append("}")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        f.write("\n".join(lines) + "\n")


def build(verbose=True):
    grip = rig.load_grip()
    solved = [(m, solve_move(m, grip, verbose)) for m in MOVES]
    write(solved)
    return solved


if __name__ == "__main__":
    build()
    print("wrote", OUT)

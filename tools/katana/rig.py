"""R6 + katana rig: forward kinematics, the KatanaChoreo blade solver, left
hand IK and grounded legs. Mirrors tools/studio/KatanaChoreo.luau and
AnimationBuilder.toTransform exactly, so poses solved here play the same in
game.

The katana's RightGrip / LeftGrip attachments aren't in the repo; they are
recovered from KatanaChoreoSpec + KatanaPoses (the same keys, solved in
Studio): see calibrate().
"""
import json
import math
import os

import numpy as np

import cf
import luatable

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
POSES_PATH = os.path.join(ROOT, "src/ReplicatedStorage/Combat/KatanaAnimations/KatanaPoses.luau")
SPEC_PATH = os.path.join(ROOT, "tools/studio/KatanaChoreoSpec.luau")
CALIBRATION_PATH = os.path.join(HERE, "grip_calibration.json")

ROOT_ROT = cf.orientation(-math.pi / 2, math.pi, 0)
RIGHT_ROT = cf.orientation(0, math.pi / 2, 0)
LEFT_ROT = cf.orientation(0, -math.pi / 2, 0)
ROTATION = {
    "Torso": ROOT_ROT, "Head": ROOT_ROT,
    "RightArm": RIGHT_ROT, "LeftArm": LEFT_ROT,
    "RightLeg": RIGHT_ROT, "LeftLeg": LEFT_ROT,
    "Katana": cf.ident(),
}
# Motor6D C0 / C1 of the standard R6 rig
MOTOR = {
    "Torso": (ROOT_ROT, ROOT_ROT),
    "Head": (cf.new(0, 1, 0) @ ROOT_ROT, cf.new(0, -0.5, 0) @ ROOT_ROT),
    "RightArm": (cf.new(1, 0.5, 0) @ RIGHT_ROT, cf.new(-0.5, 0.5, 0) @ RIGHT_ROT),
    "LeftArm": (cf.new(-1, 0.5, 0) @ LEFT_ROT, cf.new(0.5, 0.5, 0) @ LEFT_ROT),
    "RightLeg": (cf.new(1, -1, 0) @ RIGHT_ROT, cf.new(0.5, 1, 0) @ RIGHT_ROT),
    "LeftLeg": (cf.new(-1, -1, 0) @ LEFT_ROT, cf.new(-0.5, 1, 0) @ LEFT_ROT),
}
KATANA_C0 = cf.new(0, -0.8, 0)  # KatanaGrip.C0 on the Right Arm
FIST = np.array([0.0, -0.8, 0.0])
SIZE = {
    "Torso": (2, 2, 1), "Head": (2, 1, 1),
    "RightArm": (1, 2, 1), "LeftArm": (1, 2, 1),
    "RightLeg": (1, 2, 1), "LeftLeg": (1, 2, 1),
}
LIMBS = ("Head", "RightArm", "LeftArm", "RightLeg", "LeftLeg")


def to_transform(joint, value):
    v = list(value) + [0] * (6 - len(value))
    offset = cf.new(v[3], v[4], v[5]) @ cf.angles(math.radians(v[0]), math.radians(v[1]), math.radians(v[2]))
    r = ROTATION[joint]
    return cf.inv(r) @ offset @ r


def from_transform(joint, t, keep_position=True):
    r = ROTATION[joint]
    rv = r @ t @ cf.inv(r)
    x, y, z = cf.euler_xyz(rv)
    p = cf.pos(rv) if keep_position else (0, 0, 0)
    return [math.degrees(x), math.degrees(y), math.degrees(z), p[0], p[1], p[2]]


class Grip:
    """The katana handle's grip attachments (handle space)."""

    def __init__(self, right_rot, left_offset, blade=(0.35, 4.45), handle_back=1.25):
        self.right_rot = right_rot  # RightGrip.CFrame rotation (4x4)
        self.left_offset = np.asarray(left_offset, float)  # LeftGrip - RightGrip, in blade frame (X right, Y up=-edge, -Z blade)
        self.blade = blade  # guard / tip distance from the right fist along the blade (preview only)
        self.handle_back = handle_back  # pommel distance behind the right fist (preview only)


def load_grip():
    with open(CALIBRATION_PATH) as f:
        data = json.load(f)
    return Grip(np.array(data["right_rot"]), data["left_offset"])


def fk(pose, root=None, grip=None):
    """World CFrames of every part (and the blade frame at the right fist)."""
    root = cf.ident() if root is None else root
    T = {j: to_transform(j, pose[j]) if j in pose else cf.ident() for j in list(MOTOR) + ["Katana"]}
    out = {}
    c0, c1 = MOTOR["Torso"]
    out["Torso"] = root @ c0 @ T["Torso"] @ cf.inv(c1)
    for j in LIMBS:
        c0, c1 = MOTOR[j]
        out[j] = out["Torso"] @ c0 @ T[j] @ cf.inv(c1)
    if grip is not None:
        # KatanaGrip: Part0 = Right Arm, C1 = RightGrip.CFrame. The handle's
        # own frame is the blade frame (LookVector = blade, UpVector = spine);
        # its origin is put on the fist (the grip's position is unknown and
        # doesn't change any direction).
        fist = out["RightArm"] @ KATANA_C0
        handle = fist @ T["Katana"] @ cf.inv(grip.right_rot)
        blade = cf.rot(handle)
        blade[:3, 3] = cf.pos(fist)
        out["Blade"] = blade
    return out


def blade_points(frames, grip):
    b = frames["Blade"]
    return {
        "fist": cf.pos(b),
        "pommel": cf.point(b, (0, 0, grip.handle_back)),
        "guard": cf.point(b, (0, 0, -grip.blade[0])),
        "tip": cf.point(b, (0, 0, -grip.blade[1])),
        "edge": -cf.up(b),
    }


def blade_frame_torso(blade, edge):
    """KatanaChoreo's handle frame from spec vectors (torso space)."""
    blade = cf.unit(blade)
    edge = np.asarray(edge, float)
    edge = cf.unit(edge - blade * edge.dot(blade))
    upv = -edge
    rightv = np.cross(upv, -blade)
    return cf.from_matrix(np.zeros(3), rightv, upv, -blade)


# ---------------------------------------------------------------------------
# Calibration


def calibrate():
    """Recover RightGrip's rotation and the left grip offset from the keys the
    user solved in Studio (KatanaChoreoSpec -> KatanaPoses)."""
    specs, _ = luatable.load_spec(SPEC_PATH)
    poses = luatable.load(POSES_PATH)
    rots, offsets = [], []
    c0r, c1r = MOTOR["RightArm"]
    c0l, c1l = MOTOR["LeftArm"]
    for name, spec in specs.items():
        solved = {round(k["t"], 4): k["pose"] for k in poses[name]["keys"]}
        for key in spec["keys"]:
            p = solved.get(round(key["t"], 4))
            if not p:
                continue
            arm = c0r @ to_transform("RightArm", p["RightArm"]) @ cf.inv(c1r)  # torso space
            tk = cf.rot(to_transform("Katana", p["Katana"]))
            h = blade_frame_torso(key["blade"], key["edge"])
            # Tk = (arm * C0k)^-1 * handle * G, handle = H * G^-1  =>  G is free;
            # Tk_rot = arm_rot^-1 * H_rot * G^-1 * G ... solve: H_rot = arm_rot * Tk_rot * G^-1
            g = cf.inv(h) @ cf.rot(arm) @ tk
            rots.append(cf.rot(g))
            left = c0l @ to_transform("LeftArm", p["LeftArm"]) @ cf.inv(c1l)
            rf, lf = cf.point(arm, FIST), cf.point(left, FIST)
            offsets.append(cf.vec(cf.inv(h), lf - rf))
    # average rotation: mean of matrices, re-orthonormalised
    m = sum(r[:3, :3] for r in rots) / len(rots)
    u, _, vt = np.linalg.svd(m)
    g = np.eye(4)
    g[:3, :3] = u @ vt
    spread = max(math.degrees(cf.to_axis_angle(cf.inv(g) @ r)) for r in rots)
    offsets = np.array(offsets)
    left = np.median(offsets, axis=0)
    result = {"right_rot": g.tolist(), "left_offset": left.tolist(), "samples": len(rots),
              "max_rotation_error_deg": spread, "left_offset_spread": offsets.std(axis=0).tolist()}
    with open(CALIBRATION_PATH, "w") as f:
        json.dump(result, f, indent=1)
    return result


# ---------------------------------------------------------------------------
# Solver (port of KatanaChoreo.solve / leftIK)


def r2(v):
    return math.floor(v * 100 + 0.5) / 100


def solve_blade(pose, aim, blade, edge, grip, prev=None):
    """Right arm + katana wrist for a blade direction (torso space)."""
    frames = fk(pose)
    torso = frames["Torso"]
    c0, c1 = MOTOR["RightArm"]
    shoulder = torso @ c0
    pivot = cf.pos(shoulder)
    arm0 = torso @ c0 @ cf.inv(c1)
    v0 = cf.point(arm0, FIST) - pivot
    d = cf.unit(cf.vec(torso, cf.unit(aim)))
    cross = np.cross(cf.unit(v0), d)
    if np.linalg.norm(cross) > 1e-6:
        swing = cf.axis_angle(cross, math.acos(np.clip(cf.unit(v0).dot(d), -1, 1)))
    elif cf.unit(v0).dot(d) < 0:
        swing = cf.axis_angle(cf.right(torso), math.pi)
    else:
        swing = cf.ident()
    bw = cf.unit(cf.vec(torso, cf.unit(blade)))
    ew = cf.vec(torso, cf.unit(edge))
    ew = cf.unit(ew - bw * ew.dot(bw))
    upv = -ew
    rightv = np.cross(upv, -bw)
    hrot = cf.from_matrix(np.zeros(3), rightv, upv, -bw)
    best = None
    for i in range(72):
        tw = math.radians(i * 5)
        rotm = cf.axis_angle(d, tw) @ swing
        arm = cf.at(pivot) @ rotm @ cf.at(-pivot) @ arm0
        # handle * grip = blade frame at the fist  =>  Tk = (arm*C0k)^-1 * hrot(at fist) * G... rotation only
        tk = cf.rot(cf.inv(arm @ KATANA_C0)) @ hrot @ grip.right_rot
        tk = cf.rot(tk)
        angle = abs(cf.to_axis_angle(tk))
        local = cf.inv(torso) @ arm
        score = angle
        if prev is not None:
            score += abs(cf.to_axis_angle(cf.inv(prev) @ local)) * 0.9
        if best is None or score < best[0]:
            best = (score, angle, arm, tk, local)
    _, angle, arm, tk, local = best
    t = cf.inv(c0) @ cf.inv(torso) @ arm @ c1
    ra = from_transform("RightArm", t, keep_position=False)
    kx, ky, kz = cf.euler_xyz(tk)
    return [r2(ra[0]), r2(ra[1]), r2(ra[2]), 0, 0, 0], [r2(math.degrees(kx)), r2(math.degrees(ky)), r2(math.degrees(kz))], math.degrees(angle), local


def left_ik(pose, grip, start=(60, 0, 70, 0, 0, 0)):
    """Left fist onto the left grip (same method as PoseAnimator.twoHand)."""
    p = dict(pose)
    p["LeftArm"] = list(start)
    frames = fk(p, grip=grip)
    blade = frames["Blade"]
    target = cf.point(blade, grip.left_offset)
    axis = cf.look(blade)
    c0, c1 = MOTOR["LeftArm"]
    shoulder = cf.pos(frames["Torso"] @ c0)
    current = frames["LeftArm"]
    a, b = cf.point(current, FIST) - shoulder, target - shoulder
    solved = current
    cross = np.cross(cf.unit(a), cf.unit(b))
    if np.linalg.norm(cross) > 1e-5:
        ang = math.acos(np.clip(cf.unit(a).dot(cf.unit(b)), -1, 1))
        solved = cf.at(shoulder) @ cf.axis_angle(cross, ang) @ cf.at(-shoulder) @ current
    slide = target - cf.point(solved, FIST)
    if np.linalg.norm(slide) > 0.7:
        slide = cf.unit(slide) * 0.7
    solved = solved.copy()
    solved[:3, 3] += slide
    upv = cf.up(solved)
    across = axis - upv * axis.dot(upv)
    if np.linalg.norm(across) > 0.25:
        across = cf.unit(across)
        lk = cf.look(solved)
        if lk.dot(across) < 0:
            across = -across
        twist = math.atan2(np.cross(lk, across).dot(upv), lk.dot(across))
        pv = cf.point(solved, FIST)
        solved = cf.at(pv) @ cf.axis_angle(upv, twist) @ cf.at(-pv) @ solved
    t = cf.inv(c0) @ cf.inv(frames["Torso"]) @ solved @ c1
    v = from_transform("LeftArm", t)
    return [r2(v[0]), r2(v[1]), r2(v[2]), r2(v[3]), r2(v[4]), r2(v[5])]


# ---------------------------------------------------------------------------
# Legs: point a leg along a root-space direction (no knees in R6)


def leg_for(pose, side, direction, twist=0.0):
    """Joint value that points `side` leg (hip -> sole) along `direction`
    (root space), keeping the foot facing forward-ish."""
    p = dict(pose)
    p[side] = [0, 0, 0]
    frames = fk(p)
    torso = frames["Torso"]
    c0, c1 = MOTOR[side]
    rest = torso @ c0 @ cf.inv(c1)  # leg with identity transform
    hip = cf.pos(torso @ c0)
    cur = cf.unit(cf.point(rest, (0, -1, 0)) - hip)
    d = cf.unit(direction)
    cross = np.cross(cur, d)
    if np.linalg.norm(cross) > 1e-8:
        rotm = cf.axis_angle(cross, math.acos(np.clip(cur.dot(d), -1, 1)))
    else:
        rotm = cf.ident()
    # remove torso yaw from the foot: twist about the leg so the foot points
    # along the root's forward (plus `twist` degrees)
    leg = cf.at(hip) @ rotm @ cf.at(-hip) @ rest
    fwd = cf.look(leg)
    want = np.array([0.0, 0.0, -1.0])
    want = cf.vec(cf.ry(math.radians(twist)), want)
    want = want - d * want.dot(d)
    fwd = fwd - d * fwd.dot(d)
    if np.linalg.norm(want) > 1e-3 and np.linalg.norm(fwd) > 1e-3:
        a = math.atan2(np.cross(cf.unit(fwd), cf.unit(want)).dot(d), cf.unit(fwd).dot(cf.unit(want)))
        leg = cf.at(hip) @ cf.axis_angle(d, a) @ cf.at(-hip) @ leg
    t = cf.inv(c0) @ cf.inv(torso) @ leg @ c1
    v = from_transform(side, t, keep_position=False)
    return [round(v[0], 2), round(v[1], 2), round(v[2], 2)]


def sole_y(frames, side):
    leg = frames[side]
    # lowest corner of the leg box
    sx, sy, sz = [s / 2 for s in SIZE[side]]
    ys = [cf.point(leg, (x, y, z))[1] for x in (-sx, sx) for y in (-sy, sy) for z in (-sz, sz)]
    return min(ys)


if __name__ == "__main__":
    print(json.dumps(calibrate(), indent=1))

"""Roblox CFrame math on 4x4 numpy matrices (same conventions as Luau).

CFrame.Angles(x, y, z) == Rx(x) @ Ry(y) @ Rz(z); fromOrientation(x, y, z)
== Ry(y) @ Rx(x) @ Rz(z); LookVector is -Z; ToEulerAnglesXYZ inverts Angles.
"""
import math
import numpy as np


def ident():
    return np.eye(4)


def new(x=0.0, y=0.0, z=0.0):
    m = np.eye(4)
    m[:3, 3] = (x, y, z)
    return m


def at(p):
    return new(*p)


def rx(a):
    c, s = math.cos(a), math.sin(a)
    m = np.eye(4)
    m[1, 1], m[1, 2], m[2, 1], m[2, 2] = c, -s, s, c
    return m


def ry(a):
    c, s = math.cos(a), math.sin(a)
    m = np.eye(4)
    m[0, 0], m[0, 2], m[2, 0], m[2, 2] = c, s, -s, c
    return m


def rz(a):
    c, s = math.cos(a), math.sin(a)
    m = np.eye(4)
    m[0, 0], m[0, 1], m[1, 0], m[1, 1] = c, -s, s, c
    return m


def angles(x, y, z):
    return rx(x) @ ry(y) @ rz(z)


def orientation(x, y, z):
    return ry(y) @ rx(x) @ rz(z)


def inv(m):
    r = m[:3, :3].T
    out = np.eye(4)
    out[:3, :3] = r
    out[:3, 3] = -r @ m[:3, 3]
    return out


def pos(m):
    return m[:3, 3].copy()


def rot(m):
    out = m.copy()
    out[:3, 3] = 0
    return out


def point(m, v):
    return m[:3, :3] @ np.asarray(v, float) + m[:3, 3]


def vec(m, v):
    return m[:3, :3] @ np.asarray(v, float)


def look(m):
    return -m[:3, 2]


def up(m):
    return m[:3, 1].copy()


def right(m):
    return m[:3, 0].copy()


def from_matrix(p, vx, vy, vz):
    m = np.eye(4)
    m[:3, 0], m[:3, 1], m[:3, 2] = vx, vy, vz
    m[:3, 3] = p
    return m


def axis_angle(axis, a):
    axis = np.asarray(axis, float)
    axis = axis / np.linalg.norm(axis)
    x, y, z = axis
    c, s, t = math.cos(a), math.sin(a), 1 - math.cos(a)
    m = np.eye(4)
    m[:3, :3] = [
        [t * x * x + c, t * x * y - s * z, t * x * z + s * y],
        [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
        [t * x * z - s * y, t * y * z + s * x, t * z * z + c],
    ]
    return m


def to_axis_angle(m):
    r = m[:3, :3]
    c = max(-1.0, min(1.0, (np.trace(r) - 1) / 2))
    return math.acos(c)


def euler_xyz(m):
    """CFrame:ToEulerAnglesXYZ() (radians)."""
    r = m[:3, :3]
    y = math.asin(max(-1.0, min(1.0, r[0, 2])))
    if abs(r[0, 2]) < 0.999999:
        x = math.atan2(-r[1, 2], r[2, 2])
        z = math.atan2(-r[0, 1], r[0, 0])
    else:
        x = math.atan2(r[2, 1], r[1, 1])
        z = 0.0
    return x, y, z


def lerp(a, b, t):
    """CFrame:Lerp (slerp rotation, lerp position)."""
    ra, rb = a[:3, :3], b[:3, :3]
    rel = ra.T @ rb
    angle = to_axis_angle(np.vstack([np.hstack([rel, [[0], [0], [0]]]), [0, 0, 0, 1]]))
    out = np.eye(4)
    if angle < 1e-9:
        out[:3, :3] = ra
    else:
        w = np.array([rel[2, 1] - rel[1, 2], rel[0, 2] - rel[2, 0], rel[1, 0] - rel[0, 1]])
        n = np.linalg.norm(w)
        if n < 1e-9:  # 180 degrees: find the axis from the symmetric part
            vals, vecs = np.linalg.eigh((rel + rel.T) / 2)
            axis = vecs[:, np.argmax(vals)]
        else:
            axis = w / n
        out[:3, :3] = ra @ axis_angle(axis, angle * t)[:3, :3]
    out[:3, 3] = a[:3, 3] + (b[:3, 3] - a[:3, 3]) * t
    return out


def unit(v):
    v = np.asarray(v, float)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v

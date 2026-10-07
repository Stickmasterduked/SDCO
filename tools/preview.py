"""Renders AnimationData poses with the same R6 joint math Roblox uses.

    python3 tools/preview.py Stance M1_1 ...      -> previews/<name>.png
    python3 tools/preview.py --fps 30 M1_1        -> filmstrip instead of keyframes
    python3 tools/preview.py --fps 60 --window 0 0.3 M1_1   -> part of a filmstrip

Each column is one frame; rows are side, front and three-quarter views.
The red cross marks where an opponent would stand (5 studs ahead).
"""
import argparse, json, math, os, subprocess
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LUAU = os.environ.get("LUAU", "luau")


def rx(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def ry(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def rz(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


class CF:
    def __init__(self, R=None, p=None):
        self.R = np.eye(3) if R is None else R
        self.p = np.zeros(3) if p is None else np.asarray(p, float)

    def __mul__(self, o):
        return CF(self.R @ o.R, self.p + self.R @ o.p)

    def point(self, v):
        return self.p + self.R @ np.asarray(v, float)


def T(x, y, z):
    return CF(p=[x, y, z])


def pose_cf(v):
    v = list(v) + [0] * (6 - len(v))
    a = [math.radians(x) for x in v[:3]]
    return CF(rx(a[0]) @ ry(a[1]) @ rz(a[2]), v[3:6])


# --- quaternion helpers, to mirror CFrame:Lerp ---------------------------
def mat2q(m):
    t = np.trace(m)
    if t > 0:
        s = math.sqrt(t + 1) * 2
        return np.array([0.25 * s, (m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s])
    i = int(np.argmax([m[0, 0], m[1, 1], m[2, 2]]))
    if i == 0:
        s = math.sqrt(1 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        return np.array([(m[2, 1] - m[1, 2]) / s, 0.25 * s, (m[0, 1] + m[1, 0]) / s, (m[0, 2] + m[2, 0]) / s])
    if i == 1:
        s = math.sqrt(1 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        return np.array([(m[0, 2] - m[2, 0]) / s, (m[0, 1] + m[1, 0]) / s, 0.25 * s, (m[1, 2] + m[2, 1]) / s])
    s = math.sqrt(1 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
    return np.array([(m[1, 0] - m[0, 1]) / s, (m[0, 2] + m[2, 0]) / s, (m[1, 2] + m[2, 1]) / s, 0.25 * s])


def q2mat(q):
    w, x, y, z = q / np.linalg.norm(q)
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def slerp(a, b, t):
    qa, qb = mat2q(a), mat2q(b)
    d = float(np.dot(qa, qb))
    if d < 0:
        qb, d = -qb, -d
    if d > 0.9995:
        return q2mat(qa + (qb - qa) * t)
    th = math.acos(min(1.0, d))
    return q2mat((math.sin((1 - t) * th) * qa + math.sin(t * th) * qb) / math.sin(th))


def lerp_cf(a, b, t):
    return CF(slerp(a.R, b.R, t), a.p + (b.p - a.p) * t)


# --- easing (TweenService:GetValue) ---------------------------------------
def ease_in(style, t):
    if style in ("Linear",):
        return t
    if style == "Sine":
        return 1 - math.cos(t * math.pi / 2)
    if style == "Quad":
        return t ** 2
    if style == "Cubic":
        return t ** 3
    if style == "Quart":
        return t ** 4
    if style == "Quint":
        return t ** 5
    if style == "Exponential":
        return 0 if t == 0 else 2 ** (10 * t - 10)
    if style == "Circular":
        return 1 - math.sqrt(max(0, 1 - t * t))
    if style == "Back":
        c1 = 1.70158
        return (c1 + 1) * t ** 3 - c1 * t ** 2
    if style == "Elastic":
        if t in (0, 1):
            return t
        return -(2 ** (10 * t - 10)) * math.sin((t * 10 - 10.75) * (2 * math.pi) / 3)
    if style == "Bounce":
        return 1 - ease_out_bounce(1 - t)
    return t ** 2


def ease_out_bounce(t):
    n, d = 7.5625, 2.75
    if t < 1 / d:
        return n * t * t
    if t < 2 / d:
        t -= 1.5 / d
        return n * t * t + 0.75
    if t < 2.5 / d:
        t -= 2.25 / d
        return n * t * t + 0.9375
    t -= 2.625 / d
    return n * t * t + 0.984375


def ease(alpha, style, direction):
    if style == "Constant":
        return 0
    if style == "Linear":
        return alpha
    if direction == "In":
        return ease_in(style, alpha)
    if direction == "Out":
        return 1 - ease_in(style, 1 - alpha)
    if alpha < 0.5:
        return ease_in(style, alpha * 2) / 2
    return 1 - ease_in(style, (1 - alpha) * 2) / 2


JOINTS = ["Torso", "Head", "RightArm", "LeftArm", "RightLeg", "LeftLeg"]


def compile_clip(data):
    joints = {}
    for key in data["keys"]:
        for j in key["pose"]:
            joints.setdefault(j, [])
    last = {}
    for key in data["keys"]:
        for j, lst in joints.items():
            last[j] = key["pose"].get(j, last.get(j, [0, 0, 0]))
            lst.append((key["t"], pose_cf(last[j]), key.get("ease", "Linear"), key.get("dir", "In")))
    return joints


def sample(keys, t):
    if t <= keys[0][0]:
        return keys[0][1]
    for a, b in zip(keys, keys[1:]):
        if t < b[0]:
            alpha = (t - a[0]) / (b[0] - a[0])
            return lerp_cf(a[1], b[1], ease(alpha, a[2], a[3]))
    return keys[-1][1]


# R6 joint layout: (parent, C0 position, C1 position) - rotations cancel out
# because poses are authored in parent-aligned axes (see AnimationBuilder).
RIG = {
    "Torso": ("HRP", (0, 0, 0), (0, 0, 0)),
    "Head": ("Torso", (0, 1, 0), (0, -0.5, 0)),
    "RightArm": ("Torso", (1, 0.5, 0), (-0.5, 0.5, 0)),
    "LeftArm": ("Torso", (-1, 0.5, 0), (0.5, 0.5, 0)),
    "RightLeg": ("Torso", (1, -1, 0), (0.5, 1, 0)),
    "LeftLeg": ("Torso", (-1, -1, 0), (-0.5, 1, 0)),
}
SIZES = {"Torso": (2, 2, 1), "Head": (1.25, 1.25, 1.25), "RightArm": (1, 2, 1), "LeftArm": (1, 2, 1),
         "RightLeg": (1, 2, 1), "LeftLeg": (1, 2, 1)}
COLORS = {"Torso": "#9aa3ad", "Head": "#f2c94c", "RightArm": "#e05a4f", "LeftArm": "#4f7fe0",
          "RightLeg": "#b8443c", "LeftLeg": "#3c63b8"}


def solve(pose):
    world = {"HRP": CF()}
    for j in JOINTS:
        parent, c0, c1 = RIG[j]
        world[j] = world[parent] * T(*c0) * pose.get(j, CF()) * T(*(-np.array(c1)))
    return world


def box_faces(cf, size):
    sx, sy, sz = (s / 2 for s in size)
    c = [cf.point((x, y, z)) for x in (-sx, sx) for y in (-sy, sy) for z in (-sz, sz)]
    idx = [(0, 1, 3, 2), (4, 5, 7, 6), (0, 1, 5, 4), (2, 3, 7, 6), (0, 2, 6, 4), (1, 3, 7, 5)]
    return [np.array([c[i] for i in f]) for f in idx]


def view_matrix(name):
    # returns rotation mapping world -> view (x right, y up, z toward viewer)
    if name == "side":  # viewer on the character's right, forward (-Z) points right
        return ry(math.radians(-90))
    if name == "front":
        return ry(math.radians(180))
    return rx(math.radians(18)) @ ry(math.radians(-140))


def draw(ax, world, view, title):
    V = view_matrix(view)
    polys = []
    for j in JOINTS:
        for f in box_faces(world[j], SIZES[j]):
            pv = (V @ f.T).T
            n = np.cross(pv[1] - pv[0], pv[2] - pv[0])
            shade = 0.55 + 0.45 * abs(n[2]) / (np.linalg.norm(n) + 1e-9)
            polys.append((pv[:, 2].mean(), pv[:, :2], COLORS[j], shade))
    polys.sort(key=lambda p: p[0])
    for _, pts, col, shade in polys:
        rgb = np.array(matplotlib.colors.to_rgb(col)) * shade
        ax.add_patch(Polygon(pts, closed=True, facecolor=rgb, edgecolor="#222", linewidth=0.4))
    # ground + opponent marker
    g = [(V @ np.array([x, -3, z])) for x, z in ((-6, -6), (6, -6), (6, 6), (-6, 6))]
    ax.plot([p[0] for p in g + g[:1]], [p[1] for p in g + g[:1]], color="#7a8", lw=0.5)
    m = V @ np.array([0, 0, -5])
    ax.plot([m[0]], [m[1]], "x", color="red", ms=6)
    ax.set_xlim(-5.5, 5.5)
    ax.set_ylim(-4.2, 4.5)
    ax.set_aspect("equal")
    ax.axis("off")
    ax.set_title(title, fontsize=7)


def render(name, data, fps=None, out_dir="previews", window=None):
    clip = compile_clip(data)
    markers = data.get("markers", {})
    if fps:
        lo, hi = window or (0, data["length"])
        times = list(np.arange(lo, hi + 1e-6, 1 / fps))
    else:
        # detailed clips carry their authored beats in sourceKeys
        beats = data.get("sourceKeys") or data["keys"]
        times = sorted({k["t"] for k in beats} | set(markers.values()))
    views = ["side", "front", "3/4"]
    fig, axes = plt.subplots(len(views), len(times), figsize=(2.3 * len(times), 2.4 * len(views)), squeeze=False)
    for col, t in enumerate(times):
        pose = {j: sample(keys, t) for j, keys in clip.items()}
        world = solve(pose)
        tags = [m for m, mt in markers.items() if abs(mt - t) < 1e-4]
        label = f"t={t:.3f}" + (" " + ",".join(tags) if tags else "")
        for row, v in enumerate(views):
            draw(axes[row][col], world, v, label if row == 0 else v)
    fig.suptitle(f"{name}  length={data['length']}  recover={data.get('recover')}", fontsize=9)
    fig.tight_layout()
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{name}{'_film' if fps else ''}.png")
    fig.savefig(path, dpi=110)
    plt.close(fig)
    return path


def load():
    out = subprocess.check_output([LUAU, os.path.join(ROOT, "tools", "dump_anims.luau")], cwd=ROOT)
    return json.loads(out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="*")
    ap.add_argument("--fps", type=float)
    ap.add_argument("--out", default=os.path.join(ROOT, "previews"))
    ap.add_argument("--window", nargs=2, type=float, help="filmstrip start/end time")
    args = ap.parse_args()
    anims = load()
    for n in args.names or sorted(anims):
        print(render(n, anims[n], args.fps, args.out, args.window))

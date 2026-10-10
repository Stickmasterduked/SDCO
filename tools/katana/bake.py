"""Python twin of the in-game bake (AnimationData.detail + the katana skill
stagger in KatanaSkillAnimations), so previews show exactly the curves
PoseAnimator will play.
"""
import math


def channels(v):
    v = list(v) + [0] * 6
    return [float(x) for x in v[:6]]


def joint_tracks(clip):
    joints = []
    for key in clip["keys"]:
        for j in key["pose"]:
            if j not in joints:
                joints.append(j)
    tracks = {j: [] for j in joints}
    last = {}
    for key in clip["keys"]:
        for j in joints:
            last[j] = key["pose"].get(j, last.get(j, [0, 0, 0]))
            tracks[j].append({"t": key["t"], "v": channels(last[j])})
    looped = clip.get("looped", False)
    length = clip["length"]
    for lst in tracks.values():
        n = len(lst)
        for i, k in enumerate(lst):
            prev = lst[i - 1] if i > 0 else None
            nxt = lst[i + 1] if i + 1 < n else None
            prev_t = prev["t"] if prev else None
            next_t = nxt["t"] if nxt else None
            if not prev and looped and n > 2:
                prev, prev_t = lst[n - 2], lst[n - 2]["t"] - length
            if not nxt and looped and n > 2:
                nxt, next_t = lst[1], lst[1]["t"] + length
            m = [0.0] * 6
            if prev and nxt:
                h0, h1 = k["t"] - prev_t, next_t - k["t"]
                if h0 > 1e-6 and h1 > 1e-6:
                    for c in range(6):
                        d0 = (k["v"][c] - prev["v"][c]) / h0
                        d1 = (nxt["v"][c] - k["v"][c]) / h1
                        if d0 * d1 > 0:
                            w1, w2 = 2 * h1 + h0, h1 + 2 * h0
                            m[c] = (w1 + w2) / (w1 / d0 + w2 / d1)
            k["m"] = m
    return tracks


def sample_track(lst, t):
    if t <= lst[0]["t"]:
        return list(lst[0]["v"])
    for i in range(len(lst) - 1):
        a, b = lst[i], lst[i + 1]
        if t < b["t"]:
            h = b["t"] - a["t"]
            s = (t - a["t"]) / h
            s2, s3 = s * s, s * s * s
            h00 = 2 * s3 - 3 * s2 + 1
            h10 = s3 - 2 * s2 + s
            h01 = -2 * s3 + 3 * s2
            h11 = s3 - s2
            return [h00 * a["v"][c] + h10 * h * a["m"][c] + h01 * b["v"][c] + h11 * h * b["m"][c] for c in range(6)]
    return list(lst[-1]["v"])


def detail(clip, springs, fps=60):
    tracks = joint_tracks(clip)
    length = clip["length"]
    seen, times = set(), []

    def add(t):
        k = math.floor(t * 10000 + 0.5)
        if k not in seen:
            seen.add(k)
            times.append(k / 10000)

    for i in range(int(math.floor(length * fps)) + 1):
        add(i / fps)
    for key in clip["keys"]:
        add(key["t"])
    for t in (clip.get("markers") or {}).values():
        add(t)
    add(length)
    times.sort()

    state = {}
    for j, (freq, damp) in springs.items():
        if j in tracks:
            state[j] = {"x": sample_track(tracks[j], 0), "v": [0.0] * 6, "w": freq * 2 * math.pi, "z": damp}
    h = 1 / 480
    clock = [-length if clip.get("looped") else 0.0]

    def advance(to):
        while clock[0] < to - 1e-9:
            step = min(h, to - clock[0])
            clock[0] += step
            t = clock[0] % length if clip.get("looped") else min(max(clock[0], 0), length)
            for j, sp in state.items():
                target = sample_track(tracks[j], t)
                for c in range(6):
                    acc = sp["w"] * sp["w"] * (target[c] - sp["x"][c]) - 2 * sp["z"] * sp["w"] * sp["v"][c]
                    sp["v"][c] += acc * step
                    sp["x"][c] += sp["v"][c] * step

    keys = []
    for t in times:
        advance(t)
        p = {}
        for j, lst in tracks.items():
            exact = sample_track(lst, t)
            sp = state.get(j)
            if sp:
                blend = 0 if clip.get("looped") else min(max((t - (length - 0.12)) / 0.12, 0), 1) ** 2
                p[j] = [sp["x"][c] + (exact[c] - sp["x"][c]) * blend for c in range(6)]
            else:
                p[j] = exact
        keys.append({"t": t, "pose": p})
    out = dict(clip)
    out["keys"] = keys
    return out


def stagger(clip, delays, step=1 / 120):
    """Per-joint delay (negative leads), linear resample (KatanaSkillAnimations.stagger)."""
    keys = clip["keys"]
    length = clip["length"]
    tail = max([0.0] + [d for d in delays.values()])

    def sample(j, t):
        t = min(max(t, 0), length)
        lo, hi = 0, len(keys) - 1
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if keys[mid]["t"] <= t:
                lo = mid
            else:
                hi = mid
        a, b = keys[lo], keys[hi]
        va, vb = a["pose"].get(j), b["pose"].get(j)
        alpha = min(max((t - a["t"]) / (b["t"] - a["t"]), 0), 1) if b["t"] > a["t"] else 0
        return [va[c] + (vb[c] - va[c]) * alpha for c in range(6)]

    total = length + tail
    out = []
    n = math.ceil(total / step)
    for i in range(n + 1):
        t = min(i * step, total)
        out.append({"t": t, "pose": {j: sample(j, t - delays.get(j, 0)) for j in keys[0]["pose"]}})
    res = dict(clip)
    res["keys"] = out
    res["length"] = total
    return res


def sample_pose(clip, t):
    """Linear sampling of a baked clip (PoseAnimator lerps between dense keys)."""
    keys = clip["keys"]
    t = min(max(t, 0), keys[-1]["t"])
    lo, hi = 0, len(keys) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if keys[mid]["t"] <= t:
            lo = mid
        else:
            hi = mid
    a, b = keys[lo], keys[hi]
    alpha = (t - a["t"]) / (b["t"] - a["t"]) if b["t"] > a["t"] else 0
    return {j: [a["pose"][j][c] + (b["pose"][j][c] - a["pose"][j][c]) * alpha for c in range(6)] for j in a["pose"]}

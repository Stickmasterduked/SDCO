"""Lists the biggest joint rotations between consecutive keys.

Interpolation takes the short way round, so a step near 180 degrees can
swing a limb the wrong way (e.g. an arm going back over the head instead of
forward). Anything over ~165 needs an extra guide key.

    LUAU=/path/to/luau python3 tools/steps.py [names...]
"""
import math, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import preview  # noqa: E402

anims = preview.load()
names = sys.argv[1:] or sorted(anims)
rows = []
for name in names:
    clip = preview.compile_clip(anims[name])
    for joint, keys in clip.items():
        for a, b in zip(keys, keys[1:]):
            R = a[1].R.T @ b[1].R
            angle = math.degrees(math.acos(max(-1, min(1, (np.trace(R) - 1) / 2))))
            rows.append((angle, name, joint, a[0], b[0]))
rows.sort(reverse=True)
for angle, name, joint, t0, t1 in rows[:12]:
    flag = "  <-- needs a guide key" if angle > 165 else ""
    print(f"{angle:6.1f} deg  {name:<14} {joint:<9} {t0:.3f} -> {t1:.3f}{flag}")

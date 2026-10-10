"""Pose contact sheets: each move sampled through its keys from two angles,
with the dash's root motion. `python3 posecheck.py` -> previews/poses_*.png"""
import math
import os

import numpy as np

import anim
import bake
import cf
import motionprofile
import render
import rig

OUT = os.path.join(rig.ROOT, "previews")
RUSH_TARGET = 20.0
RUSH_STOP = 5.2
RUSH_DURATION = 0.3


def rush_root(clip, t, target_distance=RUSH_TARGET):
    start = clip["markers"]["Dash"]
    dist = max(4.0, target_distance - RUSH_STOP)
    u = (t - start) / RUSH_DURATION
    return cf.new(0, 3, -dist * motionprofile.fraction(u))


def root_for(name, clip, t):
    if name == "Katana_Rush":
        return rush_root(clip, t)
    return cf.new(0, 3, 0)


def target_for(name):
    return cf.new(0, 3, -RUSH_TARGET if name == "Katana_Rush" else -26) @ cf.ry(math.pi)


def main():
    grip = rig.load_grip()
    clips = anim.load_clips()
    idle = anim.idle_pose()
    os.makedirs(OUT, exist_ok=True)
    for name, clip in clips.items():
        times = [k["t"] for k in clip["source"]["keys"]]
        imgs = []
        for t in times:
            pose = bake.sample_pose(clip, t)
            root = root_for(name, clip, t)
            p = cf.pos(root)
            for eye in ((p[0] + 8.5, 4.5, p[2] + 2.0), (p[0] + 5.5, 6.5, p[2] + 9.5)):
                cam = render.Camera(eye, (p[0], 2.2, p[2] - 1.5), fov=60)
                fr = render.Frame(cam)
                fr.rig(idle, target_for(name), None, palette="target")
                fr.rig(pose, root, grip)
                marks = [m for m, mt in clip["markers"].items() if abs(mt - t) < 1e-3]
                fr.label(f"{name} t={t:.3f} {' '.join(marks)}")
                imgs.append(fr.render())
        render.sheet(imgs, 6, 0.5).save(os.path.join(OUT, f"poses_{name}.png"))
        print("wrote", f"poses_{name}.png", len(imgs))


if __name__ == "__main__":
    main()

"""Loads the generated skill poses and bakes them like the game does."""
import os

import bake
import luatable
import rig

SKILL_POSES = os.path.join(rig.ROOT, "src/ReplicatedStorage/Combat/KatanaSkillAnimations/KatanaSkillPoses.luau")

# keep in sync with KatanaSkillAnimations/init.luau
DELAYS = {"Torso": 0, "RightArm": 0, "LeftArm": 0, "Katana": 0, "RightLeg": 0.012, "LeftLeg": 0.02, "Head": 0.035}
SPRINGS = {"Head": (6, 0.38), "RightLeg": (9, 0.5), "LeftLeg": (9, 0.5)}
FPS = 120


def load_clips():
    raw = luatable.load(SKILL_POSES)
    clips = {}
    for name, c in raw.items():
        clip = {"length": c["length"], "recover": c["recover"], "markers": dict(c["markers"]),
                "keys": [{"t": k["t"], "pose": k["pose"]} for k in c["keys"]]}
        clips[name] = bake.stagger(bake.detail(clip, SPRINGS, FPS), DELAYS)
        clips[name]["source"] = c
    return clips


def idle_pose():
    return {j: list(v) + [0] * (6 - len(v)) for j, v in luatable.load(rig.POSES_PATH)["Katana_Idle"]["keys"][0]["pose"].items()}

"""Runs tools/validate.luau against the current sources.

    LUAU=/path/to/luau python3 tools/check.py
"""
import os, shutil, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
COMBAT = os.path.join(ROOT, "src", "ReplicatedStorage", "Combat")
LUAU = os.environ.get("LUAU", "luau")

# Config builds one Vector3; a local stub is enough for it to load outside Roblox.
STUB = "local Vector3 = { new = function(x, y, z) return { X = x, Y = y, Z = z } end }\n"

with tempfile.TemporaryDirectory() as tmp:
    shutil.copy(os.path.join(COMBAT, "AnimationData.luau"), tmp)
    with open(os.path.join(COMBAT, "Config.luau")) as f:
        config = f.read()
    with open(os.path.join(tmp, "Config.luau"), "w") as f:
        f.write(STUB + config)
    shutil.copy(os.path.join(ROOT, "tools", "validate.luau"), tmp)
    sys.exit(subprocess.call([LUAU, os.path.join(tmp, "validate.luau")]))

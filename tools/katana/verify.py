"""Checks that the game will play what the previews show.

    LUAU_DIR=/path/to/luau/bin python3 tools/katana/verify.py

1. Compiles every script the katana skills touch (luau-compile).
2. Runs the real AnimationData under Luau (with a tiny CFrame/Vector3 mock and
   a stub HeadDrive) and compares every baked key of Katana_Rush and
   Katana_Crescent against the Python bake the previews use.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import anim
import rig

LUAU_DIR = os.environ.get("LUAU_DIR", "")
LUAU = os.path.join(LUAU_DIR, "luau") if LUAU_DIR else "luau"
COMPILE = os.path.join(LUAU_DIR, "luau-compile") if LUAU_DIR else "luau-compile"
SRC = os.path.join(rig.ROOT, "src")
C = os.path.join(SRC, "ReplicatedStorage", "Combat")
TOUCHED = [
    "ReplicatedStorage/Combat/Config.luau",
    "ReplicatedStorage/Combat/Motion.luau",
    "ReplicatedStorage/Combat/AnimationData.luau",
    "ReplicatedStorage/Combat/KatanaSkillAnimations/init.luau",
    "ReplicatedStorage/Combat/KatanaSkillAnimations/KatanaSkillPoses.luau",
    "ReplicatedStorage/Combat/KatanaFX/init.luau",
    "ReplicatedStorage/Combat/KatanaFX/KatanaFXData.luau",
    "ServerScriptService/CombatService.luau",
    "ServerScriptService/CombatServer.server.luau",
    "StarterPlayerScripts/CombatClient.client.luau",
]
PRELUDE = 'local __rbx = require("./rbx"); local Vector3, CFrame = __rbx.Vector3, __rbx.CFrame\n'
DUMP = '''
local Data = require("./AnimationData")
local out = {}
for _, name in ipairs({ "Katana_Rush", "Katana_Crescent" }) do
	local c = Data[name]
	local keys = {}
	for _, key in ipairs(c.keys) do
		local p = {}
		for joint, v in pairs(key.pose) do
			p[joint] = { v[1], v[2], v[3], v[4] or 0, v[5] or 0, v[6] or 0 }
		end
		table.insert(keys, { t = key.t, pose = p })
	end
	out[name] = { length = c.length, recover = c.recover, keys = keys }
end
-- crude JSON
local function enc(v)
	if type(v) == "table" then
		if #v > 0 or next(v) == nil then
			local parts = {}
			for _, x in ipairs(v) do table.insert(parts, enc(x)) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		for k, x in pairs(v) do table.insert(parts, string.format("%q:%s", k, enc(x))) end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	if type(v) == "number" then return string.format("%.9g", v) end
	return tostring(v)
end
print(enc(out))
'''


def harness(tmp):
    def conv(src, dst, prelude=""):
        s = open(src, encoding="utf8").read()
        s = re.sub(r"require\(script\.Parent\.(\w+)\)", r'require("./\1")', s)
        s = re.sub(r"require\(script\.(\w+)\)", r'require("./\1")', s)
        open(dst, "w", encoding="utf8").write(prelude + s)

    conv(os.path.join(C, "Config.luau"), os.path.join(tmp, "Config.luau"), PRELUDE)
    conv(os.path.join(C, "AnimationData.luau"), os.path.join(tmp, "AnimationData.luau"), PRELUDE)
    for folder in ("KatanaAnimations", "KatanaSkillAnimations"):
        conv(os.path.join(C, folder, "init.luau"), os.path.join(tmp, folder + ".luau"))
        for f in os.listdir(os.path.join(C, folder)):
            if f != "init.luau":
                conv(os.path.join(C, folder, f), os.path.join(tmp, f))
    shutil.copy(os.path.join(os.path.dirname(__file__), "harness", "rbx.luau"), tmp)
    # AnimationData only reads HeadDrive's timings
    open(os.path.join(tmp, "HeadDrive.luau"), "w").write(
        "return { T = { GRAB_AT = 0.25, LIFT = 0.35, SLAM = 0.5, DRAG_START = 0.6, DRAG_END = 1.4, LIFT_END = 1.55, "
        "SLAM_SECOND = 1.7, LIFT_SECOND = 1.85, IMPACT = 2.0, LAND = 2.2, ATTACKER_FREE = 2.4, LENGTH = 2.6 } }\n")
    open(os.path.join(tmp, "dump.luau"), "w").write(DUMP)


def main():
    ok = True
    for path in TOUCHED:
        r = subprocess.run([COMPILE, "--null", os.path.join(SRC, path)], capture_output=True, text=True)
        print(("compiles  " if r.returncode == 0 else "FAILS     ") + path)
        if r.returncode != 0:
            print(r.stderr or r.stdout)
            ok = False
    with tempfile.TemporaryDirectory() as tmp:
        harness(tmp)
        r = subprocess.run([LUAU, "dump.luau"], cwd=tmp, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr or r.stdout)
            sys.exit(1)
        game = json.loads(r.stdout)
    py = anim.load_clips()
    for name, g in game.items():
        p = py[name]
        worst = 0.0
        assert len(g["keys"]) == len(p["keys"]), (name, len(g["keys"]), len(p["keys"]))
        for gk, pk in zip(g["keys"], p["keys"]):
            worst = max(worst, abs(gk["t"] - pk["t"]))
            for joint, gv in gk["pose"].items():
                pv = pk["pose"][joint]
                worst = max(worst, max(abs(a - b) for a, b in zip(gv, pv)))
        good = worst < 1e-3 and abs(g["length"] - p["length"]) < 1e-6
        ok &= good
        print(f"{'matches  ' if good else 'DIFFERS  '}{name}: {len(g['keys'])} keys, worst difference {worst:.2e}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

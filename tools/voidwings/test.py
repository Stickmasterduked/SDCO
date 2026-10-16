"""Checks the Void Wings Luau against the Python reference, under plain Luau
with mocked Roblox types:

  1. the rig (VoidWings/init.luau) puts every feather exactly where
     preview.py's feather_cframes() does, on both wings, at several times;
  2. the right and left wings are mirror images (no pinwheel);
  3. the right wing's Back face uses the right-wing atlas, the left wing's
     Back face the left-wing atlas, and the sprite frame stepping matches;
  4. the installer runs against a mock Studio tree and keeps uploaded ids.

    LUAU=path/to/luau python3 tools/voidwings/test.py
"""
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout as L  # noqa: E402
import preview  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
COS = os.path.join(ROOT, "src", "ReplicatedStorage", "Cosmetics")

MOCKS = r'''
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, Vector3Meta) end
Vector3Meta = {
	__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end,
	__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end,
	__mul = function(a, b)
		if type(a) == "number" then a, b = b, a end
		return vec(a.X * b, a.Y * b, a.Z * b)
	end,
	__index = function(v, k) if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end end,
}
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }
Vector3.zero = vec(0, 0, 0)

local CFrameMeta = {}
local function cf(m) return setmetatable({ m = m }, CFrameMeta) end
local function matmul(a, b)
	local r = {}
	for i = 0, 3 do for j = 0, 3 do
		local s = 0
		for k = 0, 3 do s += a[i * 4 + k + 1] * b[k * 4 + j + 1] end
		r[i * 4 + j + 1] = s
	end end
	return r
end
CFrameMeta.__mul = function(a, b)
	if getmetatable(b) == CFrameMeta then return cf(matmul(a.m, b.m)) end
	local m = a.m
	return vec(m[1] * b.X + m[2] * b.Y + m[3] * b.Z + m[4], m[5] * b.X + m[6] * b.Y + m[7] * b.Z + m[8], m[9] * b.X + m[10] * b.Y + m[11] * b.Z + m[12])
end
CFrameMeta.__index = function(c, k)
	if k == "Position" then return vec(c.m[4], c.m[8], c.m[12]) end
end
local function rot(axis, a)
	local c, s = math.cos(a), math.sin(a)
	if axis == "x" then return { 1, 0, 0, 0, 0, c, -s, 0, 0, s, c, 0, 0, 0, 0, 1 } end
	if axis == "y" then return { c, 0, s, 0, 0, 1, 0, 0, -s, 0, c, 0, 0, 0, 0, 1 } end
	return { c, -s, 0, 0, s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 }
end
CFrame = {
	new = function(x, y, z) return cf({ 1, 0, 0, x or 0, 0, 1, 0, y or 0, 0, 0, 1, z or 0, 0, 0, 0, 1 }) end,
	Angles = function(rx, ry, rz) return cf(matmul(matmul(rot("x", rx), rot("y", ry)), rot("z", rz))) end,
	lookAt = function() return CFrame.new() end,
}

local dummy = function() return {} end
Color3 = { new = dummy, fromRGB = dummy }
ColorSequence = { new = dummy }
NumberSequence = { new = dummy }
NumberSequenceKeypoint = { new = dummy }
NumberRange = { new = dummy }
Vector2 = { new = dummy }
UDim = { new = dummy }
UDim2 = { new = dummy }
Enum = setmetatable({}, { __index = function(_, e)
	return setmetatable({}, { __index = function(_, v) return { Name = v, EnumType = e } end })
end })

local InstanceMeta = {}
InstanceMeta.__index = function(self, k)
	local methods = rawget(InstanceMeta, "methods")
	if methods[k] then return methods[k] end
	local props = rawget(self, "_props")
	if props[k] ~= nil then return props[k] end
	for _, child in ipairs(rawget(self, "_children")) do
		if child.Name == k then return child end
	end
	return nil
end
InstanceMeta.__newindex = function(self, k, v)
	local props = rawget(self, "_props")
	if k == "Parent" then
		local old = props.Parent
		if old then
			local list = rawget(old, "_children")
			local i = table.find(list, self)
			if i then table.remove(list, i) end
		end
		if v then table.insert(rawget(v, "_children"), self) end
	end
	props[k] = v
end
InstanceMeta.methods = {
	FindFirstChild = function(self, name)
		for _, c in ipairs(rawget(self, "_children")) do if c.Name == name then return c end end
		return nil
	end,
	FindFirstChildOfClass = function(self, class)
		for _, c in ipairs(rawget(self, "_children")) do if c.ClassName == class then return c end end
		return nil
	end,
	WaitForChild = function(self, name) return self:FindFirstChild(name) end,
	GetChildren = function(self) return table.clone(rawget(self, "_children")) end,
	GetDescendants = function(self)
		local out = {}
		local function walk(i) for _, c in ipairs(rawget(i, "_children")) do table.insert(out, c); walk(c) end end
		walk(self)
		return out
	end,
	IsA = function(self, class)
		local c = self.ClassName
		if c == class then return true end
		if class == "BasePart" then return c == "Part" end
		if class == "BaseScript" then return c == "Script" or c == "LocalScript" end
		return false
	end,
	Destroy = function(self) self.Parent = nil; self._destroyed = true end,
	GetFullName = function(self)
		local p = rawget(self, "_props").Parent
		return (p and p:GetFullName() .. "." or "") .. self.Name
	end,
}
function newInstance(class, name)
	local self = setmetatable({ _props = { ClassName = class, Name = name or class }, _children = {} }, InstanceMeta)
	return self
end
Instance = { new = newInstance }

-- load a ModuleScript-like file with `script` bound to a mock instance
function loadModule(path, scriptInstance)
	local f = assert(SOURCES[path], path)
	local fn = assert(loadstring(f, path))
	local env = setmetatable({ script = scriptInstance }, { __index = getfenv(1) })
	setfenv(fn, env)
	return fn()
end
'''

RIG_TEST = r'''
local rigScript = newInstance("ModuleScript", "VoidWings")
local dataScript = newInstance("ModuleScript", "VoidWingsData")
dataScript.Parent = rigScript
local assetsScript = newInstance("ModuleScript", "VoidWingsAssets")
assetsScript.Parent = rigScript
local data = loadModule(COS .. "/VoidWings/VoidWingsData.luau", dataScript)
local assets = loadModule(COS .. "/VoidWings/VoidWingsAssets.luau", assetsScript)
for a = 0, 3 do
	assets["FeatherR_" .. a] = "rbxassetid://" .. (100 + a)
	assets["FeatherL_" .. a] = "rbxassetid://" .. (200 + a)
end
-- the module requires its children by instance; hand back the loaded tables
local realRequire = require
require = function(m)
	if m == dataScript then return data end
	if m == assetsScript then return assets end
	return realRequire(m)
end
local VoidWings = loadModule(COS .. "/VoidWings/init.luau", rigScript)

local torso = newInstance("Part", "Torso")
torso.CFrame = CFrame.new(0, 0, 0)
local character = newInstance("Model", "Character")
torso.Parent = character
local rig = VoidWings.new(torso, { Viewport = true })
rig.TimeOffset = 0

local out = {}
for _, t in ipairs(TIMES) do
	rig:Step(t)
	local frame = {}
	for _, f in ipairs(rig.Feathers) do
		local m = f.Part.CFrame.m
		table.insert(frame, string.format('{"side":%d,"i":%d,"m":[%s],"back":"%s","front":"%s","u":%.5f,"v":%.5f,"su":%.5f}',
			f.Side, f.Index, table.concat(m, ","), f.Back.Texture, f.Front.Texture,
			f.Back.OffsetStudsU, f.Back.OffsetStudsV, f.Back.StudsPerTileU))
	end
	table.insert(out, "[" .. table.concat(frame, ",") .. "]")
end
print("RESULT[" .. table.concat(out, ",") .. "]")
'''

INSTALL_TEST = r'''
local services = {}
for _, name in ipairs({ "ChangeHistoryService", "ReplicatedStorage", "ServerScriptService", "StarterPlayer" }) do
	services[name] = newInstance(name, name)
end
local sps = newInstance("StarterPlayerScripts", "StarterPlayerScripts")
sps.Parent = services.StarterPlayer
services.ChangeHistoryService.TryBeginRecording = function() return "rec" end
services.ChangeHistoryService.FinishRecording = function() end
game = { GetService = function(_, name) return services[name] end }

-- a place that already has the wings with two uploaded ids
local cos = newInstance("Folder", "Cosmetics")
cos.Parent = services.ReplicatedStorage
local rig = newInstance("ModuleScript", "VoidWings")
rig.Parent = cos
local old = newInstance("ModuleScript", "VoidWingsAssets")
old.Source = 'return {\n\tFeatherR_0 = "rbxassetid://111",\n\tWisp = "rbxassetid://999",\n\tFrameFlipV = true,\n}'
old.Parent = rig

local src = assert(SOURCES[INSTALLER])
local fn = assert(loadstring(src, "installer"))
local printed = {}
local env = setmetatable({ game = game, print = function(s) table.insert(printed, s) end }, { __index = getfenv(1) })
setfenv(fn, env)
fn()

local function must(cond, msg) if not cond then error("installer: " .. msg) end end
local cosmetics = services.ReplicatedStorage:FindFirstChild("Cosmetics")
must(cosmetics == cos, "reuses Cosmetics folder")
for _, n in ipairs({ "Items", "VoidWings", "Preview" }) do must(cosmetics:FindFirstChild(n), n .. " missing") end
must(rig.Source and #rig.Source > 1000, "rig source written into the existing VoidWings")
local assets = rig:FindFirstChild("VoidWingsAssets")
must(assets == old, "assets module reused")
must(string.find(assets.Source, 'FeatherR_0 = "rbxassetid://111"', 1, true), "kept FeatherR_0 id")
must(string.find(assets.Source, 'Wisp = "rbxassetid://999"', 1, true), "kept Wisp id")
must(string.find(assets.Source, 'FeatherL_0 = ""', 1, true), "left others empty")
must(string.find(assets.Source, "FrameFlipV = true", 1, true), "kept FrameFlipV")
must(string.find(assets.Source, "FrameFlipU = false", 1, true), "FrameFlipU untouched")
must(rig:FindFirstChild("VoidWingsData"), "data module")
must(services.ServerScriptService:FindFirstChild("CosmeticsServer").ClassName == "Script", "server script")
must(sps:FindFirstChild("CosmeticsClient").ClassName == "LocalScript", "client script")
must(services.ReplicatedStorage:FindFirstChild("CosmeticsRemote"), "remote")
print("INSTALL_OK")
'''


def run_luau(code):
    luau = os.environ.get("LUAU", "luau")
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as f:
        f.write(code)
        path = f.name
    try:
        res = subprocess.run([luau, path], capture_output=True, text=True, timeout=120)
    finally:
        os.unlink(path)
    if res.returncode != 0:
        sys.exit(f"luau failed:\n{res.stdout}\n{res.stderr}")
    return res.stdout


def main():
    times = [0.0, 0.37, 1.1, 2.9]
    installer = os.path.join(ROOT, "install", "InstallVoidWings.lua")
    head = f'COS = "{COS}"\nINSTALLER = "{installer}"\nTIMES = {{ {", ".join(map(str, times))} }}\nSOURCES = {{}}\n'
    # the Luau CLI has no io library, so hand the sources over inline
    for path in [os.path.join(COS, "VoidWings", n) for n in ("VoidWingsData.luau", "VoidWingsAssets.luau", "init.luau")] + [installer]:
        with open(path) as f:
            text = f.read()
        eq = "=" * 8
        assert f"]{eq}]" not in text
        head += f'SOURCES["{path}"] = [{eq}[\n{text}]{eq}]\n'
    out = run_luau(head + MOCKS + RIG_TEST)
    line = next(ln for ln in out.splitlines() if ln.startswith("RESULT"))
    frames = json.loads(line[len("RESULT"):])
    fails = 0
    for t, feathers in zip(times, frames):
        ref = preview.feather_cframes(t)
        assert len(ref) == len(feathers), "feather count"
        for (side, fe, m_ref, (w, h)), got in zip(ref, feathers):
            m = np.array(got["m"]).reshape(4, 4)
            err = np.abs(m - m_ref).max()
            # VoidWingsData rounds to 4 decimals, so allow ~1e-3 studs
            if err > 1e-3 or got["side"] != side:
                fails += 1
                print(f"t={t} side={side} feather {got['i']}: max error {err:.2e}")
            # textures: right Back = R atlas (ids 100+), left Back = L atlas (200+)
            k = (int(np.floor(t * L.FPS)) + fe["frame"]) % L.FRAMES
            atlas, col, row = L.frame_cell(k)
            back_id = (100 if side == 1 else 200) + atlas
            front_id = (200 if side == 1 else 100) + atlas
            if got["back"] != f"rbxassetid://{back_id}" or got["front"] != f"rbxassetid://{front_id}":
                fails += 1
                print(f"t={t} side={side} feather {got['i']}: textures {got['back']} / {got['front']}, want {back_id} / {front_id}")
            if abs(got["u"] - col * w) > 1e-4 or abs(got["v"] - row * h) > 1e-4 or abs(got["su"] - 2 * w) > 1e-4:
                fails += 1
                print(f"t={t} feather {got['i']}: frame offsets wrong")

        # mirror symmetry: left feather = right feather reflected in x
        n = len(L.FEATHERS)
        flip = np.diag([-1, 1, 1, 1])
        for i in range(n):
            right = np.array(feathers[i]["m"]).reshape(4, 4)
            left = np.array(feathers[n + i]["m"]).reshape(4, 4)
            mirrored = flip @ right @ flip
            if np.abs(mirrored - left).max() > 1e-6:
                fails += 1
                print(f"t={t} feather {i + 1}: wings are not mirror images")
    print(f"rig: {sum(len(f) for f in frames)} feather poses checked against preview.py")

    out = run_luau(head + MOCKS + INSTALL_TEST)
    if "INSTALL_OK" not in out:
        fails += 1
        print(out)
    else:
        print("installer: ok")
    if fails:
        sys.exit(f"{fails} failures")
    print("all good")


if __name__ == "__main__":
    main()

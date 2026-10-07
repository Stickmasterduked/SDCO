"""Runs install/InstallCombat.lua against a mock of Studio's object tree and
checks every script lands in the right place with exactly the source in src/.

    LUAU=/path/to/luau python3 tools/test_installer.py
"""
import os, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
LUAU = os.environ.get("LUAU", "luau")

MOCK = r'''
local CLASSES = {
	Script = { "BaseScript", "LuaSourceContainer" },
	LocalScript = { "Script", "BaseScript", "LuaSourceContainer" },
	ModuleScript = { "LuaSourceContainer" },
}
local Inst = {}
local function new(className, name)
	local self = { _props = { ClassName = className, Name = name or className }, _children = {} }
	return setmetatable(self, Inst)
end
Inst.__index = function(self, key)
	local method = rawget(Inst, key)
	if method then
		return method
	end
	return rawget(self, "_props")[key]
end
Inst.__newindex = function(self, key, value)
	local props = rawget(self, "_props")
	if key == "Parent" then
		local old = props.Parent
		if old then
			local list = rawget(old, "_children")
			for i, child in ipairs(list) do
				if child == self then
					table.remove(list, i)
					break
				end
			end
		end
		if value then
			table.insert(rawget(value, "_children"), self)
		end
	end
	props[key] = value
end
function Inst:IsA(className)
	if self.ClassName == className then
		return true
	end
	for _, base in ipairs(CLASSES[self.ClassName] or {}) do
		if base == className then
			return true
		end
	end
	return false
end
function Inst:GetChildren()
	return table.clone(rawget(self, "_children"))
end
function Inst:FindFirstChild(name, recursive)
	for _, child in ipairs(rawget(self, "_children")) do
		if child.Name == name then
			return child
		end
	end
	if recursive then
		for _, child in ipairs(rawget(self, "_children")) do
			local found = child:FindFirstChild(name, true)
			if found then
				return found
			end
		end
	end
	return nil
end
function Inst:FindFirstChildOfClass(className)
	for _, child in ipairs(rawget(self, "_children")) do
		if child.ClassName == className then
			return child
		end
	end
	return nil
end
function Inst:WaitForChild(name)
	return assert(self:FindFirstChild(name), "WaitForChild would hang: " .. name)
end
function Inst:Destroy()
	self.Parent = nil
end
function Inst:GetFullName()
	local names, node = {}, self
	while node and node.ClassName ~= "DataModel" do
		table.insert(names, 1, node.Name)
		node = node.Parent
	end
	return table.concat(names, ".")
end

local game = new("DataModel", "Game")
local services = {}
for _, n in ipairs({ "ReplicatedStorage", "ServerScriptService", "StarterPlayer", "ChangeHistoryService" }) do
	services[n] = new(n, n)
	services[n].Parent = game
end
local sps = new("StarterPlayerScripts", "StarterPlayerScripts")
sps.Parent = services.StarterPlayer
function services.ChangeHistoryService:TryBeginRecording()
	return "rec"
end
function services.ChangeHistoryService:FinishRecording() end
function game:GetService(name)
	return services[name]
end
local Instance = { new = function(className)
	return new(className)
end }
local Enum = { FinishRecordingOperation = { Commit = "Commit" } }

-- SCENARIO
'''

EXISTING = r'''
-- the user's layout: server scripts in a folder, client in StarterPlayerScripts
local combat = new("Folder", "Combat")
combat.Parent = services.ReplicatedStorage
local remotes = new("Folder", "Remotes")
remotes.Parent = combat
for _, n in ipairs({ "Ack", "Action", "Anim", "Effect", "Impulse" }) do
	new("RemoteEvent", n).Parent = remotes
end
for _, n in ipairs({ "AnimationBuilder", "AnimationData", "Config", "Effects", "HUD", "Motion", "PoseAnimator" }) do
	local m = new("ModuleScript", n)
	m.Source = "-- old"
	m.Parent = combat
end
local serverFolder = new("Folder", "CombatServerFolder")
serverFolder.Parent = services.ServerScriptService
for _, n in ipairs({ "CombatService" }) do
	new("ModuleScript", n).Parent = serverFolder
end
local server = new("Script", "CombatServer")
server.RunContext = "Legacy"
server.Parent = serverFolder
new("Script", "Dummies").Parent = serverFolder
local client = new("LocalScript", "CombatClient")
client.Parent = sps
'''

FRESH = "-- empty place\n"

REPORT = r'''
-- REPORT
local function dump(node, depth)
	for _, child in ipairs(child_sort(node:GetChildren())) do
		print(string.rep("  ", depth) .. child.ClassName .. " " .. child.Name)
		if child.Source then
			print("@@SOURCE " .. child:GetFullName() .. " " .. #child.Source)
		end
		dump(child, depth + 1)
	end
end
function child_sort(list)
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end
dump(game, 0)
_G_sources = nil
'''

EXPECT = {
    "existing": {
        "ReplicatedStorage.Combat.AnimationBuilder": "ReplicatedStorage/Combat/AnimationBuilder.luau",
        "ReplicatedStorage.Combat.AnimationData": "ReplicatedStorage/Combat/AnimationData.luau",
        "ReplicatedStorage.Combat.CameraFX": "ReplicatedStorage/Combat/CameraFX.luau",
        "ReplicatedStorage.Combat.Config": "ReplicatedStorage/Combat/Config.luau",
        "ReplicatedStorage.Combat.Effects": "ReplicatedStorage/Combat/Effects.luau",
        "ReplicatedStorage.Combat.Motion": "ReplicatedStorage/Combat/Motion.luau",
        "ReplicatedStorage.Combat.PoseAnimator": "ReplicatedStorage/Combat/PoseAnimator.luau",
        "ServerScriptService.CombatServerFolder.CombatService": "ServerScriptService/CombatService.luau",
        "ServerScriptService.CombatServerFolder.CombatServer": "ServerScriptService/CombatServer.server.luau",
        "StarterPlayer.StarterPlayerScripts.CombatClient": "StarterPlayerScripts/CombatClient.client.luau",
    },
}
EXPECT["fresh"] = {k.replace("CombatServerFolder.", ""): v for k, v in EXPECT["existing"].items()}


def run(name, scenario):
    with open(os.path.join(ROOT, "install", "InstallCombat.lua")) as f:
        installer = f.read()
    # Expose each written Source in the report by checksum-free exact compare:
    # the report prints lengths; the full text is compared by re-reading
    # SOURCES through a second print pass below.
    compare = "\nfor n, s in pairs(SOURCES) do print('@@BEGIN ' .. n) print(s) print('@@END ' .. n) end\n"
    code = MOCK + scenario + installer + REPORT + compare
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "run.luau")
        with open(path, "w") as f:
            f.write(code)
        out = subprocess.run([LUAU, path], capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stdout[-2000:], out.stderr)
        sys.exit(f"{name}: installer errored")
    lines = out.stdout.split("\n")
    written = {}
    for line in lines:
        if line.startswith("@@SOURCE "):
            _, full, length = line.split(" ")
            written[full] = int(length)
    embedded, current = {}, None
    for line in lines:
        if line.startswith("@@BEGIN "):
            current, buf = line[8:], []
        elif line.startswith("@@END "):
            embedded[current] = "\n".join(buf) + "\n"
            current = None
        elif current is not None:
            buf.append(line)
    ok = True
    for full, rel in EXPECT[name].items():
        with open(os.path.join(ROOT, "src", rel)) as f:
            text = f.read()
        short = full.rsplit(".", 1)[1]
        # print() adds one trailing newline after the source's own
        if embedded.get(short) != text + "\n":
            ok = False
            print(f"{name}: embedded source for {short} differs from src/{rel}")
        if written.get(full) != len(text):
            ok = False
            print(f"{name}: {full} has {written.get(full)} chars, expected {len(text)}")
    tree = []
    for line in lines:
        if line.startswith("@@BEGIN"):
            break
        if line and not line.startswith("@@") and not line.startswith("Combat rework"):
            tree.append(line)
    if any(line.strip().endswith(" HUD") for line in tree if not line.startswith("  removed")):
        ok = False
        print(f"{name}: HUD still present")
    print(f"--- {name} ---")
    print("\n".join(tree))
    return ok


if __name__ == "__main__":
    results = [run("existing", EXISTING), run("fresh", FRESH)]
    if not all(results):
        sys.exit("installer test failed")
    print("installer test passed")

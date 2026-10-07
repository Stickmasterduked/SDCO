-- Sanity checks for AnimationData and Config that a type checker can't do.
-- Run through tools/check.py, which stages the modules next to this file
-- (with a Vector3 stub for Config) and exits non-zero on failure.

local Data = require("./AnimationData")
local Config = require("./Config")

local failures = 0
local function check(ok, message)
	if not ok then
		failures += 1
		print("FAIL: " .. message)
	end
end

local JOINTS = { Torso = true, Head = true, RightArm = true, LeftArm = true, RightLeg = true, LeftLeg = true }
local EASES = { Linear = true, Constant = true, Sine = true, Quad = true, Cubic = true, Quart = true, Quint = true,
	Exponential = true, Circular = true, Back = true, Elastic = true, Bounce = true }
local DIRS = { In = true, Out = true, InOut = true }
local PRIORITIES = { Core = true, Idle = true, Movement = true, MovementOverlay = true, Action = true,
	Action2 = true, Action3 = true, Action4 = true }
local GROUPS = { base = true, hold = true, action = true, react = true, overlay = true }
local LIMBS = { ["Right Arm"] = true, ["Left Arm"] = true, ["Right Leg"] = true, ["Left Leg"] = true }

local count = 0
for name, anim in pairs(Data) do
	count += 1
	local where = "Data." .. name
	check(type(anim.length) == "number" and anim.length > 0, where .. ": bad length")
	check(PRIORITIES[anim.priority or "Action"] ~= nil, where .. ": bad priority " .. tostring(anim.priority))
	check(GROUPS[anim.group] ~= nil, where .. ": bad group " .. tostring(anim.group))
	check(#anim.keys >= 2, where .. ": needs at least two keys")
	check(anim.keys[1].t == 0, where .. ": first key must be at t=0")
	check(math.abs(anim.keys[#anim.keys].t - anim.length) < 1e-6, where .. ": last key must be at t=length")

	local last = {}
	for i, key in ipairs(anim.keys) do
		local kw = where .. " key " .. i
		if i > 1 then
			check(key.t > anim.keys[i - 1].t, kw .. ": keys out of order")
		end
		check(key.ease == nil or EASES[key.ease], kw .. ": bad ease " .. tostring(key.ease))
		check(key.dir == nil or DIRS[key.dir], kw .. ": bad dir " .. tostring(key.dir))
		for joint, value in pairs(key.pose) do
			check(JOINTS[joint] ~= nil, kw .. ": bad joint " .. tostring(joint))
			check(#value == 3 or #value == 6, kw .. ": " .. joint .. " needs 3 or 6 numbers")
			for _, n in ipairs(value) do
				check(type(n) == "number" and n == n, kw .. ": " .. joint .. " has a non-number")
			end
			local prev = last[joint]
			if prev then
				-- quaternion lerp takes the short way round: keep steps under 180
				for axis = 1, 3 do
					local step = math.abs((value[axis] or 0) - (prev[axis] or 0))
					check(step < 175, string.format("%s: %s axis %d jumps %d degrees", kw, joint, axis, step))
				end
			end
			last[joint] = value
		end
	end

	if anim.markers then
		for marker, t in pairs(anim.markers) do
			check(t >= 0 and t <= anim.length, where .. ": marker " .. marker .. " outside the clip")
		end
		if anim.markers.Swing and anim.markers.Hit then
			check(anim.markers.Swing <= anim.markers.Hit, where .. ": Swing after Hit")
		end
	end
	if anim.recover then
		check(anim.markers and anim.markers.Hit and anim.markers.Hit < anim.recover, where .. ": recover before Hit")
		check(anim.recover <= anim.length, where .. ": recover after the clip ends")
	end
	if anim.variants then
		for _, v in ipairs(anim.variants) do
			check(Data[v] ~= nil, where .. ": missing variant " .. v)
		end
	end
	if anim.trail then
		for _, limb in ipairs(anim.trail) do
			check(LIMBS[limb] ~= nil, where .. ": bad trail limb " .. limb)
		end
	end
end

for kind, attack in pairs(Config.Attacks) do
	local where = "Config.Attacks." .. kind
	local anim = Data[attack.anim]
	check(anim ~= nil, where .. ": missing anim " .. tostring(attack.anim))
	if anim then
		check(anim.markers and anim.markers.Hit ~= nil, where .. ": anim has no Hit marker")
		check(anim.recover ~= nil, where .. ": anim has no recover")
		check(anim.group == "action", where .. ": attack anim should be in the action group")
	end
	check(attack.react == nil or Data[attack.react] ~= nil, where .. ": missing react " .. tostring(attack.react))
	check(attack.hitstun and attack.hitstun > 0, where .. ": needs hitstun")
end

for _, list in ipairs({ Config.M1Chain, Config.AirChain }) do
	for _, kind in ipairs(list) do
		check(Config.Attacks[kind] ~= nil, "chain references missing attack " .. kind)
	end
end
check(Config.Attacks.Finisher ~= nil, "Finisher attack missing")
check(#Config.M1Chain + 1 == Config.ComboLength, "ComboLength should be the chain plus the finisher")

-- M1 strings must be true combos: hitstun outlasts the gap to the next hit.
for i, kind in ipairs(Config.M1Chain) do
	local nextKind = Config.M1Chain[i + 1] or "Finisher"
	local attack, a, b = Config.Attacks[kind], Data[Config.Attacks[kind].anim], Data[Config.Attacks[nextKind].anim]
	local gap = (a.recover - a.markers.Hit) + b.markers.Hit
	check(attack.hitstun > gap, string.format("%s -> %s is not a true combo (hitstun %.2f, gap %.2f)", kind, nextKind, attack.hitstun, gap))
end

for kind in pairs(Config.HitStop) do
	check(({ Hit = 1, HeavyHit = 1, Block = 1, Parry = 1, GuardBreak = 1, Slam = 1 })[kind] ~= nil, "unknown HitStop kind " .. kind)
end

print(string.format("%d animations, %d attacks checked, %d failures", count, (function()
	local n = 0
	for _ in pairs(Config.Attacks) do
		n += 1
	end
	return n
end)(), failures))
if failures > 0 then
	error("validation failed")
end

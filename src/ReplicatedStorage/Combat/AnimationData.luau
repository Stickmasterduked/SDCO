--[[
	R6 fighting animations, authored as pose data. PoseAnimator plays them
	directly on the joints (no uploaded assets); AnimationBuilder can export
	any of them as a KeyframeSequence for the Animation Editor.

	Style: battlegrounds-style, deliberately overanimated. Every strike has
	a wind-up, a near-instant snap into the hit, a short hang on the impact
	pose, an overshoot on the way back and a settle into guard. The whole
	body sells each move: hips drop, the torso twists and steps in, the head
	counter-rotates to keep eyes on the target, the off hand chambers.

	Each joint pose is { pitch, yaw, roll, x, y, z } in degrees / studs,
	expressed in the parent part's space at the joint pivot:
	  Torso is relative to HumanoidRootPart, limbs and Head are relative to Torso.
	  pitch +  = limb swings forward/up (Torso: leans back, Head: looks up)
	  yaw   +  = turns left (on a hanging limb: twists it)
	  roll  +  = limb end swings toward +X (right); Torso/Head tilt left
	  x/y/z    = shift right / up / back (Torso translation moves the whole body)
	A limb's world angle is roughly the torso's pitch plus its own, so a torso
	leaning forward 30 needs its legs pitched +30 to stay vertical.

	Keys: `ease`/`dir` shape the curve from that key to the next one. Any
	Roblox EasingStyle works (Back overshoots, Quart/Quint snap, Sine floats).

	group:
	  base    - locomotion (Stance, Walk, Run, Jump, Fall), driven by the client
	  hold    - looping holds (block), stopped explicitly
	  action  - attacks, dashes, feints; replaces other action/react/hold tracks
	  react   - hit reactions and stuns; replaces action/react/hold tracks
	  overlay - plays on top without stopping anything

	holdLast: a non-looping clip that freezes on its last frame until stopped.
	trail:    which limbs get swing trails between the Swing and Hit markers.

	markers become KeyframeMarkers. `Hit` is the impact frame the server uses,
	`recover` is when the attacker can act again.
]]

------------------------------------------------------------------------
-- Shared poses

-- Fighting stance: sitting low on the legs, lead (left) shoulder forward,
-- rear fist at the chin, lead fist out front.
local GUARD = {
	Torso = { -8, -20, 0, 0, -0.2, 0 },
	Head = { 8, 18, 0 },
	RightArm = { 100, 0, -42, 0, 0, 0.1 },
	LeftArm = { 108, 0, 28, 0, 0, -0.05 },
	RightLeg = { 2, 0, 9 },
	LeftLeg = { 24, 0, -5 },
}

-- Crossed arms in front of the face, chin tucked. No legs, so the walk
-- cycle keeps running underneath while blocking.
local BLOCK = {
	Torso = { -12, -6, 0, 0, -0.3, 0 },
	Head = { -10, 4, 0 },
	RightArm = { 118, 0, -58, 0, 0, 0.15 },
	LeftArm = { 112, 0, 52, 0, 0, 0.05 },
}

-- Legs tucked under for air moves.
local AIR_LEGS = {
	RightLeg = { 46, 0, 8 },
	LeftLeg = { 14, 0, -8 },
}

local function pose(...)
	local result = {}
	for _, part in ipairs({ ... }) do
		for joint, value in pairs(part) do
			result[joint] = value
		end
	end
	return result
end

local MIRROR = {
	Torso = "Torso",
	Head = "Head",
	RightArm = "LeftArm",
	LeftArm = "RightArm",
	RightLeg = "LeftLeg",
	LeftLeg = "RightLeg",
}

-- Left/right mirror of a pose.
local function mirror(p)
	local result = {}
	for joint, v in pairs(p) do
		result[MIRROR[joint]] = { v[1], -(v[2] or 0), -(v[3] or 0), -(v[4] or 0), v[5] or 0, v[6] or 0 }
	end
	return result
end

local function mirrorKeys(keys)
	local result = {}
	for i, key in ipairs(keys) do
		result[i] = { t = key.t, ease = key.ease, dir = key.dir, pose = mirror(key.pose) }
	end
	return result
end

------------------------------------------------------------------------
-- Detailing pass
--
-- detail(clip, springs) resamples a clip into dense keyframes (fps per
-- second) and runs the listed joints through damped springs while doing so:
-- they trail the joints that drive them and overshoot when those stop, i.e.
-- overlapping action and follow-through. Unlisted joints (the torso and the
-- striking limb) follow the authored poses exactly, so hit frames stay exact.
-- springs = { Joint = { frequency (Hz), damping ratio } }.

local EASE_IN = {
	Linear = function(t)
		return t
	end,
	Sine = function(t)
		return 1 - math.cos(t * math.pi / 2)
	end,
	Quad = function(t)
		return t * t
	end,
	Cubic = function(t)
		return t ^ 3
	end,
	Quart = function(t)
		return t ^ 4
	end,
	Quint = function(t)
		return t ^ 5
	end,
	Exponential = function(t)
		return t <= 0 and 0 or 2 ^ (10 * t - 10)
	end,
	Circular = function(t)
		return 1 - math.sqrt(math.max(0, 1 - t * t))
	end,
	Back = function(t)
		return 2.70158 * t ^ 3 - 1.70158 * t * t
	end,
	Elastic = function(t)
		if t <= 0 or t >= 1 then
			return t
		end
		return -(2 ^ (10 * t - 10)) * math.sin((t * 10 - 10.75) * (2 * math.pi) / 3)
	end,
	Bounce = function(t)
		local u = 1 - t
		local n, d = 7.5625, 2.75
		local out
		if u < 1 / d then
			out = n * u * u
		elseif u < 2 / d then
			u -= 1.5 / d
			out = n * u * u + 0.75
		elseif u < 2.5 / d then
			u -= 2.25 / d
			out = n * u * u + 0.9375
		else
			u -= 2.625 / d
			out = n * u * u + 0.984375
		end
		return 1 - out
	end,
}

-- Same curves as TweenService:GetValue, so baked keys match live playback.
local function easeValue(style, direction, t)
	if style == "Constant" then
		return 0
	elseif style == "Linear" then
		return t
	end
	local f = EASE_IN[style] or EASE_IN.Quad
	if direction == "Out" then
		return 1 - f(1 - t)
	elseif direction == "InOut" then
		if t < 0.5 then
			return f(t * 2) / 2
		end
		return 1 - f((1 - t) * 2) / 2
	end
	return f(t)
end

local function channels(value)
	return { value[1] or 0, value[2] or 0, value[3] or 0, value[4] or 0, value[5] or 0, value[6] or 0 }
end

-- Per joint: the authored keys with held values filled in.
local function jointTracks(clip)
	local tracks = {}
	for _, key in ipairs(clip.keys) do
		for joint in pairs(key.pose) do
			tracks[joint] = tracks[joint] or {}
		end
	end
	local last = {}
	for _, key in ipairs(clip.keys) do
		for joint, list in pairs(tracks) do
			last[joint] = key.pose[joint] or last[joint] or { 0, 0, 0 }
			table.insert(list, { t = key.t, v = channels(last[joint]), ease = key.ease or "Linear", dir = key.dir or "In" })
		end
	end
	return tracks
end

local function sampleTrack(list, t)
	if t <= list[1].t then
		return table.clone(list[1].v)
	end
	for i = 1, #list - 1 do
		local a, b = list[i], list[i + 1]
		if t < b.t then
			local alpha = easeValue(a.ease, a.dir, (t - a.t) / (b.t - a.t))
			local out = {}
			for c = 1, 6 do
				out[c] = a.v[c] + (b.v[c] - a.v[c]) * alpha
			end
			return out
		end
	end
	return table.clone(list[#list].v)
end

local function detail(clip, springs, fps)
	fps = fps or 60
	local tracks = jointTracks(clip)
	local length = clip.length

	-- output times: an even grid plus every authored key and marker
	local times, seen = {}, {}
	local function addTime(t)
		local k = math.floor(t * 10000 + 0.5)
		if not seen[k] then
			seen[k] = true
			table.insert(times, k / 10000)
		end
	end
	for i = 0, math.floor(length * fps) do
		addTime(i / fps)
	end
	for _, key in ipairs(clip.keys) do
		addTime(key.t)
	end
	for _, t in pairs(clip.markers or {}) do
		addTime(t)
	end
	addTime(length)
	table.sort(times)

	-- springs, warmed up over a full extra cycle for loops
	local state = {}
	for joint, params in pairs(springs) do
		if tracks[joint] then
			state[joint] = { x = sampleTrack(tracks[joint], 0), v = { 0, 0, 0, 0, 0, 0 }, w = params[1] * 2 * math.pi, z = params[2] }
		end
	end
	local h = 1 / 480
	local clock = clip.looped and -length or 0
	local function advance(toTime)
		while clock < toTime - 1e-9 do
			local step = math.min(h, toTime - clock)
			clock += step
			local t = clock % length
			if not clip.looped then
				t = math.clamp(clock, 0, length)
			end
			for joint, sp in pairs(state) do
				local target = sampleTrack(tracks[joint], t)
				for c = 1, 6 do
					local accel = sp.w * sp.w * (target[c] - sp.x[c]) - 2 * sp.z * sp.w * sp.v[c]
					sp.v[c] += accel * step
					sp.x[c] += sp.v[c] * step
				end
			end
		end
	end

	local keys = {}
	for _, t in ipairs(times) do
		advance(t)
		local p = {}
		for joint, list in pairs(tracks) do
			local exact = sampleTrack(list, t)
			local sp = state[joint]
			if sp then
				-- ease back onto the authored pose at the very end of one-shots
				local blend = clip.looped and 0 or math.clamp((t - (length - 0.12)) / 0.12, 0, 1) ^ 2
				local v = {}
				for c = 1, 6 do
					v[c] = sp.x[c] + (exact[c] - sp.x[c]) * blend
				end
				p[joint] = v
			else
				p[joint] = exact
			end
		end
		table.insert(keys, { t = t, ease = "Linear", pose = p })
	end
	if clip.looped then
		keys[#keys].pose = keys[1].pose -- seamless seam
	end

	local result = table.clone(clip)
	result.keys = keys
	result.sourceKeys = clip.keys
	return result
end

-- Pushes every in-between pose further from the clip's first pose (bigger
-- arm arcs, deeper dips, longer lunges); the first and last keys stay put.
-- Torso yaw and the legs are left alone: in R6 the legs hang off the torso,
-- so extra twist would swing the feet sideways.
local KEEP = { RightLeg = true, LeftLeg = true }

local function exaggerate(clip, amount)
	local first = clip.keys[1].pose
	local keys = {}
	for i, key in ipairs(clip.keys) do
		if i == 1 or i == #clip.keys then
			keys[i] = key
		else
			local p = {}
			for joint, value in pairs(key.pose) do
				local base = channels(first[joint] or { 0, 0, 0 })
				local v = channels(value)
				if not KEEP[joint] then
					for c = 1, 6 do
						if not (joint == "Torso" and c == 2) then
							v[c] = base[c] + (v[c] - base[c]) * amount
						end
					end
				end
				p[joint] = v
			end
			keys[i] = { t = key.t, ease = key.ease, dir = key.dir, pose = p }
		end
	end
	local result = table.clone(clip)
	result.keys = keys
	return result
end

local AIR_GUARD = pose(GUARD, AIR_LEGS, { Torso = { -4, -14, 0 } })

-- GUARD without the legs, for overlays that leave the lower body alone.
local GUARD_UPPER = {
	Torso = GUARD.Torso,
	Head = GUARD.Head,
	RightArm = GUARD.RightArm,
	LeftArm = GUARD.LeftArm,
}

local Data = {}

------------------------------------------------------------------------
-- Locomotion

-- Fighter's bounce: weight dips and rises on the balls of the feet, the
-- shoulders roll and the fists bob out of phase so the guard never freezes.
-- Fighting stance, alive: four bounces on the balls of the feet per loop,
-- each a little different. The body springs off the floor (fast out of the
-- dip, floating at the top), weight drifts from foot to foot, the shoulders
-- roll, the rear fist circles at the chin while the lead fist paws forward
-- out of phase, and the head steadies itself with a glance halfway through.
-- Feet stay planted: leg angles counter the torso's dip, tilt and sway.
Data.Stance = {
	length = 2, looped = true, priority = "Idle", group = "base",
	keys = {
		{ t = 0, ease = "Sine", dir = "In", pose = {
			Torso = { -7, -17.5, 0, 0, -0.1, 0 },
			Head = { 7, 16, 0 },
			RightArm = { 104, 0, -42, 0, 0, 0.1 },
			LeftArm = { 108, 0, 31, 0, 0, -0.05 },
			RightLeg = { -0.5, -2, 9.5 },
			LeftLeg = { 24, -2, -3.5 },
		} },
		{ t = 0.25, ease = "Sine", dir = "Out", pose = {
			Torso = { -10.5, -20, 1, -0.04, -0.33, 0.02 },
			Head = { 8.5, 19, -0.5 },
			RightArm = { 99, 0, -39, 0, -0.04, 0.12 },
			LeftArm = { 112, 0, 30, 0, -0.03, -0.14 },
			RightLeg = { 4.5, 0, 7.5 },
			LeftLeg = { 30, 0, -7.5 },
		} },
		{ t = 0.5, ease = "Sine", dir = "In", pose = {
			Torso = { -7.5, -23, 2, -0.07, -0.12, 0 },
			Head = { 8.5, 20.5, -2.5 },
			RightArm = { 95, 0, -41, 0, 0, 0.1 },
			LeftArm = { 117, 0, 27, 0, 0, -0.28 },
			RightLeg = { 3.5, 2, 8 },
			LeftLeg = { 23, 2, -7.5 },
		} },
		{ t = 0.75, ease = "Sine", dir = "Out", pose = {
			Torso = { -10, -20.5, 1.5, -0.05, -0.29, -0.02 },
			Head = { 8.5, 18.5, -1 },
			RightArm = { 99, 0, -45, 0, -0.03, 0.06 },
			LeftArm = { 111, 0, 25, 0, -0.03, -0.12 },
			RightLeg = { 3.5, 0, 8 },
			LeftLeg = { 28, 0, -7 },
		} },
		{ t = 1, ease = "Sine", dir = "In", pose = {
			Torso = { -6.5, -18, 0.5, -0.01, -0.09, 0 },
			Head = { 7.5, 19.5, 1 },
			RightArm = { 103, 0, -43, 0, 0, 0.1 },
			LeftArm = { 107, 0, 25, 0, 0, -0.04 },
			RightLeg = { -1, -1, 9.5 },
			LeftLeg = { 23, -1, -3.5 },
		} },
		{ t = 1.25, ease = "Sine", dir = "Out", pose = {
			Torso = { -12, -20.5, -1, 0.04, -0.37, -0.04 },
			Head = { 9, 24.5, 2.5 },
			RightArm = { 98, 0, -39, 0, -0.05, 0.13 },
			LeftArm = { 104, 0, 27, 0, -0.04, 0 },
			RightLeg = { 4.5, 0, 8.5 },
			LeftLeg = { 30, 0, -7 },
		} },
		{ t = 1.5, ease = "Sine", dir = "In", pose = {
			Torso = { -7.5, -24, -2, 0.07, -0.13, 0 },
			Head = { 8.5, 30, 2.5 },
			RightArm = { 94, 0, -41, 0, 0, 0.1 },
			LeftArm = { 102, 0, 29, 0, 0, 0.02 },
			RightLeg = { 2.5, 2, 10.5 },
			LeftLeg = { 20.5, 2, -5 },
		} },
		{ t = 1.75, ease = "Sine", dir = "Out", pose = {
			Torso = { -10, -21, -1.5, 0.05, -0.3, 0.02 },
			Head = { 8.5, 23, 1 },
			RightArm = { 99, 0, -45, 0, -0.03, 0.06 },
			LeftArm = { 104, 0, 31, 0, -0.03, -0.02 },
			RightLeg = { 4, 1, 9 },
			LeftLeg = { 27.5, 1, -6.5 },
		} },
		{ t = 2, pose = {
			Torso = { -7, -17.5, 0, 0, -0.1, 0 },
			Head = { 7, 16, 0 },
			RightArm = { 104, 0, -42, 0, 0, 0.1 },
			LeftArm = { 108, 0, 31, 0, 0, -0.05 },
			RightLeg = { -0.5, -2, 9.5 },
			LeftLeg = { 24, -2, -3.5 },
		} },
	},
}

-- Walk, authored for 16 studs/s (the client scales the playback). Classic
-- four-pose step (contact, down, passing, up) mirrored for the other foot:
-- arms swing opposite the legs, the torso dips onto each heel and rises over
-- the planted leg, shoulders counter-twist and the head holds steady.
-- Starts on the left heel with the right arm forward.
local LOCO_WALK_CONTACT = {
	Torso = { -6, 15, 0, 0, -0.27, 0 },
	Head = { 6, -13, 0 },
	RightArm = { 64, 0, -12 },
	LeftArm = { -40, 0, -9 },
	RightLeg = { -30, -8, 2 },
	LeftLeg = { 44, -8, -2 },
}
local LOCO_WALK_DOWN = {
	Torso = { -9, 11, 7, -0.16, -0.4, 0 },
	Head = { 9, -10, -5 },
	RightArm = { 50, 0, -9 },
	LeftArm = { -28, 0, -7 },
	RightLeg = { -16, -5, 3 },
	LeftLeg = { 30, -5, -5 },
}
local LOCO_WALK_PASS = {
	Torso = { -5, 0, 8, -0.22, -0.07, 0 },
	Head = { 4, 0, -6 },
	RightArm = { 14, 0, 7 },
	LeftArm = { 8, 0, -7 },
	RightLeg = { 16, 0, 3 },
	LeftLeg = { 4, 0, -5 },
}
local LOCO_WALK_UP = {
	Torso = { -5, -11, 5, -0.13, 0, 0 },
	Head = { 5, 10, -4 },
	RightArm = { -26, 0, 9 },
	LeftArm = { 46, 0, 5 },
	RightLeg = { 34, 5, 2 },
	LeftLeg = { -17, 5, -5 },
}
Data.Walk = {
	length = 0.72, looped = true, priority = "Movement", group = "base", speedRef = 16,
	keys = {
		{ t = 0, ease = "Sine", dir = "In", pose = LOCO_WALK_CONTACT },
		{ t = 0.09, ease = "Linear", pose = LOCO_WALK_DOWN },
		{ t = 0.18, ease = "Linear", pose = LOCO_WALK_PASS },
		{ t = 0.27, ease = "Sine", dir = "Out", pose = LOCO_WALK_UP },
		{ t = 0.36, ease = "Sine", dir = "In", pose = mirror(LOCO_WALK_CONTACT) },
		{ t = 0.45, ease = "Linear", pose = mirror(LOCO_WALK_DOWN) },
		{ t = 0.54, ease = "Linear", pose = mirror(LOCO_WALK_PASS) },
		{ t = 0.63, ease = "Sine", dir = "Out", pose = mirror(LOCO_WALK_UP) },
		{ t = 0.72, pose = LOCO_WALK_CONTACT },
	},
}

-- Sprint, authored for 28 studs/s: arms pump hard opposite the legs, the
-- knee drives high, the body sinks onto each footfall and floats through
-- the flight phase between strides. The procedural layer adds more lean
-- with speed, so the authored lean stays moderate.
-- Starts in flight with the right knee up and the left arm forward.
local LOCO_RUN_STRIDE = {
	Torso = { -16, -10, 0, 0, 0.1, 0 },
	Head = { 18, 8, 0 },
	RightArm = { -38, 0, 10 },
	LeftArm = { 85, 0, 16 },
	RightLeg = { 74, 8, 3 },
	LeftLeg = { -24, 8, -3 },
}
local LOCO_RUN_CONTACT = {
	Torso = { -17, -7, -1.5, 0.02, -0.08, 0 },
	Head = { 18, 6, 1 },
	RightArm = { -12, 0, 8 },
	LeftArm = { 56, 0, 12 },
	RightLeg = { 52, 6, 2 },
	LeftLeg = { 0, 6, -3 },
}
local LOCO_RUN_MID = {
	Torso = { -20, 0, -3, 0.05, -0.24, 0 },
	Head = { 21, 0, 2 },
	RightArm = { 36, 0, 0 },
	LeftArm = { 10, 0, -4 },
	RightLeg = { 21, 0, 2 },
	LeftLeg = { 42, 0, -4 },
}
local LOCO_RUN_PUSH = {
	Torso = { -17, 7, -1.5, 0.02, -0.02, 0 },
	Head = { 18, -6, 1 },
	RightArm = { 70, 0, -12 },
	LeftArm = { -18, 0, -8 },
	RightLeg = { -6, -6, 3 },
	LeftLeg = { 66, -6, -3 },
}
Data.Run = {
	length = 0.52, looped = true, priority = "Movement", group = "base", speedRef = 28,
	keys = {
		{ t = 0, ease = "Sine", dir = "In", pose = LOCO_RUN_STRIDE },
		{ t = 0.065, ease = "Linear", pose = LOCO_RUN_CONTACT },
		{ t = 0.13, ease = "Linear", pose = LOCO_RUN_MID },
		{ t = 0.195, ease = "Sine", dir = "Out", pose = LOCO_RUN_PUSH },
		{ t = 0.26, ease = "Sine", dir = "In", pose = mirror(LOCO_RUN_STRIDE) },
		{ t = 0.325, ease = "Linear", pose = mirror(LOCO_RUN_CONTACT) },
		{ t = 0.39, ease = "Linear", pose = mirror(LOCO_RUN_MID) },
		{ t = 0.455, ease = "Sine", dir = "Out", pose = mirror(LOCO_RUN_PUSH) },
		{ t = 0.52, pose = LOCO_RUN_STRIDE },
	},
}

-- Take-off: a quick crouch-and-spring, then tucks and holds until falling.
Data.Jump = {
	length = 0.34, holdLast = true, priority = "Movement", group = "base",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, {
			Torso = { -16, -10, 0, 0, -0.55, 0 },
			RightArm = { -22, 0, 16 },
			LeftArm = { -20, 0, -16 },
			RightLeg = { 30, 0, 8 },
			LeftLeg = { 10, 0, -8 },
		}) },
		{ t = 0.1, ease = "Back", dir = "Out", pose = {
			Torso = { 4, -6, 0, 0, 0.15, 0 },
			Head = { 12, 6, 0 },
			RightArm = { 136, 0, 22 },
			LeftArm = { 132, 0, -28 },
			RightLeg = { -12, 0, 6 },
			LeftLeg = { 64, 0, -6 },
		} },
		{ t = 0.34, pose = {
			Torso = { -4, -10, 0, 0, 0.05, 0 },
			Head = { 10, 8, 0 },
			RightArm = { 100, 0, 30 },
			LeftArm = { 112, 0, -20 },
			RightLeg = { 30, 0, 8 },
			LeftLeg = { 58, 0, -8 },
		} },
	},
}

-- Falling: arms up and out for balance, legs reaching for the ground.
Data.Fall = {
	length = 0.8, looped = true, priority = "Movement", group = "base",
	keys = {
		{ t = 0, ease = "Sine", dir = "InOut", pose = {
			Torso = { 6, -8, 0 },
			Head = { 16, 6, 0 },
			RightArm = { 70, 0, 62 },
			LeftArm = { 80, 0, -58 },
			RightLeg = { 30, 0, 10 },
			LeftLeg = { -6, 0, -10 },
		} },
		{ t = 0.4, ease = "Sine", dir = "InOut", pose = {
			Torso = { 8, -6, 2 },
			Head = { 18, 4, 0 },
			RightArm = { 84, 0, 56 },
			LeftArm = { 72, 0, -64 },
			RightLeg = { 22, 0, 12 },
			LeftLeg = { 4, 0, -12 },
		} },
		{ t = 0.8, pose = {
			Torso = { 6, -8, 0 },
			Head = { 16, 6, 0 },
			RightArm = { 70, 0, 62 },
			LeftArm = { 80, 0, -58 },
			RightLeg = { 30, 0, 10 },
			LeftLeg = { -6, 0, -10 },
		} },
	},
}

-- Landing: absorbs the drop into a deep crouch, then springs back up.
Data.Land = {
	length = 0.34, priority = "MovementOverlay", group = "overlay",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = pose(GUARD, {
			Torso = { -6, -14, 0, 0, -0.2, 0 },
		}) },
		{ t = 0.05, ease = "Sine", dir = "InOut", pose = {
			Torso = { -22, -14, 0, 0, -0.85, 0 },
			Head = { 18, 12, 0 },
			RightArm = { 50, 0, 30 },
			LeftArm = { 60, 0, -26 },
			RightLeg = { 4, 0, 18 },
			LeftLeg = { 52, 0, -14 },
		} },
		{ t = 0.14, ease = "Back", dir = "Out", pose = {
			Torso = { -18, -16, 0, 0, -0.7, 0 },
			Head = { 16, 14, 0 },
			RightArm = { 70, 0, -10 },
			LeftArm = { 84, 0, 10 },
			RightLeg = { 6, 0, 16 },
			LeftLeg = { 46, 0, -12 },
		} },
		{ t = 0.34, pose = GUARD },
	},
}

-- Second jump: a tucked front flip.
local FLIP_TUCK = {
	Head = { -30, 0, 0 },
	RightArm = { 120, 0, -20 },
	LeftArm = { 120, 0, 20 },
	RightLeg = { 110, 0, 6 },
	LeftLeg = { 104, 0, -6 },
}
Data.DoubleJump = {
	length = 0.46, priority = "MovementOverlay", group = "overlay",
	keys = {
		{ t = 0, ease = "Quad", dir = "In", pose = pose(AIR_GUARD, { Torso = { 10, 0, 0, 0, 0, 0 } }) },
		{ t = 0.07, ease = "Linear", pose = pose(FLIP_TUCK, { Torso = { -70, 0, 0, 0, 0.3, 0 } }) },
		{ t = 0.15, ease = "Linear", pose = pose(FLIP_TUCK, { Torso = { -170, 0, 0, 0, 0.5, 0 } }) },
		{ t = 0.23, ease = "Linear", pose = pose(FLIP_TUCK, { Torso = { -270, 0, 0, 0, 0.45, 0 } }) },
		{ t = 0.32, ease = "Quad", dir = "Out", pose = pose(AIR_GUARD, {
			Torso = { -350, 0, 0, 0, 0.2, 0 },
			RightArm = { 140, 0, 40 },
			LeftArm = { 140, 0, -40 },
		}) },
		{ t = 0.46, pose = pose(AIR_GUARD, { Torso = { -364, -10, 0 } }) },
	},
}

------------------------------------------------------------------------
-- M1 chain: right straight, left hook, right body shot, right roundhouse,
-- then a finisher that blasts them away.

-- Right cross. Dip, then a long readable coil (shoulders wound away, rear
-- fist cocked back, lead hand pawing out to measure), a tense beat, then
-- the hips turn over and the fist snaps through to the face.
Data.M1_1 = {
	length = 0.56, priority = "Action", group = "action", recover = 0.4,
	markers = { Swing = 0.14, Hit = 0.2 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = GUARD },
		-- counter-move: drop the hips, ease toward square, lead hand pokes out
		{ t = 0.05, ease = "Quad", dir = "Out", pose = {
			Torso = { -13, -14, -2, 0, -0.44, -0.05 },
			Head = { 13, 12, 2 },
			RightArm = { 94, 0, -40, 0, -0.06, 0.05 },
			LeftArm = { 112, 0, 24, 0, 0, -0.2 },
			RightLeg = { 5, 0, 10 },
			LeftLeg = { 32, 0, -1 },
		} },
		-- coil: shoulders wind away, weight rocks onto the back foot
		{ t = 0.115, ease = "Sine", dir = "InOut", pose = {
			Torso = { 2, -50, -5, 0.12, -0.34, 0.25 },
			Head = { -3, 47, 5 },
			RightArm = { 96, 0, -34, 0, 0.1, 0.62 },
			LeftArm = { 98, 0, 4, 0, 0.05, -0.35 },
			RightLeg = { 6, 0, 16 },
			LeftLeg = { 2, 0, -3 },
		} },
		-- tense beat at the top of the coil
		{ t = 0.14, ease = "Quad", dir = "In", pose = {
			Torso = { 3, -54, -6, 0.14, -0.36, 0.28 },
			Head = { -4, 51, 6 },
			RightArm = { 98, 0, -32, 0, 0.12, 0.7 },
			LeftArm = { 96, 0, 2, 0, 0.05, -0.38 },
			RightLeg = { 7, 0, 18 },
			LeftLeg = { -1, 0, -1 },
		} },
		-- mid-strike guide: fist drives straight down the centre line
		{ t = 0.175, ease = "Linear", pose = {
			Torso = { -8, -14, -1, 0.04, -0.36, -0.15 },
			Head = { 8, 13, 1 },
			RightArm = { 98, 0, -47, 0, 0.1, 0 },
			LeftArm = { 104, 0, 22, 0, 0.02, -0.1 },
			RightLeg = { -2, 0, 10 },
			LeftLeg = { 27, 0, -4 },
		} },
		-- impact: hips turn over, step in, fist through the face
		{ t = 0.2, ease = "Sine", dir = "Out", pose = {
			Torso = { -16, 40, 6, -0.1, -0.34, -0.7 },
			Head = { 16, -38, -6 },
			RightArm = { 112, 0, 10, 0, 0.1, -0.55 },
			LeftArm = { 122, 0, 62, 0, 0, 0.3 },
			RightLeg = { -17, 0, -6 },
			LeftLeg = { 37, 0, 18 },
		} },
		-- hang just past it
		{ t = 0.245, ease = "Quad", dir = "InOut", pose = {
			Torso = { -18, 46, 7, -0.12, -0.36, -0.78 },
			Head = { 18, -44, -7 },
			RightArm = { 116, 0, 14, 0, 0.1, -0.65 },
			LeftArm = { 124, 0, 64, 0, 0, 0.32 },
			RightLeg = { -18, 0, -8 },
			LeftLeg = { 38, 0, 22 },
		} },
		-- follow-through: shoulders keep turning as the fist starts back
		{ t = 0.285, ease = "Back", dir = "Out", pose = {
			Torso = { -16, 52, 8, -0.1, -0.34, -0.7 },
			Head = { 16, -50, -8 },
			RightArm = { 104, 0, 4, 0, 0.05, -0.3 },
			LeftArm = { 116, 0, 58, 0, 0, 0.3 },
			RightLeg = { -21, 0, -12 },
			LeftLeg = { 37, 0, 24 },
		} },
		-- rebound: fist snaps back to the chin, shoulders unwind
		{ t = 0.36, ease = "Sine", dir = "InOut", pose = {
			Torso = { -12, 8, -1, 0, -0.36, -0.25 },
			Head = { 12, -9, 1 },
			RightArm = { 112, 0, -44, 0, 0.02, 0.22 },
			LeftArm = { 98, 0, 22, 0, -0.04, -0.05 },
			RightLeg = { -6, 0, 9 },
			LeftLeg = { 40, 0, 9 },
		} },
		-- overshoot past guard, bob down
		{ t = 0.45, ease = "Sine", dir = "InOut", pose = {
			Torso = { -11, -27, 1, 0, -0.3, 0.05 },
			Head = { 11, 25, -1 },
			RightArm = { 97, 0, -41, 0, -0.03, 0.1 },
			LeftArm = { 104, 0, 29, 0, -0.03, -0.05 },
			RightLeg = { 10, 0, 5 },
			LeftLeg = { 27, 0, -12 },
		} },
		{ t = 0.56, pose = GUARD },
	},
}

-- Lead hook. Settle, then the lead side opens up (weight onto the front
-- foot, arm swung out wide and back), a beat, then the hips whip across and
-- the fist wraps around at head height, carrying through before it rebounds.
Data.M1_2 = {
	length = 0.56, priority = "Action", group = "action", recover = 0.4,
	markers = { Swing = 0.14, Hit = 0.2 },
	trail = { "Left Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = GUARD },
		-- counter-move: tuck tighter, turn a hair away and sink
		{ t = 0.05, ease = "Quad", dir = "Out", pose = {
			Torso = { -13, -28, -3, 0.05, -0.44, 0 },
			Head = { 13, 26, 3 },
			RightArm = { 106, 0, -46, 0, 0, 0.12 },
			LeftArm = { 114, 0, 38, 0, -0.05, 0.05 },
			RightLeg = { 11, 0, 8 },
			LeftLeg = { 27, 0, -8 },
		} },
		-- coil: lead side opens, weight drops onto the front foot, arm wide
		{ t = 0.115, ease = "Sine", dir = "InOut", pose = {
			Torso = { -10, 12, 10, -0.22, -0.46, -0.05 },
			Head = { 10, -14, -10 },
			RightArm = { 112, 0, -52, 0, 0, 0.15 },
			LeftArm = { 82, 0, -96, 0, 0.12, 0.1 },
			RightLeg = { -11, 0, -1 },
			LeftLeg = { 33, 0, 2 },
		} },
		-- tense beat
		{ t = 0.14, ease = "Quad", dir = "In", pose = {
			Torso = { -11, 16, 11, -0.24, -0.48, -0.05 },
			Head = { 11, -18, -11 },
			RightArm = { 113, 0, -53, 0, 0, 0.15 },
			LeftArm = { 80, 0, -100, 0, 0.13, 0.12 },
			RightLeg = { -12, 0, -3 },
			LeftLeg = { 34, 0, 4 },
		} },
		-- impact: hips whip across, fist wraps around at head height
		{ t = 0.2, ease = "Sine", dir = "Out", pose = {
			Torso = { -16, -36, -10, 0.06, -0.46, -0.42 },
			Head = { 14, 34, 10 },
			RightArm = { 112, 0, -50, 0, 0.02, 0.2 },
			LeftArm = { 116, 0, 10, 0, 0.08, -0.15 },
			RightLeg = { 14, 0, 18 },
			LeftLeg = { 22, 0, -5 },
		} },
		-- hang just past it
		{ t = 0.245, ease = "Quad", dir = "InOut", pose = {
			Torso = { -17, -43, -11, 0.08, -0.48, -0.46 },
			Head = { 15, 41, 11 },
			RightArm = { 113, 0, -50, 0, 0.02, 0.22 },
			LeftArm = { 116, 0, 22, 0, 0.08, -0.12 },
			RightLeg = { 16, 0, 17 },
			LeftLeg = { 18, 0, -7 },
		} },
		-- follow-through: the swing carries the shoulders past the target
		{ t = 0.285, ease = "Back", dir = "Out", pose = {
			Torso = { -19, -62, -14, 0.1, -0.5, -0.42 },
			Head = { 16, 58, 14 },
			RightArm = { 110, 0, -46, 0, 0, 0.24 },
			LeftArm = { 108, 0, 44, 0, 0.05, -0.05 },
			RightLeg = { 23, 0, 12 },
			LeftLeg = { 6, 0, -11 },
		} },
		-- rebound back toward the stance
		{ t = 0.36, ease = "Sine", dir = "InOut", pose = {
			Torso = { -10, -28, -2, 0.03, -0.3, -0.18 },
			Head = { 10, 26, 2 },
			RightArm = { 102, 0, -44, 0, 0.02, 0.12 },
			LeftArm = { 112, 0, 30, 0, 0.04, -0.12 },
			RightLeg = { 5, 0, 12 },
			LeftLeg = { 22, 0, -8 },
		} },
		-- overshoot past guard the other way, bob down
		{ t = 0.45, ease = "Sine", dir = "InOut", pose = {
			Torso = { -12, -12, -1, 0, -0.34, 0 },
			Head = { 12, 11, 1 },
			RightArm = { 97, 0, -41, 0, -0.03, 0.1 },
			LeftArm = { 104, 0, 27, 0, -0.04, -0.05 },
			RightLeg = { 5, 0, 9 },
			LeftLeg = { 33, 0, -1 },
		} },
		{ t = 0.56, pose = GUARD },
	},
}

-- Right shovel hook to the body: pops up, sinks the hips into a deep level
-- change with the fist loaded low by the hip, then the hips turn over and
-- the fist digs up and in under the ribs.
local M1B_SHOVEL_COIL = {
	Torso = { -18, -38, -8, 0, -0.56, 0.06 },
	Head = { 16, 36, 7 },
	RightArm = { 18, -20, 26, 0, 0, 0.3 },
	LeftArm = { 114, 0, 16, 0, 0, -0.22 },
	RightLeg = { -24, 0, 28 },
	LeftLeg = { 62, 0, -24 },
}
Data.M1_3 = {
	length = 0.58, priority = "Action", group = "action", recover = 0.41,
	markers = { Swing = 0.15, Hit = 0.21 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = GUARD },
		-- counter-move: rises a touch and opens up before sinking
		{ t = 0.05, ease = "Quad", dir = "Out", pose = {
			Torso = { -5, -12, 3, 0, -0.08, -0.04 },
			Head = { 5, 10, -2 },
			RightArm = { 108, 0, -38, 0, 0.05, 0.05 },
			LeftArm = { 114, 0, 26, 0, 0.04, -0.1 },
			RightLeg = { 0, 0, 9 },
			LeftLeg = { 22, 0, -5 },
		} },
		-- level change: hips drop, torso coils right, fist loaded low by the hip
		{ t = 0.1, ease = "Sine", dir = "InOut", pose = M1B_SHOVEL_COIL },
		-- coil peak: sinks a hair deeper and holds
		{ t = 0.15, ease = "Quad", dir = "In", pose = pose(M1B_SHOVEL_COIL, {
			Torso = { -20, -42, -10, 0, -0.6, 0.08 },
			Head = { 18, 40, 8 },
			RightArm = { 14, -22, 28, 0, 0, 0.34 },
			RightLeg = { -26, 0, 30 },
			LeftLeg = { 64, 0, -26 },
		}) },
		-- hips lead: torso turning over and stepping in, fist still low
		{ t = 0.18, ease = "Linear", pose = {
			Torso = { -22, -2, -2, 0, -0.62, -0.3 },
			Head = { 20, 4, 2 },
			RightArm = { 42, -10, 24, 0, 0, 0.1 },
			LeftArm = { 116, 0, 34, 0, 0, 0.1 },
			RightLeg = { -28, 0, 12 },
			LeftLeg = { 62, 0, -12 },
		} },
		-- impact: fist driven up and in under the ribs, lead hand at the chin
		{ t = 0.21, ease = "Quad", dir = "Out", pose = {
			Torso = { -22, 38, 8, 0, -0.58, -0.62 },
			Head = { 20, -34, -6 },
			RightArm = { 118, 0, 16, 0, 0, -0.45 },
			LeftArm = { 126, 0, 50, 0, 0, 0.3 },
			RightLeg = { -26, 0, -4 },
			LeftLeg = { 60, 0, 0 },
		} },
		-- hang just past it
		{ t = 0.25, ease = "Sine", dir = "Out", pose = {
			Torso = { -23, 44, 10, 0, -0.56, -0.68 },
			Head = { 21, -38, -7 },
			RightArm = { 124, 0, 12, 0, 0, -0.5 },
			LeftArm = { 126, 0, 52, 0, 0, 0.32 },
			RightLeg = { -27, 0, -4 },
			LeftLeg = { 60, 0, 0 },
		} },
		-- follow-through: the fist keeps rising across, the body lifts
		{ t = 0.31, ease = "Back", dir = "Out", pose = {
			Torso = { -16, 52, 12, 0, -0.44, -0.56 },
			Head = { 16, -44, -8 },
			RightArm = { 140, 0, -8, 0, 0, -0.4 },
			LeftArm = { 118, 0, 46, 0, 0, 0.25 },
			RightLeg = { -20, 0, 0 },
			LeftLeg = { 46, 0, -4 },
		} },
		-- rebound back toward guard
		{ t = 0.4, ease = "Sine", dir = "InOut", pose = {
			Torso = { -12, 10, 2, 0, -0.32, -0.2 },
			Head = { 12, -8, -2 },
			RightArm = { 100, 0, -36, 0, 0, 0.05 },
			LeftArm = { 108, 0, 34, 0, 0, 0.05 },
			RightLeg = { -6, 0, 10 },
			LeftLeg = { 34, 0, -8 },
		} },
		-- overshoot past guard
		{ t = 0.49, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -10, -28, -1, 0, -0.27, 0.04 },
			Head = { 10, 26, 1 },
			RightArm = { 103, 0, -44, 0, 0, 0.12 },
			LeftArm = { 110, 0, 27, 0, 0, -0.06 },
		}) },
		{ t = 0.58, pose = GUARD },
	},
}

-- Right roundhouse: dips, springs up onto the lead foot with the rear knee
-- chambered up and out while leaning away, then the hips whip over and the
-- shin cuts through at chest-to-head height, carries past and re-plants.
local M1B_KICK_CHAMBER = {
	Torso = { 12, -30, 20, 0, -0.02, 0.15 },
	Head = { -10, 28, -18 },
	RightArm = { 96, -10, -58, 0, 0, 0.1 },
	LeftArm = { 120, 0, -6, 0, 0, -0.15 },
	RightLeg = { 76, -10, 20 },
	LeftLeg = { -10, 0, -18 },
}
Data.M1_4 = {
	length = 0.64, priority = "Action", group = "action", recover = 0.44,
	markers = { Swing = 0.17, Hit = 0.24 },
	trail = { "Right Leg" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = GUARD },
		-- counter-move: sinks into the legs before springing up
		{ t = 0.05, ease = "Cubic", dir = "Out", pose = {
			Torso = { -12, -14, -2, 0, -0.36, 0.04 },
			Head = { 12, 14, 2 },
			RightArm = { 104, 0, -46, 0, 0, 0.12 },
			LeftArm = { 104, 0, 32, 0, 0, -0.05 },
			RightLeg = { -16, 0, 20 },
			LeftLeg = { 42, 0, -16 },
		} },
		-- chamber: up onto the lead foot, knee up and out, leaning away
		{ t = 0.12, ease = "Sine", dir = "InOut", pose = M1B_KICK_CHAMBER },
		-- coil peak: winds a little further and holds
		{ t = 0.17, ease = "Quad", dir = "In", pose = pose(M1B_KICK_CHAMBER, {
			Torso = { 14, -36, 24, 0, 0.02, 0.18 },
			Head = { -12, 34, -21 },
			RightArm = { 98, -10, -64, 0, 0, 0.12 },
			RightLeg = { 82, -10, 24 },
			LeftLeg = { -12, 0, -22 },
		}) },
		-- hips lead: torso snaps over, the leg trails flat out to the side
		{ t = 0.205, ease = "Linear", pose = {
			Torso = { 6, 18, 24, 0, 0.02, -0.05 },
			Head = { 0, -16, -20 },
			RightArm = { 20, 0, 6, 0, 0, 0 },
			LeftArm = { 112, 0, 20, 0, 0, 0 },
			RightLeg = { 22, 0, 86 },
			LeftLeg = { -6, 0, -22 },
		} },
		-- impact: shin through the target high, rear arm flung down and back
		{ t = 0.24, ease = "Quad", dir = "Out", pose = {
			Torso = { 6, 58, 28, 0, -0.02, -0.25 },
			Head = { -2, -50, -22 },
			RightArm = { -60, 0, -36, 0, 0, 0 },
			LeftArm = { 108, 0, 46, 0, 0, 0 },
			RightLeg = { 10, 30, 100 },
			LeftLeg = { -4, 0, -24 },
		} },
		-- hang just past it
		{ t = 0.28, ease = "Sine", dir = "In", pose = {
			Torso = { 6, 66, 29, 0, -0.03, -0.28 },
			Head = { -2, -56, -23 },
			RightArm = { -66, 0, -36, 0, 0, 0 },
			LeftArm = { 106, 0, 48, 0, 0, 0 },
			RightLeg = { 10, 22, 101 },
			LeftLeg = { -4, 0, -24 },
		} },
		-- follow-through: carries past the target and starts to drop
		{ t = 0.34, ease = "Back", dir = "Out", pose = {
			Torso = { 4, 92, 24, 0, -0.1, -0.25 },
			Head = { 0, -64, -18 },
			RightArm = { -30, 0, 20, 0, 0, 0 },
			LeftArm = { 84, 0, -30, 0, 0, 0 },
			RightLeg = { 14, 10, 80 },
			LeftLeg = { -2, 0, -20 },
		} },
		-- re-plant: leg comes down behind, absorbs into the legs
		{ t = 0.42, ease = "Sine", dir = "InOut", pose = {
			Torso = { -14, 24, 4, 0, -0.46, -0.1 },
			Head = { 14, -20, -4 },
			RightArm = { 88, 0, -30, 0, 0, 0.05 },
			LeftArm = { 104, 0, 22, 0, 0, 0 },
			RightLeg = { -28, 0, 14 },
			LeftLeg = { 50, 0, -10 },
		} },
		-- overshoot past guard
		{ t = 0.52, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -10, -28, -1, 0, -0.28, 0.04 },
			Head = { 10, 26, 1 },
			RightArm = { 103, 0, -44, 0, 0, 0.12 },
			LeftArm = { 110, 0, 27, 0, 0, -0.06 },
		}) },
		{ t = 0.64, pose = GUARD },
	},
}

-- Big committed haymaker: everything loads back, then the body launches
-- into the punch and hangs on it while the target flies.
-- Big committed haymaker: everything loads back, then the body launches
-- into the punch and hangs on it while the target flies.
Data.Finisher = {
	length = 0.96, priority = "Action", group = "action", recover = 0.7,
	markers = { Swing = 0.3, Hit = 0.36 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = GUARD },
		-- settle: dip and lean in a touch before loading up
		{ t = 0.07, ease = "Sine", dir = "InOut", pose = {
			Torso = { -13, -10, 3, 0, -0.36, -0.1 },
			Head = { 13, 10, -3 },
			RightArm = { 90, 0, -34, 0, -0.05, 0.05 },
			LeftArm = { 100, 0, 22, 0, 0, -0.12 },
			RightLeg = { 1, 0, 4 },
			LeftLeg = { 34, 0, -4 },
		} },
		-- wind: hips turn away, fist swings out around the side
		{ t = 0.15, ease = "Sine", dir = "Out", pose = {
			Torso = { 2, -48, -3, 0, -0.3, 0.2 },
			Head = { 4, 40, 3 },
			RightArm = { 56, -14, 58, 0, 0, 0.15 },
			LeftArm = { 90, 0, -15 },
			RightLeg = { 6, 0, 21 },
			LeftLeg = { 8, 0, -4 },
		} },
		-- coil: fist cocked at the shoulder, lead hand on the target
		{ t = 0.23, ease = "Sine", dir = "InOut", pose = {
			Torso = { 8, -76, -4, 0, -0.2, 0.36 },
			Head = { 3, 62, 6 },
			RightArm = { 2, -36, 86, 0, 0.1, 0.3 },
			LeftArm = { 14, -8, -64, 0, 0, -0.18 },
			RightLeg = { 12, 0, 30 },
			LeftLeg = { -6, 0, -4 },
		} },
		-- tension: sink a hair deeper, then go
		{ t = 0.3, ease = "Quad", dir = "In", pose = {
			Torso = { 10, -82, -6, 0, -0.24, 0.42 },
			Head = { 2, 68, 7 },
			RightArm = { -2, -42, 88, 0, 0.12, 0.35 },
			LeftArm = { 12, -2, -66, 0, 0, -0.22 },
			RightLeg = { 18, 0, 36 },
			LeftLeg = { -8, 0, 1 },
		} },
		-- hips fire first, the fist whips around the side
		{ t = 0.33, ease = "Linear", dir = "In", pose = {
			Torso = { -8, -30, -5, 0, -0.5, -0.2 },
			Head = { 8, 28, 3 },
			RightArm = { 10, -6, 86, 0, 0.1, 0.1 },
			LeftArm = { 70, 0, 30, 0, 0, 0.1 },
			RightLeg = { 3, 0, 20 },
			LeftLeg = { 36, 0, -6 },
		} },
		-- impact: full lunge, arm through the target, off hand at the chin
		{ t = 0.36, ease = "Sine", dir = "Out", pose = {
			Torso = { -18, 42, -1, 0, -0.55, -1.2 },
			Head = { 17, -36, 4 },
			RightArm = { 122, 0, 2, 0, 0, -0.35 },
			LeftArm = { 112, 0, 52, 0, 0, 0.25 },
			RightLeg = { -22, 0, 0 },
			LeftLeg = { 36, 0, 20 },
		} },
		-- hang on it while they fly
		{ t = 0.43, ease = "Sine", dir = "InOut", pose = {
			Torso = { -20, 46, -2, 0, -0.57, -1.28 },
			Head = { 18, -40, 5 },
			RightArm = { 130, 0, 3, 0, 0, -0.42 },
			LeftArm = { 114, 0, 54, 0, 0, 0.28 },
			RightLeg = { -22, 0, 0 },
			LeftLeg = { 36, 0, 24 },
		} },
		-- follow-through: the weight sags through and the fist drifts across
		{ t = 0.5, ease = "Back", dir = "InOut", pose = {
			Torso = { -23, 50, -3, 0, -0.63, -1.24 },
			Head = { 20, -44, 5 },
			RightArm = { 122, 0, -2, 0, 0, -0.3 },
			LeftArm = { 108, 0, 50, 0, 0, 0.22 },
			RightLeg = { -22, 0, 2 },
			LeftLeg = { 39, 0, 28 },
		} },
		-- recoil: pull the arm home, weight comes back
		{ t = 0.6, ease = "Sine", dir = "InOut", pose = {
			Torso = { -10, 22, -2, 0, -0.4, -0.7 },
			Head = { 11, -18, 2 },
			RightArm = { 96, 0, -22, 0, 0, -0.1 },
			LeftArm = { 104, 0, 36, 0, 0, 0.1 },
			RightLeg = { -25, 0, 5 },
			LeftLeg = { 24, 0, 11 },
		} },
		-- overshoot past guard, then settle
		{ t = 0.7, ease = "Sine", dir = "InOut", pose = {
			Torso = { -5, -33, 3, 0, -0.3, -0.12 },
			Head = { 6, 30, -3 },
			RightArm = { 104, 0, -46, 0, 0, 0.15 },
			LeftArm = { 112, 0, 26, 0, 0, -0.1 },
			RightLeg = { 0, 0, 8 },
			LeftLeg = { 16, 0, -8 },
		} },
		{ t = 0.82, ease = "Sine", dir = "InOut", pose = {
			Torso = { -10, -15, -1, 0, -0.15, -0.03 },
			Head = { 10, 14, 1 },
			RightArm = { 98, 0, -40, 0, 0, 0.08 },
			LeftArm = { 106, 0, 30, 0, 0, -0.03 },
			RightLeg = { 2, 0, 10 },
			LeftLeg = { 26, 0, -4 },
		} },
		{ t = 0.96, pose = GUARD },
	},
}

Data.Critical = {
	length = 1.12, priority = "Action", group = "action", recover = 0.9,
	markers = { Swing = 0.5, Hit = 0.58 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = GUARD },
		-- breathe in: chest rises and squares up, fists drop
		{ t = 0.08, ease = "Sine", dir = "InOut", pose = {
			Torso = { -4, -8, 2, 0, -0.1, -0.06 },
			Head = { 5, 8, -2 },
			RightArm = { 84, 0, -30, 0, 0.05, 0.1 },
			LeftArm = { 96, 0, 18, 0, 0, -0.1 },
			RightLeg = { -8, 0, 8 },
			LeftLeg = { 18, 0, -3 },
		} },
		-- draw: hips wind away, fist circles out and up around the side
		{ t = 0.18, ease = "Sine", dir = "Out", pose = {
			Torso = { 2, -52, -3, 0, -0.32, 0.22 },
			Head = { 4, 44, 3 },
			RightArm = { 58, -14, 62, 0, 0, 0.15 },
			LeftArm = { 94, 0, -20 },
			RightLeg = { 8, 0, 22 },
			LeftLeg = { 7, 0, -6 },
		} },
		-- fully coiled: fist cocked at the shoulder, open lead hand sights the target
		{ t = 0.28, ease = "Sine", dir = "Out", pose = {
			Torso = { 8, -80, -5, 0, -0.32, 0.4 },
			Head = { 2, 66, 5 },
			RightArm = { 2, -38, 86, 0, 0.1, 0.3 },
			LeftArm = { 14, -4, -64, 0, 0, -0.2 },
			RightLeg = { 19, 0, 30 },
			LeftLeg = { -8, 0, -4 },
		} },
		-- charging: the whole body trembles as it sinks and winds tighter
		{ t = 0.32, ease = "Linear", dir = "In", pose = {
			Torso = { 10, -83, -2, 0, -0.35, 0.43 },
			Head = { 4, 69, 3 },
			RightArm = { -1, -41, 90, 0, 0.13, 0.33 },
			LeftArm = { 12, -1, -67, 0, 0, -0.21 },
			RightLeg = { 21, 0, 28 },
			LeftLeg = { -10, 0, -6 },
		} },
		{ t = 0.36, ease = "Linear", dir = "In", pose = {
			Torso = { 10, -85, -7, 0, -0.38, 0.45 },
			Head = { 1, 71, 8 },
			RightArm = { 2, -44, 85, 0, 0.12, 0.34 },
			LeftArm = { 16, 1, -63, 0, 0, -0.21 },
			RightLeg = { 26, 0, 38 },
			LeftLeg = { -10, 0, 2 },
		} },
		{ t = 0.4, ease = "Linear", dir = "In", pose = {
			Torso = { 13, -88, -3, 0, -0.42, 0.48 },
			Head = { 4, 73, 3 },
			RightArm = { -3, -47, 91, 0, 0.15, 0.36 },
			LeftArm = { 12, 4, -68, 0, 0, -0.23 },
			RightLeg = { 29, 0, 36 },
			LeftLeg = { -12, 0, 0 },
		} },
		{ t = 0.44, ease = "Linear", dir = "In", pose = {
			Torso = { 12, -90, -8, 0, -0.45, 0.5 },
			Head = { 1, 75, 8 },
			RightArm = { 0, -50, 86, 0, 0.13, 0.37 },
			LeftArm = { 16, 6, -63, 0, 0, -0.22 },
			RightLeg = { 35, 0, 43 },
			LeftLeg = { -12, 0, 4 },
		} },
		{ t = 0.47, ease = "Linear", dir = "In", pose = {
			Torso = { 15, -92, -3, 0, -0.47, 0.52 },
			Head = { 4, 77, 4 },
			RightArm = { -4, -52, 91, 0, 0.16, 0.38 },
			LeftArm = { 12, 8, -68, 0, 0, -0.24 },
			RightLeg = { 36, 0, 38 },
			LeftLeg = { -13, 0, 2 },
		} },
		-- release
		{ t = 0.5, ease = "Quad", dir = "In", pose = {
			Torso = { 15, -94, -6, 0, -0.48, 0.54 },
			Head = { 3, 78, 6 },
			RightArm = { -5, -54, 90, 0, 0.16, 0.4 },
			LeftArm = { 14, 10, -66, 0, 0, -0.25 },
			RightLeg = { 40, 0, 42 },
			LeftLeg = { -13, 0, 6 },
		} },
		-- hips fire, the fist spirals down and around the side
		{ t = 0.54, ease = "Linear", dir = "In", pose = {
			Torso = { -8, -32, -3, 0, -0.42, -0.25 },
			Head = { 8, 30, 2 },
			RightArm = { 20, -10, 66, 0, 0.1, 0.1 },
			LeftArm = { 60, 0, 26, 0, 0, 0.15 },
			RightLeg = { 3, 0, 16 },
			LeftLeg = { 33, 0, -9 },
		} },
		-- impact: corkscrew lands, full lunge, rear fist chambered at the hip
		{ t = 0.58, ease = "Sine", dir = "Out", pose = {
			Torso = { -22, 46, -4, 0, -0.64, -1.25 },
			Head = { 20, -40, 5 },
			RightArm = { 80, 70, 40, 0, 0, -0.4 },
			LeftArm = { -34, 0, 22, 0, 0, 0.2 },
			RightLeg = { -23, 0, 3 },
			LeftLeg = { 38, 0, 26 },
		} },
		-- hang: the screw keeps turning through the target
		{ t = 0.66, ease = "Sine", dir = "InOut", pose = {
			Torso = { -24, 50, -6, 0, -0.66, -1.33 },
			Head = { 21, -44, 7 },
			RightArm = { 180, 110, -56, 0, 0, -0.45 },
			LeftArm = { -38, 0, 24, 0, 0, 0.24 },
			RightLeg = { -24, 0, 5 },
			LeftLeg = { 38, 0, 29 },
		} },
		-- follow-through: weight sags onto the front leg
		{ t = 0.74, ease = "Back", dir = "InOut", pose = {
			Torso = { -25, 52, -5, 0, -0.7, -1.3 },
			Head = { 21, -44, 5 },
			RightArm = { 180, 100, -61, 0, 0, -0.35 },
			LeftArm = { -26, 0, 24, 0, 0, 0.2 },
			RightLeg = { -24, 0, 3 },
			LeftLeg = { 39, 0, 30 },
		} },
		-- recoil: unscrew the arm and haul the weight back
		{ t = 0.84, ease = "Back", dir = "Out", pose = {
			Torso = { -12, 24, -3, 0, -0.42, -0.72 },
			Head = { 12, -20, 2 },
			RightArm = { 94, 30, -20, 0, 0, -0.1 },
			LeftArm = { 90, 0, 34, 0, 0, 0.1 },
			RightLeg = { -23, 0, 6 },
			LeftLeg = { 28, 0, 13 },
		} },
		-- overshoot past guard, then settle
		{ t = 0.94, ease = "Sine", dir = "InOut", pose = {
			Torso = { -6, -32, 2, 0, -0.26, -0.15 },
			Head = { 6, 30, -2 },
			RightArm = { 104, 0, -46, 0, 0, 0.15 },
			LeftArm = { 112, 0, 26, 0, 0, -0.1 },
			RightLeg = { 1, 0, 9 },
			LeftLeg = { 16, 0, -7 },
		} },
		{ t = 1.02, ease = "Sine", dir = "InOut", pose = {
			Torso = { -10, -15, -1, 0, -0.17, -0.03 },
			Head = { 10, 14, 1 },
			RightArm = { 98, 0, -40, 0, 0, 0.08 },
			LeftArm = { 106, 0, 30, 0, 0, -0.03 },
			RightLeg = { 2, 0, 10 },
			LeftLeg = { 26, 0, -3 },
		} },
		{ t = 1.12, pose = GUARD },
	},
}

------------------------------------------------------------------------
-- Specials

-- Launcher: sinks into a deep crouch, then rockets up behind the uppercut.
local SPC_UPPER_COIL = {
	Torso = { -24, -42, -8, 0, -1.0, 0.15 },
	Head = { 26, 34, 6 },
	RightArm = { -22, 0, 26, 0, 0, 0.2 },
	LeftArm = { 100, 0, 38, 0, 0, -0.1 },
	RightLeg = { -18, 0, 24 },
	LeftLeg = { 68, 0, -16 },
}

local SPC_SLAM_RAISE = {
	Torso = { 24, 0, 0, 0, 0.35, 0.25 },
	Head = { -14, 0, 0 },
	RightArm = { 196, 0, -14 },
	LeftArm = { 196, 0, 14 },
	RightLeg = { -40, 0, 8 },
	LeftLeg = { -26, 0, -8 },
}

local SPC_SUPER_COIL = {
	Torso = { 2, -38, 6, 0, 0, 0.25 },
	Head = { 2, 34, -4 },
	RightArm = { 160, 0, 30, 0, 0, 0.25 },
	LeftArm = { 100, 0, 20, 0, 0, -0.2 },
	RightLeg = { 76, 0, 10 },
	LeftLeg = { -4, 0, -6 },
}

Data.Uppercut = {
	length = 0.72, priority = "Action", group = "action", recover = 0.56,
	markers = { Swing = 0.2, Hit = 0.26 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = GUARD },
		-- counter-move: a small hitch up before the drop
		{ t = 0.06, ease = "Cubic", dir = "Out", pose = {
			Torso = { -4, -12, 2, 0, -0.08, -0.05 },
			Head = { 4, 12, -2 },
			RightArm = { 108, 0, -38, 0, 0.05, 0.05 },
			LeftArm = { 112, 0, 26, 0, 0.05, -0.08 },
			RightLeg = { 0, 0, 9 },
			LeftLeg = { 20, 0, -5 },
		} },
		-- coil: deep crouch, hips wound away, fist dropped behind the hip
		{ t = 0.13, ease = "Sine", dir = "InOut", pose = SPC_UPPER_COIL },
		{ t = 0.2, ease = "Quad", dir = "In", pose = pose(SPC_UPPER_COIL, {
			Torso = { -26, -46, -9, 0, -1.08, 0.18 },
			Head = { 28, 38, 7 },
			RightArm = { -28, 0, 28, 0, 0, 0.25 },
			LeftArm = { 98, 0, 40, 0, 0, -0.12 },
			RightLeg = { -20, 0, 25 },
			LeftLeg = { 70, 0, -17 },
		}) },
		-- drive: hips fire, body rises, fist scoops through low
		{ t = 0.235, ease = "Linear", pose = {
			Torso = { -14, 0, 0, 0, -0.5, -0.25 },
			Head = { 18, -2, 0 },
			RightArm = { 50, 0, -10, 0, 0, -0.1 },
			LeftArm = { 70, 0, 40, 0, 0, 0.1 },
			RightLeg = { -24, 0, 14 },
			LeftLeg = { 50, 0, -10 },
		} },
		-- impact: fist up through the chin, rear leg pushes off, knee drives
		{ t = 0.26, ease = "Quad", dir = "Out", pose = {
			Torso = { 6, 34, 10, 0, 0.35, -0.6 },
			Head = { 20, -28, -6 },
			RightArm = { 128, 0, -16, 0, 0.1, -0.25 },
			LeftArm = { 120, 0, 60, 0, 0, 0.35 },
			RightLeg = { -30, 0, 8 },
			LeftLeg = { 62, 0, -8 },
		} },
		{ t = 0.3, ease = "Sine", dir = "Out", pose = {
			Torso = { 12, 40, 11, 0, 0.55, -0.68 },
			Head = { 26, -32, -7 },
			RightArm = { 150, 0, -14, 0, 0.15, -0.25 },
			LeftArm = { 118, 0, 62, 0, 0, 0.38 },
			RightLeg = { -34, 0, 8 },
			LeftLeg = { 70, 0, -8 },
		} },
		-- follow-through: fist all the way up, body stretched off the ground
		{ t = 0.38, ease = "Back", dir = "Out", pose = {
			Torso = { 18, 46, 12, 0, 0.6, -0.6 },
			Head = { 30, -36, -8 },
			RightArm = { 172, 0, -8, 0, 0.2, -0.1 },
			LeftArm = { 60, 0, 40, 0, 0, 0.2 },
			RightLeg = { -10, 0, 10 },
			LeftLeg = { 58, 0, -8 },
		} },
		-- unwind and tuck in the air
		{ t = 0.48, ease = "Sine", dir = "InOut", pose = {
			Torso = { 2, 6, 3, 0, 0.25, -0.2 },
			Head = { 14, -4, -2 },
			RightArm = { 120, 0, -30, 0, 0, 0.05 },
			LeftArm = { 104, 0, 30 },
			RightLeg = { 40, 0, 8 },
			LeftLeg = { 20, 0, -8 },
		} },
		{ t = 0.6, ease = "Sine", dir = "InOut", pose = pose(AIR_GUARD, {
			Torso = { -6, -22, -1, 0, 0.04, 0 },
			Head = { 9, 22, 1 },
			RightArm = { 96, 0, -44, 0, 0, 0.12 },
			RightLeg = { 50, 0, 8 },
			LeftLeg = { 10, 0, -8 },
		}) },
		{ t = 0.72, pose = AIR_GUARD },
	},
}

-- Air M1s: a straight and a spinning kick while hanging in the air. Each
-- one still shows a twist-away and a held coil before it fires.
Data.AirPunch = {
	length = 0.5, priority = "Action", group = "action", recover = 0.36,
	markers = { Swing = 0.1, Hit = 0.16 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = AIR_GUARD },
		{ t = 0.04, ease = "Cubic", dir = "Out", pose = {
			Torso = { -8, -6, -2, 0, 0.06, -0.04 },
			Head = { 10, 8, 2 },
			RightArm = { 104, 0, -38, 0, 0.04, 0.05 },
			LeftArm = { 110, 0, 26, 0, 0.03, -0.08 },
			RightLeg = { 50, 0, 8 },
			LeftLeg = { 18, 0, -8 },
		} },
		{ t = 0.085, ease = "Sine", dir = "InOut", pose = {
			Torso = { 4, -46, 6, 0, -0.05, 0.2 },
			Head = { 0, 40, -4 },
			RightArm = { 82, 0, -26, 0, 0, 0.5 },
			LeftArm = { 98, 0, 22, 0, 0, -0.25 },
			RightLeg = { 62, 0, 10 },
			LeftLeg = { 6, 0, -8 },
		} },
		{ t = 0.1, ease = "Quad", dir = "In", pose = {
			Torso = { 5, -50, 7, 0, -0.06, 0.22 },
			Head = { 0, 44, -5 },
			RightArm = { 80, 0, -24, 0, 0, 0.55 },
			LeftArm = { 97, 0, 21, 0, 0, -0.27 },
			RightLeg = { 64, 0, 10 },
			LeftLeg = { 4, 0, -8 },
		} },
		{ t = 0.16, ease = "Quad", dir = "Out", pose = {
			Torso = { -18, 42, -5, 0, 0, -0.5 },
			Head = { 16, -38, 5 },
			RightArm = { 96, 0, -6, 0, 0, -0.6 },
			LeftArm = { 118, 0, 58, 0, 0, 0.35 },
			RightLeg = { -12, 0, 10 },
			LeftLeg = { 62, 0, -8 },
		} },
		{ t = 0.2, ease = "Back", dir = "Out", pose = {
			Torso = { -20, 47, -6, 0, -0.02, -0.56 },
			Head = { 18, -42, 6 },
			RightArm = { 98, 0, -3, 0, 0, -0.65 },
			LeftArm = { 120, 0, 60, 0, 0, 0.38 },
			RightLeg = { -16, 0, 10 },
			LeftLeg = { 66, 0, -8 },
		} },
		{ t = 0.28, ease = "Sine", dir = "InOut", pose = {
			Torso = { -8, 8, -1, 0, 0.04, -0.15 },
			Head = { 10, -6, 1 },
			RightArm = { 94, 0, -32, 0, 0, 0 },
			LeftArm = { 106, 0, 36, 0, 0, 0.05 },
			RightLeg = { 30, 0, 8 },
			LeftLeg = { 34, 0, -8 },
		} },
		{ t = 0.38, ease = "Sine", dir = "InOut", pose = pose(AIR_GUARD, {
			Torso = { -6, -22, 1, 0, -0.03, 0.03 },
			Head = { 9, 22, -1 },
			RightLeg = { 50, 0, 8 },
			LeftLeg = { 10, 0, -8 },
		}) },
		{ t = 0.5, pose = AIR_GUARD },
	},
}

Data.AirKick = {
	length = 0.52, priority = "Action", group = "action", recover = 0.37,
	markers = { Swing = 0.1, Hit = 0.17 },
	trail = { "Left Leg" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = AIR_GUARD },
		{ t = 0.04, ease = "Cubic", dir = "Out", pose = {
			Torso = { -8, -24, 2, 0, -0.06, 0 },
			Head = { 10, 22, -2 },
			RightArm = { 104, 0, -44, 0, 0, 0.1 },
			LeftArm = { 112, 0, 26, 0, 0, -0.05 },
			RightLeg = { 50, 0, 8 },
			LeftLeg = { 20, 0, -8 },
		} },
		{ t = 0.085, ease = "Sine", dir = "InOut", pose = {
			Torso = { 2, 40, 10, 0, 0.08, 0.1 },
			Head = { 2, -36, -8 },
			RightArm = { 96, 0, -64 },
			LeftArm = { 50, 0, -24 },
			RightLeg = { 34, 0, 10 },
			LeftLeg = { 76, 0, -36 },
		} },
		{ t = 0.1, ease = "Quad", dir = "In", pose = {
			Torso = { 3, 46, 11, 0, 0.1, 0.12 },
			Head = { 2, -40, -9 },
			RightArm = { 94, 0, -68 },
			LeftArm = { 46, 0, -26 },
			RightLeg = { 32, 0, 10 },
			LeftLeg = { 80, 0, -40 },
		} },
		{ t = 0.135, ease = "Linear", pose = {
			Torso = { 4, -6, -12, 0, 0.12, -0.05 },
			Head = { 4, 6, 8 },
			RightArm = { 70, 0, 10 },
			LeftArm = { 20, 0, -30 },
			RightLeg = { 30, 0, 12 },
			LeftLeg = { 50, -20, -80 },
		} },
		{ t = 0.17, ease = "Quad", dir = "Out", pose = {
			Torso = { 4, -56, -26, 0, 0.15, -0.2 },
			Head = { 4, 50, 20 },
			RightArm = { 60, 0, 72 },
			LeftArm = { -10, 0, -30 },
			RightLeg = { 30, 0, 14 },
			LeftLeg = { 6, -40, -96 },
		} },
		{ t = 0.21, ease = "Back", dir = "Out", pose = {
			Torso = { 4, -68, -28, 0, 0.15, -0.25 },
			Head = { 4, 60, 22 },
			RightArm = { 56, 0, 74 },
			LeftArm = { -14, 0, -34 },
			RightLeg = { 30, 0, 14 },
			LeftLeg = { 6, -24, -94 },
		} },
		{ t = 0.3, ease = "Sine", dir = "InOut", pose = pose(AIR_GUARD, {
			Torso = { -4, -30, -8, 0, 0.05, 0 },
			Head = { 6, 26, 6 },
			RightArm = { 90, 0, -20 },
			LeftArm = { 90, 0, 10 },
			LeftLeg = { 44, 0, -28 },
		}) },
		{ t = 0.41, ease = "Sine", dir = "InOut", pose = pose(AIR_GUARD, {
			Torso = { -6, -8, 2, 0, 0.02, 0 },
			Head = { 9, 12, -2 },
			LeftLeg = { 10, 0, -10 },
		}) },
		{ t = 0.52, pose = AIR_GUARD },
	},
}

Data.Downslam = {
	length = 0.72, priority = "Action", group = "action", recover = 0.58,
	markers = { Swing = 0.22, Hit = 0.3 },
	trail = { "Right Arm", "Left Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = AIR_GUARD },
		{ t = 0.06, ease = "Cubic", dir = "Out", pose = {
			Torso = { -16, -6, 0, 0, -0.1, 0 },
			Head = { 14, 6, 0 },
			RightArm = { 70, 0, -30, 0, 0, 0.1 },
			LeftArm = { 76, 0, 24 },
			RightLeg = { 64, 0, 8 },
			LeftLeg = { 44, 0, -8 },
		} },
		{ t = 0.14, ease = "Sine", dir = "InOut", pose = SPC_SLAM_RAISE },
		{ t = 0.22, ease = "Quad", dir = "In", pose = pose(SPC_SLAM_RAISE, {
			Torso = { 30, 0, 0, 0, 0.42, 0.3 },
			Head = { -20, 0, 0 },
			RightArm = { 206, 0, -12 },
			LeftArm = { 206, 0, 12 },
			RightLeg = { -50, 0, 8 },
			LeftLeg = { -34, 0, -8 },
		}) },
		{ t = 0.26, ease = "Linear", pose = {
			Torso = { -16, 0, 0, 0, 0.2, 0 },
			Head = { 10, 0, 0 },
			RightArm = { 160, 0, -14 },
			LeftArm = { 160, 0, 14 },
			RightLeg = { 10, 0, 8 },
			LeftLeg = { 20, 0, -8 },
		} },
		{ t = 0.3, ease = "Quad", dir = "Out", pose = {
			Torso = { -56, 0, 0, 0, -0.15, -0.45 },
			Head = { 46, 0, 0 },
			RightArm = { 92, 0, -16, 0, 0, -0.1 },
			LeftArm = { 92, 0, 16, 0, 0, -0.1 },
			RightLeg = { 70, 0, 10 },
			LeftLeg = { 80, 0, -8 },
		} },
		{ t = 0.35, ease = "Quad", dir = "In", pose = {
			Torso = { -62, 0, 0, 0, -0.25, -0.5 },
			Head = { 50, 0, 0 },
			RightArm = { 80, 0, -18 },
			LeftArm = { 80, 0, 18 },
			RightLeg = { 74, 0, 10 },
			LeftLeg = { 84, 0, -8 },
		} },
		{ t = 0.44, ease = "Back", dir = "Out", pose = {
			Torso = { -30, -6, 0, 0, -0.95, -0.3 },
			Head = { 26, 6, 0 },
			RightArm = { 50, 0, -10 },
			LeftArm = { 54, 0, 10 },
			RightLeg = { -6, 0, 22 },
			LeftLeg = { 70, 0, -16 },
		} },
		{ t = 0.54, ease = "Sine", dir = "InOut", pose = {
			Torso = { -12, -14, 0, 0, -0.35, -0.1 },
			Head = { 12, 14, 0 },
			RightArm = { 96, 0, -36, 0, 0, 0.1 },
			LeftArm = { 100, 0, 26 },
			RightLeg = { 4, 0, 12 },
			LeftLeg = { 30, 0, -8 },
		} },
		{ t = 0.63, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -10, -26, 1, 0, -0.28, 0.04 },
			Head = { 10, 24, -1 },
		}) },
		{ t = 0.72, pose = GUARD },
	},
}

Data.RunningAttack = {
	length = 0.7, priority = "Action", group = "action", recover = 0.52,
	markers = { Swing = 0.16, Hit = 0.24 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		{ t = 0.05, ease = "Quad", dir = "Out", pose = {
			Torso = { -20, -14, 0, 0, -0.55, 0 },
			Head = { 18, 12, 0 },
			RightArm = { 60, 0, -20, 0, 0, 0.2 },
			LeftArm = { 80, 0, 20 },
			RightLeg = { 10, 0, 10 },
			LeftLeg = { 40, 0, -8 },
		} },
		{ t = 0.11, ease = "Sine", dir = "InOut", pose = SPC_SUPER_COIL },
		{ t = 0.16, ease = "Quad", dir = "In", pose = pose(SPC_SUPER_COIL, {
			Torso = { 4, -42, 7, 0, 0.15, 0.25 },
			Head = { 0, 38, -5 },
			RightArm = { 196, 0, 32, 0, 0, 0.3 },
			LeftArm = { 98, 0, 18, 0, 0, -0.25 },
			RightLeg = { 82, 0, 10 },
			LeftLeg = { -8, 0, -6 },
		}) },
		{ t = 0.2, ease = "Linear", pose = {
			Torso = { -38, 0, 2, 0, 0.45, -0.4 },
			Head = { 34, 0, 0 },
			RightArm = { 190, 0, 10 },
			LeftArm = { 60, 0, 20, 0, 0, 0.2 },
			RightLeg = { 20, 0, 8 },
			LeftLeg = { -10, 0, -6 },
		} },
		{ t = 0.24, ease = "Quad", dir = "Out", pose = {
			Torso = { -74, 28, 0, 0, 0.5, -0.9 },
			Head = { 62, -20, 0 },
			RightArm = { 168, 0, -8, 0, 0, -0.3 },
			LeftArm = { 20, 0, 20, 0, 0, 0.2 },
			RightLeg = { -6, 0, 6 },
			LeftLeg = { 20, 0, -6 },
		} },
		{ t = 0.29, ease = "Quad", dir = "In", pose = {
			Torso = { -78, 32, 0, 0, 0.4, -1.0 },
			Head = { 66, -22, 0 },
			RightArm = { 172, 0, -6, 0, 0, -0.35 },
			LeftArm = { 14, 0, 22, 0, 0, 0.2 },
			RightLeg = { -10, 0, 6 },
			LeftLeg = { 16, 0, -6 },
		} },
		{ t = 0.36, ease = "Back", dir = "Out", pose = {
			Torso = { -26, 4, 0, 0, -0.8, -0.7 },
			Head = { 24, -4, 0 },
			RightArm = { 100, 0, -20 },
			LeftArm = { 70, 0, -50 },
			RightLeg = { -14, 0, 16 },
			LeftLeg = { 66, 0, -10 },
		} },
		{ t = 0.45, ease = "Sine", dir = "InOut", pose = {
			Torso = { 6, -16, 4, 0, -0.65, -0.4 },
			Head = { -2, 14, -2 },
			RightArm = { 80, 0, 40 },
			LeftArm = { 90, 0, -30 },
			RightLeg = { -30, 0, 16 },
			LeftLeg = { 40, 0, -10 },
		} },
		{ t = 0.57, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -12, -26, 1, 0, -0.32, 0.05 },
			Head = { 12, 24, -1 },
		}) },
		{ t = 0.7, pose = GUARD },
	},
}

-- Air M1s: alternate a straight and a spinning kick while hanging in the air.

-- Air finisher / jump attack: both fists overhead, the whole body folds
-- forward and hammers down.

-- Superman punch off a sprint: launches horizontal with the fist leading.

-- Feint: the swing is pulled with a shoulder roll and a hop back to guard.
Data.Feint = {
	length = 0.32, priority = "Action", group = "action",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, {
			Torso = { -2, 10, 4, 0, -0.32, 0.25 },
			Head = { 4, -6, -2 },
			RightArm = { 80, 0, -50, 0, 0, 0.3 },
			LeftArm = { 84, 0, 46, 0, 0, 0.2 },
		}) },
		{ t = 0.12, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -10, -30, -2, 0, -0.18, 0.1 },
			Head = { 10, 26, 2 },
		}) },
		{ t = 0.32, pose = GUARD },
	},
}

------------------------------------------------------------------------
-- Defense

Data.Block = {
	length = 1.2, looped = true, priority = "Action", group = "hold",
	keys = {
		{ t = 0, ease = "Sine", dir = "InOut", pose = BLOCK },
		{ t = 0.6, ease = "Sine", dir = "InOut", pose = pose(BLOCK, {
			Torso = { -14, -7, 0, 0, -0.36, 0 },
			Head = { -12, 4, 0 },
			RightArm = { 115, 0, -57, 0, -0.03, 0.15 },
			LeftArm = { 109, 0, 51, 0, -0.03, 0.05 },
		}) },
		{ t = 1.2, pose = BLOCK },
	},
}

-- Absorbing a hit on the guard: shoved back, arms crushed in, rebound.
Data.BlockImpact = {
	length = 0.3, priority = "Action3", group = "overlay",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = BLOCK },
		{ t = 0.04, ease = "Sine", dir = "InOut", pose = {
			Torso = { 6, -2, 0, 0, -0.42, 0.4 },
			Head = { -22, 4, 0 },
			RightArm = { 128, 0, -64, 0, 0, 0.35 },
			LeftArm = { 122, 0, 58, 0, 0, 0.3 },
		} },
		{ t = 0.13, ease = "Back", dir = "Out", pose = {
			Torso = { -16, -8, 0, 0, -0.36, -0.05 },
			Head = { -8, 4, 0 },
			RightArm = { 114, 0, -56, 0, 0, 0.1 },
			LeftArm = { 108, 0, 50 },
		} },
		{ t = 0.3, pose = BLOCK },
	},
}

-- Successful parry: the lead hand slaps the strike aside, rear hand cocked.
Data.Deflect = {
	length = 0.38, priority = "Action4", group = "overlay",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = BLOCK },
		{ t = 0.05, ease = "Sine", dir = "InOut", pose = {
			Torso = { 4, 26, -6, 0, -0.3, 0.25 },
			Head = { 6, -18, 4 },
			RightArm = { 92, 0, -30, 0, 0, 0.35 },
			LeftArm = { 150, 0, -52, 0, 0, -0.1 },
		} },
		{ t = 0.13, ease = "Back", dir = "Out", pose = {
			Torso = { 2, 30, -7, 0, -0.3, 0.3 },
			Head = { 6, -22, 4 },
			RightArm = { 88, 0, -28, 0, 0, 0.4 },
			LeftArm = { 156, 0, -60, 0, 0, -0.1 },
		} },
		{ t = 0.38, pose = GUARD_UPPER },
	},
}

------------------------------------------------------------------------
-- Reactions

-- The parried attacker: arms batted up and away, stumbling back.
Data.Parried = {
	length = 0.5, priority = "Action3", group = "react",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.05, ease = "Sine", dir = "InOut", pose = {
			Torso = { 26, 14, 6, 0, -0.1, 0.5 },
			Head = { 30, -8, 4 },
			RightArm = { 156, 0, 48 },
			LeftArm = { 132, 0, -34 },
			RightLeg = { -20, 0, 10 },
			LeftLeg = { 26, 0, -10 },
		} },
		{ t = 0.17, ease = "Sine", dir = "InOut", pose = {
			Torso = { 18, 10, 4, 0, -0.2, 0.7 },
			Head = { 20, -6, 3 },
			RightArm = { 140, 0, 40 },
			LeftArm = { 120, 0, -24 },
			RightLeg = { -14, 0, 10 },
			LeftLeg = { 16, 0, -10 },
		} },
		{ t = 0.32, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { 2, -10, 0, 0, -0.24, 0.4 },
			Head = { 4, 10, 0 },
		}) },
		{ t = 0.5, pose = GUARD },
	},
}

-- Clean hits. The client picks one of the variants at random.
Data.HitFront = {
	length = 0.46, priority = "Action3", group = "react", variants = { "HitFront", "HitFrontB", "HitFrontC" },
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.04, ease = "Sine", dir = "InOut", pose = {
			Torso = { 24, 16, 8, 0, -0.15, 0.45 },
			Head = { 34, 14, 10 },
			RightArm = { 54, 0, 52 },
			LeftArm = { 76, 0, -34 },
			RightLeg = { -14, 0, 12 },
			LeftLeg = { 18, 0, -12 },
		} },
		{ t = 0.12, ease = "Sine", dir = "InOut", pose = {
			Torso = { 28, 20, 9, 0, -0.18, 0.55 },
			Head = { 38, 16, 11 },
			RightArm = { 48, 0, 56 },
			LeftArm = { 70, 0, -38 },
			RightLeg = { -16, 0, 12 },
			LeftLeg = { 20, 0, -12 },
		} },
		{ t = 0.28, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -4, -6, 0, 0, -0.26, 0.3 },
			Head = { 4, 6, 0 },
		}) },
		{ t = 0.46, pose = GUARD },
	},
}

-- Head turned by a hook.
Data.HitFrontB = {
	length = 0.46, priority = "Action3", group = "react",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.04, ease = "Sine", dir = "InOut", pose = {
			Torso = { 14, -44, -12, 0, -0.2, 0.3 },
			Head = { 20, -40, -18 },
			RightArm = { 70, 0, 20 },
			LeftArm = { 40, 0, -60 },
			RightLeg = { -6, 0, 16 },
			LeftLeg = { 22, 0, -6 },
		} },
		{ t = 0.12, ease = "Sine", dir = "InOut", pose = {
			Torso = { 16, -52, -14, 0, -0.22, 0.36 },
			Head = { 22, -46, -20 },
			RightArm = { 66, 0, 24 },
			LeftArm = { 36, 0, -64 },
			RightLeg = { -6, 0, 16 },
			LeftLeg = { 24, 0, -6 },
		} },
		{ t = 0.28, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -4, -8, 0, 0, -0.26, 0.2 },
			Head = { 4, 8, 0 },
		}) },
		{ t = 0.46, pose = GUARD },
	},
}

-- Folded over by a body shot.
Data.HitFrontC = {
	length = 0.5, priority = "Action3", group = "react",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.05, ease = "Sine", dir = "InOut", pose = {
			Torso = { -38, -10, 4, 0, -0.55, 0.4 },
			Head = { -16, 8, 0 },
			RightArm = { 40, 0, -40 },
			LeftArm = { 44, 0, 40 },
			RightLeg = { 30, 0, 12 },
			LeftLeg = { 46, 0, -12 },
		} },
		{ t = 0.15, ease = "Sine", dir = "InOut", pose = {
			Torso = { -42, -12, 5, 0, -0.6, 0.5 },
			Head = { -20, 10, 0 },
			RightArm = { 36, 0, -44 },
			LeftArm = { 40, 0, 44 },
			RightLeg = { 32, 0, 12 },
			LeftLeg = { 48, 0, -12 },
		} },
		{ t = 0.32, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -14, -14, 0, 0, -0.32, 0.25 },
			Head = { 12, 12, 0 },
		}) },
		{ t = 0.5, pose = GUARD },
	},
}

Data.HitBack = {
	length = 0.46, priority = "Action3", group = "react",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.04, ease = "Sine", dir = "InOut", pose = {
			Torso = { -30, 8, 0, 0, -0.25, -0.45 },
			Head = { -26, 0, 0 },
			RightArm = { 10, 0, 44 },
			LeftArm = { 14, 0, -44 },
			RightLeg = { 24, 0, 10 },
			LeftLeg = { 4, 0, -10 },
		} },
		{ t = 0.12, ease = "Sine", dir = "InOut", pose = {
			Torso = { -34, 10, 0, 0, -0.28, -0.55 },
			Head = { -30, 0, 0 },
			RightArm = { 4, 0, 48 },
			LeftArm = { 8, 0, -48 },
			RightLeg = { 26, 0, 10 },
			LeftLeg = { 6, 0, -10 },
		} },
		{ t = 0.28, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -14, -10, 0, 0, -0.26, -0.2 },
		}) },
		{ t = 0.46, pose = GUARD },
	},
}

-- Blasted away by a finisher: arched back, limbs trailing, then a backward
-- roll over the shoulders back onto the feet.
local BLASTED = {
	Head = { 40, 0, 0 },
	RightArm = { 120, 0, 40 },
	LeftArm = { 110, 0, -40 },
	RightLeg = { 46, 0, 10 },
	LeftLeg = { 30, 0, -10 },
}
local TUCK = {
	Head = { -30, 0, 0 },
	RightArm = { 130, 0, -20 },
	LeftArm = { 130, 0, 20 },
	RightLeg = { 100, 0, 6 },
	LeftLeg = { 96, 0, -6 },
}
Data.Knockback = {
	length = 1.0, priority = "Action4", group = "react",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.05, ease = "Sine", dir = "InOut", pose = pose(BLASTED, { Torso = { 56, 10, 6, 0, 0.1, 0.4 } }) },
		{ t = 0.3, ease = "Quad", dir = "In", pose = pose(BLASTED, { Torso = { 74, 14, 8, 0, 0, 0.4 } }) },
		{ t = 0.42, ease = "Linear", pose = pose(TUCK, { Torso = { 150, 0, 0, 0, -0.9, 0 } }) },
		{ t = 0.52, ease = "Linear", pose = pose(TUCK, { Torso = { 240, 0, 0, 0, -1.2, 0 } }) },
		{ t = 0.62, ease = "Quad", dir = "Out", pose = pose(TUCK, { Torso = { 320, 0, 0, 0, -1.0, 0 } }) },
		{ t = 0.74, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { 340, -20, 0, 0, -0.8, 0 },
			Head = { 30, 18, 0 },
			RightArm = { 60, 0, 30 },
			LeftArm = { 70, 0, -20 },
			RightLeg = { 10, 0, 22 },
			LeftLeg = { 58, 0, -18 },
		}) },
		{ t = 0.88, ease = "Sine", dir = "InOut", pose = pose(GUARD, { Torso = { 350, -20, 0, 0, -0.3, 0 } }) },
		{ t = 1.0, pose = pose(GUARD, { Torso = { 352, -20, 0, 0, -0.2, 0 } }) },
	},
}

-- Guard shattered: arms blown wide, a stagger back, then a dazed sway.
local DAZED = {
	Torso = { -22, 6, 8, 0, -0.5, 0.2 },
	Head = { -24, -8, 10 },
	RightArm = { 14, 0, 16 },
	LeftArm = { 18, 0, -14 },
	RightLeg = { 14, 0, 14 },
	LeftLeg = { 30, 0, -10 },
}
Data.GuardBreak = {
	length = 1.5, priority = "Action4", group = "react",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = pose(GUARD, BLOCK) },
		{ t = 0.06, ease = "Sine", dir = "InOut", pose = {
			Torso = { 32, 0, 0, 0, -0.1, 0.6 },
			Head = { 34, 0, 0 },
			RightArm = { 96, 0, 100 },
			LeftArm = { 96, 0, -100 },
			RightLeg = { -16, 0, 10 },
			LeftLeg = { 24, 0, -10 },
		} },
		{ t = 0.22, ease = "Sine", dir = "InOut", pose = {
			Torso = { 22, 0, -4, 0, -0.2, 0.85 },
			Head = { 24, 0, -4 },
			RightArm = { 80, 0, 80 },
			LeftArm = { 84, 0, -86 },
			RightLeg = { -10, 0, 12 },
			LeftLeg = { 14, 0, -12 },
		} },
		{ t = 0.5, ease = "Sine", dir = "InOut", pose = DAZED },
		{ t = 0.8, ease = "Sine", dir = "InOut", pose = pose(DAZED, {
			Torso = { -20, 2, -7, 0, -0.46, 0.2 },
			Head = { -20, 6, -10 },
		}) },
		{ t = 1.1, ease = "Sine", dir = "InOut", pose = pose(DAZED, {
			Torso = { -22, 8, 6, 0, -0.5, 0.2 },
			Head = { -22, -10, 8 },
		}) },
		{ t = 1.35, ease = "Back", dir = "Out", pose = pose(GUARD, { Torso = { -12, -16, 0, 0, -0.3, 0.1 } }) },
		{ t = 1.5, pose = GUARD },
	},
}

-- Spiked into the ground by a downslam: crushed flat, a bounce, then up.
local CRUSHED = {
	Torso = { 36, 4, 6, 0, -1.35, 0.35 },
	Head = { 30, -4, -6 },
	RightArm = { 150, 0, 50 },
	LeftArm = { 140, 0, -50 },
	RightLeg = { 84, 0, 8 },
	LeftLeg = { -14, 0, -12 },
}
Data.Slammed = {
	length = 1.15, priority = "Action4", group = "react",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.06, ease = "Quad", dir = "Out", pose = CRUSHED },
		{ t = 0.16, ease = "Quad", dir = "In", pose = pose(CRUSHED, {
			Torso = { 22, 4, 4, 0, -0.85, 0.3 },
			Head = { 18, -4, -4 },
			RightArm = { 110, 0, 40 },
			LeftArm = { 100, 0, -40 },
		}) },
		{ t = 0.26, ease = "Sine", dir = "InOut", pose = pose(CRUSHED, {
			Torso = { 32, 4, 4, 0, -1.25, 0.3 },
			RightArm = { 40, 0, 34 },
			LeftArm = { 46, 0, -40 },
		}) },
		{ t = 0.75, ease = "Sine", dir = "InOut", pose = pose(CRUSHED, {
			Torso = { 28, 4, 4, 0, -1.15, 0.3 },
			Head = { 18, -4, -4 },
			RightArm = { 30, 0, 34 },
			LeftArm = { 36, 0, -40 },
			RightLeg = { 80, 0, 6 },
		}) },
		{ t = 0.95, ease = "Back", dir = "Out", pose = pose(GUARD, { Torso = { -16, -16, 0, 0, -0.6, 0 } }) },
		{ t = 1.15, pose = GUARD },
	},
}

------------------------------------------------------------------------
-- Dashes (Q). Short and explosive: a low launch, a glide while the body
-- trails behind the movement, and a skid to a stop.

Data.DashForward = {
	length = 0.42, priority = "Action3", group = "action",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.04, ease = "Sine", dir = "Out", pose = {
			Torso = { -38, 0, 0, 0, -0.55, 0 },
			Head = { 34, 0, 0 },
			RightArm = { -40, 0, 26 },
			LeftArm = { -44, 0, -26 },
			RightLeg = { 10, 0, 8 },
			LeftLeg = { 70, 0, -6 },
		} },
		{ t = 0.2, ease = "Sine", dir = "InOut", pose = {
			Torso = { -46, 0, 0, 0, -0.62, 0 },
			Head = { 40, 0, 0 },
			RightArm = { -56, 0, 30 },
			LeftArm = { -60, 0, -30 },
			RightLeg = { 0, 0, 8 },
			LeftLeg = { 82, 0, -6 },
		} },
		{ t = 0.3, ease = "Back", dir = "Out", pose = {
			Torso = { -6, -14, 0, 0, -0.62, 0.2 },
			Head = { 8, 12, 0 },
			RightArm = { 80, 0, -30 },
			LeftArm = { 96, 0, 30 },
			RightLeg = { -20, 0, 16 },
			LeftLeg = { 40, 0, -10 },
		} },
		{ t = 0.42, pose = GUARD },
	},
}

local DASH_LEFT = {
	length = 0.42, priority = "Action3", group = "action",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.04, ease = "Sine", dir = "Out", pose = {
			Torso = { -14, -10, 26, 0, -0.6, 0 },
			Head = { 12, 10, -20 },
			RightArm = { 84, 0, 4 },
			LeftArm = { 70, 0, -10 },
			RightLeg = { 14, 0, 46 },
			LeftLeg = { 14, 0, -12 },
		} },
		{ t = 0.2, ease = "Sine", dir = "InOut", pose = {
			Torso = { -16, -10, 32, 0, -0.68, 0 },
			Head = { 14, 10, -24 },
			RightArm = { 80, 0, 14 },
			LeftArm = { 62, 0, -16 },
			RightLeg = { 14, 0, 54 },
			LeftLeg = { 16, 0, -14 },
		} },
		{ t = 0.3, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -12, -16, -8, 0, -0.5, 0 },
			Head = { 12, 16, 6 },
			RightLeg = { 4, 0, 16 },
			LeftLeg = { 26, 0, -20 },
		}) },
		{ t = 0.42, pose = GUARD },
	},
}
Data.DashLeft = DASH_LEFT
Data.DashRight = {
	length = DASH_LEFT.length, priority = DASH_LEFT.priority, group = DASH_LEFT.group,
	keys = mirrorKeys(DASH_LEFT.keys),
}
-- the mirrored first/last keys should still be the (asymmetric) guard
Data.DashRight.keys[1].pose = GUARD
Data.DashRight.keys[#Data.DashRight.keys].pose = GUARD

Data.DashBack = {
	length = 0.42, priority = "Action3", group = "action",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		{ t = 0.04, ease = "Sine", dir = "Out", pose = {
			Torso = { 18, -6, 0, 0, -0.4, 0.15 },
			Head = { -8, 6, 0 },
			RightArm = { 110, 0, -36 },
			LeftArm = { 116, 0, 30 },
			RightLeg = { 36, 0, 10 },
			LeftLeg = { 4, 0, -10 },
		} },
		{ t = 0.2, ease = "Sine", dir = "InOut", pose = {
			Torso = { 22, -6, 0, 0, -0.35, 0.2 },
			Head = { -12, 6, 0 },
			RightArm = { 116, 0, -40 },
			LeftArm = { 120, 0, 34 },
			RightLeg = { 44, 0, 10 },
			LeftLeg = { 10, 0, -10 },
		} },
		{ t = 0.3, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -18, -20, 0, 0, -0.55, -0.1 },
			Head = { 18, 18, 0 },
			RightLeg = { 6, 0, 14 },
			LeftLeg = { 36, 0, -10 },
		}) },
		{ t = 0.42, pose = GUARD },
	},
}

-- Air dash: flattens out horizontally and streaks.
Data.DashAir = {
	length = 0.42, priority = "Action3", group = "action",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = AIR_GUARD },
		{ t = 0.05, ease = "Sine", dir = "Out", pose = {
			Torso = { -66, 0, 0, 0, 0.2, 0 },
			Head = { 56, 0, 0 },
			RightArm = { -30, 0, 22 },
			LeftArm = { -34, 0, -22 },
			RightLeg = { 6, 0, 6 },
			LeftLeg = { 24, 0, -6 },
		} },
		{ t = 0.22, ease = "Sine", dir = "InOut", pose = {
			Torso = { -72, 0, 0, 0, 0.2, 0 },
			Head = { 60, 0, 0 },
			RightArm = { -40, 0, 26 },
			LeftArm = { -44, 0, -26 },
			RightLeg = { 0, 0, 6 },
			LeftLeg = { 18, 0, -6 },
		} },
		{ t = 0.32, ease = "Back", dir = "Out", pose = pose(AIR_GUARD, { Torso = { -14, -10, 0 } }) },
		{ t = 0.42, pose = AIR_GUARD },
	},
}

------------------------------------------------------------------------
-- Slash skill (Y). Unchanged moves; only their start/end blend into the new
-- guard.

Data.SkillCast = {
	length = 0.62, priority = "Action", group = "action", recover = 0.55,
	markers = { Swing = 0.16, Hit = 0.22 },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		{ t = 0.14, ease = "Back", dir = "Out", pose = {
			Torso = { 2, 38, 4, 0, -0.12, 0.1 },
			Head = { 4, -30, 0 },
			RightArm = { 92, 0, 62, 0, 0.1, -0.2 },
			LeftArm = { 20, 0, 20 },
			RightLeg = { 8, 0, 4 },
			LeftLeg = { -10, 0, -4 },
		} },
		{ t = 0.22, ease = "Quad", dir = "Out", pose = {
			Torso = { -6, -40, -4, 0, -0.18, -0.2 },
			Head = { -2, 30, 0 },
			RightArm = { 96, 0, -78, 0, 0, -0.3 },
			LeftArm = { 30, 0, 26 },
			RightLeg = { -16, 0, 6 },
			LeftLeg = { 18, 0, -6 },
		} },
		{ t = 0.38, ease = "Sine", dir = "InOut", pose = {
			Torso = { -4, -34, -3, 0, -0.14, -0.15 },
			Head = { 0, 26, 0 },
			RightArm = { 90, 0, -84, 0, 0, -0.25 },
			LeftArm = { 28, 0, 24 },
			RightLeg = { -12, 0, 4 },
			LeftLeg = { 14, 0, -4 },
		} },
		{ t = 0.62, pose = GUARD },
	},
}

-- Caught in the slashes: the body jerks between cuts (springs add the chaos).
local function jolt(p, y, r, armL, armR)
	return {
		Torso = { p, y, r, 0, -0.05, 0 },
		Head = { p * 1.4, -y, -r },
		RightArm = { 40 + armR, 0, 30 },
		LeftArm = { 40 + armL, 0, -30 },
		RightLeg = { -p * 0.4, 0, 6 },
		LeftLeg = { p * 0.4, 0, -6 },
	}
end
Data.Captured = {
	length = 0.48, looped = true, priority = "Action4", group = "react",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = jolt(14, 8, 6, 20, -10) },
		{ t = 0.12, ease = "Quad", dir = "Out", pose = jolt(-8, -10, -5, -12, 24) },
		{ t = 0.24, ease = "Quad", dir = "Out", pose = jolt(18, -4, 8, 26, 4) },
		{ t = 0.36, ease = "Quad", dir = "Out", pose = jolt(-4, 12, -7, -6, 18) },
		{ t = 0.48, pose = jolt(14, 8, 6, 20, -10) },
	},
}

-- Afterwards: down on one knee, head hanging, then back up.
local KNEEL = {
	Torso = { 24, 0, 4, 0, -1.2, 0.3 },
	Head = { 34, 6, 0 },
	RightArm = { 12, 0, 18 },
	LeftArm = { 30, 0, -10, 0, 0, 0 },
	RightLeg = { 84, 0, 4 },
	LeftLeg = { -10, 0, -8 },
}
Data.Kneel = {
	length = 2, priority = "Action4", group = "react",
	keys = {
		{ t = 0, ease = "Back", dir = "Out", pose = GUARD },
		{ t = 0.25, ease = "Sine", dir = "InOut", pose = KNEEL },
		{ t = 1.0, ease = "Sine", dir = "InOut", pose = pose(KNEEL, { Torso = { 28, 0, 4, 0, -1.25, 0.3 }, Head = { 38, 4, 0 } }) },
		{ t = 1.65, ease = "Quad", dir = "InOut", pose = KNEEL },
		{ t = 2, pose = GUARD },
	},
}

------------------------------------------------------------------------
-- Detailing: overlap and follow-through on every swing, floppier arms and
-- head on the walk and run (see detail() at the top).

local TRAIL_JOINT = { ["Right Arm"] = "RightArm", ["Left Arm"] = "LeftArm", ["Right Leg"] = "RightLeg", ["Left Leg"] = "LeftLeg" }

local EXAGGERATION = {
	M1_1 = 1.25, M1_2 = 1.25, M1_3 = 1.22, M1_4 = 1.15,
	Finisher = 1.2, Critical = 1.2, Uppercut = 1.15,
	RunningAttack = 1.12, Downslam = 1.12, AirPunch = 1.2, AirKick = 1.15,
}

for name, amount in pairs(EXAGGERATION) do
	local clip = exaggerate(Data[name], amount)
	local strikers = {}
	for _, limb in ipairs(clip.trail or {}) do
		strikers[TRAIL_JOINT[limb]] = true
	end
	local springs = { Head = { 5.2, 0.36 } }
	for _, joint in ipairs({ "RightArm", "LeftArm" }) do
		if not strikers[joint] then
			springs[joint] = { 6.5, 0.4 }
		end
	end
	for _, joint in ipairs({ "RightLeg", "LeftLeg" }) do
		if not strikers[joint] then
			springs[joint] = { 9, 0.5 }
		end
	end
	-- a kick's arms fly loose
	if strikers.RightLeg or strikers.LeftLeg then
		springs.RightArm = { 5.2, 0.36 }
		springs.LeftArm = { 5.2, 0.36 }
	end
	Data[name] = detail(clip, springs, 60)
end

Data.Walk = detail(Data.Walk, {
	Head = { 5, 0.45 },
	RightArm = { 4.2, 0.38 },
	LeftArm = { 4.2, 0.38 },
}, 40)
Data.Run = detail(Data.Run, {
	Head = { 6, 0.45 },
	RightArm = { 6, 0.42 },
	LeftArm = { 6, 0.42 },
}, 40)
Data.Stance = detail(Data.Stance, {
	Head = { 3.5, 0.5 },
	RightArm = { 4, 0.45 },
	LeftArm = { 4, 0.45 },
}, 30)

return Data

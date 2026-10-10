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

	Keys: motion runs on one smooth curve through all of a clip's keys (a
	monotone cubic, see the detailing pass): velocity carries through every
	key and only comes to rest where a joint reverses, so nothing snaps from
	pose to pose. Timing between keys is what shapes a move now. `ease`/`dir`
	are only used by AnimationBuilder's Animation Editor export.

	group:
	  base    - locomotion (Stance, Idle, Run, Jump, Fall), driven by the client
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

-- High guard: both gloves up side by side in front of the face (not
-- crossed), elbows tucked in, chin down behind them, shoulders hunched
-- forward. No legs, so the walk cycle keeps running underneath.
-- Guard pose, baked from Roblox animation 81591715877632 (upper body).
-- The legs live in BLOCK_LEGS and play under the run cycle (see Data.Block).
local BLOCK = {
	Torso = { -8.036, 0, 0 },
	Head = { 0, 0, 0 },
	RightArm = { 74.463, -26.082, -71.52 },
	LeftArm = { 96.088, 29.471, 76.579 },
}
local BLOCK_LEGS = {
	RightLeg = { 0, -8.192, 0, 0.055, 0, -0.385 },
	LeftLeg = { 0, 45.664, 0, -0.051, 0, 0.603 },
}

-- `base` with each joint's values shifted by `deltas` (same layout).
local function nudge(base, deltas)
	local result = {}
	for joint, value in pairs(base) do
		local d = deltas[joint]
		if d then
			local v = {}
			for i = 1, math.max(#value, #d) do
				v[i] = (value[i] or 0) + (d[i] or 0)
			end
			result[joint] = v
		 else
			result[joint] = value
		end
	end
	return result
end

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
-- detail(clip, springs) resamples a clip along the smooth curve into dense keyframes (fps per
-- second) and runs the listed joints through damped springs while doing so:
-- they trail the joints that drive them and overshoot when those stop, i.e.
-- overlapping action and follow-through. Unlisted joints (the torso and the
-- striking limb) follow the authored poses exactly, so hit frames stay exact.
-- springs = { Joint = { frequency (Hz), damping ratio } }.

local function channels(value)
	return { value[1] or 0, value[2] or 0, value[3] or 0, value[4] or 0, value[5] or 0, value[6] or 0 }
end

-- Per joint: the authored keys with held values filled in, each with a
-- tangent per channel. Tangents follow the monotone cubic (PCHIP) rule:
-- velocity is continuous through every key, it only comes to rest where a
-- channel actually reverses, and the curve never overshoots between two
-- keys (the overshoots that sell a move are authored as keys of their own).
-- This replaces per-segment easing, which stopped the body dead on every
-- key and made moves read as a string of separate poses.
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
			table.insert(list, { t = key.t, v = channels(last[joint]) })
		end
	end

	for _, list in pairs(tracks) do
		local n = #list
		for i, k in ipairs(list) do
			local prev, prevT = list[i - 1], nil
			local nxt, nextT = list[i + 1], nil
			if prev then
				prevT = prev.t
			elseif clip.looped and n > 2 then
				-- the last key repeats the first one, so wrap past it
				prev = list[n - 1]
				prevT = prev.t - clip.length
			end
			if nxt then
				nextT = nxt.t
			elseif clip.looped and n > 2 then
				nxt = list[2]
				nextT = nxt.t + clip.length
			end

			local m = { 0, 0, 0, 0, 0, 0 }
			if prev and nxt then
				local h0, h1 = k.t - prevT, nextT - k.t
				if h0 > 1e-6 and h1 > 1e-6 then
					for c = 1, 6 do
						local d0 = (k.v[c] - prev.v[c]) / h0
						local d1 = (nxt.v[c] - k.v[c]) / h1
						if d0 * d1 > 0 then
							local w1, w2 = 2 * h1 + h0, h1 + 2 * h0
							m[c] = (w1 + w2) / (w1 / d0 + w2 / d1)
						end
					end
				end
			end
			-- one-shots start from and settle into rest (m stays zero at the ends)
			k.m = m
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
			local h = b.t - a.t
			local s = (t - a.t) / h
			local s2, s3 = s * s, s * s * s
			local h00 = 2 * s3 - 3 * s2 + 1
			local h10 = s3 - 2 * s2 + s
			local h01 = -2 * s3 + 3 * s2
			local h11 = s3 - s2
			local out = {}
			for c = 1, 6 do
				out[c] = h00 * a.v[c] + h10 * h * a.m[c] + h01 * b.v[c] + h11 * h * b.m[c]
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

local Config = require(script.Parent.Config)

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

-- The run is generated, not hand-keyed: 96 poses per cycle computed from
-- the R6 leg geometry so the planted foot travels backward at exactly
-- ground speed (no sliding), and both legs come from the same function half
-- a cycle apart (perfectly even, no limp). The client plays it back at
-- speed / speedRef, so the match holds at any movement speed.
--
-- Per leg, phase 0 is heel strike. While planted the foot moves linearly
-- under the body. In swing it follows a cubic whose end velocities match
-- the planted phase (so the leg never jerks at lift-off or touchdown), with
-- a knee-drive bump and a lift so the foot clears the ground. The torso
-- drops onto each contact by exactly what the leg angle needs, rocks over
-- the planted leg, counter-twists against the arms, and the head steadies
-- itself against all of it.

local LEG = 2 -- R6 hip pivot to sole

local function hermite(p0, p1, m0, m1, u)
	local u2, u3 = u * u, u * u * u
	return (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1
end

local function bell(u)
	return math.sin(math.pi * u) ^ 2 -- 0 -> 1 -> 0 with zero slope at both ends
end

-- The standard R6 joints, so the gait can be solved against the real rig.
local R6_ROOT = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0)
local R6_HIP = {
	[1] = { c0 = CFrame.new(1, -1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0), c1 = CFrame.new(0.5, 1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0), rot = CFrame.fromOrientation(0, math.pi / 2, 0) },
	[-1] = { c0 = CFrame.new(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), c1 = CFrame.new(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), rot = CFrame.fromOrientation(0, -math.pi / 2, 0) },
}
local R6_ROOT_ROT = CFrame.fromOrientation(-math.pi / 2, math.pi, 0)
local SOLE_HEIGHT = -3 -- sole below the root when standing

local function jointTransform(rot, v)
	local offset = CFrame.new(v[4] or 0, v[5] or 0, v[6] or 0) * CFrame.Angles(math.rad(v[1]), math.rad(v[2]), math.rad(v[3]))
	return rot:Inverse() * offset * rot
end

-- Sole position (root space) for a torso pose and one leg pose.
local function soleAt(torsoPose, legPose, side)
	local hip = R6_HIP[side]
	local torso = R6_ROOT * jointTransform(R6_ROOT_ROT, torsoPose) * R6_ROOT:Inverse()
	return (torso * hip.c0 * jointTransform(hip.rot, legPose) * hip.c1:Inverse()) * Vector3.new(0, -1, 0)
end

local function makeGait(g)
	local sweep = g.speed * g.duty * g.length -- sole travel while planted
	local reachFront = sweep * g.front

	local function body(p)
		local w = 2 * math.pi * p
		return {
			lean = g.lean + g.leanWave * math.cos(2 * w),
			yaw = -g.twist * math.cos(w), -- right shoulder back as the right foot lands
			roll = -g.rock * math.cos(w - math.pi * g.duty), -- tilt over the planted leg
			sway = g.sway * math.cos(w - math.pi * g.duty),
			-- lowest at mid-stance (weight sinking onto the leg), highest mid-flight
			bob = -g.bob * math.cos(4 * math.pi * (p - g.duty / 2)),
		}
	end

	-- The torso as PoseAnimator will actually pose it at this speed (its
	-- procedural lean included), and a leg in that frame with the torso's
	-- twist and tilt cancelled.
	local function geomTorso(b, y)
		return { b.lean + g.runtimeLean, b.yaw, b.roll, b.sway, y, 0 }
	end
	local function geomLeg(b, side, pitch, shift)
		return { pitch, -b.yaw, -b.roll + side * g.splay, 0, shift, 0 }
	end

	-- Shift along the torso that puts the sole at `targetY` for a given pitch
	-- (the sole's height is linear in the shift, so two probes solve it).
	local function shiftFor(torso, b, side, pitch, targetY)
		local y0 = soleAt(torso, geomLeg(b, side, pitch, 0), side).Y
		local y1 = soleAt(torso, geomLeg(b, side, pitch, 1), side).Y
		return (targetY - y0) / (y1 - y0)
	end

	-- Leg pitch and shift that put the sole at (z, height) in root space. The
	-- height is held exactly for every candidate pitch, then the pitch is
	-- searched for the forward offset, so the two never fight each other.
	local function solve(b, y, side, targetZ, targetY, pitchOnly)
		local torso = geomTorso(b, y)
		if pitchOnly then
			return pitchOnly, shiftFor(torso, b, side, pitchOnly, targetY)
		end
		local lo, hi = -80, 100
		for _ = 1, 40 do
			local mid = (lo + hi) / 2
			local z = soleAt(torso, geomLeg(b, side, mid, shiftFor(torso, b, side, mid, targetY)), side).Z
			-- more pitch = sole further forward (more negative z)
			if z > targetZ then
				lo = mid
			else
				hi = mid
			end
		end
		local pitch = (lo + hi) / 2
		return pitch, shiftFor(torso, b, side, pitch, targetY)
	end

	local function bodyFor(legPhase, side)
		return body(legPhase + (side == 1 and 0 or 0.5))
	end

	local function plan(base)
		-- planted: sole pinned to a floor spot moving back at exactly ground speed
		local function stance(legPhase, side)
			local b = bodyFor(legPhase, side)
			local z = -reachFront + sweep * (legPhase / g.duty)
			return solve(b, base + b.bob, side, z, SOLE_HEIGHT)
		end
		local e = 1e-3
		local pLift, sLift = stance(g.duty, 1)
		local pContact, sContact = stance(0, 1)
		local mLift = (pLift - stance(g.duty - e, 1)) / e * (1 - g.duty)
		local mContact = (stance(e, 1) - pContact) / e * (1 - g.duty)

		return function(legPhase, side)
			legPhase %= 1
			if legPhase < g.duty then
				return stance(legPhase, side)
			end
			-- swing: a cubic whose end angles and velocities match the planted
			-- leg (no jerk at lift-off or touchdown), plus knee drive. The leg
			-- tucks up into the hip by `lift` (R6 has no knee), and is only pulled
			-- down if the sole would otherwise scrape the floor.
			local u = (legPhase - g.duty) / (1 - g.duty)
			local pitch = hermite(pLift, pContact, mLift, mContact, u) + g.drive * math.sin(math.pi * u ^ 1.2) ^ 2
			local b = bodyFor(legPhase, side)
			local natural = sLift + (sContact - sLift) * (u * u * (3 - 2 * u)) + g.lift * bell(u)
			local _, floorShift = solve(b, base + b.bob, side, 0, SOLE_HEIGHT + 0.06 * bell(u), pitch)
			-- smooth max, so switching between the two never kinks the motion
			-- (its softness fades to zero at lift-off and touchdown, so the swing
			-- still meets the planted leg exactly)
			local k = 0.08 * bell(u) + 1e-4
			local shift = (natural + floorShift + math.sqrt((natural - floorShift) ^ 2 + k * k)) / 2
			return pitch, shift
		end
	end

	-- Sit the body low enough that a planted leg never has to drop more than
	-- `gap` out of the hip to reach the floor.
	local base = 0
	for _ = 1, 2 do
		local legAt = plan(base)
		local minShift = math.huge
		for i = 0, 40 do
			local _, shift = legAt(g.duty * i / 40, 1)
			minShift = math.min(minShift, shift)
		end
		if minShift < -g.gap then
			base -= (-g.gap - minShift)
		end
	end
	local legAt = plan(base)

	local keys = {}
	for i = 0, g.keys do
		local p = i / g.keys
		local b = body(p)
		local rPitch, rShift = legAt(p, 1)
		local lPitch, lShift = legAt(p + 0.5, -1)

		local function arm(phase, side)
			local swing = math.cos(2 * math.pi * (phase - g.armLag))
			local forward = math.max(0, -swing)
			return {
				g.armBias - g.armSwing * swing - b.lean * 0.7,
				side * g.armTwist * forward,
				side * (g.armOut - g.armCross * forward),
			}
		end

		-- authored leg pitch: PoseAnimator adds -runtimeLean to the legs at speed
		local right = geomLeg(b, 1, rPitch + g.runtimeLean, rShift)
		local left = geomLeg(b, -1, lPitch + g.runtimeLean, lShift)
		table.insert(keys, { t = p * g.length, pose = {
			Torso = { b.lean, b.yaw, b.roll, b.sway, base + b.bob, 0 },
			Head = { g.headPitch - b.lean * 0.75, -b.yaw * 0.85, -b.roll * 0.8 },
			RightArm = arm(p, 1),
			LeftArm = arm(p + 0.5, -1),
			RightLeg = right,
			LeftLeg = left,
		} })
	end
	keys[#keys].pose = keys[1].pose -- exact seam

	return {
		length = g.length, looped = true, priority = "Movement", group = "base",
		speedRef = g.speed, keys = keys,
	}
end

-- The one run cycle, used for all ground movement (there's no separate
-- walk). Authored for the middle of the speed range; the client plays it
-- at speed / speedRef, so the feet stay planted from walk speed (slower,
-- looser strides) up to a sprint (faster, harder strides). Upright chest,
-- head up, arms swinging from the shoulder.
local RUN_SPEED = (Config.WalkSpeed + Config.SprintSpeed) / 2
Data.Run = makeGait({
	speed = RUN_SPEED, length = 0.44, duty = 0.21, front = 0.35, keys = 96,
	runtimeLean = -RUN_SPEED * 0.12, -- PoseAnimator's lean at this speed
	gap = 0.08, bob = 0.11, lift = 0.45, drive = 24,
	lean = -3, leanWave = 1.2, twist = 9, rock = 2, sway = 0.05, splay = 1,
	headPitch = 3,
	armBias = 16, armSwing = 50, armLag = 0.03, armOut = 7, armCross = 12, armTwist = 8,
})

-- Unequipped (fists down): standing loose, arms hanging a little out from
-- the body. Weight drifts from foot to foot, the chest rises with a slow
-- breath and the head glances around once per loop.
local RELAXED = {
	Torso = { -1, 0, 0, 0, 0, 0 },
	Head = { 2, 0, 0 },
	RightArm = { 5, 0, 7 },
	LeftArm = { 5, 0, -7 },
	RightLeg = { 0, 0, 3 },
	LeftLeg = { 0, 0, -3 },
}
-- Idle: Roblox's default R6 idle (animation 180435571), baked 1:1 so it
-- plays through PoseAnimator like every other clip (Run/Jump/Fall sit
-- above it at Movement priority, so walking and running still take over).
Data.Idle = {
	length = 1.000000, looped = true, priority = "Idle", group = "base",
	sourceAssetId = "rbxassetid://180435571",
	keys = {
		{ t = 0.000000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000 },
			Head = { 0.009282, 0.014725, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { -0.031971, -0.012662, 0.057811, -0.000001, 0.000026, 0.000000 },
			LeftArm = { 0.051969, -0.438317, -0.011001, 0.000000, -0.003103, -0.000001 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000 },
		} },
		{ t = 0.050000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.001830, 0.000000 },
			Head = { 0.147193, -0.017704, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { -0.222195, -0.241789, 0.221966, 0.000000, 0.004133, 0.000000 },
			LeftArm = { -0.073052, -0.054775, -0.063255, 0.000000, 0.007690, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.001367, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.001696, 0.000000 },
		} },
		{ t = 0.100000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.003928, 0.000000 },
			Head = { 0.216349, -0.037128, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { -0.269526, -0.369274, 0.328084, 0.000000, 0.005899, 0.000000 },
			LeftArm = { -0.127712, 0.075974, -0.118316, 0.000000, 0.011064, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.002934, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.003639, 0.000000 },
		} },
		{ t = 0.150000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.009811, 0.000000 },
			Head = { 0.339480, -0.074656, 0.000000, 0.000000, -0.000001, 0.000000 },
			RightArm = { -0.309929, -0.561393, 0.509619, -0.000001, 0.008296, 0.000000 },
			LeftArm = { -0.210908, 0.234856, -0.246088, 0.000000, 0.015117, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.007327, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.009088, 0.000000 },
		} },
		{ t = 0.200000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.013305, 0.000000 },
			Head = { 0.387380, -0.089324, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { -0.302138, -0.584484, 0.555864, 0.000000, 0.008623, 0.000000 },
			LeftArm = { -0.235088, 0.264707, -0.300062, 0.000000, 0.015898, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.009936, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.012324, 0.000000 },
		} },
		{ t = 0.250000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.020647, 0.000000 },
			Head = { 0.440610, -0.102101, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { -0.208449, -0.458772, 0.537631, 0.000000, 0.007025, 0.000000 },
			LeftArm = { -0.233712, 0.216980, -0.344409, 0.000000, 0.014618, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.015419, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.019125, 0.000000 },
		} },
		{ t = 0.300000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.027442, 0.000000 },
			Head = { 0.416143, -0.082735, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { -0.031857, -0.189134, 0.442215, 0.000000, 0.003463, 0.000001 },
			LeftArm = { -0.161517, 0.001719, -0.336213, 0.000000, 0.008695, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.020494, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.025420, 0.000000 },
		} },
		{ t = 0.350000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.030259, 0.000000 },
			Head = { 0.373915, -0.060332, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.071391, -0.028361, 0.378270, 0.000000, 0.001314, 0.000000 },
			LeftArm = { -0.106914, -0.156532, -0.326532, 0.000000, 0.004350, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.022597, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.028029, 0.000000 },
		} },
		{ t = 0.400000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.034014, 0.000000 },
			Head = { 0.246659, 0.001948, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.277431, 0.296622, 0.238354, 0.000000, -0.003068, 0.000000 },
			LeftArm = { 0.023550, -0.529077, -0.297551, 0.000000, -0.005870, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.025401, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.031508, 0.000000 },
		} },
		{ t = 0.450000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.034685, 0.000000 },
			Head = { 0.169137, 0.038331, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.368024, 0.441296, 0.171148, 0.000000, -0.005038, 0.000000 },
			LeftArm = { 0.092999, -0.725384, -0.278882, 0.000000, -0.011255, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.025902, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.032129, 0.000000 },
		} },
		{ t = 0.500000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.033422, 0.000000 },
			Head = { 0.006761, 0.112357, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.490202, 0.641783, 0.067613, 0.000000, -0.007805, 0.000000 },
			LeftArm = { 0.223322, -1.089659, -0.235586, 0.000000, -0.021244, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.024959, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.030959, 0.000000 },
		} },
		{ t = 0.550000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.031734, 0.000000 },
			Head = { -0.070818, 0.146677, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.513127, 0.683669, 0.037703, 0.000000, -0.008416, -0.000001 },
			LeftArm = { 0.277951, -1.240149, -0.211987, 0.000000, -0.025369, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.023699, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.029396, 0.000000 },
		} },
		{ t = 0.600000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.026807, 0.000000 },
			Head = { -0.199620, 0.201166, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.502754, 0.677195, 0.004813, 0.000000, -0.008528, 0.000000 },
			LeftArm = { 0.349501, -1.431168, -0.164089, 0.000000, -0.030602, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.020019, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.024831, 0.000000 },
		} },
		{ t = 0.650000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.023791, 0.000000 },
			Head = { -0.242421, 0.217610, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.481607, 0.646597, -0.005787, 0.000000, -0.008278, 0.000000 },
			LeftArm = { 0.362000, -1.460169, -0.140994, 0.000000, -0.031388, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.017766, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.022037, 0.000000 },
		} },
		{ t = 0.700000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.017213, 0.000000 },
			Head = { -0.275882, 0.220303, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.413411, 0.542943, -0.015986, 0.000000, -0.007277, 0.000000 },
			LeftArm = { 0.349957, -1.414662, -0.098178, 0.000000, -0.029852, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.012855, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.015944, 0.000000 },
		} },
		{ t = 0.750000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.010655, 0.000000 },
			Head = { -0.259838, 0.184321, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.318345, 0.401418, -0.013064, 0.000000, -0.005757, 0.000000 },
			LeftArm = { 0.302482, -1.266626, -0.061493, 0.000000, -0.024959, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.007957, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.009869, 0.000000 },
		} },
		{ t = 0.800000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.007662, 0.000000 },
			Head = { -0.238123, 0.156933, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.263222, 0.323551, -0.007162, 0.000000, -0.004852, 0.000000 },
			LeftArm = { 0.268601, -1.160949, -0.046133, 0.000000, -0.021607, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.005722, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.007097, 0.000000 },
		} },
		{ t = 0.850000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.002809, 0.000000 },
			Head = { -0.168393, 0.093335, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.142151, 0.166846, 0.013063, 0.000000, -0.002846, 0.000000 },
			LeftArm = { 0.185375, -0.895455, -0.022806, 0.000000, -0.013892, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.002097, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.002602, 0.000000 },
		} },
		{ t = 0.900000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.001172, 0.000000 },
			Head = { -0.118602, 0.061536, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { 0.078152, 0.093851, 0.027216, -0.000001, -0.001786, 0.000000 },
			LeftArm = { 0.137980, -0.738792, -0.015528, 0.000000, -0.009855, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.000875, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.001086, 0.000000 },
		} },
		{ t = 0.950000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000 },
			Head = { 0.027215, 0.012376, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { -0.043086, -0.017934, 0.061364, 0.000000, 0.000207, 0.000000 },
			LeftArm = { 0.042973, -0.405543, -0.011116, 0.000000, -0.002432, 0.000000 },
			RightLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000 },
			LeftLeg = { 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000 },
		} },
		{ t = 1.000000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, 0.000000, 0.000000 },
			Head = { 0.009282, 0.014725, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightArm = { -0.031971, -0.012662, 0.057811, -0.000001, 0.000026, 0.000000 },
			LeftArm = { 0.051969, -0.438317, -0.011001, 0.000000, -0.003103, -0.000001 },
		} },
	},
}

-- E: fists come up. A small sink and pull back, then the hands snap up a
-- touch past the guard and settle into it.
Data.EquipIn = {
	length = 0.38, priority = "Action", group = "action",
	keys = {
		{ t = 0, pose = RELAXED },
		{ t = 0.08, pose = {
			Torso = { 2, -4, 0, 0, -0.06, 0 },
			Head = { 0, 4, 0 },
			RightArm = { -14, 0, 10 },
			LeftArm = { -12, 0, -10 },
			RightLeg = { 1, 0, 5 },
			LeftLeg = { 8, 0, -4 },
		} },
		{ t = 0.2, pose = {
			Torso = { -11, -22, 0, 0, -0.28, 0 },
			Head = { 10, 20, 0 },
			RightArm = { 110, 0, -47, 0, 0, 0.1 },
			LeftArm = { 118, 0, 33, 0, 0, -0.05 },
			RightLeg = { 3, 0, 10 },
			LeftLeg = { 26, 0, -6 },
		} },
		{ t = 0.38, pose = GUARD },
	},
}

-- E again: the guard drops, the hands shake out loose and hang.
Data.EquipOut = {
	length = 0.46, priority = "Action", group = "action",
	keys = {
		{ t = 0, pose = GUARD },
		{ t = 0.1, pose = {
			Torso = { -6, -10, 0, 0, -0.14, 0 },
			Head = { 6, 8, 0 },
			RightArm = { 32, 0, -12 },
			LeftArm = { 36, 0, 12 },
			RightLeg = { 1, 0, 6 },
			LeftLeg = { 12, 0, -5 },
		} },
		{ t = 0.21, pose = {
			Torso = { 0, -2, 1, 0, 0.05, 0 },
			Head = { 4, -4, 0 },
			RightArm = { -6, 0, 18 },
			LeftArm = { -4, 0, -18 },
			RightLeg = RELAXED.RightLeg,
			LeftLeg = RELAXED.LeftLeg,
		} },
		{ t = 0.31, pose = pose(RELAXED, {
			RightArm = { 9, 0, 3 },
			LeftArm = { 7, 0, -3 },
		}) },
		{ t = 0.46, pose = RELAXED },
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

-- Right hook: from Roblox animation 113429222873224 (upper body, legs stay on the stance).
Data.M1_1 = {
	length = 0.56, priority = "Action", group = "action", recover = 0.36,
	markers = { Swing = 0.167, Hit = 0.2 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, pose = {
			Torso = { -2.72, -56.41, 2.08 },
			Head = { -14.03, 39.4, 9.01 },
			RightArm = { 103.64, 0, 13.34, 0.106, 0.115, 0.435 },
			LeftArm = { 56.6, -0.01, -41.49, -0.109, -0.171, -0.144 },
		} },
		{ t = 0.0333, pose = {
			Torso = { -2.83, -54.75, 1.99 },
			Head = { -14.11, 39.81, 9.07 },
			RightArm = { 103.64, 0, 13.34, 0.106, 0.115, 0.435 },
			LeftArm = { 56.6, -0.01, -41.49, -0.109, -0.171, -0.144 },
		} },
		{ t = 0.0667, pose = {
			Torso = { -3.02, -51.27, 1.84 },
			Head = { -14.26, 40.5, 9.16 },
			RightArm = { 103.64, 0, 13.34, 0.106, 0.115, 0.435 },
			LeftArm = { 56.6, -0.01, -41.49, -0.109, -0.171, -0.144 },
		} },
		{ t = 0.1, pose = {
			Torso = { -3.17, -48.19, 1.72 },
			Head = { -14.29, 40.64, 9.18 },
			RightArm = { 103.64, 0, 13.34, 0.106, 0.115, 0.435 },
			LeftArm = { 56.6, -0.01, -41.49, -0.109, -0.171, -0.144 },
		} },
		{ t = 0.1333, pose = {
			Torso = { -3.19, -47.75, 1.71 },
			Head = { -14.03, 39.4, 9.01 },
			RightArm = { 103.64, 0, 13.34, 0.106, 0.115, 0.435 },
			LeftArm = { 56.6, -0.01, -41.49, -0.109, -0.171, -0.144 },
		} },
		{ t = 0.1667, pose = {
			Torso = { -4.29, -30.91, 0.47 },
			Head = { -9.13, 18.04, 5.58 },
			RightArm = { 91.42, -3.52, -2.48, 0.02, 0.01, 0.187 },
			LeftArm = { 56.6, -0.01, -41.5, -0.075, -0.233, 0.04 },
		} },
		{ t = 0.2, pose = {
			Torso = { -5.31, 8.95, -0.35 },
			Head = { -5.53, -15.11, 3.79 },
			RightArm = { 79.4, -0.2, -18.44, -0.065, -0.094, -0.061 },
			LeftArm = { 56.61, -0.01, -41.5, -0.042, -0.296, 0.224 },
		} },
		{ t = 0.2333, pose = {
			Torso = { -6.53, 50.89, -1.73 },
			Head = { -3.51, -46.55, 2.93 },
			RightArm = { 70.14, 9.15, -32.69, -0.151, -0.199, -0.309 },
			LeftArm = { 56.61, -0.01, -41.5, -0.008, -0.358, 0.408 },
		} },
		{ t = 0.2667, pose = {
			Torso = { -6.58, 73.9, -6.64 },
			Head = { -4.04, -62.77, 0.8 },
			RightArm = { 65.13, 22.8, -44.92, -0.237, -0.304, -0.556 },
			LeftArm = { 56.62, -0.01, -41.5, 0.026, -0.421, 0.592 },
		} },
		{ t = 0.3, pose = {
			Torso = { -10.51, 71.95, -4.71 },
			Head = { -4.04, -62.77, 0.8 },
			RightArm = { 65.13, 22.8, -44.92, -0.237, -0.304, -0.556 },
			LeftArm = { 56.62, -0.01, -41.5, 0.026, -0.421, 0.592 },
		} },
		{ t = 0.3333, pose = {
			Torso = { -9.28, 69.99, -3.16 },
			Head = { -4.04, -62.77, 0.8 },
			RightArm = { 65.13, 22.8, -44.92, -0.237, -0.304, -0.556 },
			LeftArm = { 56.62, -0.01, -41.5, 0.026, -0.421, 0.592 },
		} },
		{ t = 0.3667, pose = {
			Torso = { -8.4, 68.01, -1.87 },
			Head = { -4.04, -62.77, 0.8 },
			RightArm = { 65.13, 22.8, -44.92, -0.237, -0.304, -0.556 },
			LeftArm = { 56.62, -0.01, -41.5, 0.026, -0.421, 0.592 },
		} },
		{ t = 0.56, pose = GUARD_UPPER },
	},
}

-- Left hook: from Roblox animation 132633686577355 (upper body, legs stay on the stance).
Data.M1_2 = {
	length = 0.53, priority = "Action", group = "action", recover = 0.33,
	markers = { Swing = 0.15, Hit = 0.183 },
	trail = { "Left Arm" },
	keys = {
		{ t = 0, pose = {
			Torso = { -8.78, 62.63, -1.52 },
			Head = { -4.24, -54.57, 0.63 },
			RightArm = { 65.13, 22.8, -44.92, -0.237, -0.304, -0.556 },
			LeftArm = { 56.62, -0.01, -41.5, 0.026, -0.421, 0.592 },
		} },
		{ t = 0.0333, pose = {
			Torso = { -9.35, 48.44, -1.06 },
			Head = { 0.13, -44.24, 3.25 },
			RightArm = { 65.13, 22.8, -44.93, -0.236, -0.38, -0.479 },
			LeftArm = { 61.36, -3.56, -50.15, -0.073, -0.225, 0.283 },
		} },
		{ t = 0.0667, pose = {
			Torso = { -9.66, 34.25, -0.85 },
			Head = { 3.37, -33.9, 5.17 },
			RightArm = { 65.14, 22.8, -44.93, -0.235, -0.456, -0.402 },
			LeftArm = { 65.99, -8.2, -58.18, -0.172, -0.029, -0.026 },
		} },
		{ t = 0.1, pose = {
			Torso = { -9.79, 26.11, -0.78 },
			Head = { 3.66, -26.48, 4.73 },
			RightArm = { 63.99, 23.85, -44.48, -0.225, -0.537, -0.352 },
			LeftArm = { 71.01, -17.58, -54.74, -0.242, 0.057, -0.23 },
		} },
		{ t = 0.1333, pose = {
			Torso = { -9.88, 20.11, -0.75 },
			Head = { 2.28, -18.91, 3.01 },
			RightArm = { 62.82, 24.89, -44, -0.205, -0.579, -0.307 },
			LeftArm = { 75.33, -22.11, -41.34, -0.263, 0.046, -0.279 },
		} },
		{ t = 0.1667, pose = {
			Torso = { -10.35, -17.27, -0.73 },
			Head = { -1.28, 16.4, 2.08 },
			RightArm = { 58.85, 22.47, -26.27, -0.139, -0.472, -0.215 },
			LeftArm = { 66.86, -8.79, -16.63, -0.213, -0.108, -0.265 },
		} },
		{ t = 0.2, pose = {
			Torso = { -13.01, -76.3, -2.96 },
			Head = { -7.72, 70.9, 3.53 },
			RightArm = { 60.78, 20.52, 5.15, -0.032, -0.272, -0.109 },
			LeftArm = { 56.42, -0.12, 24.16, -0.11, -0.392, -0.234 },
		} },
		{ t = 0.2333, pose = {
			Torso = { -7.86, -107.11, 2.38 },
			Head = { -1.62, 99.24, -4.82 },
			RightArm = { 65.18, 22.8, 21.08, 0.043, -0.164, -0.04 },
			LeftArm = { 56.67, 0.01, 44.93, -0.025, -0.546, -0.205 },
		} },
		{ t = 0.2667, pose = {
			Torso = { -7.54, -105.12, 4.6 },
			Head = { 0.15, 96.77, -6.57 },
			RightArm = { 64.86, 22.74, 15.47, 0.071, -0.193, -0.012 },
			LeftArm = { 56.67, 0.01, 44.93, 0.019, -0.534, -0.177 },
		} },
		{ t = 0.3, pose = {
			Torso = { -5.16, -99.16, 5.98 },
			Head = { 13.65, 92.26, -20.04 },
			RightArm = { 64.85, 22.76, 4.81, 0.088, -0.245, 0.005 },
			LeftArm = { 56.67, 0.01, 44.93, 0.045, -0.514, -0.151 },
		} },
		{ t = 0.3333, pose = {
			Torso = { -0.94, -94.38, 9.23 },
			Head = { -71.27, 89.15, 64.9 },
			RightArm = { 65.17, 22.8, -1.05, 0.094, -0.274, 0.011 },
			LeftArm = { 56.67, 0.01, 44.92, 0.054, -0.502, -0.139 },
		} },
		{ t = 0.53, pose = GUARD_UPPER },
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

-- Critical (R): a long, readable charge with the body coiling and shaking,
-- then a corkscrew punch that lunges forward on the hit.
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

-- Holding the guard: a slow breath, the gloves sink and lift a touch.
-- Held guard. Upper body at Action priority; the legs only sit above the
-- idle/stance (jointPriority), so walking while blocking still steps.
Data.Block = {
	length = 1.4, looped = true, priority = "Action", group = "hold",
	jointPriority = { RightLeg = 1.5, LeftLeg = 1.5 },
	keys = {
		{ t = 0, ease = "Sine", dir = "InOut", pose = pose(BLOCK, BLOCK_LEGS) },
		{ t = 0.7, ease = "Sine", dir = "InOut", pose = pose(nudge(BLOCK, {
			Torso = { -1.2, 0, 0, 0, -0.04, 0 },
			RightArm = { 1.5, 0, 0 },
			LeftArm = { 1.5, 0, 0 },
		}), BLOCK_LEGS) },
		{ t = 1.4, pose = pose(BLOCK, BLOCK_LEGS) },
	},
}

-- Absorbing a hit on the guard: gloves driven back into the face, shoulders
-- rock back, then the guard rebounds a little past where it was and settles.
Data.BlockImpact = {
	length = 0.3, priority = "Action3", group = "overlay",
	keys = {
		{ t = 0, pose = BLOCK },
		-- guard driven back, shoulders rock
		{ t = 0.045, pose = nudge(BLOCK, {
			Torso = { 9, 0, 0, 0, -0.05, 0.3 },
			Head = { -8, 0, 0 },
			RightArm = { 10, 0, 0 },
			LeftArm = { 10, 0, 0 },
		}) },
		-- rebound a little past the guard, then settle
		{ t = 0.14, pose = nudge(BLOCK, {
			Torso = { -3, 0, 0, 0, 0, -0.06 },
			Head = { 2, 0, 0 },
			RightArm = { -3, 0, 0 },
			LeftArm = { -3, 0, 0 },
		}) },
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
-- Head Drive (Y). Timed to HeadDrive.T. The bodies themselves are moved by
-- HeadDrive's shared path (so they never desync); these clips pose the limbs
-- along the way. Legs are given as world angles and converted against the
-- torso's lean, so the feet stay under the body while it hunches and arches.

local HD_T = require(script.Parent.HeadDrive).T

local function stance(torso, head, rightArm, leftArm, rightLegWorld, leftLegWorld, legRoll)
	legRoll = legRoll or 7
	return {
		Torso = torso,
		Head = head,
		RightArm = rightArm,
		LeftArm = leftArm,
		RightLeg = { rightLegWorld - torso[1], 0, legRoll },
		LeftLeg = { leftLegWorld - torso[1], 0, -legRoll },
	}
end

local HD_GRAB = stance({ -18, 24, 3, 0, -0.42, -0.55 }, { 16, -20, -2 }, { 100, 0, -6, 0, 0, -0.45 }, { 72, 0, 32 }, -22, 38)

-- The reach: shoulder winds back, then the open hand shoots out at head
-- height. A miss overreaches a touch and recovers into guard.
Data.HeadDriveReach = {
	length = 0.52, priority = "Action", group = "action", recover = 0.48,
	markers = { Swing = 0.1, Hit = HD_T.GRAB_AT },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, pose = GUARD },
		{ t = 0.045, pose = stance({ -10, -18, -2, 0, -0.3, 0.1 }, { 10, 16, 0 }, { 92, 0, -30, 0, 0, 0.15 }, { 108, 0, 26 }, 2, 24) },
		-- cocked: right shoulder back, open hand by the ear
		{ t = 0.1, pose = stance({ -4, -30, -3, 0, -0.25, 0.3 }, { 4, 26, 2 }, { 62, -10, 18, 0, 0, 0.45 }, { 112, 0, 22, 0, 0, -0.1 }, 6, 18) },
		{ t = 0.145, pose = stance({ -12, 2, 0, 0, -0.35, -0.2 }, { 10, -2, 0 }, { 92, 0, -2, 0, 0, -0.1 }, { 96, 0, 26 }, -8, 30) },
		-- full reach, hand at head height
		{ t = HD_T.GRAB_AT, pose = HD_GRAB },
		{ t = 0.245, pose = stance({ -20, 28, 4, 0, -0.45, -0.62 }, { 18, -24, -3 }, { 98, 0, -2, 0, 0, -0.5 }, { 66, 0, 34 }, -24, 40) },
		{ t = 0.34, pose = stance({ -14, 4, 0, 0, -0.35, -0.2 }, { 12, -4, 0 }, { 96, 0, -30, 0, 0, 0.05 }, { 100, 0, 26 }, -6, 28) },
		{ t = 0.43, pose = stance({ -11, -24, 0, 0, -0.27, 0.04 }, { 10, 22, 0 }, { 103, 0, -44, 0, 0, 0.12 }, { 110, 0, 27, 0, 0, -0.06 }, 6, 20) },
		{ t = 0.52, pose = GUARD },
	},
}

local function headDriveAttackerKeys()
	local keys = {}
	local function key(t, pose)
		table.insert(keys, { t = t, pose = pose })
	end
	key(0, HD_GRAB)
	key(0.04, stance({ -6, 10, 1, 0, -0.2, -0.25 }, { 8, -8, 0 }, { 125, 0, -10, 0, 0, -0.2 }, { 60, 0, 34 }, -16, 26))
	-- yanks the head up
	key(HD_T.LIFT, stance({ 6, 0, 0, 0, 0.05, 0.05 }, { 0, 0, 0 }, { 160, 0, 5 }, { 50, 0, 30 }, -12, 14))
	-- and swings it down to the right side, the whole body following it
	key(0.14, stance({ -30, -14, -8, 0, -0.4, -0.2 }, { 24, -6, 0 }, { 100, 0, 30 }, { 10, 0, -30 }, -26, 32))
	key(HD_T.SLAM, stance({ -58, -18, -12, 0.15, -0.72, -0.3 }, { 44, -10, 0 }, { 45, 0, 18 }, { -30, 0, -28 }, -34, 40))
	key(0.24, stance({ -54, -16, -11, 0.15, -0.66, -0.3 }, { 42, -9, 0 }, { 48, 0, 16 }, { -20, 0, -24 }, -30, 36))

	-- The drag: a hunched sprint, the right hand down at the side pinning the
	-- head to the floor, the left arm pumping, strides lengthening as the run
	-- picks up speed. Their body trails behind alongside the right leg.
	local steps = 36
	for i = 0, steps do
		local u = i / steps
		local t = HD_T.DRAG_START + (HD_T.DRAG_END - HD_T.DRAG_START) * u
		local speed = (1 - math.cos(2 * math.pi * u)) / 2
		local amp = 0.35 + 0.65 * speed
		local phase = 2 * math.pi * 3.2 * (t - HD_T.DRAG_START)
		local scrape = math.noise(t * 20, 4.2)
		key(t, stance(
			{ -50 - 4 * speed + 2.5 * math.cos(2 * phase), -14 + 5 * math.sin(phase), -10 + 2 * math.sin(phase), 0.15, -0.62 + 0.07 * math.cos(2 * phase) - 0.08 * speed, 0 },
			{ 40 + 2 * math.sin(2 * phase), -8, 4 },
			{ 48 + 4 * scrape, 0, 14 + 3 * math.cos(phase) },
			{ 15 + 60 * amp * math.sin(phase + math.pi), 0, -12 },
			12 + 42 * amp * math.sin(phase),
			12 - 42 * amp * math.sin(phase),
			6
		))
	end

	-- plants the feet, keeping the head held down beside the right leg
	key(0.97, stance({ -48, -14, -8, 0.15, -0.64, 0 }, { 36, -8, 4 }, { 48, 0, 14 }, { 24, 0, -22 }, -24, 32))
	key(1.02, stance({ -42, -12, -6, 0.15, -0.55, 0 }, { 30, -8, 2 }, { 60, 0, 12 }, { 34, 0, -24 }, -22, 30))
	-- hauls the head up with the shoulder, holds the pull, then drives down hard
	key(HD_T.LIFT_END, stance({ -16, -12, -3, 0.15, -0.16, 0.18 }, { 12, -6, 2 }, { 114, -4, 8 }, { 62, 0, -30 }, -14, 24))
	key(1.125, stance({ -16, -12, -3, 0.15, -0.16, 0.18 }, { 12, -6, 2 }, { 114, -4, 8 }, { 62, 0, -30 }, -14, 24))
	key(HD_T.SLAM_SECOND, stance({ -72, -20, -15, 0.24, -1.0, -0.32 }, { 54, -12, 5 }, { 24, 0, 22 }, { -32, 0, -40 }, -38, 46))
	key(1.22, stance({ -62, -17, -12, 0.2, -0.86, -0.2 }, { 46, -10, 4 }, { 42, 0, 18 }, { -4, 0, -32 }, -32, 40))
	-- keeps the grip and snaps back into a second, heavier drive
	key(1.28, stance({ -38, -14, -6, 0.15, -0.42, 0.04 }, { 26, -8, 2 }, { 72, 0, 10 }, { 38, 0, -26 }, -22, 30))
	key(HD_T.LIFT_SECOND, stance({ -12, -12, -3, 0.15, -0.12, 0.22 }, { 10, -6, 2 }, { 120, -4, 8 }, { 66, 0, -32 }, -12, 22))
	key(1.405, stance({ -12, -12, -3, 0.15, -0.12, 0.22 }, { 10, -6, 2 }, { 120, -4, 8 }, { 66, 0, -32 }, -12, 22))
	key(HD_T.IMPACT, stance({ -76, -20, -16, 0.24, -1.08, -0.36 }, { 58, -12, 5 }, { 20, 0, 24 }, { -38, 0, -42 }, -40, 48))
	key(1.51, stance({ -64, -17, -12, 0.2, -0.88, -0.2 }, { 48, -10, 4 }, { 42, 0, 18 }, { 0, 0, -32 }, -32, 40))
	-- releases the head and rises straight back into guard
	key(HD_T.LAND, stance({ -40, -12, -5, 0.1, -0.5, -0.04 }, { 28, -6, 2 }, { 64, 0, -12 }, { 64, 0, 12 }, -20, 30))
	key(HD_T.ATTACKER_FREE, stance({ -14, -22, 0, 0, -0.32, 0.04 }, { 12, 20, 0 }, { 104, 0, -46, 0, 0, 0.12 }, { 112, 0, 28, 0, 0, -0.06 }, 4, 20))
	key(HD_T.LENGTH, GUARD)
	return keys
end

Data.HeadDrive = {
	length = HD_T.LENGTH, priority = "Action4", group = "action",
	keys = headDriveAttackerKeys(),
}

-- The victim. Their root stays face down through the drag and both ending
-- head slams, then rises back onto the feet. These poses sell the head pull,
-- the flinch into each impact, loose arms following the motion, and the
-- palms and knees pushing off the floor to recover.
local function headDrivenKeys()
	local keys = {}
	local function key(t, pose)
		table.insert(keys, { t = t, pose = pose })
	end
	key(0, { Torso = { -4, 0, 0 }, Head = { 6, 0, 0 }, RightArm = { 60, 0, 10 }, LeftArm = { 60, 0, -10 }, RightLeg = { 0, 0, 4 }, LeftLeg = { 0, 0, -4 } })
	key(0.04, { Torso = { 8, 0, 3 }, Head = { 24, 0, 0 }, RightArm = { 125, 0, 30 }, LeftArm = { 130, 0, -28 }, RightLeg = { 8, 0, 6 }, LeftLeg = { -6, 0, -6 } })
	key(HD_T.LIFT, { Torso = { 12, 0, 4 }, Head = { 28, 0, 0 }, RightArm = { 145, 0, 40 }, LeftArm = { 150, 0, -36 }, RightLeg = { 22, 0, 8 }, LeftLeg = { -12, 0, -8 } })
	key(0.14, { Torso = { -12, 0, 0 }, Head = { -14, 0, 0 }, RightArm = { 165, 0, 58 }, LeftArm = { 170, 0, -52 }, RightLeg = { -24, 0, 10 }, LeftLeg = { 16, 0, -8 } })
	key(HD_T.SLAM, { Torso = { -8, 0, 0 }, Head = { -28, 0, 0 }, RightArm = { 100, 0, 78 }, LeftArm = { 96, 0, -80 }, RightLeg = { 8, 0, 8 }, LeftLeg = { -6, 0, -8 } })
	key(0.25, { Torso = { -4, 0, 2 }, Head = { -20, 0, 0 }, RightArm = { 60, 0, 55 }, LeftArm = { 64, 0, -52 }, RightLeg = { -4, 0, 8 }, LeftLeg = { 4, 0, -8 } })

	-- dragged head first: arms trailing back along the body, everything rattling
	local steps = 36
	for i = 0, steps do
		local t = HD_T.DRAG_START + (HD_T.DRAG_END - HD_T.DRAG_START) * i / steps
		local n1, n2, n3 = math.noise(t * 17, 1.1), math.noise(t * 19, 2.3), math.noise(t * 23, 3.7)
		key(t, {
			Torso = { 3 * n1, 3 * n2, 4 * n3 },
			Head = { -22 + 5 * n2, 8 * n1, 0 },
			RightArm = { 12 + 10 * n3, 0, 22 + 10 * n1 },
			LeftArm = { 14 + 10 * n1, 0, -22 - 10 * n2 },
			RightLeg = { 4 + 6 * n2, 0, 8 + 4 * n3 },
			LeftLeg = { 2 + 6 * n3, 0, -8 - 4 * n1 },
		})
	end

	key(1.0, { Torso = { 0, 0, 0 }, Head = { -18, 0, 0 }, RightArm = { 18, 0, 30 }, LeftArm = { 20, 0, -28 }, RightLeg = { 2, 0, 6 }, LeftLeg = { 0, 0, -6 } })
	-- the neck and shoulders haul up, limbs hanging loose until the drive
	key(HD_T.LIFT_END, { Torso = { -10, 0, 3 }, Head = { 24, 0, 0 }, RightArm = { 18, 0, 28 }, LeftArm = { 22, 0, -26 }, RightLeg = { -14, 0, 8 }, LeftLeg = { -10, 0, -8 } })
	key(1.125, { Torso = { -10, 0, 3 }, Head = { 24, 0, 0 }, RightArm = { 18, 0, 28 }, LeftArm = { 22, 0, -26 }, RightLeg = { -14, 0, 8 }, LeftLeg = { -10, 0, -8 } })
	-- first ending slam: the whole body flinches, arms and feet kicked out
	key(HD_T.SLAM_SECOND, { Torso = { -16, 0, -3 }, Head = { -42, 0, 0 }, RightArm = { 104, 0, 74 }, LeftArm = { 110, 0, -72 }, RightLeg = { 24, 0, 14 }, LeftLeg = { -18, 0, -14 } })
	key(1.22, { Torso = { -4, 0, 3 }, Head = { -24, 0, 0 }, RightArm = { 58, 0, 48 }, LeftArm = { 64, 0, -46 }, RightLeg = { -8, 0, 10 }, LeftLeg = { 8, 0, -10 } })
	key(1.28, { Torso = { -3, 0, 1 }, Head = { -8, 0, 0 }, RightArm = { 28, 0, 32 }, LeftArm = { 32, 0, -30 }, RightLeg = { -8, 0, 8 }, LeftLeg = { -4, 0, -8 } })
	-- pulled up again, held a beat, then slammed straight back down
	key(HD_T.LIFT_SECOND, { Torso = { -12, 0, 3 }, Head = { 28, 0, 0 }, RightArm = { 16, 0, 30 }, LeftArm = { 20, 0, -28 }, RightLeg = { -16, 0, 8 }, LeftLeg = { -12, 0, -8 } })
	key(1.405, { Torso = { -12, 0, 3 }, Head = { 28, 0, 0 }, RightArm = { 16, 0, 30 }, LeftArm = { 20, 0, -28 }, RightLeg = { -16, 0, 8 }, LeftLeg = { -12, 0, -8 } })
	key(HD_T.IMPACT, { Torso = { -18, 0, -4 }, Head = { -46, 0, 0 }, RightArm = { 112, 0, 80 }, LeftArm = { 118, 0, -78 }, RightLeg = { 28, 0, 16 }, LeftLeg = { -22, 0, -16 } })
	key(1.51, { Torso = { -5, 0, 2 }, Head = { -26, 0, 0 }, RightArm = { 62, 0, 52 }, LeftArm = { 68, 0, -50 }, RightLeg = { -6, 0, 10 }, LeftLeg = { 8, 0, -10 } })
	key(HD_T.LAND, { Torso = { 0, 0, 0 }, Head = { -16, 0, 0 }, RightArm = { 30, 0, 30 }, LeftArm = { 34, 0, -28 }, RightLeg = { 4, 0, 6 }, LeftLeg = { 6, 0, -6 } })
	-- plants the palms, folds the knees under and pushes back onto the feet
	key(1.6, { Torso = { -12, 0, 0 }, Head = { 0, 0, 0 }, RightArm = { 66, 0, 18 }, LeftArm = { 70, 0, -18 }, RightLeg = { 32, 0, 8 }, LeftLeg = { 36, 0, -8 } })
	key(1.66, { Torso = { -34, 0, 0 }, Head = { 20, 0, 0 }, RightArm = { 54, 0, 14 }, LeftArm = { 58, 0, -14 }, RightLeg = { 62, 0, 8 }, LeftLeg = { 66, 0, -8 } })
	key(1.72, { Torso = { -36, -6, 0 }, Head = { 20, 6, 0 }, RightArm = { 70, 0, -10 }, LeftArm = { 76, 0, 10 }, RightLeg = { 70, 0, 9 }, LeftLeg = { 72, 0, -7 } })
	key(HD_T.LENGTH, { Torso = { -12, -14, 0, 0, -0.3, 0 }, Head = { 10, 12, 0 }, RightArm = { 96, 0, -40 }, LeftArm = { 104, 0, 26 }, RightLeg = { 2, 0, 9 }, LeftLeg = { 22, 0, -5 } })
	key(2.0, GUARD)
	return keys
end

Data.HeadDriven = {
	length = 2.0, priority = "Action4", group = "react",
	keys = headDrivenKeys(),
}

------------------------------------------------------------------------
-- Detailing: every clip is baked into dense keys on the smooth curve (see
-- jointTracks), with overlap and follow-through springs on the joints that
-- trail the motion.

local TRAIL_JOINT = { ["Right Arm"] = "RightArm", ["Left Arm"] = "LeftArm", ["Right Leg"] = "RightLeg", ["Left Leg"] = "LeftLeg" }

-- How far each strike's in-between poses are pushed out from its first pose.
local EXAGGERATION = {
	Critical = 1.43, Uppercut = 1.35,
	Downslam = 1.3, AirPunch = 1.35, AirKick = 1.33,
}

-- The strikes twisted the torso 90-120 degrees in 3-4 frames, which reads as
-- a teleport rather than a swing. Scale the twist (and the head's counter
-- turn, so the eyes stay on the target) back toward the guard.
local TWIST = 0.72

local function tameTwist(clip)
	local keys = {}
	for i, key in ipairs(clip.keys) do
		local p = {}
		for joint, value in pairs(key.pose) do
			local v = channels(value)
			if joint == "Torso" or joint == "Head" then
				local base = GUARD[joint][2]
				v[2] = base + (v[2] - base) * TWIST
			end
			p[joint] = v
		end
		keys[i] = { t = key.t, ease = key.ease, dir = key.dir, pose = p }
	end
	local result = table.clone(clip)
	result.keys = keys
	return result
end

-- Wind-ups were long enough to read as input lag (0.2 s before an M1 could
-- connect). retime() compresses everything before the Hit marker into the
-- new wind-up and keeps the impact and follow-through at their own pace, so
-- the clip gets shorter by the same amount and recovery moves up with it.
local HIT_AT = {
	Critical = 0.42, Uppercut = 0.16,
	AirPunch = 0.1, AirKick = 0.11, Downslam = 0.2,
}

local function retime(clip, newHit)
	local oldHit = clip.markers.Hit
	local scale = newHit / oldHit
	local shift = oldHit - newHit
	local function map(t)
		return t <= oldHit and t * scale or t - shift
	end
	local keys = {}
	for i, key in ipairs(clip.keys) do
		keys[i] = { t = map(key.t), ease = key.ease, dir = key.dir, pose = key.pose }
	end
	local markers = {}
	for name, t in pairs(clip.markers) do
		markers[name] = map(t)
	end
	local result = table.clone(clip)
	result.keys = keys
	result.markers = markers
	result.length = clip.length - shift
	result.recover = clip.recover and clip.recover - shift
	return result
end

for name, hitAt in pairs(HIT_AT) do
	Data[name] = retime(Data[name], hitAt)
end

-- Follow-through springs. Damped enough that the head and off arm ride with
-- the torso and settle in one swing instead of wobbling on their own clock.
-- (loose on purpose: cartoony overshoot and wobble)
local HEAD_SPRING = { 6.2, 0.32 }
local ARM_SPRING = { 6.8, 0.31 }
local KICK_ARM_SPRING = { 5.8, 0.3 }
local LEG_SPRING = { 8.8, 0.42 }

-- Every clip is baked to this many keys per second, so playback is smooth
-- even on high refresh rate screens.
local BAKE_FPS = 120

local detailed = {}

-- The hooks are imported keyframes: played as authored, just baked smooth.
for _, name in ipairs({ "M1_1", "M1_2" }) do
	Data[name] = detail(Data[name], {}, BAKE_FPS)
	detailed[name] = true
end
-- The chain just alternates them: right, left, right, left, and the fifth
-- press (finisher) is a right hook too, with a longer recovery.
Data.M1_3 = table.clone(Data.M1_1)
Data.M1_4 = table.clone(Data.M1_2)
Data.Finisher = table.clone(Data.M1_1)
Data.Finisher.recover = 0.45
for _, name in ipairs({ "M1_3", "M1_4", "Finisher" }) do
	detailed[name] = true
end

for name, amount in pairs(EXAGGERATION) do
	local clip = exaggerate(tameTwist(Data[name]), amount)
	local strikers = {}
	for _, limb in ipairs(clip.trail or {}) do
		strikers[TRAIL_JOINT[limb]] = true
	end
	local springs = { Head = HEAD_SPRING }
	for _, joint in ipairs({ "RightArm", "LeftArm" }) do
		if not strikers[joint] then
			springs[joint] = ARM_SPRING
		end
	end
	for _, joint in ipairs({ "RightLeg", "LeftLeg" }) do
		if not strikers[joint] then
			springs[joint] = LEG_SPRING
		end
	end
	-- a kick's arms fly loose
	if strikers.RightLeg or strikers.LeftLeg then
		springs.RightArm = KICK_ARM_SPRING
		springs.LeftArm = KICK_ARM_SPRING
	end
	Data[name] = detail(clip, springs, BAKE_FPS)
	detailed[name] = true
end

------------------------------------------------------------------------
-- Low Sweep (H): drop to the floor, plant the left hand, wind the right
-- leg behind, then sweep it flat along the ground through their ankles.

-- Karate-style low sweep: the body drops almost flat, leaning right over
-- onto the planted left hand with the head near the floor, the left knee
-- tucked under, and the right leg stretched out straight along the ground.
-- The whole low body then spins so that leg scythes through their ankles.
-- (Shape checked against a reference photo on a posed rig.)
local SWEEP_LOW = {
	Torso = { -22, -30, 78, 0, -1.75, 0 }, -- yaw is the spin; -30 = leg behind
	Head = { -14, 0, -22 },
	RightArm = { 10, 0, 15 }, -- balance arm laid back along the body
	LeftArm = { 20, 0, -82 }, -- planted on the floor under the head
	RightLeg = { 0, 0, 4 }, -- the sweeping leg, flat along the ground
	LeftLeg = { 85, 0, -40 }, -- knee tucked under
}
-- the low pose spun to `yaw`, with the torso nudged (pitch/roll/height) and
-- any limbs overridden
local function sweepAt(yaw, extra, dPitch, dRoll, dY)
	local p = pose(SWEEP_LOW, extra or {})
	local t = SWEEP_LOW.Torso
	p.Torso = { t[1] + (dPitch or 0), yaw, t[3] + (dRoll or 0), 0, t[5] + (dY or 0), 0 }
	return p
end

Data.LowSweep = {
	length = 0.82, priority = "Action", group = "action", recover = 0.6,
	markers = { Swing = 0.19, Hit = 0.27 },
	trail = { "Right Leg" },
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = GUARD },

		-- anticipation: a quick coil up and back before the drop, weight
		-- shifting onto the left foot, gloves lifting
		{ t = 0.04, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { 4, 14, -6, 0, 0.06, 0.1 },
			Head = { 4, -10, 4 },
			RightArm = { 116, 0, -30, 0, 0.05, 0.1 },
			LeftArm = { 122, 0, 18, 0, 0.05, 0 },
			RightLeg = { -6, 0, 12 },
			LeftLeg = { 14, 0, -6 },
		}) },

		-- the drop: hips fall away, chest pitching over, starting to tip left;
		-- the left hand already reaching for the floor, right arm flung up
		{ t = 0.08, ease = "Quad", dir = "In", pose = {
			Torso = { -30, -8, 22, 0, -0.75, 0 },
			Head = { -2, 6, -8 },
			RightArm = { 70, 0, -10 },
			LeftArm = { 50, 0, -40 },
			RightLeg = { 26, 0, 22 },
			LeftLeg = { 60, 0, -20 },
		} },
		{ t = 0.12, ease = "Quad", dir = "Out", pose = {
			Torso = { -28, -18, 52, 0, -1.4, 0 },
			Head = { -10, 12, -16 },
			RightArm = { 40, 0, -30 },
			LeftArm = { 34, 0, -66 },
			RightLeg = { 14, -8, 16 },
			LeftLeg = { 78, 0, -32 },
		} },

		-- hand plants: the body lands on it and compresses, the sweeping leg
		-- dragged out behind, eyes snapping to their feet
		{ t = 0.155, ease = "Sine", dir = "Out", pose = sweepAt(-28, {
			Head = { -16, 24, -24 },
			RightArm = { 30, 0, -8 },
			LeftArm = { 26, 0, -86 },
			RightLeg = { 4, -18, 10 },
			LeftLeg = { 92, 0, -44 },
		}, -4, 4, -0.12) },
		-- the coil: a last twist further back, loading the spin
		{ t = 0.19, ease = "Quad", dir = "In", pose = sweepAt(-40, {
			Head = { -14, 30, -22 },
			RightArm = { 50, 0, 6 },
			LeftArm = { 22, 0, -84 },
			RightLeg = { 2, -22, 8 },
			LeftLeg = { 88, 0, -42 },
		}, -2, 2, -0.05) },

		-- the spin: shoulders lead, the leg lags a beat behind them...
		{ t = 0.215, ease = "Linear", pose = sweepAt(5, {
			Head = { -14, 14, -22 },
			RightArm = { 20, 0, -30 },
			LeftArm = { 18, 0, -80 },
			RightLeg = { 0, -16, 3 },
			LeftLeg = { 80, 0, -36 },
		}) },
		{ t = 0.24, ease = "Linear", pose = sweepAt(45, {
			Head = { -14, 4, -22 },
			RightArm = { 6, 0, -48 },
			LeftArm = { 16, 0, -80 },
			RightLeg = { 0, -8, 1 },
			LeftLeg = { 76, 0, -34 },
		}, 0, 2) },
		-- ...then whips through them flat along the floor (the hit)
		{ t = 0.27, ease = "Quad", dir = "Out", pose = sweepAt(88, {
			Head = { -12, -6, -20 },
			RightArm = { 0, 0, -62 },
			LeftArm = { 18, 0, -82 },
			RightLeg = { 0, 8, 0 },
			LeftLeg = { 82, 0, -38 },
		}, 0, 4, -0.05) },
		-- impact carries the leg on and up a touch, the arm flung wide
		{ t = 0.3, ease = "Sine", dir = "Out", pose = sweepAt(108, {
			Head = { -10, -14, -18 },
			RightArm = { 4, 0, -56 },
			RightLeg = { 0, 16, 7 },
			LeftLeg = { 88, 0, -42 },
		}, 2, 2) },
		{ t = 0.34, ease = "Sine", dir = "Out", pose = sweepAt(126, {
			Head = { -10, -20, -18 },
			RightArm = { 12, 0, -36 },
			RightLeg = { 0, 20, 10 },
			LeftLeg = { 92, 0, -44 },
		}) },
		-- the spin bleeds off: leg drifts back down, body sinks onto the hand
		{ t = 0.39, ease = "Sine", dir = "InOut", pose = sweepAt(138, {
			Head = { -12, -16, -20 },
			RightArm = { 16, 0, -10 },
			LeftArm = { 24, 0, -86 },
			RightLeg = { 0, 12, 6 },
			LeftLeg = { 96, 0, -46 },
		}, -2, -2, -0.1) },

		-- push off the hand: the body rocks up off the floor, unwinding,
		-- the sweeping leg swinging round to step under
		{ t = 0.45, ease = "Quad", dir = "Out", pose = {
			Torso = { -26, 96, 46, 0, -1.3, 0 },
			Head = { -6, -10, -12 },
			RightArm = { 60, 0, 10 },
			LeftArm = { 40, 0, -54 },
			RightLeg = { 30, 0, 24 },
			LeftLeg = { 70, 0, -26 },
		} },
		{ t = 0.52, ease = "Sine", dir = "Out", pose = {
			Torso = { -22, 46, 16, 0, -0.8, 0 },
			Head = { 2, -6, -4 },
			RightArm = { 92, 0, -24, 0, 0, 0.1 },
			LeftArm = { 80, 0, 6 },
			RightLeg = { 36, 0, 16 },
			LeftLeg = { 10, 0, -10 },
		} },

		-- back on the feet, overshooting upright, gloves swinging up into guard
		{ t = 0.6, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -2, -6, -5, 0, -0.1, 0 },
			Head = { 12, 22, 2 },
			RightArm = { 108, 0, -48, 0, 0, 0.1 },
			LeftArm = { 116, 0, 32, 0, 0, -0.05 },
			RightLeg = { 8, 0, 11 },
			LeftLeg = { 20, 0, -6 },
		}) },
		-- settle: a little dip and a bounce into stance
		{ t = 0.7, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -10, -22, 1, 0, -0.27, 0 },
			Head = { 7, 16, 0 },
			RightArm = { 98, 0, -40, 0, 0, 0.1 },
			LeftArm = { 106, 0, 26, 0, 0, -0.05 },
		}) },
		{ t = 0.82, ease = "Sine", dir = "InOut", pose = GUARD },
	},
}
-- Loose follow-through on top of the keys: the off arm, the tucked leg and
-- the head lag and overshoot like a real body (the sweeping leg stays exact).
-- Baked here, skipping the twist-taming pass, which would flatten the spin.
Data.LowSweep = detail(Data.LowSweep, {
	Head = HEAD_SPRING,
	RightArm = KICK_ARM_SPRING,
	LeftArm = { 9, 0.7 }, -- the planted hand: only a little give
	LeftLeg = LEG_SPRING,
}, BAKE_FPS)
detailed.LowSweep = true

-- Overlapping action: each joint runs the clip on its own slight delay
-- (negative = leads), so the body breaks at the joints in sequence instead
-- of every part starting and stopping on the same frame. The clip is
-- lengthened so the last joint still reaches its final pose.
local function stagger(clip, delays)
	local keys = clip.keys
	local length = clip.length
	local function sampleJoint(joint, t)
		t = math.clamp(t, 0, length)
		local lo, hi = 1, #keys
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if keys[mid].t <= t then
				lo = mid
			else
				hi = mid
			end
		end
		local a, b = keys[lo], keys[hi]
		local va, vb = a.pose[joint], b.pose[joint]
		if not va or not vb then
			return va or vb
		end
		local alpha = b.t > a.t and math.clamp((t - a.t) / (b.t - a.t), 0, 1) or 0
		local v = {}
		for i = 1, 6 do
			v[i] = (va[i] or 0) + ((vb[i] or 0) - (va[i] or 0)) * alpha
		end
		return v
	end

	local maxDelay = 0
	for _, d in pairs(delays) do
		maxDelay = math.max(maxDelay, d)
	end
	local joints = {}
	for joint in pairs(keys[1].pose) do
		table.insert(joints, joint)
	end

	local out = {}
	local step = 1 / BAKE_FPS
	local total = length + maxDelay
	local n = math.ceil(total / step)
	for i = 0, n do
		local t = math.min(i * step, total)
		local p = {}
		for _, joint in ipairs(joints) do
			p[joint] = sampleJoint(joint, t - (delays[joint] or 0))
		end
		table.insert(out, { t = t, ease = "Linear", pose = p })
	end
	local result = table.clone(clip)
	result.keys = out
	result.length = total
	return result
end

Data.LowSweep = stagger(Data.LowSweep, {
	Torso = 0, -- the hips/torso lead everything
	RightLeg = 0, -- the sweeping leg stays on the hit frame
	LeftArm = -0.02, -- the planting hand reaches a touch ahead of the fall
	LeftLeg = 0.025, -- the tucked leg gathers a beat after the hips
	RightArm = 0.055, -- the free arm trails the body
	Head = 0.075, -- and the head settles last
})

-- Swept: feet taken out, flat on the back for half a second, then up.
local FLOORED = {
	Torso = { 84, 10, 6, 0, -2.35, 0.9 },
	Head = { -20, -6, 0 },
	RightArm = { 40, 0, 70 },
	LeftArm = { 50, 0, -64 },
	RightLeg = { 24, 0, 10 },
	LeftLeg = { 40, 0, -8 },
}

Data.Swept = {
	length = 0.8, priority = "Action4", group = "react",
	keys = {
		{ t = 0, ease = "Quart", dir = "Out", pose = GUARD },
		-- legs fly up as the feet go, arms flung out
		{ t = 0.07, ease = "Quad", dir = "In", pose = {
			Torso = { 40, 6, 4, 0, -0.6, 0.5 },
			Head = { -10, -4, 0 },
			RightArm = { 150, 0, 60 },
			LeftArm = { 140, 0, -60 },
			RightLeg = { 80, 0, 12 },
			LeftLeg = { 96, 0, -10 },
		} },
		-- slam onto the back
		{ t = 0.17, ease = "Bounce", dir = "Out", pose = FLOORED },
		-- lying there, a little bounce settling
		{ t = 0.5, ease = "Sine", dir = "InOut", pose = pose(FLOORED, {
			Torso = { 82, 8, 4, 0, -2.3, 0.9 },
			Head = { -6, -4, 0 },
			RightLeg = { 50, 0, 10 },
			LeftLeg = { 70, 0, -8 },
		}) },
		-- kip up
		{ t = 0.64, ease = "Quad", dir = "Out", pose = pose(GUARD, {
			Torso = { -20, -10, 0, 0, -0.9, 0.2 },
			RightLeg = { 50, 0, 10 },
			LeftLeg = { -20, 0, -8 },
		}) },
		{ t = 0.8, pose = GUARD },
	},
}

-- the gaits are already dense and exact; only the arms and head get a
-- little loose follow-through on top
Data.Run = detail(Data.Run, {
	Head = { 7, 0.7 },
	RightArm = { 7, 0.6 },
	LeftArm = { 7, 0.6 },
}, BAKE_FPS)
Data.Stance = detail(Data.Stance, {
	Head = { 4, 0.65 },
	RightArm = { 4.5, 0.6 },
	LeftArm = { 4.5, 0.6 },
}, 60)
detailed.Run, detailed.Stance = true, true

-- Katana moveset: its clips (and the katana-held versions of the movement
-- clips) are added and baked here; see KatanaAnimations.
require(script.Parent.KatanaAnimations)(Data, {
	detail = detail,
	detailed = detailed,
	fps = BAKE_FPS,
	headSpring = HEAD_SPRING,
	legSpring = LEG_SPRING,
})

-- Walking/running: Roblox's default R6 walk (animation 180426354), baked 1:1.
-- The client plays it at speed / speedRef like the default Animate script
-- does (14.5 is the speed it was authored for). It is swapped in here, after
-- the katana set is built, so the katana-drawn run (Katana_Run, which is
-- built from the custom run cycle defined above) is left exactly as it was.
Data.Run = {
	length = 0.666667, looped = true, priority = "Movement", group = "base",
	speedRef = 14.5,
	sourceAssetId = "rbxassetid://180426354",
	keys = {
		{ t = 0.000000, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.000360, 0.000000 },
			Head = { -1.728778, 1.994411, 0.053662, 0.000000, 0.000000, 0.000000 },
			RightArm = { -44.900752, -3.900731, -0.410790, 0.005044, 0.073209, 0.199004 },
			LeftArm = { 55.722678, 0.323781, -3.965115, -0.020773, -0.043183, -0.289511 },
			RightLeg = { 45.273755, 1.709329, -1.493907, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { -59.431942, -0.059071, -0.020743, 0.014998, -0.129369, -0.032098 },
		} },
		{ t = 0.031746, pose = {
			Torso = { 0.000000, -0.060103, 0.000000, 0.000000, -0.000360, 0.000000 },
			Head = { -1.728809, 1.969988, 0.053661, 0.000000, 0.000000, 0.000000 },
			RightArm = { -40.314976, -3.969533, 0.145194, 0.005912, 0.068061, 0.190430 },
			LeftArm = { 53.456284, 0.352601, -3.841133, -0.020104, -0.048401, -0.274348 },
			RightLeg = { 42.851459, 1.770950, -1.420329, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { -65.708933, -0.056492, -0.027046, 0.014998, -0.140642, -0.032098 },
		} },
		{ t = 0.063492, pose = {
			Torso = { 0.000000, -0.224084, 0.000000, 0.000000, -0.000146, 0.000000 },
			Head = { -1.728742, 1.903372, 0.053659, 0.000000, 0.000000, 0.000000 },
			RightArm = { -28.716957, -3.837331, 1.540600, 0.008109, 0.054780, 0.167661 },
			LeftArm = { 47.525607, 0.403080, -3.544773, -0.018379, -0.061020, -0.235524 },
			RightLeg = { 36.163277, 1.924296, -1.204439, -0.011197, -0.201478, -0.005458 },
			LeftLeg = { -65.744273, -0.056435, -0.027103, 0.014998, -0.165271, -0.032098 },
		} },
		{ t = 0.095238, pose = {
			Torso = { 0.000000, -0.467539, 0.000000, 0.000000, 0.000684, 0.000000 },
			Head = { -1.728645, 1.804370, 0.053656, 0.000000, 0.000000, 0.000000 },
			RightArm = { -13.371336, -3.029494, 3.195833, 0.011018, 0.036613, 0.135130 },
			LeftArm = { 39.233775, 0.422847, -3.198164, -0.016022, -0.076484, -0.183036 },
			RightLeg = { 26.076872, 2.105406, -0.848927, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { -60.673383, -0.058612, -0.022004, 0.014998, -0.189470, -0.032098 },
		} },
		{ t = 0.126984, pose = {
			Torso = { 0.000000, -0.765953, 0.000000, 0.000000, 0.001660, 0.000000 },
			Head = { -1.728532, 1.683076, 0.053652, 0.000000, 0.000000, 0.000000 },
			RightArm = { 2.451752, -1.571305, 4.393953, 0.014027, 0.016804, 0.097269 },
			LeftArm = { 29.885206, 0.414367, -2.903177, -0.013457, -0.090241, -0.126881 },
			RightLeg = { 13.460614, 2.239918, -0.368697, -0.011197, -0.201478, -0.005458 },
			LeftLeg = { -51.631623, -0.061363, -0.012492, 0.014998, -0.199327, -0.032098 },
		} },
		{ t = 0.158730, pose = {
			Torso = { 0.000000, -1.094989, 0.000000, 0.000000, 0.002262, 0.000000 },
			Head = { -1.728361, 1.549352, 0.053649, 0.000000, 0.000000, 0.000000 },
			RightArm = { 15.545722, -0.087548, 4.729753, 0.016521, -0.001399, 0.058511 },
			LeftArm = { 20.784546, 0.443589, -2.698621, -0.011108, -0.097737, -0.077055 },
			RightLeg = { -0.815179, 2.261650, 0.194901, -0.011197, -0.201478, -0.005458 },
			LeftLeg = { -39.754221, -0.062624, 0.000399, 0.014998, -0.156995, -0.032098 },
		} },
		{ t = 0.190476, pose = {
			Torso = { 0.000000, -1.430079, 0.000000, 0.000000, 0.002166, 0.000000 },
			Head = { -1.728256, 1.413172, 0.053645, 0.000000, 0.000000, 0.000000 },
			RightArm = { 25.000386, 0.934363, 4.382883, 0.018317, -0.017720, 0.022641 },
			LeftArm = { 11.998614, 0.617661, -2.495765, -0.009102, -0.086909, -0.036236 },
			RightLeg = { -15.878286, 2.133385, 0.775832, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { -26.176647, -0.060791, 0.015068, 0.014998, -0.072392, -0.032098 },
		} },
		{ t = 0.222222, pose = {
			Torso = { 0.000000, -1.746818, 0.000000, 0.000000, 0.001698, 0.000000 },
			Head = { -1.728164, 1.284450, 0.053643, 0.000000, 0.000000, 0.000000 },
			RightArm = { 34.465596, 1.787402, 3.689263, 0.020108, -0.036755, -0.009389 },
			LeftArm = { 1.848288, 0.917746, -2.155851, -0.007025, -0.046420, 0.005178 },
			RightLeg = { -30.855943, 1.860549, 1.300726, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { -12.034119, -0.055233, 0.029450, 0.014998, 0.007837, -0.032098 },
		} },
		{ t = 0.253968, pose = {
			Torso = { 0.000000, -2.020840, 0.000000, 0.000000, 0.001065, 0.000000 },
			Head = { -1.728034, 1.173098, 0.053640, 0.000000, 0.000000, 0.000000 },
			RightArm = { 43.533368, 2.351677, 2.781360, 0.021819, -0.056720, -0.036907 },
			LeftArm = { -8.417955, 1.197798, -1.755972, -0.005040, 0.006689, 0.041317 },
			RightLeg = { -44.877365, 1.490087, 1.712720, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { 1.580877, -0.046753, 0.041654, 0.014998, 0.036762, -0.032098 },
		} },
		{ t = 0.285714, pose = {
			Torso = { 0.000000, -2.227591, 0.000000, 0.000000, 0.000454, 0.000000 },
			Head = { -1.727984, 1.089086, 0.053639, 0.000000, 0.000000, 0.000000 },
			RightArm = { 51.559694, 2.569487, 1.828908, 0.023329, -0.075515, -0.059206 },
			LeftArm = { -17.408370, 1.407441, -1.433780, -0.003342, 0.054304, 0.065536 },
			RightLeg = { -57.074550, 1.094529, 1.988814, -0.011197, -0.201478, -0.005458 },
			LeftLeg = { 16.333996, -0.034607, 0.052197, 0.014998, -0.017967, -0.032098 },
		} },
		{ t = 0.317460, pose = {
			Torso = { 0.000000, -2.342732, 0.000000, 0.000000, 0.000058, 0.000000 },
			Head = { -1.727901, 1.042382, 0.053638, 0.000000, 0.000000, 0.000000 },
			RightArm = { 57.896153, 2.476750, 0.994945, 0.024519, -0.091038, -0.075581 },
			LeftArm = { -24.150331, 2.075019, -1.202714, -0.002157, 0.089059, 0.075515 },
			RightLeg = { -66.580950, 0.750938, 2.142288, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { 30.917691, -0.020340, 0.059188, 0.014998, -0.103581, -0.032098 },
		} },
		{ t = 0.349206, pose = {
			Torso = { 0.000000, -2.342732, 0.000000, 0.000000, 0.000059, 0.000000 },
			Head = { -1.727901, 1.042497, 0.053638, 0.000000, 0.000000, 0.000000 },
			RightArm = { 61.898740, 2.171054, 0.394651, 0.025271, -0.101190, -0.085326 },
			LeftArm = { -28.451722, 3.435795, -0.960905, -0.001566, 0.116826, 0.078777 },
			RightLeg = { -72.530113, 0.524778, 2.208593, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { 41.585791, -0.009052, 0.061938, 0.014998, -0.198133, -0.032098 },
		} },
		{ t = 0.380952, pose = {
			Torso = { 0.000000, -2.227591, 0.000000, 0.000000, 0.000474, 0.000000 },
			Head = { -1.727984, 1.089316, 0.053639, 0.000000, 0.000000, 0.000000 },
			RightArm = { 62.860014, 1.759714, 0.086154, 0.025452, -0.103813, -0.087520 },
			LeftArm = { -29.523762, 4.237792, -1.295559, -0.001450, 0.125229, 0.078655 },
			RightLeg = { -73.896083, 0.471949, 2.220444, -0.011197, -0.201478, -0.005458 },
			LeftLeg = { 44.680140, -0.005672, 0.062340, 0.014998, -0.231082, -0.032098 },
		} },
		{ t = 0.412698, pose = {
			Torso = { 0.000000, -2.020840, 0.000000, 0.000000, 0.001159, 0.000000 },
			Head = { -1.728034, 1.173385, 0.053640, 0.000000, 0.000000, 0.000000 },
			RightArm = { 58.050611, 1.289893, 0.147458, 0.024541, -0.095914, -0.074735 },
			LeftArm = { -25.455410, 4.541721, -2.502394, -0.001956, 0.112005, 0.062873 },
			RightLeg = { -65.141509, 0.804515, 2.122762, -0.011197, -0.201478, -0.005458 },
			LeftLeg = { 40.877647, -0.009797, 0.061824, 0.014998, -0.199050, -0.032098 },
		} },
		{ t = 0.444444, pose = {
			Torso = { 0.000000, -1.746818, 0.000000, 0.000000, 0.001963, 0.000000 },
			Head = { -1.728164, 1.284736, 0.053643, 0.000000, 0.000000, 0.000000 },
			RightArm = { 47.558607, 0.744751, 0.424600, 0.022553, -0.078673, -0.046829 },
			LeftArm = { -16.944830, 4.420054, -4.281057, -0.003081, 0.085094, 0.029535 },
			RightLeg = { -47.019545, 1.424978, 1.767200, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { 32.479452, -0.018735, 0.059761, 0.014998, -0.138536, -0.032098 },
		} },
		{ t = 0.476190, pose = {
			Torso = { 0.000000, -1.430079, 0.000000, 0.000000, 0.002734, 0.000000 },
			Head = { -1.728256, 1.413401, 0.053645, 0.000000, 0.000000, 0.000000 },
			RightArm = { 33.057245, 0.075000, 0.701833, 0.019805, -0.054833, -0.008242 },
			LeftArm = { -5.890193, 3.580394, -6.173523, -0.004673, 0.051583, -0.014462 },
			RightLeg = { -23.826130, 2.005704, 1.063264, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { 19.655143, -0.031513, 0.054088, 0.014998, -0.058572, -0.032098 },
		} },
		{ t = 0.507937, pose = {
			Torso = { 0.000000, -1.094989, 0.000000, 0.000000, 0.003320, 0.000000 },
			Head = { -1.728363, 1.549581, 0.053649, 0.000000, 0.000000, 0.000000 },
			RightArm = { 16.213506, -0.710314, 0.822171, 0.016612, -0.027136, 0.036587 },
			LeftArm = { 5.820381, 2.116185, -7.618612, -0.006581, 0.018559, -0.062222 },
			RightLeg = { 0.132686, 2.264575, 0.157457, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { 1.363081, -0.046925, 0.041482, 0.014998, 0.055414, -0.032098 },
		} },
		{ t = 0.539683, pose = {
			Torso = { 0.000000, -0.765953, 0.000000, 0.000000, 0.003569, 0.000000 },
			Head = { -1.728532, 1.683248, 0.053652, 0.000000, 0.000000, 0.000000 },
			RightArm = { -1.311176, -1.546028, 0.812892, 0.013291, 0.001675, 0.083220 },
			LeftArm = { 16.370961, 0.552913, -8.220768, -0.008653, -0.006892, -0.106849 },
			RightLeg = { 20.536893, 2.177477, -0.641732, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { -15.644753, -0.057009, 0.025954, 0.014998, 0.120344, -0.032098 },
		} },
		{ t = 0.571429, pose = {
			Torso = { 0.000000, -0.467539, 0.000000, 0.000000, 0.003008, 0.000000 },
			Head = { -1.728645, 1.804485, 0.053656, 0.000000, 0.000000, 0.000000 },
			RightArm = { -17.855848, -2.410572, 0.609950, 0.010157, 0.028857, 0.127217 },
			LeftArm = { 27.482946, -0.590099, -7.482587, -0.011645, -0.023091, -0.156983 },
			RightLeg = { 32.724949, 1.993034, -1.086938, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { -28.244963, -0.061249, 0.012890, 0.014998, 0.084862, -0.032098 },
		} },
		{ t = 0.603175, pose = {
			Torso = { 0.000000, -0.224084, 0.000000, 0.000000, 0.001652, 0.000000 },
			Head = { -1.728742, 1.903429, 0.053659, 0.000000, 0.000000, 0.000000 },
			RightArm = { -31.755523, -3.179542, 0.207962, 0.007527, 0.051669, 0.164140 },
			LeftArm = { 40.449931, -0.800333, -5.783961, -0.015688, -0.034392, -0.217355 },
			RightLeg = { 38.925135, 1.864045, -1.295740, -0.011197, -0.201478, -0.005458 },
			LeftLeg = { -39.490651, -0.062624, 0.000686, 0.014998, -0.001394, -0.032098 },
		} },
		{ t = 0.634921, pose = {
			Torso = { 0.000000, -0.060103, 0.000000, 0.000000, 0.000272, 0.000000 },
			Head = { -1.728809, 1.970045, 0.053661, 0.000000, 0.000000, 0.000000 },
			RightArm = { -41.333180, -3.707045, -0.219672, 0.005717, 0.067366, 0.189548 },
			LeftArm = { 51.226586, -0.151375, -4.432136, -0.019245, -0.041020, -0.268158 },
			RightLeg = { 43.458619, 1.755817, -1.439010, -0.011197, -0.201478, -0.005458 },
			LeftLeg = { -49.763884, -0.061707, -0.010487, 0.014998, -0.089185, -0.032098 },
		} },
		{ t = 0.666667, pose = {
			Torso = { 0.000000, 0.000000, 0.000000, 0.000000, -0.000360, 0.000000 },
			Head = { -1.728778, 1.994411, 0.053662, 0.000000, 0.000000, 0.000000 },
			RightArm = { -44.900752, -3.900731, -0.410790, 0.005044, 0.073209, 0.199004 },
			LeftArm = { 55.722678, 0.323781, -3.965115, -0.020773, -0.043183, -0.289511 },
			RightLeg = { 45.273755, 1.709329, -1.493907, -0.011197, -0.201477, -0.005458 },
			LeftLeg = { -59.431942, -0.059071, -0.020743, 0.014998, -0.129369, -0.032098 },
		} },
	},
}
-- the defaults are already exact: skip the smoothing pass for both
detailed.Run, detailed.Idle = true, true

-- Sprint (hold Shift): the sprint animation 123493387641662, baked 1:1.
-- CombatClient plays this instead of Run while sprinting, at speed /
-- speedRef, so it runs exactly as authored at full sprint speed. Walking
-- (Run) and Idle are separate clips and are not affected.
Data.Sprint = {
	length = 0.666667, looped = true, priority = "Movement", group = "base",
	speedRef = Config.SprintSpeed,
	sourceAssetId = "rbxassetid://123493387641662",
	keys = {
		{ t = 0.000000, pose = {
			Torso = { -37.139488, 1.423952, 2.506670, 0.000000, 0.000000, 0.000000 },
			Head = { 30.377881, -0.102677, -1.697957, 0.000000, 0.000000, 0.000000 },
			RightArm = { -46.406310, -9.945841, 0.000000, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 113.483409, 18.113812, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 70.942436, 0.000000, 0.000000, 0.000000, 0.125022, -0.165357 },
			LeftLeg = { -70.144608, 0.000000, 0.000000, 0.000000, 0.127607, -0.353370 },
		} },
		{ t = 0.016667, pose = {
			Torso = { -37.137671, 1.333476, 2.306114, 0.000000, -0.005299, 0.004013 },
			Head = { 30.338345, -0.099720, -1.681588, 0.000000, 0.000000, 0.000000 },
			RightArm = { -45.618683, -9.956331, -0.057747, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 112.667174, 18.103305, 0.059841, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 70.639606, 0.000000, 0.000000, 0.000000, 0.129968, -0.213215 },
			LeftLeg = { -70.537529, 0.000000, 0.000000, 0.000000, 0.067770, -0.386011 },
		} },
		{ t = 0.033333, pose = {
			Torso = { -37.134106, 1.061996, 1.704462, 0.000000, -0.021195, 0.016052 },
			Head = { 30.219718, -0.090920, -1.632465, 0.000000, 0.000000, 0.000000 },
			RightArm = { -43.255694, -9.992479, -0.230046, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 110.218933, 18.066948, 0.238307, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 69.731000, 0.000000, 0.000000, 0.000000, 0.144804, -0.356788 },
			LeftLeg = { -71.716508, 0.000000, 0.000000, 0.000000, -0.111740, -0.483936 },
		} },
		{ t = 0.050000, pose = {
			Torso = { -37.134110, 0.654725, 0.802050, 0.000000, -0.045038, 0.034111 },
			Head = { 30.021977, -0.076478, -1.550554, 0.000000, 0.000000, 0.000000 },
			RightArm = { -39.316977, -10.068163, -0.513426, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 106.140115, 17.990367, 0.531507, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 68.367960, 0.000000, 0.000000, 0.000000, 0.167059, -0.572147 },
			LeftLeg = { -73.485261, 0.000000, 0.000000, 0.000000, -0.381005, -0.630824 },
		} },
		{ t = 0.066667, pose = {
			Torso = { -37.137682, 0.383246, 0.200504, 0.000000, -0.060934, 0.046150 },
			Head = { 29.745112, -0.056735, -1.435796, 0.000000, 0.000000, 0.000000 },
			RightArm = { -33.801698, -10.205929, -0.899994, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 100.434025, 17.850281, 0.930553, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 67.459354, 0.000000, 0.000000, 0.000000, 0.181896, -0.715719 },
			LeftLeg = { -74.664254, 0.000000, 0.000000, 0.000000, -0.560516, -0.728749 },
		} },
		{ t = 0.083333, pose = {
			Torso = { -37.139495, 0.292769, 0.000003, 0.000000, -0.066233, 0.050163 },
			Head = { 29.389078, -0.032166, -1.288112, 0.000000, 0.000000, 0.000000 },
			RightArm = { -26.708140, -10.435656, -1.374397, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 93.106946, 17.615992, 1.418176, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 67.156530, 0.000000, 0.000000, 0.000000, 0.186841, -0.763577 },
			LeftLeg = { -75.057174, 0.000000, 0.000000, 0.000000, -0.620352, -0.761391 },
		} },
		{ t = 0.100000, pose = {
			Torso = { -37.139495, 0.269879, 0.000003, 0.000000, -0.062727, 0.047508 },
			Head = { 28.953855, -0.003384, -1.107407, 0.000000, 0.000000, 0.000000 },
			RightArm = { -18.032946, -10.791914, -1.909925, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 84.169425, 17.252337, 1.964557, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 62.403634, 0.000000, 0.000000, 0.000000, 0.202492, -0.786021 },
			LeftLeg = { -71.932690, 0.000000, 0.000000, 0.000000, -0.519798, -0.787136 },
		} },
		{ t = 0.116667, pose = {
			Torso = { -37.139499, 0.201211, 0.000003, 0.000000, -0.052209, 0.039542 },
			Head = { 28.439379, 0.028860, -0.893572, 0.000000, 0.000000, 0.000000 },
			RightArm = { -7.770112, -11.309352, -2.464322, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 73.637062, 16.724779, 2.523246, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 48.144938, 0.000000, 0.000000, 0.000000, 0.249445, -0.853354 },
			LeftLeg = { -62.559246, 0.000000, 0.000000, 0.000000, -0.218133, -0.864374 },
		} },
		{ t = 0.133333, pose = {
			Torso = { -37.139495, 0.086763, 0.000003, 0.000000, -0.034680, 0.026266 },
			Head = { 27.845614, 0.063676, -0.646492, 0.000000, 0.000000, 0.000000 },
			RightArm = { 4.090806, -12.015440, -2.976271, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 61.530285, 16.007214, 3.028539, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 26.756890, 0.000000, 0.000000, 0.000000, 0.319875, -0.954352 },
			LeftLeg = { -48.499070, 0.000000, 0.000000, 0.000000, 0.234363, -0.980230 },
		} },
		{ t = 0.150000, pose = {
			Torso = { -37.139495, -0.073465, 0.000003, 0.000000, -0.010139, 0.007679 },
			Head = { 27.172502, 0.100036, -0.366048, 0.000000, 0.000000, 0.000000 },
			RightArm = { 17.566811, -12.920344, -3.364123, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 47.872000, 15.092418, 3.396127, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 12.498184, 0.000000, 0.000000, 0.000000, 0.366828, -1.021684 },
			LeftLeg = { -39.125632, 0.000000, 0.000000, 0.000000, 0.536027, -1.057468 },
		} },
		{ t = 0.166667, pose = {
			Torso = { -37.139495, -0.279475, 0.000003, 0.000000, 0.021414, -0.016219 },
			Head = { 26.420002, 0.136772, -0.052129, 0.000000, 0.000000, 0.000000 },
			RightArm = { 32.683534, -14.004272, -3.528968, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 32.683534, 14.004272, 3.528968, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 7.745278, 0.000000, 0.000000, 0.000000, 0.382479, -1.044129 },
			LeftLeg = { -36.001148, 0.000000, 0.000000, 0.000000, 0.636582, -1.083214 },
		} },
		{ t = 0.183333, pose = {
			Torso = { -37.139499, -0.485484, 0.000003, 0.000000, 0.052967, -0.040116 },
			Head = { 25.667304, 0.169381, 0.262245, 0.000000, 0.000000, 0.000000 },
			RightArm = { 47.872000, -15.092418, -3.396127, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 17.566811, 12.920344, 3.364123, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 2.418334, 0.000000, 0.000000, 0.000000, 0.331140, -0.959928 },
			LeftLeg = { -29.854047, 0.000000, 0.000000, 0.000000, 0.669785, -0.997668 },
		} },
		{ t = 0.200000, pose = {
			Torso = { -37.139502, -0.645712, 0.000003, 0.000000, 0.077509, -0.058703 },
			Head = { 24.993691, 0.195054, 0.543869, 0.000000, 0.000000, 0.000000 },
			RightArm = { 61.530285, -16.007214, -3.028539, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 4.090806, 12.015440, 2.976271, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -13.562521, 0.000000, 0.000000, 0.000000, 0.177123, -0.707326 },
			LeftLeg = { -11.412744, 0.000000, 0.000000, 0.000000, 0.769395, -0.741030 },
		} },
		{ t = 0.216667, pose = {
			Torso = { -37.139499, -0.760160, 0.000003, 0.000000, 0.095038, -0.071980 },
			Head = { 24.399239, 0.214955, 0.792598, 0.000000, 0.000000, 0.000000 },
			RightArm = { 73.637062, -16.724779, -2.523246, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -7.770112, 11.309352, 2.464322, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -37.533805, 0.000000, 0.000000, 0.000000, -0.053901, -0.328423 },
			LeftLeg = { 16.249213, 0.000000, 0.000000, 0.000000, 0.918809, -0.356075 },
		} },
		{ t = 0.233333, pose = {
			Torso = { -37.139499, -0.828829, 0.000003, 0.000000, 0.105556, -0.079946 },
			Head = { 23.883971, 0.230115, 1.008320, 0.000000, 0.000000, 0.000000 },
			RightArm = { 84.169425, -17.252337, -1.964557, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -18.032946, 10.791914, 1.909925, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -53.514669, 0.000000, 0.000000, 0.000000, -0.207918, -0.075821 },
			LeftLeg = { 34.690524, 0.000000, 0.000000, 0.000000, 1.018419, -0.099437 },
		} },
		{ t = 0.250000, pose = {
			Torso = { -37.139495, -0.851718, 0.000003, 0.000000, 0.109062, -0.082601 },
			Head = { 23.447937, 0.241427, 1.190954, 0.000000, 0.000000, 0.000000 },
			RightArm = { 93.106946, -17.615992, -1.418176, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -26.708140, 10.435656, 1.374397, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -58.841622, 0.000000, 0.000000, 0.000000, -0.259257, 0.008380 },
			LeftLeg = { 40.837619, 0.000000, 0.000000, 0.000000, 1.051622, -0.013891 },
		} },
		{ t = 0.266667, pose = {
			Torso = { -37.138628, -0.897489, -0.189420, 0.000000, 0.100337, -0.075993 },
			Head = { 23.091150, 0.249648, 1.340443, 0.000000, 0.000000, 0.000000 },
			RightArm = { 100.434045, -17.850284, -0.930552, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -33.801701, 10.205930, 0.899994, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -60.585731, -0.038968, -0.220317, 0.000000, -0.285390, 0.021766 },
			LeftLeg = { 43.245657, -0.051927, 0.210640, 0.000000, 0.977494, -0.026009 },
		} },
		{ t = 0.283333, pose = {
			Torso = { -37.136920, -1.034824, -0.757729, 0.000000, 0.074162, -0.056169 },
			Head = { 22.813639, 0.255399, 1.456745, 0.000000, 0.000000, 0.000000 },
			RightArm = { 106.140115, -17.990367, -0.531507, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -39.316963, 10.068161, 0.513425, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -65.818797, -0.115414, -0.886952, 0.000000, -0.363788, 0.061922 },
			LeftLeg = { 50.470727, -0.154039, 0.853033, 0.000000, 0.755110, -0.062360 },
		} },
		{ t = 0.300000, pose = {
			Torso = { -37.136924, -1.240848, -1.610269, 0.000000, 0.034900, -0.026432 },
			Head = { 22.615417, 0.259161, 1.539836, 0.000000, 0.000000, 0.000000 },
			RightArm = { 110.218947, -18.066950, -0.238306, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -43.255687, 9.992475, 0.230045, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -73.669191, -0.115414, -1.893020, 0.000000, -0.481386, 0.122158 },
			LeftLeg = { 61.309335, -0.154039, 1.827912, 0.000000, 0.421534, -0.116888 },
		} },
		{ t = 0.316667, pose = {
			Torso = { -37.138624, -1.378183, -2.178646, 0.000000, 0.008725, -0.006608 },
			Head = { 22.496475, 0.261281, 1.589696, 0.000000, 0.000000, 0.000000 },
			RightArm = { 112.667174, -18.103305, -0.059841, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -45.618683, 9.956331, 0.057747, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -78.902263, -0.038968, -2.559655, 0.000000, -0.559785, 0.162315 },
			LeftLeg = { 68.534405, -0.051927, 2.470305, 0.000000, 0.199151, -0.153239 },
		} },
		{ t = 0.333333, pose = {
			Torso = { -37.139488, -1.423954, -2.368103, 0.000000, 0.000000, 0.000000 },
			Head = { 22.456825, 0.261964, 1.606317, 0.000000, 0.000000, 0.000000 },
			RightArm = { 113.483409, -18.113812, 0.000000, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -46.406310, 9.945841, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -80.646393, 0.000000, -2.779972, 0.000000, -0.585918, 0.175700 },
			LeftLeg = { 70.942436, 0.000000, 2.680945, 0.000000, 0.125023, -0.165357 },
		} },
		{ t = 0.350000, pose = {
			Torso = { -37.137767, -1.333475, -2.178632, 0.000000, -0.005299, 0.004013 },
			Head = { 22.496475, 0.261281, 1.589696, 0.000000, 0.000000, 0.000000 },
			RightArm = { 112.667174, -18.103305, -0.059841, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -45.618683, 9.956331, 0.057747, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -82.197987, 0.034661, -2.559220, 0.000000, -0.595755, 0.131831 },
			LeftLeg = { 69.308716, -0.037593, 2.636196, 0.000000, 0.135943, -0.180532 },
		} },
		{ t = 0.366667, pose = {
			Torso = { -37.134403, -1.061996, -1.610237, 0.000000, -0.021195, 0.016052 },
			Head = { 22.615414, 0.259161, 1.539836, 0.000000, 0.000000, 0.000000 },
			RightArm = { 110.218933, -18.066948, -0.238307, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -43.255694, 9.992479, 0.230046, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -86.853450, 0.102619, -1.892468, 0.000000, -0.625267, 0.000226 },
			LeftLeg = { 64.407407, -0.142509, 2.495780, 0.000000, 0.168703, -0.226058 },
		} },
		{ t = 0.383333, pose = {
			Torso = { -37.134410, -0.654729, -0.757711, 0.000000, -0.045038, 0.034111 },
			Head = { 22.813638, 0.255398, 1.456746, 0.000000, 0.000000, 0.000000 },
			RightArm = { 106.140115, -17.990367, -0.531507, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -39.316977, 10.068163, 0.513426, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -93.837346, 0.102619, -0.887504, 0.000000, -0.669535, -0.197183 },
			LeftLeg = { 56.237947, -0.289516, 2.243506, 0.000000, 0.223303, -0.301934 },
		} },
		{ t = 0.400000, pose = {
			Torso = { -37.137774, -0.383249, -0.189416, 0.000000, -0.060934, 0.046150 },
			Head = { 23.091152, 0.249648, 1.340443, 0.000000, 0.000000, 0.000000 },
			RightArm = { 100.434025, -17.850281, -0.930553, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -33.801698, 10.205929, 0.899994, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -98.492830, 0.034661, -0.220752, 0.000000, -0.699048, -0.328788 },
			LeftLeg = { 44.799583, -0.432066, 1.860742, 0.000000, 0.299743, -0.408160 },
		} },
		{ t = 0.416667, pose = {
			Torso = { -37.139495, -0.292771, 0.000003, 0.000000, -0.066233, 0.050163 },
			Head = { 23.447937, 0.241427, 1.190954, 0.000000, 0.000000, 0.000000 },
			RightArm = { 93.106946, -17.615992, -1.418176, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -26.708140, 10.435656, 1.374397, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -100.044527, 0.000000, 0.000000, 0.000000, -0.708885, -0.372657 },
			LeftLeg = { 30.091963, -0.499209, 1.340472, 0.000000, 0.398023, -0.544737 },
		} },
		{ t = 0.433333, pose = {
			Torso = { -37.139492, -0.247520, 0.000003, 0.000000, -0.063955, 0.048438 },
			Head = { 23.883971, 0.230115, 1.008320, 0.000000, 0.000000, 0.000000 },
			RightArm = { 84.169425, -17.252337, -1.964557, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -18.032946, 10.791914, 1.909925, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -93.784631, 0.000000, 0.000000, 0.000000, -0.575056, -0.449371 },
			LeftLeg = { 15.384339, -0.432066, 0.820203, 0.000000, 0.496303, -0.681315 },
		} },
		{ t = 0.450000, pose = {
			Torso = { -37.139499, -0.111764, 0.000003, 0.000000, -0.057120, 0.043262 },
			Head = { 24.399239, 0.214955, 0.792598, 0.000000, 0.000000, 0.000000 },
			RightArm = { 73.637062, -16.724779, -2.523246, 0.000000, 0.000000, 0.000000 },
			LeftArm = { -7.770112, 11.309352, 2.464322, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -75.005251, 0.000000, 0.000000, 0.000000, -0.173569, -0.679515 },
			LeftLeg = { 3.945985, -0.289516, 0.437439, 0.000000, 0.572743, -0.787541 },
		} },
		{ t = 0.466667, pose = {
			Torso = { -37.139499, 0.114501, 0.000003, 0.000000, -0.045729, 0.034635 },
			Head = { 24.993691, 0.195054, 0.543869, 0.000000, 0.000000, 0.000000 },
			RightArm = { 61.530285, -16.007214, -3.028539, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 4.090806, 12.015440, 2.976271, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -46.836178, 0.000000, 0.000000, 0.000000, 0.428661, -1.024730 },
			LeftLeg = { -4.223481, -0.142509, 0.185165, 0.000000, 0.627343, -0.863417 },
		} },
		{ t = 0.483333, pose = {
			Torso = { -37.139495, 0.431281, 0.000003, 0.000000, -0.029782, 0.022557 },
			Head = { 25.667299, 0.169381, 0.262245, 0.000000, 0.000000, 0.000000 },
			RightArm = { 47.872000, -15.092418, -3.396127, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 17.566811, 12.920344, 3.364123, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -28.056817, 0.000000, 0.000000, 0.000000, 0.830148, -1.254874 },
			LeftLeg = { -9.124804, -0.037593, 0.044748, 0.000000, 0.660103, -0.908943 },
		} },
		{ t = 0.500000, pose = {
			Torso = { -37.139502, 0.838578, 0.000003, 0.000000, -0.009279, 0.007028 },
			Head = { 26.420002, 0.136772, -0.052129, 0.000000, 0.000000, 0.000000 },
			RightArm = { 32.683534, -14.004272, -3.528968, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 32.683534, 14.004272, 3.528968, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -21.797034, 0.000000, 0.000000, 0.000000, 0.963977, -1.331588 },
			LeftLeg = { -10.758517, 0.000000, 0.000000, 0.000000, 0.671023, -0.924118 },
		} },
		{ t = 0.516667, pose = {
			Torso = { -37.139495, 1.245875, 0.000003, 0.000000, 0.011224, -0.008501 },
			Head = { 27.172502, 0.100036, -0.366048, 0.000000, 0.000000, 0.000000 },
			RightArm = { 17.566811, -12.920344, -3.364123, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 47.872000, 15.092418, 3.396127, 0.000000, 0.000000, 0.000000 },
			RightLeg = { -16.202232, 0.000000, 0.000000, 0.000000, 0.970493, -1.232029 },
			LeftLeg = { -16.909718, 0.000000, 0.000000, 0.000000, 0.572580, -0.931614 },
		} },
		{ t = 0.533333, pose = {
			Torso = { -37.139505, 1.562655, 0.000003, 0.000000, 0.027171, -0.020579 },
			Head = { 27.845614, 0.063676, -0.646492, 0.000000, 0.000000, 0.000000 },
			RightArm = { 4.090806, -12.015440, -2.976271, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 61.530285, 16.007214, 3.028539, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 0.582148, 0.000000, 0.000000, 0.000000, 0.990044, -0.933351 },
			LeftLeg = { -35.363325, 0.000000, 0.000000, 0.000000, 0.277250, -0.954100 },
		} },
		{ t = 0.550000, pose = {
			Torso = { -37.139505, 1.788920, 0.000003, 0.000000, 0.038562, -0.029206 },
			Head = { 28.439379, 0.028860, -0.893572, 0.000000, 0.000000, 0.000000 },
			RightArm = { -7.770112, -11.309352, -2.464322, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 73.637062, 16.724779, 2.523246, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 25.758716, 0.000000, 0.000000, 0.000000, 1.019369, -0.485333 },
			LeftLeg = { -63.043746, 0.000000, 0.000000, 0.000000, -0.165745, -0.987829 },
		} },
		{ t = 0.566667, pose = {
			Torso = { -37.139499, 1.924676, 0.000003, 0.000000, 0.045397, -0.034382 },
			Head = { 28.953855, -0.003384, -1.107407, 0.000000, 0.000000, 0.000000 },
			RightArm = { -18.032946, -10.791914, -1.909925, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 84.169425, 17.252337, 1.964557, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 42.543093, 0.000000, 0.000000, 0.000000, 1.038920, -0.186655 },
			LeftLeg = { -81.497366, 0.000000, 0.000000, 0.000000, -0.461075, -1.010315 },
		} },
		{ t = 0.583333, pose = {
			Torso = { -37.139499, 1.969927, 0.000003, 0.000000, 0.047675, -0.036108 },
			Head = { 29.389078, -0.032166, -1.288112, 0.000000, 0.000000, 0.000000 },
			RightArm = { -26.708140, -10.435656, -1.374397, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 93.106946, 17.615992, 1.418176, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 48.137893, 0.000000, 0.000000, 0.000000, 1.045437, -0.087095 },
			LeftLeg = { -87.648560, 0.000000, 0.000000, 0.000000, -0.559518, -1.017810 },
		} },
		{ t = 0.600000, pose = {
			Torso = { -37.140380, 1.926258, 0.200552, 0.000000, 0.043861, -0.033219 },
			Head = { 29.745112, -0.056735, -1.435796, 0.000000, 0.000000, 0.000000 },
			RightArm = { -33.801701, -10.205930, -0.899994, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 100.434045, 17.850284, 0.930552, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 49.962263, 0.000000, 0.000000, 0.000000, 0.971804, -0.093356 },
			LeftLeg = { -86.248234, 0.000000, 0.000000, 0.000000, -0.504548, -0.964655 },
		} },
		{ t = 0.616667, pose = {
			Torso = { -37.142101, 1.795226, 0.802200, 0.000000, 0.032419, -0.024553 },
			Head = { 30.021974, -0.076478, -1.550554, 0.000000, 0.000000, 0.000000 },
			RightArm = { -39.316963, -10.068161, -0.513425, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 106.140115, 17.990367, 0.531507, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 55.435349, 0.000000, 0.000000, 0.000000, 0.750904, -0.112139 },
			LeftLeg = { -82.047285, 0.000000, 0.000000, 0.000000, -0.339638, -0.805189 },
		} },
		{ t = 0.633333, pose = {
			Torso = { -37.142097, 1.598654, 1.704627, 0.000000, 0.015256, -0.011555 },
			Head = { 30.219718, -0.090920, -1.632465, 0.000000, 0.000000, 0.000000 },
			RightArm = { -43.255687, -9.992475, -0.230045, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 110.218947, 18.066950, 0.238306, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 63.644987, 0.000000, 0.000000, 0.000000, 0.419555, -0.140313 },
			LeftLeg = { -75.745883, 0.000000, 0.000000, 0.000000, -0.092273, -0.565990 },
		} },
		{ t = 0.650000, pose = {
			Torso = { -37.140363, 1.467622, 2.306173, 0.000000, 0.003814, -0.002889 },
			Head = { 30.338345, -0.099720, -1.681588, 0.000000, 0.000000, 0.000000 },
			RightArm = { -45.618683, -9.956331, -0.057747, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 112.667174, 18.103305, 0.059841, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 69.118072, 0.000000, 0.000000, 0.000000, 0.198656, -0.159096 },
			LeftLeg = { -71.544927, 0.000000, 0.000000, 0.000000, 0.072637, -0.406525 },
		} },
		{ t = 0.666667, pose = {
			Torso = { -37.139488, 1.423952, 2.506670, 0.000000, 0.000000, 0.000000 },
			Head = { 30.377881, -0.102677, -1.697957, 0.000000, 0.000000, 0.000000 },
			RightArm = { -46.406310, -9.945841, 0.000000, 0.000000, 0.000000, 0.000000 },
			LeftArm = { 113.483409, 18.113812, 0.000000, 0.000000, 0.000000, 0.000000 },
			RightLeg = { 70.942436, 0.000000, 0.000000, 0.000000, 0.125022, -0.165357 },
			LeftLeg = { -70.144608, 0.000000, 0.000000, 0.000000, 0.127607, -0.353370 },
		} },
	},
}
detailed.Sprint = true

-- Everything else (block, reactions, dashes, jumps) gets the same smooth
-- curve, with the head following the body a beat behind.
for name, clip in pairs(Data) do
	if not detailed[name] then
		Data[name] = detail(clip, { Head = HEAD_SPRING }, BAKE_FPS)
	end
end

return Data

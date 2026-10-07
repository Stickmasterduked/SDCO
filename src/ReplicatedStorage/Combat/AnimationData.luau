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
Data.Stance = {
	length = 1.1, looped = true, priority = "Idle", group = "base",
	keys = {
		{ t = 0, ease = "Sine", dir = "InOut", pose = GUARD },
		{ t = 0.28, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -11, -22, 2, 0, -0.34, 0 },
			Head = { 11, 20, -2 },
			RightArm = { 94, 0, -40, 0, -0.04, 0.1 },
			LeftArm = { 104, 0, 30, 0, -0.03, -0.05 },
			RightLeg = { 5, 0, 10 },
			LeftLeg = { 27, 0, -6 },
		}) },
		{ t = 0.55, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -7, -18, -1, 0, -0.16, 0 },
			Head = { 7, 16, 1 },
			RightArm = { 104, 0, -43, 0, 0.03, 0.1 },
			LeftArm = { 111, 0, 27 },
		}) },
		{ t = 0.83, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -11, -19, -2, 0, -0.33, 0 },
			Head = { 11, 17, 2 },
			RightArm = { 97, 0, -41, 0, -0.03, 0.1 },
			LeftArm = { 103, 0, 29, 0, -0.04, -0.05 },
			RightLeg = { 5, 0, 10 },
			LeftLeg = { 27, 0, -6 },
		}) },
		{ t = 1.1, pose = GUARD },
	},
}

-- Guarded walk, authored for 16 studs/s (the client scales the playback).
local WALK_A = {
	Torso = { -10, -8, 0, 0, -0.3, 0 },
	Head = { 10, 8, 0 },
	RightArm = { 98, 0, -40, 0, 0, 0.15 },
	LeftArm = { 112, 0, 30, 0, 0, -0.1 },
	RightLeg = { 42, 0, 4 },
	LeftLeg = { -18, 0, -4 },
}
local WALK_PASS = {
	Torso = { -8, -14, 0, 0, -0.08, 0 },
	Head = { 8, 14, 0 },
	RightArm = { 104, 0, -42, 0, 0.04, 0.1 },
	LeftArm = { 106, 0, 28, 0, 0.04, -0.05 },
	RightLeg = { 18, 0, 4 },
	LeftLeg = { 4, 0, -4 },
}
Data.Walk = {
	length = 0.72, looped = true, priority = "Movement", group = "base", speedRef = 16,
	keys = {
		{ t = 0, ease = "Sine", dir = "InOut", pose = WALK_A },
		{ t = 0.18, ease = "Sine", dir = "InOut", pose = WALK_PASS },
		{ t = 0.36, ease = "Sine", dir = "InOut", pose = pose(WALK_A, {
			Torso = { -10, -20, 0, 0, -0.3, 0 },
			Head = { 10, 20, 0 },
			RightLeg = { -14, 0, 4 },
			LeftLeg = { 46, 0, -4 },
		}) },
		{ t = 0.54, ease = "Sine", dir = "InOut", pose = pose(WALK_PASS, {
			RightLeg = { 6, 0, 4 },
			LeftLeg = { 20, 0, -4 },
		}) },
		{ t = 0.72, pose = WALK_A },
	},
}

-- Sprint: hard forward lean, big arm pumps, high knees, a bouncing flight
-- phase between strides. Authored for 28 studs/s.
local RUN_A = {
	Torso = { -28, 10, 0, 0, -0.22, 0 },
	Head = { 24, -10, 0 },
	RightArm = { -40, 0, 8 },
	LeftArm = { 96, 0, 14 },
	RightLeg = { 64, 0, 4 },
	LeftLeg = { -12, 0, -4 },
}
local RUN_PASS = {
	Torso = { -24, 0, 0, 0, 0.1, 0 },
	Head = { 22, 0, 0 },
	RightArm = { 20, 0, 10 },
	LeftArm = { 36, 0, -10 },
	RightLeg = { 14, 0, 4 },
	LeftLeg = { 66, 0, -4 },
}
Data.Run = {
	length = 0.56, looped = true, priority = "Movement", group = "base", speedRef = 28,
	keys = {
		{ t = 0, ease = "Sine", dir = "Out", pose = RUN_A },
		{ t = 0.14, ease = "Sine", dir = "In", pose = RUN_PASS },
		{ t = 0.28, ease = "Sine", dir = "Out", pose = mirror(RUN_A) },
		{ t = 0.42, ease = "Sine", dir = "In", pose = mirror(RUN_PASS) },
		{ t = 0.56, pose = RUN_A },
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

Data.M1_1 = {
	length = 0.46, priority = "Action", group = "action", recover = 0.34,
	markers = { Swing = 0.06, Hit = 0.13 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		-- load: weight rocks back, rear fist chambers
		{ t = 0.06, ease = "Quart", dir = "Out", pose = {
			Torso = { -6, -36, 2, 0, -0.3, 0.12 },
			Head = { 6, 32, -2 },
			RightArm = { 84, 0, -30, 0, 0, 0.4 },
			LeftArm = { 104, 0, 30, 0, 0, -0.1 },
			RightLeg = { -4, 0, 11 },
			LeftLeg = { 26, 0, -6 },
		} },
		-- snap: hips whip around, step in, arm fully extended
		{ t = 0.13, ease = "Sine", dir = "Out", pose = {
			Torso = { -16, 40, -4, 0, -0.32, -0.6 },
			Head = { 10, -36, 4 },
			RightArm = { 94, 0, -8, 0, 0, -0.55 },
			LeftArm = { 78, 0, 44, 0, 0, 0.3 },
			RightLeg = { -10, 0, 8 },
			LeftLeg = { 34, 0, -6 },
		} },
		-- hang on the impact
		{ t = 0.17, ease = "Quad", dir = "InOut", pose = {
			Torso = { -18, 45, -5, 0, -0.34, -0.68 },
			Head = { 12, -40, 5 },
			RightArm = { 96, 0, -4, 0, 0, -0.6 },
			LeftArm = { 76, 0, 46, 0, 0, 0.32 },
			RightLeg = { -12, 0, 8 },
			LeftLeg = { 36, 0, -6 },
		} },
		-- recoil
		{ t = 0.25, ease = "Back", dir = "Out", pose = {
			Torso = { -12, 20, -2, 0, -0.28, -0.35 },
			Head = { 10, -18, 2 },
			RightArm = { 92, 0, -26, 0, 0, -0.1 },
			LeftArm = { 92, 0, 36, 0, 0, 0.1 },
			RightLeg = { -4, 0, 8 },
			LeftLeg = { 30, 0, -6 },
		} },
		-- overshoot past guard, then settle
		{ t = 0.36, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -9, -26, 1, 0, -0.26, 0.05 },
			Head = { 9, 24, -1 },
		}) },
		{ t = 0.46, pose = GUARD },
	},
}

Data.M1_2 = {
	length = 0.46, priority = "Action", group = "action", recover = 0.34,
	markers = { Swing = 0.07, Hit = 0.14 },
	trail = { "Left Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		-- load: dip onto the lead leg, lead arm swings wide
		{ t = 0.07, ease = "Quart", dir = "Out", pose = {
			Torso = { -10, 6, 6, 0, -0.38, 0 },
			Head = { 10, -6, -4 },
			RightArm = { 102, 0, -46, 0, 0, 0.15 },
			LeftArm = { 88, 0, -62, 0, 0.1, 0 },
			RightLeg = { 0, 0, 12 },
			LeftLeg = { 28, 0, -10 },
		} },
		-- whip across
		{ t = 0.14, ease = "Sine", dir = "Out", pose = {
			Torso = { -14, -50, -6, 0, -0.36, -0.35 },
			Head = { 10, 42, 4 },
			RightArm = { 104, 0, -48, 0, 0, 0.25 },
			LeftArm = { 94, 0, 36, 0, 0.05, -0.3 },
			RightLeg = { -14, 0, 12 },
			LeftLeg = { 30, 0, -8 },
		} },
		{ t = 0.18, ease = "Quad", dir = "InOut", pose = {
			Torso = { -15, -56, -7, 0, -0.37, -0.4 },
			Head = { 11, 46, 5 },
			RightArm = { 104, 0, -48, 0, 0, 0.25 },
			LeftArm = { 96, 0, 44, 0, 0.05, -0.35 },
			RightLeg = { -16, 0, 12 },
			LeftLeg = { 31, 0, -8 },
		} },
		{ t = 0.26, ease = "Back", dir = "Out", pose = {
			Torso = { -11, -36, -3, 0, -0.3, -0.2 },
			Head = { 9, 32, 2 },
			RightArm = { 100, 0, -44, 0, 0, 0.15 },
			LeftArm = { 92, 0, 22, 0, 0, -0.1 },
			RightLeg = { -6, 0, 10 },
			LeftLeg = { 28, 0, -6 },
		} },
		{ t = 0.37, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -9, -12, 0, 0, -0.24, 0 },
			Head = { 9, 12, 0 },
		}) },
		{ t = 0.46, pose = GUARD },
	},
}

Data.M1_3 = {
	length = 0.48, priority = "Action", group = "action", recover = 0.35,
	markers = { Swing = 0.07, Hit = 0.15 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		-- level change: drop the hips, fist low and loaded
		{ t = 0.07, ease = "Quart", dir = "Out", pose = {
			Torso = { -16, -38, -8, 0, -0.6, 0.1 },
			Head = { 16, 32, 6 },
			RightArm = { 40, 0, 14, 0, 0, 0.35 },
			LeftArm = { 106, 0, 34, 0, 0, 0 },
			RightLeg = { 4, 0, 18 },
			LeftLeg = { 40, 0, -14 },
		} },
		-- shovel up into the ribs
		{ t = 0.15, ease = "Sine", dir = "Out", pose = {
			Torso = { -26, 38, 6, 0, -0.66, -0.55 },
			Head = { 22, -34, -4 },
			RightArm = { 96, 0, -22, 0, -0.1, -0.45 },
			LeftArm = { 92, 0, 46, 0, 0, 0.25 },
			RightLeg = { 2, 0, 14 },
			LeftLeg = { 50, 0, -12 },
		} },
		{ t = 0.19, ease = "Quad", dir = "InOut", pose = {
			Torso = { -28, 44, 7, 0, -0.68, -0.62 },
			Head = { 24, -38, -5 },
			RightArm = { 100, 0, -20, 0, -0.1, -0.5 },
			LeftArm = { 90, 0, 48, 0, 0, 0.28 },
			RightLeg = { 2, 0, 14 },
			LeftLeg = { 52, 0, -12 },
		} },
		{ t = 0.28, ease = "Back", dir = "Out", pose = {
			Torso = { -16, 14, 2, 0, -0.42, -0.3 },
			Head = { 14, -12, -1 },
			RightArm = { 92, 0, -32, 0, 0, -0.1 },
			LeftArm = { 100, 0, 36, 0, 0, 0.1 },
			RightLeg = { 0, 0, 11 },
			LeftLeg = { 32, 0, -8 },
		} },
		{ t = 0.39, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -9, -26, 1, 0, -0.24, 0.05 },
			Head = { 9, 24, -1 },
		}) },
		{ t = 0.48, pose = GUARD },
	},
}

Data.M1_4 = {
	length = 0.56, priority = "Action", group = "action", recover = 0.4,
	markers = { Swing = 0.1, Hit = 0.18 },
	trail = { "Right Leg" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		-- chamber: wind the hips away, rear knee comes up and out
		{ t = 0.1, ease = "Quart", dir = "Out", pose = {
			Torso = { 2, -46, 8, 0, -0.18, 0.15 },
			Head = { 2, 40, -6 },
			RightArm = { 30, 0, 20, 0, 0, 0.2 },
			LeftArm = { 100, 0, 14 },
			RightLeg = { 64, 0, 36 },
			LeftLeg = { 4, 0, -6 },
		} },
		-- roundhouse: hips turn over, leg whips through at head height
		{ t = 0.18, ease = "Sine", dir = "Out", pose = {
			Torso = { 6, 50, 26, 0, -0.08, -0.2 },
			Head = { 0, -44, -18 },
			RightArm = { -10, 0, 30 },
			LeftArm = { 70, 0, -60 },
			RightLeg = { 6, 40, 96 },
			LeftLeg = { 8, 0, -20 },
		} },
		-- follow-through
		{ t = 0.24, ease = "Quad", dir = "InOut", pose = {
			Torso = { 6, 72, 28, 0, -0.1, -0.25 },
			Head = { 0, -62, -20 },
			RightArm = { -16, 0, 34 },
			LeftArm = { 66, 0, -64 },
			RightLeg = { 6, 14, 92 },
			LeftLeg = { 8, 0, -20 },
		} },
		-- recoil the leg and plant it
		{ t = 0.34, ease = "Back", dir = "Out", pose = {
			Torso = { -6, 30, 8, 0, -0.32, -0.2 },
			Head = { 6, -26, -6 },
			RightArm = { 70, 0, -20 },
			LeftArm = { 96, 0, 10 },
			RightLeg = { 40, 0, 26 },
			LeftLeg = { 14, 0, -10 },
		} },
		{ t = 0.45, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -10, -10, 0, 0, -0.3, 0 },
			Head = { 10, 10, 0 },
		}) },
		{ t = 0.56, pose = GUARD },
	},
}

-- Big committed haymaker: everything loads back, then the body launches
-- into the punch and hangs on it while the target flies.
Data.Finisher = {
	length = 0.84, priority = "Action", group = "action", recover = 0.62,
	markers = { Swing = 0.2, Hit = 0.27 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "In", pose = GUARD },
		{ t = 0.05, ease = "Sine", dir = "Out", pose = pose(GUARD, {
			Torso = { -2, -46, -3, 0, -0.34, 0.18 },
			Head = { 4, 40, 2 },
			RightArm = { 62, -12, 60, 0, 0, 0.15 },
		}) },
		{ t = 0.12, ease = "Sine", dir = "InOut", pose = {
			Torso = { 6, -68, -6, 0, -0.45, 0.4 },
			Head = { 2, 56, 4 },
			RightArm = { 0, -30, 78, 0, 0, 0.3 },
			LeftArm = { 100, 0, 16, 0, 0, -0.25 },
			RightLeg = { -14, 0, 14 },
			LeftLeg = { 30, 0, -10 },
		} },
		{ t = 0.2, ease = "Quint", dir = "Out", pose = {
			Torso = { 8, -76, -8, 0, -0.52, 0.48 },
			Head = { 2, 62, 5 },
			RightArm = { -6, -34, 84, 0, 0, 0.35 },
			LeftArm = { 102, 0, 14, 0, 0, -0.3 },
			RightLeg = { -16, 0, 15 },
			LeftLeg = { 32, 0, -10 },
		} },
		{ t = 0.27, ease = "Sine", dir = "Out", pose = {
			Torso = { -24, 56, -6, 0, -0.38, -1.15 },
			Head = { 18, -46, 6 },
			RightArm = { 98, 0, -4, 0, 0, -0.65 },
			LeftArm = { -20, 0, 34, 0, 0, 0.3 },
			RightLeg = { -22, 0, 8 },
			LeftLeg = { 52, 0, -6 },
		} },
		{ t = 0.36, ease = "Quad", dir = "InOut", pose = {
			Torso = { -26, 62, -7, 0, -0.4, -1.25 },
			Head = { 20, -50, 7 },
			RightArm = { 100, 0, 0, 0, 0, -0.7 },
			LeftArm = { -26, 0, 36, 0, 0, 0.32 },
			RightLeg = { -24, 0, 8 },
			LeftLeg = { 54, 0, -6 },
		} },
		{ t = 0.5, ease = "Back", dir = "Out", pose = {
			Torso = { -14, 34, -2, 0, -0.32, -0.75 },
			Head = { 12, -30, 2 },
			RightArm = { 82, 0, -22, 0, 0, -0.2 },
			LeftArm = { 60, 0, 30 },
			RightLeg = { -12, 0, 8 },
			LeftLeg = { 40, 0, -6 },
		} },
		{ t = 0.68, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -10, -28, 1, 0, -0.28, -0.1 },
			Head = { 10, 26, -1 },
		}) },
		{ t = 0.84, pose = GUARD },
	},
}

------------------------------------------------------------------------
-- Specials

-- Launcher: sinks into a deep crouch, then rockets up behind the uppercut.
Data.Uppercut = {
	length = 0.62, priority = "Action", group = "action", recover = 0.5,
	markers = { Swing = 0.14, Hit = 0.2 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		{ t = 0.1, ease = "Sine", dir = "InOut", pose = {
			Torso = { -22, -38, -6, 0, -0.95, 0.1 },
			Head = { 24, 30, 4 },
			RightArm = { -14, 0, 24, 0, 0, 0.2 },
			LeftArm = { 104, 0, 34 },
			RightLeg = { 8, 0, 22 },
			LeftLeg = { 52, 0, -18 },
		} },
		{ t = 0.14, ease = "Quint", dir = "Out", pose = {
			Torso = { -24, -40, -7, 0, -1.02, 0.12 },
			Head = { 26, 32, 5 },
			RightArm = { -18, 0, 26, 0, 0, 0.2 },
			LeftArm = { 104, 0, 36 },
			RightLeg = { 8, 0, 23 },
			LeftLeg = { 54, 0, -19 },
		} },
		{ t = 0.2, ease = "Sine", dir = "Out", pose = {
			Torso = { 10, 30, 8, 0, 0.3, -0.3 },
			Head = { 32, -24, -4 },
			RightArm = { 148, 0, -14, 0, 0.2, 0 },
			LeftArm = { -14, 0, 26 },
			RightLeg = { -24, 0, 6 },
			LeftLeg = { 64, 0, -6 },
		} },
		{ t = 0.28, ease = "Quad", dir = "InOut", pose = {
			Torso = { 14, 36, 9, 0, 0.36, -0.34 },
			Head = { 36, -28, -5 },
			RightArm = { 178, 0, -10, 0, 0.25, 0 },
			LeftArm = { -18, 0, 28 },
			RightLeg = { -28, 0, 6 },
			LeftLeg = { 70, 0, -6 },
		} },
		{ t = 0.42, ease = "Back", dir = "Out", pose = {
			Torso = { 4, 14, 3, 0, 0.1, -0.1 },
			Head = { 20, -10, -1 },
			RightArm = { 140, 0, -20 },
			LeftArm = { 60, 0, 30 },
			RightLeg = { 10, 0, 6 },
			LeftLeg = { 50, 0, -6 },
		} },
		{ t = 0.62, pose = AIR_GUARD },
	},
}

-- Air M1s: alternate a straight and a spinning kick while hanging in the air.
Data.AirPunch = {
	length = 0.42, priority = "Action", group = "action", recover = 0.32,
	markers = { Swing = 0.06, Hit = 0.12 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = AIR_GUARD },
		{ t = 0.06, ease = "Quart", dir = "Out", pose = {
			Torso = { 2, -36, 2, 0, 0, 0.15 },
			Head = { 4, 30, -2 },
			RightArm = { 84, 0, -30, 0, 0, 0.4 },
			LeftArm = { 104, 0, 30 },
			RightLeg = { 56, 0, 10 },
			LeftLeg = { 20, 0, -8 },
		} },
		{ t = 0.12, ease = "Sine", dir = "Out", pose = {
			Torso = { -20, 40, -4, 0, 0, -0.45 },
			Head = { 16, -36, 4 },
			RightArm = { 100, 0, -8, 0, 0, -0.55 },
			LeftArm = { 70, 0, 44, 0, 0, 0.3 },
			RightLeg = { -14, 0, 10 },
			LeftLeg = { 64, 0, -6 },
		} },
		{ t = 0.16, ease = "Quad", dir = "InOut", pose = {
			Torso = { -22, 44, -5, 0, 0, -0.5 },
			Head = { 18, -40, 5 },
			RightArm = { 102, 0, -4, 0, 0, -0.6 },
			LeftArm = { 68, 0, 46, 0, 0, 0.32 },
			RightLeg = { -16, 0, 10 },
			LeftLeg = { 66, 0, -6 },
		} },
		{ t = 0.26, ease = "Back", dir = "Out", pose = pose(AIR_GUARD, {
			Torso = { -10, 16, -2, 0, 0, -0.2 },
			Head = { 10, -12, 2 },
		}) },
		{ t = 0.42, pose = AIR_GUARD },
	},
}

Data.AirKick = {
	length = 0.44, priority = "Action", group = "action", recover = 0.33,
	markers = { Swing = 0.07, Hit = 0.13 },
	trail = { "Left Leg" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = AIR_GUARD },
		{ t = 0.07, ease = "Quart", dir = "Out", pose = {
			Torso = { 0, 40, -10, 0, 0.1, 0.1 },
			Head = { 4, -34, 8 },
			RightArm = { 90, 0, -60 },
			LeftArm = { 40, 0, -20 },
			RightLeg = { 30, 0, 8 },
			LeftLeg = { 60, 0, -40 },
		} },
		{ t = 0.13, ease = "Sine", dir = "Out", pose = {
			Torso = { 4, -54, -26, 0, 0.15, -0.2 },
			Head = { 4, 48, 20 },
			RightArm = { 60, 0, 70 },
			LeftArm = { -10, 0, -30 },
			RightLeg = { 30, 0, 14 },
			LeftLeg = { 6, -40, -96 },
		} },
		{ t = 0.18, ease = "Quad", dir = "InOut", pose = {
			Torso = { 4, -72, -28, 0, 0.15, -0.25 },
			Head = { 4, 62, 22 },
			RightArm = { 56, 0, 72 },
			LeftArm = { -14, 0, -34 },
			RightLeg = { 30, 0, 14 },
			LeftLeg = { 6, -14, -92 },
		} },
		{ t = 0.28, ease = "Back", dir = "Out", pose = pose(AIR_GUARD, {
			Torso = { -4, -30, -8, 0, 0.05, 0 },
			Head = { 6, 26, 6 },
			LeftLeg = { 40, 0, -26 },
		}) },
		{ t = 0.44, pose = AIR_GUARD },
	},
}

-- Air finisher / jump attack: both fists overhead, the whole body folds
-- forward and hammers down.
Data.Downslam = {
	length = 0.62, priority = "Action", group = "action", recover = 0.52,
	markers = { Swing = 0.16, Hit = 0.24 },
	trail = { "Right Arm", "Left Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = AIR_GUARD },
		{ t = 0.12, ease = "Sine", dir = "InOut", pose = {
			Torso = { 22, 0, 0, 0, 0.3, 0.2 },
			Head = { 10, 0, 0 },
			RightArm = { 196, 0, -8 },
			LeftArm = { 196, 0, 8 },
			RightLeg = { 50, 0, 8 },
			LeftLeg = { 40, 0, -8 },
		} },
		{ t = 0.16, ease = "Quint", dir = "Out", pose = {
			Torso = { 26, 0, 0, 0, 0.35, 0.25 },
			Head = { 12, 0, 0 },
			RightArm = { 204, 0, -8 },
			LeftArm = { 204, 0, 8 },
			RightLeg = { 54, 0, 8 },
			LeftLeg = { 44, 0, -8 },
		} },
		{ t = 0.24, ease = "Sine", dir = "Out", pose = {
			Torso = { -54, 0, 0, 0, -0.2, -0.4 },
			Head = { 44, 0, 0 },
			RightArm = { 70, 0, -12 },
			LeftArm = { 70, 0, 12 },
			RightLeg = { 4, 0, 8 },
			LeftLeg = { 24, 0, -8 },
		} },
		{ t = 0.32, ease = "Quad", dir = "InOut", pose = {
			Torso = { -60, 0, 0, 0, -0.25, -0.45 },
			Head = { 48, 0, 0 },
			RightArm = { 62, 0, -14 },
			LeftArm = { 62, 0, 14 },
			RightLeg = { 0, 0, 8 },
			LeftLeg = { 20, 0, -8 },
		} },
		{ t = 0.46, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -26, -10, 0, 0, -0.6, -0.1 },
			Head = { 22, 10, 0 },
			RightLeg = { 14, 0, 16 },
			LeftLeg = { 46, 0, -14 },
		}) },
		{ t = 0.62, pose = GUARD },
	},
}

-- Superman punch off a sprint: launches horizontal with the fist leading.
Data.RunningAttack = {
	length = 0.62, priority = "Action", group = "action", recover = 0.48,
	markers = { Swing = 0.12, Hit = 0.2 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		{ t = 0.1, ease = "Sine", dir = "InOut", pose = {
			Torso = { -22, -30, 0, 0, -0.6, 0.2 },
			Head = { 20, 26, 0 },
			RightArm = { -20, 0, 22 },
			LeftArm = { 90, 0, 20 },
			RightLeg = { -6, 0, 10 },
			LeftLeg = { 60, 0, -8 },
		} },
		{ t = 0.12, ease = "Quint", dir = "Out", pose = {
			Torso = { -24, -32, 0, 0, -0.64, 0.22 },
			Head = { 22, 28, 0 },
			RightArm = { -24, 0, 24 },
			LeftArm = { 90, 0, 20 },
			RightLeg = { -8, 0, 10 },
			LeftLeg = { 62, 0, -8 },
		} },
		{ t = 0.2, ease = "Sine", dir = "Out", pose = {
			Torso = { -56, 22, 0, 0, 0.2, -0.6 },
			Head = { 48, -18, 0 },
			RightArm = { 140, 0, -6 },
			LeftArm = { 10, 0, 30 },
			RightLeg = { 16, 0, 8 },
			LeftLeg = { 70, 0, -6 },
		} },
		{ t = 0.28, ease = "Quad", dir = "InOut", pose = {
			Torso = { -60, 26, 0, 0, 0.22, -0.7 },
			Head = { 52, -20, 0 },
			RightArm = { 144, 0, -4 },
			LeftArm = { 4, 0, 32 },
			RightLeg = { 12, 0, 8 },
			LeftLeg = { 72, 0, -6 },
		} },
		{ t = 0.4, ease = "Back", dir = "Out", pose = pose(GUARD, {
			Torso = { -24, 0, 0, 0, -0.7, -0.3 },
			Head = { 22, 0, 0 },
			RightLeg = { 18, 0, 18 },
			LeftLeg = { 52, 0, -14 },
		}) },
		{ t = 0.62, pose = GUARD },
	},
}

-- Critical (R): a long, readable charge with the body coiling and shaking,
-- then a corkscrew punch that lunges forward on the hit.
local CRIT_COIL = {
	Torso = { 6, -72, -6, 0, -0.5, 0.35 },
	Head = { 2, 60, 4 },
	RightArm = { 0, -40, 80, 0, 0, 0.35 },
	LeftArm = { 98, 0, 10, 0, 0, -0.3 },
	RightLeg = { -14, 0, 16 },
	LeftLeg = { 34, 0, -12 },
}
Data.Critical = {
	length = 1.0, priority = "Action", group = "action", recover = 0.82,
	markers = { Swing = 0.44, Hit = 0.5 },
	trail = { "Right Arm" },
	keys = {
		{ t = 0, ease = "Sine", dir = "In", pose = GUARD },
		{ t = 0.07, ease = "Sine", dir = "Out", pose = pose(GUARD, {
			Torso = { -2, -50, -3, 0, -0.38, 0.18 },
			Head = { 4, 44, 2 },
			RightArm = { 60, -16, 64, 0, 0, 0.2 },
			LeftArm = { 102, 0, 18, 0, 0, -0.15 },
		}) },
		{ t = 0.16, ease = "Sine", dir = "InOut", pose = CRIT_COIL },
		{ t = 0.24, ease = "Sine", dir = "InOut", pose = pose(CRIT_COIL, {
			Torso = { 7, -76, -9, 0, -0.55, 0.38 },
			RightArm = { -4, -44, 84, 0, 0, 0.38 },
		}) },
		{ t = 0.32, ease = "Sine", dir = "InOut", pose = pose(CRIT_COIL, {
			Torso = { 5, -73, -3, 0, -0.52, 0.36 },
		}) },
		{ t = 0.44, ease = "Quint", dir = "Out", pose = pose(CRIT_COIL, {
			Torso = { 9, -84, -10, 0, -0.62, 0.45 },
			Head = { 2, 70, 6 },
			RightArm = { -8, -50, 88, 0, 0, 0.4 },
		}) },
		{ t = 0.5, ease = "Sine", dir = "Out", pose = {
			Torso = { -28, 58, -12, 0, -0.42, -1.3 },
			Head = { 22, -48, 10 },
			RightArm = { 98, 40, -2, 0, 0, -0.7 },
			LeftArm = { -24, 0, 34, 0, 0, 0.3 },
			RightLeg = { -26, 0, 8 },
			LeftLeg = { 58, 0, -6 },
		} },
		{ t = 0.6, ease = "Quad", dir = "InOut", pose = {
			Torso = { -30, 64, -13, 0, -0.44, -1.4 },
			Head = { 24, -52, 11 },
			RightArm = { 100, 50, 0, 0, 0, -0.75 },
			LeftArm = { -30, 0, 36, 0, 0, 0.32 },
			RightLeg = { -28, 0, 8 },
			LeftLeg = { 60, 0, -6 },
		} },
		{ t = 0.74, ease = "Back", dir = "Out", pose = {
			Torso = { -16, 32, -4, 0, -0.34, -0.8 },
			Head = { 14, -28, 3 },
			RightArm = { 80, 0, -24, 0, 0, -0.2 },
			LeftArm = { 60, 0, 30 },
			RightLeg = { -12, 0, 8 },
			LeftLeg = { 40, 0, -6 },
		} },
		{ t = 0.88, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -10, -28, 1, 0, -0.28, -0.1 },
			Head = { 10, 26, -1 },
		}) },
		{ t = 1.0, pose = GUARD },
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

return Data

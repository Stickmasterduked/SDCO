--[[
	R6 fist animations, authored as pose data and built into KeyframeSequences
	by AnimationBuilder.

	Each joint pose is { pitch, yaw, roll, x, y, z } in degrees / studs,
	expressed in the parent part's space at the joint pivot:
	  Torso is relative to HumanoidRootPart, limbs and Head are relative to Torso.
	  pitch +  = limb swings forward/up (Torso: leans back)
	  yaw   +  = turns left
	  roll  +  = limb end swings toward +X (right)

	group:
	  base    - stance / walk, never stopped by other tracks
	  hold    - looping holds (block), stopped explicitly
	  action  - attacks, rolls, feints; replaces other action/react/hold tracks
	  react   - hit reactions and stuns; replaces action/react/hold tracks
	  overlay - plays on top without stopping anything

	markers become KeyframeMarkers. `Hit` is the impact frame the server uses,
	`recover` is when the attacker can act again.
]]

local GUARD = {
	Torso = { -4, -15, 0 },
	Head = { 0, 13, 0 },
	RightArm = { 74, 0, -30, 0, 0, 0.15 },
	LeftArm = { 84, 0, 24 },
}

local BLOCK = {
	Torso = { -6, 0, 0 },
	Head = { -12, 0, 0 },
	RightArm = { 104, 0, -50, 0, 0, 0.25 },
	LeftArm = { 100, 0, 47, 0, 0, 0.25 },
}

local LEGS_NEUTRAL = { RightLeg = { 0, 0, 0 }, LeftLeg = { 0, 0, 0 } }

local function pose(...)
	local result = {}
	for _, part in ipairs({ ... }) do
		for joint, value in pairs(part) do
			result[joint] = value
		end
	end
	return result
end

local Data = {}

-- Fighter's bounce: weight dips and rises on the balls of the feet, fists
-- bob slightly out of phase so the guard never looks frozen.
Data.Stance = {
	length = 0.9, looped = true, priority = "Idle", group = "base",
	keys = {
		{ t = 0, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -4, -15, 1, 0, 0.02, 0 },
			RightArm = { 76, 0, -30, 0, 0.02, 0.15 },
			LeftArm = { 82, 0, 25 },
		}) },
		{ t = 0.45, ease = "Sine", dir = "InOut", pose = pose(GUARD, {
			Torso = { -7, -16, -1, 0, -0.1, 0 },
			Head = { 3, 13, 0 },
			RightArm = { 72, 0, -31, 0, -0.05, 0.15 },
			LeftArm = { 87, 0, 23, 0, -0.04, 0 },
		}) },
		{ t = 0.9, pose = pose(GUARD, {
			Torso = { -4, -15, 1, 0, 0.02, 0 },
			RightArm = { 76, 0, -30, 0, 0.02, 0.15 },
			LeftArm = { 82, 0, 25 },
		}) },
	},
}

Data.Walk = {
	length = 0.8, looped = true, priority = "Movement", group = "base",
	keys = {
		{ t = 0, ease = "Sine", dir = "InOut", pose = { RightLeg = { 32, 0, 0 }, LeftLeg = { -32, 0, 0 } } },
		{ t = 0.4, ease = "Sine", dir = "InOut", pose = { RightLeg = { -32, 0, 0 }, LeftLeg = { 32, 0, 0 } } },
		{ t = 0.8, pose = { RightLeg = { 32, 0, 0 }, LeftLeg = { -32, 0, 0 } } },
	},
}

-- Punches: hip-loaded wind-up, the back foot drives, the strike overshoots
-- (Back easing) and snaps back into guard through a short settle.
Data.PunchRight = {
	length = 0.52, priority = "Action", group = "action", recover = 0.36,
	markers = { Swing = 0.1, Hit = 0.18 },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.1, ease = "Back", dir = "Out", pose = {
			Torso = { -3, -30, 3, 0, -0.08, 0.05 },
			Head = { 2, 24, 0 },
			RightArm = { 54, 0, -12, 0, 0, 0.5 },
			LeftArm = { 88, 0, 28, 0, 0, -0.1 },
			RightLeg = { -10, 0, 4 },
			LeftLeg = { 12, 0, -3 },
		} },
		{ t = 0.18, ease = "Quad", dir = "Out", pose = {
			Torso = { -15, 38, -3, 0, -0.14, -0.5 },
			Head = { -5, -32, 2 },
			RightArm = { 95, 0, -8, 0, 0, -0.6 },
			LeftArm = { 70, 0, 34, 0, 0, 0.35 },
			RightLeg = { -22, 0, 3 },
			LeftLeg = { 20, 0, -4 },
		} },
		{ t = 0.26, ease = "Sine", dir = "InOut", pose = {
			Torso = { -12, 32, -2, 0, -0.1, -0.4 },
			Head = { -4, -27, 1 },
			RightArm = { 88, 0, -13, 0, 0, -0.42 },
			LeftArm = { 74, 0, 31, 0, 0, 0.28 },
			RightLeg = { -16, 0, 2 },
			LeftLeg = { 15, 0, -3 },
		} },
		{ t = 0.4, ease = "Sine", dir = "Out", pose = pose(GUARD, {
			Torso = { -6, -10, 0, 0, -0.03, 0 },
			RightLeg = { -4, 0, 0 },
			LeftLeg = { 4, 0, 0 },
		}) },
		{ t = 0.52, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

Data.PunchLeft = {
	length = 0.52, priority = "Action", group = "action", recover = 0.36,
	markers = { Swing = 0.1, Hit = 0.18 },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.1, ease = "Back", dir = "Out", pose = {
			Torso = { -3, 17, -3, 0, -0.08, 0.05 },
			Head = { 2, -14, 0 },
			RightArm = { 80, 0, -34, 0, 0, 0.15 },
			LeftArm = { 56, 0, 12, 0, 0, 0.5 },
			RightLeg = { 10, 0, 3 },
			LeftLeg = { -12, 0, -4 },
		} },
		{ t = 0.18, ease = "Quad", dir = "Out", pose = {
			Torso = { -14, -40, 3, 0, -0.14, -0.45 },
			Head = { -5, 34, -2 },
			RightArm = { 70, 0, -34, 0, 0, 0.38 },
			LeftArm = { 95, 0, 8, 0, 0, -0.6 },
			RightLeg = { 20, 0, 4 },
			LeftLeg = { -22, 0, -3 },
		} },
		{ t = 0.26, ease = "Sine", dir = "InOut", pose = {
			Torso = { -11, -34, 2, 0, -0.1, -0.35 },
			Head = { -4, 29, -1 },
			RightArm = { 74, 0, -31, 0, 0, 0.3 },
			LeftArm = { 88, 0, 13, 0, 0, -0.42 },
			RightLeg = { 15, 0, 3 },
			LeftLeg = { -16, 0, -2 },
		} },
		{ t = 0.4, ease = "Sine", dir = "Out", pose = pose(GUARD, {
			Torso = { -6, -18, 0, 0, -0.03, 0 },
			RightLeg = { 4, 0, 0 },
			LeftLeg = { -4, 0, 0 },
		}) },
		{ t = 0.52, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

Data.Flourish = {
	length = 0.72, priority = "Action", group = "action", recover = 0.6,
	markers = { Swing = 0.17, Hit = 0.3 },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.17, ease = "Linear", pose = {
			Torso = { 8, 12, 0, 0, 0.1, 0 },
			Head = { -8, -10, 0 },
			RightArm = { 55, 0, 40 },
			LeftArm = { 75, 0, 30 },
			RightLeg = { 58, 0, 0 },
			LeftLeg = { -6, 0, 0 },
		} },
		{ t = 0.3, ease = "Quad", dir = "Out", pose = {
			Torso = { 18, 18, 0, 0, 0.15, 0.2 },
			Head = { -16, -14, 0 },
			RightArm = { 25, 0, 45 },
			LeftArm = { 70, 0, 35 },
			RightLeg = { 102, 0, 0 },
			LeftLeg = { -12, 0, 0 },
		} },
		{ t = 0.42, ease = "Quad", dir = "InOut", pose = {
			Torso = { 14, 16, 0, 0, 0.1, 0.15 },
			Head = { -12, -12, 0 },
			RightArm = { 30, 0, 42 },
			LeftArm = { 72, 0, 33 },
			RightLeg = { 92, 0, 0 },
			LeftLeg = { -10, 0, 0 },
		} },
		{ t = 0.72, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

Data.Uppercut = {
	length = 0.68, priority = "Action", group = "action", recover = 0.56,
	markers = { Swing = 0.15, Hit = 0.28 },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.15, ease = "Linear", pose = {
			Torso = { -22, -24, 0, 0, -0.55, 0 },
			Head = { 12, 18, 0 },
			RightArm = { 22, 0, -8, 0, 0, 0.35 },
			LeftArm = { 84, 0, 26 },
			RightLeg = { 38, 0, 0 },
			LeftLeg = { -38, 0, 0 },
		} },
		{ t = 0.28, ease = "Quad", dir = "Out", pose = {
			Torso = { 12, 28, 0, 0, 0.3, 0 },
			Head = { 18, -10, 0 },
			RightArm = { 172, 0, -8 },
			LeftArm = { 55, 0, 32 },
			RightLeg = { 10, 0, 0 },
			LeftLeg = { -14, 0, 0 },
		} },
		{ t = 0.42, ease = "Quad", dir = "InOut", pose = {
			Torso = { 10, 24, 0, 0, 0.2, 0 },
			Head = { 14, -8, 0 },
			RightArm = { 165, 0, -6 },
			LeftArm = { 58, 0, 30 },
			RightLeg = { 6, 0, 0 },
			LeftLeg = { -8, 0, 0 },
		} },
		{ t = 0.68, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

Data.Aerial = {
	length = 0.6, priority = "Action", group = "action", recover = 0.5,
	markers = { Swing = 0.12, Hit = 0.25 },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.12, ease = "Linear", pose = {
			Torso = { 16, 0, 0 },
			Head = { 10, 0, 0 },
			RightArm = { 168, 0, 12 },
			LeftArm = { 168, 0, -12 },
			RightLeg = { 22, 0, 0 },
			LeftLeg = { -18, 0, 0 },
		} },
		{ t = 0.25, ease = "Quad", dir = "Out", pose = {
			Torso = { -38, 0, 0, 0, 0, -0.3 },
			Head = { 18, 0, 0 },
			RightArm = { 68, 0, -16 },
			LeftArm = { 68, 0, 16 },
			RightLeg = { 45, 0, 0 },
			LeftLeg = { 28, 0, 0 },
		} },
		{ t = 0.36, ease = "Quad", dir = "InOut", pose = {
			Torso = { -32, 0, 0, 0, 0, -0.25 },
			Head = { 15, 0, 0 },
			RightArm = { 64, 0, -14 },
			LeftArm = { 64, 0, 14 },
			RightLeg = { 38, 0, 0 },
			LeftLeg = { 24, 0, 0 },
		} },
		{ t = 0.6, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

Data.RunningAttack = {
	length = 0.62, priority = "Action", group = "action", recover = 0.5,
	markers = { Swing = 0.1, Hit = 0.22 },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.1, ease = "Linear", pose = {
			Torso = { -16, -32, 0 },
			Head = { 6, 26, 0 },
			RightArm = { 40, 0, -10, 0, 0, 0.5 },
			LeftArm = { 80, 0, 28 },
			RightLeg = { 30, 0, 0 },
			LeftLeg = { -30, 0, 0 },
		} },
		{ t = 0.22, ease = "Quad", dir = "Out", pose = {
			Torso = { -28, 40, 0, 0, -0.3, -0.45 },
			Head = { 12, -32, 0 },
			RightArm = { 96, 0, -6, 0, 0, -0.6 },
			LeftArm = { -28, 0, 22 },
			RightLeg = { -36, 0, 0 },
			LeftLeg = { 40, 0, 0 },
		} },
		{ t = 0.36, ease = "Quad", dir = "InOut", pose = {
			Torso = { -24, 36, 0, 0, -0.25, -0.4 },
			Head = { 10, -29, 0 },
			RightArm = { 92, 0, -8, 0, 0, -0.5 },
			LeftArm = { -20, 0, 22 },
			RightLeg = { -30, 0, 0 },
			LeftLeg = { 34, 0, 0 },
		} },
		{ t = 0.62, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

Data.Critical = {
	length = 1.0, priority = "Action", group = "action", recover = 0.86,
	markers = { Swing = 0.48, Hit = 0.56 },
	keys = {
		{ t = 0, ease = "Cubic", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.38, ease = "Sine", dir = "InOut", pose = {
			Torso = { 6, -50, 0, 0, -0.2, 0.3 },
			Head = { 0, 40, 0 },
			RightArm = { 34, 0, 36, 0, 0, 0.5 },
			LeftArm = { 92, 0, 30 },
			RightLeg = { -16, 0, 0 },
			LeftLeg = { 24, 0, 0 },
		} },
		{ t = 0.48, ease = "Linear", pose = {
			Torso = { 9, -56, 0, 0, -0.25, 0.35 },
			Head = { 0, 44, 0 },
			RightArm = { 30, 0, 40, 0, 0, 0.55 },
			LeftArm = { 94, 0, 30 },
			RightLeg = { -18, 0, 0 },
			LeftLeg = { 26, 0, 0 },
		} },
		{ t = 0.56, ease = "Quad", dir = "Out", pose = {
			Torso = { -22, 46, 0, 0, -0.25, -0.65 },
			Head = { -6, -36, 0 },
			RightArm = { 95, 0, -5, 0, 0, -0.7 },
			LeftArm = { 40, 0, 40, 0, 0, 0.4 },
			RightLeg = { -32, 0, 0 },
			LeftLeg = { 36, 0, 0 },
		} },
		{ t = 0.72, ease = "Quad", dir = "InOut", pose = {
			Torso = { -20, 42, 0, 0, -0.2, -0.6 },
			Head = { -5, -33, 0 },
			RightArm = { 92, 0, -7, 0, 0, -0.6 },
			LeftArm = { 44, 0, 38, 0, 0, 0.35 },
			RightLeg = { -28, 0, 0 },
			LeftLeg = { 32, 0, 0 },
		} },
		{ t = 1.0, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

Data.Feint = {
	length = 0.26, priority = "Action", group = "action",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = {
			Torso = { 2, 4, 0 },
			Head = { 0, 4, 0 },
			RightArm = { 62, 0, -38, 0, 0, 0.3 },
			LeftArm = { 66, 0, 36, 0, 0, 0.2 },
		} },
		{ t = 0.26, pose = GUARD },
	},
}

Data.Block = {
	length = 1, looped = true, priority = "Action", group = "hold",
	keys = {
		{ t = 0, pose = BLOCK },
		{ t = 1, pose = BLOCK },
	},
}

Data.Parried = {
	length = 0.5, priority = "Action3", group = "react",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.1, ease = "Quad", dir = "InOut", pose = {
			Torso = { 18, -10, 0, 0, 0, 0.35 },
			Head = { 20, 6, 0 },
			RightArm = { 150, 0, 46 },
			LeftArm = { 118, 0, -28 },
			RightLeg = { -10, 0, 0 },
			LeftLeg = { 10, 0, 0 },
		} },
		{ t = 0.28, ease = "Quad", dir = "InOut", pose = {
			Torso = { 12, -8, 0, 0, 0, 0.25 },
			Head = { 12, 6, 0 },
			RightArm = { 120, 0, 30 },
			LeftArm = { 100, 0, -10 },
			RightLeg = { -8, 0, 0 },
			LeftLeg = { 8, 0, 0 },
		} },
		{ t = 0.5, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

Data.HitFront = {
	length = 0.42, priority = "Action3", group = "react", variants = { "HitFront", "HitFrontB" },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		{ t = 0.06, ease = "Quad", dir = "InOut", pose = {
			Torso = { 17, 10, 6, 0, 0, 0.25 },
			Head = { 24, 8, 0 },
			RightArm = { 50, 0, 40 },
			LeftArm = { 56, 0, -34 },
		} },
		{ t = 0.42, pose = GUARD },
	},
}

Data.HitFrontB = {
	length = 0.42, priority = "Action3", group = "react",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		{ t = 0.06, ease = "Quad", dir = "InOut", pose = {
			Torso = { 15, -14, -7, 0, 0, 0.25 },
			Head = { 20, -10, 6 },
			RightArm = { 60, 0, 30 },
			LeftArm = { 44, 0, -42 },
		} },
		{ t = 0.42, pose = GUARD },
	},
}

Data.HitBack = {
	length = 0.42, priority = "Action3", group = "react",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = GUARD },
		{ t = 0.06, ease = "Quad", dir = "InOut", pose = {
			Torso = { -20, -6, 0, 0, 0, -0.25 },
			Head = { -16, 0, 0 },
			RightArm = { 22, 0, 32 },
			LeftArm = { 22, 0, -32 },
		} },
		{ t = 0.42, pose = GUARD },
	},
}

Data.BlockImpact = {
	length = 0.26, priority = "Action3", group = "overlay",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = BLOCK },
		{ t = 0.05, ease = "Quad", dir = "InOut", pose = {
			Torso = { 9, 0, 0, 0, 0, 0.25 },
			Head = { -4, 0, 0 },
			RightArm = { 113, 0, -46, 0, 0, 0.45 },
			LeftArm = { 108, 0, 43, 0, 0, 0.45 },
		} },
		{ t = 0.26, pose = BLOCK },
	},
}

Data.GuardBreak = {
	length = 1.5, priority = "Action4", group = "react",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(BLOCK, LEGS_NEUTRAL) },
		{ t = 0.1, ease = "Quad", dir = "InOut", pose = {
			Torso = { 28, 0, 0, 0, 0, 0.4 },
			Head = { 30, 0, 0 },
			RightArm = { 75, 0, 82 },
			LeftArm = { 75, 0, -82 },
			RightLeg = { -12, 0, 6 },
			LeftLeg = { 14, 0, -6 },
		} },
		{ t = 0.55, ease = "Sine", dir = "InOut", pose = {
			Torso = { -26, 6, 8, 0, -0.35, 0 },
			Head = { -22, -6, 0 },
			RightArm = { 12, 0, 14 },
			LeftArm = { 18, 0, -12 },
			RightLeg = { 22, 0, 4 },
			LeftLeg = { -20, 0, -4 },
		} },
		{ t = 1.2, ease = "Quad", dir = "InOut", pose = {
			Torso = { -24, 4, 6, 0, -0.32, 0 },
			Head = { -18, -4, 0 },
			RightArm = { 16, 0, 12 },
			LeftArm = { 20, 0, -10 },
			RightLeg = { 20, 0, 4 },
			LeftLeg = { -18, 0, -4 },
		} },
		{ t = 1.5, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

-- Spiked into the ground by a downslam: crumples to one knee, then rises.
Data.Slammed = {
	length = 1.15, priority = "Action4", group = "react",
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.12, ease = "Back", dir = "Out", pose = {
			Torso = { 38, 0, 6, 0, -1.25, 0.35 },
			Head = { 28, 0, -6 },
			RightArm = { 20, 0, 40 },
			LeftArm = { 30, 0, -46 },
			RightLeg = { 80, 0, 6 },
			LeftLeg = { -12, 0, -10 },
		} },
		{ t = 0.75, ease = "Sine", dir = "InOut", pose = {
			Torso = { 30, 4, 4, 0, -1.15, 0.3 },
			Head = { 18, -4, -4 },
			RightArm = { 30, 0, 34 },
			LeftArm = { 36, 0, -40 },
			RightLeg = { 76, 0, 6 },
			LeftLeg = { -10, 0, -8 },
		} },
		{ t = 1.15, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

local TUCK_ARMS = { RightArm = { 150, 0, -18 }, LeftArm = { 150, 0, 18 } }
local TUCK_LEGS = { RightLeg = { 95, 0, 0 }, LeftLeg = { 95, 0, 0 } }

Data.RollForward = {
	length = 0.38, priority = "Action3", group = "action",
	keys = {
		{ t = 0, ease = "Linear", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.07, ease = "Linear", pose = pose(TUCK_ARMS, TUCK_LEGS, { Torso = { -90, 0, 0, 0, -1.3, 0 }, Head = { -30, 0, 0 } }) },
		{ t = 0.14, ease = "Linear", pose = pose(TUCK_ARMS, TUCK_LEGS, { Torso = { -180, 0, 0, 0, -1.6, 0 }, Head = { -30, 0, 0 } }) },
		{ t = 0.21, ease = "Linear", pose = pose(TUCK_ARMS, TUCK_LEGS, { Torso = { -270, 0, 0, 0, -1.3, 0 }, Head = { -30, 0, 0 } }) },
		{ t = 0.29, ease = "Quad", dir = "Out", pose = pose(GUARD, { Torso = { -350, -10, 0, 0, -0.3, 0 }, RightLeg = { 20, 0, 0 }, LeftLeg = { -10, 0, 0 } }) },
		{ t = 0.38, pose = pose(GUARD, LEGS_NEUTRAL, { Torso = { -364, -15, 0 } }) },
	},
}

-- Low, fast sidestep: pushes off, slides with the guard up, then settles.
-- `roll` leans the body into the dash, `lean` pitches it (back dash leans back).
local function dodge(roll, lean, trailLeg)
	local push = {
		Torso = { lean * 0.6, 0, roll * 0.5, 0, -0.35, 0 },
		Head = { -lean * 0.3, 0, -roll * 0.3 },
		RightArm = { 78, 0, -30 + roll * 0.4 },
		LeftArm = { 82, 0, 26 + roll * 0.4 },
		RightLeg = { -lean * 0.5, 0, 18 },
		LeftLeg = { lean * 0.5, 0, -18 },
	}
	local slide = {
		Torso = { lean, 0, roll, 0, -0.75, 0 },
		Head = { -lean * 0.5, 0, -roll * 0.7 },
		RightArm = { 72, 0, -24 + roll * 0.9 },
		LeftArm = { 78, 0, 22 + roll * 0.9 },
		RightLeg = { -lean, 0, trailLeg == "Right" and 38 or 14 },
		LeftLeg = { lean, 0, trailLeg == "Left" and -38 or -14 },
	}
	return {
		length = 0.36, priority = "Action3", group = "action",
		keys = {
			{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
			{ t = 0.05, ease = "Quad", dir = "Out", pose = push },
			{ t = 0.12, ease = "Linear", pose = slide },
			{ t = 0.24, ease = "Quad", dir = "InOut", pose = slide },
			{ t = 0.36, pose = pose(GUARD, LEGS_NEUTRAL) },
		},
	}
end

Data.DodgeLeft = dodge(26, -6, "Right")
Data.DodgeRight = dodge(-26, -6, "Left")
Data.DodgeBack = dodge(0, 18, "Right")

-- The jump attack / last air hit: both fists hammer down.
Data.Downslam = Data.Aerial

-- Slash skill cast: two fingers drawn across the chest, then flicked out
-- in a flat sweep that releases the slash.
Data.SkillCast = {
	length = 0.62, priority = "Action", group = "action", recover = 0.55,
	markers = { Swing = 0.16, Hit = 0.22 },
	keys = {
		{ t = 0, ease = "Quad", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
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
		{ t = 0.62, pose = pose(GUARD, LEGS_NEUTRAL) },
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
		{ t = 0, ease = "Back", dir = "Out", pose = pose(GUARD, LEGS_NEUTRAL) },
		{ t = 0.25, ease = "Sine", dir = "InOut", pose = KNEEL },
		{ t = 1.0, ease = "Sine", dir = "InOut", pose = pose(KNEEL, { Torso = { 28, 0, 4, 0, -1.25, 0.3 }, Head = { 38, 4, 0 } }) },
		{ t = 1.65, ease = "Quad", dir = "InOut", pose = KNEEL },
		{ t = 2, pose = pose(GUARD, LEGS_NEUTRAL) },
	},
}

return Data

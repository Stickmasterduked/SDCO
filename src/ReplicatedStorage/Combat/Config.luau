--[[
	All tunable combat values live here. Times are in seconds.
	Attack timing (windup / recovery / total length) is read from the
	animation markers in AnimationData so visuals and hit frames never drift.
]]

local Config = {}

-- Movement. Faster than Roblox defaults: battlegrounds pacing.
Config.WalkSpeed = 17
Config.SprintSpeed = 28
Config.SprintDoubleTapWindow = 0.3
Config.JumpHeight = 7.6

-- Double jump (Space in the air): one per airtime, a flip with a burst of wind.
Config.DoubleJumpVelocity = 48
Config.DoubleJumpWindow = 0.12 -- min time after leaving the ground

Config.MaxHealth = 100
Config.MaxPosture = 100

-- M1 chain: four strikes, the fifth press is the finisher.
Config.ComboResetTime = 1.1
Config.ComboLength = 5
Config.M1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" }
Config.AirChain = { "AirPunch", "AirKick" }
Config.InputBufferTime = 0.22

-- Parry / block
Config.ParryWindow = 0.42
Config.ParryCooldown = 0.7 -- applied on press, refunded on a successful parry
Config.ParriedStun = 0.45 -- the parried attacker can't attack for this long, but can still parry back
Config.BlockCooldown = 0.2 -- after letting go of block (or a guard break ending)
Config.BlockBuffer = 0.25 -- F pressed this close before a stun ends still parries
Config.ParryPostureRecover = 15
Config.ShakyBlockTime = 0.25
Config.ShakyPostureMult = 1.5
Config.ChipDamage = 0.25
Config.BlockWalkSpeed = 11
Config.FacingDot = 0.15 -- how directly you must face an attack to block/parry it

-- Posture
Config.PostureRegenDelay = 1.5
Config.PostureRegenRate = 18 -- per second, only while not blocking
Config.GuardBreakStun = 1.5
Config.GuardBreakDamageMult = 1.6

-- Feint
Config.FeintCooldown = 1.5
Config.FeintLockout = 0.06 -- can't feint this close to the hit frame

-- Dash (Q). Direction follows your movement keys and can be steered
-- mid-dash. Side dashes near an opponent curve around them.
Config.RollCooldown = 1.1
Config.RollCancelCooldown = 0.7
Config.RollCancelWindow = 0.15
Config.RollIFrames = 0.24
Config.RollDuration = 0.36
Config.RollSpeed = 76 -- peak speed; eases out to ~12 studs total
Config.AirDashSpeed = 66
Config.DashOrbitRange = 16 -- side dashes orbit an opponent this close

Config.AttackWalkSpeed = 10 -- low, so the strikes' own lunges carry the movement
Config.StunWalkSpeed = 5

-- Engagement: attacks soft-turn you toward the enemy in front of you so
-- trades happen face to face.
Config.AimAssistRange = 14
Config.AimAssistAngle = 70 -- degrees either side of where you're looking
Config.AimAssistTurnRate = 16 -- higher = snappier

-- Air combos (Space + M1 launches, air M1s juggle, the last one slams)
Config.LauncherBuffer = 0.12 -- Space waits this long for an M1 before it jumps
Config.JuggleHover = 0.8 -- target floats this long after each air hit
Config.JuggleHitstun = 0.3 -- short, so a good player can block/dash between hits
Config.AirAttackHover = 0.55 -- attacker floats while comboing
Config.MaxJuggleTime = 3.2
Config.LaunchApexDelay = 0.36
Config.SlamStun = 1.15
Config.SlamSpeed = 95

-- Shift lock (Alt)
Config.ShiftLockOffset = Vector3.new(1.75, 0.25, 0)

-- Camera. Intensity scales every effect below (0 turns them all off).
Config.Camera = {
	Intensity = 1,
	BaseFOV = 70,
	SprintFOV = 9, -- added while sprinting
	DashFOV = 12, -- kick on a dash
	StrafeTilt = 2.2, -- degrees of roll when strafing at walk speed
	DashTilt = 7, -- roll kick on a side dash
	RunBob = 0.05, -- studs of bob while sprinting
	ImpactFrames = true, -- brief contrast flash on big hits
}

-- Hit-stop: both fighters freeze for this long when a hit connects.
Config.HitStop = {
	Hit = 0.065,
	HeavyHit = 0.12,
	Block = 0.045,
	Parry = 0.13,
	GuardBreak = 0.15,
	Slam = 0.1,
}

--[[
	Attack definitions. `anim` is the AnimationData key.
	damage / posture: health and posture dealt. hitstun: stun on a clean hit.
	range / width: hitbox depth and width in studs, in front of the attacker.
	knockback: horizontal push on clean hit. launch: vertical push.
	pushTime: how long the knockback push lasts (default 0.15).
	lunge: forward movement for the attacker {speed, duration} at windup start.
	react: the hit reaction the target plays (default HitFront / HitBack).
	heavy: bigger hit effects, hit-stop and camera kick.
]]
Config.Attacks = {
	M1_1 = {
		anim = "M1_1", damage = 10, posture = 9, hitstun = 0.5,
		range = 5.8, width = 4.5, knockback = 3, lunge = { 9, 0.1 },
		feintable = true, isM1 = true,
	},
	M1_2 = {
		anim = "M1_2", damage = 10, posture = 9, hitstun = 0.5,
		range = 5.8, width = 5, knockback = 3, lunge = { 8, 0.1 },
		react = "HitFrontB", feintable = true, isM1 = true,
	},
	M1_3 = {
		anim = "M1_3", damage = 10, posture = 10, hitstun = 0.53,
		range = 5.6, width = 4.5, knockback = 3, lunge = { 9, 0.1 },
		react = "HitFrontC", feintable = true, isM1 = true,
	},
	M1_4 = {
		anim = "M1_4", damage = 10, posture = 11, hitstun = 0.64,
		range = 6.2, width = 5.5, knockback = 5, lunge = { 6, 0.12 },
		feintable = true, isM1 = true,
	},
	Finisher = {
		anim = "Finisher", damage = 12, posture = 16, hitstun = 1.0,
		range = 6, width = 5, knockback = 72, launch = 18, pushTime = 0.24, lunge = { 14, 0.16 },
		react = "Knockback", heavy = true, feintable = true, isM1 = true, endsCombo = true,
	},
	AirPunch = {
		anim = "AirPunch", damage = 10, posture = 9, hitstun = 0.3,
		range = 6.5, width = 5, height = 9, knockback = 1.5, juggle = true,
		feintable = true, isM1 = true, air = true,
	},
	AirKick = {
		anim = "AirKick", damage = 10, posture = 9, hitstun = 0.3,
		range = 6.5, width = 5.5, height = 9, knockback = 1.5, juggle = true,
		feintable = true, isM1 = true, air = true,
	},
	Downslam = {
		anim = "Downslam", damage = 10, posture = 16, hitstun = 1.15,
		range = 6.5, width = 5.5, height = 11, knockback = 6, slam = true,
		lunge = { 10, 0.15 }, heavy = true, feintable = true, isM1 = true, air = true, endsCombo = true,
	},
	Uppercut = {
		anim = "Uppercut", damage = 10, posture = 12, hitstun = 0.45,
		range = 5.8, width = 4.5, knockback = 1, launch = 60, selfLaunch = 58,
		heavy = true, juggle = true, launcher = true, feintable = true, isM1 = true,
	},
	RunningAttack = {
		anim = "RunningAttack", damage = 10, posture = 13, hitstun = 0.7,
		range = 6.5, width = 4.5, knockback = 30, launch = 6, pushTime = 0.2, lunge = { 40, 0.22 },
		heavy = true, feintable = true, isM1 = true,
	},
	Critical = {
		anim = "Critical", damage = 15, posture = 34, hitstun = 1.0,
		range = 6, width = 5, knockback = 58, launch = 14, pushTime = 0.24, lunge = { 24, 0.18 }, lungeAtHit = true,
		react = "Knockback", heavy = true, feintable = true, cooldown = 6,
	},
}

-- Custom textures (generated and uploaded to this account).
Config.Textures = {
	impact = "rbxassetid://112690762420519", -- 4x4 flipbook
	parry = "rbxassetid://134662175081926", -- 4x4 flipbook
	smoke = "rbxassetid://90351183951922", -- 4x4 flipbook
	ring = "rbxassetid://130122732510808",
	spark = "rbxassetid://117807430752358",
	glow = "rbxassetid://72017005421515",
	trail = "rbxassetid://118590739472328",
	cleave = "rbxassetid://131518491667388", -- thrown crescent slash
	dismantle = "rbxassetid://130771659688630", -- 4x4 flipbook: a cut flashes in and splits
	slashline = "rbxassetid://138118569985577",
}

-- Slash skill (Y): throws a crescent slash; whoever it catches is held in
-- place and cut apart for `captureTime`, then left kneeling (invincible).
Config.Skill = {
	cooldown = 20,
	release = 0.22, -- slash leaves the hand at this point of the cast
	castTime = 0.55,
	speed = 85,
	range = 30,
	width = 6,
	captureTime = 5,
	tickInterval = 0.2,
	damagePerSecond = 0.05, -- fraction of max health
	kneelTime = 2,
}

Config.Sounds = {
	Swing = { "rbxassetid://93311226362113", "rbxassetid://111254855668531" },
	Hit = { "rbxassetid://96359585058783", "rbxassetid://98642142686121" },
	HeavyHit = { "rbxassetid://137499859855978" },
	Block = { "rbxassetid://9120917438" },
	Parry = { "rbxassetid://5763723309" },
	GuardBreak = { "rbxassetid://9120801590" },
	Feint = { "rbxassetid://111254855668531" },
	Dash = { "rbxassetid://93311226362113", "rbxassetid://111254855668531" },
}

return Config

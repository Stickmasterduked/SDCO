--[[
	All tunable combat values live here. Times are in seconds.
	Attack timing (windup / recovery / total length) is read from the
	animation markers in AnimationData so visuals and hit frames never drift.
]]

local Config = {}

Config.WalkSpeed = 16
Config.SprintSpeed = 26
Config.SprintDoubleTapWindow = 0.3

Config.MaxHealth = 100
Config.MaxPosture = 100

-- M1 chain
Config.ComboResetTime = 1.1
Config.ComboLength = 5 -- 4 punches, 5th is the flourish
Config.InputBufferTime = 0.2

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

-- Dash (Q). Direction follows your movement keys and can be steered mid-dash.
Config.RollCooldown = 1.2
Config.RollCancelCooldown = 0.7
Config.RollCancelWindow = 0.15
Config.RollIFrames = 0.25
Config.RollDuration = 0.34
Config.RollSpeed = 49

Config.AttackWalkSpeed = 13
Config.StunWalkSpeed = 5

-- Engagement: attacks soft-turn you toward the enemy in front of you so
-- trades happen face to face.
Config.AimAssistRange = 13
Config.AimAssistAngle = 70 -- degrees either side of where you're looking
Config.AimAssistTurnRate = 14 -- higher = snappier

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

--[[
	Attack definitions. `anim` is the AnimationData key.
	damage / posture: health and posture dealt. hitstun: stun on a clean hit.
	range / width: hitbox depth and width in studs, in front of the attacker.
	knockback: horizontal push on clean hit. launch: vertical push.
	lunge: forward movement for the attacker {speed, duration} at windup start.
]]
Config.Attacks = {
	PunchRight = {
		anim = "PunchRight", damage = 10, posture = 9, hitstun = 0.4,
		range = 5.8, width = 4.5, knockback = 2.5,
		feintable = true, isM1 = true,
	},
	PunchLeft = {
		anim = "PunchLeft", damage = 10, posture = 9, hitstun = 0.4,
		range = 5.8, width = 4.5, knockback = 2.5,
		feintable = true, isM1 = true,
	},
	AirPunchRight = {
		anim = "PunchRight", damage = 10, posture = 9, hitstun = 0.3,
		range = 6.5, width = 5, height = 9, knockback = 1.5, juggle = true,
		feintable = true, isM1 = true, air = true,
	},
	AirPunchLeft = {
		anim = "PunchLeft", damage = 10, posture = 9, hitstun = 0.3,
		range = 6.5, width = 5, height = 9, knockback = 1.5, juggle = true,
		feintable = true, isM1 = true, air = true,
	},
	Downslam = {
		anim = "Downslam", damage = 10, posture = 16, hitstun = 1.15,
		range = 6.5, width = 5.5, height = 11, knockback = 6, slam = true,
		lunge = { 10, 0.15 }, feintable = true, isM1 = true, air = true, endsCombo = true,
	},
	Flourish = {
		anim = "Flourish", damage = 10, posture = 14, hitstun = 0.8,
		range = 5.5, width = 4.5, knockback = 48, launch = 12, lunge = { 8, 0.15 },
		feintable = true, isM1 = true, endsCombo = true,
	},
	Uppercut = {
		anim = "Uppercut", damage = 10, posture = 12, hitstun = 0.45,
		range = 5.8, width = 4.5, knockback = 1, launch = 60, selfLaunch = 58,
		juggle = true, launcher = true, feintable = true, isM1 = true,
	},
	RunningAttack = {
		anim = "RunningAttack", damage = 10, posture = 13, hitstun = 0.6,
		range = 6, width = 4.5, knockback = 18, lunge = { 34, 0.22 },
		feintable = true, isM1 = true,
	},
	Critical = {
		anim = "Critical", damage = 15, posture = 34, hitstun = 0.9,
		range = 6, width = 5, knockback = 30, lunge = { 20, 0.18 }, lungeAtHit = true,
		feintable = true, cooldown = 6,
	},
}

-- Custom textures (generated and uploaded to this account).
Config.Textures = {
	ui = "rbxassetid://137707197689121", -- health bar + shield atlas
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

-- Where each piece lives in the ui atlas (pixels).
Config.Atlas = {
	BarFrame = { 0, 0, 1024, 192 },
	BarTrough = { 0, 192, 1024, 192 },
	BarFill = { 0, 384, 1024, 192 },
	BarTrail = { 0, 576, 1024, 192 },
	BarTip = { 864, 800, 64, 192 },
	BarSlot = { 96, 832 }, -- fill starts at x=96 and spans 832px
	ShieldFrame = { 0, 768, 256, 256 },
	ShieldFill = { 256, 768, 256, 256 },
	ShieldBroken = { 512, 768, 256, 256 },
}

Config.Sounds = {
	Swing = { "rbxassetid://93311226362113", "rbxassetid://111254855668531" },
	Hit = { "rbxassetid://96359585058783", "rbxassetid://98642142686121" },
	HeavyHit = { "rbxassetid://137499859855978" },
	Block = { "rbxassetid://9120917438" },
	Parry = { "rbxassetid://5763723309" },
	GuardBreak = { "rbxassetid://9120801590" },
	Feint = { "rbxassetid://111254855668531" },
}

return Config

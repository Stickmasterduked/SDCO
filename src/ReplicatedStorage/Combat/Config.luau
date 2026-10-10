--[[
	All tunable combat values live here. Times are in seconds.
	Attack timing (windup / recovery / total length) is read from the
	animation markers in AnimationData so visuals and hit frames never drift.
]]

local Config = {}

-- Movement. Faster than Roblox defaults: battlegrounds pacing.
Config.WalkSpeed = 17
Config.SprintSpeed = 28 -- hold Left Shift
Config.JumpHeight = 7.6

-- Double jump (Space in the air): one per airtime, a flip with a burst of wind.
Config.DoubleJumpVelocity = 48
Config.DoubleJumpWindow = 0.12 -- min time after leaving the ground

Config.MaxHealth = 100
Config.MaxPosture = 100

-- M1 chain: four strikes, the fifth press is the finisher.
Config.ComboResetTime = 1.1
Config.ComboLength = 5
Config.M1ChainEndlag = 0.35 -- pause after a full chain before another M1, for every weapon
Config.M1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" }
Config.AirChain = { "AirM1_1", "AirM1_2", "AirM1_3", "AirM1_4" }
Config.InputBufferTime = 0.22

-- Parry / block
-- Each F press opens a parry window. A successful parry refunds it at once,
-- so you can parry every hit of a string by tapping per hit. A window that
-- catches nothing locks parrying out for ParryWhiffCooldown (holding F still
-- blocks), so mashing F doesn't work.
Config.ParryWindow = 0.9 -- three times the previous 0.3-second window
Config.ParryWindupMultiplier = 1 / 2.5 -- guard-raise animation; detection is already immediate
Config.ParryM1SpeedMultiplier = 1.2 -- successful parry: one accepted M1, any weapon
Config.ParryWhiffCooldown = 0.45
Config.ParriedStun = 0.45 -- the parried attacker can't attack for this long, but can still parry back
-- Blocking or parrying resets your own M1 chain, and after letting go of
-- block you can't M1 for BlockAttackDelay, so block-cancelling a string
-- can't be looped: the target's hitstun runs out first.
Config.BlockAttackDelay = 0.35
Config.BlockCooldown = 0.25 -- after letting go of block/parry before you can again (stops F spam); a held press comes up when it ends
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
Config.RollSpeed = 95 -- peak speed; eases out to ~15 studs total (was 76 / ~12)
Config.AirDashSpeed = 82.5 -- was 66
Config.DashOrbitRange = 16 -- side dashes orbit an opponent this close
Config.DashOrbitMinRange = 4 -- stay in control when right against an opponent

Config.AttackWalkSpeed = 10 -- low, so the strikes' own lunges carry the movement
Config.StunWalkSpeed = 5

-- Engagement: attacks soft-turn you toward the enemy in front of you so
-- trades happen face to face.
Config.AimAssistRange = 14
Config.AimAssistAngle = 70 -- degrees either side of where you're looking
-- How the assist feels: it eases in when you engage and out when you stop.
Config.AimAssist = {
	TurnRate = 9, -- full-strength turn speed (higher = snappier)
	FadeIn = 5, -- how quickly it ramps up (per second, exponential)
	FadeOut = 3, -- how quickly it lets go
	DashFacingTurnRate = 6, -- softly turn the character and camera together
	DashFacingMaxTurnRate = 180, -- maximum degrees per second
	DashCameraInputGrace = 0.08, -- briefly yield while the player turns the camera
	-- Side dash around someone: the camera stays put during the dash, then
	-- eases round to face them (moving the camera yourself cancels it).
	RecenterAfterDash = true, -- false = never turn the camera for you
	RecenterRate = 5, -- how quickly it turns (higher = faster)
	RecenterTime = 0.7, -- gives up after this long
}

-- Air combos (Space + M1 launches, air M1s juggle, the last one slams)
Config.LauncherBuffer = 0.15 -- Space and M1 this close together (either order) = uptilt
Config.LauncherQueue = 0.45 -- Space mid-M1-chain: the next strike within this long is an uptilt
Config.JuggleHover = 0.8 -- target floats this long after each air hit
Config.JuggleHitstun = 0.3 -- short, so a good player can block/dash between hits
Config.AirAttackHover = 0.55 -- attacker floats while comboing
Config.MaxJuggleTime = 3.2
Config.LaunchApexDelay = 0.36
Config.SlamSpeed = 95
-- A downslammed target can't be hit for this long (no ground follow-ups).
-- Downslam itself can't be used again until you've touched the ground.
Config.SlamIFrames = 1.15
Config.DownslamCooldown = 2 -- also needs a ground touch between slams
-- Jump presses that land while you can't jump yet (end of an attack) are
-- kept this long instead of being dropped.
Config.JumpBuffer = 0.35

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

-- Client-side hit detection. A player's client finds its own hits and the
-- server validates each claim: the attack must still be live, the claim
-- can't come before the hit frame (minus a little jitter), and the target
-- must be within the hitbox plus RangeSlack studs on the server's view.
Config.HitClaim = {
	RangeSlack = 4,
	EarlyTolerance = 0.1,
}
-- A new strike may start this long before the last one's recovery ends on
-- the server, so network jitter never eats a combo input.
Config.ChainTolerance = 0.08

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
	pushTime: how long small pushes last (default 0.15); Knockback reactions ease out over hitstun.
	walkSpeed: optional movement speed while attacking (defaults to AttackWalkSpeed).
	lunge: forward movement for the attacker {speed, duration} at windup start.
	react: the hit reaction the target plays (default HitFront / HitBack).
	heavy: bigger hit effects, hit-stop and camera kick.
]]
Config.Attacks = {
	M1_1 = {
		anim = "M1_1", damage = 6, posture = 18, hitstun = 0.35,
		range = 5.8, width = 4.5, knockback = 3, lunge = { 9, 0.1 },
		feintable = true, isM1 = true,
	},
	M1_2 = {
		anim = "M1_2", damage = 6, posture = 18, hitstun = 0.35,
		range = 5.8, width = 5, knockback = 3, lunge = { 8, 0.1 },
		react = "HitFrontB", feintable = true, isM1 = true,
	},
	M1_3 = {
		anim = "M1_3", damage = 6, posture = 20, hitstun = 0.38,
		range = 5.6, width = 4.5, knockback = 3, lunge = { 9, 0.1 },
		react = "HitFrontC", feintable = true, isM1 = true,
	},
	M1_4 = {
		anim = "M1_4", damage = 6, posture = 22, hitstun = 0.42,
		range = 6.2, width = 5.5, knockback = 5, lunge = { 6, 0.12 },
		feintable = true, isM1 = true,
	},
	Finisher = {
		anim = "Finisher", damage = 8, posture = 30, hitstun = 0.65, walkSpeed = Config.WalkSpeed,
		range = 6, width = 5, knockback = 72, launch = 18, lunge = { 17, 0.16 },
		react = "Knockback", heavy = true, feintable = true, isM1 = true, endsCombo = true,
	},
	AirPunch = {
		anim = "AirPunch", damage = 5, posture = 14, hitstun = 0.3,
		range = 6.5, width = 5, height = 9, knockback = 1.5, juggle = true,
		feintable = true, isM1 = true, air = true,
	},
	AirKick = {
		anim = "AirKick", damage = 5, posture = 14, hitstun = 0.3,
		range = 6.5, width = 5.5, height = 9, knockback = 1.5, juggle = true,
		feintable = true, isM1 = true, air = true,
	},
	Downslam = {
		anim = "Downslam", damage = 7, posture = 26, hitstun = 0,
		range = 6.5, width = 5.5, height = 11, knockback = 6, slam = true,
		lunge = { 10, 0.15 }, heavy = true, feintable = true, isM1 = true, air = true, endsCombo = true,
	},
	Uppercut = {
		anim = "Uppercut", damage = 6, posture = 20, hitstun = 0.45,
		range = 5.8, width = 4.5, knockback = 1, launch = 60, selfLaunch = 58,
		heavy = true, juggle = true, launcher = true, feintable = true, isM1 = true,
	},
	Critical = {
		anim = "Critical", damage = 12, posture = 40, hitstun = 0.65,
		range = 6, width = 5, knockback = 58, launch = 14, lunge = { 24, 0.18 }, lungeAtHit = true,
		react = "Knockback", heavy = true, feintable = true, cooldown = 6, readyField = "critReadyAt",
	},
	-- H: a low leg sweep. Knocks them flat for half a second (they can't move),
	-- long enough to start a combo. Everyone has it (set `owners` = { [UserId] = true }
	-- to limit it to certain players again).
	LowSweep = {
		anim = "LowSweep", damage = 6, posture = 24, hitstun = 0.55,
		range = 6.5, width = 6.5, knockback = 2, launch = 6, lunge = { 14, 0.14 },
		react = "Swept", forceReact = true, knockdown = true, heavy = true, feintable = false,
		cooldown = 15, readyField = "sweepReadyAt",
	},
	-- Katana skills (katana drawn only; see Config.KatanaSkills).
	-- Z, Lumen Rush: dash in and cut through. The hit is found by the
	-- attacker's client at the clip's Hit marker like any strike; claimSlack
	-- widens the server's check because the dash outruns its view of you.
	KatanaRush = {
		anim = "Katana_Rush", damage = 14, posture = 35, hitstun = 1.05, walkSpeed = 0,
		range = 8.5, width = 9, height = 7, knockback = 78, launch = 32,
		react = "Knockback", heavy = true, feintable = false, katanaSkill = true,
		cooldown = 12, readyField = "rushReadyAt", claimSlack = 14,
		-- the dash cuts THROUGH them: the hit is anyone the dash path passed
		rush = true,
	},
	-- X, Moonfall Crescent: an overhead cut that launches a travelling slash.
	-- The server flies it and decides the hit (range/width/height are the
	-- crescent's own box, swept along its path).
	KatanaCrescent = {
		anim = "Katana_Crescent", damage = 9, posture = 22, hitstun = 0.7, walkSpeed = 0,
		range = 72, width = 7, height = 17, knockback = 14, launch = 4,
		react = "HitFront", heavy = true, feintable = false, katanaSkill = true,
		cooldown = 15, readyField = "crescentReadyAt", projectile = true,
		-- a cross slash: one crescent per release (clip marker), each its own
		-- hit; anything listed overrides the fields above for that crescent.
		-- tilt: degrees the crescent leans about its travel direction.
		releases = {
			{ marker = "Hit", tilt = 0 },
			{ marker = "Hit2", tilt = -48, damage = 11, posture = 26, hitstun = 1.1, knockback = 88, launch = 30,
				react = "Knockback", width = 12, height = 15 },
		},
	},
}

-- Missing a move with a cooldown (Critical, Low Sweep, Head Drive) only
-- puts it on this cooldown instead of its full one, if that's shorter.
-- Blocked or parried counts as connecting; a whiff or a dodge doesn't.
Config.WhiffCooldown = 8

-- Custom textures (generated and uploaded to this account).
Config.Textures = {
	impact = "rbxassetid://112690762420519", -- 4x4 flipbook
	parry = "rbxassetid://134662175081926", -- 4x4 flipbook
	smoke = "rbxassetid://90351183951922", -- 4x4 flipbook
	ring = "rbxassetid://130122732510808",
	spark = "rbxassetid://117807430752358",
	glow = "rbxassetid://72017005421515",
	trail = "rbxassetid://118590739472328",

	-- Generated with Python (procedural, original) for the impact rework:
	hitImpact = "rbxassetid://89726259190834", -- 4x4 flipbook: core pop, spikes, breaking ring
	parryFlash = "rbxassetid://73575208299325", -- 4x4 flipbook: four-point star, glints, snapping ring
	dust = "rbxassetid://133376856287724", -- 4x4 flipbook: billowing dirt puff
	debris = "rbxassetid://100385672879709", -- 4x4 sheet: 16 rock shards (one per particle)
	shockwave = "rbxassetid://100102775499734", -- flat ring with a soft wake
	groundCracks = "rbxassetid://98197199624999", -- radial fractures, crushed centre
	beamStreak = "rbxassetid://92839688026958", -- tiles along the beam
	sparkStreak = "rbxassetid://137618832773668", -- hot sliver for velocity-aligned sparks
	softGlow = "rbxassetid://134341603170358",
}

-- Head Drive (Y): grab the head, slam it, drag it along the floor, then
-- slam their head down twice. A combo extender: 10% of max health in total
-- (see HeadDrive.DAMAGE), and you're free a beat before they can attack
-- again, though they can block or dash straight away. A held block stops
-- the grab; it can't be parried; dash i-frames slip it.
Config.HeadDrive = {
	cooldown = 19,
	range = 5.5, -- reach of the grab (same hitbox as the strikes)
	width = 4.5,
	height = 6,
	whiffRecover = 0.5, -- a miss leaves you open this long
	dragDistance = 12, -- studs, shortened by walls and drops ahead
	getUpTime = 0.3, -- after it ends: they can block/dash but not attack yet
	-- From the moment the attacker is let go until this long after the victim
	-- is back up, the victim can't be hit, so the grab can't be extended.
	releaseIFrames = 0.6,
	blockPosture = 15, -- posture dealt to a guard that stops the grab
}

-- Katana skills. Both need the katana drawn (E). Keys are KeyCode names.
Config.KatanaSkills = {
	KatanaRush = {
		key = "Z",
		dashDuration = 0.28, -- from the clip's Dash marker
		maxDistance = 30, -- dash length with no one ahead
		minDistance = 10,
		passBy = 6, -- carries on this far past the target (cuts through them)
		bend = { 2.5, 4.5 }, -- the dash bows sideways by this much (random side)
		pathRadius = 5.5, -- how close the dash must pass someone to cut them
		targetRange = 30, -- picks the opponent you're facing within this ...
		targetAngle = 40, -- ... and this many degrees of your aim
		hitStop = 0.2,
	},
	KatanaCrescent = {
		key = "X",
		speed = 92, -- studs/s
		range = 72,
		hitStop = 0.16, -- the victim only; the caster is far away
	},
}

-- Custom sprites for the katana skills, generated by tools/katana/textures.py
-- (assets/katana/*.png). Upload them and paste each image id here
-- ("rbxassetid://123"); empty ones fall back to the textures above.
Config.KatanaTextures = {
	glow = "",
	core = "",
	star = "",
	burst = "",
	prism = "",
	streak = "",
	crescent = "",
	spark = "",
	glint = "",
	ribbonCore = "",
	ribbonFlow = "",
	ribbonSoft = "",
	bladeTrail = "",
	-- round 2 (flipbooks are 4x4)
	explosion = "",
	smoke = "",
	slash = "",
	shock = "",
	spike = "",
	energy = "",
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
	-- katana (Creator Store, free)
	KatanaSwing = { "rbxassetid://110528221841597", "rbxassetid://80030494081806" },
	KatanaDraw = { "rbxassetid://9119742466" },
	KatanaSheathe = { "rbxassetid://9119744718" },
	-- katana skills: each cue is layered and pitched in KatanaFXData. These
	-- reuse the sounds above; swap in dedicated ones here.
	KatanaGather = { "rbxassetid://9119742466" }, -- energy tightening (a bright draw, pitched up)
	KatanaGlint = { "rbxassetid://5763723309" }, -- the glint before the release
	KatanaRushWind = { "rbxassetid://93311226362113", "rbxassetid://111254855668531" }, -- the dash / launch rush
	KatanaCrack = { "rbxassetid://9120801590" }, -- the cutting crack
	KatanaBurst = { "rbxassetid://137499859855978" }, -- the impact burst
	KatanaTail = { "rbxassetid://5763723309" }, -- the fading energy tail (rung low)
}

--[[
	Weapons: a character with the "Weapon" attribute swings that weapon's
	versions of the attacks while it's drawn ("KatanaDrawn", E). Only what differs is listed (reach here); timing,
	damage and stun stay the fists' so combos and balance are unchanged.
]]
-- The katana swings are heavier (longer wind-up and follow-through, see
-- KatanaAnimations WEIGHT), so its hitstun is a little longer too and the
-- strings still combo. Its hits also freeze a bit longer on impact.
Config.KatanaHitStopMult = 1.35
Config.Weapons = {
	Katana = {
		M1_1 = { range = 8, width = 6.5, hitstun = 0.43 },
		M1_2 = { range = 8, width = 6.5, hitstun = 0.43 },
		M1_3 = { range = 8, width = 7.5, hitstun = 0.47 },
		M1_4 = { range = 8.5, width = 5.5, hitstun = 0.52 },
		Finisher = { range = 8.5, width = 8 },
		Uppercut = { range = 7.5, width = 5.5 },
		AirPunch = { range = 8, width = 6.5, hitstun = 0.35 },
		AirKick = { range = 8, width = 7.5, hitstun = 0.35 },
		Downslam = { range = 8, width = 6.5 },
		Critical = { range = 9.5, width = 7 },
	},
}

-- Air strings use the current M1 clips, with the existing air hit rules.
for i, groundKind in ipairs(Config.M1Chain) do
	local airKind = Config.AirChain[i]
	local oldAirKind = i % 2 == 1 and "AirPunch" or "AirKick"
	local airAttack = table.clone(Config.Attacks[oldAirKind])
	airAttack.anim = Config.Attacks[groundKind].anim
	airAttack.react = Config.Attacks[groundKind].react
	Config.Attacks[airKind] = airAttack

	for _, weaponAttacks in pairs(Config.Weapons) do
		if weaponAttacks[oldAirKind] then
			weaponAttacks[airKind] = table.clone(weaponAttacks[oldAirKind])
		end
	end
end

local mergedAttacks = {}
-- Server-authored admin overrides never modify shared attack definitions.
function Config.damageFor(model, defaultDamage)
	local override = model and model:GetAttribute("AdminDamageOverride")
	if typeof(override) == "number" and override == override and override >= 0 and override < math.huge then
		return override
	end
	return defaultDamage
end

local function withAdminDamage(attack, model)
	if not attack then return nil end
	local damage = Config.damageFor(model, attack.damage)
	if damage == attack.damage then return attack end
	local adjusted = table.clone(attack)
	adjusted.damage = damage
	return adjusted
end

function Config.attackFor(kind, model)
	local base = Config.Attacks[kind]
	-- only while it's drawn: sheathed, you're swinging fists
	local weapon = model and model:GetAttribute("KatanaDrawn") == true and model:GetAttribute("Weapon")
	local overrides = weapon and Config.Weapons[weapon] and Config.Weapons[weapon][kind]
	if not base or not overrides then
		return withAdminDamage(base, model)
	end
	local key = weapon .. ":" .. kind
	local merged = mergedAttacks[key]
	if not merged then
		merged = table.clone(base)
		for k, v in pairs(overrides) do
			merged[k] = v
		end
		mergedAttacks[key] = merged
	end
	return withAdminDamage(merged, model)
end

return Config

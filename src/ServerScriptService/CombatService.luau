--[[
	Server-authoritative combat. Every character that can fight (players and
	dummies) is a combatant with one state machine:

	  Idle, Attacking, Blocking, Rolling, Stunned, Parried, GuardBroken,
	  Grabbing / Grabbed (Head Drive), GetUp (just let go of: can block or
	  dash, can't attack yet)

	Juggling is tracked alongside the state: a juggled combatant floats
	(Motion.hover) for a short time after each air hit and is released if
	they block or dash out, the juggle times out, or they get slammed.

	The client sends inputs, and for a player's own strikes also the hit
	itself: its client finds the target at its hit frame (so feedback is
	instant) and CombatService.claimHit validates that claim against the
	server's positions and timing. Damage, posture, parry and block
	resolution all happen here. Dummies are detected on the server.
	Effects carry the attack kind so every client can scale its hit effects,
	hit-stop and camera kick to the move, and the attack id so the attacker
	(who already played them) can skip its own.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatShared = ReplicatedStorage.Combat
local Config = require(CombatShared.Config)
local AnimationData = require(CombatShared.AnimationData)
local Motion = require(CombatShared.Motion)
local Hitbox = require(CombatShared.Hitbox)
local HeadDrive = require(CombatShared.HeadDrive)
local Remotes = CombatShared.Remotes

local FLAT = Vector3.new(1, 0, 1)

local CombatService = {}

local combatants = {}
CombatService.Combatants = combatants

local grabs = {} -- [attacker] = the Head Drive it's performing
local cancelGrab -- defined with Head Drive below

local attackStarted = Instance.new("BindableEvent")
-- (attacker, attackKind, hitTime) - lets dummies react to incoming attacks
CombatService.AttackStarted = attackStarted.Event

local now = os.clock

local function flat(vector)
	return vector * FLAT
end

------------------------------------------------------------------------
-- Replication helpers

local function playAnim(c, name, predicted, stop, speed)
	if c.player and predicted then
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= c.player then
				Remotes.Anim:FireClient(player, c.model, name, stop, speed)
			end
		end
	else
		Remotes.Anim:FireAllClients(c.model, name, stop, speed)
	end
end

local function stopAnim(c, name, predicted)
	playAnim(c, name, predicted, true)
end

-- `info` is the attack kind for hits, or the direction for a dash.
-- `attackId` lets the attacker's client skip effects it already predicted.
local function effect(kind, position, attacker, defender, info, attackId, details)
	Remotes.Effect:FireAllClients(kind, position, attacker and attacker.model, defender and defender.model, info, attackId, details)
end

-- Movement runs where the character's physics lives: the owning client for
-- players, the server for dummies.
local function motion(c, kind, velocity, duration, delay)
	if c.player then
		Remotes.Impulse:FireClient(c.player, kind, velocity or Vector3.zero, duration or 0, delay or 0)
	else
		Motion.apply(c.root, kind, velocity or Vector3.zero, duration or 0, delay or 0)
	end
end

local function push(c, velocity, duration)
	motion(c, "push", velocity, duration)
end

local function dash(c, velocity, duration)
	motion(c, "dash", velocity, duration)
end

local function isAirborne(c)
	return c.humanoid.FloorMaterial == Enum.Material.Air
end

local function stopMotion(c)
	motion(c, "stop")
end

local function hover(c, duration, delay)
	motion(c, "hover", nil, duration, delay)
end

local function stopHover(c)
	motion(c, "stopHover")
end

------------------------------------------------------------------------
-- State

local function walkSpeedFor(c)
	local state = c.state
	if state == "Idle" then
		return c.sprinting and Config.SprintSpeed or Config.WalkSpeed
	elseif state == "Blocking" then
		return Config.BlockWalkSpeed
	elseif state == "Attacking" then
		local attack = c.attack and c.attack.def
		return attack and attack.walkSpeed or Config.AttackWalkSpeed
	elseif state == "Rolling" then
		return Config.WalkSpeed
	elseif state == "GuardBroken" or state == "Grabbing" or state == "Grabbed" then
		return 0
	elseif state == "Stunned" and c.knockedDown then
		return 0 -- swept off their feet
	end
	return Config.StunWalkSpeed
end

local function applyMovement(c)
	c.humanoid.WalkSpeed = walkSpeedFor(c)
	c.humanoid.JumpHeight = (c.state == "Idle") and Config.JumpHeight or 0
end

local function clearStunParry(c)
	if c.stunParry then
		c.stunParry = false
		c.parryUntil = 0
		c.model:SetAttribute("StunParry", false)
	end
end

local function setState(c, state, duration)
	if state ~= "Stunned" then
		clearStunParry(c)
	end
	c.state = state
	c.token += 1
	c.knockedDown = false
	c.model:SetAttribute("CombatState", state)
	applyMovement(c)

	if duration then
		local token = c.token
		task.delay(duration, function()
			if c.token == token then
				setState(c, "Idle")
			end
		end)
	end
	return c.token
end

local function setPosture(c, value)
	c.posture = c.model:GetAttribute("InfinitePosture") == true and 0 or math.clamp(value, 0, c.maxPosture)
	c.model:SetAttribute("Posture", math.floor(c.posture + 0.5))
end

function CombatService.setInfinitePosture(model, enabled)
	local wasEnabled = model:GetAttribute("InfinitePosture") == true
	model:SetAttribute("InfinitePosture", enabled == true)
	local c = combatants[model]
	if c and (enabled or wasEnabled) then
		setPosture(c, 0)
	elseif enabled then
		model:SetAttribute("Posture", 0)
	end
end

-- I-frames (dashes, being downslammed, the end of a Head Drive). Published
-- as server time so attackers' clients don't predict hits that won't land.
local function setIFrames(c, untilTime)
	c.iframesUntil = untilTime
	c.model:SetAttribute("IFramesUntil", workspace:GetServerTimeNow() + math.max(0, untilTime - now()))
end

-- Cooldowns are published as server time so the owner's client shows (and
-- predicts) the real one, including whiff refunds.
local COOLDOWN_ATTRIBUTE = {
	critReadyAt = "CritReady",
	sweepReadyAt = "SweepReady",
	grabReadyAt = "GrabReady",
	rushReadyAt = "RushReady",
	crescentReadyAt = "CrescentReady",
}
local function setCooldown(c, field, readyAt)
	c[field] = readyAt
	local name = COOLDOWN_ATTRIBUTE[field]
	if name then
		c.model:SetAttribute(name, workspace:GetServerTimeNow() + math.max(0, readyAt - now()))
	end
end

-- A successful parry arms one faster M1. Monotonic grant/consume tokens let
-- the owner predict it without a late attribute update restoring a spent
-- charge. Parrying again refreshes the single charge instead of stacking it.
local function grantParryM1(c)
	c.parryM1Token += 1
	c.model:SetAttribute("ParryM1Token", c.parryM1Token)
end

local function attackSpeed(c, attack, inheritedSpeed)
	-- Turning the M1 already in flight into an uptilt retains that strike's
	-- speed; it isn't another M1 press and cannot consume a newer reward.
	if inheritedSpeed then
		return inheritedSpeed
	end
	if attack.isM1 and c.parryM1Token > c.parryM1Consumed then
		c.parryM1Consumed = c.parryM1Token
		c.model:SetAttribute("ParryM1Consumed", c.parryM1Consumed)
		return Config.ParryM1SpeedMultiplier
	end
	return 1
end

-- A move that whiffed goes on the (shorter) whiff cooldown instead.
local function refundWhiff(c, field, started, cooldown)
	local whiffReady = started + math.min(cooldown, Config.WhiffCooldown)
	if c[field] and whiffReady < c[field] then
		setCooldown(c, field, whiffReady)
	end
end

local function isFacing(defender, attacker)
	local toAttacker = flat(attacker.root.Position - defender.root.Position)
	if toAttacker.Magnitude < 0.05 then
		return true
	end
	local look = flat(defender.root.CFrame.LookVector)
	return look.Unit:Dot(toAttacker.Unit) >= Config.FacingDot
end

local function isAlive(c)
	return c.humanoid.Health > 0
end

local function isJuggled(c, t)
	return c.juggledBy ~= nil and (t or now()) < c.juggleUntil
end

local function releaseJuggle(c)
	if c.juggledBy then
		c.juggledBy = nil
		c.juggleUntil = 0
		c.model:SetAttribute("Juggled", false)
		stopHover(c)
	end
end

-- Is `c` currently keeping someone airborne?
local function juggleTargetOf(c, t)
	for _, other in pairs(combatants) do
		if other.juggledBy == c and isJuggled(other, t)
			and (other.root.Position - c.root.Position).Magnitude < 12 then
			return other
		end
	end
	return nil
end

local function groundBelow(c)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	for model in pairs(combatants) do
		table.insert(ignore, model)
	end
	params.FilterDescendantsInstances = ignore
	local result = workspace:Raycast(c.root.Position, Vector3.new(0, -60, 0), params)
	return result and result.Position or (c.root.Position - Vector3.new(0, 3, 0))
end

-- Returns true if the hit killed the target. Death is Roblox's normal death.
local function damage(c, amount)
	if amount <= 0 or not isAlive(c) then
		return false
	end
	c.lastDamaged = now()
	c.humanoid.Health = math.max(0, c.humanoid.Health - amount)
	if not isAlive(c) then
		c.attack = nil
		c.token += 1
		return true
	end
	return false
end

------------------------------------------------------------------------
-- Hits

-- Server-side detection (dummies' strikes).
local function findTarget(c, attack)
	local candidates = {}
	for model, other in pairs(combatants) do
		if other ~= c and isAlive(other) then
			table.insert(candidates, model)
		end
	end
	local model = Hitbox.find(c.root, attack, candidates)
	return model and combatants[model]
end

local function guardBreak(defender, attacker, attack, kind, attackId)
	defender.attack = nil
	defender.combo = 0
	defender.blockReadyAt = now() + Config.GuardBreakStun + Config.BlockCooldown
	releaseJuggle(defender)
	setPosture(defender, 0)
	effect("GuardBreak", defender.root.Position, attacker, defender, kind, attackId)
	if damage(defender, attack.damage * Config.GuardBreakDamageMult) then
		return
	end
	setState(defender, "GuardBroken", Config.GuardBreakStun)
	playAnim(defender, "GuardBreak")
	push(defender, flat(attacker.root.CFrame.LookVector) * 14, 0.15)
end

-- `clientDriven`: the attacker is a player whose client already moved
-- itself (lunges, launcher self-launch) and played the hit effects.
-- `source` (optional) is where the hit came from when that isn't the
-- attacker's body (Moonfall Crescent): { contact, direction }. Facing,
-- knockback and the contact point use it, and a parry deflects it without
-- recoiling an attacker who is far away.
local function resolveHit(attacker, defender, attack, kind, attackId, clientDriven, source)
	local t = now()
	if not isAlive(defender) then
		return
	end
	if t < defender.iframesUntil then
		effect("Dodge", defender.root.Position, attacker, defender, kind, attackId)
		return
	end
	-- Held in someone's Head Drive: extra hits still hurt but don't free them.
	if defender.state == "Grabbed" then
		effect("Hit", defender.root.Position + Vector3.new(0, 0.6, 0), attacker, defender, kind, attackId)
		damage(defender, attack.damage)
		return
	end
	-- Hitting someone mid-Head-Drive knocks them off it (their victim is let go).
	if defender.grab and defender.state == "Grabbing" then
		cancelGrab(defender.grab)
	end

	local contact = defender.root.Position:Lerp(attacker.root.Position, 0.4) + Vector3.new(0, 0.6, 0)
	local facing = isFacing(defender, attacker)
	if source then
		contact = source.contact
		local look = flat(defender.root.CFrame.LookVector)
		facing = look.Magnitude < 0.05 or look.Unit:Dot(-source.direction) >= Config.FacingDot
	end
	local stunParry = defender.state == "Stunned" and defender.stunParry and not defender.knockedDown
	local stunnable = defender.state ~= "GuardBroken" and defender.state ~= "Parried"
		and (defender.state ~= "Stunned" or stunParry)

	-- Parry: negates everything, refunds the parry, recovers posture, recoils the attacker.
	if facing and t <= defender.parryUntil and stunnable then
		defender.parryUntil = 0
		defender.parryReadyAt = 0
		if stunParry then
			defender.nextActionAt = t
			setState(defender, "Idle")
			if defender.stunAnim then
				stopAnim(defender, defender.stunAnim)
				defender.stunAnim = nil
			end
		end
		grantParryM1(defender)
		setPosture(defender, defender.posture - Config.ParryPostureRecover)

		if source then
			-- a deflected projectile: the caster is far away and keeps going
			playAnim(defender, "BlockImpact")
			effect("Parry", contact, attacker, defender, kind, attackId, {
				parryM1Token = defender.parryM1Token,
				parryM1Consumed = defender.parryM1Consumed,
				stunParry = stunParry == true,
			})
			return
		end

		attacker.attack = nil
		attacker.combo = 0
		attacker.model:SetAttribute("Combo", 0)
		-- Can't attack again for a moment, but can still parry the counter:
		-- that's what makes parry trading possible.
		attacker.nextActionAt = t + Config.ParriedStun
		setState(attacker, "Parried", Config.ParriedStun)
		stopMotion(attacker)
		playAnim(attacker, "Parried")
		playAnim(defender, "BlockImpact")
		effect("Parry", contact, attacker, defender, kind, attackId, {
			parryM1Token = defender.parryM1Token,
			parryM1Consumed = defender.parryM1Consumed,
			stunParry = stunParry == true,
		})
		if not isJuggled(defender, t) then
			stopHover(attacker)
		end
		return
	end

	-- Block: chip damage and posture. Overflowing posture guard breaks.
	if facing and defender.state == "Blocking" then
		local shaky = t - defender.blockStart < Config.ShakyBlockTime
		local postureDamage = attack.posture * (shaky and Config.ShakyPostureMult or 1)
		defender.lastPostureGain = t

		if defender.model:GetAttribute("InfinitePosture") ~= true and defender.posture + postureDamage >= defender.maxPosture then
			guardBreak(defender, attacker, attack, kind, attackId)
			return
		end

		setPosture(defender, defender.posture + postureDamage)
		-- Blocking absorbs the hit, but the attacker still advances through
		-- the string instead of replaying the first (right-hook) strike.
		effect("Block", contact, attacker, defender, kind, attackId)
		playAnim(defender, "BlockImpact")
		push(defender, (source and source.direction or flat(attacker.root.CFrame.LookVector)) * 2.5, 0.08)
		damage(defender, attack.damage * Config.ChipDamage)
		return
	end

	-- Clean hit: damage, interrupt, hitstun, knockback.
	clearStunParry(defender)
	local heavy = attack.heavy or attack.knockback >= 18 or attack.launcher or attack.slam
	effect(heavy and "HeavyHit" or "Hit", contact, attacker, defender, kind, attackId)
	defender.lastCleanHit = { by = attacker, at = t }
	if damage(defender, attack.damage) then
		releaseJuggle(defender)
		return
	end

	-- A guard-broken target takes free hits without its stun being shortened.
	if defender.state == "GuardBroken" and not attack.launcher and not attack.slam then
		push(defender, flat(attacker.root.CFrame.LookVector) * 2, 0.1)
		return
	end

	defender.attack = nil
	defender.combo = 0
	defender.sprinting = false
	if defender.state == "Rolling" then
		stopMotion(defender)
	end

	local direction = source and source.direction or flat(attacker.root.CFrame.LookVector)

	if attack.slam then
		-- Spiked into the ground, but free to act immediately.
		releaseJuggle(defender)
		defender.nextActionAt = t
		defender.parryUntil = 0
		setState(defender, "Idle")
		-- no ground follow-ups on someone you've just spiked
		setIFrames(defender, t + Config.SlamIFrames)
		playAnim(defender, "Slammed")
		local ground = groundBelow(defender)
		local fall = math.max(0, defender.root.Position.Y - ground.Y - 3)
		push(defender, direction * attack.knockback + Vector3.new(0, -Config.SlamSpeed, 0), 0.12)
		task.delay(math.min(0.35, fall / Config.SlamSpeed), function()
			effect("Slam", groundBelow(defender), attacker, defender, kind)
		end)
		return
	end

	setState(defender, "Stunned", attack.hitstun)
	if attack.knockdown then
		defender.knockedDown = true
		applyMovement(defender)
	end
	local react
	if attack.react == "Knockback" or attack.forceReact then
		react = "Knockback"
	elseif not facing then
		react = "HitBack"
	else
		react = attack.react or "HitFront"
	end
	defender.stunAnim = react
	playAnim(defender, react)

	if attack.juggle then
		-- Launch (or keep) them in the air for a follow-up.
		local first = not isJuggled(defender, t)
		if first then
			defender.juggleStart = t
		end
		if t - defender.juggleStart < Config.MaxJuggleTime then
			defender.juggledBy = attacker
			defender.juggleUntil = t + Config.JuggleHover + (attack.launcher and Config.LaunchApexDelay or 0)
			defender.model:SetAttribute("Juggled", true)
			local apex = attack.launcher and Config.LaunchApexDelay or 0
			push(defender, direction * attack.knockback + Vector3.new(0, attack.launch or 0, 0), 0.12)
			hover(defender, Config.JuggleHover, apex)
			if attack.selfLaunch and not clientDriven then
				push(attacker, Vector3.new(0, attack.selfLaunch, 0), 0)
				hover(attacker, Config.AirAttackHover, apex)
			end
			return
		end
		releaseJuggle(defender)
	end

	local velocity = direction * attack.knockback + Vector3.new(0, attack.launch or 0, 0)
	if attack.react == "Knockback" then
		motion(defender, "knockback", velocity, attack.hitstun)
	else
		push(defender, velocity, attack.pushTime or 0.15)
	end
end

------------------------------------------------------------------------
-- Lumen Rush's hit and miss (the rest of the skill code is further down)

-- a share of the victim's max health (admin overrides still win)
local function shareOf(attacker, victim, fraction)
	return Config.damageFor(attacker.model, victim.humanoid.MaxHealth * fraction)
end

-- The dash's cut: it holds them for the follow-up instead of knocking back.
local function rushCut(c, target, attack)
	local def = table.clone(attack)
	def.damage = shareOf(c, target, Config.KatanaSkills.KatanaRush.cutFraction)
	def.knockback, def.launch, def.hitstun, def.react = 0, 0, 1.0, "HitFront"
	return def
end

-- A whiffed Z: the swing carries you into a guard break.
local function rushStagger(c)
	local S = Config.KatanaSkills.KatanaRush
	c.attack = nil
	c.combo = 0
	c.blockReadyAt = now() + S.staggerOnMiss + Config.BlockCooldown
	stopMotion(c)
	setState(c, "GuardBroken", S.staggerOnMiss)
	playAnim(c, "GuardBreak")
	effect("GuardBreak", c.root.Position, c, c, "KatanaRushStagger")
end

local rushFollow -- defined with the katana skills below

-- `attackId` is the client's input sequence number for a player's strike;
-- with it, that client reports the hit itself (see claimHit).
local function startAttack(c, kind, predicted, attackId, inheritedSpeed)
	local attack = Config.Attacks[kind]
	local speed = attackSpeed(c, attack, inheritedSpeed)
	-- the katana's (heavier) clip has its own timing while it's drawn
	local animName = attack.anim
	if c.model:GetAttribute("Weapon") == "Katana" and c.model:GetAttribute("KatanaDrawn") == true
		and AnimationData["Katana_" .. animName] and AnimationData["Katana_" .. animName].markers then
		animName = "Katana_" .. animName
	end
	local anim = AnimationData[animName]
	local hitDelay = anim.markers.Hit / speed
	local recover = anim.recover / speed
	local t = now()
	local clientDriven = c.player ~= nil and predicted and attackId ~= nil

	local a = { kind = kind, def = attack, started = t, hitAt = t + hitDelay, id = attackId, clientDriven = clientDriven, speed = speed }
	c.attack = a
	local token = setState(c, "Attacking")
	c.nextActionAt = t + recover

	-- moves with a cooldown: a whiff only costs the whiff cooldown
	if attack.cooldown and attack.readyField then
		task.delay(recover + 0.05, function()
			if not a.contact then
				refundWhiff(c, attack.readyField, a.started, attack.cooldown)
			end
		end)
	end

	playAnim(c, attack.anim, predicted, nil, speed)
	attackStarted:Fire(c, kind, c.attack.hitAt)

	-- Stay up with the target while air comboing; a slam drops you with them.
	if attack.air and not attack.slam and juggleTargetOf(c, t) then
		hover(c, Config.AirAttackHover)
	elseif attack.slam then
		stopHover(c)
	end

	-- Lumen Rush: a miss (nobody cut, or they dashed through it) staggers you
	if attack.rush then
		task.delay(hitDelay + 0.4, function()
			if c.token == token and c.attack == a and not a.contact and isAlive(c) then
				rushStagger(c)
			end
		end)
	end

	if clientDriven then
		-- The attacker's client lunges, finds the hit and reports it; here we
		-- only end the strike on time.
		task.delay(recover, function()
			if c.token == token then
				c.attack = nil
				setState(c, "Idle")
			end
		end)
		return speed
	end

	if attack.lunge and not attack.lungeAtHit then
		push(c, flat(c.root.CFrame.LookVector) * attack.lunge[1], attack.lunge[2])
	end
	if attack.rush and anim.markers.Dash then
		task.delay(anim.markers.Dash / speed, function()
			if c.token == token and isAlive(c) then
				local S = Config.KatanaSkills.KatanaRush
				local look = flat(c.root.CFrame.LookVector).Unit
				local bend = math.random(S.bend[1] * 10, S.bend[2] * 10) / 10 * (math.random() < 0.5 and -1 or 1)
				Motion.rush(c.root, look * CombatService.rushDistance(c), S.dashDuration / speed, bend)
			end
		end)
	end

	task.delay(hitDelay, function()
		if c.token ~= token then
			return
		end
		if attack.lunge and attack.lungeAtHit then
			push(c, flat(c.root.CFrame.LookVector) * attack.lunge[1], attack.lunge[2])
		end

		local target = findTarget(c, attack)
		if target then
			a.contact = true
			if attack.rush then
				local before = now()
				resolveHit(c, target, rushCut(c, target, attack), kind)
				if target.lastCleanHit and target.lastCleanHit.by == c and target.lastCleanHit.at >= before then
					rushFollow(c, target)
					return
				end
			else
				resolveHit(c, target, attack, kind)
			end
		end
		if c.token ~= token then
			return
		end

		task.delay(recover - hitDelay, function()
			if c.token == token then
				c.attack = nil
				setState(c, "Idle")
			end
		end)
	end)
	return speed
end

------------------------------------------------------------------------
-- Actions. Each returns (accepted, animationName).

local function canStartAction(c, t)
	if t <= c.parryUntil then
		return false
	end
	if c.state == "Idle" then
		return t >= c.nextActionAt
	end
	-- chaining: the next strike may come in a hair before this one's recovery
	-- ends here, so jitter on the way to the server never drops a combo input
	return c.state == "Attacking" and c.attack ~= nil and t >= c.nextActionAt - Config.ChainTolerance
end

-- A player's client reporting that its current strike hit `targetModel`
-- (for Head Drive, that its hand closed on them, from `startCF`).
function CombatService.claimHit(c, attackId, targetModel, startCF)
	local a = c.attack
	if not a or not a.clientDriven or a.id ~= attackId or a.resolved then
		-- if this was a grab the client is already playing, tell it to stop
		Remotes.Grab:FireClient(c.player, "deny", attackId)
		return false
	end
	local target = combatants[targetModel]
	if a.kind == "HeadDrive" then
		a.resolved = true
		local H = Config.HeadDrive
		if not target or target == c or not isAlive(target) or not isAlive(c)
			or now() < a.hitAt - Config.HitClaim.EarlyTolerance
			or not Hitbox.plausible(c.root, target.root, H, Config.HitClaim.RangeSlack) then
			Remotes.Grab:FireClient(c.player, "deny", attackId)
			return false
		end
		return CombatService.resolveGrab(c, target, startCF, attackId)
	end
	local attack = Config.attackFor(a.kind, c.model)
	if not attack or not target or target == c or not isAlive(target) or not isAlive(c) then
		return false
	end
	if now() < a.hitAt - Config.HitClaim.EarlyTolerance then
		return false
	end
	local slack = Config.HitClaim.RangeSlack + (attack.claimSlack or 0)
	if attack.rush then
		-- the dash cut through them and carried on: any side, close enough
		local offset = target.root.Position - c.root.Position
		if (offset * FLAT).Magnitude > attack.range + slack or math.abs(offset.Y) > 8 then
			return false
		end
	elseif not Hitbox.plausible(c.root, target.root, attack, slack) then
		return false
	end
	a.resolved = true
	-- connected (a dodge through i-frames still counts as a whiff)
	if now() >= target.iframesUntil then
		a.contact = true
	end
	if attack.rush then
		local before = now()
		resolveHit(c, target, rushCut(c, target, attack), a.kind, attackId, true)
		if target.lastCleanHit and target.lastCleanHit.by == c and target.lastCleanHit.at >= before then
			rushFollow(c, target)
		end
		return true
	end
	resolveHit(c, target, attack, a.kind, attackId, true)
	return true
end

-- After your hit frame you can cancel the rest of the swing into a block,
-- parry or dash, so one attack doesn't lock you out of everything else.
local function inRecovery(c, t)
	return c.state == "Attacking" and c.attack ~= nil and t > c.attack.hitAt
end

local function cancelRecovery(c, t)
	c.attack = nil
	c.nextActionAt = t
end

function CombatService.m1(c, options, predicted, attackId)
	local t = now()
	if t < c.m1ReadyAt or not canStartAction(c, t) then
		return false
	end

	if t - c.lastM1 > Config.ComboResetTime then
		c.combo = 0
	end

	local airborne = options.airborne or c.humanoid.FloorMaterial == Enum.Material.Air
	-- an uptilt comes out of the jump's first instant (the client cancels the
	-- hop), so a launcher press counts as the ground
	if options.launcher and not options.airborne then
		airborne = false
	end
	if not airborne then
		c.slamLocked = false
	end

	local kind
	if airborne then
		-- In the air: keep juggling, and the last hit (or a lone jump attack) slams.
		if juggleTargetOf(c, t) and c.combo + 1 < Config.ComboLength then
			kind = Config.AirChain[c.combo % #Config.AirChain + 1]
		else
			-- one downslam per airtime
			if c.slamLocked or t < c.downslamReadyAt - Config.ChainTolerance then
				return false
			end
			kind = "Downslam"
			c.slamLocked = true
			c.downslamReadyAt = t + Config.DownslamCooldown
		end
	elseif c.combo + 1 >= Config.ComboLength then
		-- the fifth hit is always the finisher, even with Space held, so an
		-- uptilt can't extend a full string into an air combo
		kind = "Finisher"
	elseif options.launcher then
		kind = "Uppercut"
	else
		kind = Config.M1Chain[c.combo % #Config.M1Chain + 1]
	end

	c.combo += 1
	if Config.Attacks[kind].endsCombo then
		c.combo = 0
	end
	c.lastM1 = t
	c.sprinting = false
	c.model:SetAttribute("Combo", c.combo)
	c.model:SetAttribute("ComboExpires", workspace:GetServerTimeNow() + Config.ComboResetTime)

	local speed = startAttack(c, kind, predicted, attackId)
	if kind == "Finisher" then
		c.m1ReadyAt = c.nextActionAt + Config.M1ChainEndlag
	end
	return true, Config.Attacks[kind].anim, speed
end

-- M1 then Space a beat later: the ground strike that just started becomes
-- an uptilt (before its hit frame). Takes the same slot in the combo.
function CombatService.launch(c, predicted, attackId)
	local t = now()
	local a = c.attack
	if c.state ~= "Attacking" or not a or a.resolved or t >= a.hitAt then
		return false
	end
	local def = a.def
	if not def.isM1 or def.air or a.kind == "Finisher" or a.kind == "Uppercut" then
		return false
	end
	if t - a.started > Config.LauncherBuffer / a.speed + Config.ChainTolerance then
		return false
	end
	local speed = startAttack(c, "Uppercut", predicted, attackId, a.speed)
	return true, "Uppercut", speed
end

function CombatService.critical(c, predicted, attackId)
	local t = now()
	if not canStartAction(c, t) or t < c.critReadyAt then
		return false
	end
	setCooldown(c, "critReadyAt", t + Config.Attacks.Critical.cooldown)
	c.sprinting = false
	startAttack(c, "Critical", predicted, attackId)
	return true, "Critical"
end

-- H: Low Sweep. Everyone, unless Config lists `owners`.
function CombatService.canLowSweep(c)
	local owners = Config.Attacks.LowSweep.owners
	return c.player ~= nil and (owners == nil or owners[c.player.UserId] == true)
end

function CombatService.lowSweep(c, predicted, attackId)
	local t = now()
	if not CombatService.canLowSweep(c) or not canStartAction(c, t) or t < c.sweepReadyAt then
		return false
	end
	setCooldown(c, "sweepReadyAt", t + Config.Attacks.LowSweep.cooldown)
	c.sprinting = false
	startAttack(c, "LowSweep", predicted, attackId)
	return true, "LowSweep"
end

function CombatService.feint(c, predicted)
	local t = now()

	if c.state == "Attacking" and c.attack then
		if not c.attack.def.feintable or t < c.feintReadyAt or t > c.attack.hitAt - Config.FeintLockout / c.attack.speed then
			return false
		end
		c.feintReadyAt = t + Config.FeintCooldown
		c.attack = nil
		c.nextActionAt = t + 0.1
		setState(c, "Idle")
		stopMotion(c)
		playAnim(c, "Feint", predicted)
		effect("Feint", c.root.Position, c)
		return true, "Feint"
	end

	if c.state == "Rolling" and t - c.rollStarted <= Config.RollCancelWindow then
		setIFrames(c, 0)
		c.rollReadyAt = t + Config.RollCancelCooldown
		setState(c, "Idle")
		stopMotion(c)
		playAnim(c, "Feint", predicted)
		return true, "Feint"
	end

	return false
end

function CombatService.blockDown(c, resume, predicted, parryOnly)
	local t = now()
	if t < c.blockReadyAt or c.stunParryHeld or (parryOnly and c.state ~= "Stunned") then
		return false
	end
	-- A fresh press during ordinary hitstun can only try a timed parry.
	-- Keep the stun and its recovery timer; a held guard never opens here.
	if c.state == "Stunned" then
		if resume or c.knockedDown or t < c.parryReadyAt then
			return false
		end
		c.parryUntil = t + Config.ParryWindow
		c.parryReadyAt = c.parryUntil + Config.ParryWhiffCooldown
		c.stunParry = true
		c.stunParryHeld = true
		c.model:SetAttribute("StunParry", true)
		local untilTime = c.parryUntil
		task.delay(Config.ParryWindow, function()
			if c.stunParry and c.parryUntil == untilTime then
				clearStunParry(c)
			end
		end)
		return true
	end
	if c.state == "Rolling" then
		setIFrames(c, 0)
	elseif inRecovery(c, t) then
		cancelRecovery(c, t)
	elseif c.state ~= "Idle" and c.state ~= "Parried" and c.state ~= "GetUp" then
		return false
	end

	-- Guarding mid-juggle is how you get out of an air combo.
	if isJuggled(c, t) then
		releaseJuggle(c)
	end

	-- Pressing F opens the parry window; keeping it held is a normal block.
	-- Both use the same block pose, so a parry is purely about timing.
	-- (a successful parry clears parryReadyAt, so the next press is live at once)
	if not resume and t >= c.parryReadyAt then
		c.parryUntil = t + Config.ParryWindow
		c.parryReadyAt = t + Config.ParryWindow + Config.ParryWhiffCooldown
	end

	c.sprinting = false
	c.blockStart = t
	-- guarding (or parrying) ends your own string: no block-cancel loops
	c.combo = 0
	c.model:SetAttribute("Combo", 0)
	setState(c, "Blocking")
	playAnim(c, "Block", predicted)
	return true, "Block"
end

function CombatService.blockUp(c, predicted)
	c.stunParryHeld = false -- releasing F permits a new press, without cancelling its timed parry
	if c.state == "Blocking" then
		c.blockReadyAt = now() + Config.BlockCooldown
		c.nextActionAt = math.max(c.nextActionAt, now() + Config.BlockAttackDelay - Config.ChainTolerance)
		setState(c, "Idle")
		stopAnim(c, "Block", predicted)
	end
	return true
end

-- Picks the dash clip from the dash direction relative to facing.
function CombatService.dashAnim(root, direction, airborne)
	if airborne then
		return "DashAir"
	end
	local relative = root.CFrame:VectorToObjectSpace(direction)
	if relative.Z < -0.5 then
		return "DashForward"
	elseif relative.Z > 0.5 then
		return "DashBack"
	elseif relative.X < 0 then
		return "DashLeft"
	end
	return "DashRight"
end

function CombatService.roll(c, direction, predicted, airborne)
	local t = now()
	if t < c.rollReadyAt then
		return false
	end
	if inRecovery(c, t) then
		cancelRecovery(c, t)
	elseif c.state ~= "Idle" and c.state ~= "Blocking" and c.state ~= "GetUp" then
		return false
	end

	local look = flat(c.root.CFrame.LookVector).Unit
	local move = typeof(direction) == "Vector3" and flat(direction) or Vector3.zero
	local dir = move.Magnitude > 0.1 and move.Unit or look

	-- Players' physics runs on their client, so its grounded check is the
	-- accurate one; dummies are simulated here.
	if c.player then
		airborne = airborne == true
	else
		airborne = isAirborne(c)
	end
	local anim = CombatService.dashAnim(c.root, dir, airborne)

	c.rollReadyAt = t + Config.RollCooldown
	setIFrames(c, t + Config.RollIFrames)
	c.rollStarted = t
	c.sprinting = false
	if c.state == "Blocking" then
		c.blockReadyAt = t + Config.BlockCooldown
	end
	releaseJuggle(c)
	if not juggleTargetOf(c, t) then
		stopHover(c)
	end
	setState(c, "Rolling", Config.RollDuration)
	playAnim(c, anim, predicted)
	-- a player's own client already started the dash when the key went down
	if not (c.player and predicted) then
		dash(c, dir * (airborne and Config.AirDashSpeed or Config.RollSpeed), Config.RollDuration * 0.9)
		if airborne then
			hover(c, Config.RollDuration * 0.9)
		end
	end
	effect("Dash", c.root.Position, c, nil, dir)
	return true, anim
end

-- Second jump in the air. The jump itself is physics on the owning client;
-- this only validates it and shows the flip to everyone else.
function CombatService.doubleJump(c, predicted)
	local t = now()
	if c.state ~= "Idle" or t < c.doubleJumpReadyAt then
		return false
	end
	c.doubleJumpReadyAt = t + 0.35
	playAnim(c, "DoubleJump", predicted)
	effect("DoubleJump", c.root.Position, c)
	return true, "DoubleJump"
end

-- E toggles the fists. Players start unequipped (relaxed idle); dummies are
-- always equipped. Attacking or blocking equips automatically (silently: the
-- strike's own animation covers it). Unequipping only from Idle.
function CombatService.setEquipped(c, on, predicted, silent)
	on = on == true
	if c.equipped == on then
		return true
	end
	if not on and c.state ~= "Idle" then
		return false
	end
	c.equipped = on
	c.model:SetAttribute("Equipped", on)
	if silent then
		return true
	end
	local anim = on and "EquipIn" or "EquipOut"
	playAnim(c, anim, predicted)
	return true, anim
end

-- E with a katana: draw it / put it away (players only). Sheathed, you fight
-- with your fists. Only from Idle.
function CombatService.setKatana(c, on, predicted)
	on = on == true
	if c.katanaDrawn == on then
		return true
	end
	if c.state ~= "Idle" or c.model:GetAttribute("Weapon") ~= "Katana" then
		return false
	end
	c.katanaDrawn = on
	c.model:SetAttribute("KatanaDrawn", on)
	if on and not c.equipped then
		c.equipped = true
		c.model:SetAttribute("Equipped", true)
	end
	local anim = on and "Katana_EquipIn" or "Katana_EquipOut"
	playAnim(c, anim, predicted)
	return true, anim
end

function CombatService.setSprint(c, on)
	c.sprinting = on == true and c.state == "Idle"
	applyMovement(c)
	return true
end

------------------------------------------------------------------------
-- Katana skills (katana drawn): Z Lumen Rush, X Moonfall Crescent.

local function katanaReady(c)
	return c.katanaDrawn == true and c.model:GetAttribute("Weapon") == "Katana"
end

-- How far Lumen Rush dashes: through the opponent in front and out past
-- them, or the full length with nobody there. Players' clients
-- decide this themselves; this is for dummies.
function CombatService.rushDistance(c)
	local S = Config.KatanaSkills.KatanaRush
	local look = flat(c.root.CFrame.LookVector)
	look = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
	local cosLimit = math.cos(math.rad(S.targetAngle))
	local best
	for _, other in pairs(combatants) do
		if other ~= c and isAlive(other) then
			local offset = flat(other.root.Position - c.root.Position)
			local distance = offset.Magnitude
			if distance > 0.1 and distance <= S.targetRange and look:Dot(offset.Unit) >= cosLimit then
				if not best or distance < best then
					best = distance
				end
			end
		end
	end
	if best then
		return math.clamp(best + S.passBy, S.minDistance, S.maxDistance)
	end
	return S.maxDistance
end

-- The follow-up after the dash's cut lands: three more cuts, then the
-- explosion that launches them. Everyone plays Katana_RushFollow (the
-- owner's client moves its own body to each cut; dummies are moved here).
rushFollow = function(c, victim)
	local S = Config.KatanaSkills.KatanaRush
	local base = Config.Attacks.KatanaRush
	local clip = AnimationData.Katana_RushFollow
	local m = clip.markers
	local t = now()
	local a = { kind = "KatanaRushFollow", def = { feintable = false, walkSpeed = 0 }, started = t, hitAt = t + m.Boom, speed = 1, contact = true }
	c.attack = a
	local token = setState(c, "Attacking")
	c.nextActionAt = t + clip.recover
	playAnim(c, "Katana_RushFollow")
	local cuts = { { m.Cut1, "HitFront" }, { m.Cut2, "HitFrontB" }, { m.Cut3, "HitFrontC" } }
	for i, cut in ipairs(cuts) do
		task.delay(cut[1], function()
			if c.token ~= token or not isAlive(c) or not isAlive(victim) then
				return
			end
			if not c.player then
				-- dummies blink to the cut themselves
				local around = flat(c.root.Position - victim.root.Position)
				around = around.Magnitude > 0.1 and around.Unit or Vector3.xAxis
				local angle = math.rad(S.blinkAngles[i] or 0)
				local dir = CFrame.Angles(0, angle, 0):VectorToWorldSpace(around)
				local at = victim.root.Position + dir * S.blinkRadius
				c.root.CFrame = CFrame.lookAt(at, Vector3.new(victim.root.Position.X, at.Y, victim.root.Position.Z))
			end
			local def = table.clone(base)
			def.damage = shareOf(c, victim, S.cutFraction)
			def.knockback, def.launch, def.hitstun, def.react = 0, 0, 0.7, cut[2]
			resolveHit(c, victim, def, "KatanaRushCut")
		end)
	end
	task.delay(m.Boom, function()
		if c.token ~= token or not isAlive(c) or not isAlive(victim) then
			return
		end
		local def = table.clone(base)
		def.damage = shareOf(c, victim, S.boomFraction)
		def.knockback, def.launch, def.hitstun, def.react = 78, 32, 1.05, "Knockback"
		resolveHit(c, victim, def, "KatanaRushBoom", nil, false, {
			contact = victim.root.Position,
			direction = (function()
				local d = flat(victim.root.Position - c.root.Position)
				return d.Magnitude > 0.1 and d.Unit or flat(c.root.CFrame.LookVector).Unit
			end)(),
		})
	end)
	task.delay(clip.recover, function()
		if c.token == token then
			c.attack = nil
			setState(c, "Idle")
		end
	end)
end

function CombatService.katanaRush(c, predicted, attackId)
	local t = now()
	if not katanaReady(c) or not canStartAction(c, t) or t < c.rushReadyAt then
		return false
	end
	setCooldown(c, "rushReadyAt", t + Config.Attacks.KatanaRush.cooldown)
	c.sprinting = false
	startAttack(c, "KatanaRush", predicted, attackId)
	return true, Config.Attacks.KatanaRush.anim
end

-- The travelling crescent, flown here: a box swept along its path each
-- frame; the first fighter inside it is hit, walls stop it.
local function flyCrescent(c, attack, a, onEnd)
	local S = Config.KatanaSkills.KatanaCrescent
	local direction = flat(c.root.CFrame.LookVector)
	direction = direction.Magnitude > 0.01 and direction.Unit or Vector3.new(0, 0, -1)
	local origin = c.root.Position + direction * 3 -- the chord, at the attacker's centre height
	-- the bulge leads the chord by a few studs: that's the edge that cuts
	local LEAD = 4.5
	local wallParams = RaycastParams.new()
	wallParams.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	for model in pairs(combatants) do
		table.insert(ignore, model)
	end
	local fx = workspace:FindFirstChild("CombatFX")
	if fx then
		table.insert(ignore, fx)
	end
	wallParams.FilterDescendantsInstances = ignore
	local hitBox = OverlapParams.new()
	hitBox.FilterType = Enum.RaycastFilterType.Include
	local passed = {} -- dashed through it: it carries on past them

	-- every explosion catches everyone close (not the caster, not whoever
	-- the crescent itself already hit)
	local function blast(point, skip)
		for _, other in pairs(combatants) do
			if other ~= c and other ~= skip and isAlive(other) and now() >= other.iframesUntil then
				local offset = flat(other.root.Position - point)
				if offset.Magnitude <= S.blastRadius and math.abs(other.root.Position.Y - point.Y) <= S.blastRadius then
					local def = table.clone(attack)
					def.damage = shareOf(c, other, S.damageFraction)
					def.knockback, def.launch, def.hitstun, def.react = 40, 16, 0.8, "Knockback"
					a.contact = true
					resolveHit(c, other, def, "KatanaCrescentBlast", nil, false, {
						contact = other.root.Position,
						direction = offset.Magnitude > 0.1 and offset.Unit or direction,
					})
				end
			end
		end
	end

	local travelled = 0
	local last = now()
	local connection
	local function finish(hitSomeone)
		connection:Disconnect()
		if not hitSomeone then
			-- out of range or into a wall: it still explodes there
			blast(origin + direction * (travelled + LEAD * 0.5) + Vector3.new(0, -2, 0))
		end
		onEnd()
	end
	connection = RunService.Heartbeat:Connect(function()
		local t = now()
		local step = math.min(S.speed * (t - last), 12)
		last = t
		local from = travelled
		travelled = math.min(S.range, travelled + step)
		-- walls (raised a little so floor bumps don't stop it)
		local probeFrom = origin + direction * from + Vector3.new(0, 1.5, 0)
		local wall = workspace:Raycast(probeFrom, direction * (travelled - from + LEAD), wallParams)
		if wall then
			finish()
			return
		end
		local candidates = {}
		for model, other in pairs(combatants) do
			if other ~= c and isAlive(other) and not passed[other] then
				table.insert(candidates, model)
			end
		end
		if #candidates > 0 then
			hitBox.FilterDescendantsInstances = candidates
			local depth = travelled - from + LEAD
			local centre = origin + direction * (from + depth / 2) + Vector3.new(0, attack.height / 2 - 3, 0)
			local parts = workspace:GetPartBoundsInBox(CFrame.lookAlong(centre, direction), Vector3.new(attack.width, attack.height, depth), hitBox)
			local victim, bestAlong
			for _, part in ipairs(parts) do
				local other = combatants[part.Parent]
				if other and other ~= c and isAlive(other) then
					local along = (other.root.Position - origin):Dot(direction)
					if not bestAlong or along < bestAlong then
						victim, bestAlong = other, along
					end
				end
			end
			if victim then
				local tt = now()
				if tt < victim.iframesUntil then
					effect("Dodge", victim.root.Position, c, victim, "KatanaCrescent")
					passed[victim] = true
				else
					a.contact = true
					local at = math.max(0, bestAlong - LEAD * 0.5)
					local def = table.clone(attack)
					def.damage = shareOf(c, victim, S.damageFraction)
					resolveHit(c, victim, def, "KatanaCrescent", nil, false, {
						contact = origin + direction * at,
						direction = direction,
					})
					-- it drives on through them, then explodes
					local hitVictim = victim
					task.delay(S.carryTime, function()
						local point = hitVictim.root.Position
						blast(point, hitVictim)
					end)
					finish(true)
					return
				end
			end
		end
		if travelled >= S.range then
			finish()
		end
	end)
end

function CombatService.katanaCrescent(c, predicted, attackId)
	local t = now()
	local attack = Config.Attacks.KatanaCrescent
	if not katanaReady(c) or not canStartAction(c, t) or t < c.crescentReadyAt then
		return false
	end
	local anim = AnimationData[attack.anim]
	setCooldown(c, "crescentReadyAt", t + attack.cooldown)
	c.sprinting = false

	-- (recovery cancels open once the last crescent has left)
	local a = { kind = "KatanaCrescent", def = attack, started = t, hitAt = t + (anim.markers.Hit2 or anim.markers.Hit), id = attackId, speed = 1 }
	c.attack = a
	local token = setState(c, "Attacking")
	c.nextActionAt = t + anim.recover
	playAnim(c, attack.anim, predicted)
	attackStarted:Fire(c, "KatanaCrescent", a.hitAt)

	-- One crescent per release (the cross slash). Each flies even if the
	-- caster is interrupted afterwards; a release that never came (cut short)
	-- throws nothing. The cooldown is refunded once none of them connected.
	local releases = attack.releases or { { marker = "Hit" } }
	local outstanding = #releases
	local function oneEnded()
		outstanding -= 1
		if outstanding == 0 and not a.contact then
			refundWhiff(c, "crescentReadyAt", a.started, attack.cooldown)
		end
	end
	for _, release in ipairs(releases) do
		local def = table.clone(attack)
		for key, value in pairs(release) do
			def[key] = value
		end
		def.damage = Config.damageFor(c.model, def.damage)
		task.delay(anim.markers[release.marker] or anim.markers.Hit, function()
			if c.token ~= token or not isAlive(c) then
				oneEnded()
				return
			end
			flyCrescent(c, def, a, oneEnded)
		end)
	end
	task.delay(anim.recover, function()
		if c.token == token then
			c.attack = nil
			setState(c, "Idle")
		end
	end)
	return true, attack.anim
end

------------------------------------------------------------------------
-- Head Drive (Y): grab, head slam, drag, two head slams. See HeadDrive for the
-- timeline. A player attacker's own client drives their body (they steer
-- the drag); the server pins the victim (anchored) and places it relative
-- to wherever the attacker is. Every client does the same placement
-- locally, so the two bodies stay locked together on every screen.
-- Dummies have no client, so a dummy attacker runs the straight path here.

local HD = HeadDrive.T

local function pin(c, on)
	c.root.Anchored = on
	if not on then
		c.root.AssemblyLinearVelocity = Vector3.zero
		c.root.AssemblyAngularVelocity = Vector3.zero
		pcall(function()
			-- back to its owner's physics (the server's, for dummies)
			c.root:SetNetworkOwner(c.player)
		end)
	end
end

local function grabExclude()
	local list = {}
	for model in pairs(combatants) do
		table.insert(list, model)
	end
	local fx = workspace:FindFirstChild("CombatFX")
	if fx then
		table.insert(list, fx)
	end
	return list
end

local function denyGrab(c, attackId)
	if c.player and attackId then
		Remotes.Grab:FireClient(c.player, "deny", attackId)
	end
	return false
end

-- `upright`: an interrupted grab stands the victim up where they are.
local function releaseTarget(g, upright)
	if g.targetFreed then
		return
	end
	g.targetFreed = true
	local d = g.defender
	if upright then
		local p = d.root.Position
		d.root.CFrame = CFrame.lookAlong(Vector3.new(p.X, g.base.Position.Y, p.Z), -flat(g.base.LookVector))
	end
	pin(d, false)
	d.grab = nil
	if isAlive(d) and d.state == "Grabbed" then
		-- can block or dash out straight away, but not attack for a beat
		setState(d, "GetUp", Config.HeadDrive.getUpTime)
	end
end

local function releaseAttacker(g)
	if g.attackerFreed then
		return
	end
	g.attackerFreed = true
	local a = g.attacker
	if g.serverDriven then
		pin(a, false)
	end
	a.grab = nil
	if isAlive(a) and a.state == "Grabbing" then
		a.nextActionAt = now()
		setState(a, "Idle")
	end
end

cancelGrab = function(g)
	if g.done then
		return
	end
	g.done = true
	grabs[g.attacker] = nil
	releaseTarget(g, true)
	releaseAttacker(g)
	Remotes.Grab:FireAllClients("stop", g.attacker.model)
end

local function startGrab(attacker, defender, startCF, attackId)
	local base, D = HeadDrive.plan(startCF, grabExclude())
	attacker.attack = nil
	defender.attack = nil
	defender.combo = 0
	defender.sprinting = false
	releaseJuggle(defender)
	for _, c in ipairs({ attacker, defender }) do
		stopMotion(c)
		stopHover(c)
	end
	setState(attacker, "Grabbing")
	setState(defender, "Grabbed")

	local startRel = base:ToObjectSpace(defender.root.CFrame)
	local serverDriven = attacker.player == nil
	if serverDriven then
		pin(attacker, true)
	end
	pin(defender, true)
	local g = {
		attacker = attacker,
		defender = defender,
		base = base,
		D = D,
		startRel = startRel,
		started = now(),
		id = attackId,
		nextDamage = 1,
		serverDriven = serverDriven,
	}
	grabs[attacker] = g
	attacker.grab = g
	defender.grab = g
	Remotes.Grab:FireAllClients("start", attacker.model, defender.model, startRel, attackId)
end

-- The hand closed on `defender`. Returns whether the grab took.
function CombatService.resolveGrab(attacker, defender, startCF, attackId)
	local t = now()
	if not isAlive(defender) or not isAlive(attacker) or defender.grab or attacker.grab then
		return denyGrab(attacker, attackId)
	end
	-- dash i-frames slip it
	if t < defender.iframesUntil then
		effect("Dodge", defender.root.Position, attacker, defender, "HeadDrive", attackId)
		return denyGrab(attacker, attackId)
	end
	-- the hand reached them (blocked or not): not a whiff
	if attacker.attack and attacker.attack.kind == "HeadDrive" then
		attacker.attack.contact = true
	end
	-- a held guard stops it. There's no parry check at all: a grab can't be
	-- parried, only blocked.
	if defender.state == "Blocking" and isFacing(defender, attacker) then
		local contact = defender.root.Position:Lerp(attacker.root.Position, 0.4) + Vector3.new(0, 0.6, 0)
		defender.lastPostureGain = t
		setPosture(defender, math.min(defender.maxPosture - 1, defender.posture + Config.HeadDrive.blockPosture))
		effect("Block", contact, attacker, defender, "HeadDrive", attackId)
		playAnim(defender, "BlockImpact")
		push(defender, flat(attacker.root.CFrame.LookVector) * 3, 0.1)
		return denyGrab(attacker, attackId)
	end
	-- the client's view of where it grabbed from, if it's believable
	if typeof(startCF) ~= "CFrame" or (startCF.Position - attacker.root.Position).Magnitude > 6 then
		startCF = attacker.root.CFrame
	end
	startGrab(attacker, defender, startCF, attackId)
	return true
end

function CombatService.headDrive(c, predicted, attackId)
	local H = Config.HeadDrive
	local t = now()
	if not canStartAction(c, t) or t < c.grabReadyAt then
		return false
	end
	setCooldown(c, "grabReadyAt", t + H.cooldown)
	c.sprinting = false

	local clientDriven = c.player ~= nil and predicted and attackId ~= nil
	local token = setState(c, "Attacking")
	local a = { kind = "HeadDrive", def = { feintable = false }, started = t, hitAt = t + HD.GRAB_AT, id = attackId, clientDriven = clientDriven }
	c.attack = a
	-- a grab that reached nobody only costs the whiff cooldown
	task.delay(H.whiffRecover + 0.05, function()
		if not a.contact then
			refundWhiff(c, "grabReadyAt", a.started, H.cooldown)
		end
	end)
	c.nextActionAt = t + H.whiffRecover
	playAnim(c, "HeadDriveReach", predicted)

	if not clientDriven then
		task.delay(HD.GRAB_AT, function()
			if c.token ~= token or not isAlive(c) then
				return
			end
			local target = findTarget(c, H)
			if target then
				CombatService.resolveGrab(c, target, c.root.CFrame, nil)
			end
		end)
	end
	-- a miss (or a blocked grab) recovers here; a grab that takes changes
	-- state, which cancels this
	task.delay(H.whiffRecover, function()
		if c.token == token then
			c.attack = nil
			setState(c, "Idle")
		end
	end)
	return true, "HeadDriveReach"
end

local function stepGrab(g)
	local t = now() - g.started
	local a, d = g.attacker, g.defender
	if not a.model.Parent or not d.model.Parent or not isAlive(a) or not isAlive(d) then
		cancelGrab(g)
		return
	end
	-- where the attacker is: the dummy path, or wherever the player steered
	local attackerCF
	if g.freeCF then
		attackerCF = g.freeCF -- after they're free, the victim finishes in place
	elseif g.serverDriven then
		attackerCF = g.base * (HeadDrive.sample(math.min(t, HD.LENGTH), g.D, g.startRel))
		a.root.CFrame = attackerCF
	else
		attackerCF = a.root.CFrame
	end
	if t >= HD.ATTACKER_FREE and not g.freeCF then
		g.freeCF = attackerCF
	end
	if not g.targetFreed then
		d.root.CFrame = attackerCF * HeadDrive.relative(math.min(t, HD.LENGTH), g.startRel)
	end

	while g.nextDamage <= #HeadDrive.DAMAGE and t >= HeadDrive.DAMAGE[g.nextDamage].t do
		local hit = HeadDrive.DAMAGE[g.nextDamage]
		g.nextDamage += 1
		if damage(d, Config.damageFor(a.model, d.humanoid.MaxHealth * hit.frac)) then
			cancelGrab(g)
			return
		end
	end

	if t >= HD.ATTACKER_FREE then
		-- the attacker is free a beat before the victim; they can't be hit
		-- in that gap or just after getting up, so the grab doesn't extend
		if not g.iframed then
			g.iframed = true
			setIFrames(d, now() + math.max(0, HD.LENGTH - t) + Config.HeadDrive.getUpTime + Config.HeadDrive.releaseIFrames)
		end
		releaseAttacker(g)
	end
	if t >= HD.LENGTH then
		g.done = true
		grabs[a] = nil
		releaseTarget(g, false)
	end
end

------------------------------------------------------------------------
-- Registration

function CombatService.get(model)
	return combatants[model]
end

function CombatService.register(model, player)
	local humanoid = model:WaitForChild("Humanoid")
	local root = model:WaitForChild("HumanoidRootPart")

	humanoid.MaxHealth = Config.MaxHealth
	humanoid.Health = Config.MaxHealth
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = Config.JumpHeight
	-- Plain Roblox overhead health while the custom HUD is out.
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer

	if not root:FindFirstChild("CombatAttachment") then
		local attachment = Instance.new("Attachment")
		attachment.Name = "CombatAttachment"
		attachment.Parent = root
	end

	local c = {
		model = model,
		humanoid = humanoid,
		root = root,
		player = player,

		state = "Idle",
		token = 0,
		attack = nil,

		combo = 0,
		lastM1 = 0,
		m1ReadyAt = 0,
		nextActionAt = 0,
		critReadyAt = 0,
		sweepReadyAt = 0,
		feintReadyAt = 0,

		parryUntil = 0,
		parryReadyAt = 0,
		parryM1Token = 0,
		parryM1Consumed = 0,
		stunParry = false,
		stunParryHeld = false,
		stunAnim = nil,
		blockStart = 0,
		blockReadyAt = 0,

		juggledBy = nil,
		juggleUntil = 0,
		juggleStart = 0,

		grabReadyAt = 0,
		grab = nil, -- the Head Drive this fighter is in, either side of it

		rushReadyAt = 0,
		crescentReadyAt = 0,

		rollReadyAt = 0,
		rollStarted = 0,
		iframesUntil = 0,
		doubleJumpReadyAt = 0,
		slamLocked = false, -- used a downslam this airtime
		downslamReadyAt = 0,

		posture = 0,
		maxPosture = Config.MaxPosture,
		lastPostureGain = 0,
		lastDamaged = 0,

		sprinting = false,
		equipped = player == nil,
	}

	combatants[model] = c
	setState(c, "Idle")
	setPosture(c, 0)
	model:SetAttribute("Equipped", c.equipped)
	model:SetAttribute("ParryM1Token", 0)
	model:SetAttribute("ParryM1Consumed", 0)
	model:SetAttribute("StunParry", false)
	CollectionService:AddTag(model, "Combatant")

	local function unregister()
		if combatants[model] == c then
			combatants[model] = nil
			c.token += 1
		end
	end
	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			unregister()
		end
	end)
	humanoid.Died:Connect(unregister)

	return c
end

RunService.Heartbeat:Connect(function(dt)
	for _, g in pairs(grabs) do
		if not g.done then
			stepGrab(g)
		end
	end

	local t = now()
	for _, c in pairs(combatants) do
		if c.juggledBy and t >= c.juggleUntil then
			releaseJuggle(c)
		end
		-- back on the ground: downslam is available again (a raycast, since
		-- FloorMaterial isn't reliable here for player-owned bodies)
		if c.slamLocked and c.root.Position.Y - groundBelow(c).Y < 3.4 then
			c.slamLocked = false
		end
		if c.posture > 0 and c.state ~= "Blocking" and not c.sprinting and t - c.lastPostureGain > Config.PostureRegenDelay then
			setPosture(c, c.posture - Config.PostureRegenRate * dt)
		end
	end
end)

return CombatService

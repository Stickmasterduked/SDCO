--[[
	Server-authoritative combat. Every character that can fight (players and
	dummies) is a combatant with one state machine:

	  Idle, Attacking, Blocking, Rolling, Stunned, Parried, GuardBroken

	Juggling is tracked alongside the state: a juggled combatant floats
	(Motion.hover) for a short time after each air hit and is released if
	they block or dash out, the juggle times out, or they get slammed.

	The client only sends inputs. Timing, hit detection, damage, posture and
	parry resolution all happen here. Effects carry the attack kind so every
	client can scale its hit effects, hit-stop and camera kick to the move.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CombatShared = ReplicatedStorage.Combat
local Config = require(CombatShared.Config)
local AnimationData = require(CombatShared.AnimationData)
local Motion = require(CombatShared.Motion)
local Remotes = CombatShared.Remotes

local FLAT = Vector3.new(1, 0, 1)

local CombatService = {}

local combatants = {}
CombatService.Combatants = combatants

local attackStarted = Instance.new("BindableEvent")
-- (attacker, attackKind, hitTime) - lets dummies react to incoming attacks
CombatService.AttackStarted = attackStarted.Event

local now = os.clock

local function flat(vector)
	return vector * FLAT
end

------------------------------------------------------------------------
-- Replication helpers

local function playAnim(c, name, predicted, stop)
	if c.player and predicted then
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= c.player then
				Remotes.Anim:FireClient(player, c.model, name, stop)
			end
		end
	else
		Remotes.Anim:FireAllClients(c.model, name, stop)
	end
end

local function stopAnim(c, name, predicted)
	playAnim(c, name, predicted, true)
end

-- `info` is the attack kind for hits, or the direction for a dash.
local function effect(kind, position, attacker, defender, info)
	Remotes.Effect:FireAllClients(kind, position, attacker and attacker.model, defender and defender.model, info)
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
		return Config.AttackWalkSpeed
	elseif state == "Rolling" then
		return Config.WalkSpeed
	elseif state == "GuardBroken" or state == "Captured" or state == "Kneeling" then
		return 0
	end
	return Config.StunWalkSpeed
end

local function applyMovement(c)
	c.humanoid.WalkSpeed = walkSpeedFor(c)
	c.humanoid.JumpHeight = (c.state == "Idle") and Config.JumpHeight or 0
end

local function setState(c, state, duration)
	c.state = state
	c.token += 1
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
	c.posture = math.clamp(value, 0, c.maxPosture)
	c.model:SetAttribute("Posture", math.floor(c.posture + 0.5))
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

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include

local function findTarget(c, attack)
	local candidates = {}
	for model, other in pairs(combatants) do
		if other ~= c and isAlive(other) then
			table.insert(candidates, model)
		end
	end
	if #candidates == 0 then
		return nil
	end
	overlap.FilterDescendantsInstances = candidates

	local height = attack.height or 6
	local boxCFrame = CFrame.lookAlong(c.root.Position, flat(c.root.CFrame.LookVector).Unit)
		* CFrame.new(0, attack.height and -1.5 or 0, -attack.range / 2)
	local parts = workspace:GetPartBoundsInBox(boxCFrame, Vector3.new(attack.width, height, attack.range), overlap)

	local best, bestDistance
	for _, part in ipairs(parts) do
		local other = combatants[part.Parent]
		if other and other ~= c then
			local distance = (other.root.Position - c.root.Position).Magnitude
			if not bestDistance or distance < bestDistance then
				best, bestDistance = other, distance
			end
		end
	end
	return best
end

local function guardBreak(defender, attacker, attack, kind)
	defender.attack = nil
	defender.combo = 0
	defender.blockReadyAt = now() + Config.GuardBreakStun + Config.BlockCooldown
	releaseJuggle(defender)
	setPosture(defender, 0)
	effect("GuardBreak", defender.root.Position, attacker, defender, kind)
	if damage(defender, attack.damage * Config.GuardBreakDamageMult) then
		return
	end
	setState(defender, "GuardBroken", Config.GuardBreakStun)
	playAnim(defender, "GuardBreak")
	push(defender, flat(attacker.root.CFrame.LookVector) * 14, 0.15)
end

local function resolveHit(attacker, defender, attack, kind)
	local t = now()
	if not isAlive(defender) or t < defender.invincibleUntil then
		return
	end
	-- Held by the slash skill: extra hits still hurt but don't break the hold.
	if defender.state == "Captured" then
		effect("Hit", defender.root.Position + Vector3.new(0, 0.6, 0), attacker, defender)
		damage(defender, attack.damage)
		return
	end
	if t < defender.iframesUntil then
		effect("Dodge", defender.root.Position, attacker, defender)
		return
	end

	local contact = defender.root.Position:Lerp(attacker.root.Position, 0.4) + Vector3.new(0, 0.6, 0)
	local facing = isFacing(defender, attacker)
	local stunnable = defender.state ~= "Stunned" and defender.state ~= "GuardBroken" and defender.state ~= "Parried"

	-- Parry: negates everything, refunds the parry, recovers posture, recoils the attacker.
	if facing and t <= defender.parryUntil and stunnable then
		defender.parryUntil = 0
		defender.parryReadyAt = 0
		setPosture(defender, defender.posture - Config.ParryPostureRecover)

		attacker.attack = nil
		attacker.combo = 0
		-- Can't attack again for a moment, but can still parry the counter:
		-- that's what makes parry trading possible.
		attacker.nextActionAt = t + Config.ParriedStun
		setState(attacker, "Parried", Config.ParriedStun)
		stopMotion(attacker)
		playAnim(attacker, "Parried")
		playAnim(defender, "BlockImpact")
		effect("Parry", contact, attacker, defender, kind)
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

		if defender.posture + postureDamage >= defender.maxPosture then
			guardBreak(defender, attacker, attack, kind)
			return
		end

		setPosture(defender, defender.posture + postureDamage)
		effect("Block", contact, attacker, defender, kind)
		playAnim(defender, "BlockImpact")
		push(defender, flat(attacker.root.CFrame.LookVector) * 2.5, 0.08)
		damage(defender, attack.damage * Config.ChipDamage)
		return
	end

	-- Clean hit: damage, interrupt, hitstun, knockback.
	local heavy = attack.heavy or attack.knockback >= 18 or attack.launcher or attack.slam
	effect(heavy and "HeavyHit" or "Hit", contact, attacker, defender, kind)
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

	local direction = flat(attacker.root.CFrame.LookVector)

	if attack.slam then
		-- Spiked into the ground: long stun, ground impact where they land.
		releaseJuggle(defender)
		setState(defender, "Stunned", Config.SlamStun)
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
	local react
	if attack.react == "Knockback" then
		react = "Knockback"
	elseif not facing then
		react = "HitBack"
	else
		react = attack.react or "HitFront"
	end
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
			if attack.selfLaunch then
				push(attacker, Vector3.new(0, attack.selfLaunch, 0), 0)
				hover(attacker, Config.AirAttackHover, apex)
			end
			return
		end
		releaseJuggle(defender)
	end

	push(defender, direction * attack.knockback + Vector3.new(0, attack.launch or 0, 0), attack.pushTime or 0.15)
end

local function startAttack(c, kind, predicted)
	local attack = Config.Attacks[kind]
	local anim = AnimationData[attack.anim]
	local hitDelay = anim.markers.Hit
	local t = now()

	local token = setState(c, "Attacking")
	c.attack = { kind = kind, def = attack, started = t, hitAt = t + hitDelay }
	c.nextActionAt = t + anim.recover

	playAnim(c, attack.anim, predicted)
	attackStarted:Fire(c, kind, c.attack.hitAt)

	-- Stay up with the target while air comboing; a slam drops you with them.
	if attack.air and not attack.slam and juggleTargetOf(c, t) then
		hover(c, Config.AirAttackHover)
	elseif attack.slam then
		stopHover(c)
	end

	if attack.lunge and not attack.lungeAtHit then
		push(c, flat(c.root.CFrame.LookVector) * attack.lunge[1], attack.lunge[2])
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
			resolveHit(c, target, attack, kind)
		end
		if c.token ~= token then
			return
		end

		task.delay(anim.recover - hitDelay, function()
			if c.token == token then
				c.attack = nil
				setState(c, "Idle")
			end
		end)
	end)
end

------------------------------------------------------------------------
-- Actions. Each returns (accepted, animationName).

local function canStartAction(c, t)
	return c.state == "Idle" and t >= c.nextActionAt and t > c.parryUntil
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

function CombatService.m1(c, options, predicted)
	local t = now()
	if not canStartAction(c, t) then
		return false
	end

	if t - c.lastM1 > Config.ComboResetTime then
		c.combo = 0
	end

	local airborne = options.airborne or c.humanoid.FloorMaterial == Enum.Material.Air
	local speed = flat(c.root.AssemblyLinearVelocity).Magnitude

	local kind
	if airborne then
		-- In the air: keep juggling, and the last hit (or a lone jump attack) slams.
		if juggleTargetOf(c, t) and c.combo + 1 < Config.ComboLength then
			kind = Config.AirChain[c.combo % #Config.AirChain + 1]
		else
			kind = "Downslam"
		end
	elseif options.launcher then
		kind = "Uppercut"
	elseif c.sprinting and speed > Config.WalkSpeed + 2 then
		kind = "RunningAttack"
	elseif c.combo + 1 >= Config.ComboLength then
		kind = "Finisher"
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

	startAttack(c, kind, predicted)
	return true, Config.Attacks[kind].anim
end

function CombatService.critical(c, predicted)
	local t = now()
	if not canStartAction(c, t) or t < c.critReadyAt then
		return false
	end
	c.critReadyAt = t + Config.Attacks.Critical.cooldown
	c.sprinting = false
	startAttack(c, "Critical", predicted)
	return true, "Critical"
end

function CombatService.feint(c, predicted)
	local t = now()

	if c.state == "Attacking" and c.attack then
		if not c.attack.def.feintable or t < c.feintReadyAt or t > c.attack.hitAt - Config.FeintLockout then
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
		c.iframesUntil = 0
		c.rollReadyAt = t + Config.RollCancelCooldown
		setState(c, "Idle")
		stopMotion(c)
		playAnim(c, "Feint", predicted)
		return true, "Feint"
	end

	return false
end

function CombatService.blockDown(c, resume, predicted)
	local t = now()
	if t < c.blockReadyAt then
		return false
	end
	if c.state == "Rolling" then
		c.iframesUntil = 0
	elseif inRecovery(c, t) then
		cancelRecovery(c, t)
	elseif c.state ~= "Idle" and c.state ~= "Parried" then
		return false
	end

	-- Guarding mid-juggle is how you get out of an air combo.
	if isJuggled(c, t) then
		releaseJuggle(c)
	end

	-- Pressing F opens the parry window; keeping it held is a normal block.
	-- Both use the same block pose, so a parry is purely about timing.
	if not resume and t >= c.parryReadyAt then
		c.parryUntil = t + Config.ParryWindow
		c.parryReadyAt = t + Config.ParryCooldown
	end

	c.sprinting = false
	c.blockStart = t
	setState(c, "Blocking")
	playAnim(c, "Block", predicted)
	return true, "Block"
end

function CombatService.blockUp(c, predicted)
	if c.state == "Blocking" then
		c.blockReadyAt = now() + Config.BlockCooldown
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
	elseif c.state ~= "Idle" and c.state ~= "Blocking" then
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
	c.iframesUntil = t + Config.RollIFrames
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
	dash(c, dir * (airborne and Config.AirDashSpeed or Config.RollSpeed), Config.RollDuration * 0.9)
	if airborne then
		hover(c, Config.RollDuration * 0.9)
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

function CombatService.setSprint(c, on)
	c.sprinting = on == true and c.state == "Idle"
	applyMovement(c)
	return true
end

------------------------------------------------------------------------
-- Slash skill

local function capture(victim, caster)
	local S = Config.Skill
	local t = now()
	victim.attack = nil
	victim.combo = 0
	victim.sprinting = false
	releaseJuggle(victim)
	stopMotion(victim)
	setState(victim, "Captured")
	victim.captureId += 1
	local id = victim.captureId
	victim.model:SetAttribute("Dismantled", true)
	playAnim(victim, "Captured")
	effect("CleaveHit", victim.root.Position + Vector3.new(0, 0.5, 0), caster, victim)

	task.spawn(function()
		local perTick = victim.humanoid.MaxHealth * S.damagePerSecond * S.tickInterval
		local elapsed = 0
		while elapsed < S.captureTime do
			task.wait(S.tickInterval)
			elapsed += S.tickInterval
			if victim.captureId ~= id or not isAlive(victim) or victim.state ~= "Captured" then
				break
			end
			damage(victim, perTick)
		end
		if victim.captureId ~= id then
			return
		end
		victim.model:SetAttribute("Dismantled", false)
		stopAnim(victim, "Captured")
		if isAlive(victim) then
			victim.invincibleUntil = now() + S.kneelTime
			setState(victim, "Kneeling", S.kneelTime)
			playAnim(victim, "Kneel")
		end
	end)
	return t
end

function CombatService.skill(c, predicted)
	local S = Config.Skill
	local t = now()
	if not canStartAction(c, t) or t < c.skillReadyAt then
		return false
	end
	c.skillReadyAt = t + S.cooldown
	c.sprinting = false

	local token = setState(c, "Attacking")
	c.attack = { kind = "Skill", def = { feintable = false }, started = t, hitAt = t + S.release }
	c.nextActionAt = t + S.castTime
	playAnim(c, "SkillCast", predicted)

	task.delay(S.release, function()
		if c.token ~= token or not isAlive(c) then
			return
		end
		local direction = flat(c.root.CFrame.LookVector).Unit
		local origin = c.root.Position + direction * 1.5
		effect("CleaveThrow", origin, c)

		-- the slash travels; the first fighter it passes through is caught
		local start = now()
		local travelled = 0
		while travelled < S.range do
			local step = math.min(S.range, S.speed * (now() - start))
			local segment = math.max(step - travelled, 1)
			local centre = origin + direction * (travelled + segment / 2)
			local candidates = {}
			for model, other in pairs(combatants) do
				if other ~= c and isAlive(other) then
					table.insert(candidates, model)
				end
			end
			overlap.FilterDescendantsInstances = candidates
			local box = CFrame.lookAlong(centre, direction)
			local parts = workspace:GetPartBoundsInBox(box, Vector3.new(S.width, 6, segment + 1), overlap)
			for _, part in ipairs(parts) do
				local victim = combatants[part.Parent]
				if victim and victim ~= c and isAlive(victim) then
					local tt = now()
					if tt < victim.iframesUntil then
						effect("Dodge", victim.root.Position, c, victim)
					elseif tt >= victim.invincibleUntil and victim.state ~= "Captured" then
						capture(victim, c)
						return
					end
				end
			end
			travelled = step
			task.wait()
		end
	end)

	task.delay(S.castTime, function()
		if c.token == token then
			c.attack = nil
			setState(c, "Idle")
		end
	end)
	return true, "SkillCast"
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
		nextActionAt = 0,
		critReadyAt = 0,
		feintReadyAt = 0,

		parryUntil = 0,
		parryReadyAt = 0,
		blockStart = 0,
		blockReadyAt = 0,

		juggledBy = nil,
		juggleUntil = 0,
		juggleStart = 0,

		skillReadyAt = 0,
		captureId = 0,
		invincibleUntil = 0,

		rollReadyAt = 0,
		rollStarted = 0,
		iframesUntil = 0,
		doubleJumpReadyAt = 0,

		posture = 0,
		maxPosture = Config.MaxPosture,
		lastPostureGain = 0,
		lastDamaged = 0,

		sprinting = false,
	}

	combatants[model] = c
	setState(c, "Idle")
	setPosture(c, 0)
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
	local t = now()
	for _, c in pairs(combatants) do
		if c.juggledBy and t >= c.juggleUntil then
			releaseJuggle(c)
		end
		if c.posture > 0 and c.state ~= "Blocking" and not c.sprinting and t - c.lastPostureGain > Config.PostureRegenDelay then
			setPosture(c, c.posture - Config.PostureRegenRate * dt)
		end
	end
end)

return CombatService

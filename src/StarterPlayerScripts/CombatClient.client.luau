--[[
	Client side of the fist combat: input, animation playback for every
	combatant (locomotion included), impact feedback and camera work.

	Own actions are predicted: the animation and effects play the moment you
	press the key, and the server's Ack corrects it if the server disagrees.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CombatShared = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatShared.Config)
local AnimationData = require(CombatShared.AnimationData)
local PoseAnimator = require(CombatShared.PoseAnimator)
local Effects = require(CombatShared.Effects)
local Motion = require(CombatShared.Motion)
local CameraFX = require(CombatShared.CameraFX)
local Remotes = CombatShared:WaitForChild("Remotes")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local FLAT = Vector3.new(1, 0, 1)

Effects.preload()
CameraFX.start()

------------------------------------------------------------------------
-- Animation playback (all combatants, run locally on every client)

-- Poses are played straight from AnimationData by PoseAnimator, so nothing
-- has to be uploaded and it behaves the same in Studio and live games.
local tracksByModel = {}

local function getTrack(model, name)
	if not model:FindFirstChildOfClass("Humanoid") then
		return nil
	end

	local tracks = tracksByModel[model]
	if not tracks then
		tracks = {}
		tracksByModel[model] = tracks
		model.Destroying:Once(function()
			tracksByModel[model] = nil
		end)
	end
	if tracks[name] then
		return tracks[name]
	end
	local track = PoseAnimator.get(model):track(name)

	local data = AnimationData[name]
	if data.markers and data.markers.Swing then
		local heavy = name == "Critical" or name == "Finisher"
		track:GetMarkerReachedSignal("Swing"):Connect(function()
			local root = model:FindFirstChild("HumanoidRootPart")
			if root then
				Effects.sound("Swing", root, heavy and 0.65 or 0.45, heavy and 0.8 or 1)
				-- your own strike leaving the windup nudges the camera with it
				if model == player.Character and root:IsA("BasePart") then
					CameraFX.punch(root.CFrame.LookVector, heavy and 0.35 or 0.12)
				end
			end
			local hitAt = data.markers.Hit or data.markers.Swing
			Effects.swingTrails(model, (hitAt - data.markers.Swing) + 0.1, data.trail)
		end)
	end

	tracks[name] = track
	return track
end

local REPLACES = {
	action = { action = true, react = true, hold = true },
	react = { action = true, react = true, hold = true },
	hold = { action = true },
}

local function stopGroups(model, groups, except)
	local tracks = tracksByModel[model]
	if not tracks then
		return
	end
	for name, track in pairs(tracks) do
		if name ~= except and track.IsPlaying and groups[AnimationData[name].group] then
			track:Stop(0.08)
		end
	end
end

local function isPlayingGroup(model, groups)
	local tracks = tracksByModel[model]
	if tracks then
		for name, track in pairs(tracks) do
			if track.IsPlaying and groups[AnimationData[name].group] then
				return true
			end
		end
	end
	return false
end

local function playAnim(model, name)
	local data = AnimationData[name]
	if not data then
		return
	end
	if data.variants then
		name = data.variants[math.random(1, #data.variants)]
		data = AnimationData[name]
	end

	local replaces = REPLACES[data.group]
	if replaces then
		stopGroups(model, replaces, name)
	end

	local track = getTrack(model, name)
	if track then
		local fade = data.group == "react" and 0.03 or 0.06
		if data.group == "hold" and track.IsPlaying then
			return
		end
		track:Play(fade, 1, 1)
	end
end

local function stopAnim(model, name)
	local tracks = tracksByModel[model]
	local track = tracks and tracks[name]
	if track and track.IsPlaying then
		track:Stop(0.1)
	end
end

local function stopFamily(model, name)
	-- hit reactions have variants; stopping the family stops whichever played
	stopAnim(model, name)
	local data = AnimationData[name]
	if data and data.variants then
		for _, variant in ipairs(data.variants) do
			stopAnim(model, variant)
		end
	end
end

Remotes.Anim.OnClientEvent:Connect(function(model, name, stop)
	if typeof(model) ~= "Instance" or not model.Parent or type(name) ~= "string" then
		return
	end
	if stop then
		stopFamily(model, name)
	else
		playAnim(model, name)
	end
end)

------------------------------------------------------------------------
-- Locomotion: idle / walk / run / jump / fall / land for every combatant,
-- picked from how the body is actually moving.

local locomotion = {}

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshGroundFilter()
	local ignore = CollectionService:GetTagged("Combatant")
	local fx = workspace:FindFirstChild("CombatFX")
	if fx then
		table.insert(ignore, fx)
	end
	groundParams.FilterDescendantsInstances = ignore
end

local function isGrounded(humanoid, root, model)
	if model == player.Character then
		return humanoid.FloorMaterial ~= Enum.Material.Air
	end
	-- Other bodies: FloorMaterial isn't reliable for them here, so probe.
	return workspace:Raycast(root.Position, Vector3.new(0, -3.6, 0), groundParams) ~= nil
end

local function updateLocomotion(model, dt)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end

	local state = locomotion[model]
	if not state then
		state = { current = nil, airborneFor = 0, minVy = 0, stride = 0 }
		locomotion[model] = state
		model.Destroying:Once(function()
			locomotion[model] = nil
		end)
	end

	local stance = getTrack(model, "Stance")
	if stance and not stance.IsPlaying then
		stance:Play(0.2)
	end

	local velocity = root.AssemblyLinearVelocity
	local speed = (velocity * FLAT).Magnitude
	local grounded = isGrounded(humanoid, root, model)

	local want
	if not grounded then
		state.airborneFor += dt
		state.minVy = math.min(state.minVy, velocity.Y)
		if velocity.Y > 3 and state.current ~= "Fall" then
			want = "Jump"
		elseif state.airborneFor > 0.12 or velocity.Y < -8 then
			want = "Fall"
		else
			want = state.current
		end
	else
		-- landing
		if state.airborneFor > 0.25 then
			local impact = -state.minVy
			if impact > 22 then
				local strength = math.clamp((impact - 22) / 70, 0, 1)
				if not isPlayingGroup(model, { action = true, react = true }) then
					playAnim(model, "Land")
				end
				Effects.land(root.Position, strength)
				if model == player.Character then
					CameraFX.shake(0.08 + strength * 0.25)
					CameraFX.punch(-Vector3.yAxis, 0.25 + strength * 0.5)
				end
			end
		end
		state.airborneFor = 0
		state.minVy = 0

		if speed < 1.2 then
			want = nil
		elseif speed < Config.WalkSpeed + 3.5 then
			want = "Walk"
		else
			want = "Run"
		end
	end

	if want ~= state.current then
		if state.current then
			local old = getTrack(model, state.current)
			if old then
				old:Stop(state.current == "Jump" and 0.25 or 0.15)
			end
		end
		if want then
			local track = getTrack(model, want)
			if track then
				track:Play(want == "Fall" and 0.25 or 0.12)
			end
		end
		state.current = want
	end

	if want == "Walk" or want == "Run" then
		local track = getTrack(model, want)
		local data = AnimationData[want]
		if track and data.speedRef then
			track:AdjustSpeed(math.clamp(speed / data.speedRef, 0.55, 1.6))
		end
	end

	-- dust kicked up by sprinting feet
	if grounded and want == "Run" then
		state.stride += speed * dt
		if state.stride > 7.5 then
			state.stride = 0
			Effects.step(root.Position)
		end
	end
end

------------------------------------------------------------------------
-- Combatant setup

local function setupCombatant(model)
	task.spawn(function()
		local humanoid = model:WaitForChild("Humanoid", 10)
		if not humanoid then
			return
		end
		local track = getTrack(model, "Stance")
		if track then
			track:Play(0.2)
		end
		Effects.attachTrails(model)
	end)
end

CollectionService:GetInstanceAddedSignal("Combatant"):Connect(setupCombatant)
for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
	setupCombatant(model)
end

-- Keeps state-driven tracks in sync: locomotion, and the block hold while
-- another combatant is blocking (late joiners and missed events recover).
local filterTimer = 0
RunService.Heartbeat:Connect(function(dt)
	filterTimer -= dt
	if filterTimer <= 0 then
		filterTimer = 1
		refreshGroundFilter()
	end

	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		if model.Parent then
			updateLocomotion(model, dt)

			if model ~= player.Character then
				local blocking = model:GetAttribute("CombatState") == "Blocking"
				local block = getTrack(model, "Block")
				if block and blocking ~= block.IsPlaying then
					if blocking then
						block:Play(0.07)
					else
						block:Stop(0.1)
					end
				end
			end
		end
	end
end)

------------------------------------------------------------------------
-- Feedback

-- Physical reactions layered over the clips (degrees/second impulses).
local function hitDirection(attacker, defender)
	local a = attacker and attacker:FindFirstChild("HumanoidRootPart")
	local d = defender and defender:FindFirstChild("HumanoidRootPart")
	if not a or not d then
		return 1, 0
	end
	local from = d.CFrame:VectorToObjectSpace((d.Position - a.Position) * FLAT)
	if from.Magnitude < 0.01 then
		return 1, 0
	end
	from = from.Unit
	-- from.Z < 0: pushed backwards relative to the defender's facing
	return -from.Z, from.X
end

local function worldDirection(attacker, defender)
	local a = attacker and attacker:FindFirstChild("HumanoidRootPart")
	local d = defender and defender:FindFirstChild("HumanoidRootPart")
	if a and d then
		local dir = (d.Position - a.Position) * FLAT
		if dir.Magnitude > 0.05 then
			return dir.Unit
		end
	end
	return Vector3.zero
end

local function isModel(value)
	return typeof(value) == "Instance" and value.Parent ~= nil
end

local function react(kind, attacker, defender)
	local back, side = hitDirection(attacker, defender)
	local function kick(model, joint, p, y, r)
		if isModel(model) then
			PoseAnimator.kick(model, joint, Vector3.new(p, y, r))
		end
	end
	if kind == "Hit" or kind == "HeavyHit" then
		local m = kind == "HeavyHit" and 1.8 or 1.15
		kick(defender, "Torso", 300 * back * m, math.random(-160, 160), -200 * side * m)
		kick(defender, "Head", 420 * back * m, math.random(-260, 260), -120 * side * m)
		kick(defender, "RightArm", 260 * m, 0, 160 * m)
		kick(defender, "LeftArm", 260 * m, 0, -160 * m)
		kick(attacker, "Torso", -90, 0, 0)
		kick(attacker, "Head", -120, 0, 0)
	elseif kind == "Block" then
		kick(defender, "RightArm", -320, 0, 80)
		kick(defender, "LeftArm", -320, 0, -80)
		kick(defender, "Torso", 180, 0, 0)
		kick(attacker, "Torso", 120, 0, 0)
	elseif kind == "Parry" then
		kick(attacker, "Torso", 320, 0, 0)
		kick(attacker, "RightArm", 520, 0, 0)
		kick(attacker, "LeftArm", 520, 0, 0)
		kick(defender, "LeftArm", 300, 0, -120)
	elseif kind == "GuardBreak" then
		kick(defender, "Torso", 480, 0, 0)
		kick(defender, "Head", 600, 0, 0)
	elseif kind == "Slam" then
		kick(defender, "Torso", -420, 0, 0)
		kick(defender, "Head", -520, 0, 0)
	end
end

-- Both bodies freeze for a few frames when a hit connects.
local function hitStop(kind, attacker, defender)
	local duration = Config.HitStop[kind]
	if not duration then
		return
	end
	if isModel(defender) then
		PoseAnimator.hitStop(defender, duration, kind == "Block" and 0.1 or 0.28)
	end
	if isModel(attacker) then
		PoseAnimator.hitStop(attacker, duration, kind == "Parry" and 0.22 or 0)
	end
	if kind == "Parry" and isModel(defender) then
		playAnim(defender, "Deflect")
	end
end

local IMPACT_TINT = {
	Parry = Color3.fromRGB(255, 230, 170),
	GuardBreak = Color3.fromRGB(255, 190, 150),
}

-- Camera reaction, strongest for whoever is on the receiving end.
local function cameraReact(kind, amount, position, attacker, defender, info)
	local character = player.Character
	if not character then
		return
	end
	local direction = worldDirection(attacker, defender)
	local big = info == "Finisher" or info == "Critical"

	if defender == character then
		CameraFX.shake(amount)
		CameraFX.punch(direction, kind == "HeavyHit" and 0.9 or 0.5)
		if kind == "HeavyHit" or kind == "GuardBreak" then
			CameraFX.fovKick(big and 7 or 4)
			CameraFX.rollKick(math.random() < 0.5 and -5 or 5)
			CameraFX.impactFrame(big and 0.7 or 0.4, IMPACT_TINT[kind])
		elseif kind == "Parry" then
			CameraFX.fovKick(-3)
			CameraFX.impactFrame(0.35, IMPACT_TINT.Parry)
		end
	elseif attacker == character then
		CameraFX.shake(amount * 0.55)
		CameraFX.punch(direction, kind == "HeavyHit" and 0.45 or 0.22)
		if kind == "HeavyHit" or kind == "GuardBreak" then
			CameraFX.fovKick(big and -6 or -3)
			CameraFX.impactFrame(big and 0.8 or 0.35, IMPACT_TINT[kind])
			if big then
				CameraFX.blur(8)
			end
		elseif kind == "Parry" then
			CameraFX.shake(0.15)
			CameraFX.fovKick(4)
		elseif kind == "Hit" then
			CameraFX.fovKick(-1.2)
		end
	else
		-- spectating: only big impacts nearby reach the camera
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and amount >= 0.4 then
			local falloff = math.clamp(1 - (root.Position - position).Magnitude / 45, 0, 1)
			CameraFX.shake(amount * 0.35 * falloff)
		end
	end
end

Remotes.Effect.OnClientEvent:Connect(function(kind, position, attacker, defender, info)
	if type(kind) ~= "string" or typeof(position) ~= "Vector3" then
		return
	end
	local character = player.Character

	-- movement effects: our own were already played when we pressed the key
	if kind == "Dash" then
		if isModel(attacker) and attacker ~= character then
			Effects.dash(attacker, typeof(info) == "Vector3" and info or Vector3.zero, false)
		end
		return
	elseif kind == "DoubleJump" then
		if isModel(attacker) and attacker ~= character then
			Effects.doubleJump(attacker)
		end
		return
	end

	react(kind, attacker, defender)
	hitStop(kind, attacker, defender)
	local amount = Effects.play(kind, position, attacker, defender, info)
	cameraReact(kind, amount, position, attacker, defender, info)
end)

------------------------------------------------------------------------
-- Aim assist: attacks, guards and side dashes turn toward the enemy you're
-- facing, so exchanges happen face to face.

local function findFocus(root, range)
	local look = camera.CFrame.LookVector * FLAT
	if look.Magnitude < 0.01 then
		return nil
	end
	look = look.Unit
	local cosLimit = math.cos(math.rad(Config.AimAssistAngle))
	local best, bestScore
	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		if model ~= player.Character then
			local other = model:FindFirstChild("HumanoidRootPart")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if other and humanoid and humanoid.Health > 0 then
				local offset = (other.Position - root.Position) * FLAT
				local distance = offset.Magnitude
				if distance > 0.1 and distance <= (range or Config.AimAssistRange) then
					local dot = look:Dot(offset.Unit)
					if dot >= cosLimit then
						local score = distance * (2 - dot)
						if not bestScore or score < bestScore then
							best, bestScore = other, score
						end
					end
				end
			end
		end
	end
	return best
end

------------------------------------------------------------------------
-- Local prediction

local sequence = 0
local pending = {}

local predicted = {
	combo = 0,
	lastM1 = 0,
	busyUntil = 0,
	attackHitAt = 0,
	attacking = false,
	parryReadyAt = 0,
	parryUntil = 0,
	feintReadyAt = 0,
	critReadyAt = 0,
	rollReadyAt = 0,
	rollStarted = 0,
	blockReadyAt = 0,
	blocking = false,
	lastBlockTry = 0,
	skillReadyAt = 0,
	doubleJumped = false,
	dashOrbit = nil,
	dashOrbitUntil = 0,
}

local blockPressedAt = 0

-- Space waits a beat before jumping so Space + M1 can launch instead.
local spaceDownAt = nil
local jumpConsumed = false

local sprinting = false
local blockHeld = false
local bufferedM1 = nil
local lastWPress = 0

local function getCharacter()
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return nil
	end
	return character, humanoid, root
end

local function serverState()
	local character = player.Character
	return character and character:GetAttribute("CombatState") or "Idle"
end

local function canPredictAction(t)
	return serverState() == "Idle" and t >= predicted.busyUntil and t > predicted.parryUntil
end

local function send(action, arg, predictedAnim, kind)
	sequence += 1
	if predictedAnim then
		pending[sequence] = { anim = predictedAnim, kind = kind }
	end
	Remotes.Action:FireServer(action, sequence, arg)
end

Remotes.Ack.OnClientEvent:Connect(function(id, accepted, anim)
	local entry = pending[id]
	pending[id] = nil
	local character = player.Character
	if not character then
		return
	end

	if entry and entry.kind == "block" then
		if not accepted then
			stopAnim(character, "Block")
		end
		return
	end

	if entry and entry.kind == "m1" then
		predicted.combo = character:GetAttribute("Combo") or predicted.combo
	end

	if entry then
		if not accepted then
			stopAnim(character, entry.anim)
			predicted.busyUntil = 0
			predicted.attacking = false
		elseif anim and anim ~= entry.anim then
			stopAnim(character, entry.anim)
			playAnim(character, anim)
		end
	elseif accepted and anim then
		playAnim(character, anim)
	end
end)

-- Past your own hit frame: block, parry and dash can cut the swing short.
local function inPredictedRecovery(t)
	return predicted.attacking and t > predicted.attackHitAt
end

local function predictAttack(kind)
	local attack = Config.Attacks[kind]
	local anim = AnimationData[attack.anim]
	local t = os.clock()
	predicted.busyUntil = t + anim.recover
	predicted.attackHitAt = t + anim.markers.Hit
	predicted.attacking = true
	return attack.anim
end

local function doM1()
	local character, humanoid, root = getCharacter()
	if not character then
		return
	end
	local t = os.clock()

	if not canPredictAction(t) then
		bufferedM1 = t
		return
	end
	bufferedM1 = nil

	local airborne = humanoid.FloorMaterial == Enum.Material.Air
	local launcher = not airborne and spaceDownAt ~= nil and UserInputService:IsKeyDown(Enum.KeyCode.Space)
	local speed = (root.AssemblyLinearVelocity * FLAT).Magnitude
	if launcher then
		jumpConsumed = true
	end

	if t - predicted.lastM1 > Config.ComboResetTime then
		predicted.combo = 0
	end

	local juggling = false
	if airborne then
		for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
			local other = model:FindFirstChild("HumanoidRootPart")
			if model ~= character and other and model:GetAttribute("Juggled")
				and (other.Position - root.Position).Magnitude < 12 then
				juggling = true
				break
			end
		end
	end

	local kind
	if airborne then
		if juggling and predicted.combo + 1 < Config.ComboLength then
			kind = Config.AirChain[predicted.combo % #Config.AirChain + 1]
		else
			kind = "Downslam"
		end
	elseif launcher then
		kind = "Uppercut"
	elseif sprinting and speed > Config.WalkSpeed + 2 then
		kind = "RunningAttack"
	elseif predicted.combo + 1 >= Config.ComboLength then
		kind = "Finisher"
	else
		kind = Config.M1Chain[predicted.combo % #Config.M1Chain + 1]
	end

	predicted.combo += 1
	if Config.Attacks[kind].endsCombo then
		predicted.combo = 0
	end
	predicted.lastM1 = t
	sprinting = false

	local anim = predictAttack(kind)
	playAnim(character, anim)
	send("M1", { launcher = launcher, airborne = airborne }, anim, "m1")
end

local function doCritical()
	local character = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	if canPredictAction(t) and t >= predicted.critReadyAt then
		predicted.critReadyAt = t + Config.Attacks.Critical.cooldown
		sprinting = false
		local anim = predictAttack("Critical")
		playAnim(character, anim)
		CameraFX.fovKick(-2)
		send("Critical", nil, anim)
	else
		send("Critical")
	end
end

local function doFeint()
	local character, _, root = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	local state = serverState()

	local canFeintAttack = predicted.attacking
		and t < predicted.attackHitAt - Config.FeintLockout
		and t >= predicted.feintReadyAt
	local canCancelRoll = state == "Rolling" and t - predicted.rollStarted <= Config.RollCancelWindow

	if canFeintAttack then
		predicted.feintReadyAt = t + Config.FeintCooldown
		predicted.attacking = false
		predicted.busyUntil = t + 0.1
		playAnim(character, "Feint")
		send("Feint", nil, "Feint")
	elseif canCancelRoll then
		Motion.stop(root)
		playAnim(character, "Feint")
		send("Feint", nil, "Feint")
	else
		send("Feint")
	end
end

local function doBlock(resume)
	local character = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	local state = serverState()
	local recovering = inPredictedRecovery(t)
	predicted.lastBlockTry = t
	if t < predicted.blockReadyAt then
		return
	end
	if state ~= "Idle" and state ~= "Rolling" and state ~= "Parried" and not recovering then
		return
	end
	predicted.blocking = true

	-- Same pose either way: the press opens the parry window, holding blocks.
	if not resume and t >= predicted.parryReadyAt then
		predicted.parryReadyAt = t + Config.ParryCooldown
		predicted.parryUntil = t + Config.ParryWindow
	end
	if recovering then
		predicted.attacking = false
		predicted.busyUntil = t
	end
	sprinting = false
	playAnim(character, "Block")
	send("BlockDown", resume == true, "Block", "block")
end

local function releaseBlock()
	local character = player.Character
	if character then
		stopAnim(character, "Block")
	end
	if predicted.blocking then
		predicted.blockReadyAt = os.clock() + Config.BlockCooldown
	end
	predicted.blocking = false
	send("BlockUp")
end

-- Same choice the server makes in CombatService.dashAnim.
local function dashAnim(root, direction, airborne)
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

local function doRoll()
	local character, humanoid, root = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	local state = serverState()
	local recovering = inPredictedRecovery(t)
	if (state ~= "Idle" and state ~= "Blocking" and not recovering) or t < predicted.rollReadyAt then
		return
	end
	if recovering then
		predicted.attacking = false
		predicted.busyUntil = t
	end

	local move = humanoid.MoveDirection * FLAT
	local direction = move.Magnitude > 0.1 and move.Unit or (root.CFrame.LookVector * FLAT).Unit
	local airborne = humanoid.FloorMaterial == Enum.Material.Air
	local anim = dashAnim(root, direction, airborne)

	-- Side dashes near an opponent curve around them (Motion.dash orbit).
	predicted.dashOrbit = nil
	if anim == "DashLeft" or anim == "DashRight" then
		predicted.dashOrbit = findFocus(root, Config.DashOrbitRange)
		predicted.dashOrbitUntil = t + Config.RollDuration + 0.4
	end

	predicted.rollReadyAt = t + Config.RollCooldown
	predicted.rollStarted = t
	if state == "Blocking" then
		predicted.blockReadyAt = t + Config.BlockCooldown
		predicted.blocking = false
	end
	sprinting = false
	playAnim(character, anim)
	Effects.dash(character, direction, airborne)

	local sideways = root.CFrame:VectorToObjectSpace(direction).X
	CameraFX.fovKick(Config.Camera.DashFOV)
	CameraFX.rollKick(-sideways * Config.Camera.DashTilt)
	CameraFX.blur(5)
	send("Roll", { direction = direction, airborne = airborne }, anim)
end

local function tryDoubleJump()
	local character, _, root = getCharacter()
	if not character or predicted.doubleJumped then
		return false
	end
	local t = os.clock()
	if serverState() ~= "Idle" or t < predicted.busyUntil then
		return false
	end
	local state = locomotion[character]
	if not state or state.airborneFor < Config.DoubleJumpWindow then
		return false
	end
	predicted.doubleJumped = true
	local v = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(v.X, Config.DoubleJumpVelocity, v.Z)
	playAnim(character, "DoubleJump")
	Effects.doubleJump(character)
	CameraFX.fovKick(4)
	CameraFX.punch(Vector3.yAxis, 0.3)
	send("DoubleJump", nil, "DoubleJump")
	return true
end

local function doSkill()
	local character = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	if canPredictAction(t) and t >= predicted.skillReadyAt then
		predicted.skillReadyAt = t + Config.Skill.cooldown
		predicted.busyUntil = t + Config.Skill.castTime
		predicted.attackHitAt = t + Config.Skill.release
		predicted.attacking = true
		sprinting = false
		playAnim(character, "SkillCast")
		send("Skill", nil, "SkillCast")
	end
end

local function setSprint(on)
	if sprinting == on then
		return
	end
	sprinting = on
	send("Sprint", on)
end

Remotes.Impulse.OnClientEvent:Connect(function(kind, velocity, duration, delay)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or type(kind) ~= "string" or typeof(velocity) ~= "Vector3" then
		return
	end
	local orbit = nil
	if kind == "dash" and predicted.dashOrbit and os.clock() < predicted.dashOrbitUntil then
		orbit = predicted.dashOrbit
	end
	Motion.apply(root, kind, velocity, duration, delay, orbit)
end)

------------------------------------------------------------------------
-- Input

local shiftLocked = false

local function toggleShiftLock()
	shiftLocked = not shiftLocked
	if not shiftLocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

-- Space: jump after a short buffer unless an M1 turns it into a launcher;
-- in the air it's the double jump.
ContextActionService:BindActionAtPriority("CombatJump", function(_, inputState)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local _, humanoid = getCharacter()
	if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
		tryDoubleJump()
		return Enum.ContextActionResult.Sink
	end

	local pressedAt = os.clock()
	spaceDownAt = pressedAt
	jumpConsumed = false
	task.delay(Config.LauncherBuffer, function()
		if spaceDownAt ~= pressedAt or jumpConsumed then
			return
		end
		local _, h = getCharacter()
		-- ChangeState rather than .Jump: the default control script rewrites
		-- .Jump every frame, and Space is sunk so it never sees the press.
		if h and serverState() == "Idle" and h.JumpHeight > 0
			and h.FloorMaterial ~= Enum.Material.Air then
			h:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end)
	return Enum.ContextActionResult.Sink
end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Space then
		task.delay(Config.LauncherBuffer + 0.02, function()
			if not UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				spaceDownAt = nil
			end
		end)
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		doM1()
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		doFeint()
	elseif input.KeyCode == Enum.KeyCode.R then
		doCritical()
	elseif input.KeyCode == Enum.KeyCode.F then
		blockHeld = true
		blockPressedAt = os.clock()
		doBlock(false)
	elseif input.KeyCode == Enum.KeyCode.Y then
		doSkill()
	elseif input.KeyCode == Enum.KeyCode.Q then
		doRoll()
	elseif input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		toggleShiftLock()
	elseif input.KeyCode == Enum.KeyCode.W then
		local t = os.clock()
		if t - lastWPress <= Config.SprintDoubleTapWindow then
			setSprint(true)
		end
		lastWPress = t
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.F then
		if blockHeld then
			blockHeld = false
			releaseBlock()
		end
	elseif input.KeyCode == Enum.KeyCode.W then
		setSprint(false)
	end
end)

------------------------------------------------------------------------
-- State follow-up: buffering, block resume

local function onStateChanged(character)
	local state = character:GetAttribute("CombatState")

	if state == "Stunned" or state == "Parried" or state == "GuardBroken" then
		predicted.combo = 0
		predicted.attacking = false
		predicted.busyUntil = 0
		sprinting = false
		bufferedM1 = nil
	end
	if state == "GuardBroken" then
		predicted.blocking = false
		predicted.blockReadyAt = os.clock() + Config.GuardBreakStun + Config.BlockCooldown
	end
	if state ~= "Blocking" and predicted.blocking and not blockHeld then
		predicted.blocking = false
	end

	if state == "Idle" then
		predicted.attacking = false
		if blockHeld then
			-- F pressed late in a stun still comes out as a parry the moment it ends
			doBlock(os.clock() - blockPressedAt > Config.BlockBuffer)
		elseif bufferedM1 and os.clock() - bufferedM1 <= Config.InputBufferTime then
			doM1()
		end
	end
end

local function onCharacterAdded(character)
	predicted.combo = 0
	predicted.busyUntil = 0
	predicted.attacking = false
	predicted.doubleJumped = false
	sprinting = false
	blockHeld = false

	character:GetAttributeChangedSignal("CombatState"):Connect(function()
		onStateChanged(character)
	end)

	-- PoseAnimator drives the whole body; Roblox's default animations would
	-- only fight it. The server removes Animate already; this covers setups
	-- that spawn characters some other way.
	local function removeAnimate(child)
		if child.Name == "Animate" and (child:IsA("LocalScript") or child:IsA("Script")) then
			child:Destroy()
		end
	end
	for _, child in ipairs(character:GetChildren()) do
		removeAnimate(child)
	end
	character.ChildAdded:Connect(removeAnimate)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, playing in ipairs(animator:GetPlayingAnimationTracks()) do
			playing:Stop(0)
		end
	end
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end

RunService.Heartbeat:Connect(function()
	local character, humanoid = getCharacter()
	if not character then
		return
	end

	local t = os.clock()
	if bufferedM1 and t - bufferedM1 > Config.InputBufferTime then
		bufferedM1 = nil
	elseif bufferedM1 and canPredictAction(t) then
		doM1()
	end

	-- Holding F through a block cooldown (or a stun) brings the guard back up.
	if blockHeld and serverState() == "Idle" and t >= predicted.blockReadyAt
		and not predicted.attacking and t - predicted.lastBlockTry > 0.03 then
		doBlock(true)
	end

	-- Touching the ground gives the double jump back.
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		predicted.doubleJumped = false
	end
end)

-- Anyone held by the slash skill gets cut from every angle until released.
local nextCut = {}
RunService.Heartbeat:Connect(function()
	local t = os.clock()
	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		if model:GetAttribute("Dismantled") then
			if t >= (nextCut[model] or 0) then
				nextCut[model] = t + math.random(45, 85) / 1000
				Effects.dismantleCut(model)
				local joints = { "Torso", "Head", "RightArm", "LeftArm" }
				PoseAnimator.kick(model, joints[math.random(1, #joints)],
					Vector3.new(math.random(-380, 380), math.random(-260, 260), math.random(-300, 300)))
				if model == player.Character then
					CameraFX.shake(0.12)
				end
			end
		else
			nextCut[model] = nil
		end
	end
end)

------------------------------------------------------------------------
-- Rotation and shift lock (Alt). Shake, FOV and tilt live in CameraFX.

-- You keep turning freely while attacking, blocking and dashing. Only hard
-- stuns take rotation away.
local ROTATION_LOCKED = { Stunned = true, Parried = true, GuardBroken = true, Captured = true, Kneeling = true }

RunService:BindToRenderStep("CombatCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local character, humanoid, root = getCharacter()
	if not character then
		return
	end

	-- Characters are spawned by the server, so the default camera can stay
	-- attached to the old body after a respawn. Always follow the live one.
	camera = workspace.CurrentCamera
	if camera.CameraSubject ~= humanoid then
		camera.CameraSubject = humanoid
		camera.CameraType = Enum.CameraType.Custom
	end

	local offset = Vector3.zero
	local state = serverState()
	local rotationLocked = ROTATION_LOCKED[state] == true
	local t = os.clock()

	local focus
	if not rotationLocked and state == "Rolling" and predicted.dashOrbit
		and predicted.dashOrbit.Parent and t < predicted.dashOrbitUntil then
		-- face the opponent while circling them
		focus = predicted.dashOrbit
	else
		local engaged = predicted.attacking or state == "Attacking" or state == "Blocking"
		focus = engaged and not rotationLocked and not shiftLocked and findFocus(root)
	end

	if focus then
		humanoid.AutoRotate = false
		local position = root.Position
		local goal = CFrame.lookAt(position, Vector3.new(focus.Position.X, position.Y, focus.Position.Z))
		root.CFrame = root.CFrame:Lerp(goal, 1 - math.exp(-Config.AimAssistTurnRate * dt))
	elseif shiftLocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		offset += Config.ShiftLockOffset
		humanoid.AutoRotate = false
		if not rotationLocked then
			local look = camera.CFrame.LookVector * FLAT
			if look.Magnitude > 0.01 then
				local position = root.Position
				root.CFrame = CFrame.lookAt(position, position + look.Unit)
			end
		end
	else
		humanoid.AutoRotate = not rotationLocked
	end

	humanoid.CameraOffset = offset
end)

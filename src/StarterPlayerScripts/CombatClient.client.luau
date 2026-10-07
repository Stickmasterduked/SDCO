--[[
	Client side of the fist combat: input, animation playback for every
	combatant, and impact feedback.

	Own actions are predicted: the animation plays the moment you press the
	key, and the server's Ack corrects it if the server disagrees.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local CombatShared = ReplicatedStorage:WaitForChild("Combat")
local Config = require(CombatShared.Config)
local AnimationData = require(CombatShared.AnimationData)
local PoseAnimator = require(CombatShared.PoseAnimator)
local Effects = require(CombatShared.Effects)
local Motion = require(CombatShared.Motion)
local HUD = require(CombatShared.HUD)
local Remotes = CombatShared:WaitForChild("Remotes")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local FLAT = Vector3.new(1, 0, 1)

Effects.preload()
HUD.createHealthBar(player)

task.spawn(function()
	for _ = 1, 20 do
		if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Health, false) then
			break
		end
		task.wait(0.5)
	end
end)

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
		track:GetMarkerReachedSignal("Swing"):Connect(function()
			local root = model:FindFirstChild("HumanoidRootPart")
			if root then
				Effects.sound("Swing", root, name == "Critical" and 0.6 or 0.4, name == "Critical" and 0.8 or 1)
			end
			Effects.swingTrails(model, (data.markers.Hit - data.markers.Swing) + 0.08)
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
		local fade = data.group == "react" and 0.04 or 0.07
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
	if typeof(model) ~= "Instance" or not model.Parent then
		return
	end
	if stop then
		stopFamily(model, name)
	else
		playAnim(model, name)
	end
end)

-- Stance on every combatant, plus a walk cycle for NPCs (players have Animate).
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
		HUD.attachShield(model)
		if model ~= player.Character then
			HUD.attachMiniBar(model)
		end
	end)
end

CollectionService:GetInstanceAddedSignal("Combatant"):Connect(setupCombatant)
for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
	setupCombatant(model)
end

-- Keeps state-driven tracks in sync: stance always on, block hold while
-- another combatant is blocking (late joiners and missed events recover).
RunService.Heartbeat:Connect(function()
	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		local stance = model.Parent and getTrack(model, "Stance")
		if stance and not stance.IsPlaying then
			stance:Play(0.2)
		end

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

		if not Players:GetPlayerFromCharacter(model) then
			local root = model:FindFirstChild("HumanoidRootPart")
			local walk = root and getTrack(model, "Walk")
			if walk then
				local moving = (root.AssemblyLinearVelocity * FLAT).Magnitude > 2
				if moving and not walk.IsPlaying then
					walk:Play(0.15)
				elseif not moving and walk.IsPlaying then
					walk:Stop(0.2)
				end
			end
		end
	end
end)

------------------------------------------------------------------------
-- Feedback

local shake = 0

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

local function react(kind, attacker, defender)
	local back, side = hitDirection(attacker, defender)
	local function kick(model, joint, p, y, r)
		if typeof(model) == "Instance" and model.Parent then
			PoseAnimator.kick(model, joint, Vector3.new(p, y, r))
		end
	end
	if kind == "Hit" or kind == "HeavyHit" then
		local m = kind == "HeavyHit" and 1.7 or 1
		kick(defender, "Torso", 260 * back * m, math.random(-120, 120), -160 * side * m)
		kick(defender, "Head", 340 * back * m, math.random(-200, 200), 0)
		kick(attacker, "Torso", -60, 0, 0)
	elseif kind == "Block" then
		kick(defender, "RightArm", -260, 0, 60)
		kick(defender, "LeftArm", -260, 0, -60)
		kick(defender, "Torso", 140, 0, 0)
	elseif kind == "Parry" then
		kick(attacker, "Torso", 260, 0, 0)
		kick(attacker, "RightArm", 420, 0, 0)
		kick(attacker, "LeftArm", 420, 0, 0)
		kick(defender, "RightArm", 240, 0, 0)
	elseif kind == "GuardBreak" then
		kick(defender, "Torso", 420, 0, 0)
		kick(defender, "Head", 500, 0, 0)
	end
end

Remotes.Effect.OnClientEvent:Connect(function(kind, position, attacker, defender)
	if typeof(position) ~= "Vector3" then
		return
	end
	react(kind, attacker, defender)
	local amount = Effects.play(kind, position, attacker)
	local character = player.Character
	if character and amount > 0 then
		if defender == character then
			shake = math.max(shake, amount)
		elseif attacker == character then
			shake = math.max(shake, amount * 0.6)
		end
	end
end)

Remotes.Impulse.OnClientEvent:Connect(function(kind, velocity, duration, delay)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or type(kind) ~= "string" or typeof(velocity) ~= "Vector3" then
		return
	end
	Motion.apply(root, kind, velocity, duration, delay)
end)

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
			kind = (predicted.combo % 2 == 0) and "AirPunchRight" or "AirPunchLeft"
		else
			kind = "Downslam"
		end
	elseif launcher then
		kind = "Uppercut"
	elseif sprinting and speed > Config.WalkSpeed + 2 then
		kind = "RunningAttack"
	elseif predicted.combo + 1 >= Config.ComboLength then
		kind = "Flourish"
	else
		kind = (predicted.combo % 2 == 0) and "PunchRight" or "PunchLeft"
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
	local relative = root.CFrame:VectorToObjectSpace(direction)
	local anim
	if relative.Z < -0.5 then
		anim = "RollForward"
	elseif relative.Z > 0.5 then
		anim = "DodgeBack"
	elseif relative.X < 0 then
		anim = "DodgeLeft"
	else
		anim = "DodgeRight"
	end

	predicted.rollReadyAt = t + Config.RollCooldown
	predicted.rollStarted = t
	if state == "Blocking" then
		predicted.blockReadyAt = t + Config.BlockCooldown
		predicted.blocking = false
	end
	sprinting = false
	playAnim(character, anim)
	send("Roll", direction, anim)
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

------------------------------------------------------------------------
-- Input

local shiftLocked = false

local function toggleShiftLock()
	shiftLocked = not shiftLocked
	if not shiftLocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

-- Space: jump after a short buffer unless an M1 turns it into a launcher.
ContextActionService:BindActionAtPriority("CombatJump", function(_, inputState)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local pressedAt = os.clock()
	spaceDownAt = pressedAt
	jumpConsumed = false
	task.delay(Config.LauncherBuffer, function()
		if spaceDownAt ~= pressedAt or jumpConsumed then
			return
		end
		local _, humanoid = getCharacter()
		-- ChangeState rather than .Jump: the default control script rewrites
		-- .Jump every frame, and Space is sunk so it never sees the press.
		if humanoid and serverState() == "Idle" and humanoid.JumpHeight > 0
			and humanoid.FloorMaterial ~= Enum.Material.Air then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
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
	sprinting = false
	blockHeld = false
	character:GetAttributeChangedSignal("CombatState"):Connect(function()
		onStateChanged(character)
	end)
end

player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end

RunService.Heartbeat:Connect(function()
	local character, humanoid, root = getCharacter()
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
					shake = math.max(shake, 0.12)
				end
			end
		else
			nextCut[model] = nil
		end
	end
end)

------------------------------------------------------------------------
-- Aim assist: attacks and guards soft-turn toward the enemy you're facing,
-- so exchanges happen face to face.

local function findFocus(root)
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
				if distance > 0.1 and distance <= Config.AimAssistRange then
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
-- Rotation, shift lock (Alt) and camera shake

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
	if shake > 0.001 then
		local t = os.clock() * 38
		offset = Vector3.new(math.noise(t, 0.3), math.noise(0.7, t), math.noise(t, t)) * shake
		shake = math.max(0, shake - dt * 2.6)
	end

	local state = serverState()
	local rotationLocked = ROTATION_LOCKED[state] == true
	local engaged = predicted.attacking or state == "Attacking" or state == "Blocking"
	local focus = engaged and not rotationLocked and not shiftLocked and findFocus(root)
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

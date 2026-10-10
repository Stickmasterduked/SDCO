--[[
	Client side of the fist combat: input, animation playback for every
	combatant (locomotion included), impact feedback and camera work.

	Own actions are predicted: the animation and effects play the moment you
	press the key, and the server's Ack corrects it if the server disagrees.
	Own hits are predicted too: at the strike's Hit frame this client runs
	the shared hitbox, plays the impact (sound, sparks, hit-stop, camera kick,
	the target's flinch) immediately and reports the hit to the server, which
	validates it. When the server's verdict comes back the same, it's skipped;
	when it differs (a parry, a guard break) the real outcome plays.
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
local Hitbox = require(CombatShared.Hitbox)
local HeadDrive = require(CombatShared.HeadDrive)
local KatanaFX = require(CombatShared.KatanaFX)
local Remotes = CombatShared:WaitForChild("Remotes")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local FLAT = Vector3.new(1, 0, 1)

local updateKatana -- katana visibility (defined with the locomotion loop)
local predicted -- this client's predicted combat state (filled in under "Local prediction")
local equipped = false -- our own fists up/down, predicted
local katanaDrawn = false -- our own katana out (E draws / puts it away), predicted
local shiftLocked = false -- Alt

-- Fists up? Our own body uses the predicted value, everyone else the
-- server's attribute (dummies are always equipped).
local function isEquipped(model)
	if model == player.Character then
		return equipped
	end
	return model:GetAttribute("Equipped") ~= false
end

-- Katana out? Our own body uses the predicted value, everyone else the
-- server's attribute. Sheathed (the default), you fight with your fists.
local function isDrawn(model)
	if model == player.Character then
		return katanaDrawn
	end
	return model:GetAttribute("KatanaDrawn") == true
end

-- Weapon clips: while the katana is drawn a body plays "Katana_<name>"
-- wherever one exists. Callers keep using the plain names.
local function resolveAnim(model, name)
	if model:GetAttribute("Weapon") == "Katana" and isDrawn(model) then
		local variant = "Katana_" .. name
		if AnimationData[variant] then
			return variant
		end
	end
	return name
end

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
	name = resolveAnim(model, name)
	if tracks[name] then
		return tracks[name]
	end
	local track = PoseAnimator.get(model):track(name)

	local data = AnimationData[name]
	if data.katana and data.markers then
		for marker, sound in pairs({ Draw = "KatanaDraw", Sheathe = "KatanaSheathe" }) do
			if data.markers[marker] then
				track:GetMarkerReachedSignal(marker):Connect(function()
					local root = model:FindFirstChild("HumanoidRootPart")
					if root then
						Effects.sound(sound, root, 0.55, 1.05)
					end
				end)
			end
		end
	end
	-- Finisher: the overhead slam hits the ground. Ground-slam VFX where the
	-- blade lands, and a heavy (not overdone) camera hit for whoever's near.
	if name == "Katana_Finisher" and data.markers and data.markers.Hit then
		track:GetMarkerReachedSignal("Hit"):Connect(function()
			local katana = model:FindFirstChild("Katana")
			local blade = katana and katana:FindFirstChild("KatanaBlade")
			local tip = blade and blade:FindFirstChild("BladeTip")
			local root = model:FindFirstChild("HumanoidRootPart")
			if not root then
				return
			end
			local at = tip and tip.WorldPosition or (root.Position + root.CFrame.LookVector * 4.5)
			at = Vector3.new(at.X, math.min(at.Y, root.Position.Y - 1), at.Z)
			Effects.play("Slam", at, model, nil, "Finisher")
			PoseAnimator.hitStop(model, 0.07, 0)
			local character = player.Character
			if model == character then
				CameraFX.shake(0.5)
				CameraFX.punch(-Vector3.yAxis, 0.75)
				CameraFX.fovKick(-5)
				CameraFX.rollKick(math.random() < 0.5 and -3 or 3)
				CameraFX.impactFrame(0.45)
			else
				local own = character and character:FindFirstChild("HumanoidRootPart")
				local near = own and math.clamp(1 - (own.Position - at).Magnitude / 50, 0, 1) or 0
				if near > 0 then
					CameraFX.shake(0.4 * near)
					CameraFX.punch(-Vector3.yAxis, 0.5 * near)
				end
			end
		end)
	end
	if data.katana and not data.skill and data.markers and data.markers.Swing then
		local heavy = name == "Katana_Critical" or name == "Katana_Finisher"
		track:GetMarkerReachedSignal("Swing"):Connect(function()
			local root = model:FindFirstChild("HumanoidRootPart")
			if root then
				-- pitched down a touch: a heavier blade moving more air
				Effects.sound(Config.Sounds.KatanaSwing and "KatanaSwing" or "Swing", root, heavy and 0.85 or 0.68, heavy and 0.8 or 0.9)
			end
			local katana = model:FindFirstChild("Katana")
			local blade = katana and katana:FindFirstChild("KatanaBlade")
			local trail = blade and blade:FindFirstChild("SlashTrail")
			if trail then
				trail.Enabled = true
				local hitAt = data.markers.Hit or data.markers.Swing
				task.delay((hitAt - data.markers.Swing) + (heavy and 0.2 or 0.12), function()
					trail.Enabled = false
				end)
			end
		end)
	end
	-- every strike snaps through its hit frame (hit or whiff): the body
	-- dips into it and the torso/head whip, then wobble back
	if data.markers and data.markers.Hit and data.group == "action" and not data.skill then
		local heavy = name:find("Finisher") or name:find("Critical") or name:find("Downslam")
		track:GetMarkerReachedSignal("Hit"):Connect(function()
			local m = heavy and 1.7 or 1
			if data.katana then
				m *= 1.25 -- the blade's weight drags the body through the cut
			end
			PoseAnimator.kick(model, "Torso", Vector3.new(-360 * m, math.random(-200, 200), math.random(-90, 90)))
			PoseAnimator.kick(model, "Head", Vector3.new(320 * m, math.random(-110, 110), math.random(-120, 120)))
			PoseAnimator.bounce(model, -4.2 * m)
		end)
	end
	if data.katana then
		-- (katana swing sound and trail handled above)
	elseif data.markers and data.markers.Swing then
		local heavy = name == "Critical" or name == "Finisher"
		track:GetMarkerReachedSignal("Swing"):Connect(function()
			local root = model:FindFirstChild("HumanoidRootPart")
			if root then
				Effects.sound("Swing", root, heavy and 0.65 or 0.45, heavy and 0.8 or 1)
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

-- Crossfade times per group. PoseAnimator eases the weights, so these blend
-- out of the body's current pose instead of popping to a clip's first key.
-- Reactions and impact overlays stay quick so a hit still reads instantly.
local FADE_IN = { action = 0.1, react = 0.05, hold = 0.1, overlay = 0.05, base = 0.12 }
local FADE_OUT = 0.12

local function stopGroups(model, groups, except)
	local tracks = tracksByModel[model]
	if not tracks then
		return
	end
	for name, track in pairs(tracks) do
		if name ~= except and track.IsPlaying and groups[AnimationData[name].group] then
			track:Stop(FADE_OUT)
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

local function playAnim(model, name, speed)
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
		stopGroups(model, replaces, resolveAnim(model, name))
	end

	local track = getTrack(model, name)
	if track then
		local fade = FADE_IN[data.group] or 0.08
		if name == "Block" then
			fade *= Config.ParryWindupMultiplier
		end
		if data.group == "hold" and track.IsPlaying then
			return
		end
		track:Play(fade, 1, speed or (name == "Knockback" and 2 or 1))
		if data.skill then
			KatanaFX.begin(model, track, name)
		end
	end
end

local function stopAnim(model, name)
	local tracks = tracksByModel[model]
	if not tracks then
		return
	end
	for _, n in ipairs({ name, "Katana_" .. name }) do
		local track = tracks[n]
		if track and track.IsPlaying then
			track:Stop(0.1)
		end
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

-- Flinches this client already played on someone it hit (see clientHit), so
-- the server's copy of the same reaction doesn't restart it.
local predictedReacts = setmetatable({}, { __mode = "k" })

Remotes.Anim.OnClientEvent:Connect(function(model, name, stop, speed)
	if typeof(model) ~= "Instance" or not model.Parent or type(name) ~= "string" then
		return
	end
	if stop then
		stopFamily(model, name)
	else
		local predicted = predictedReacts[model]
		if predicted and predicted.name == name and os.clock() - predicted.at < 0.5 then
			predictedReacts[model] = nil
			return
		end
		playAnim(model, name, speed)
	end
end)

------------------------------------------------------------------------
-- Locomotion: idle / run / jump / fall / land for every combatant (one run
-- cycle covers walking and sprinting, sped up or slowed to the real speed),
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

	-- idle: always the relaxed idle (the baked Roblox idle in AnimationData),
	-- for everyone, before, between and after fights. The old fists-up
	-- fighting stance is no longer used. It sits under Run/Jump/Fall below,
	-- so movement always shows over it.
	local idle = getTrack(model, "Idle")
	if idle and not idle.IsPlaying then
		idle:Play(0.25)
	end
	local tracks = tracksByModel[model]
	for _, other in ipairs({ "Idle", "Katana_Idle", "Stance" }) do
		local track = tracks and tracks[other]
		if track and track ~= idle and track.IsPlaying then
			track:Stop(0.25)
		end
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
		else
			want = "Run"
			-- Sprinting (Shift) has its own clip. It's picked from real speed so
			-- everyone's sprint shows, with a little hysteresis so it can't flicker
			-- at the threshold. A drawn katana keeps Katana_Run.
			if speed > (state.current == "Sprint" and Config.WalkSpeed + 1.5 or Config.WalkSpeed + 3)
				and resolveAnim(model, "Run") == "Run" then
				want = "Sprint"
			end
		end
	end

	-- (the resolved clip can change under the same name: drawing the katana
	-- mid-run swaps Run for Katana_Run)
	local wantTrack = want and getTrack(model, want) or nil
	if wantTrack ~= state.track then
		if state.track then
			state.track:Stop(state.current == "Jump" and 0.25 or 0.15)
		end
		if wantTrack then
			wantTrack:Play(want == "Fall" and 0.25 or 0.12)
		end
		state.track = wantTrack
	end
	state.current = want

	if want == "Run" or want == "Sprint" then
		local track = wantTrack
		local data = track and AnimationData[track.Name] or AnimationData[want]
		if track and data.speedRef then
			track:AdjustSpeed(math.clamp(speed / data.speedRef, 0.45, 1.6))
		end
	end

	-- dust kicked up by sprinting feet
	if grounded and (want == "Run" or want == "Sprint") and speed > Config.WalkSpeed + 3 then
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
		local track = getTrack(model, "Idle")
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

-- The katana shows while it's drawn: from the draw's grip frame until the
-- sheathe's last slide home. (Local only; the server leaves it visible.)
local katanaShown = setmetatable({}, { __mode = "k" })
local DRAW_AT = AnimationData.Katana_EquipIn and AnimationData.Katana_EquipIn.markers.Draw or 0
local SHEATHE_AT = AnimationData.Katana_EquipOut and AnimationData.Katana_EquipOut.markers.Sheathe or 0

updateKatana = function(model)
	local katana = model:FindFirstChild("Katana")
	if not katana then
		return
	end
	local show = isDrawn(model)
	local tracks = tracksByModel[model]
	local drawing = tracks and tracks.Katana_EquipIn
	local sheathing = tracks and tracks.Katana_EquipOut
	if show and drawing and drawing.IsPlaying and drawing.time < DRAW_AT then
		show = false
	elseif not show and sheathing and sheathing.IsPlaying and sheathing.time < SHEATHE_AT then
		show = true
	end
	if katanaShown[katana] == show then
		return
	end
	katanaShown[katana] = show
	for _, part in ipairs(katana:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = show and 0 or 1
			part.CastShadow = show
		elseif part:IsA("Trail") and not show then
			part.Enabled = false
		end
	end
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
			updateKatana(model)

			-- the guard pose follows the blocking state (our own body also keeps
			-- it while our predicted press is on its way to the server)
			local combatState = model:GetAttribute("CombatState")
			local blocking = combatState == "Blocking"
			if model == player.Character and predicted and predicted.blocking
				and (combatState == "Idle" or combatState == "Rolling" or combatState == "GetUp" or combatState == "Parried") then
				blocking = true
			end
			local block = getTrack(model, "Block")
			if block and blocking ~= block.IsPlaying then
				if blocking then
					block:Play(0.07 * Config.ParryWindupMultiplier)
				else
					block:Stop(0.1)
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
	local function bounce(model, v)
		if isModel(model) then
			PoseAnimator.bounce(model, v)
		end
	end
	-- cartoony on purpose: big snaps that overshoot and wobble back (the
	-- springs are underdamped), plus a whole-body bounce
	if kind == "Hit" or kind == "HeavyHit" then
		local m = kind == "HeavyHit" and 4 or 2.5
		kick(defender, "Torso", 300 * back * m, math.random(-260, 260), -260 * side * m)
		kick(defender, "Head", 460 * back * m, math.random(-380, 380), -200 * side * m)
		kick(defender, "RightArm", 320 * m, 0, 220 * m)
		kick(defender, "LeftArm", 320 * m, 0, -220 * m)
		bounce(defender, kind == "HeavyHit" and -7.5 or -4.8)
		kick(attacker, "Torso", -320, math.random(-150, 150), 0)
		kick(attacker, "Head", -370, 0, 0)
		bounce(attacker, -3.2)
	elseif kind == "Block" then
		kick(defender, "RightArm", -720, 0, 180)
		kick(defender, "LeftArm", -720, 0, -180)
		kick(defender, "Torso", 450, 0, 0)
		bounce(defender, -3.5)
		kick(attacker, "Torso", 350, 0, 0)
		bounce(attacker, 1.6)
	elseif kind == "Parry" then
		kick(attacker, "Torso", 720, 0, 0)
		kick(attacker, "Head", 560, 0, 0)
		kick(attacker, "RightArm", 1050, 0, 0)
		kick(attacker, "LeftArm", 1050, 0, 0)
		bounce(attacker, 3.5)
		kick(defender, "LeftArm", 680, 0, -260)
		kick(defender, "Torso", -280, 0, 0)
		bounce(defender, -2.4)
	elseif kind == "GuardBreak" then
		kick(defender, "Torso", 1050, 0, 0)
		kick(defender, "Head", 1200, 0, 0)
		bounce(defender, -6.5)
	elseif kind == "Slam" then
		kick(defender, "Torso", -920, 0, 0)
		kick(defender, "Head", -1120, 0, 0)
		bounce(defender, -8)
	end
end

-- Both bodies freeze for a few frames when a hit connects.
local function hitStop(kind, attacker, defender, info)
	local duration = Config.HitStop[kind]
	if not duration then
		return
	end
	local skill = Config.KatanaSkills[info]
	local thrown = skill ~= nil and Config.Attacks[info] ~= nil and Config.Attacks[info].projectile == true
	if skill and skill.hitStop and (kind == "Hit" or kind == "HeavyHit") then
		duration = skill.hitStop
	elseif isModel(attacker) and attacker:GetAttribute("Weapon") == "Katana" and isDrawn(attacker) then
		-- a katana cut bites in a little longer: the blade has weight
		duration *= Config.KatanaHitStopMult or 1
	end
	if isModel(defender) then
		PoseAnimator.hitStop(defender, duration, kind == "Block" and 0.1 or 0.28)
	end
	if isModel(attacker) and not thrown then
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

	-- a slam shakes everyone nearby, hardest for the two fighters
	if kind == "Slam" then
		local root = character:FindFirstChild("HumanoidRootPart")
		local near = 0
		if defender == character or attacker == character then
			near = 1
		elseif root then
			near = math.clamp(1 - (root.Position - position).Magnitude / 60, 0, 1)
		end
		if near > 0 then
			CameraFX.shake(0.75 * near)
			CameraFX.punch(-Vector3.yAxis, 0.9 * near)
			CameraFX.fovKick(6 * near)
			CameraFX.flash(0.3 * near, Color3.fromRGB(255, 240, 220))
		end
		return
	end

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
			CameraFX.flash(0.55, IMPACT_TINT.Parry)
			CameraFX.shake(0.12)
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
			CameraFX.shake(0.2)
			CameraFX.fovKick(4)
			CameraFX.flash(0.4, IMPACT_TINT.Parry)
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

-- Full impact feedback for one effect event.
local function playEffect(kind, position, attacker, defender, info)
	react(kind, attacker, defender)
	hitStop(kind, attacker, defender, info)
	if KatanaFX.handles(kind, info) then
		-- the katana skills' own impact (with its own camera cues); a block,
		-- parry or guard break still shows the usual sparks and camera too
		local amount = KatanaFX.impact(kind, position, attacker, defender, info)
		if kind ~= "Hit" and kind ~= "HeavyHit" then
			amount = math.max(amount, Effects.play(kind, position, attacker, defender, info) or 0)
			cameraReact(kind, amount, position, attacker, defender, info)
		end
		return
	end
	local amount = Effects.play(kind, position, attacker, defender, info)
	cameraReact(kind, amount, position, attacker, defender, info)
end

-- attack id -> the effect this client already played for its own hit
local predictedHits = {}

-- Monotonic grant/consumption counters keep an old replicated attribute
-- from giving back a counterattack charge that an Ack already consumed.
local parryM1Token = 0
local parryM1Consumed = 0
local function mergeParryM1(token, consumed)
	if type(token) == "number" then
		parryM1Token = math.max(parryM1Token, token)
	end
	if type(consumed) == "number" then
		parryM1Consumed = math.max(parryM1Consumed, consumed)
	end
end

Remotes.Effect.OnClientEvent:Connect(function(kind, position, attacker, defender, info, attackId, details)
	if type(kind) ~= "string" or typeof(position) ~= "Vector3" then
		return
	end
	local character = player.Character

	-- our own hit, already shown the moment it landed; only a different
	-- verdict (parried, guard broken, dodged) still needs playing
	if attackId ~= nil and attacker == character and predictedHits[attackId] then
		local predicted = predictedHits[attackId]
		predictedHits[attackId] = nil
		if predicted.kind == kind then
			return
		end
	end

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

	-- A parry interrupts our string; an ordinary block lets the next M1
	-- advance to the next clip instead of repeatedly restarting the hook.
	if kind == "Parry" and attacker == character then
		predicted.combo = 0
	end

	-- we parried: the parry is refunded, the next press is live straight away
	if kind == "Parry" and defender == character then
		predicted.parryReadyAt = 0
		predicted.parryUntil = 0
		if type(details) == "table" then
			mergeParryM1(details.parryM1Token, details.parryM1Consumed)
			if details.stunParry then
				predicted.busyUntil = 0
				predicted.attacking = false
				predicted.blocking = false
			end
		end
	end

	playEffect(kind, position, attacker, defender, info)
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
local characterConnections = {}
local characterSequenceFloor = 0

-- SkillHUD observes accepted server cooldowns; it never starts a cosmetic
-- cooldown from a key press or a locally predicted attack.
local skillStatus = {
	Y = { attribute = "GrabReady", duration = Config.HeadDrive.cooldown, activationId = 0 },
	H = { attribute = "SweepReady", duration = Config.Attacks.LowSweep.cooldown, activationId = 0 },
}

predicted = {
	combo = 0,
	lastM1 = 0,
	busyUntil = 0,
	m1ReadyAt = 0,
	attackHitAt = 0,
	attackSpeed = 1,
	attackId = nil,
	attackSourceId = nil,
	attackKind = nil,
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
	headDriveReadyAt = 0,
	doubleJumped = false,
	dashOrbit = nil,
	dashOrbitUntil = 0,
	slamLocked = false, -- used a downslam this airtime
	downslamReadyAt = 0,
	sweepReadyAt = 0,
	rushReadyAt = 0,
	crescentReadyAt = 0,
	lockFacingUntil = 0, -- Lumen Rush's dash holds the body's facing
}

-- The server publishes cooldowns (as server time) on our character; it has
-- the final say, e.g. a whiffed move's shorter cooldown.
local COOLDOWN_ATTRIBUTE = {
	CritReady = "critReadyAt",
	SweepReady = "sweepReadyAt",
	GrabReady = "headDriveReadyAt",
	RushReady = "rushReadyAt",
	CrescentReady = "crescentReadyAt",
}
local function cooldownFromServer(character, attribute)
	local readyAt = character:GetAttribute(attribute)
	if type(readyAt) ~= "number" then
		return 0
	end
	return os.clock() + math.max(0, readyAt - workspace:GetServerTimeNow())
end

-- Server-granted i-frames (dash, downslammed, end of a Head Drive).
local function hasIFrames(model)
	local untilTime = model:GetAttribute("IFramesUntil")
	return type(untilTime) == "number" and workspace:GetServerTimeNow() < untilTime
end

local blockPressedAt = 0

-- Space waits a beat before jumping so Space + M1 can launch instead.
local spaceDownAt = nil
local jumpConsumed = false
local jumpPendingUntil = nil -- a jump press waiting until we're allowed to jump
local justJumpedAt = nil -- when our last ground jump left the floor
local lastGroundM1 = nil -- { at, anim }: a ground strike Space can still turn into an uptilt
local bufferedCrit = nil
local bufferedSweep = nil
local bufferedSkill = nil -- { kind, at }: a katana skill pressed mid-strike
local launcherQueuedAt = nil -- Space pressed mid-chain: the next strike is an uptilt

local sprinting = false
local sprintHeld = false -- Left Shift
local lastSprintSync = 0
local blockHeld = false
local blockSuppressedUntilRelease = false -- a stun-time F press never becomes a held guard
local bufferedM1 = nil

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

-- Chaining doesn't wait for the server: while the server still reports our
-- own strike as Attacking, the next one may start as soon as our predicted
-- recovery ends (the server allows the same, with a little tolerance).
local function canPredictAction(t)
	if t < predicted.busyUntil or t <= predicted.parryUntil then
		return false
	end
	local state = serverState()
	return state == "Idle" or (state == "Attacking" and predicted.attacking)
end

-- Returns the sequence number, which is also the attack id for hit claims.
local function send(action, arg, predictedAnim, kind, attackPrediction)
	sequence += 1
	if predictedAnim then
		pending[sequence] = { anim = predictedAnim, kind = kind, character = player.Character }
		if attackPrediction then
			pending[sequence].attackKind = attackPrediction.attackKind
			pending[sequence].speed = attackPrediction.speed
			pending[sequence].parryM1Token = attackPrediction.parryM1Token
			pending[sequence].sourceAttackId = attackPrediction.sourceAttackId
			pending[sequence].m1ReadyBefore = attackPrediction.m1ReadyBefore
			predicted.attackId = sequence
			predicted.attackSourceId = attackPrediction.sourceAttackId or sequence
		end
	end
	local skillKey = action == "HeadDrive" and "Y" or (action == "LowSweep" and "H" or nil)
	if skillKey and pending[sequence] then
		local record = skillStatus[skillKey]
		record.character = player.Character
		record.requestId = sequence
		record.accepted = nil
		record.sentAt = os.clock()
		record.startedAt = workspace:GetServerTimeNow()
		record.timedOut = false
		pending[sequence].skillKey = skillKey
		pending[sequence].skillCharacter = player.Character
	end
	Remotes.Action:FireServer(action, sequence, arg)
	return sequence
end

local function nextM1Speed(character)
	mergeParryM1(character:GetAttribute("ParryM1Token"), character:GetAttribute("ParryM1Consumed"))
	local reserved = parryM1Consumed
	for _, entry in pairs(pending) do
		if entry.character == character and entry.parryM1Token then
			reserved = math.max(reserved, entry.parryM1Token)
		end
	end
	if parryM1Token > reserved then
		return Config.ParryM1SpeedMultiplier, parryM1Token
	end
	return 1, nil
end

------------------------------------------------------------------------
-- Own hit detection

-- Bumped whenever the current strike is cancelled (feint, stun, parried,
-- rejected), so a pending Hit frame from it does nothing.
local attackToken = 0

local function cancelPredictedHit()
	attackToken += 1
end

-- What the server will most likely decide, from what this client can see.
-- A parry can't be seen coming, so it shows up as the server's correction.
local function predictOutcome(attack, root, target)
	local state = target:GetAttribute("CombatState")
	local targetRoot = target:FindFirstChild("HumanoidRootPart")
	local facing = true
	if targetRoot then
		local toUs = (root.Position - targetRoot.Position) * FLAT
		if toUs.Magnitude > 0.05 then
			facing = (targetRoot.CFrame.LookVector * FLAT).Unit:Dot(toUs.Unit) >= Config.FacingDot
		end
	end
	if facing and state == "Blocking" then
		return "Block", nil
	end
	local heavy = attack.heavy or attack.knockback >= 18 or attack.launcher or attack.slam
	local reaction
	if state ~= "GuardBroken" and state ~= "Grabbed" and not attack.slam then
		if attack.react == "Knockback" or attack.forceReact then
			reaction = attack.react
		elseif not facing then
			reaction = "HitBack"
		else
			reaction = attack.react or "HitFront"
		end
	end
	return heavy and "HeavyHit" or "Hit", reaction
end

-- Where this cast's dash started (the hit is anyone the path passed).
local rushPath = nil
-- Who the last dash cut (the follow-up cuts blink around them).
local rushVictim = nil

local function clientHit(kind, attackId, token)
	if token ~= attackToken then
		return
	end
	local character, _, root = getCharacter()
	if not character then
		return
	end
	local attack = Config.attackFor(kind, character)
	if attack.lunge and attack.lungeAtHit then
		Motion.push(root, (root.CFrame.LookVector * FLAT).Unit * attack.lunge[1], attack.lunge[2])
	end

	local candidates = {}
	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if model ~= character and humanoid and humanoid.Health > 0 then
			table.insert(candidates, model)
		end
	end
	local target
	if attack.rush and rushPath and rushPath.token == token then
		-- whoever the dash passed closest to (it cut straight through them)
		local a, b = rushPath.from, root.Position
		local ab = (b - a) * FLAT
		local best
		for _, model in ipairs(candidates) do
			local other = model:FindFirstChild("HumanoidRootPart")
			if other and math.abs(other.Position.Y - root.Position.Y) < 6 then
				local ap = (other.Position - a) * FLAT
				local along = ab.Magnitude > 0.01 and math.clamp(ap:Dot(ab) / ab:Dot(ab), 0, 1) or 0
				local miss = (ap - ab * along).Magnitude
				if miss <= Config.KatanaSkills.KatanaRush.pathRadius and (not best or miss < best) then
					target, best = model, miss
				end
			end
		end
	else
		target = Hitbox.find(root, attack, candidates)
	end
	if not target or hasIFrames(target) then
		return
	end
	if attack.rush then
		rushVictim = { model = target, at = os.clock() }
	end
	Remotes.Action:FireServer("Hit", nil, { id = attackId, target = target })

	local t = os.clock()
	for id, entry in pairs(predictedHits) do
		if t - entry.at > 3 then
			predictedHits[id] = nil
		end
	end
	local outcome, reaction = predictOutcome(attack, root, target)
	predictedHits[attackId] = { kind = outcome, at = t }
	if reaction then
		predictedReacts[target] = { name = reaction, at = t }
		playAnim(target, reaction)
	end
	if attack.selfLaunch and outcome ~= "Block" then
		Motion.push(root, Vector3.new(0, attack.selfLaunch, 0), 0)
		Motion.hover(root, Config.AirAttackHover, Config.LaunchApexDelay)
	end
	local targetRoot = target:FindFirstChild("HumanoidRootPart")
	local contact = targetRoot.Position:Lerp(root.Position, 0.4) + Vector3.new(0, 0.6, 0)
	playEffect(outcome, contact, character, target, kind)
end

-- Lunges right away (no waiting on the server) and watches the strike's
-- Hit frame on our own animation.
local function armHit(kind, attackId)
	local character, _, root = getCharacter()
	if not character then
		return
	end
	attackToken += 1
	local token = attackToken
	local attack = Config.Attacks[kind]
	if attack.lunge and not attack.lungeAtHit then
		Motion.push(root, (root.CFrame.LookVector * FLAT).Unit * attack.lunge[1], attack.lunge[2])
	end
	local track = getTrack(character, attack.anim)
	if not track then
		return
	end
	local connection
	connection = track:GetMarkerReachedSignal("Hit"):Connect(function()
		connection:Disconnect()
		clientHit(kind, attackId, token)
	end)
	-- a strike cut short never reaches its marker; drop the listener
	task.delay(1.5, function()
		connection:Disconnect()
	end)
end

------------------------------------------------------------------------
-- Head Drive (Y): grab, slam, drag, suplex. You drive your own body through
-- it: the run keeps going forward and turns toward your movement keys (or
-- where the camera points when shift-locked). The victim is placed
-- relative to the attacker every frame on every client, so the two stay
-- locked together whichever way the run goes.

local HD = HeadDrive.T
local activeGrabs = {} -- [attacker model] = playback

local GRAB_EVENTS = {
	{ t = HD.SLAM, kind = "slam" },
	{ t = HeadDrive.DAMAGE[2].t, kind = "scrapeHit" },
	{ t = HeadDrive.DAMAGE[3].t, kind = "scrapeHit" },
	{ t = HeadDrive.DAMAGE[4].t, kind = "scrapeHit" },
	{ t = HeadDrive.DAMAGE[5].t, kind = "scrapeHit" },
	{ t = HD.SLAM_SECOND, kind = "slam" },
	{ t = HD.IMPACT, kind = "slam" },
	{ t = HD.LAND, kind = "slap" },
}
table.sort(GRAB_EVENTS, function(a, b)
	return a.t < b.t
end)

local SCRAPE_EVERY = 0.035
local TURN_RATE = math.rad(240) -- how fast the run turns, per second

local grabParams = RaycastParams.new()
grabParams.FilterType = Enum.RaycastFilterType.Exclude

local function involvesUs(g)
	return g.attacker == player.Character or g.target == player.Character
end

-- The victim's body is pinned locally too, so physics doesn't fight the path.
local function pinLocal(model, on)
	if model == player.Character then
		local root = model:FindFirstChild("HumanoidRootPart")
		if root then
			root.Anchored = on
		end
	end
end

-- While we're the attacker: our body is driven by the move, not walking,
-- and the victim doesn't physically bump into us.
local function holdOwnBody(g, on)
	local humanoid = g.attacker:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = on
	end
	if on then
		g.collisions = {}
		for _, part in ipairs(g.target:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide then
				g.collisions[part] = true
				part.CanCollide = false
			end
		end
	elseif g.collisions then
		for part in pairs(g.collisions) do
			if part.Parent then
				part.CanCollide = true
			end
		end
		g.collisions = nil
	end
end

local function releaseOwnBody(g)
	if g.ownReleased then
		return
	end
	g.ownReleased = true
	holdOwnBody(g, false)
	local root = g.attacker:FindFirstChild("HumanoidRootPart")
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
	end
	-- done: aim assist shouldn't swing us off toward someone else
	predicted.attacking = false
end

local function stopGrabPlayback(attackerModel, finished)
	local g = activeGrabs[attackerModel]
	if not g then
		return
	end
	activeGrabs[attackerModel] = nil
	if not finished then
		stopAnim(g.attacker, "HeadDrive")
		stopAnim(g.target, "HeadDriven")
	end
	if g.mine then
		releaseOwnBody(g)
	end
	pinLocal(g.target, false)
end

local function startGrabPlayback(attackerModel, targetModel, startRel, clock0, id)
	stopGrabPlayback(attackerModel)
	local attackerRoot = attackerModel:FindFirstChild("HumanoidRootPart")
	if not attackerRoot then
		return nil
	end
	local look = attackerRoot.CFrame.LookVector * FLAT
	local g = {
		attacker = attackerModel,
		target = targetModel,
		startRel = startRel,
		clock0 = clock0,
		id = id,
		mine = attackerModel == player.Character,
		nextEvent = 1,
		scrapeAt = HD.DRAG_START,
		scrapes = 0,
		-- our own run
		pos = attackerRoot.Position,
		heading = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1),
		travelled = 0,
	}
	activeGrabs[attackerModel] = g
	local elapsed = math.max(0, os.clock() - clock0)
	for model, clip in pairs({ [attackerModel] = "HeadDrive", [targetModel] = "HeadDriven" }) do
		playAnim(model, clip)
		local track = getTrack(model, clip)
		if track then
			track.time = elapsed
		end
	end
	if g.mine then
		holdOwnBody(g, true)
	end
	pinLocal(targetModel, true)
	return g
end

-- Which way we want the run to go: where the camera points when
-- shift-locked, otherwise our movement keys (nil: keep going straight).
local function desiredHeading(humanoid)
	if shiftLocked then
		local look = workspace.CurrentCamera.CFrame.LookVector * FLAT
		if look.Magnitude > 0.01 then
			return look.Unit
		end
	end
	local move = humanoid.MoveDirection * FLAT
	if move.Magnitude > 0.1 then
		return move.Unit
	end
	return nil
end

-- Moves our own body one frame along the run and returns its CFrame.
local function driveOwnBody(g, t, dt)
	local root = g.attacker:FindFirstChild("HumanoidRootPart")
	local humanoid = g.attacker:FindFirstChildOfClass("Humanoid")

	-- steer while dragging
	if HeadDrive.steerable(t) and humanoid then
		local want = desiredHeading(humanoid)
		if want then
			local angle = math.acos(math.clamp(g.heading:Dot(want), -1, 1))
			local step = math.min(angle, TURN_RATE * dt)
			if step > 1e-4 then
				local sign = g.heading:Cross(want).Y >= 0 and 1 or -1
				g.heading = (CFrame.Angles(0, sign * step, 0) * g.heading).Unit
			end
		end
	end

	-- run forward by however far the move travels this frame
	local exclude = CollectionService:GetTagged("Combatant")
	local fx = workspace:FindFirstChild("CombatFX")
	if fx then
		table.insert(exclude, fx)
	end
	grabParams.FilterDescendantsInstances = exclude

	local total = HeadDrive.travel(t)
	local move = g.heading * math.max(0, total - g.travelled)
	g.travelled = total
	if move.Magnitude > 0 then
		-- walls: slide along them instead of going through
		local wall = workspace:Raycast(g.pos, move.Unit * (move.Magnitude + 1.2), grabParams)
		if wall then
			move -= wall.Normal * (move:Dot(wall.Normal))
			move *= FLAT
		end
		-- ledges: stop rather than drag them off the edge
		local ahead = g.pos + move
		local floor = workspace:Raycast(ahead + Vector3.new(0, 1, 0), Vector3.new(0, -6.5, 0), grabParams)
		if floor and math.abs(floor.Position.Y + 3 - g.pos.Y) < 2 then
			g.pos = Vector3.new(ahead.X, g.pos.Y + (floor.Position.Y + 3 - g.pos.Y) * math.min(1, dt * 20), ahead.Z)
		else
			move = Vector3.zero
		end
	end

	local yaw = math.atan2(-g.heading.X, -g.heading.Z) + HeadDrive.extraYaw(t)
	local cf = CFrame.new(g.pos) * CFrame.Angles(0, yaw, 0)
	if root then
		root.CFrame = cf
		root.AssemblyLinearVelocity = dt > 0 and move / dt or Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
	return cf
end

local function grabEvent(g, kind, targetCF)
	local head = targetCF * Vector3.new(0, 1.5, 0)
	local ours = involvesUs(g)
	if kind == "slam" then
		Effects.grabSlam(head, g.target)
		if ours then
			local victim = g.target == player.Character
			CameraFX.shake(victim and 0.85 or 0.7)
			CameraFX.punch(-Vector3.yAxis, victim and 1.3 or 1.05)
			CameraFX.fovKick(-4)
			CameraFX.rollKick(victim and -2.5 or 2.5)
			CameraFX.impactFrame(0.6)
		end
	elseif kind == "scrapeHit" then
		Effects.bodyFlash(g.target, Color3.fromRGB(255, 240, 225), 0.1, 0.45)
		if ours then
			CameraFX.shake(0.08)
		end
	elseif kind == "slap" then
		Effects.bodySlap(targetCF.Position)
	end
end

-- Before the camera updates, so it follows the bodies this same frame.
RunService:BindToRenderStep("HeadDrive", Enum.RenderPriority.Camera.Value - 2, function(dt)
	for attackerModel, g in pairs(activeGrabs) do
		local attackerRoot = attackerModel:FindFirstChild("HumanoidRootPart")
		local targetRoot = g.target:FindFirstChild("HumanoidRootPart")
		if not attackerModel.Parent or not g.target.Parent or not attackerRoot or not targetRoot then
			stopGrabPlayback(attackerModel)
			continue
		end

		local t = os.clock() - g.clock0
		local attackerCF
		if g.freeCF then
			attackerCF = g.freeCF -- they're free; the victim finishes where it is
		elseif g.mine then
			attackerCF = driveOwnBody(g, t, dt)
		else
			attackerCF = attackerRoot.CFrame
		end
		if t >= HD.ATTACKER_FREE and not g.freeCF then
			g.freeCF = attackerCF
			if g.mine then
				releaseOwnBody(g)
			end
		end

		local targetCF = attackerCF * HeadDrive.relative(math.clamp(t, 0, HD.LENGTH), g.startRel)
		targetRoot.CFrame = targetCF

		while g.nextEvent <= #GRAB_EVENTS and t >= GRAB_EVENTS[g.nextEvent].t do
			grabEvent(g, GRAB_EVENTS[g.nextEvent].kind, targetCF)
			g.nextEvent += 1
		end

		-- the face scraping along the floor: a scrape every few hundredths of
		-- a second, spread along the stretch the head covered this frame
		local head = targetCF * Vector3.new(0, 1.5, 0)
		if t >= HD.DRAG_START and t < HD.DRAG_END + 0.05 then
			local from = g.lastHead or head
			local count = 0
			while g.scrapeAt <= t and g.scrapeAt < HD.DRAG_END + 0.05 do
				count += 1
				g.scrapeAt += SCRAPE_EVERY
			end
			for i = 1, count do
				local at = from:Lerp(head, i / count)
				local u = math.clamp((t - HD.DRAG_START) / (HD.DRAG_END - HD.DRAG_START), 0, 1)
				local strength = 0.4 + 0.6 * math.sin(math.pi * u)
				local direction = (head - from) * FLAT
				Effects.dragScrape(at, direction.Magnitude > 0.01 and direction or attackerCF.LookVector, strength)
				g.scrapes += 1
				if g.scrapes % 3 == 0 then
					Effects.sound("Hit", targetRoot, 0.22, 0.5)
				end
				if involvesUs(g) then
					CameraFX.shake(0.06 * strength)
				end
			end
		end
		g.lastHead = head

		if t >= HD.LENGTH then
			stopGrabPlayback(attackerModel, true)
		end
	end
end)

-- Our hand closed: if someone's there, start the move right now and tell
-- the server (which checks it, and refuses it if they were guarding or mid-dash).
local function clientGrab(attackId, token)
	if token ~= attackToken then
		return
	end
	local character, _, root = getCharacter()
	if not character then
		return
	end
	local candidates = {}
	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if model ~= character and humanoid and humanoid.Health > 0 then
			table.insert(candidates, model)
		end
	end
	local target = Hitbox.find(root, Config.HeadDrive, candidates)
	local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return -- a miss: the reach recovers on its own
	end
	local state = target:GetAttribute("CombatState")
	if state == "Rolling" or state == "Grabbed" or state == "Grabbing" or hasIFrames(target) then
		return -- slips it
	end

	local startCF = root.CFrame
	Remotes.Action:FireServer("Hit", nil, { id = attackId, target = target, start = startCF })

	local toUs = (root.Position - targetRoot.Position) * FLAT
	local facing = toUs.Magnitude < 0.05 or (targetRoot.CFrame.LookVector * FLAT).Unit:Dot(toUs.Unit) >= Config.FacingDot
	if state == "Blocking" and facing then
		-- a held guard stops it; show that now, the server's copy is skipped
		predictedHits[attackId] = { kind = "Block", at = os.clock() }
		playEffect("Block", targetRoot.Position:Lerp(root.Position, 0.4) + Vector3.new(0, 0.6, 0), character, target, "HeadDrive")
		return
	end

	local exclude = CollectionService:GetTagged("Combatant")
	local fx = workspace:FindFirstChild("CombatFX")
	if fx then
		table.insert(exclude, fx)
	end
	local base = HeadDrive.plan(startCF, exclude)
	local g = startGrabPlayback(character, target, base:ToObjectSpace(targetRoot.CFrame), os.clock(), attackId)
	if g then
		g.pos = base.Position -- start standing level on the floor
	end
	predicted.busyUntil = os.clock() + HD.ATTACKER_FREE
	predicted.attacking = true
end

-- Watches the reach's grab frame on our own animation.
local function armGrab(attackId)
	local character = getCharacter()
	if not character then
		return
	end
	attackToken += 1
	local token = attackToken
	local track = getTrack(character, "HeadDriveReach")
	if not track then
		return
	end
	local connection
	connection = track:GetMarkerReachedSignal("Hit"):Connect(function()
		connection:Disconnect()
		clientGrab(attackId, token)
	end)
	task.delay(1.5, function()
		connection:Disconnect()
	end)
end

Remotes.Grab.OnClientEvent:Connect(function(action, a, b, c, d)
	if action == "start" then
		local attackerModel, targetModel, startRel, id = a, b, c, d
		if not isModel(attackerModel) or not isModel(targetModel) or typeof(startRel) ~= "CFrame" then
			return
		end
		local mine = activeGrabs[attackerModel]
		if mine and attackerModel == player.Character and mine.id == id then
			return -- we've been playing it since our own hand closed
		end
		-- everyone else starts now: the attacker's body we see is delayed by
		-- the same trip, so the two line up
		startGrabPlayback(attackerModel, targetModel, startRel, os.clock(), id)
	elseif action == "stop" then
		stopGrabPlayback(a)
	elseif action == "deny" then
		local mine = activeGrabs[player.Character]
		if mine and mine.id == a then
			stopGrabPlayback(player.Character)
			predicted.busyUntil = os.clock() + 0.2
		end
	end
end)

local function setPredictedAttackTiming(kind, speed, timePlayed)
	local attack = Config.Attacks[kind]
	local character = player.Character
	local anim = AnimationData[character and resolveAnim(character, attack.anim) or attack.anim]
	if not anim or not anim.markers or not anim.markers.Hit then
		anim = AnimationData[attack.anim]
	end
	local t = os.clock()
	speed = speed or 1
	timePlayed = timePlayed or 0
	predicted.busyUntil = t + math.max(0, anim.recover - timePlayed) / speed
	if kind == "Finisher" then
		predicted.m1ReadyAt = predicted.busyUntil + Config.M1ChainEndlag
	end
	predicted.attackHitAt = t + (anim.markers.Hit - timePlayed) / speed
	predicted.attackSpeed = speed
	predicted.attackKind = kind
	predicted.attacking = true
	return attack.anim
end

Remotes.Ack.OnClientEvent:Connect(function(id, accepted, anim, details)
	local entry = pending[id]
	pending[id] = nil
	local character = player.Character
	if not character or type(id) ~= "number" or id <= characterSequenceFloor then
		return
	end
	if type(details) == "table" and details.character and details.character ~= character then
		return
	end
	-- An Ack for the previous life must not animate or reset the new one.
	if entry and entry.character ~= character then
		return
	end
	if type(details) == "table" then
		mergeParryM1(details.parryM1Token, details.parryM1Consumed)
	end
	-- A late verdict still releases its reservation and updates the reward
	-- counters, but cannot cancel or rewind the M1 that replaced it. The
	-- original M1's Ack remains relevant to its own launch conversion.
	if entry and entry.kind == "m1" and predicted.attackId ~= id and predicted.attackSourceId ~= id then
		return
	end
	local sourceAck = entry and entry.kind == "m1" and predicted.attackId ~= id and predicted.attackSourceId == id
	local speed = type(details) == "table" and details.speed
	if type(speed) ~= "number" or speed <= 0 then
		speed = entry and entry.speed or 1
	end
	-- Removing a rejected entry also releases its local charge reservation;
	-- the authoritative consumed counter decides whether it can be retried.
	if accepted and entry and entry.kind == "m1" then
		if lastGroundM1 and lastGroundM1.id == id then
			lastGroundM1.speed = speed
		end
		if (anim == entry.anim or sourceAck) and predicted.attacking
			and (predicted.attackId == id or predicted.attackSourceId == id)
			and speed ~= predicted.attackSpeed then
			-- Keep the pose's current time: a speed correction must not restart
			-- the swing or fire a second Hit marker.
			local currentAnim = Config.Attacks[predicted.attackKind].anim
			local track = getTrack(character, currentAnim)
			if track and track.IsPlaying then
				track:AdjustSpeed(speed)
				setPredictedAttackTiming(predicted.attackKind, speed, track.time)
			end
		end
	end
	-- Once converted, the Launch request owns the Uppercut's verdict. The
	-- original M1 can correct its inherited rate, but a corrected ground
	-- clip must never replace the Uppercut or take over its request identity.
	if sourceAck then
		return
	end
	if entry and entry.skillKey then
		local record = skillStatus[entry.skillKey]
		if record.requestId ~= id then
			return -- an old, timed-out request must not cancel a newer strike
		end
		if record.character == character and record.requestId == id then
			record.accepted = accepted == true
			if accepted then
				record.activationId += 1
			end
		end
	end
	if entry and entry.kind == "stunParry" then
		if not accepted and predicted.parryReadyAt == entry.parryReadyPredicted then
			predicted.parryReadyAt = entry.parryReadyBefore
		end
		return
	end

	if entry and entry.kind == "block" then
		-- a repeat press the server turned down because we're already blocking
		-- must not drop the guard
		if not accepted and serverState() ~= "Blocking" then
			predicted.blocking = false
			stopAnim(character, "Block")
		end
		return
	end

	if entry and entry.kind == "equip" then
		if not accepted then
			stopAnim(character, entry.anim)
			equipped = character:GetAttribute("Equipped") == true
			katanaDrawn = character:GetAttribute("KatanaDrawn") == true
		end
		return
	end

	-- only resync the combo count when the server disagreed
	if entry and entry.kind == "m1" and (not accepted or anim ~= entry.anim) then
		predicted.combo = character:GetAttribute("Combo") or predicted.combo
		if entry.attackKind == "Finisher" then
			predicted.m1ReadyAt = entry.m1ReadyBefore or 0
		end
	end
	if entry and entry.kind == "m1" and type(details) == "table" and type(details.m1ReadyAt) == "number" then
		predicted.m1ReadyAt = details.m1ReadyAt > 0
			and os.clock() + math.max(0, details.m1ReadyAt - workspace:GetServerTimeNow()) or 0
	end

	if entry then
		if not accepted then
			stopAnim(character, entry.anim)
			predicted.busyUntil = 0
			predicted.attacking = false
			cancelPredictedHit()
			if entry.anim == "HeadDriveReach" then
				predicted.headDriveReadyAt = cooldownFromServer(character, "GrabReady") -- preserve any real server cooldown
			elseif entry.anim == "Critical" then
				-- refused: don't sit on a cooldown for a move that never happened
				predicted.critReadyAt = cooldownFromServer(character, "CritReady")
			elseif entry.anim == "LowSweep" then
				predicted.sweepReadyAt = cooldownFromServer(character, "SweepReady")
			elseif entry.anim == "Katana_Rush" then
				predicted.rushReadyAt = cooldownFromServer(character, "RushReady")
				predicted.lockFacingUntil = 0
				local root = character:FindFirstChild("HumanoidRootPart")
				if root then
					Motion.stop(root)
				end
			elseif entry.anim == "Katana_Crescent" then
				predicted.crescentReadyAt = cooldownFromServer(character, "CrescentReady")
			elseif entry.anim == "Downslam" then
				predicted.downslamReadyAt = 0
			end
		elseif anim and anim ~= entry.anim then
			stopAnim(character, entry.anim)
			if Config.Attacks[anim] then
				setPredictedAttackTiming(anim, speed)
				predicted.attackId = id
				predicted.attackSourceId = id
			end
			playAnim(character, anim, speed)
			if Config.Attacks[anim] then
				armHit(anim, id)
			end
		end
	elseif accepted and anim then
		if Config.Attacks[anim] then
			setPredictedAttackTiming(anim, speed)
			predicted.attackId = id
			predicted.attackSourceId = id
		end
		playAnim(character, anim, speed)
		-- an attack the server started that we didn't predict: report its hit too
		if Config.Attacks[anim] then
			armHit(anim, id)
		elseif anim == "HeadDriveReach" then
			armGrab(id)
		end
	end
end)

-- Past your own hit frame: block, parry and dash can cut the swing short.
local function inPredictedRecovery(t)
	return predicted.attacking and t > predicted.attackHitAt
end

local function predictAttack(kind, speed)
	predicted.attackId = nil
	predicted.attackSourceId = nil
	-- Every weapon uses its resolved clip, with both the marker and recovery
	-- accelerated for just the accepted counterattack.
	return setPredictedAttackTiming(kind, speed)
end

local function doM1()
	local character, humanoid, root = getCharacter()
	if not character then
		return
	end
	local t = os.clock()

	if t < predicted.m1ReadyAt then
		bufferedM1 = bufferedM1 or t
		return
	end
	if not canPredictAction(t) then
		bufferedM1 = t
		return
	end
	bufferedM1 = nil

	local airborne = humanoid.FloorMaterial == Enum.Material.Air
	-- Space + M1 this close together = uptilt. Space jumps straight away, so
	-- a hop that has only just left the floor still counts as the ground.
	local hopped = justJumpedAt ~= nil and t - justJumpedAt <= Config.LauncherBuffer
	local launcher = spaceDownAt ~= nil and t - spaceDownAt <= Config.LauncherBuffer
		and (not airborne or hopped)
	-- Space pressed during the chain (or still held as the next strike comes
	-- out) makes that next strike the uptilt
	if not launcher and not airborne then
		launcher = (launcherQueuedAt ~= nil and t - launcherQueuedAt <= Config.LauncherQueue)
			or (spaceDownAt ~= nil and UserInputService:IsKeyDown(Enum.KeyCode.Space))
	end
	launcherQueuedAt = nil
	if launcher then
		jumpConsumed = true
		jumpPendingUntil = nil
		airborne = false
		if hopped then
			-- cancel the hop: the uptilt launches you itself when it lands
			local v = root.AssemblyLinearVelocity
			if v.Y > 0 then
				root.AssemblyLinearVelocity = Vector3.new(v.X, 0, v.Z)
			end
		end
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
			-- one downslam per airtime, and a cooldown (same rules as the server)
			if predicted.slamLocked or t < predicted.downslamReadyAt then
				return
			end
			kind = "Downslam"
			predicted.slamLocked = true
			predicted.downslamReadyAt = t + Config.DownslamCooldown
		end
	elseif predicted.combo + 1 >= Config.ComboLength then
		-- the fifth hit is the finisher even with Space held (no uptilt extend)
		kind = "Finisher"
	elseif launcher then
		kind = "Uppercut"
	else
		kind = Config.M1Chain[predicted.combo % #Config.M1Chain + 1]
	end

	predicted.combo += 1
	if Config.Attacks[kind].endsCombo then
		predicted.combo = 0
	end
	predicted.lastM1 = t
	sprinting = false

	-- attacking puts the fists up (the strike's own animation covers it)
	equipped = true
	local speed, boostToken = nextM1Speed(character)
	local m1ReadyBefore = predicted.m1ReadyAt
	local anim = predictAttack(kind, speed)
	playAnim(character, anim, speed)
	local id = send("M1", { launcher = launcher, airborne = airborne }, anim, "m1", {
		attackKind = kind, speed = speed, parryM1Token = boostToken, m1ReadyBefore = m1ReadyBefore,
	})
	armHit(kind, id)
	-- Space right after this (M1 first, then jump) still makes it an uptilt
	if not airborne and Config.Attacks[kind].isM1 and kind ~= "Finisher" and kind ~= "Uppercut" then
		lastGroundM1 = { at = t, anim = anim, id = id, speed = speed }
	else
		lastGroundM1 = nil
	end
end

local function doCritical()
	local character = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	if t < predicted.critReadyAt then
		return -- on cooldown
	end
	if not canPredictAction(t) then
		-- mid-strike or recovering: fire it the moment we're free
		bufferedCrit = t
		return
	end
	bufferedCrit = nil
	predicted.critReadyAt = t + Config.Attacks.Critical.cooldown
	sprinting = false
	equipped = true
	lastGroundM1 = nil
	local anim = predictAttack("Critical")
	playAnim(character, anim)
	CameraFX.fovKick(-2)
	local id = send("Critical", nil, anim)
	armHit("Critical", id)
end

-- H: Low Sweep. Everyone, unless Config lists `owners`.
local function canLowSweep()
	local owners = Config.Attacks.LowSweep.owners
	return owners == nil or owners[player.UserId] == true
end

local function doLowSweep()
	local character = getCharacter()
	if not character or not canLowSweep() then
		return
	end
	local t = os.clock()
	if t < predicted.sweepReadyAt then
		return -- on cooldown
	end
	if not canPredictAction(t) then
		bufferedSweep = t -- fires the moment the current strike lets go
		return
	end
	bufferedSweep = nil
	predicted.sweepReadyAt = t + Config.Attacks.LowSweep.cooldown
	sprinting = false
	equipped = true
	lastGroundM1 = nil
	local anim = predictAttack("LowSweep")
	playAnim(character, anim)
	CameraFX.fovKick(-1.5)
	local id = send("LowSweep", nil, anim)
	armHit("LowSweep", id)
end

-- Katana skills (katana drawn): Z Lumen Rush, X Moonfall Crescent.
local SKILL_ACTION = { KatanaRush = "KatanaRush", KatanaCrescent = "KatanaCrescent" }
local SKILL_READY = { KatanaRush = "rushReadyAt", KatanaCrescent = "crescentReadyAt" }

local function katanaOut(character)
	return character:GetAttribute("Weapon") == "Katana" and katanaDrawn
end

-- The opponent Lumen Rush dashes to: the nearest one within range and close
-- to where you're aiming.
local function rushTarget(root)
	local S = Config.KatanaSkills.KatanaRush
	local look = camera.CFrame.LookVector * FLAT
	if look.Magnitude < 0.01 then
		look = root.CFrame.LookVector * FLAT
	end
	look = look.Unit
	local cosLimit = math.cos(math.rad(S.targetAngle))
	local best, bestScore
	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		if model ~= player.Character then
			local other = model:FindFirstChild("HumanoidRootPart")
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if other and humanoid and humanoid.Health > 0 then
				local offset = (other.Position - root.Position) * FLAT
				local distance = offset.Magnitude
				if distance > 0.5 and distance <= S.targetRange then
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

-- Other fighters stop colliding with us for the dash, so it cuts through
-- them instead of bumping (local only: our own body's physics is ours).
local function ghostThrough(duration)
	local character = player.Character
	local changed = {}
	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		if model ~= character then
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") and part.CanCollide then
					part.CanCollide = false
					table.insert(changed, part)
				end
			end
		end
	end
	task.delay(duration, function()
		for _, part in ipairs(changed) do
			if part.Parent then
				part.CanCollide = true
			end
		end
	end)
end

-- Lumen Rush moves on its clip's Dash marker: through the target and out
-- past them, bowing to a random side so it never reads as a straight line.
local function armRush(token)
	local character = getCharacter()
	local track = character and getTrack(character, Config.Attacks.KatanaRush.anim)
	if not track then
		return
	end
	local S = Config.KatanaSkills.KatanaRush
	local connection
	connection = track:GetMarkerReachedSignal("Dash"):Connect(function()
		connection:Disconnect()
		if token ~= attackToken then
			return -- cancelled (stunned, refused) before it launched
		end
		local _, _, root = getCharacter()
		if not root then
			return
		end
		local direction = root.CFrame.LookVector * FLAT
		direction = direction.Magnitude > 0.01 and direction.Unit or Vector3.new(0, 0, -1)
		local distance = S.maxDistance
		local target = rushTarget(root)
		if target then
			local offset = (target.Position - root.Position) * FLAT
			direction = offset.Unit
			distance = math.clamp(offset.Magnitude + S.passBy, S.minDistance, S.maxDistance)
		end
		root.CFrame = CFrame.lookAt(root.Position, root.Position + direction)
		predicted.lockFacingUntil = os.clock() + S.dashDuration + 0.1
		rushPath = { from = root.Position, token = token }
		ghostThrough(S.dashDuration + 0.25)
		local bend = (S.bend[1] + math.random() * (S.bend[2] - S.bend[1])) * (math.random() < 0.5 and -1 or 1)
		Motion.rush(root, direction * distance, S.dashDuration, bend)
	end)
	task.delay(2, function()
		connection:Disconnect()
	end)
end

-- The dash's cut landed: the server plays Katana_RushFollow, and our own
-- body blinks around the victim for each of its three extra cuts (the
-- server checks nothing about where we stand; the cuts are its own).
local function followRush(character)
	local S = Config.KatanaSkills.KatanaRush
	local clip = AnimationData.Katana_RushFollow
	local track = getTrack(character, "Katana_RushFollow")
	local _, _, root = getCharacter()
	if not clip or not track or not root then
		return
	end
	local victim = rushVictim and os.clock() - rushVictim.at < 3 and rushVictim.model
	if not victim or not victim.Parent then
		victim = nil
		local best = 14
		for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
			local other = model ~= character and model:FindFirstChild("HumanoidRootPart")
			if other and (other.Position - root.Position).Magnitude < best then
				victim, best = model, (other.Position - root.Position).Magnitude
			end
		end
	end
	rushVictim = nil
	local t = os.clock()
	predicted.attacking = true
	predicted.busyUntil = math.max(predicted.busyUntil, t + clip.recover)
	predicted.lockFacingUntil = t + clip.recover
	bufferedSkill = nil
	Motion.stop(root)
	local victimRoot = victim and victim:FindFirstChild("HumanoidRootPart")
	if not victimRoot then
		return
	end
	ghostThrough(clip.recover)
	local connections = {}
	for i, marker in ipairs({ "Cut1", "Cut2", "Cut3" }) do
		table.insert(connections, track:GetMarkerReachedSignal(marker):Connect(function()
			local _, _, body = getCharacter()
			if not body or not victimRoot.Parent or character:GetAttribute("CombatState") ~= "Attacking" then
				return
			end
			local centre = victimRoot.Position
			local around = (body.Position - centre) * FLAT
			around = around.Magnitude > 0.1 and around.Unit or -victimRoot.CFrame.LookVector * FLAT
			local direction = CFrame.Angles(0, math.rad(S.blinkAngles[i] or 0), 0):VectorToWorldSpace(around.Unit)
			local at = Vector3.new(centre.X, body.Position.Y, centre.Z) + direction * S.blinkRadius
			body.CFrame = CFrame.lookAt(at, Vector3.new(centre.X, at.Y, centre.Z))
			body.AssemblyLinearVelocity = Vector3.zero
		end))
	end
	task.delay(clip.recover + 0.5, function()
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end)
end

Remotes.Anim.OnClientEvent:Connect(function(model, name, stop)
	if not stop and name == "Katana_RushFollow" and model == player.Character then
		followRush(model)
	end
end)

local function doKatanaSkill(kind)
	local character = getCharacter()
	if not character or not katanaOut(character) then
		return
	end
	local t = os.clock()
	local field = SKILL_READY[kind]
	if t < predicted[field] then
		return -- on cooldown
	end
	if not canPredictAction(t) then
		bufferedSkill = { kind = kind, at = t } -- fires the moment the current strike lets go
		return
	end
	bufferedSkill = nil
	predicted[field] = t + Config.Attacks[kind].cooldown
	sprinting = false
	lastGroundM1 = nil
	local anim = predictAttack(kind)
	playAnim(character, anim)
	local id = send(SKILL_ACTION[kind], nil, anim)
	if kind == "KatanaRush" then
		-- the cut is found here at its Hit marker, like any strike
		armHit(kind, id)
		armRush(attackToken)
	end
end

local function doFeint()
	local character, _, root = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	local state = serverState()

	-- (the katana skills can't be feinted: the server refuses it, so don't
	-- cancel them here either)
	local skill = predicted.attackKind and Config.Attacks[predicted.attackKind]
	local canFeintAttack = predicted.attacking
		and not (skill and skill.katanaSkill)
		and t < predicted.attackHitAt - Config.FeintLockout / predicted.attackSpeed
		and t >= predicted.feintReadyAt
	-- our own dash just started: don't wait for the server's Rolling state to
	-- arrive (with ping it lands after the window and the cancel was lost)
	local canCancelRoll = not predicted.attacking and (state == "Rolling" or state == "Idle")
		and t - predicted.rollStarted <= Config.RollCancelWindow

	if canFeintAttack then
		predicted.feintReadyAt = t + Config.FeintCooldown
		predicted.attacking = false
		cancelPredictedHit()
		predicted.busyUntil = t + 0.1
		playAnim(character, "Feint")
		send("Feint", nil, "Feint")
	elseif canCancelRoll then
		Motion.stop(root)
		Motion.stopHover(root)
		-- stop circling: no more turning toward the orbit target
		predicted.dashOrbit = nil
		predicted.dashOrbitUntil = 0
		predicted.rollReadyAt = t + Config.RollCancelCooldown
		predicted.busyUntil = t + 0.05
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
	if blockSuppressedUntilRelease then
		return
	end
	if state == "Stunned" then
		-- Only a fresh, timed press can escape ordinary hitstun. The server
		-- checks knockdowns; this never raises a held guard or ends recovery.
		blockSuppressedUntilRelease = true
		if resume or t < predicted.blockReadyAt or t < predicted.parryReadyAt then
			return
		end
		predicted.blocking = false
		local before = predicted.parryReadyAt
		predicted.parryReadyAt = t + Config.ParryWindow + Config.ParryWhiffCooldown
		local id = send("BlockDown", { parryOnly = true }, "Block", "stunParry")
		pending[id].parryReadyBefore = before
		pending[id].parryReadyPredicted = predicted.parryReadyAt
		return
	end
	if t < predicted.blockReadyAt then
		return
	end
	if state ~= "Idle" and state ~= "Rolling" and state ~= "Parried" and state ~= "GetUp" and not recovering then
		return
	end
	predicted.blocking = true

	-- Same pose either way: the press opens the parry window, holding blocks.
	if not resume and t >= predicted.parryReadyAt then
		predicted.parryReadyAt = t + Config.ParryWindow + Config.ParryWhiffCooldown
		predicted.parryUntil = t + Config.ParryWindow
	end
	if recovering then
		predicted.attacking = false
		predicted.busyUntil = t
	end
	-- guarding ends your own string (same as the server)
	predicted.combo = 0
	bufferedM1 = nil
	launcherQueuedAt = nil
	sprinting = false
	equipped = true
	playAnim(character, "Block")
	send("BlockDown", resume == true, "Block", "block")
end

local function releaseBlock()
	local character = player.Character
	if character then
		stopAnim(character, "Block")
	end
	if predicted.blocking then
		local t = os.clock()
		predicted.blockReadyAt = t + Config.BlockCooldown
		-- no M1 straight out of a guard (stops block-cancel loops)
		predicted.busyUntil = math.max(predicted.busyUntil, t + Config.BlockAttackDelay)
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
	if (state ~= "Idle" and state ~= "Blocking" and state ~= "GetUp" and not recovering) or t < predicted.rollReadyAt then
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

	-- Side dashes orbit only with enough space to turn safely.
	predicted.dashOrbit = nil
	predicted.dashOrbitUntil = 0
	if anim == "DashLeft" or anim == "DashRight" then
		local target = findFocus(root, Config.DashOrbitRange)
		if target and ((target.Position - root.Position) * FLAT).Magnitude > Config.DashOrbitMinRange then
			predicted.dashOrbit = target
			predicted.dashOrbitUntil = t + Config.RollDuration * 0.9
		end
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
	-- move now; the server only validates (it no longer sends the dash back)
	if predicted.attacking then
		predicted.attacking = false
		cancelPredictedHit()
	end
	Motion.dash(root, direction * (airborne and Config.AirDashSpeed or Config.RollSpeed), Config.RollDuration * 0.9, predicted.dashOrbit)
	if airborne then
		Motion.hover(root, Config.RollDuration * 0.9)
	end

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

local function doHeadDrive()
	local character = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	if not canPredictAction(t) or t < predicted.headDriveReadyAt then
		return
	end
	predicted.headDriveReadyAt = t + Config.HeadDrive.cooldown
	predicted.busyUntil = t + Config.HeadDrive.whiffRecover
	predicted.attackHitAt = t + HD.GRAB_AT
	predicted.attacking = true
	sprinting = false
	equipped = true
	playAnim(character, "HeadDriveReach")
	local id = send("HeadDrive", nil, "HeadDriveReach")
	armGrab(id)
end

------------------------------------------------------------------------
-- Skill buttons: one input path, with the combat code retaining authority.
-- The HUD owns presentation only. Keyboard and Activated both call its
-- Activate method, which forwards here; it binds no additional Y/H input.
local function getSkillState(key)
	local record = skillStatus[key]
	if not record then
		return { available = false, pressable = false, reason = "UNAVAILABLE", readyAt = 0, duration = 1, pending = false }
	end
	local character = player.Character
	local baseDuration = key == "Y" and Config.HeadDrive.cooldown or Config.Attacks.LowSweep.cooldown
	if record.character ~= character then
		record.character = character
		record.requestId = nil
		record.accepted = nil
		record.sentAt = nil
		record.startedAt = nil
		record.lastReadyAt = 0
		record.duration = baseDuration
		record.timedOut = false
	end
	local value = character and character:GetAttribute(record.attribute)
	local readyAt = type(value) == "number" and value or 0
	local serverNow = workspace:GetServerTimeNow()
	if readyAt ~= record.lastReadyAt then
		if readyAt > serverNow then
			-- The existing server shortens a confirmed miss to WhiffCooldown.
			-- Detect that authoritative correction, including one while pending.
			local shortened = record.lastReadyAt and readyAt < record.lastReadyAt - 0.1
			-- A throttled client might first observe the already-refunded value.
			-- A full cooldown cannot end before sent time + full duration.
			local firstSampleWhiff = record.startedAt and readyAt - record.startedAt < baseDuration - 0.1
			if shortened or firstSampleWhiff then
				record.duration = math.min(baseDuration, Config.WhiffCooldown)
			else
				record.duration = baseDuration
			end
		end
		record.lastReadyAt = readyAt
	end
	local entry = record.requestId and pending[record.requestId]
	local waiting = entry ~= nil and entry.skillCharacter == character and readyAt <= serverNow and not record.timedOut
	if waiting and record.sentAt and os.clock() - record.sentAt >= 3 then
		-- The existing server can silently reject requests at its rate limit.
		-- Recover the HUD latch and predicted clock from server truth, without
		-- manufacturing a cooldown or deleting a possible late Ack's entry.
		record.timedOut = true
		local field = key == "Y" and "headDriveReadyAt" or "sweepReadyAt"
		predicted[field] = cooldownFromServer(character, record.attribute)
		waiting = false
	end
	local queued = key == "H" and bufferedSweep ~= nil and os.clock() - bufferedSweep <= Config.InputBufferTime + 0.15
	local alive = getCharacter() ~= nil
	local free = alive and canPredictAction(os.clock())
	local reason
	if not alive then
		reason = "RESPAWNING"
	elseif player:GetAttribute("InMenu") or player:GetAttribute("DisclaimerOpen") or UserInputService:GetFocusedTextBox() then
		reason = "MENU OPEN"
	elseif key == "H" and not canLowSweep() then
		reason = "UNAVAILABLE"
	elseif readyAt > serverNow then
		reason = "COOLDOWN"
	elseif waiting then
		reason = "ACTIVATING"
	elseif queued then
		reason = "QUEUED"
	elseif not free then
		reason = "RECOVERING"
	end
	-- H remains pressable during recovery because the existing move supports
	-- a short input buffer. It still displays unavailable until it can run.
	local pressable = reason == nil or (key == "H" and (reason == "RECOVERING" or reason == "QUEUED"))
	return {
		available = reason == nil,
		pressable = pressable,
		reason = reason or "READY",
		readyAt = readyAt,
		duration = record.duration,
		pending = waiting,
		queued = queued,
		character = character,
		activationId = record.activationId,
	}
end

local function activateSkill(key)
	local state = getSkillState(key)
	if not state.pressable then
		return false, state.reason
	end
	local before = sequence
	if key == "Y" then
		doHeadDrive()
	elseif key == "H" then
		doLowSweep()
	else
		return false, "UNAVAILABLE"
	end
	if sequence > before then
		return true, "PENDING"
	end
	if key == "H" and bufferedSweep then
		return true, "QUEUED"
	end
	return false, "RECOVERING"
end

local skillHUD = require(CombatShared:WaitForChild("SkillHUD")).mount({
	activate = activateSkill,
	getState = getSkillState,
})
script.Destroying:Connect(function()
	skillHUD:Destroy()
	for _, connection in ipairs(characterConnections) do
		connection:Disconnect()
	end
	table.clear(characterConnections)
end)

local function toggleEquip()
	local character = getCharacter()
	if not character then
		return
	end
	local t = os.clock()
	if serverState() ~= "Idle" or predicted.attacking or predicted.blocking or t < predicted.busyUntil then
		return
	end
	if character:GetAttribute("Weapon") == "Katana" then
		-- E draws the katana / puts it away; fists are the default
		katanaDrawn = not katanaDrawn
		local anim = katanaDrawn and "Katana_EquipIn" or "Katana_EquipOut"
		playAnim(character, anim)
		send("Katana", katanaDrawn, anim, "equip")
		return
	end
	equipped = not equipped
	local anim = equipped and "EquipIn" or "EquipOut"
	playAnim(character, anim)
	send("Equip", equipped, anim, "equip")
end

-- The hotbar (CombatHUD) draws / sheathes the katana through this; returns
-- whether it's drawn afterwards (unchanged if the toggle wasn't allowed).
local katanaToggle = Instance.new("BindableFunction")
katanaToggle.Name = "ToggleKatana"
katanaToggle.OnInvoke = function()
	toggleEquip()
	return katanaDrawn
end
katanaToggle.Parent = script

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

local function toggleShiftLock()
	shiftLocked = not shiftLocked
	if not shiftLocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

-- M1 then Space (within LauncherBuffer, before the strike's hit frame):
-- the strike turns into an uptilt instead of a jump.
local function tryLaunchUpgrade()
	local g = lastGroundM1
	local t = os.clock()
	if not g or t - g.at > Config.LauncherBuffer / g.speed or not predicted.attacking or t >= predicted.attackHitAt then
		return false
	end
	local character = getCharacter()
	if not character then
		return false
	end
	lastGroundM1 = nil
	cancelPredictedHit()
	stopAnim(character, g.anim)
	local anim = predictAttack("Uppercut", g.speed)
	playAnim(character, anim, g.speed)
	local id = send("Launch", nil, anim, "m1", {
		attackKind = "Uppercut", speed = g.speed, sourceAttackId = g.id,
	})
	armHit("Uppercut", id)
	return true
end

-- Jumps the moment it's allowed. A press while we can't jump yet (an attack
-- still ending on the server) waits JumpBuffer seconds instead of dropping.
local function tryJump()
	if not jumpPendingUntil then
		return
	end
	local t = os.clock()
	if jumpConsumed or t > jumpPendingUntil then
		jumpPendingUntil = nil
		return
	end
	local _, h = getCharacter()
	-- ChangeState rather than .Jump: the default control script rewrites
	-- .Jump every frame, and Space is sunk so it never sees the press.
	if h and serverState() == "Idle" and h.JumpHeight > 0 and h.FloorMaterial ~= Enum.Material.Air
		and t >= predicted.busyUntil and not predicted.attacking then
		h:ChangeState(Enum.HumanoidStateType.Jumping)
		justJumpedAt = t
		jumpPendingUntil = nil
	end
end

-- Space: jumps instantly (M1 right after turns it into an uptilt, see
-- doM1); in the air it's the double jump.
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
	if tryLaunchUpgrade() then
		jumpConsumed = true
		return Enum.ContextActionResult.Sink
	end
	-- mid M1 chain on the ground: queue the uptilt for the next strike
	-- instead of a jump that would fire when the chain ends
	-- (only while a strike is really still running, so a jump pressed as the
	-- chain ends is still a jump)
	if (predicted.attacking and pressedAt < predicted.busyUntil) or bufferedM1 ~= nil then
		launcherQueuedAt = pressedAt
		jumpConsumed = true
		return Enum.ContextActionResult.Sink
	end
	jumpPendingUntil = pressedAt + Config.JumpBuffer
	tryJump()
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
	if processed or player:GetAttribute("InMenu") or player:GetAttribute("DisclaimerOpen") then -- no combat input while a menu is up
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
		skillHUD:Activate("Y")
	elseif input.KeyCode == Enum.KeyCode.H then
		skillHUD:Activate("H")
	elseif input.KeyCode == Enum.KeyCode.Q then
		doRoll()
	elseif input.KeyCode.Name == Config.KatanaSkills.KatanaRush.key then
		doKatanaSkill("KatanaRush")
	elseif input.KeyCode.Name == Config.KatanaSkills.KatanaCrescent.key then
		doKatanaSkill("KatanaCrescent")
	elseif input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		toggleShiftLock()
	end
end)

-- Hold Left Shift to sprint. Checked before the `processed` filter (some
-- setups bind Shift), but never while typing in a text box.
UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.LeftShift and not UserInputService:GetFocusedTextBox() then
		sprintHeld = true
		setSprint(true)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.F then
		blockSuppressedUntilRelease = false
		if blockHeld then
			blockHeld = false
			releaseBlock()
		end
	elseif input.KeyCode == Enum.KeyCode.LeftShift then
		sprintHeld = false
		setSprint(false)
	end
end)

------------------------------------------------------------------------
-- State follow-up: buffering, block resume

local function cancelPredictedAction()
	predicted.combo = 0
	predicted.attacking = false
	cancelPredictedHit()
	predicted.busyUntil = 0
	sprinting = false
	bufferedM1 = nil
	bufferedSkill = nil
	predicted.lockFacingUntil = 0
end

-- A downslam interrupts our action without entering Stunned.
Remotes.Anim.OnClientEvent:Connect(function(model, name, stop)
	if model == player.Character and name == "Slammed" and not stop then
		cancelPredictedAction()
		predicted.blocking = false
		predicted.parryUntil = 0
		predicted.dashOrbit = nil
	end
end)

local function onStateChanged(character)
	local state = character:GetAttribute("CombatState")

	if state == "Stunned" or state == "Parried" or state == "GuardBroken" then
		cancelPredictedAction()
	end
	if state == "Stunned" then
		blockSuppressedUntilRelease = blockSuppressedUntilRelease or blockHeld
		predicted.blocking = false
		predicted.parryUntil = 0
	end
	if state == "GuardBroken" then
		predicted.blocking = false
		predicted.blockReadyAt = os.clock() + Config.GuardBreakStun + Config.BlockCooldown
	end
	if state ~= "Blocking" and predicted.blocking and not blockHeld then
		predicted.blocking = false
	end
	-- a dash that ended (or was cancelled) stops steering the body and camera
	if state ~= "Rolling" then
		predicted.dashOrbit = nil
	end

	if state == "Idle" then
		-- an Idle for a strike we've already chained out of doesn't end the new one
		if os.clock() >= predicted.busyUntil then
			predicted.attacking = false
		end
		if blockHeld and not blockSuppressedUntilRelease then
			doBlock(os.clock() - blockPressedAt > Config.BlockBuffer)
		elseif bufferedM1 and os.clock() - bufferedM1 <= Config.InputBufferTime then
			doM1()
		end
	end
end

local function connectCharacter(signal, callback)
	local connection = signal:Connect(callback)
	table.insert(characterConnections, connection)
	return connection
end

local function onCharacterAdded(character)
	for _, connection in ipairs(characterConnections) do
		connection:Disconnect()
	end
	table.clear(characterConnections)
	characterSequenceFloor = sequence
	table.clear(pending)
	parryM1Token = 0
	parryM1Consumed = 0
	mergeParryM1(character:GetAttribute("ParryM1Token"), character:GetAttribute("ParryM1Consumed"))
	-- Cooldowns and buffered presses from a dead character cannot carry into
	-- the next life. Read authoritative values if they already replicated.
	bufferedSweep = nil
	bufferedCrit = nil
	bufferedSkill = nil
	predicted.lockFacingUntil = 0
	for attribute, field in pairs(COOLDOWN_ATTRIBUTE) do
		predicted[field] = cooldownFromServer(character, attribute)
	end
	equipped = false
	katanaDrawn = false
	predicted.combo = 0
	predicted.busyUntil = 0
	predicted.m1ReadyAt = 0
	predicted.attacking = false
	predicted.attackSpeed = 1
	predicted.attackKind = nil
	predicted.attackId = nil
	predicted.attackSourceId = nil
	predicted.blocking = false
	predicted.parryUntil = 0
	predicted.parryReadyAt = 0
	bufferedM1 = nil
	lastGroundM1 = nil
	cancelPredictedHit()
	predicted.doubleJumped = false
	predicted.slamLocked = false
	sprinting = false
	blockHeld = false
	blockSuppressedUntilRelease = false

	connectCharacter(character:GetAttributeChangedSignal("CombatState"), function()
		onStateChanged(character)
	end)
	for _, attribute in ipairs({ "ParryM1Token", "ParryM1Consumed" }) do
		connectCharacter(character:GetAttributeChangedSignal(attribute), function()
			mergeParryM1(character:GetAttribute("ParryM1Token"), character:GetAttribute("ParryM1Consumed"))
		end)
	end

	-- follow the server's cooldowns (whiffs come back sooner)
	for attribute, field in pairs(COOLDOWN_ATTRIBUTE) do
		connectCharacter(character:GetAttributeChangedSignal(attribute), function()
			predicted[field] = cooldownFromServer(character, attribute)
		end)
	end

	-- follow the server when it equips us itself (an unpredicted attack);
	-- skip while our own E press is still on its way
	connectCharacter(character:GetAttributeChangedSignal("Equipped"), function()
		for _, entry in pairs(pending) do
			if entry.kind == "equip" then
				return
			end
		end
		equipped = character:GetAttribute("Equipped") == true
	end)
	connectCharacter(character:GetAttributeChangedSignal("KatanaDrawn"), function()
		for _, entry in pairs(pending) do
			if entry.kind == "equip" then
				return
			end
		end
		katanaDrawn = character:GetAttribute("KatanaDrawn") == true
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
	connectCharacter(character.ChildAdded, removeAnimate)
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
	if bufferedCrit and t - bufferedCrit > Config.InputBufferTime + 0.15 then
		bufferedCrit = nil
	elseif bufferedCrit and canPredictAction(t) then
		doCritical()
	end
	if bufferedSweep and t - bufferedSweep > Config.InputBufferTime + 0.15 then
		bufferedSweep = nil
	elseif bufferedSweep and canPredictAction(t) then
		doLowSweep()
	end
	if bufferedSkill and t - bufferedSkill.at > Config.InputBufferTime + 0.15 then
		bufferedSkill = nil
	elseif bufferedSkill and canPredictAction(t) then
		doKatanaSkill(bufferedSkill.kind)
	end
	tryJump()

	-- Holding F through a block cooldown brings the guard back up. A press
	-- consumed during hitstun must be released before it can become a guard.
	-- A press that landed inside the cooldown still counts as a parry press
	-- (it used to be dropped, which is why a second parry turned into a block).
	if blockHeld and not blockSuppressedUntilRelease and serverState() == "Idle" and t >= predicted.blockReadyAt
		and not predicted.attacking and t - predicted.lastBlockTry > 0.03 then
		-- don't re-send while a press is still waiting on the server's answer
		local waiting = false
		for _, entry in pairs(pending) do
			if entry.kind == "block" then
				waiting = true
				break
			end
		end
		if not waiting then
			doBlock(t - blockPressedAt > Config.BlockBuffer)
		end
	end

	-- Touching the ground gives the double jump and the downslam back.
	if humanoid.FloorMaterial ~= Enum.Material.Air then
		predicted.doubleJumped = false
		predicted.slamLocked = false
	end

	-- Shift held: sprint resumes after anything that dropped it (attacks,
	-- blocks, dashes, stuns), and is re-sent if the server didn't take it.
	if sprintHeld and serverState() == "Idle" and not predicted.attacking
		and not predicted.blocking and t >= predicted.busyUntil then
		if not sprinting then
			setSprint(true)
			lastSprintSync = t
		elseif humanoid.WalkSpeed < Config.SprintSpeed - 0.5 and t - lastSprintSync > 0.3 then
			sprinting = false
			setSprint(true)
			lastSprintSync = t
		end
	end
end)

------------------------------------------------------------------------
-- Rotation and shift lock (Alt). Shake, FOV and tilt live in CameraFX.

-- You can turn freely during ordinary hitstun as well as attacks and dashes.
-- Parries, guard breaks and grabs still lock rotation.
local ROTATION_LOCKED = { Parried = true, GuardBroken = true, Grabbing = true, Grabbed = true }
-- after a side dash around someone, the camera eases round to face them
local recenterTarget = nil
local recenterUntil = nil
local recenterStarted = 0
local lastManualCamera = 0 -- last time the player turned the camera themselves
local manualCameraStick = false
UserInputService.InputChanged:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Thumbstick2 then
		manualCameraStick = input.Position.Magnitude > 0.15
		if manualCameraStick then
			lastManualCamera = os.clock()
		end
		return
	end
	local turning = (input.UserInputType == Enum.UserInputType.MouseMovement
		and (UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter))
		or input.KeyCode == Enum.KeyCode.Thumbstick2
		or input.UserInputType == Enum.UserInputType.Touch
	if turning and input.Delta.Magnitude > 1 then
		lastManualCamera = os.clock()
	end
end)
local assistWeight = 0 -- 0..1: how strongly aim assist is turning us right now
local assistFocus = nil -- the target it's easing toward / away from

RunService:BindToRenderStep("CombatCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local character, humanoid, root = getCharacter()
	if not character then
		return
	end
	if player:GetAttribute("DisclaimerOpen") then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
		humanoid.AutoRotate = false
		return
	end

	-- Characters are spawned by the server, so the default camera can stay
	-- attached to the old body after a respawn. Always follow the live one.
	camera = workspace.CurrentCamera
	if camera.CameraSubject ~= humanoid then
		camera.CameraSubject = humanoid
		camera.CameraType = Enum.CameraType.Custom
	end

	-- in a Head Drive the move owns the body (shift lock steers the run
	-- instead of turning us), but the camera and shift lock keep working
	for _, g in pairs(activeGrabs) do
		if g.attacker == character or g.target == character then
			humanoid.AutoRotate = false
			if shiftLocked then
				UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
				humanoid.CameraOffset = Config.ShiftLockOffset
			else
				humanoid.CameraOffset = Vector3.zero
			end
			return
		end
	end

	local offset = Vector3.zero
	local state = serverState()
	-- (Lumen Rush's dash keeps the facing it launched with)
	local rotationLocked = ROTATION_LOCKED[state] == true or os.clock() < predicted.lockFacingUntil
	local t = os.clock()
	if manualCameraStick then
		lastManualCamera = t
	end

	-- Stop following for the rest of this dash if they get too close.
	local orbit = predicted.dashOrbit
	if orbit and (not orbit.Parent or ((orbit.Position - root.Position) * FLAT).Magnitude <= Config.DashOrbitMinRange) then
		predicted.dashOrbit = nil
		predicted.dashOrbitUntil = 0
	end

	-- Yield both assisted turns together while the player controls the camera.
	local manualDashCamera = predicted.dashOrbit and t - lastManualCamera <= Config.AimAssist.DashCameraInputGrace
	-- Face the opponent and turn the camera only while safely circling them.
	local strafeTarget = state ~= "Stunned" and not manualDashCamera and not rotationLocked and (state == "Rolling" or predicted.rollStarted and t - predicted.rollStarted < 0.15)
		and predicted.dashOrbit and predicted.dashOrbit.Parent and t < predicted.dashOrbitUntil and predicted.dashOrbit or nil

	local focus
	if not strafeTarget then
		local engaged = predicted.attacking or state == "Attacking" or state == "Blocking"
		focus = engaged and not rotationLocked and not shiftLocked and findFocus(root)
	end

	-- Aim assist eases in when you engage and out when you stop, instead of
	-- snapping on at full strength.
	local A = Config.AimAssist
	if focus then
		assistFocus = focus
	end
	local want = focus and 1 or 0
	local fade = want > assistWeight and A.FadeIn or A.FadeOut
	assistWeight += (want - assistWeight) * (1 - math.exp(-fade * dt))
	if assistWeight < 0.02 and not focus then
		assistWeight = 0
		assistFocus = nil
	end
	local easing = state ~= "Stunned" and assistFocus and assistFocus.Parent and not rotationLocked and assistWeight > 0.02
		and not shiftLocked and not manualDashCamera

	if strafeTarget then
		humanoid.AutoRotate = false
		local position = root.Position
		local toTarget = (strafeTarget.Position - position) * FLAT
		local previousFacing = root.CFrame.LookVector * FLAT
		if toTarget.Magnitude > 0.1 and previousFacing.Magnitude > 0.01 then
			local facing = toTarget.Unit
			previousFacing = previousFacing.Unit
			local error = math.atan2(previousFacing:Cross(facing).Y, previousFacing:Dot(facing))
			local limit = math.rad(A.DashFacingMaxTurnRate) * dt
			local turn = math.clamp(error * (1 - math.exp(-A.DashFacingTurnRate * dt)), -limit, limit)
			local rotation = CFrame.Angles(0, turn, 0)
			root.CFrame = CFrame.lookAt(position, position + rotation:VectorToWorldSpace(previousFacing))
			-- Follow the actual character turn, with the same gentle easing.
			-- Manual input pauses the assist briefly rather than cancelling the dash.
			if math.abs(turn) > 1e-4 and t - lastManualCamera > A.DashCameraInputGrace then
				local spin = CFrame.new(position) * rotation * CFrame.new(-position)
				camera.CFrame = spin * camera.CFrame
				camera.Focus = spin * camera.Focus
			end
		end
		if shiftLocked then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			offset += Config.ShiftLockOffset
		end
	elseif easing then
		-- while engaged we own the facing easing out, movement takes back over
		humanoid.AutoRotate = not focus and not rotationLocked
		local position = root.Position
		local target = assistFocus.Position
		local goal = CFrame.lookAt(position, Vector3.new(target.X, position.Y, target.Z))
		local rate = A.TurnRate * assistWeight * assistWeight
		root.CFrame = root.CFrame:Lerp(goal, 1 - math.exp(-rate * dt))
		if shiftLocked then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
			offset += Config.ShiftLockOffset
		end
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


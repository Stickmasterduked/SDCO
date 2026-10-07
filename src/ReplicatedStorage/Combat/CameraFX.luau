--[[
	Client camera feel: subtle all the time, loud only on impact.

	  - FOV widens with speed (sprinting) and kicks out on dashes
	  - the camera tilts slightly into strafes and side dashes, bobs on a sprint
	  - hits punch the camera along the hit direction and shake it
	  - big hits flash an "impact frame" (contrast spike) and a blur pulse

	Everything is layered on top of Roblox's camera without fighting it:
	the offset applied last frame is removed just before the default camera
	updates, then re-applied after it, so nothing accumulates or drifts.
	All strengths scale with Config.Camera.Intensity (0 disables it all).
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local SETTINGS = Config.Camera
local FLAT = Vector3.new(1, 0, 1)
local STEP = 1 / 240

local CameraFX = {}

------------------------------------------------------------------------
-- Springs (substepped so frame drops can't blow them up)

local function spring(stiffness, damping, zero)
	return { pos = zero, vel = zero, k = stiffness, c = damping }
end

local function stepSpring(s, dt)
	while dt > 0 do
		local h = math.min(dt, STEP)
		local accel = -s.pos * s.k - s.vel * s.c
		s.vel += accel * h
		s.pos += s.vel * h
		dt -= h
	end
end

local fovSpring = spring(140, 16, 0)
local rollSpring = spring(160, 15, 0)
local punchMove = spring(220, 18, Vector3.zero) -- studs, camera space
local punchTurn = spring(200, 16, Vector3.zero) -- degrees (pitch, yaw, roll)

local trauma = 0
local sprintBlend = 0
local strafeRoll = 0
local bobClock = 0
local applied = CFrame.identity

local impact = nil
local blur = nil
local impactAmount = 0
local impactTint = Color3.new(1, 1, 1)
local blurAmount = 0

local function intensity()
	return SETTINGS.Intensity or 1
end

------------------------------------------------------------------------
-- API

-- Adds shake. `amount` around 0.1 is a tap, 0.6 a big slam.
function CameraFX.shake(amount)
	trauma = math.min(1, trauma + amount)
end

-- Knocks the camera along `direction` (world space) and tips it, like the
-- shot itself hit the lens.
function CameraFX.punch(direction, strength)
	local camera = workspace.CurrentCamera
	if not camera or direction.Magnitude < 0.001 then
		return
	end
	local dir = camera.CFrame:VectorToObjectSpace(direction.Unit)
	punchMove.vel += dir * strength * 9
	punchTurn.vel += Vector3.new(40 - dir.Y * 70, -dir.X * 90, -dir.X * 60) * strength
end

-- Positive widens the view (speed), negative zooms in (impact focus).
function CameraFX.fovKick(amount)
	fovSpring.vel += amount * 14
end

function CameraFX.rollKick(degrees)
	rollSpring.vel += degrees * 14
end

-- A one-frame-ish contrast spike, optionally tinted.
function CameraFX.impactFrame(strength, tint)
	if not SETTINGS.ImpactFrames then
		return
	end
	impactAmount = math.max(impactAmount, strength)
	impactTint = tint or Color3.new(1, 1, 1)
end

function CameraFX.blur(size)
	blurAmount = math.max(blurAmount, size)
end

------------------------------------------------------------------------
-- Per-frame

local function ensureEffects()
	if not impact or not impact.Parent then
		impact = Instance.new("ColorCorrectionEffect")
		impact.Name = "CombatImpactFrame"
		impact.Parent = Lighting
	end
	if not blur or not blur.Parent then
		blur = Instance.new("BlurEffect")
		blur.Name = "CombatBlur"
		blur.Size = 0
		blur.Parent = Lighting
	end
end

local function localCharacter()
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 then
		return humanoid, root
	end
	return nil
end

local function update(dt)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local scale = intensity()

	stepSpring(fovSpring, dt)
	stepSpring(rollSpring, dt)
	stepSpring(punchMove, dt)
	stepSpring(punchTurn, dt)

	-- movement feel
	local humanoid, root = localCharacter()
	local speedFov, bobOffset, bobRoll = 0, Vector3.zero, 0
	local targetStrafe = 0
	if humanoid and root then
		local velocity = root.AssemblyLinearVelocity * FLAT
		local speed = velocity.Magnitude
		local sprintAmount = math.clamp((speed - Config.WalkSpeed - 1) / (Config.SprintSpeed - Config.WalkSpeed), 0, 1.5)
		sprintBlend += (sprintAmount - sprintBlend) * math.min(1, dt * 6)
		speedFov = sprintBlend * SETTINGS.SprintFOV

		local sideways = camera.CFrame:VectorToObjectSpace(velocity).X
		targetStrafe = -math.clamp(sideways / Config.WalkSpeed, -1.5, 1.5) * SETTINGS.StrafeTilt

		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
		if grounded and sprintBlend > 0.4 then
			bobClock += dt * speed * 0.42
			bobOffset = Vector3.new(0, math.abs(math.sin(bobClock)) * SETTINGS.RunBob * sprintBlend, 0)
			bobRoll = math.sin(bobClock) * 0.35 * sprintBlend
		end
	else
		sprintBlend += (0 - sprintBlend) * math.min(1, dt * 6)
	end
	strafeRoll += (targetStrafe - strafeRoll) * math.min(1, dt * 7)

	-- shake (trauma squared: small hits stay small)
	trauma = math.max(0, trauma - dt * 1.7)
	local shake = trauma * trauma
	local t = os.clock() * 32
	local shakeTurn = Vector3.new(
		math.noise(t, 1.3) * 2.4,
		math.noise(t, 7.1) * 2.4,
		math.noise(t, 13.7) * 3.2
	) * shake
	local shakeMove = Vector3.new(math.noise(t, 21.1), math.noise(t, 31.9), 0) * 0.35 * shake

	local move = (punchMove.pos + shakeMove + bobOffset) * scale
	local turn = (punchTurn.pos + shakeTurn) * scale
	local roll = (strafeRoll + rollSpring.pos + bobRoll) * scale + turn.Z

	applied = CFrame.new(move) * CFrame.Angles(math.rad(turn.X), math.rad(turn.Y), math.rad(roll))
	camera.CFrame *= applied
	camera.FieldOfView = math.clamp(SETTINGS.BaseFOV + (speedFov + fovSpring.pos) * scale, 40, 110)

	-- screen effects
	ensureEffects()
	impactAmount = math.max(0, impactAmount - dt * 9)
	local frame = impactAmount * scale
	impact.Contrast = frame * 0.9
	impact.Saturation = -frame * 0.5
	impact.Brightness = frame * 0.08
	impact.TintColor = Color3.new(1, 1, 1):Lerp(impactTint, math.min(1, frame))
	blurAmount = math.max(0, blurAmount - dt * 40)
	blur.Size = blurAmount * scale
end

local started = false

function CameraFX.start()
	if started then
		return
	end
	started = true

	-- Undo last frame's offset right before the default camera reads the
	-- CFrame, so its own math never sees our shake.
	RunService:BindToRenderStep("CombatCameraFXUndo", Enum.RenderPriority.Camera.Value - 1, function()
		local camera = workspace.CurrentCamera
		if camera and applied ~= CFrame.identity then
			camera.CFrame *= applied:Inverse()
		end
		applied = CFrame.identity
	end)

	RunService:BindToRenderStep("CombatCameraFX", Enum.RenderPriority.Camera.Value + 2, function(dt)
		if intensity() <= 0 then
			return
		end
		update(dt)
	end)
end

return CameraFX

-- Viewport-only previews. Uses the game's authored clips and pose convention,
-- without registering models with the live PoseAnimator or emitting combat events.
-- The HUD owns the one render connection and calls Step; Destroy owns all 3D data.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Combat = ReplicatedStorage:WaitForChild("Combat")
local AnimationData = require(Combat:WaitForChild("AnimationData"))
local AnimationBuilder = require(Combat:WaitForChild("AnimationBuilder"))
local HeadDrive = require(Combat:WaitForChild("HeadDrive"))

local SkillPreview = {}
SkillPreview.__index = SkillPreview

local ROOT_ROTATION = CFrame.fromOrientation(-math.pi / 2, math.pi, 0)
local RIGHT_ROTATION = CFrame.fromOrientation(0, math.pi / 2, 0)
local LEFT_ROTATION = CFrame.fromOrientation(0, -math.pi / 2, 0)
local JOINT_ORDER = { "Torso", "Head", "RightArm", "LeftArm", "RightLeg", "LeftLeg" }
local JOINTS = {
	Torso = { "Torso", CFrame.identity * ROOT_ROTATION, ROOT_ROTATION },
	Head = { "Head", CFrame.new(0, 1, 0) * ROOT_ROTATION, CFrame.new(0, -0.5, 0) * ROOT_ROTATION },
	RightArm = { "Right Arm", CFrame.new(1, 0.5, 0) * RIGHT_ROTATION, CFrame.new(-0.5, 0.5, 0) * RIGHT_ROTATION },
	LeftArm = { "Left Arm", CFrame.new(-1, 0.5, 0) * LEFT_ROTATION, CFrame.new(0.5, 0.5, 0) * LEFT_ROTATION },
	RightLeg = { "Right Leg", CFrame.new(1, -1, 0) * RIGHT_ROTATION, CFrame.new(0.5, 1, 0) * RIGHT_ROTATION },
	LeftLeg = { "Left Leg", CFrame.new(-1, -1, 0) * LEFT_ROTATION, CFrame.new(-0.5, 1, 0) * LEFT_ROTATION },
}
local compiled = {}

local function compile(name)
	if compiled[name] then
		return compiled[name]
	end
	local data = assert(AnimationData[name], "SkillPreview: missing authored clip " .. name)
	local result = { length = data.length, joints = {} }
	for _, joint in ipairs(JOINT_ORDER) do
		local keys, value = {}, { 0, 0, 0 }
		for _, key in ipairs(data.keys) do
			value = key.pose[joint] or value
			table.insert(keys, {
				t = key.t,
				cf = AnimationBuilder.toTransform(joint, value),
				style = key.ease or "Linear",
				direction = key.dir or "In",
			})
		end
		result.joints[joint] = keys
	end
	compiled[name] = result
	return result
end

local function sampleJoint(keys, time)
	if time <= keys[1].t then
		return keys[1].cf
	elseif time >= keys[#keys].t then
		return keys[#keys].cf
	end
	local lo, hi = 1, #keys
	while hi - lo > 1 do
		local mid = (lo + hi) // 2
		if keys[mid].t <= time then
			lo = mid
		else
			hi = mid
		end
	end
	local a, b = keys[lo], keys[hi]
	local alpha = (time - a.t) / (b.t - a.t)
	if a.style == "Constant" then
		alpha = 0
	elseif a.style ~= "Linear" then
		alpha = TweenService:GetValue(alpha, Enum.EasingStyle[a.style], Enum.EasingDirection[a.direction])
	end
	return a.cf:Lerp(b.cf, alpha)
end

local function sample(clip, time)
	local pose = {}
	for _, joint in ipairs(JOINT_ORDER) do
		pose[joint] = sampleJoint(clip.joints[joint], time)
	end
	return pose
end

local function part(parent, name, size, color, transparency)
	local object = Instance.new("Part")
	object.Name = name
	object.Size = size
	object.Color = color
	object.Transparency = transparency or 0
	object.Material = Enum.Material.SmoothPlastic
	object.Anchored = true
	object.CanCollide = false
	object.CanTouch = false
	object.CanQuery = false
	object.CastShadow = false
	object.TopSurface = Enum.SurfaceType.Smooth
	object.BottomSurface = Enum.SurfaceType.Smooth
	object.Parent = parent
	return object
end

local function makeDummy(world, name)
	local model = Instance.new("Model")
	model.Name = name
	-- Match the existing plain R6 preview models and their rounded head mesh.
	local skin = Color3.fromRGB(196, 168, 132)
	local shirt = Color3.fromRGB(110, 92, 72)
	local pants = Color3.fromRGB(52, 48, 46)
	local limbs = {
		Torso = part(model, "Torso", Vector3.new(2, 2, 1), shirt),
		Head = part(model, "Head", Vector3.new(2, 1, 1), skin),
		RightArm = part(model, "Right Arm", Vector3.new(1, 2, 1), skin),
		LeftArm = part(model, "Left Arm", Vector3.new(1, 2, 1), skin),
		RightLeg = part(model, "Right Leg", Vector3.new(1, 2, 1), pants),
		LeftLeg = part(model, "Left Leg", Vector3.new(1, 2, 1), pants),
	}
	for _, limb in pairs(limbs) do
		limb.Material = Enum.Material.Plastic
	end
	local headMesh = Instance.new("SpecialMesh")
	headMesh.Name = "Mesh"
	headMesh.MeshType = Enum.MeshType.FileMesh
	headMesh.MeshId = "rbxassetid://18446596298"
	-- A face image mapped across the whole mesh darkens the entire head.
	-- Use the part's tan color without a texture so the reference head stays plain.
	headMesh.TextureId = ""
	headMesh.VertexColor = Vector3.new(1, 1, 1)
	headMesh.Parent = limbs.Head
	model.PrimaryPart = limbs.Torso
	model.Parent = world
	return { model = model, parts = limbs }
end

local function apply(dummy, root, pose, plantFeet)
	local frames = {}
	local floor = math.huge
	for _, joint in ipairs(JOINT_ORDER) do
		local definition = JOINTS[joint]
		local parent = joint == "Torso" and root or frames.Torso
		local cf = parent * definition[2] * pose[joint] * definition[3]:Inverse()
		frames[joint] = cf
		if plantFeet then
			local size = dummy.parts[joint].Size * 0.5
			local extent = math.abs(cf.RightVector.Y) * size.X
				+ math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z
			floor = math.min(floor, cf.Position.Y - extent)
		end
	end
	-- The authored sweep goes below the R6 floor by a small amount; preview
	-- grounding keeps its planted foot/hand on the display plinth.
	local offset = plantFeet and Vector3.new(0, math.max(0, 0.07 - floor), 0) or Vector3.zero
	for joint, cf in pairs(frames) do
		dummy.parts[joint].CFrame = cf + offset
	end
end

local function makeStage(world, accent)
	local platform = part(world, "DisplayPlinth", Vector3.new(0.09, 8.5, 8.5), Color3.fromRGB(22, 28, 38), 0.1)
	platform.Shape = Enum.PartType.Cylinder
	platform.CFrame = CFrame.new(0, -0.05, -0.4) * CFrame.Angles(0, 0, math.pi / 2)
	local surface = part(world, "StageSurface", Vector3.new(0.035, 8.15, 8.15), accent:Lerp(Color3.fromRGB(22, 28, 38), 0.84), 0.15)
	surface.Shape = Enum.PartType.Cylinder
	surface.CFrame = CFrame.new(0, 0.01, -0.4) * CFrame.Angles(0, 0, math.pi / 2)
end

function SkillPreview.new(viewport, key, accent)
	assert(viewport:IsA("ViewportFrame"), "SkillPreview requires a ViewportFrame")
	assert(key == "Y" or key == "H", "SkillPreview requires Y or H")
	local world = Instance.new("WorldModel")
	world.Name = "SkillPreviewWorld"
	world.Parent = viewport
	local camera = Instance.new("Camera")
	camera.Name = "SkillPreviewCamera"
	camera.FieldOfView = 32
	camera.CFrame = CFrame.lookAt(Vector3.new(10.7, 8.4, -15.4), Vector3.new(0.4, 2, -0.6))
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.Ambient = Color3.fromRGB(167, 177, 196)
	viewport.LightColor = Color3.fromRGB(255, 241, 213)
	viewport.LightDirection = Vector3.new(-1, -2, -3).Unit
	viewport.BackgroundTransparency = 1
	makeStage(world, accent)
	local self = setmetatable({
		viewport = viewport,
		world = world,
		camera = camera,
		key = key,
		active = true,
		time = key == "H" and 0.1 or 0,
		destroyed = false,
		attacker = makeDummy(world, "SkillDummy"),
		clips = {},
	}, SkillPreview)
	self.clips.LowSweep = compile("LowSweep")
	self.guard = sample(self.clips.LowSweep, 0)
	if key == "Y" then
		self.target = makeDummy(world, "TrainingOpponent")
		self.clips.HeadDriveReach = compile("HeadDriveReach")
		self.clips.HeadDrive = compile("HeadDrive")
		self.clips.HeadDriven = compile("HeadDriven")
	end
	self:Step(0)
	return self
end

function SkillPreview:SetActive(active)
	self.active = active == true
end

function SkillPreview:Replay()
	if self.destroyed then
		return
	end
	self.time = 0.32
	self.active = true
end

function SkillPreview:Step(dt)
	if self.destroyed or not self.viewport.Parent then
		return
	end
	if self.active then
		self.time += math.clamp(dt, 0, 0.1) * 0.85
	end
	local root = CFrame.new(-0.55, 3, 0.45)
	if self.key == "H" then
		local duration = self.clips.LowSweep.length
		local t = self.time % (0.32 + duration + 0.85) - 0.32
		-- Reset the complete pose immediately when the clip ends.
		local pose = t >= 0 and t < duration and sample(self.clips.LowSweep, t) or self.guard
		apply(self.attacker, CFrame.new(0, 3, 0) * CFrame.Angles(0, math.rad(-18), 0), pose, true)
		return
	end

	local reach = HeadDrive.T.GRAB_AT
	local motionLength = math.max(self.clips.HeadDrive.length, self.clips.HeadDriven.length)
	local t = self.time % (0.32 + reach + motionLength + 1.1) - 0.32
	local startRelative = CFrame.new(0, 0, -2.4) * CFrame.Angles(0, math.pi, 0)
	local attackerPose, targetPose = self.guard, self.guard
	local attackerRoot, targetRoot = root, root * startRelative
	if t >= 0 and t < reach then
		attackerPose = sample(self.clips.HeadDriveReach, t)
	elseif t >= reach and t < reach + motionLength then
		local motionTime = math.clamp(t - reach, 0, motionLength)
		-- Same grab/slam path as combat. Only the forward display travel is
		-- reduced, so both dummies remain in this compact camera composition.
		local a, b = HeadDrive.sample(math.min(motionTime, HeadDrive.T.LENGTH), 1.25, startRelative)
		attackerRoot, targetRoot = root * a, root * b
		attackerPose = sample(self.clips.HeadDrive, motionTime)
		targetPose = sample(self.clips.HeadDriven, motionTime)
	end
	-- Outside the move, assign the starting roots/poses directly; no return tween.
	apply(self.attacker, attackerRoot, attackerPose, true)
	apply(self.target, targetRoot, targetPose, true)
end

function SkillPreview:Destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true
	if self.viewport.CurrentCamera == self.camera then
		self.viewport.CurrentCamera = nil
	end
	self.world:Destroy()
	self.camera:Destroy()
	self.attacker = nil
	self.target = nil
end

return SkillPreview

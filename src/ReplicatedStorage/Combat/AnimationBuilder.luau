--[[
	Pose math shared by PoseAnimator (which plays the animations in game),
	plus an optional KeyframeSequence export of AnimationData for anyone who
	wants to open a move in Roblox's Animation Editor. The game itself never
	needs uploaded animation assets.
]]

local AnimationData = require(script.Parent.AnimationData)

local AnimationBuilder = {}

-- Joint rest rotations of the standard R6 rig (C0 and C1 share them).
local ROOT_ROTATION = CFrame.fromOrientation(-math.pi / 2, math.pi, 0)
local RIGHT_ROTATION = CFrame.fromOrientation(0, math.pi / 2, 0)
local LEFT_ROTATION = CFrame.fromOrientation(0, -math.pi / 2, 0)

local JOINTS = {
	Torso = { part = "Torso", rotation = ROOT_ROTATION },
	Head = { part = "Head", rotation = ROOT_ROTATION },
	RightArm = { part = "Right Arm", rotation = RIGHT_ROTATION },
	LeftArm = { part = "Left Arm", rotation = LEFT_ROTATION },
	RightLeg = { part = "Right Leg", rotation = RIGHT_ROTATION },
	LeftLeg = { part = "Left Leg", rotation = LEFT_ROTATION },
}

local LIMBS = { "Head", "RightArm", "LeftArm", "RightLeg", "LeftLeg" }

-- Pose easing only supports a few curves; map the authored names onto them.
local EASING = {
	Linear = Enum.PoseEasingStyle.Linear,
	Constant = Enum.PoseEasingStyle.Constant,
	Quad = Enum.PoseEasingStyle.CubicV2,
	Cubic = Enum.PoseEasingStyle.CubicV2,
	Quart = Enum.PoseEasingStyle.CubicV2,
	Quint = Enum.PoseEasingStyle.CubicV2,
	Exponential = Enum.PoseEasingStyle.CubicV2,
	Circular = Enum.PoseEasingStyle.CubicV2,
	Back = Enum.PoseEasingStyle.CubicV2,
	Sine = Enum.PoseEasingStyle.CubicV2,
	Elastic = Enum.PoseEasingStyle.Elastic,
	Bounce = Enum.PoseEasingStyle.Bounce,
}

-- PoseAnimator has an in-between priority Roblox doesn't.
local PRIORITY = {
	MovementOverlay = Enum.AnimationPriority.Movement,
}

-- Converts a parent-space pose into the Motor6D.Transform the pose represents.
function AnimationBuilder.toTransform(joint, value)
	local rx, ry, rz = math.rad(value[1] or 0), math.rad(value[2] or 0), math.rad(value[3] or 0)
	local offset = CFrame.new(value[4] or 0, value[5] or 0, value[6] or 0) * CFrame.Angles(rx, ry, rz)
	local rotation = JOINTS[joint].rotation
	return rotation:Inverse() * offset * rotation
end

local function usedJoints(data)
	local used = {}
	for _, key in ipairs(data.keys) do
		for joint in pairs(key.pose) do
			used[joint] = true
		end
	end
	return used
end

local function makePose(joint, value, used, key)
	local pose = Instance.new("Pose")
	pose.Name = JOINTS[joint].part
	if used and value then
		pose.CFrame = AnimationBuilder.toTransform(joint, value)
		pose.Weight = 1
	else
		pose.Weight = 0
	end
	pose.EasingStyle = EASING[key.ease or "Linear"] or Enum.PoseEasingStyle.Linear
	pose.EasingDirection = Enum.PoseEasingDirection[key.dir or "In"]
	return pose
end

function AnimationBuilder.build(name)
	local data = AnimationData[name]
	assert(data, "Unknown animation " .. tostring(name))

	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = name
	sequence.Loop = data.looped == true
	local priority = data.priority or "Action"
	sequence.Priority = PRIORITY[priority] or Enum.AnimationPriority[priority]

	local used = usedJoints(data)
	local last = {}

	for _, key in ipairs(data.keys) do
		for joint in pairs(used) do
			if key.pose[joint] then
				last[joint] = key.pose[joint]
			end
		end

		local keyframe = Instance.new("Keyframe")
		keyframe.Time = key.t

		local root = Instance.new("Pose")
		root.Name = "HumanoidRootPart"
		root.Weight = 0

		local torso = makePose("Torso", last.Torso or { 0, 0, 0 }, used.Torso, key)
		for _, joint in ipairs(LIMBS) do
			if used[joint] then
				makePose(joint, last[joint] or { 0, 0, 0 }, true, key).Parent = torso
			end
		end
		torso.Parent = root
		root.Parent = keyframe

		if data.markers then
			for markerName, time in pairs(data.markers) do
				if math.abs(time - key.t) < 1e-4 then
					local marker = Instance.new("KeyframeMarker")
					marker.Name = markerName
					marker.Parent = keyframe
				end
			end
		end

		keyframe.Parent = sequence
	end

	return sequence
end

return AnimationBuilder

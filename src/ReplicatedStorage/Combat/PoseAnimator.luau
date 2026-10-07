--[[
	Plays AnimationData directly on a character's joints, with no uploaded
	animation assets. Works the same in Studio and in live servers.

	Each frame, after Roblox's own Animator has run (default walk/idle), the
	active tracks are layered on top by priority with fade weights, and the
	result is written to Motor6D.Transform. Tracks mimic the parts of the
	AnimationTrack API the combat client uses: Play, Stop, IsPlaying,
	GetMarkerReachedSignal.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AnimationData = require(script.Parent.AnimationData)
local AnimationBuilder = require(script.Parent.AnimationBuilder)

local PRIORITY = {
	Core = 0, Idle = 1, Movement = 2, Action = 3, Action2 = 4, Action3 = 5, Action4 = 6,
}

local JOINT_BY_PART = {
	Torso = "Torso",
	Head = "Head",
	["Right Arm"] = "RightArm",
	["Left Arm"] = "LeftArm",
	["Right Leg"] = "RightLeg",
	["Left Leg"] = "LeftLeg",
}

------------------------------------------------------------------------
-- Compiled clips: per joint, a list of { t, cframe, style, direction }

local clips = {}

local function compile(name)
	if clips[name] then
		return clips[name]
	end
	local data = AnimationData[name]
	assert(data, "Unknown animation " .. tostring(name))

	local joints = {}
	for _, key in ipairs(data.keys) do
		for joint, value in pairs(key.pose) do
			joints[joint] = joints[joint] or {}
		end
	end

	local last = {}
	for _, key in ipairs(data.keys) do
		for joint, list in pairs(joints) do
			last[joint] = key.pose[joint] or last[joint] or { 0, 0, 0 }
			table.insert(list, {
				t = key.t,
				cframe = AnimationBuilder.toTransform(joint, last[joint]),
				style = key.ease or "Linear",
				direction = key.dir or "In",
			})
		end
	end

	local markers = {}
	if data.markers then
		for markerName, time in pairs(data.markers) do
			table.insert(markers, { name = markerName, t = time })
		end
	end

	local clip = {
		name = name,
		joints = joints,
		length = data.length,
		looped = data.looped == true,
		priority = PRIORITY[data.priority or "Action"] or 3,
		markers = markers,
	}
	clips[name] = clip
	return clip
end

local function ease(alpha, style, direction)
	if style == "Linear" or style == "Constant" then
		return style == "Constant" and 0 or alpha
	end
	local easingStyle = Enum.EasingStyle[style] or Enum.EasingStyle.Quad
	local easingDirection = Enum.EasingDirection[direction] or Enum.EasingDirection.In
	return TweenService:GetValue(alpha, easingStyle, easingDirection)
end

local function sample(keys, time)
	if time <= keys[1].t then
		return keys[1].cframe
	end
	for i = 1, #keys - 1 do
		local a, b = keys[i], keys[i + 1]
		if time < b.t then
			local alpha = (time - a.t) / (b.t - a.t)
			return a.cframe:Lerp(b.cframe, ease(alpha, a.style, a.direction))
		end
	end
	return keys[#keys].cframe
end

------------------------------------------------------------------------
-- Tracks

local Track = {}
Track.__index = Track

function Track:Play(fadeTime)
	self.time = 0
	self.firedMarkers = {}
	self.IsPlaying = true
	self.targetWeight = 1
	self.fadeTime = fadeTime or 0.1
	self.order = self.controller:nextOrder()
	if self.fadeTime <= 0 then
		self.weight = 1
	end
	self.controller.active[self] = true
end

function Track:Stop(fadeTime)
	self.IsPlaying = false
	self.targetWeight = 0
	self.fadeTime = fadeTime or 0.1
	if self.fadeTime <= 0 then
		self.weight = 0
	end
end

function Track:GetMarkerReachedSignal(markerName)
	local track = self
	return {
		Connect = function(_, callback)
			track.markerHandlers[markerName] = callback
		end,
	}
end

function Track:step(dt)
	local clip = self.clip

	if self.weight ~= self.targetWeight then
		local rate = self.fadeTime > 0 and dt / self.fadeTime or 1
		if self.weight < self.targetWeight then
			self.weight = math.min(self.targetWeight, self.weight + rate)
		else
			self.weight = math.max(self.targetWeight, self.weight - rate)
		end
	end

	if not self.IsPlaying and self.weight <= 0 then
		return false
	end

	local previous = self.time
	self.time += dt

	for _, marker in ipairs(clip.markers) do
		if not self.firedMarkers[marker.name] and previous <= marker.t and self.time >= marker.t then
			self.firedMarkers[marker.name] = true
			local handler = self.IsPlaying and self.markerHandlers[marker.name]
			if handler then
				task.spawn(handler)
			end
		end
	end

	if self.time >= clip.length then
		if clip.looped then
			self.time %= clip.length
			self.firedMarkers = {}
		elseif self.IsPlaying then
			self.time = clip.length
			self:Stop(0.1)
		end
	end
	return true
end

------------------------------------------------------------------------
-- Controllers (one per character)

local Controller = {}
Controller.__index = Controller

local controllers = {}

function Controller:nextOrder()
	self.counter += 1
	return self.counter
end

function Controller:findMotors()
	self.motors = {}
	for _, motor in ipairs(self.model:GetDescendants()) do
		if motor:IsA("Motor6D") and motor.Part1 then
			local joint = JOINT_BY_PART[motor.Part1.Name]
			if joint then
				self.motors[joint] = motor
			end
		end
	end
end

function Controller:track(name)
	local track = self.tracks[name]
	if not track then
		track = setmetatable({
			controller = self,
			clip = compile(name),
			Name = name,
			time = 0,
			weight = 0,
			targetWeight = 0,
			fadeTime = 0.1,
			order = 0,
			IsPlaying = false,
			markerHandlers = {},
			firedMarkers = {},
		}, Track)
		self.tracks[name] = track
	end
	return track
end

------------------------------------------------------------------------
-- Procedural layer: breathing, momentum lean and damped springs that hits
-- and impacts "kick", so the body reacts physically on top of the clips.

local SPRING_STIFFNESS = 260
local SPRING_DAMPING = 17

function Controller:kick(joint, impulse)
	local spring = self.springs[joint]
	if not spring then
		spring = { pos = Vector3.zero, vel = Vector3.zero }
		self.springs[joint] = spring
	end
	spring.vel += impulse
end

function Controller:procedural(dt)
	self.clock += dt
	local offsets = {}

	local function add(joint, pitch, yaw, roll, x, y, z)
		local o = offsets[joint]
		if not o then
			o = { 0, 0, 0, 0, 0, 0 }
			offsets[joint] = o
		end
		o[1] += pitch or 0
		o[2] += yaw or 0
		o[3] += roll or 0
		o[4] += x or 0
		o[5] += y or 0
		o[6] += z or 0
	end

	-- breathing
	local breath = math.sin(self.clock * math.pi * 2 * 0.3)
	add("Torso", -breath * 0.9, 0, 0, 0, breath * 0.03, 0)
	add("Head", breath * 1.2, 0, 0)
	add("RightArm", breath * 1.6, 0, 0)
	add("LeftArm", breath * 1.6, 0, 0)

	-- lean into movement, arms trail a little behind
	local root = self.model:FindFirstChild("HumanoidRootPart")
	if root then
		local localVel = root.CFrame:VectorToObjectSpace(root.AssemblyLinearVelocity)
		local target = Vector3.new(-localVel.Z, 0, localVel.X)
		self.lean = self.lean:Lerp(target, math.min(1, dt * 8))
		local forward = math.clamp(self.lean.X, -30, 30)
		local side = math.clamp(self.lean.Z, -30, 30)
		add("Torso", -forward * 0.32, 0, side * 0.3)
		add("Head", forward * 0.18, 0, -side * 0.15)
		add("RightArm", -forward * 0.25, 0, 0)
		add("LeftArm", -forward * 0.25, 0, 0)
	end

	-- springs
	for joint, spring in pairs(self.springs) do
		local accel = -spring.pos * SPRING_STIFFNESS - spring.vel * SPRING_DAMPING
		spring.vel += accel * dt
		spring.pos += spring.vel * dt
		if spring.pos.Magnitude < 0.01 and spring.vel.Magnitude < 0.1 then
			self.springs[joint] = nil
		else
			add(joint, spring.pos.X, spring.pos.Y, spring.pos.Z)
		end
	end

	return offsets
end

function Controller:step(dt)
	local layers = {}
	for track in pairs(self.active) do
		if track:step(dt) then
			table.insert(layers, track)
		else
			self.active[track] = nil
		end
	end

	table.sort(layers, function(a, b)
		if a.clip.priority ~= b.clip.priority then
			return a.clip.priority < b.clip.priority
		end
		return a.order < b.order
	end)

	local humanoid = self.model:FindFirstChildOfClass("Humanoid")
	local alive = humanoid and humanoid.Health > 0
	local offsets = alive and self:procedural(dt) or {}

	for joint, motor in pairs(self.motors) do
		if motor.Parent then
			-- Players have Roblox's Animate script driving walk/idle underneath;
			-- dummies don't, so their unanimated joints rest at neutral.
			local result = self.hasBaseAnimator and motor.Transform or CFrame.identity
			for _, track in ipairs(layers) do
				local keys = track.clip.joints[joint]
				if keys and track.weight > 0 then
					result = result:Lerp(sample(keys, track.time), track.weight)
				end
			end
			local offset = offsets[joint]
			if offset then
				result = result * AnimationBuilder.toTransform(joint, offset)
			end
			motor.Transform = result
		end
	end
end

local PoseAnimator = {}

-- Adds a physical jolt to a joint: impulse is degrees/second as
-- Vector3(pitch, yaw, roll) in the same convention as AnimationData.
function PoseAnimator.kick(model, joint, impulse)
	local controller = PoseAnimator.get(model)
	controller:kick(joint, impulse)
end

function PoseAnimator.get(model)
	local controller = controllers[model]
	if controller then
		return controller
	end
	controller = setmetatable({
		model = model,
		tracks = {},
		active = {},
		motors = {},
		counter = 0,
		springs = {},
		clock = math.random() * 10,
		lean = Vector3.zero,
		hasBaseAnimator = model:FindFirstChild("Animate") ~= nil,
	}, Controller)
	controller:findMotors()
	controllers[model] = controller

	model.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Motor6D") then
			controller:findMotors()
		elseif descendant.Name == "Animate" then
			controller.hasBaseAnimator = true
		end
	end)
	model.Destroying:Once(function()
		controllers[model] = nil
	end)
	return controller
end

-- PreSimulation runs after Roblox's Animator has written this frame's
-- transforms, so writing here layers combat poses on top of them.
RunService.PreSimulation:Connect(function(dt)
	for model, controller in pairs(controllers) do
		if model.Parent then
			controller:step(dt)
		end
	end
end)

return PoseAnimator

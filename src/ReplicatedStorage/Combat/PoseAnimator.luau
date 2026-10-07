--[[
	Plays AnimationData directly on a character's joints, with no uploaded
	animation assets. Works the same in Studio and in live servers.

	Every frame the active tracks are layered by priority with fade weights
	and the result is written to Motor6D.Transform (from identity: this owns
	the whole body, locomotion included, so Roblox's default Animate isn't
	used). Tracks mimic the parts of the AnimationTrack API the combat client
	uses: Play, Stop, AdjustSpeed, IsPlaying, GetMarkerReachedSignal.

	On top of the clips sits a procedural layer that makes everything feel
	alive and heavy:
	  - micro-motion and breathing, so nothing is ever perfectly still
	  - overlap: the head and arms lag behind fast torso turns and whip
	    through when the torso stops (follow-through on every strike)
	  - lean into movement and bank into turns
	  - damped springs that impacts kick (PoseAnimator.kick)
	  - hit-stop: PoseAnimator.hitStop freezes a body for a few frames on
	    impact, shuddering in place, so hits land with weight
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AnimationData = require(script.Parent.AnimationData)
local AnimationBuilder = require(script.Parent.AnimationBuilder)

local PRIORITY = {
	Core = 0,
	Idle = 1,
	Movement = 2,
	MovementOverlay = 2.5,
	Action = 3,
	Action2 = 4,
	Action3 = 5,
	Action4 = 6,
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
		for joint in pairs(key.pose) do
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

	local priority = data.priority or "Action"
	local clip = {
		name = name,
		joints = joints,
		length = data.length,
		looped = data.looped == true,
		holdLast = data.holdLast == true,
		priority = PRIORITY[priority] or tonumber(priority) or PRIORITY.Action,
		markers = markers,
	}
	clips[name] = clip
	return clip
end

local function ease(alpha, style, direction)
	if style == "Linear" then
		return alpha
	elseif style == "Constant" then
		return 0
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

function Track:Play(fadeTime, _weight, speed)
	self.time = 0
	self.firedMarkers = {}
	self.IsPlaying = true
	self.targetWeight = 1
	self.fadeTime = fadeTime or 0.1
	self.speed = speed or 1
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

function Track:AdjustSpeed(speed)
	self.speed = speed
end

function Track:GetMarkerReachedSignal(markerName)
	local track = self
	return {
		Connect = function(_, callback)
			local handlers = track.markerHandlers[markerName]
			if not handlers then
				handlers = {}
				track.markerHandlers[markerName] = handlers
			end
			table.insert(handlers, callback)
			return {
				Disconnect = function()
					local index = table.find(handlers, callback)
					if index then
						table.remove(handlers, index)
					end
				end,
			}
		end,
	}
end

-- `dt` drives the fades (real time); `animDt` drives the clip (frozen
-- during hit-stop).
function Track:step(dt, animDt)
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
	self.time += animDt * self.speed

	for _, marker in ipairs(clip.markers) do
		if not self.firedMarkers[marker.name] and previous <= marker.t and self.time >= marker.t then
			self.firedMarkers[marker.name] = true
			local handlers = self.IsPlaying and self.markerHandlers[marker.name]
			if handlers then
				for _, handler in ipairs(handlers) do
					task.spawn(handler)
				end
			end
		end
	end

	if self.time >= clip.length then
		if clip.looped then
			self.time %= clip.length
			self.firedMarkers = {}
		elseif clip.holdLast then
			self.time = clip.length
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
			speed = 1,
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
-- Procedural layer

local SPRING_STIFFNESS = 260
local SPRING_DAMPING = 17

-- How much each joint lags behind the torso's rotation (overlap).
local DRAG = {
	Head = 0.2,
	RightArm = 0.07,
	LeftArm = 0.07,
}
local MAX_DRAG_KICK = 420

-- Micro-motion: slow noise (degrees) so no joint ever sits perfectly still.
local MICRO = {
	Torso = 0.9,
	Head = 2.6,
	RightArm = 2.4,
	LeftArm = 2.4,
}
local MICRO_SEED = { Torso = 1.7, Head = 5.3, RightArm = 9.1, LeftArm = 13.9 }

local JOINT_ROTATION = {
	Torso = CFrame.fromOrientation(-math.pi / 2, math.pi, 0),
}

function Controller:kick(joint, impulse)
	local spring = self.springs[joint]
	if not spring then
		spring = { pos = Vector3.zero, vel = Vector3.zero }
		self.springs[joint] = spring
	end
	spring.vel += impulse
end

-- Feeds the torso's angular acceleration into head/arm springs so they
-- trail behind turns and overshoot when the torso stops.
function Controller:overlap(torsoTransform, dt)
	if dt <= 0 then
		return
	end
	local previous = self.lastTorso
	self.lastTorso = torsoTransform
	if not previous then
		return
	end

	local axis, angle = (previous:Inverse() * torsoTransform):ToAxisAngle()
	if angle ~= angle or axis.Magnitude < 0.5 then
		return
	end
	-- transform space -> pose space (pitch, yaw, roll axes)
	local omega = JOINT_ROTATION.Torso:VectorToWorldSpace(axis) * math.deg(angle) / dt
	local delta = omega - self.lastOmega
	self.lastOmega = omega
	if delta.Magnitude > 4000 then
		return -- a teleport or a clip switch, not motion
	end

	for joint, gain in pairs(DRAG) do
		local impulse = -delta * gain
		if impulse.Magnitude > MAX_DRAG_KICK then
			impulse = impulse.Unit * MAX_DRAG_KICK
		end
		if impulse.Magnitude > 2 then
			self:kick(joint, impulse)
		end
	end
end

function Controller:procedural(dt, frozen)
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

	-- micro-motion
	local drift = self.clock * 0.8
	for joint, amount in pairs(MICRO) do
		local seed = MICRO_SEED[joint]
		add(joint,
			math.noise(drift, seed) * amount,
			math.noise(seed, drift) * amount * 0.6,
			math.noise(drift + seed, seed * 0.5) * amount * 0.5)
	end

	-- breathing
	local breath = math.sin(self.clock * math.pi * 2 * 0.3)
	add("Torso", -breath * 0.9, 0, 0, 0, breath * 0.03, 0)
	add("Head", breath * 1.2, 0, 0)
	add("RightArm", breath * 1.6, 0, 0)
	add("LeftArm", breath * 1.6, 0, 0)

	local root = self.model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		-- lean into movement, arms trail a little behind
		local localVel = root.CFrame:VectorToObjectSpace(root.AssemblyLinearVelocity)
		local target = Vector3.new(-localVel.Z, 0, localVel.X)
		self.lean = self.lean:Lerp(target, math.min(1, dt * 8))
		local forward = math.clamp(self.lean.X, -32, 32)
		local side = math.clamp(self.lean.Z, -32, 32)
		add("Torso", -forward * 0.34, 0, side * 0.32)
		add("Head", forward * 0.2, 0, -side * 0.16)
		add("RightArm", -forward * 0.28, 0, 0)
		add("LeftArm", -forward * 0.28, 0, 0)

		-- bank into turns, head leads the turn
		local look = root.CFrame.LookVector
		local heading = math.atan2(-look.X, -look.Z)
		if self.lastHeading and dt > 0 then
			local turn = (heading - self.lastHeading + math.pi) % (2 * math.pi) - math.pi
			local rate = math.deg(turn) / dt
			local speed = Vector2.new(localVel.X, localVel.Z).Magnitude
			local bank = math.clamp(rate * math.clamp(speed / 20, 0.15, 1.3) * 0.03, -14, 14)
			self.bank += (bank - self.bank) * math.min(1, dt * 10)
		end
		self.lastHeading = heading
		add("Torso", 0, 0, self.bank)
		add("Head", 0, self.bank * 0.9, -self.bank * 0.5)
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

	-- hit-stop shudder
	if frozen and self.shudder > 0 then
		local s = self.shudder
		add("Torso", 0, 0, 0, (math.random() - 0.5) * s, (math.random() - 0.5) * s * 0.4, (math.random() - 0.5) * s)
	end

	return offsets
end

function Controller:step(dt)
	local now = os.clock()
	local frozen = now < self.frozenUntil
	local animDt = frozen and 0 or dt

	local layers = {}
	for track in pairs(self.active) do
		if track:step(dt, animDt) then
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
	local alive = humanoid ~= nil and humanoid.Health > 0

	local results = {}
	for joint in pairs(self.motors) do
		local result = CFrame.identity
		for _, track in ipairs(layers) do
			local keys = track.clip.joints[joint]
			if keys and track.weight > 0 then
				result = result:Lerp(sample(keys, track.time), track.weight)
			end
		end
		results[joint] = result
	end

	if alive and results.Torso then
		self:overlap(results.Torso, animDt)
	end
	local offsets = alive and self:procedural(dt, frozen) or {}

	for joint, motor in pairs(self.motors) do
		if motor.Parent then
			local result = results[joint]
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
	PoseAnimator.get(model):kick(joint, impulse)
end

-- Freezes the body's clips for `duration` seconds (springs keep moving) and
-- shudders it by `shudder` studs. Re-freezing extends, never shortens.
function PoseAnimator.hitStop(model, duration, shudder)
	local controller = PoseAnimator.get(model)
	local untilTime = os.clock() + duration
	if untilTime > controller.frozenUntil then
		controller.frozenUntil = untilTime
	end
	controller.shudder = shudder or 0
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
		bank = 0,
		lastHeading = nil,
		lastTorso = nil,
		lastOmega = Vector3.zero,
		frozenUntil = 0,
		shudder = 0,
	}, Controller)
	controller:findMotors()
	controllers[model] = controller

	model.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Motor6D") then
			controller:findMotors()
		end
	end)
	model.Destroying:Once(function()
		controllers[model] = nil
	end)
	return controller
end

-- PreSimulation runs after Roblox's Animator has written this frame's
-- transforms, so these poses always win.
RunService.PreSimulation:Connect(function(dt)
	for model, controller in pairs(controllers) do
		if model.Parent then
			controller:step(dt)
		end
	end
end)

return PoseAnimator

-- Short movement bursts (lunges, dashes, knockback). Runs wherever the
-- character's physics is owned: the client for players, the server for NPCs.

local RunService = game:GetService("RunService")

local FLAT = Vector3.new(1, 0, 1)
local DASH_STEER_RATE = 9
local DASH_MIN_SPEED = 14
local ORBIT_MIN_RADIUS = 7

local Motion = {}

local function getAttachment(root)
	local attachment = root:FindFirstChild("CombatAttachment")
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "CombatAttachment"
		attachment.Parent = root
	end
	return attachment
end

local function makePush(root, planeVelocity)
	local push = Instance.new("LinearVelocity")
	push.Name = "CombatPush"
	push.Attachment0 = getAttachment(root)
	push.RelativeTo = Enum.ActuatorRelativeTo.World
	push.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	push.PrimaryTangentAxis = Vector3.xAxis
	push.SecondaryTangentAxis = Vector3.zAxis
	push.PlaneVelocity = planeVelocity
	push.MaxForce = 1e5
	push.Parent = root
	return push
end

function Motion.stop(root)
	local existing = root:FindFirstChild("CombatPush")
	if existing then
		existing:Destroy()
	end
end

-- Constant push for `duration`, plus an optional vertical launch.
function Motion.push(root, velocity, duration)
	Motion.stop(root)

	local horizontal = Vector2.new(velocity.X, velocity.Z)
	if horizontal.Magnitude > 0.01 and duration > 0 then
		local push = makePush(root, horizontal)
		task.delay(duration, function()
			if push.Parent then
				push:Destroy()
			end
		end)
	end

	if velocity.Y ~= 0 then
		local humanoid = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
		if humanoid and velocity.Y > 0 then
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
		local current = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(current.X, velocity.Y, current.Z)
	end
end

-- A burst that starts fast and eases out. While it runs, the movement keys
-- steer it, so a dash can curve around someone instead of locking you into
-- a straight line. With `orbit` (a target's root part) a sideways dash
-- circles the target at roughly its starting distance instead.
function Motion.dash(root, velocity, duration, orbit)
	Motion.stop(root)

	local speed = (velocity * FLAT).Magnitude
	if speed < 0.01 or duration <= 0 then
		return
	end
	local direction = (velocity * FLAT).Unit
	local humanoid = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
	local push = makePush(root, Vector2.new(direction.X, direction.Z) * speed)

	local orbitSign, orbitRadius
	if orbit then
		local offset = (orbit.Position - root.Position) * FLAT
		if offset.Magnitude > 0.5 and math.abs(direction:Dot(offset.Unit)) < 0.65 then
			local tangent = offset.Unit:Cross(Vector3.yAxis)
			orbitSign = direction:Dot(tangent) >= 0 and 1 or -1
			orbitRadius = math.max(offset.Magnitude, ORBIT_MIN_RADIUS)
		end
	end

	local start = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		local alpha = (os.clock() - start) / duration
		if alpha >= 1 or not push.Parent then
			connection:Disconnect()
			if push.Parent then
				push:Destroy()
			end
			return
		end

		local offset = orbitSign and orbit.Parent and (orbit.Position - root.Position) * FLAT
		if offset and offset.Magnitude > 0.5 then
			-- tangent around the target, nudged back toward the orbit radius
			local radial = offset.Unit
			local tangent = radial:Cross(Vector3.yAxis) * orbitSign
			local correction = math.clamp((offset.Magnitude - orbitRadius) * 0.8, -0.6, 0.6)
			direction = (tangent + radial * correction).Unit
		elseif humanoid then
			local move = humanoid.MoveDirection * FLAT
			if move.Magnitude > 0.1 then
				local blended = direction:Lerp(move.Unit, math.min(1, dt * DASH_STEER_RATE))
				if blended.Magnitude > 0.05 then
					direction = blended.Unit
				end
			end
		end

		local current = math.max(DASH_MIN_SPEED, speed * (1 - alpha) ^ 1.6)
		push.PlaneVelocity = Vector2.new(direction.X, direction.Z) * current
	end)
end

------------------------------------------------------------------------
-- Hover: holds a character in the air (slowly sinking) during juggles.
-- `delay` lets a launch carry them up first; each new call refreshes it.

local hoverTokens = setmetatable({}, { __mode = "k" })

function Motion.stopHover(root)
	hoverTokens[root] = (hoverTokens[root] or 0) + 1
	local existing = root:FindFirstChild("CombatHover")
	if existing then
		existing:Destroy()
	end
end

function Motion.hover(root, duration, delay)
	local token = (hoverTokens[root] or 0) + 1
	hoverTokens[root] = token

	local function begin()
		if hoverTokens[root] ~= token or not root.Parent then
			return
		end
		local hover = root:FindFirstChild("CombatHover")
		if not hover then
			hover = Instance.new("LinearVelocity")
			hover.Name = "CombatHover"
			hover.Attachment0 = getAttachment(root)
			hover.RelativeTo = Enum.ActuatorRelativeTo.World
			hover.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
			hover.LineDirection = Vector3.yAxis
			hover.MaxForce = 6e4
			hover.Parent = root
		end
		hover.LineVelocity = -1.5
		task.delay(duration, function()
			if hoverTokens[root] == token and hover.Parent then
				hover:Destroy()
			end
		end)
	end

	if delay and delay > 0 then
		task.delay(delay, begin)
	else
		begin()
	end
end

-- One entry point for the server's Impulse remote. `orbit` is only used by
-- dashes (see Motion.dash).
function Motion.apply(root, kind, velocity, duration, delay, orbit)
	if kind == "push" then
		Motion.push(root, velocity, duration)
	elseif kind == "dash" then
		Motion.dash(root, velocity, duration, orbit)
	elseif kind == "stop" then
		Motion.stop(root)
	elseif kind == "hover" then
		Motion.hover(root, duration, delay)
	elseif kind == "stopHover" then
		Motion.stopHover(root)
	end
end

return Motion

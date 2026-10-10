-- Short movement bursts (lunges, dashes, knockback). Runs wherever the
-- character's physics is owned: the client for players, the server for NPCs.

local RunService = game:GetService("RunService")
local Config = require(script.Parent.Config)

local DASH_STEER_RATE = 9
local DASH_MIN_SPEED = 14
local ORBIT_MIN_RADIUS = 4 -- only pushes you out if you start almost inside them
local ORBIT_SIDEWAYS = 0.65 -- how sideways (relative to them) a dash must be to strafe around them
local ORBIT_MAX_ANGLE = math.rad(100) -- the most one strafe can carry you around someone
--
local Motion = {}
--boi.
-- horizontal part of a world vector (positions/velocities can have height)
local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- 90 degrees around the vertical axis. Same as v:Cross(Vector3.yAxis) for a
-- flat v, and horizontal by construction, so it never needs flattening again.
local function perp(v)
	return Vector3.new(-v.Z, 0, v.X)
end

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

-- Knockback loses speed across the whole stun, easing gently to a stop.
-- Keep this separate from lunges, small hit pushes and dash steering.
function Motion.knockback(root, velocity, duration)
	Motion.push(root, velocity, 0) -- clear the previous push and apply vertical launch
	local horizontal = Vector2.new(velocity.X, velocity.Z)
	if horizontal.Magnitude < 0.01 or duration <= 0 then
		return
	end

	local push = makePush(root, horizontal)
	local started = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if not push.Parent then
			connection:Disconnect()
			return
		end
		local alpha = math.clamp((os.clock() - started) / duration, 0, 1)
		push.PlaneVelocity = horizontal * (1 - alpha) ^ 2
		if alpha >= 1 then
			connection:Disconnect()
			push:Destroy()
		end
	end)
end

-- A burst that starts fast and eases out. A straight dash can be steered a
-- little with the movement keys. With `orbit` (a target's root part), a
-- sideways dash becomes a strafe arc around them instead: same distance and
-- timing as a straight dash, held at your starting distance from them, and
-- never more than ORBIT_MAX_ANGLE around however close you are. The camera
-- is turned in CombatClient, together with your facing.
function Motion.dash(root, velocity, duration, orbit)
	Motion.stop(root)

	local speed = flat(velocity).Magnitude
	if speed < 0.01 or duration <= 0 then
		return
	end
	local direction = flat(velocity).Unit
	local humanoid = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
	local push = makePush(root, Vector2.new(direction.X, direction.Z) * speed)

	local function speedAt(alpha)
		return math.max(DASH_MIN_SPEED, speed * (1 - alpha) ^ 1.6)
	end

	-- decide once, at the start, whether this is a strafe around someone
	local orbitSign, orbitRadius, orbitScale
	if orbit then
		local offset = flat(orbit.Position - root.Position)
		if offset.Magnitude > Config.DashOrbitMinRange and math.abs(direction:Dot(offset.Unit)) < ORBIT_SIDEWAYS then
			orbitSign = direction:Dot(perp(offset.Unit)) >= 0 and 1 or -1
			orbitRadius = math.max(offset.Magnitude, ORBIT_MIN_RADIUS)
			-- how far a straight dash would go, then fit that to an arc
			local distance = 0
			for i = 0, 19 do
				distance += speedAt((i + 0.5) / 20) * duration / 20
			end
			local arc = math.min(distance / orbitRadius, ORBIT_MAX_ANGLE)
			orbitScale = arc * orbitRadius / distance -- <= 1: close up, you slow down instead of looping
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

		-- Keep the same speed easing when orbit assist drops out.
		local current = speedAt(alpha) * (orbitScale or 1)
		local offset = orbitSign and orbit.Parent and flat(orbit.Position - root.Position)
		if orbitSign and (not offset or offset.Magnitude <= Config.DashOrbitMinRange) then
			orbitSign = nil -- stay a straight dash for the rest of this burst
			offset = nil
		end
		if offset then
			-- along the circle, with a gentle pull back onto the starting radius
			local radial = offset.Unit
			local tangent = perp(radial) * orbitSign
			local correction = math.clamp((offset.Magnitude - orbitRadius) * 1.2, -0.6, 0.6)
			direction = (tangent + radial * correction).Unit
		elseif not orbitSign and humanoid then
			-- straight dash: the movement keys can bend it a little
			local move = flat(humanoid.MoveDirection)
			if move.Magnitude > 0.1 then
				local blended = direction:Lerp(move.Unit, math.min(1, dt * DASH_STEER_RATE))
				if blended.Magnitude > 0.05 then
					direction = blended.Unit
				end
			end
		end
		push.PlaneVelocity = Vector2.new(direction.X, direction.Z) * current
	end)
end

------------------------------------------------------------------------
-- Rush (Lumen Rush's dash): covers exactly `displacement` (horizontal) in
-- `duration`, on a curve with a hard but visible acceleration out of the
-- launch, a peak about a quarter of the way in, and a long braking glide
-- that settles the body where the cut lands, without sliding past it.
-- v(u) ~ u^A (1 - u)^B, the same curve tools/katana/motionprofile.py uses.

local RUSH_A, RUSH_B, RUSH_STEPS = 0.5, 1.4, 256
local rushCum = { 0 } -- distance share covered by each step of the clock
for i = 0, RUSH_STEPS - 1 do
	local u0, u1 = i / RUSH_STEPS, (i + 1) / RUSH_STEPS
	rushCum[i + 2] = rushCum[i + 1] + ((u0 ^ RUSH_A) * (1 - u0) ^ RUSH_B + (u1 ^ RUSH_A) * (1 - u1) ^ RUSH_B) / 2 / RUSH_STEPS
end
local rushTotal = rushCum[RUSH_STEPS + 1]

local function rushShare(u)
	local x = math.clamp(u, 0, 1) * RUSH_STEPS
	local i = math.min(math.floor(x), RUSH_STEPS - 1)
	return (rushCum[i + 1] + (rushCum[i + 2] - rushCum[i + 1]) * (x - i)) / rushTotal
end

-- `bend` bows the path sideways by that many studs at its middle (sign = side).
function Motion.rush(root, displacement, duration, bend)
	Motion.stop(root)
	bend = bend or 0
	local flatMove = flat(displacement)
	local distance = flatMove.Magnitude
	if distance < 0.05 or duration <= 0 then
		return
	end
	local direction = flatMove.Unit
	local push = makePush(root, Vector2.zero)
	local start = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local u = (os.clock() - start) / duration
		if u >= 1 or not push.Parent then
			connection:Disconnect()
			if push.Parent then
				push:Destroy()
			end
			return
		end
		u = math.max(u, 1e-3)
		local speed = distance / duration * (u ^ RUSH_A) * (1 - u) ^ RUSH_B / rushTotal
		-- the bow: lateral offset bend * sin(pi * s), s = share of the distance
		-- covered, so its rate is bend * pi * cos(pi * s) * ds/dt
		local s = rushShare(u)
		local lateral = bend * math.pi * math.cos(math.pi * s) * speed / distance
		local side = Vector3.new(-direction.Z, 0, direction.X)
		local v = direction * speed + side * lateral
		push.PlaneVelocity = Vector2.new(v.X, v.Z)
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
	elseif kind == "knockback" then
		Motion.knockback(root, velocity, duration)
	elseif kind == "dash" then
		Motion.dash(root, velocity, duration, orbit)
	elseif kind == "rush" then
		Motion.rush(root, velocity, duration)
	elseif kind == "stop" then
		Motion.stop(root)
	elseif kind == "hover" then
		Motion.hover(root, duration, delay)
	elseif kind == "stopHover" then
		Motion.stopHover(root)
	end
end

return Motion

--[[
	Client-side combat VFX and sound, battlegrounds style: every hit stacks a
	neon impact flash, a shock ring, streak lines and sparks; dashes leave
	afterimages and wind rings; slams crack the ground into a crater of rocks.

	Most shapes are procedural (neon parts animated every frame), so they need
	no uploads. The custom textures in Config.Textures add sparks, smoke and
	flipbook impacts on top. The slash skill's visuals are unchanged.
]]

local CollectionService = game:GetService("CollectionService")
local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local TEX = Config.Textures
local FLAT = Vector3.new(1, 0, 1)

local Effects = {}

local random = Random.new()

local function pick(list)
	return list[random:NextInteger(1, #list)]
end

function Effects.preload()
	local assets = {}
	for _, list in pairs(Config.Sounds) do
		for _, id in ipairs(list) do
			local sound = Instance.new("Sound")
			sound.SoundId = id
			table.insert(assets, sound)
		end
	end
	for _, id in pairs(TEX) do
		local decal = Instance.new("Decal")
		decal.Texture = id
		table.insert(assets, decal)
	end
	task.spawn(function()
		ContentProvider:PreloadAsync(assets)
	end)
end

local function anchorAt(position, lifetime)
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain
	Debris:AddItem(attachment, lifetime)
	return attachment
end

function Effects.sound(kind, parent, volume, pitch)
	local list = Config.Sounds[kind]
	if not list then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = pick(list)
	sound.Volume = volume or 0.6
	sound.PlaybackSpeed = (pitch or 1) * random:NextNumber(0.94, 1.06)
	sound.RollOffMinDistance = 8
	sound.RollOffMaxDistance = 90
	sound.Parent = parent
	sound:Play()
	Debris:AddItem(sound, 4)
end

------------------------------------------------------------------------
-- Procedural building blocks

local fxFolder

local function folder()
	if not fxFolder or not fxFolder.Parent then
		fxFolder = Instance.new("Folder")
		fxFolder.Name = "CombatFX"
		fxFolder.Parent = workspace
	end
	return fxFolder
end

local function fxPart(color, material, shape)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = material or Enum.Material.Neon
	part.Color = color or Color3.new(1, 1, 1)
	if shape then
		part.Shape = shape
	end
	part.Parent = folder()
	return part
end

-- Runs `step(alpha, dt)` every frame for `duration`, then `done()`.
local function animate(duration, step, done)
	local start = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		local alpha = math.min(1, (os.clock() - start) / duration)
		local ok = pcall(step, alpha, dt)
		if alpha >= 1 or not ok then
			connection:Disconnect()
			if done then
				done()
			end
		end
	end)
end

local function easeOut(alpha, power)
	return 1 - (1 - alpha) ^ (power or 3)
end

-- A CFrame at `position` whose LookVector is `normal`.
local function facing(position, normal)
	normal = normal.Magnitude > 0.001 and normal.Unit or Vector3.yAxis
	local up = math.abs(normal.Y) > 0.95 and Vector3.xAxis or Vector3.yAxis
	local right = normal:Cross(up).Unit
	return CFrame.fromMatrix(position, right, right:Cross(normal), -normal)
end

-- A random direction within `spread` degrees of `direction`.
local function cone(direction, spread)
	local basis = facing(Vector3.zero, direction)
	local theta = math.rad(random:NextNumber(0, spread))
	local phi = random:NextNumber(0, math.pi * 2)
	return basis:VectorToWorldSpace(Vector3.new(
		math.sin(theta) * math.cos(phi),
		math.sin(theta) * math.sin(phi),
		-math.cos(theta)
	))
end

-- Expanding neon ball that fades out: the core of every impact.
local function burst(position, color, size0, size1, duration, transparency)
	local ball = fxPart(color, Enum.Material.Neon, Enum.PartType.Ball)
	ball.Size = Vector3.one * size0
	ball.CFrame = CFrame.new(position)
	local t0 = transparency or 0
	animate(duration, function(alpha)
		local size = size0 + (size1 - size0) * easeOut(alpha, 4)
		ball.Size = Vector3.one * size
		ball.Transparency = t0 + (1 - t0) * alpha ^ 1.4
	end, function()
		ball:Destroy()
	end)
end

-- Segmented shock ring lying in the plane of `cf` (axis = cf.LookVector).
local function ring(cf, color, r0, r1, thickness, duration, transparency, segments)
	segments = segments or 20
	local t0 = transparency or 0.1
	local parts = {}
	for i = 1, segments do
		parts[i] = fxPart(color)
	end
	animate(duration, function(alpha)
		local eased = easeOut(alpha, 3)
		local radius = r0 + (r1 - r0) * eased
		local width = thickness * (1 - alpha * 0.75)
		local length = (2 * math.pi * radius / segments) * 1.08
		local fade = t0 + (1 - t0) * alpha ^ 1.6
		for i, part in ipairs(parts) do
			local angle = (i / segments) * math.pi * 2
			part.Size = Vector3.new(width, length, width * 0.6)
			part.CFrame = cf * CFrame.Angles(0, 0, angle) * CFrame.new(radius, 0, 0)
			part.Transparency = fade
		end
	end, function()
		for _, part in ipairs(parts) do
			part:Destroy()
		end
	end)
end

-- Thin neon lines shooting out of an impact.
local function streaks(position, direction, count, color, length, distance, spread, duration, width)
	local lines = {}
	for i = 1, count do
		local dir = direction and cone(direction, spread) or cone(Vector3.yAxis, 180)
		lines[i] = { part = fxPart(color), dir = dir, length = length * random:NextNumber(0.6, 1.2), distance = distance * random:NextNumber(0.7, 1.15) }
	end
	width = width or 0.12
	animate(duration, function(alpha)
		local eased = easeOut(alpha, 2.5)
		for _, line in ipairs(lines) do
			local len = math.max(0.05, line.length * math.min(1, alpha * 6) * (1 - alpha) ^ 0.6)
			local centre = position + line.dir * (0.4 + line.distance * eased + len / 2)
			line.part.Size = Vector3.new(width * (1 - alpha * 0.6), width * (1 - alpha * 0.6), len)
			line.part.CFrame = CFrame.lookAt(centre, centre + line.dir)
			line.part.Transparency = alpha ^ 2
		end
	end, function()
		for _, line in ipairs(lines) do
			line.part:Destroy()
		end
	end)
end

-- Neon wedges blown outward with gravity (guard break).
local function shards(position, direction, count, color)
	local pieces = {}
	for i = 1, count do
		local part = Instance.new("WedgePart")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Size = Vector3.new(0.08, random:NextNumber(0.3, 0.8), random:NextNumber(0.3, 0.9))
		part.CFrame = CFrame.new(position) * CFrame.Angles(random:NextNumber(0, 6.3), random:NextNumber(0, 6.3), 0)
		part.Parent = folder()
		local dir = direction and cone(direction, 70) or cone(Vector3.yAxis, 180)
		pieces[i] = {
			part = part,
			velocity = dir * random:NextNumber(18, 34) + Vector3.new(0, random:NextNumber(4, 12), 0),
			spin = CFrame.Angles(random:NextNumber(-0.4, 0.4), random:NextNumber(-0.4, 0.4), random:NextNumber(-0.4, 0.4)),
		}
	end
	animate(0.7, function(alpha, dt)
		for _, piece in ipairs(pieces) do
			piece.velocity += Vector3.new(0, -70, 0) * dt
			piece.velocity *= 1 - math.min(1, dt * 2)
			piece.part.CFrame = (piece.part.CFrame + piece.velocity * dt) * piece.spin
			piece.part.Transparency = alpha ^ 2
		end
	end, function()
		for _, piece in ipairs(pieces) do
			piece.part:Destroy()
		end
	end)
end

------------------------------------------------------------------------
-- Ground

local function groundParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = { folder() }
	for _, model in ipairs(CollectionService:GetTagged("Combatant")) do
		table.insert(ignore, model)
	end
	params.FilterDescendantsInstances = ignore
	return params
end

-- Ground position, material and colour under `position`, or nil.
local function groundAt(position, depth)
	local result = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -(depth or 10), 0), groundParams())
	if not result then
		return nil
	end
	local color
	if result.Instance:IsA("Terrain") then
		local ok, terrainColor = pcall(function()
			return workspace.Terrain:GetMaterialColor(result.Material)
		end)
		color = ok and terrainColor or Color3.fromRGB(110, 105, 100)
	elseif result.Instance:IsA("BasePart") then
		color = result.Instance.Color
	else
		color = Color3.fromRGB(110, 105, 100)
	end
	return result.Position, result.Material, color
end

local function rockPart(material, color, size)
	local part = fxPart(color, Enum.Material.Slate)
	pcall(function()
		part.Material = material
	end)
	part.Size = size
	return part
end

-- Chunks of ground thrown up in arcs.
local function debris(position, count, material, color, power)
	local pieces = {}
	for i = 1, count do
		local s = random:NextNumber(0.35, 0.9)
		local part = rockPart(material, color, Vector3.new(s, s * random:NextNumber(0.6, 1), s))
		part.CFrame = CFrame.new(position) * CFrame.Angles(random:NextNumber(0, 6.3), random:NextNumber(0, 6.3), 0)
		local angle = random:NextNumber(0, math.pi * 2)
		pieces[i] = {
			part = part,
			velocity = Vector3.new(math.cos(angle), 0, math.sin(angle)) * random:NextNumber(8, 18) * power
				+ Vector3.new(0, random:NextNumber(18, 34) * power, 0),
			spin = CFrame.Angles(random:NextNumber(-0.3, 0.3), random:NextNumber(-0.3, 0.3), random:NextNumber(-0.3, 0.3)),
			floor = position.Y,
		}
	end
	animate(1.4, function(alpha, dt)
		for _, piece in ipairs(pieces) do
			if piece.velocity then
				piece.velocity += Vector3.new(0, -110, 0) * dt
				local cf = (piece.part.CFrame + piece.velocity * dt) * piece.spin
				if cf.Position.Y < piece.floor + 0.2 and piece.velocity.Y < 0 then
					piece.velocity = nil -- landed
					cf = CFrame.new(cf.Position.X, piece.floor + 0.2, cf.Position.Z) * cf.Rotation
				end
				piece.part.CFrame = cf
			end
			piece.part.Transparency = math.clamp((alpha - 0.7) / 0.3, 0, 1)
		end
	end, function()
		for _, piece in ipairs(pieces) do
			piece.part:Destroy()
		end
	end)
end

-- Rocks bursting up in a circle around an impact, then sinking away.
local function crater(position, radius, count)
	local ground, material, color = groundAt(position, 14)
	if not ground then
		return
	end
	local rocks = {}
	local offset = random:NextNumber(0, math.pi * 2)
	for i = 1, count do
		local angle = offset + (i / count) * math.pi * 2 + random:NextNumber(-0.15, 0.15)
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local size = Vector3.new(random:NextNumber(1.3, 2.4), random:NextNumber(1.1, 2), random:NextNumber(1.3, 2.4))
		local rest = CFrame.lookAt(ground + dir * radius * random:NextNumber(0.85, 1.15), ground + dir * (radius + 5))
			* CFrame.Angles(math.rad(random:NextNumber(25, 50)), 0, math.rad(random:NextNumber(-20, 20)))
		local part = rockPart(material, color, size)
		part.CFrame = rest - Vector3.new(0, 2.5, 0)
		rocks[i] = { part = part, rest = rest }
	end
	animate(0.14, function(alpha)
		for _, rock in ipairs(rocks) do
			rock.part.CFrame = rock.rest - Vector3.new(0, 2.5 * (1 - easeOut(alpha, 3)), 0)
		end
	end)
	task.delay(1.8, function()
		animate(0.6, function(alpha)
			for _, rock in ipairs(rocks) do
				rock.part.CFrame = rock.rest - Vector3.new(0, 2.5 * alpha * alpha, 0)
				rock.part.Transparency = alpha ^ 3
			end
		end, function()
			for _, rock in ipairs(rocks) do
				rock.part:Destroy()
			end
		end)
	end)
	debris(ground, math.floor(count * 0.8), material, color, 1)
end

------------------------------------------------------------------------
-- Flipbook billboard: steps through a 4x4 sheet while growing.

local function flipbook(parent, texture, options)
	local duration = options.duration or 0.35
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(options.size0, options.size0)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = options.onTop == true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Adornee = parent
	gui.Parent = parent

	local image = Instance.new("ImageLabel")
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromScale(1, 1)
	image.Image = texture
	image.ImageColor3 = options.color or Color3.new(1, 1, 1)
	image.ImageTransparency = options.transparency or 0
	image.ImageRectSize = Vector2.new(256, 256)
	image.Rotation = options.rotation or random:NextNumber(0, 360)
	image.Parent = gui

	local start = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local alpha = (os.clock() - start) / duration
		if alpha >= 1 or not gui.Parent then
			connection:Disconnect()
			gui:Destroy()
			return
		end
		local frame = math.min(15, math.floor(alpha * 16))
		image.ImageRectOffset = Vector2.new((frame % 4) * 256, math.floor(frame / 4) * 256)
		local eased = 1 - (1 - alpha) ^ 3
		local size = options.size0 + (options.size1 - options.size0) * eased
		gui.Size = UDim2.fromScale(size, size)
	end)
	return gui
end

------------------------------------------------------------------------
-- Particle bursts

local function emitter(parent, props)
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.Texture = props.texture
	e.Color = ColorSequence.new(props.color or Color3.new(1, 1, 1))
	e.LightEmission = props.lightEmission or 0
	e.LightInfluence = props.lightInfluence or 0
	e.Size = props.size
	e.Transparency = props.transparency or NumberSequence.new(0, 1)
	e.Lifetime = props.lifetime
	e.Speed = props.speed
	e.SpreadAngle = props.spread or Vector2.new(180, 180)
	e.Drag = props.drag or 0
	e.Acceleration = props.acceleration or Vector3.zero
	e.Rotation = props.rotation or NumberRange.new(0, 360)
	e.RotSpeed = props.rotSpeed or NumberRange.new(0)
	e.Orientation = props.orientation or Enum.ParticleOrientation.FacingCamera
	e.EmissionDirection = props.direction or Enum.NormalId.Top
	e.Squash = props.squash or NumberSequence.new(0)
	e.ZOffset = props.zOffset or 0
	if props.flipbook then
		e.FlipbookLayout = Enum.ParticleFlipbookLayout.Grid4x4
		e.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
	end
	e.Parent = parent
	e:Emit(props.count or 1)
	return e
end

local function sparks(parent, count, color, speed)
	emitter(parent, {
		texture = TEX.spark,
		color = color,
		lightEmission = 1,
		size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.32), NumberSequenceKeypoint.new(1, 0) }),
		squash = NumberSequence.new(-1.4),
		transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.7, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		lifetime = NumberRange.new(0.12, 0.32),
		speed = NumberRange.new(speed * 0.55, speed),
		drag = 7,
		acceleration = Vector3.new(0, -40, 0),
		orientation = Enum.ParticleOrientation.VelocityParallel,
		rotation = NumberRange.new(0),
		count = count,
	})
end

local function glow(parent, size, color, lifetime)
	emitter(parent, {
		texture = TEX.glow,
		color = color,
		lightEmission = 1,
		size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, size * 1.6) }),
		transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) }),
		lifetime = NumberRange.new(lifetime),
		speed = NumberRange.new(0),
		count = 1,
	})
end

local function smoke(parent, count, size, speed, color)
	emitter(parent, {
		texture = TEX.smoke,
		flipbook = true,
		color = color or Color3.fromRGB(176, 168, 158),
		lightInfluence = 0.6,
		size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, size * 2.2) }),
		transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) }),
		lifetime = NumberRange.new(0.55, 0.85),
		speed = NumberRange.new(speed * 0.5, speed),
		drag = 4,
		rotSpeed = NumberRange.new(-40, 40),
		count = count,
	})
end

local function flash(parent, color, brightness, range, duration)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = parent
	local start = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local alpha = (os.clock() - start) / duration
		if alpha >= 1 or not light.Parent then
			connection:Disconnect()
			light:Destroy()
			return
		end
		light.Brightness = brightness * (1 - alpha) ^ 2
	end)
end

-- Dust thrown outward along the ground.
local function dustRing(position, radius, count, color)
	for i = 1, count do
		local angle = (i / count) * math.pi * 2 + random:NextNumber(-0.2, 0.2)
		local dir = Vector3.new(math.cos(angle), 0.12, math.sin(angle))
		local a = Instance.new("Attachment")
		a.WorldCFrame = CFrame.lookAt(position + dir * 0.6, position + dir * 2)
		a.Parent = workspace.Terrain
		Debris:AddItem(a, 2)
		emitter(a, {
			texture = TEX.smoke,
			flipbook = true,
			color = color or Color3.fromRGB(170, 160, 148),
			lightInfluence = 0.6,
			size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 3.4) }),
			transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) }),
			lifetime = NumberRange.new(0.5, 0.8),
			speed = NumberRange.new(radius * 0.9, radius * 1.3),
			spread = Vector2.new(8, 8),
			direction = Enum.NormalId.Front,
			drag = 5,
			rotSpeed = NumberRange.new(-30, 30),
			count = 1,
		})
	end
end

-- Ground shockwave: a flat ring plus dust thrown outward.
local function groundBurst(position, radius, color)
	ring(facing(position + Vector3.new(0, 0.2, 0), Vector3.yAxis), color or Color3.fromRGB(240, 232, 220), 1, radius, 0.7, 0.45, 0.25, 28)
	dustRing(position, radius, 12)
end

------------------------------------------------------------------------
-- Afterimages

local BODY_PARTS = { "Head", "Torso", "Right Arm", "Left Arm", "Right Leg", "Left Leg" }

-- A neon snapshot of the body that fades in place.
function Effects.afterimage(model, color, duration, transparency)
	local ghosts = {}
	for _, name in ipairs(BODY_PARTS) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local ghost = fxPart(color, Enum.Material.Neon)
			ghost.Size = part.Size
			ghost.CFrame = part.CFrame
			ghost.Transparency = transparency
			local mesh = part:FindFirstChildOfClass("SpecialMesh")
			if mesh and mesh.MeshType == Enum.MeshType.Head then
				local copy = Instance.new("SpecialMesh")
				copy.MeshType = Enum.MeshType.Head
				copy.Scale = mesh.Scale
				copy.Parent = ghost
			end
			table.insert(ghosts, ghost)
		end
	end
	animate(duration, function(alpha)
		for _, ghost in ipairs(ghosts) do
			ghost.Transparency = transparency + (1 - transparency) * alpha
		end
	end, function()
		for _, ghost in ipairs(ghosts) do
			ghost:Destroy()
		end
	end)
end

-- A string of afterimages left behind while the body moves.
function Effects.afterimages(model, duration, interval, color, transparency)
	task.spawn(function()
		local stop = os.clock() + duration
		while os.clock() < stop and model.Parent do
			Effects.afterimage(model, color or Color3.fromRGB(210, 225, 255), 0.22, transparency or 0.6)
			task.wait(interval or 0.035)
		end
	end)
end

------------------------------------------------------------------------
-- Movement effects (all clients, for every combatant)

local WIND = Color3.fromRGB(235, 242, 255)

-- Dash: a wind ring punched out behind, dust kicked up, afterimages trail.
function Effects.dash(model, direction, airborne)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	direction = (direction * FLAT).Magnitude > 0.01 and (direction * FLAT).Unit or (root.CFrame.LookVector * FLAT).Unit
	local at = anchorAt(root.Position, 1.5)
	Effects.sound("Dash", at, 0.45, 0.7)
	ring(facing(root.Position - direction * 1.2, direction), WIND, 0.8, 4.2, 0.35, 0.28, 0.35, 16)
	streaks(root.Position, -direction, 6, WIND, 3.2, 4, 25, 0.25, 0.08)
	Effects.afterimages(model, Config.RollDuration * 0.85, 0.035)
	if not airborne then
		local ground = groundAt(root.Position, 5)
		if ground then
			local dust = anchorAt(ground + Vector3.new(0, 0.3, 0), 2)
			smoke(dust, 5, 1.1, 9)
		end
	end
end

-- Double jump: a flat wind ring under the feet.
function Effects.doubleJump(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local feet = root.Position - Vector3.new(0, 2.8, 0)
	ring(facing(feet, Vector3.yAxis), WIND, 0.6, 4.5, 0.4, 0.32, 0.3, 18)
	streaks(feet, -Vector3.yAxis, 5, WIND, 2.4, 3, 35, 0.22, 0.07)
	Effects.sound("Dash", anchorAt(feet, 1), 0.3, 1.1)
end

-- Landing: dust and a small ground ring scaled by fall speed (0..1).
function Effects.land(position, strength)
	local ground = groundAt(position, 6)
	if not ground then
		return
	end
	local dust = anchorAt(ground + Vector3.new(0, 0.3, 0), 2)
	smoke(dust, math.floor(3 + strength * 6), 0.9 + strength, 4 + strength * 8)
	if strength > 0.5 then
		ring(facing(ground + Vector3.new(0, 0.15, 0), Vector3.yAxis), WIND, 0.8, 3 + strength * 3, 0.3, 0.35, 0.45, 18)
	end
end

-- Footfall puff while sprinting.
function Effects.step(position)
	local ground = groundAt(position, 6)
	if not ground then
		return
	end
	emitter(anchorAt(ground + Vector3.new(0, 0.2, 0), 1.5), {
		texture = TEX.smoke,
		flipbook = true,
		color = Color3.fromRGB(190, 182, 172),
		lightInfluence = 0.6,
		size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1.6) }),
		transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }),
		lifetime = NumberRange.new(0.35, 0.55),
		speed = NumberRange.new(1, 3),
		drag = 3,
		count = 1,
	})
end

-- Sent flying: afterimages and a wind trail behind the body.
function Effects.knockback(model, duration)
	Effects.afterimages(model, duration, 0.05, Color3.fromRGB(255, 240, 225), 0.7)
end

------------------------------------------------------------------------
-- Slash skill

local BLOOD = Color3.fromRGB(200, 20, 30)

-- The thrown crescent: a flat blade (decals on both faces) that flies
-- forward, widening slightly, with a red glow riding along.
local function throwCleave(origin, direction)
	local S = Config.Skill
	local part = Instance.new("Part")
	part.Name = "CleaveSlash"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(11, 0.05, 5.5)
	for _, face in ipairs({ Enum.NormalId.Top, Enum.NormalId.Bottom }) do
		local decal = Instance.new("Decal")
		decal.Texture = TEX.cleave
		decal.Face = face
		decal.Parent = part
	end
	local light = Instance.new("PointLight")
	light.Color = BLOOD
	light.Brightness = 3
	light.Range = 12
	light.Parent = part
	local tilt = math.rad(random:NextNumber(-14, 14))
	part.Parent = workspace.Terrain

	local at = anchorAt(origin, 1.5)
	Effects.sound("Swing", at, 0.9, 0.65)
	glow(at, 3, BLOOD, 0.2)

	local duration = S.range / S.speed
	local start = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local alpha = (os.clock() - start) / duration
		if alpha >= 1 then
			connection:Disconnect()
			part:Destroy()
			return
		end
		local position = origin + direction * (S.range * alpha) + Vector3.new(0, 0.4, 0)
		local scale = 1 + 0.35 * alpha
		part.Size = Vector3.new(11 * scale, 0.05, 5.5 * scale)
		part.CFrame = CFrame.lookAt(position, position + direction) * CFrame.Angles(0, 0, tilt)
		local fade = math.clamp((alpha - 0.75) / 0.25, 0, 1)
		for _, decal in ipairs(part:GetChildren()) do
			if decal:IsA("Decal") then
				decal.Transparency = fade
			end
		end
		light.Brightness = 3 * (1 - fade)
	end)
end

-- One cut landing on a held body: a slash flashes in at a random angle
-- somewhere on them, with a spray of red.
function Effects.dismantleCut(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local offset = Vector3.new(random:NextNumber(-1.3, 1.3), random:NextNumber(-1.8, 1.9), random:NextNumber(-1.3, 1.3))
	local at = anchorAt(root.Position + offset, 1)
	flipbook(at, TEX.dismantle, {
		size0 = random:NextNumber(4.5, 6.5),
		size1 = random:NextNumber(5.5, 7.5),
		duration = random:NextNumber(0.24, 0.34),
		onTop = random:NextNumber() < 0.5,
	})
	if random:NextNumber() < 0.6 then
		sparks(at, 4, BLOOD, 26)
	end
	if random:NextNumber() < 0.45 then
		Effects.sound("Swing", at, 0.35, random:NextNumber(1.5, 1.9))
	end
end

local WARM = Color3.fromRGB(255, 226, 190)
local HOT = Color3.fromRGB(255, 250, 240)
local GOLD = Color3.fromRGB(255, 214, 140)
local STEEL = Color3.fromRGB(190, 215, 255)
local EMBER = Color3.fromRGB(255, 120, 60)

local function hitDirection(position, attacker, defender)
	local a = attacker and attacker:FindFirstChild("HumanoidRootPart")
	local d = defender and defender:FindFirstChild("HumanoidRootPart")
	if a and d then
		local dir = (d.Position - a.Position) * FLAT
		if dir.Magnitude > 0.05 then
			return dir.Unit
		end
	end
	local camera = workspace.CurrentCamera
	return camera and (position - camera.CFrame.Position).Unit or Vector3.zAxis
end

-- Plays an effect and returns how hard it should hit the camera (0..1).
-- `info` is the attack kind for hits (or a direction for dashes).
function Effects.play(kind, position, attacker, defender, info)
	if kind == "CleaveThrow" then
		local root = attacker and attacker:FindFirstChild("HumanoidRootPart")
		local direction = root and (root.CFrame.LookVector * Vector3.new(1, 0, 1)).Unit or Vector3.zAxis
		throwCleave(position, direction)
		return 0.15
	elseif kind == "CleaveHit" then
		local at = anchorAt(position, 2)
		Effects.sound("HeavyHit", at, 0.9, 1.15)
		flipbook(at, TEX.dismantle, { size0 = 7, size1 = 12, duration = 0.32, onTop = true })
		flipbook(at, TEX.parry, { size0 = 3, size1 = 8, duration = 0.3, color = BLOOD, onTop = true })
		sparks(at, 20, BLOOD, 45)
		flash(at, BLOOD, 6, 14, 0.3)
		return 0.45
	end

	local direction = hitDirection(position, attacker, defender)

	if kind == "Hit" then
		local at = anchorAt(position, 1.5)
		Effects.sound("Hit", at, 0.75)
		burst(position, HOT, 0.6, 3.4, 0.14)
		burst(position, WARM, 1.2, 4.4, 0.2, 0.55)
		ring(facing(position, direction), WARM, 0.4, 3.2, 0.25, 0.2, 0.2, 14)
		streaks(position, direction, 6, HOT, 2.4, 3.5, 55, 0.18)
		flipbook(at, TEX.impact, { size0 = 2.2, size1 = 5, duration = 0.26, color = WARM })
		sparks(at, 9, WARM, 42)
		return 0.22
	elseif kind == "HeavyHit" then
		local at = anchorAt(position, 2)
		local big = info == "Finisher" or info == "Critical"
		Effects.sound("HeavyHit", at, 0.9, big and 0.85 or 1)
		Effects.sound("Hit", at, 0.6, 0.8)
		burst(position, HOT, 1, big and 6.5 or 5, 0.18)
		burst(position, WARM, 1.6, big and 8 or 6.5, 0.28, 0.5)
		ring(facing(position, direction), HOT, 0.6, big and 7 or 5.5, 0.45, 0.3, 0.1, 22)
		ring(facing(position + direction * 1.5, direction), WARM, 0.4, big and 4.5 or 3.5, 0.3, 0.26, 0.3, 18)
		streaks(position, direction, big and 14 or 10, HOT, 3.4, big and 7 or 5.5, 50, 0.24, 0.14)
		flipbook(at, TEX.impact, { size0 = 3.2, size1 = 8, duration = 0.32, color = WARM, onTop = true })
		sparks(at, 18, WARM, 56)
		smoke(at, 4, 1.4, 7)
		glow(at, 4, WARM, 0.18)
		flash(at, WARM, 5, 14, 0.22)
		if defender and big then
			Effects.knockback(defender, 0.35)
		end
		return big and 0.6 or 0.42
	elseif kind == "Block" then
		local at = anchorAt(position, 1.5)
		Effects.sound("Block", at, 0.7, 0.9)
		burst(position, STEEL, 0.5, 2.6, 0.12, 0.2)
		ring(facing(position, direction), STEEL, 0.5, 2.8, 0.2, 0.18, 0.25, 14)
		sparks(at, 7, STEEL, 30)
		smoke(at, 2, 0.9, 4)
		return 0.12
	elseif kind == "Parry" then
		local at = anchorAt(position, 1.5)
		Effects.sound("Parry", at, 0.85)
		burst(position, HOT, 0.8, 4.5, 0.16)
		burst(position, GOLD, 1.2, 6, 0.24, 0.45)
		ring(facing(position, direction), GOLD, 0.6, 6, 0.4, 0.3, 0.05, 22)
		ring(facing(position, Vector3.yAxis), GOLD, 0.4, 4.5, 0.25, 0.26, 0.3, 18)
		streaks(position, nil, 14, GOLD, 2.6, 5, 180, 0.24, 0.1)
		flipbook(at, TEX.parry, { size0 = 3, size1 = 8.5, duration = 0.34, color = GOLD, onTop = true })
		sparks(at, 24, GOLD, 64)
		flash(at, GOLD, 7, 16, 0.22)
		return 0.32
	elseif kind == "GuardBreak" then
		local center = position + Vector3.new(0, 0.6, 0)
		local at = anchorAt(center, 2)
		Effects.sound("GuardBreak", at, 0.95)
		Effects.sound("HeavyHit", at, 0.7, 0.85)
		burst(center, HOT, 1, 6, 0.2)
		burst(center, EMBER, 1.6, 7.5, 0.3, 0.45)
		ring(facing(center, direction), EMBER, 0.6, 6.5, 0.45, 0.32, 0.1, 22)
		shards(center, direction, 16, Color3.fromRGB(200, 225, 255))
		streaks(center, direction, 10, EMBER, 3, 6, 70, 0.26, 0.12)
		flipbook(at, TEX.parry, { size0 = 3.5, size1 = 10, duration = 0.4, color = EMBER, onTop = true })
		sparks(at, 26, EMBER, 58)
		smoke(at, 6, 1.6, 7)
		flash(at, EMBER, 7, 16, 0.3)
		return 0.65
	elseif kind == "Slam" then
		local at = anchorAt(position + Vector3.new(0, 0.5, 0), 2)
		Effects.sound("HeavyHit", at, 0.95, 0.72)
		burst(position + Vector3.new(0, 0.5, 0), HOT, 1, 6, 0.2)
		groundBurst(position, 15)
		crater(position, 5.5, 12)
		streaks(position, Vector3.yAxis, 10, WARM, 3, 6, 60, 0.26, 0.12)
		sparks(at, 14, WARM, 44)
		return 0.7
	elseif kind == "Feint" then
		local at = anchorAt(position, 1)
		Effects.sound("Feint", at, 0.35, 1.25)
		smoke(at, 2, 0.8, 3, Color3.fromRGB(210, 210, 215))
		return 0
	elseif kind == "Dodge" then
		local at = anchorAt(position, 1)
		smoke(at, 2, 1, 3, Color3.fromRGB(200, 200, 205))
		if defender then
			Effects.afterimage(defender, Color3.fromRGB(210, 225, 255), 0.3, 0.45)
		end
		return 0
	end
	return 0
end

------------------------------------------------------------------------
-- Swing trails, switched on around each strike.

local TRAIL_LIMBS = { "Right Arm", "Left Arm", "Right Leg", "Left Leg" }

function Effects.attachTrails(model)
	local trails = {}
	for _, limbName in ipairs(TRAIL_LIMBS) do
		local limb = model:FindFirstChild(limbName)
		if limb and not limb:FindFirstChild("FistTrail") then
			local a0 = Instance.new("Attachment")
			a0.Name = "FistTrailTop"
			a0.Position = Vector3.new(0, -0.45, 0)
			a0.Parent = limb
			local a1 = Instance.new("Attachment")
			a1.Name = "FistTrailBottom"
			a1.Position = Vector3.new(0, -1.05, 0)
			a1.Parent = limb
			local trail = Instance.new("Trail")
			trail.Name = "FistTrail"
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Texture = TEX.trail
			trail.TextureMode = Enum.TextureMode.Stretch
			trail.Lifetime = 0.16
			trail.MinLength = 0.05
			trail.LightEmission = 0.8
			trail.FaceCamera = true
			trail.Color = ColorSequence.new(Color3.fromRGB(255, 244, 228))
			trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
			trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.2) })
			trail.Enabled = false
			trail.Parent = limb
		end
		local trail = limb and limb:FindFirstChild("FistTrail")
		if trail then
			trails[limbName] = trail
		end
	end
	return trails
end

-- `limbs` defaults to both arms.
function Effects.swingTrails(model, duration, limbs)
	local trails = Effects.attachTrails(model)
	for _, limbName in ipairs(limbs or { "Right Arm", "Left Arm" }) do
		local trail = trails[limbName]
		if trail then
			trail.Enabled = true
			task.delay(duration, function()
				trail.Enabled = false
			end)
		end
	end
end

return Effects

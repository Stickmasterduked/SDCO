-- Client-side combat VFX and sound. Textures are custom-made and uploaded
-- (see Config.Textures): flipbook impacts are 4x4 sheets of 256px frames
-- played on camera-facing billboards; sparks, smoke and shockwaves are
-- ParticleEmitters burst once.

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local TEX = Config.Textures

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
		size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.28), NumberSequenceKeypoint.new(1, 0) }),
		squash = NumberSequence.new(-1.2),
		transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.7, 0.1), NumberSequenceKeypoint.new(1, 1) }),
		lifetime = NumberRange.new(0.12, 0.3),
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

-- Flat shockwave + dust thrown outward along the ground.
local function groundBurst(position, radius, color)
	local center = anchorAt(position + Vector3.new(0, 0.15, 0), 2)
	emitter(center, {
		texture = TEX.ring,
		color = color or Color3.fromRGB(235, 225, 210),
		lightEmission = 0.4,
		size = NumberSequence.new({ NumberSequenceKeypoint.new(0, radius * 0.15), NumberSequenceKeypoint.new(1, radius) }),
		transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.05), NumberSequenceKeypoint.new(1, 1) }),
		lifetime = NumberRange.new(0.45),
		speed = NumberRange.new(0.01),
		spread = Vector2.new(0, 0),
		orientation = Enum.ParticleOrientation.VelocityPerpendicular,
		rotation = NumberRange.new(0, 360),
		count = 1,
	})
	for i = 1, 10 do
		local angle = (i / 10) * math.pi * 2 + random:NextNumber(-0.2, 0.2)
		local dir = Vector3.new(math.cos(angle), 0.15, math.sin(angle))
		local a = Instance.new("Attachment")
		a.WorldCFrame = CFrame.lookAt(position + dir * 0.6, position + dir * 2)
		a.Parent = workspace.Terrain
		Debris:AddItem(a, 2)
		emitter(a, {
			texture = TEX.smoke,
			flipbook = true,
			color = Color3.fromRGB(170, 160, 148),
			lightInfluence = 0.6,
			size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 3.6) }),
			transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) }),
			lifetime = NumberRange.new(0.6, 0.9),
			speed = NumberRange.new(radius * 0.9, radius * 1.3),
			spread = Vector2.new(8, 8),
			direction = Enum.NormalId.Front,
			drag = 5,
			rotSpeed = NumberRange.new(-30, 30),
			count = 1,
		})
	end
end

------------------------------------------------------------------------

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
local GOLD = Color3.fromRGB(255, 214, 140)
local STEEL = Color3.fromRGB(205, 220, 240)
local EMBER = Color3.fromRGB(255, 120, 60)

-- Plays an effect and returns how much camera shake it should cause.
function Effects.play(kind, position, attacker)
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
	elseif kind == "Hit" then
		local at = anchorAt(position, 1.5)
		Effects.sound("Hit", at, 0.7)
		flipbook(at, TEX.impact, { size0 = 2.2, size1 = 4.6, duration = 0.28, color = WARM })
		sparks(at, 8, WARM, 38)
		return 0.18
	elseif kind == "HeavyHit" then
		local at = anchorAt(position, 2)
		Effects.sound("HeavyHit", at, 0.8)
		flipbook(at, TEX.impact, { size0 = 3.2, size1 = 7.5, duration = 0.34, color = WARM })
		sparks(at, 16, WARM, 52)
		smoke(at, 4, 1.4, 6)
		glow(at, 4, WARM, 0.18)
		return 0.38
	elseif kind == "Block" then
		local at = anchorAt(position, 1.5)
		Effects.sound("Block", at, 0.7, 0.9)
		flipbook(at, TEX.impact, { size0 = 1.6, size1 = 3.2, duration = 0.22, color = STEEL, transparency = 0.25 })
		sparks(at, 5, STEEL, 26)
		smoke(at, 2, 0.9, 4)
		return 0.1
	elseif kind == "Parry" then
		local at = anchorAt(position, 1.5)
		Effects.sound("Parry", at, 0.8)
		flipbook(at, TEX.parry, { size0 = 3, size1 = 8.5, duration = 0.36, color = GOLD, onTop = true })
		sparks(at, 22, GOLD, 60)
		glow(at, 5, GOLD, 0.16)
		flash(at, GOLD, 6, 14, 0.2)
		return 0.24
	elseif kind == "GuardBreak" then
		local at = anchorAt(position + Vector3.new(0, 0.6, 0), 2)
		Effects.sound("GuardBreak", at, 0.9)
		Effects.sound("HeavyHit", at, 0.7, 0.85)
		flipbook(at, TEX.parry, { size0 = 3.5, size1 = 10, duration = 0.42, color = EMBER, onTop = true })
		flipbook(at, TEX.impact, { size0 = 3, size1 = 8, duration = 0.4, color = WARM })
		sparks(at, 26, EMBER, 55)
		smoke(at, 6, 1.6, 7)
		flash(at, EMBER, 7, 16, 0.3)
		return 0.55
	elseif kind == "Slam" then
		local at = anchorAt(position + Vector3.new(0, 0.5, 0), 2)
		Effects.sound("HeavyHit", at, 0.9, 0.75)
		groundBurst(position, 14)
		sparks(at, 12, WARM, 40)
		return 0.6
	elseif kind == "Feint" then
		local at = anchorAt(position, 1)
		Effects.sound("Feint", at, 0.35, 1.25)
		return 0
	elseif kind == "Dodge" then
		local at = anchorAt(position, 1)
		smoke(at, 2, 1, 3, Color3.fromRGB(200, 200, 205))
		return 0
	end
	return 0
end

------------------------------------------------------------------------
-- Fist trails, switched on around each strike.

function Effects.attachTrails(model)
	local trails = {}
	for _, armName in ipairs({ "Right Arm", "Left Arm" }) do
		local arm = model:FindFirstChild(armName)
		if arm and not arm:FindFirstChild("FistTrail") then
			local a0 = Instance.new("Attachment")
			a0.Name = "FistTrailTop"
			a0.Position = Vector3.new(0, -0.55, 0)
			a0.Parent = arm
			local a1 = Instance.new("Attachment")
			a1.Name = "FistTrailBottom"
			a1.Position = Vector3.new(0, -1.05, 0)
			a1.Parent = arm
			local trail = Instance.new("Trail")
			trail.Name = "FistTrail"
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Texture = TEX.trail
			trail.TextureMode = Enum.TextureMode.Stretch
			trail.Lifetime = 0.14
			trail.MinLength = 0.05
			trail.LightEmission = 0.6
			trail.FaceCamera = true
			trail.Color = ColorSequence.new(Color3.fromRGB(255, 240, 220))
			trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
			trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.3) })
			trail.Enabled = false
			trail.Parent = arm
		end
		local trail = arm and arm:FindFirstChild("FistTrail")
		if trail then
			table.insert(trails, trail)
		end
	end
	return trails
end

function Effects.swingTrails(model, duration)
	for _, trail in ipairs(Effects.attachTrails(model)) do
		trail.Enabled = true
		task.delay(duration, function()
			trail.Enabled = false
		end)
	end
end

return Effects

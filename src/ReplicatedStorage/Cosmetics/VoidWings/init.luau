--[[
	Void Wings rig. Builds the wings on a torso and animates them.

		local rig = VoidWings.new(torso)                    -- in play: welded parts + particles + light
		local rig = VoidWings.new(torso, { Viewport = true }) -- ViewportFrame: anchored parts, no effects
		rig:Step(os.clock())  -- every frame
		rig:Destroy()

	Each feather is a thin invisible Part with the feather atlas as a Texture
	on its Back and Front faces. The sprite-sheet frame is picked with
	StudsPerTile (atlas = 2x2 cells, so twice the part) and OffsetStuds.
	Textures render in ViewportFrames too, so shop/inventory previews show the
	real wings.

	Mirroring: the right wing's Back face shows the right-wing atlas and its
	Front face the mirrored (left-wing) atlas, and the reverse on the left
	wing, so from any side each wing reads as the mirror of the other.
]]

local Data = require(script.VoidWingsData)
local Assets = require(script.VoidWingsAssets)

local TAU = 2 * math.pi
local rad = math.rad

local VIOLET = Color3.fromRGB(140, 40, 220)
local INDIGO = Color3.fromRGB(40, 10, 90)
local MAGENTA = Color3.fromRGB(255, 80, 220)
local PINK_WHITE = Color3.fromRGB(255, 220, 255)
local BLUE = Color3.fromRGB(90, 140, 255)

local function asset(key: string): string?
	local id = Assets[key]
	if type(id) == "number" then
		return "rbxassetid://" .. id
	elseif type(id) == "string" and id ~= "" then
		return if string.match(id, "^%d+$") then "rbxassetid://" .. id else id
	end
	return nil
end

local ATLAS = { R = {}, L = {} }
local TEXTURED = true
for a = 0, Data.Atlases - 1 do
	ATLAS.R[a] = asset("FeatherR_" .. a)
	ATLAS.L[a] = asset("FeatherL_" .. a)
	if not (ATLAS.R[a] and ATLAS.L[a]) then
		TEXTURED = false
	end
end

local FALLBACK_PARTICLE = "rbxasset://textures/particles/sparkles_main.dds"

local function frameCell(k: number): (number, number, number)
	local per = Data.Grid * Data.Grid
	k %= Data.Frames
	local atlas = k // per
	local sub = k % per
	local col, row = sub % Data.Grid, sub // Data.Grid
	if Assets.FrameFlipU then
		col = Data.Grid - 1 - col
	end
	if Assets.FrameFlipV then
		row = Data.Grid - 1 - row
	end
	return atlas, col, row
end

local VoidWings = {}
VoidWings.__index = VoidWings

-- Image ids to hand to ContentProvider:PreloadAsync so the first loop doesn't flicker.
function VoidWings.preloadList(): { string }
	local list = {}
	for a = 0, Data.Atlases - 1 do
		table.insert(list, ATLAS.R[a])
		table.insert(list, ATLAS.L[a])
	end
	for _, key in ipairs({ "Sparkle", "Mote", "Wisp" }) do
		local id = asset(key)
		if id then
			table.insert(list, id)
		end
	end
	return list
end

local function invisiblePart(name: string, size: Vector3, anchored: boolean): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Transparency = 1
	part.Anchored = anchored
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	return part
end

local function texture(part: BasePart, face: Enum.NormalId, w: number, h: number): Texture
	local tex = Instance.new("Texture")
	tex.Name = face.Name
	tex.Face = face
	tex.StudsPerTileU = Data.Grid * w
	tex.StudsPerTileV = Data.Grid * h
	tex.Parent = part
	return tex
end

function VoidWings.new(torso: BasePart, opts: { Viewport: boolean?, Parent: Instance?, Scale: number?, Effects: boolean? }?)
	local options = opts or {}
	local self = setmetatable({}, VoidWings)
	self.Torso = torso
	self.Viewport = options.Viewport == true
	self.Scale = (options.Scale or 1) * Data.Scale
	self.TimeOffset = math.random() * 20
	self.Feathers = {}
	self.Emitters = {}
	self.Enabled = true

	-- UpperTorso (R15) is shorter than the R6 Torso; drop the root to the shoulder blades
	local rootY = Data.WingRoot[2] + (if torso.Name == "UpperTorso" then -0.3 else 0)
	self.Root = Vector3.new(Data.WingRoot[1], rootY, Data.WingRoot[3]) * self.Scale

	local model = Instance.new("Model")
	model.Name = "VoidWings"
	self.Model = model
	self.Parent = options.Parent or torso.Parent

	for _, side in ipairs({ 1, -1 }) do
		for i, fe in ipairs(Data.Feathers) do
			local length = fe.Length * self.Scale
			local w, h = Data.FrameW * length, Data.FrameH * length
			local part = invisiblePart((if side == 1 then "R" else "L") .. i, Vector3.new(w, h, 0.05), self.Viewport)
			local feather = {
				Part = part,
				Side = side,
				Index = i,
				Data = fe,
				W = w,
				H = h,
				Frame = -1,
				Base = CFrame.new(side * fe.Base[1] * self.Scale, fe.Base[2] * self.Scale, fe.Depth * self.Scale),
				-- the part's centre relative to the feather's base point
				Offset = CFrame.new(side * (0.5 - Data.BaseU) * w, (Data.BaseV - 0.5) * h, 0),
				Emit = Vector3.new(side * (Data.EmitU - 0.5) * w, (0.5 - Data.EmitV) * h, 0),
			}
			if TEXTURED then
				feather.Back = texture(part, Enum.NormalId.Back, w, h)
				feather.Front = texture(part, Enum.NormalId.Front, w, h)
				feather.BackSet = if side == 1 then ATLAS.R else ATLAS.L
				feather.FrontSet = if side == 1 then ATLAS.L else ATLAS.R
			else
				-- no atlases uploaded yet: plain neon blades in the same layout
				part.Size = Vector3.new(0.1 * length, 0.95 * length, 0.05)
				part.Transparency = 0.15
				part.Material = Enum.Material.Neon
				part.Color = VIOLET
				feather.Offset = CFrame.new(0, 0.475 * length, 0)
				feather.Emit = Vector3.new(0, 0.2 * length, 0)
			end
			if not self.Viewport then
				local weld = Instance.new("Weld")
				weld.Part0 = torso
				weld.Part1 = part
				weld.Parent = part
				feather.Weld = weld
			end
			part.Parent = model
			table.insert(self.Feathers, feather)
		end
	end

	if not self.Viewport and options.Effects ~= false then
		self:_addEffects()
	end

	self:Step(0)
	model.Parent = self.Parent
	return self
end

local function emitter(props): ParticleEmitter
	local pe = Instance.new("ParticleEmitter")
	pe.LightEmission = 1
	pe.LightInfluence = 0
	pe.ZOffset = 0.2
	for key, value in pairs(props) do
		pe[key] = value
	end
	return pe
end

function VoidWings:_addEffects()
	local mote = asset("Mote") or FALLBACK_PARTICLE
	local sparkle = asset("Sparkle") or FALLBACK_PARTICLE
	local wisp = asset("Wisp") or FALLBACK_PARTICLE
	local s = self.Scale

	for _, f in ipairs(self.Feathers) do
		local i = f.Index
		local wants = { dust = i == 2 or i == 4 or i == 6 or i == 7, sparkle = i == 3 or i == 5, wisp = i == 4 }
		if wants.dust or wants.sparkle or wants.wisp then
			local att = Instance.new("Attachment")
			att.Name = "Emit"
			att.Position = f.Emit
			att.Parent = f.Part
			if wants.dust then
				-- void dust shedding off the feathers and drifting down
				table.insert(self.Emitters, emitter({
					Name = "VoidDust",
					Texture = mote,
					Color = ColorSequence.new(VIOLET, INDIGO),
					Size = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0.16 * s),
						NumberSequenceKeypoint.new(1, 0),
					}),
					Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0.15),
						NumberSequenceKeypoint.new(0.7, 0.45),
						NumberSequenceKeypoint.new(1, 1),
					}),
					Lifetime = NumberRange.new(1.2, 2.4),
					Rate = 7,
					Speed = NumberRange.new(0.3, 0.9),
					SpreadAngle = Vector2.new(180, 180),
					Acceleration = Vector3.new(0, -1.1, 0),
					Drag = 1.2,
					EmissionDirection = Enum.NormalId.Back,
					Parent = att,
				}))
			end
			if wants.sparkle then
				-- 4-point star sparkles that twinkle as they fall away
				table.insert(self.Emitters, emitter({
					Name = "Sparkles",
					Texture = sparkle,
					Color = ColorSequence.new(PINK_WHITE, MAGENTA),
					Size = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(0.25, 0.38 * s),
						NumberSequenceKeypoint.new(0.5, 0.12 * s),
						NumberSequenceKeypoint.new(0.75, 0.3 * s),
						NumberSequenceKeypoint.new(1, 0),
					}),
					Lifetime = NumberRange.new(0.7, 1.2),
					Rate = 2.5,
					Speed = NumberRange.new(0.2, 0.6),
					SpreadAngle = Vector2.new(180, 180),
					Acceleration = Vector3.new(0, -0.6, 0),
					Rotation = NumberRange.new(0, 45),
					Parent = att,
				}))
			end
			if wants.wisp then
				-- rare electric-blue / violet wisps
				table.insert(self.Emitters, emitter({
					Name = "Wisps",
					Texture = wisp,
					Color = ColorSequence.new(BLUE, VIOLET),
					Size = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0.3 * s),
						NumberSequenceKeypoint.new(1, 0.9 * s),
					}),
					Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 1),
						NumberSequenceKeypoint.new(0.3, 0.55),
						NumberSequenceKeypoint.new(1, 1),
					}),
					Lifetime = NumberRange.new(1.4, 2.2),
					Rate = 0.7,
					Speed = NumberRange.new(0.3, 0.7),
					SpreadAngle = Vector2.new(180, 180),
					Acceleration = Vector3.new(0, -0.4, 0),
					Rotation = NumberRange.new(0, 360),
					RotSpeed = NumberRange.new(-30, 30),
					Parent = att,
				}))
			end
		end
	end

	-- faint purple light on the wearer
	local att = Instance.new("Attachment")
	att.Name = "VoidWingsLight"
	att.Position = self.Root + Vector3.new(0, 0.6, 0.8)
	local light = Instance.new("PointLight")
	light.Color = VIOLET
	light.Brightness = 1.1
	light.Range = 9 * s
	light.Shadows = false
	light.Parent = att
	att.Parent = self.Torso
	self.LightAttachment = att
	self.Light = light
end

function VoidWings:Step(now: number)
	local t = now + self.TimeOffset
	local beat = math.sin(TAU * Data.BeatHz * t)
	local breathe = Data.BreatheStuds * math.sin(TAU * Data.BreatheHz * t)
	local frameNow = math.floor(t * Data.Fps)
	local root = self.Root

	local wing = {}
	for _, side in ipairs({ 1, -1 }) do
		wing[side] = CFrame.new(side * root.X, root.Y + breathe, root.Z)
			* CFrame.Angles(0, -side * rad(Data.Sweep + Data.BeatDeg * beat), 0)
			* CFrame.Angles(rad(Data.Tilt), 0, 0)
			* CFrame.Angles(0, 0, side * rad(Data.BeatLiftDeg * beat))
	end

	local torsoCFrame = self.Viewport and self.Torso.CFrame
	for _, f in ipairs(self.Feathers) do
		local fe = f.Data
		local flutter = fe.Flutter * math.sin(TAU * Data.BeatHz * 2 * t - fe.Phase)
		local cf = wing[f.Side] * f.Base * CFrame.Angles(0, 0, -f.Side * rad(fe.Angle + flutter)) * f.Offset
		if f.Weld then
			f.Weld.C0 = cf
		else
			f.Part.CFrame = torsoCFrame * cf
		end

		if f.Back then
			local k = (frameNow + fe.Frame) % Data.Frames
			if k ~= f.Frame then
				f.Frame = k
				local atlas, col, row = frameCell(k)
				local u, v = col * f.W, row * f.H
				f.Back.Texture = f.BackSet[atlas]
				f.Front.Texture = f.FrontSet[atlas]
				f.Back.OffsetStudsU, f.Back.OffsetStudsV = u, v
				f.Front.OffsetStudsU, f.Front.OffsetStudsV = u, v
			end
		end
	end

	if self.Light then
		-- the halo flickers with the flow
		self.Light.Brightness = 1.05 + 0.25 * math.sin(t * 3.1) * math.sin(t * 1.7 + 0.6)
	end
end

-- Hide (and stop emitting) without tearing the rig down, e.g. when far away.
function VoidWings:SetEnabled(on: boolean)
	if on == self.Enabled then
		return
	end
	self.Enabled = on
	self.Model.Parent = if on then self.Parent else nil
	for _, pe in ipairs(self.Emitters) do
		pe.Enabled = on
	end
	if self.Light then
		self.Light.Enabled = on
	end
end

function VoidWings:Destroy()
	self.Model:Destroy()
	if self.LightAttachment then
		self.LightAttachment:Destroy()
	end
	table.clear(self.Feathers)
	table.clear(self.Emitters)
end

return VoidWings

--[[
	Custom HUD built from the uploaded ui atlas (Config.Textures.ui):

	  Health bar  ornate frame over a red molten fill. Damage snaps the fill
	              down, a pale trail holds for a beat then slides after it,
	              and the bar shakes with the hit. Low health trembles.
	  Shield      floating over every fighter's head: fills with posture,
	              shifts white -> amber -> red, and shatters on guard break.

	No text anywhere.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local ATLAS = Config.Textures.ui
local A = Config.Atlas

local HUD = {}

local random = Random.new()

local function atlasImage(key, parent)
	local rect = A[key]
	local image = Instance.new("ImageLabel")
	image.Name = key
	image.BackgroundTransparency = 1
	image.Image = ATLAS
	image.ImageRectOffset = Vector2.new(rect[1], rect[2])
	image.ImageRectSize = Vector2.new(rect[3], rect[4])
	image.ScaleType = Enum.ScaleType.Stretch
	image.Parent = parent
	return image
end

------------------------------------------------------------------------
-- Health bar

local BAR_W, BAR_H = 480, 90 -- 1024x192 source at ~0.47x
local SCALE = BAR_W / 1024
local SLOT_X = A.BarSlot[1] * SCALE
local SLOT_W = A.BarSlot[2] * SCALE

local function clipped(key, parent, z)
	local clip = Instance.new("Frame")
	clip.Name = key .. "Clip"
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.Size = UDim2.fromOffset(BAR_W, BAR_H)
	clip.ZIndex = z
	clip.Parent = parent
	local image = atlasImage(key, clip)
	image.Size = UDim2.fromOffset(BAR_W, BAR_H)
	image.ZIndex = z
	return clip, image
end

function HUD.createHealthBar(player)
	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local holder = Instance.new("Frame")
	holder.Name = "HealthBar"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -28)
	holder.Size = UDim2.fromOffset(BAR_W, BAR_H)
	holder.Parent = gui

	local scale = Instance.new("UIScale")
	scale.Parent = holder

	-- `shaker` moves inside `holder` so shaking never shifts the layout
	local shaker = Instance.new("Frame")
	shaker.BackgroundTransparency = 1
	shaker.Size = UDim2.fromOffset(BAR_W, BAR_H)
	shaker.Parent = holder

	local trough = atlasImage("BarTrough", shaker)
	trough.Size = UDim2.fromOffset(BAR_W, BAR_H)
	trough.ZIndex = 1
	local trailClip, trail = clipped("BarTrail", shaker, 2)
	trail.ImageColor3 = Color3.fromRGB(255, 214, 180)
	local fillClip, fill = clipped("BarFill", shaker, 3)
	local tip = atlasImage("BarTip", shaker)
	tip.Size = UDim2.fromOffset(A.BarTip[3] * SCALE, A.BarTip[4] * SCALE)
	tip.AnchorPoint = Vector2.new(0.72, 0)
	tip.ZIndex = 4
	local frame = atlasImage("BarFrame", shaker)
	frame.Size = UDim2.fromOffset(BAR_W, BAR_H)
	frame.ZIndex = 5

	local state = {
		fill = 1,
		trail = 1,
		target = 1,
		trailHoldUntil = 0,
		shake = 0,
		flash = 0,
		nextTremble = os.clock() + 2,
		humanoid = nil,
		lastHealth = nil,
	}

	local function widthFor(fraction)
		if fraction <= 0.001 then
			return 0
		end
		return SLOT_X + SLOT_W * fraction
	end

	local function bind(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if not humanoid then
			return
		end
		state.humanoid = humanoid
		state.lastHealth = humanoid.Health
		state.target = humanoid.Health / humanoid.MaxHealth
		state.fill, state.trail = state.target, state.target
		humanoid.HealthChanged:Connect(function(health)
			if state.humanoid ~= humanoid then
				return
			end
			local fraction = math.clamp(health / humanoid.MaxHealth, 0, 1)
			local lost = (state.lastHealth or health) - health
			state.lastHealth = health
			state.target = fraction
			if lost > 0.01 then
				state.trailHoldUntil = os.clock() + 0.38
				state.shake = math.max(state.shake, math.clamp(lost / humanoid.MaxHealth * 55, 2.5, 9))
				state.flash = 1
			end
		end)
	end

	player.CharacterAdded:Connect(bind)
	if player.Character then
		task.spawn(bind, player.Character)
	end

	RunService.RenderStepped:Connect(function(dt)
		local camera = workspace.CurrentCamera
		if camera then
			scale.Scale = math.clamp(camera.ViewportSize.X / 1500, 0.65, 1.15)
		end

		-- fill: snaps down fast, heals up smoothly
		if state.target < state.fill then
			state.fill += (state.target - state.fill) * math.min(1, dt * 28)
		else
			state.fill += (state.target - state.fill) * math.min(1, dt * 4)
		end
		-- trail: holds, then slides down after the fill
		if state.trail < state.fill then
			state.trail = state.fill
		elseif os.clock() > state.trailHoldUntil then
			state.trail += (state.fill - state.trail) * math.min(1, dt * 5)
		end

		fillClip.Size = UDim2.fromOffset(widthFor(state.fill), BAR_H)
		trailClip.Size = UDim2.fromOffset(widthFor(state.trail), BAR_H)
		tip.Position = UDim2.fromOffset(widthFor(state.fill), 0)
		tip.Visible = state.fill > 0.005 and state.fill < 0.999

		-- hit flash: the fill burns brighter for a moment
		state.flash = math.max(0, state.flash - dt * 5)
		local f = state.flash
		fill.ImageColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 236, 220), f)
		frame.ImageColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 170, 160), f * 0.6)

		-- low health: occasional tremble and a slow pulse on the tip
		local now = os.clock()
		if state.fill < 0.35 and state.fill > 0 and now > state.nextTremble then
			state.shake = math.max(state.shake, 1.6)
			state.nextTremble = now + random:NextNumber(1.4, 2.8)
		end
		local pulse = state.fill < 0.35 and (0.5 + 0.5 * math.sin(now * 6)) or 0
		tip.ImageTransparency = 0.15 * pulse

		if state.shake > 0.05 then
			local s = state.shake
			shaker.Position = UDim2.fromOffset(random:NextNumber(-s, s), random:NextNumber(-s, s) * 0.6)
			shaker.Rotation = random:NextNumber(-s, s) * 0.12
			state.shake *= math.exp(-dt * 11)
		else
			state.shake = 0
			shaker.Position = UDim2.new()
			shaker.Rotation = 0
		end
	end)

	return gui
end

------------------------------------------------------------------------
-- Posture shield over each fighter

local WHITE = Color3.fromRGB(240, 240, 236)
local AMBER = Color3.fromRGB(255, 186, 74)
local RED = Color3.fromRGB(235, 52, 40)

local function postureColour(fraction)
	if fraction < 0.55 then
		return WHITE:Lerp(AMBER, fraction / 0.55)
	end
	return AMBER:Lerp(RED, math.clamp((fraction - 0.55) / 0.4, 0, 1))
end

local shields = {}

function HUD.attachShield(model)
	if shields[model] then
		return
	end
	local head = model:WaitForChild("Head", 10)
	if not head then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "PostureShield"
	gui.Adornee = head
	gui.Size = UDim2.fromScale(2.3, 2.3)
	gui.StudsOffset = Vector3.new(0, 4.1, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 80
	gui.ResetOnSpawn = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui

	local frame = atlasImage("ShieldFrame", root)
	frame.Size = UDim2.fromScale(1, 1)
	frame.ZIndex = 1

	local clip = Instance.new("Frame")
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.AnchorPoint = Vector2.new(0, 1)
	clip.Position = UDim2.fromScale(0, 1)
	clip.Size = UDim2.fromScale(1, 0)
	clip.ZIndex = 2
	clip.Parent = root
	local fill = atlasImage("ShieldFill", clip)
	fill.AnchorPoint = Vector2.new(0, 1)
	fill.Position = UDim2.fromScale(0, 1)
	fill.ZIndex = 2

	local broken = atlasImage("ShieldBroken", root)
	broken.AnchorPoint = Vector2.new(0.5, 0.5)
	broken.Position = UDim2.fromScale(0.5, 0.5)
	broken.Size = UDim2.fromScale(1, 1)
	broken.ZIndex = 3
	broken.Visible = false

	local s = {
		gui = gui,
		shown = 0,
		posture = 0,
		brokenAt = nil,
		lastActive = 0,
		pulse = 0,
	}
	shields[model] = s

	local lastPosture = 0
	model:GetAttributeChangedSignal("Posture"):Connect(function()
		local p = model:GetAttribute("Posture") or 0
		if p > lastPosture + 0.5 then
			s.pulse = 1 -- took posture: shield flinches
		end
		lastPosture = p
	end)
	model:GetAttributeChangedSignal("CombatState"):Connect(function()
		if model:GetAttribute("CombatState") == "GuardBroken" then
			s.brokenAt = os.clock()
		end
	end)

	local function cleanup()
		shields[model] = nil
		gui:Destroy()
	end
	model.Destroying:Once(cleanup)
	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanup()
		end
	end)

	s.update = function(dt)
		local now = os.clock()
		local posture = (model:GetAttribute("Posture") or 0) / Config.MaxPosture
		local state = model:GetAttribute("CombatState")
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local alive = humanoid and humanoid.Health > 0

		s.posture += (posture - s.posture) * math.min(1, dt * 14)
		if posture > 0.01 or state == "Blocking" then
			s.lastActive = now
		end

		-- shattered shield: pops, shakes and fades out
		if s.brokenAt then
			local t = (now - s.brokenAt) / 0.9
			if t >= 1 then
				s.brokenAt = nil
				broken.Visible = false
			else
				broken.Visible = true
				frame.Visible, clip.Visible = false, false
				local pop = 1 + 0.45 * (1 - (1 - math.min(1, t * 3)) ^ 3)
				broken.Size = UDim2.fromScale(pop, pop)
				broken.Rotation = random:NextNumber(-1, 1) * 9 * (1 - t)
				broken.ImageTransparency = t ^ 2
				gui.Enabled = alive
				return
			end
		end
		frame.Visible, clip.Visible = true, true

		local wantShown = alive and (now - s.lastActive < 1.2) and 1 or 0
		s.shown += (wantShown - s.shown) * math.min(1, dt * 8)
		gui.Enabled = s.shown > 0.02

		local fraction = math.clamp(s.posture, 0, 1)
		clip.Size = UDim2.fromScale(1, fraction)
		if fraction > 0.001 then
			fill.Size = UDim2.fromScale(1, 1 / fraction)
		end
		fill.ImageColor3 = postureColour(fraction)

		s.pulse = math.max(0, s.pulse - dt * 6)
		local bump = 1 + 0.12 * s.pulse + (fraction > 0.8 and 0.04 * math.sin(now * 18) or 0)
		root.Size = UDim2.fromScale(bump, bump)
		root.Rotation = s.pulse * random:NextNumber(-6, 6)

		local fade = 1 - s.shown
		frame.ImageTransparency = fade
		fill.ImageTransparency = fade + (state == "Blocking" and 0 or 0.1)
	end
end

------------------------------------------------------------------------
-- Mini health bar over everyone else (same art as the main bar)

local miniBars = {}
local SLOT_LEFT = A.BarSlot[1] / 1024
local SLOT_SPAN = A.BarSlot[2] / 1024

function HUD.attachMiniBar(model)
	if miniBars[model] then
		return
	end
	local head = model:WaitForChild("Head", 10)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not head or not humanoid then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "MiniHealth"
	gui.Adornee = head
	gui.Size = UDim2.fromScale(4.4, 0.83)
	gui.StudsOffset = Vector3.new(0, 2.35, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 90
	gui.ResetOnSpawn = false
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local shaker = Instance.new("Frame")
	shaker.BackgroundTransparency = 1
	shaker.Size = UDim2.fromScale(1, 1)
	shaker.Parent = gui

	local function layer(key, z, parent)
		local image = atlasImage(key, parent or shaker)
		image.Size = UDim2.fromScale(1, 1)
		image.ZIndex = z
		return image
	end
	local function clipLayer(key, z)
		local clip = Instance.new("Frame")
		clip.BackgroundTransparency = 1
		clip.ClipsDescendants = true
		clip.Size = UDim2.fromScale(1, 1)
		clip.ZIndex = z
		clip.Parent = shaker
		return clip, layer(key, z, clip)
	end

	layer("BarTrough", 1)
	local trailClip, trail = clipLayer("BarTrail", 2)
	trail.ImageColor3 = Color3.fromRGB(255, 214, 180)
	local fillClip, fill = clipLayer("BarFill", 3)
	layer("BarFrame", 4)

	local m = {
		fill = humanoid.Health / humanoid.MaxHealth,
		trail = humanoid.Health / humanoid.MaxHealth,
		target = humanoid.Health / humanoid.MaxHealth,
		hold = 0,
		shake = 0,
		last = humanoid.Health,
	}
	miniBars[model] = m

	humanoid.HealthChanged:Connect(function(health)
		local lost = m.last - health
		m.last = health
		m.target = math.clamp(health / humanoid.MaxHealth, 0, 1)
		if lost > 0.01 then
			m.hold = os.clock() + 0.38
			m.shake = math.max(m.shake, math.clamp(lost / humanoid.MaxHealth * 0.18, 0.015, 0.04))
		end
	end)

	local function cleanup()
		miniBars[model] = nil
		gui:Destroy()
	end
	model.Destroying:Once(cleanup)
	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanup()
		end
	end)

	local function width(fraction)
		if fraction <= 0.001 then
			return 0
		end
		return SLOT_LEFT + SLOT_SPAN * fraction
	end

	m.update = function(dt)
		gui.Enabled = humanoid.Health > 0
		if m.target < m.fill then
			m.fill += (m.target - m.fill) * math.min(1, dt * 28)
		else
			m.fill += (m.target - m.fill) * math.min(1, dt * 4)
		end
		if m.trail < m.fill then
			m.trail = m.fill
		elseif os.clock() > m.hold then
			m.trail += (m.fill - m.trail) * math.min(1, dt * 5)
		end
		local fw, tw = width(m.fill), width(m.trail)
		fillClip.Size = UDim2.fromScale(fw, 1)
		fill.Size = UDim2.fromScale(fw > 0 and 1 / fw or 1, 1)
		trailClip.Size = UDim2.fromScale(tw, 1)
		trail.Size = UDim2.fromScale(tw > 0 and 1 / tw or 1, 1)
		if m.shake > 0.001 then
			shaker.Position = UDim2.fromScale(random:NextNumber(-m.shake, m.shake), random:NextNumber(-m.shake, m.shake) * 2)
			m.shake *= math.exp(-dt * 11)
		else
			m.shake = 0
			shaker.Position = UDim2.new()
		end
	end
end

RunService.RenderStepped:Connect(function(dt)
	for _, s in pairs(shields) do
		s.update(dt)
	end
	for _, m in pairs(miniBars) do
		m.update(dt)
	end
end)

return HUD

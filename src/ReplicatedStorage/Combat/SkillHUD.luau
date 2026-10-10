-- Skill HUD presentation only. CombatClient supplies the existing gameplay path.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Preview = require(script.Parent.SkillPreview)
local Art = require(script.Parent.SkillArt)

local SkillHUD = {}
local mounted = nil
local WHITE = Color3.fromRGB(239, 242, 237)
local MUTED = Color3.fromRGB(117, 128, 133)
local FONT = Font.new("rbxasset://fonts/families/Sarpanch.json", Enum.FontWeight.Bold)
local DEFINITIONS = {
	{ key = "Y", name = "HEAD DRIVE", accent = Color3.fromRGB(218, 183, 112), position = Vector2.new(0, 0) },
	{ key = "H", name = "LOW SWEEP", accent = Color3.fromRGB(117, 183, 154), position = Vector2.new(156, 0) },
}

local function make(className, props, parent)
	local object = Instance.new(className)
	for key, value in pairs(props) do object[key] = value end
	object.Parent = parent
	return object
end

function SkillHUD.mount(adapter)
	assert(type(adapter.activate) == "function" and type(adapter.getState) == "function", "SkillHUD needs combat callbacks")
	if mounted then mounted:Destroy() end
	local player = Players.LocalPlayer
	local connections, tweens, buttons = {}, {}, {}
	local alive = true
	local artworkTime = 0
	local gui = make("ScreenGui", {
		Name = "SkillHUD", ResetOnSpawn = false, DisplayOrder = 5,
		ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	}, player:WaitForChild("PlayerGui"))
	local bounds = make("Frame", {Name = "SafeBounds", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1}, gui)
	local root = make("Frame", {
		Name = "StaggeredSkills", AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16), Size = UDim2.fromOffset(300, 144), BackgroundTransparency = 1,
	}, bounds)
	local layoutScale = make("UIScale", {Scale = 1}, root)
	local self = { Gui = gui }
	mounted = self
	local function connect(signal, callback)
		local connection = signal:Connect(callback)
		table.insert(connections, connection)
		return connection
	end
	local function animate(object, channel, duration, props, style)
		local channels = tweens[object]
		if not channels then channels = {}; tweens[object] = channels end
		if channels[channel] then channels[channel]:Cancel() end
		local tween = TweenService:Create(object, TweenInfo.new(duration, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
		channels[channel] = tween
		tween:Play()
	end
	local function label(parent, name, text, x, y, w, h, size, color, z)
		return make("TextLabel", {
			Name = name, Text = text, Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h),
			BackgroundTransparency = 1, FontFace = FONT, TextSize = size, TextColor3 = color or WHITE,
			TextStrokeColor3 = Color3.fromRGB(8, 12, 15), TextStrokeTransparency = 0.7,
			TextXAlignment = Enum.TextXAlignment.Left, ZIndex = z or 10,
		}, parent)
	end
	local function settle(button, style)
		local interactive = button.state and button.state.pressable
		local hovered = button.hover and interactive
		animate(button.scale, "scale", 0.22, {Scale = hovered and 1.06 or 1}, style or Enum.EasingStyle.Back)
		animate(button.face, "lift", 0.16, {Position = UDim2.fromOffset(0, hovered and -4 or 0)})
		local unavailable = button.mode == "unavailable"
		local color = unavailable and MUTED or button.accent
		animate(button.border, "border", 0.15, {
			Color = hovered and color:Lerp(WHITE, 0.4) or color,
			Thickness = hovered and 2.4 or 1.6,
			Transparency = unavailable and 0.55 or (button.mode == "cooldown" and 0.36 or 0.10),
		})
	end
	local function flash(button, ready)
		button.flash.BackgroundColor3 = ready and button.accent or WHITE
		button.flash.BackgroundTransparency = ready and 0.8 or 0.68
		animate(button.flash, "flash", 0.32, {BackgroundTransparency = 1})
		button.pulse.Transparency = 0.1
		animate(button.pulse, "pulse", 0.48, {Transparency = 1, Thickness = 1})
		button.scale.Scale = ready and 0.975 or 0.94
		settle(button, Enum.EasingStyle.Back)
	end
	local function rescale()
		local size = bounds.AbsoluteSize
		if size.X < 1 or size.Y < 1 then return end
		-- A single transparent row keeps Head Drive first and Low Sweep second.
		local scale = math.clamp(math.min(size.X / 1280, size.Y / 851) * 0.76, 0.60, 0.86)
		scale = math.min(scale, (size.X - 32) / 300, (size.Y - 80) / 144)
		layoutScale.Scale = math.max(0.35, scale) * 0.85
		local halfWidth = 150 * layoutScale.Scale
		local centerX = math.clamp(size.X * 0.5, halfWidth + 12, math.max(halfWidth + 12, size.X - halfWidth - 12))
		root.Position = UDim2.fromScale(centerX / size.X, (size.Y - 16) / size.Y)
	end
	connect(bounds:GetPropertyChangedSignal("AbsoluteSize"), rescale)
	rescale()

	for _, definition in ipairs(DEFINITIONS) do
		local slot = make("Frame", {Name = definition.key, Size = UDim2.fromOffset(144, 144), Position = UDim2.fromOffset(definition.position.X, definition.position.Y), BackgroundTransparency = 1}, root)
		local scale = make("UIScale", {}, slot)
		local lip = make("Frame", {Name = "Shadow", Position = UDim2.fromOffset(0, 3), Size = UDim2.fromScale(1, 1), BackgroundColor3 = definition.accent:Lerp(Color3.new(), 0.85), BackgroundTransparency = 0.12, BorderSizePixel = 0}, slot)
		make("UICorner", {CornerRadius = UDim.new(0, 9)}, lip)
		local face = make("TextButton", {
			Name = "Activate", Size = UDim2.fromScale(1, 1), Text = "", AutoButtonColor = false,
			BackgroundColor3 = Color3.fromRGB(12, 20, 25), BackgroundTransparency = 0.14,
			BorderSizePixel = 0, ClipsDescendants = true, Active = true, Selectable = true,
		}, slot)
		make("UICorner", {CornerRadius = UDim.new(0, 9)}, face)
		make("UIGradient", {Color = ColorSequence.new(Color3.fromRGB(41, 50, 55), Color3.fromRGB(13, 19, 24)), Rotation = 90}, face)
		local artwork = Art.decorate(face, definition.accent, definition.key)
		local border = make("UIStroke", {Name = "Border", Color = definition.accent, Thickness = 1.6, Transparency = 0.1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, face)
		local pulse = make("UIStroke", {Name = "Pulse", Color = definition.accent, Thickness = 1, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, slot)
		local viewport = make("ViewportFrame", {
			Name = "MovePreview", Position = UDim2.fromOffset(4, 6), Size = UDim2.fromOffset(136, 106),
			BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 4,
		}, face)
		local fill = make("Frame", {
			Name = "CooldownDrain", Size = UDim2.fromScale(1, 1), Visible = false,
			BackgroundColor3 = Color3.fromRGB(6, 11, 17), BackgroundTransparency = 0.26, BorderSizePixel = 0, ZIndex = 8,
		}, face)
		make("UICorner", {CornerRadius = UDim.new(0, 9)}, fill)
		-- Keep mask geometry fixed. A feathered shader edge moves smoothly below
		-- pixel boundaries and remains visible through the entire card/footer.
		local fillGradient = make("UIGradient", {
			Name = "DrainMask", Rotation = 90, Offset = Vector2.new(0, 0.52),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.48, 1),
				NumberSequenceKeypoint.new(0.52, 0),
				NumberSequenceKeypoint.new(1, 0),
			}),
		}, fill)
		local footer = make("Frame", {Name = "Footer", Position = UDim2.fromOffset(0, 99), Size = UDim2.fromOffset(144, 45), BackgroundColor3 = definition.accent:Lerp(Color3.fromRGB(7, 10, 12), 0.88), BackgroundTransparency = 0.16, BorderSizePixel = 0, ZIndex = 7}, face)
		make("UIGradient", {Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.34, 0.1), NumberSequenceKeypoint.new(1, 0)}), Rotation = 90}, footer)
		label(face, "MoveName", definition.name, 9, 107, 127, 19, 17, WHITE, 9)
		local status = label(face, "Status", "READY", 20, 125, 115, 15, 12, definition.accent, 9)
		local dot = make("Frame", {Name = "StatusDot", Position = UDim2.fromOffset(10, 131), Size = UDim2.fromOffset(4, 4), BackgroundColor3 = definition.accent, BorderSizePixel = 0, ZIndex = 9}, face)
		local badge = make("Frame", {Name = "KeyBadge", Position = UDim2.fromOffset(8, 8), Size = UDim2.fromOffset(30, 30), Rotation = definition.key == "Y" and -4 or 4, BackgroundColor3 = definition.accent:Lerp(Color3.fromRGB(8, 12, 14), 0.62), BackgroundTransparency = 0, BorderSizePixel = 0, ZIndex = 9}, face)
		make("UICorner", {CornerRadius = UDim.new(0, 7)}, badge)
		make("UIStroke", {Color = definition.accent:Lerp(WHITE, 0.35), Thickness = 1.6, Transparency = 0.1}, badge)
		local key = label(badge, "Key", definition.key, 0, -1, 30, 30, 27, WHITE, 10)
		key.TextXAlignment = Enum.TextXAlignment.Center
		local countdown = label(face, "Seconds", "", 6, 52, 132, 34, 29, WHITE, 10)
		countdown.TextXAlignment = Enum.TextXAlignment.Center
		local flashFrame = make("Frame", {Name = "ActivationLight", Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 6}, face)
		local button = {face = face, scale = scale, border = border, pulse = pulse, flash = flashFrame, viewport = viewport, fill = fill, fillGradient = fillGradient, status = status, dot = dot, countdown = countdown,
			accent = definition.accent, artwork = artwork, preview = Preview.new(viewport, definition.key, definition.accent), hover = false, state = nil, mode = "", fraction = 0, activationId = nil, character = nil, pressToken = 0}
		buttons[definition.key] = button
		connect(face.MouseEnter, function() button.hover = true; settle(button) end)
		connect(face.MouseLeave, function() button.hover = false; button.pressToken += 1; settle(button) end)
		connect(face.SelectionGained, function() button.hover = true; settle(button) end)
		connect(face.SelectionLost, function() button.hover = false; settle(button) end)
		connect(face.InputBegan, function(input)
			if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and button.state and button.state.pressable then
				animate(scale, "scale", 0.065, {Scale = 0.94})
			end
		end)
		connect(face.InputEnded, function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then settle(button) end
		end)
		connect(face.Activated, function() self:Activate(definition.key) end)
	end

	function self:Activate(key)
		if not alive then return false end
		local button = buttons[key]
		if not button then return false end
		local state = adapter.getState(key)
		-- The adapter applies exactly the same gameplay checks for all inputs.
		local result = adapter.activate(key)
		button.pressToken += 1
		local token = button.pressToken
		if state.pressable then
			animate(button.scale, "scale", 0.065, {Scale = 0.94})
			task.delay(0.07, function()
				if alive and token == button.pressToken then settle(button) end
			end)
		else
			button.border.Color = Color3.fromRGB(164, 127, 125)
			animate(button.border, "border", 0.18, {Color = button.mode == "cooldown" and button.accent or MUTED})
		end
		return result
	end

	connect(RunService.RenderStepped, function(dt)
		local hidden = player:GetAttribute("InMenu") == true or player:GetAttribute("DisclaimerOpen") == true
		root.Visible = not hidden
		if not hidden then artworkTime += math.min(dt, 0.1) end
		local serverNow = workspace:GetServerTimeNow()
		for key, button in pairs(buttons) do
			local state = adapter.getState(key)
			button.state = state
			local changedCharacter = button.character ~= state.character
			if changedCharacter then
				button.character = state.character
				button.mode, button.fraction, button.activationId, button.readyPulsePending = "", 0, state.activationId, false
				button.drainReadyAt, button.drainStartedAt, button.drainStartFraction = nil, nil, nil
			end
			local readyAt = state.readyAt or 0
			local remaining = math.max(0, readyAt - serverNow)
			local cooling = remaining > 0
			local mode = cooling and "cooldown" or (state.pending and "pending" or (state.queued and "queued" or (state.available and "ready" or "unavailable")))
			local oldMode = button.mode
			if mode ~= oldMode then
				button.mode = mode
				local unavailable = mode == "unavailable"
				animate(button.viewport, "dim", 0.2, {ImageColor3 = unavailable and Color3.fromRGB(104, 112, 122) or (cooling and Color3.fromRGB(133, 145, 151) or WHITE)})
				button.dot.BackgroundColor3 = unavailable and MUTED or button.accent
				button.status.TextColor3 = unavailable and MUTED or button.accent
				settle(button)
				if oldMode == "cooldown" then button.readyPulsePending = true end
				if mode == "ready" and button.readyPulsePending and not changedCharacter then
					button.readyPulsePending = false
					flash(button, true)
				end
			end
			if state.activationId ~= button.activationId then
				if button.activationId ~= nil and not changedCharacter then flash(button, false); button.preview:Replay() end
				button.activationId = state.activationId
			end
			if cooling then
				if not button.drainReadyAt or button.drainReadyAt <= serverNow then
					button.drainStartedAt, button.drainReadyAt = serverNow, readyAt
					button.drainStartFraction = math.clamp(remaining / math.max(0.01, state.duration or 1), 0, 1)
				elseif readyAt ~= button.drainReadyAt then
					-- Continue from the current visual position when the server adjusts
					-- a deadline. Whiff refunds accelerate the drain without refilling it.
					local previousSpan = math.max(0.0001, button.drainReadyAt - button.drainStartedAt)
					button.drainStartFraction *= math.clamp((button.drainReadyAt - serverNow) / previousSpan, 0, 1)
					button.drainStartedAt, button.drainReadyAt = serverNow, readyAt
				end
				local span = math.max(0.0001, button.drainReadyAt - button.drainStartedAt)
				button.fraction = button.drainStartFraction * math.clamp(remaining / span, 0, 1)
			else
				button.fraction = 0
				button.drainReadyAt, button.drainStartedAt, button.drainStartFraction = nil, nil, nil
			end
			button.fillGradient.Offset = Vector2.new(0, 0.52 - 1.04 * button.fraction)
			button.fill.Visible = cooling and button.fraction > 0
			button.countdown.Text = cooling and string.format("%.1fs", math.ceil(remaining * 10) / 10) or ""
			button.status.Text = cooling and "COOLDOWN" or (mode == "pending" and "CONFIRMING" or (mode == "queued" and "QUEUED" or (mode == "ready" and "READY" or string.upper(state.reason or "UNAVAILABLE"))))
			button.face:SetAttribute("State", mode)
			button.face:SetAttribute("Remaining", remaining)
			button.face:SetAttribute("ActivationId", state.activationId or 0)
			button.preview:SetActive(not hidden)
			if not hidden then
				button.preview:Step(math.min(dt, 0.1))
				button.artwork:Step(artworkTime + (key == "H" and 1.4 or 0), mode, button.hover)
			end
		end
	end)

	function self:Destroy()
		if not alive then return end
		alive = false
		for _, connection in ipairs(connections) do connection:Disconnect() end
		for _, channels in pairs(tweens) do for _, tween in pairs(channels) do tween:Cancel() end end
		for _, button in pairs(buttons) do button.preview:Destroy(); button.artwork:Destroy() end
		table.clear(connections); table.clear(tweens)
		if mounted == self then mounted = nil end
		gui:Destroy()
	end
	connect(gui.Destroying, function() self:Destroy() end)
	return self
end

return SkillHUD

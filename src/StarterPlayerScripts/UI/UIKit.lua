--[[
	UIKit  (ModuleScript in StarterPlayerScripts > UI)

	A toolbox for BUILDING UI pieces so the other files stay short.
	  UIKit.Create(...)  any object
	  UIKit.Label(...)   outlined text
	  UIKit.Button(...)  chunky 3D cartoon button
	  UIKit.Panel(...)   a navy box with an outline
	  UIKit.Bar(...)     health / XP bar
	  UIKit.Tween / Pop  animation helpers

	SIZES AND POSITIONS: UDim2.new(scaleX, offsetX, scaleY, offsetY)
	  scale  = a fraction of the parent (0.5 = half)
	  offset = exact pixels
	  UDim2.new(0.5, 0, 0.1, 0) = half the parent's width, 10% of its height
]]

local TweenService = game:GetService("TweenService")
local Theme = require(script.Parent.Theme) -- script.Parent = the UI folder this file is in

local UIKit = {}
local C = Theme.Colors -- short nickname so lines don't get too long

-- Create(className, properties, parent)
--   className  = what to make, e.g. "Frame", "TextLabel", "TextButton"
--   properties = a table of settings, e.g. { Text = "Hi", Size = ... }
--   parent     = what it goes inside
function UIKit.Create(className, properties, parent)
	local object = Instance.new(className)
	for name, value in pairs(properties) do
		object[name] = value -- same as writing object.Text = "Hi"
	end
	object.Parent = parent
	return object
end

-- Corner(object, radius): round the corners
function UIKit.Corner(object, radius)
	return UIKit.Create("UICorner", { CornerRadius = UDim.new(0, radius or Theme.CornerRadius) }, object)
end

-- Outline(object, thickness): thick dark border around a BOX
function UIKit.Outline(object, thickness)
	return UIKit.Create("UIStroke", {
		Thickness = thickness or Theme.OutlineThickness,
		Color = C.Outline,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border, -- Border = around the box
	}, object)
end

-- TextOutline(object, thickness): thick dark border around TEXT letters
function UIKit.TextOutline(object, thickness)
	return UIKit.Create("UIStroke", {
		Thickness = thickness or 2,
		Color = C.Outline,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual, -- Contextual = around the letters
	}, object)
end

-- Gradient(object, topColor, bottomColor): fade from one color to another, top to bottom
function UIKit.Gradient(object, topColor, bottomColor)
	return UIKit.Create("UIGradient", {
		Color = ColorSequence.new(topColor, bottomColor),
		Rotation = 90,
	}, object)
end

-- Lighten / Darken a color. amount 0 = same color, 1 = fully white/black
function UIKit.Lighten(color, amount)
	return color:Lerp(Color3.new(1, 1, 1), amount) -- Lerp = mix two colors
end
function UIKit.Darken(color, amount)
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

-- GetScale(object): a UIScale lets us grow/shrink something without changing its Size
function UIKit.GetScale(object)
	return object:FindFirstChildOfClass("UIScale") or UIKit.Create("UIScale", { Scale = 1 }, object)
end

-- Tween(object, seconds, goals, style, direction): smoothly animate properties
-- Example: UIKit.Tween(frame, 0.5, { BackgroundTransparency = 1 }) fades a frame out in half a second
function UIKit.Tween(object, seconds, goals, style, direction)
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
	local tween = TweenService:Create(object, info, goals)
	tween:Play()
	return tween
end

-- Pop(object, startScale): "boing!" Jump to startScale, then wobble back to normal.
function UIKit.Pop(object, startScale)
	local scale = UIKit.GetScale(object)
	scale.Scale = startScale or 1.2
	UIKit.Tween(scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Label(parent, text, size, position, color, font): outlined text, positioned from its CENTER
function UIKit.Label(parent, text, size, position, color, font)
	local label = UIKit.Create("TextLabel", {
		Text = text,
		Size = size,
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5), -- position = the center of the label
		BackgroundTransparency = 1,          -- just text, no box
		Font = font or Theme.TitleFont,
		TextColor3 = color or C.Text,
		TextScaled = true,                   -- text grows/shrinks to fit the label
	}, parent)
	UIKit.TextOutline(label)
	return label
end

-- Panel(parent, size, position, color): a rounded box with an outline (cards, windows...)
function UIKit.Panel(parent, size, position, color)
	color = color or C.Panel
	local panel = UIKit.Create("Frame", {
		Size = size,
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1), -- white, so the gradient shows its true colors
	}, parent)
	UIKit.Corner(panel)
	UIKit.Outline(panel)
	UIKit.Gradient(panel, UIKit.Lighten(color, 0.08), color)
	return panel
end

--[[
	Button(parent, text, color, size, position)
	A chunky 3D button: a darker "base" sits under the colored "face".
	Pressing it pushes the face down onto the base, like a real button.

	Gives back THREE things:
	  face   = the TextButton (connect .Activated to this)
	  holder = the invisible frame around it (move or hide THIS one)
	  label  = the text on it (change label.Text to change the words)
]]
function UIKit.Button(parent, text, color, size, position)
	local depth = Theme.ButtonDepth

	local holder = UIKit.Create("Frame", {
		Size = size,
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
	}, parent)

	local base = UIKit.Create("Frame", { -- the dark part underneath
		Size = UDim2.new(1, 0, 1, -depth),
		Position = UDim2.new(0, 0, 0, depth),
		BackgroundColor3 = UIKit.Darken(color, 0.45),
	}, holder)
	UIKit.Corner(base)
	UIKit.Outline(base)

	local face = UIKit.Create("TextButton", { -- the colored top you click
		Size = UDim2.new(1, 0, 1, -depth),
		BackgroundColor3 = Color3.new(1, 1, 1),
		AutoButtonColor = false, -- turn off Roblox's default grey hover
		Text = "", -- the words go in a separate label (below) so the shine can sit BEHIND them
	}, holder)
	UIKit.Corner(face)
	UIKit.Outline(face)
	UIKit.Gradient(face, UIKit.Lighten(color, 0.15), color)

	local shine = UIKit.Create("Frame", { -- the glossy white strip at the top
		Size = UDim2.new(1, -10, 0.3, 0),
		Position = UDim2.new(0, 5, 0, 4),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.75,
	}, face)
	UIKit.Corner(shine, 8)

	local label = UIKit.Label(face, text, UDim2.new(0.85, 0, 0.62, 0), UDim2.new(0.5, 0, 0.5, 0))
	label.ZIndex = 2 -- higher ZIndex = drawn on top (so the text is above the shine)

	-- Animations
	local scale = UIKit.GetScale(holder)
	local up = UDim2.new(0, 0, 0, 0)
	local down = UDim2.new(0, 0, 0, depth)

	face.MouseEnter:Connect(function()
		UIKit.Tween(scale, 0.15, { Scale = 1.06 }, Enum.EasingStyle.Back) -- grow a little on hover
	end)
	face.MouseLeave:Connect(function()
		UIKit.Tween(scale, 0.15, { Scale = 1 }, Enum.EasingStyle.Back)
		UIKit.Tween(face, 0.08, { Position = up })
	end)
	face.MouseButton1Down:Connect(function()
		UIKit.Tween(face, 0.05, { Position = down }) -- push down onto the base
	end)
	face.MouseButton1Up:Connect(function()
		UIKit.Tween(face, 0.2, { Position = up }, Enum.EasingStyle.Back) -- spring back up
	end)

	return face, holder, label
end

--[[
	Bar(parent, size, position, color)
	A health/XP bar. Gives back a table: { Frame, Fill, Text }
	Use UIKit.SetBar(bar, 0.5, "50 / 100") to change it.
]]
function UIKit.Bar(parent, size, position, color)
	local back = UIKit.Create("Frame", {
		Size = size,
		Position = position,
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = C.Slot,
	}, parent)
	UIKit.Corner(back, 10)
	UIKit.Outline(back)

	local fill = UIKit.Create("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
	}, back)
	UIKit.Corner(fill, 10)
	UIKit.Gradient(fill, UIKit.Lighten(color, 0.25), color)

	local text = UIKit.Label(back, "", UDim2.new(0.95, 0, 0.75, 0), UDim2.new(0.5, 0, 0.5, 0), C.Text, Theme.TextFont)
	text.ZIndex = 2 -- draw it ON TOP of the fill

	return { Frame = back, Fill = fill, Text = text }
end

-- SetBar(bar, percent, text): percent goes from 0 (empty) to 1 (full)
function UIKit.SetBar(bar, percent, text)
	percent = math.clamp(percent, 0, 1) -- clamp = keep it between 0 and 1
	UIKit.Tween(bar.Fill, 0.2, { Size = UDim2.new(percent, 0, 1, 0) })
	bar.Fill.Visible = percent > 0 -- a 0-wide bar with round corners looks glitchy, so hide it
	bar.Text.Text = text
end

return UIKit

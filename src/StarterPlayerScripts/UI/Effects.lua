--[[
	Effects  (ModuleScript in StarterPlayerScripts > UI)

	The "juice": damage numbers, shakes, flashes, messages and the egg hatch scene.
	Call Effects.Init(gui) once before using anything else.
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)

local Effects = {}
local C = Theme.Colors
local gui = nil -- the ScreenGui, set in Init
local toastLabel = nil

function Effects.Init(screenGui)
	gui = screenGui

	-- The message ("toast") that drops in from the top of the screen
	toastLabel = UIKit.Label(gui, "", UDim2.new(0.5, 0, 0.055, 0), UDim2.new(0.5, 0, -0.1, 0))
	toastLabel.ZIndex = 50
end

-- Toast(text, color): show a short message for about 2 seconds
function Effects.Toast(text, color)
	toastLabel.Text = text
	toastLabel.TextColor3 = color or C.Text
	toastLabel.Position = UDim2.new(0.5, 0, -0.1, 0) -- start above the screen
	UIKit.Tween(toastLabel, 0.35, { Position = UDim2.new(0.5, 0, 0.27, 0) }, Enum.EasingStyle.Back)
	UIKit.Pop(toastLabel, 1.3)
	task.delay(1.8, function() -- task.delay(seconds, function) = run this later, without pausing now
		if toastLabel.Text == text then -- only hide it if no newer message replaced it
			UIKit.Tween(toastLabel, 0.3, { Position = UDim2.new(0.5, 0, -0.1, 0) }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		end
	end)
end

-- FloatText(parent, text, color, big): a number that pops up, drifts upward and fades away
function Effects.FloatText(parent, text, color, big)
	local x = 0.3 + math.random() * 0.4 -- random spot between 30% and 70% across
	local height = big and 0.16 or 0.11
	local label = UIKit.Label(parent, text, UDim2.new(0.7, 0, height, 0), UDim2.new(x, 0, 0.45, 0), color)
	label.ZIndex = 10
	label.Rotation = math.random(-12, 12)
	UIKit.Pop(label, 1.7)

	local goal = UDim2.new(x, 0, 0.15, 0) -- float up
	UIKit.Tween(label, 0.8, { Position = goal, TextTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	UIKit.Tween(label:FindFirstChildOfClass("UIStroke"), 0.8, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.8, function()
		label:Destroy() -- clean up, or thousands of invisible labels would pile up
	end)
end

-- Shake(object, strength): wiggle left and right quickly
function Effects.Shake(object, strength)
	strength = strength or 5
	task.spawn(function() -- run on the side, so the code that called Shake doesn't wait
		for i = 1, 4 do
			object.Rotation = (i % 2 == 0) and strength or -strength -- even = right, odd = left
			task.wait(0.03)
		end
		object.Rotation = 0
	end)
end

-- Flash(frame): flash a frame white for a moment (when something gets hit)
function Effects.Flash(frame)
	frame.BackgroundTransparency = 0.25
	UIKit.Tween(frame, 0.25, { BackgroundTransparency = 1 })
end

--[[
	PlayHatch(characterId)
	The big egg scene: screen darkens, egg wobbles faster and faster, white flash,
	then the character card bursts out with spinning rays behind it.
	This function WAITS until the scene is over (about 4 seconds).
]]
function Effects.PlayHatch(characterId)
	local character = nil
	for _, item in ipairs(GameConfig.Characters) do
		if item.Id == characterId then
			character = item
		end
	end
	if not character then return end
	local rarityColor = GameConfig.RarityColors[character.Rarity]

	-- dark cover over the whole screen
	local overlay = UIKit.Create("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = C.Outline,
		BackgroundTransparency = 1,
		ZIndex = 60,
	}, gui)
	UIKit.Tween(overlay, 0.3, { BackgroundTransparency = 0.25 })

	-- the egg (a tall rounded box)
	local egg = UIKit.Create("Frame", {
		Size = UDim2.new(0.2, 0, 0.27, 0),
		SizeConstraint = Enum.SizeConstraint.RelativeYY, -- size is based on screen HEIGHT, so it stays egg-shaped
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 61,
	}, overlay)
	UIKit.Corner(egg, 999) -- a huge radius = fully rounded
	UIKit.Outline(egg, 5)
	UIKit.Gradient(egg, Color3.fromRGB(255, 250, 235), C.Gold)
	UIKit.Pop(egg, 0.2) -- grow in from tiny

	-- wobble, faster each time
	for i = 1, 10 do
		local speed = 0.17 - i * 0.012
		UIKit.Tween(egg, speed, { Rotation = (i % 2 == 0) and 14 or -14 })
		task.wait(speed)
	end

	-- WHITE FLASH
	local flash = UIKit.Create("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 70,
	}, overlay)
	UIKit.Tween(flash, 0.6, { BackgroundTransparency = 1 })
	egg:Destroy()

	-- spinning rays behind the card
	local rays = UIKit.Create("Frame", {
		Size = UDim2.new(0.8, 0, 0.8, 0),
		SizeConstraint = Enum.SizeConstraint.RelativeYY,
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 61,
	}, overlay)
	for i = 1, 6 do
		UIKit.Create("Frame", {
			Size = UDim2.new(0.1, 0, 1, 0),
			Position = UDim2.new(0.5, 0, 0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Rotation = i * 30, -- 6 rays, 30 degrees apart (each ray pokes out both sides = 12 points)
			BackgroundColor3 = rarityColor,
			BackgroundTransparency = 0.6,
			ZIndex = 61,
		}, rays)
	end
	local spinForever = TweenInfo.new(5, Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1) -- -1 = repeat forever
	TweenService:Create(rays, spinForever, { Rotation = 360 }):Play()

	-- the character card
	local card = UIKit.Panel(overlay, UDim2.new(0.26, 0, 0.38, 0), UDim2.new(0.5, 0, 0.5, 0), C.Panel)
	card.SizeConstraint = Enum.SizeConstraint.RelativeYY
	card.ZIndex = 62
	card:FindFirstChildOfClass("UIStroke").Color = rarityColor -- outline in the rarity color
	card:FindFirstChildOfClass("UIStroke").Thickness = 5

	local rarityLabel = UIKit.Label(card, string.upper(character.Rarity), UDim2.new(0.8, 0, 0.11, 0), UDim2.new(0.5, 0, 0.1, 0), rarityColor)
	rarityLabel.ZIndex = 63

	local picture = UIKit.Create("ImageLabel", { -- BLANK picture. Put "rbxassetid://123" in Image later!
		Image = "",
		Size = UDim2.new(0.75, 0, 0.52, 0),
		Position = UDim2.new(0.5, 0, 0.45, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = C.Slot,
		ZIndex = 63,
	}, card)
	UIKit.Corner(picture)

	local nameLabel = UIKit.Label(card, character.Name, UDim2.new(0.9, 0, 0.12, 0), UDim2.new(0.5, 0, 0.79, 0))
	nameLabel.ZIndex = 63
	local powerLabel = UIKit.Label(card, "+" .. character.Power .. " POWER", UDim2.new(0.6, 0, 0.08, 0), UDim2.new(0.5, 0, 0.9, 0), C.Gold, Theme.TextFont)
	powerLabel.ZIndex = 63

	UIKit.Pop(card, 0.1) -- burst out
	task.wait(2.4) -- let them look at it

	UIKit.Tween(UIKit.GetScale(card), 0.25, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	UIKit.Tween(overlay, 0.3, { BackgroundTransparency = 1 })
	rays.Visible = false
	task.wait(0.3)
	overlay:Destroy() -- removes everything inside it too
end

return Effects

--[[
	Panels  (ModuleScript in StarterPlayerScripts > UI)

	The pop-up windows: SHOP, EGGS and STORY.
	This file only DRAWS them. When a button is pressed, it calls one of
	the "actions" that ClientMain hands in, and ClientMain talks to the server.

	Functions:
	  Panels.Build(gui, actions)   make all windows (call once)
	  Panels.Open(name)            open "Shop", "Eggs" or "Story"
	  Panels.UpdateData(data)      refresh prices, team and story progress
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Formulas = require(ReplicatedStorage.Shared.Formulas)
local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)

local Panels = {}
local C = Theme.Colors

local windows = {}       -- windows.Shop, windows.Eggs, windows.Story
local openWindow = nil   -- the window that's open right now (nil = none)
local upgradeRows = {}   -- so we can update prices later
local passRows = {}
local chapterRows = {}
local teamGrid = nil

---------------------------------------------------------------------------
-- builders
---------------------------------------------------------------------------

-- makeWindow(title): a centered window with a title, close button and a scrolling list
local function makeWindow(gui, title)
	local window = UIKit.Panel(gui, UDim2.new(0.5, 0, 0.66, 0), UDim2.new(0.5, 0, 0.52, 0))
	window.Visible = false
	window.ZIndex = 20 -- above the HUD
	UIKit.Create("UIAspectRatioConstraint", { AspectRatio = 1.3 }, window)
	window:FindFirstChildOfClass("UIStroke").Thickness = 5

	UIKit.Label(window, title, UDim2.new(0.6, 0, 0.1, 0), UDim2.new(0.5, 0, 0.08, 0), C.Gold)

	local close, closeHolder = UIKit.Button(window, "X", C.Red, UDim2.new(0.11, 0, 0.11, 0), UDim2.new(0.97, 0, 0.03, 0))
	closeHolder.SizeConstraint = Enum.SizeConstraint.RelativeYY -- keep it square
	close.Activated:Connect(function()
		Panels.Close()
	end)

	local list = UIKit.Create("ScrollingFrame", {
		Size = UDim2.new(0.94, 0, 0.8, 0),
		Position = UDim2.new(0.5, 0, 0.57, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = C.PanelLight,
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, -- the scroll area grows as we add rows
	}, window)
	UIKit.Create("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, list)
	UIKit.Create("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, list)

	return window, list
end

-- makeHeader(list, text, order): a small section title inside a list
local function makeHeader(list, text, order)
	local header = UIKit.Label(list, text, UDim2.new(0.95, 0, 0, 32), UDim2.new(0, 0, 0, 0), C.TextDim)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.AnchorPoint = Vector2.new(0, 0) -- the list layout places it, so measure from the top-left
	header.LayoutOrder = order
	return header
end

--[[
	makeRow(list, title, description, buttonText, buttonColor, order)
	One row: [picture] Title / description  [BUTTON]
	Gives back a table: { Frame, Description, Button, ButtonLabel }
]]
local function makeRow(list, title, description, buttonText, buttonColor, order)
	local row = UIKit.Panel(list, UDim2.new(0.97, 0, 0, 84), UDim2.new(0, 0, 0, 0), C.PanelLight)
	row.LayoutOrder = order
	row.AnchorPoint = Vector2.new(0, 0) -- the list layout places it, so measure from the top-left

	local icon = UIKit.Create("ImageLabel", { -- BLANK icon. Put an image id in Image later.
		Image = "",
		Size = UDim2.new(0, 64, 0, 64),
		Position = UDim2.new(0, 10, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = C.Slot,
	}, row)
	UIKit.Corner(icon, 12)
	UIKit.Outline(icon, 2)

	local titleLabel = UIKit.Label(row, title, UDim2.new(0.5, 0, 0.36, 0), UDim2.new(0, 86, 0.32, 0))
	titleLabel.AnchorPoint = Vector2.new(0, 0.5) -- measure from the LEFT edge instead of the center
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left

	local descLabel = UIKit.Label(row, description, UDim2.new(0.5, 0, 0.26, 0), UDim2.new(0, 86, 0.7, 0), C.TextDim, Theme.TextFont)
	descLabel.AnchorPoint = Vector2.new(0, 0.5)
	descLabel.TextXAlignment = Enum.TextXAlignment.Left

	local button, _, buttonLabel = UIKit.Button(row, buttonText, buttonColor, UDim2.new(0.25, 0, 0.78, 0), UDim2.new(0.85, 0, 0.5, 0))

	return { Frame = row, Description = descLabel, Button = button, ButtonLabel = buttonLabel }
end

---------------------------------------------------------------------------
-- BUILD
-- actions = a table of functions ClientMain gives us:
--   actions.BuyUpgrade(upgradeId)
--   actions.HatchEgg(eggId)
--   actions.BuyPass(passId)
---------------------------------------------------------------------------
function Panels.Build(gui, actions)
	-- SHOP ---------------------------------------------------------------
	local shop, shopList = makeWindow(gui, "SHOP")
	windows.Shop = shop

	makeHeader(shopList, "UPGRADES", 1)
	for index, upgrade in ipairs(GameConfig.Upgrades) do
		local row = makeRow(shopList, upgrade.Name, upgrade.Description, "...", C.Green, 1 + index)
		row.Button.Activated:Connect(function()
			actions.BuyUpgrade(upgrade.Id)
		end)
		upgradeRows[upgrade.Id] = row
	end

	makeHeader(shopList, "GAMEPASSES", 100)
	for index, pass in ipairs(GameConfig.Gamepasses) do
		local row = makeRow(shopList, pass.Name, pass.Description, "R$ BUY", C.Gold, 100 + index)
		row.Button.Activated:Connect(function()
			actions.BuyPass(pass.PassId)
		end)
		passRows[pass.Key] = row
	end

	-- EGGS ---------------------------------------------------------------
	local eggs, eggList = makeWindow(gui, "EGGS")
	windows.Eggs = eggs

	for index, egg in ipairs(GameConfig.Eggs) do
		local currencyText = egg.Currency == "Gems" and " GEMS" or " COINS"
		local row = makeRow(eggList, egg.Name, egg.Description, Formulas.FormatNumber(egg.Price) .. currencyText, C.Green, index)
		row.Button.Activated:Connect(function()
			actions.HatchEgg(egg.Id)
		end)
	end

	makeHeader(eggList, "YOUR TEAM", 50)
	teamGrid = UIKit.Create("Frame", {
		Size = UDim2.new(0.97, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, -- grows taller as we add characters
		BackgroundTransparency = 1,
		LayoutOrder = 51,
	}, eggList)
	UIKit.Create("UIGridLayout", {
		CellSize = UDim2.new(0, 110, 0, 130),
		CellPadding = UDim2.new(0, 10, 0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, teamGrid)

	-- STORY --------------------------------------------------------------
	local story, storyList = makeWindow(gui, "STORY")
	windows.Story = story

	for index, chapter in ipairs(GameConfig.Chapters) do
		local first = (index - 1) * GameConfig.StagesPerChapter + 1 -- chapter 2 starts at stage 11
		local last = index * GameConfig.StagesPerChapter            -- and ends at stage 20
		local row = makeRow(storyList, "CH. " .. index .. "  " .. chapter.Name, "Stages " .. first .. "-" .. last .. "  |  Boss: " .. chapter.Boss, "LOCKED", C.Slot, index)
		row.Button.Active = false -- it's just a status badge, not clickable
		chapterRows[index] = { Row = row, First = first, Last = last }
	end
end

---------------------------------------------------------------------------
-- OPEN / CLOSE
---------------------------------------------------------------------------
function Panels.Open(name)
	local window = windows[name]
	if openWindow == window then -- pressing the same menu button again closes it
		Panels.Close()
		return
	end
	if openWindow then
		openWindow.Visible = false -- hide the other window first
	end
	openWindow = window
	window.Visible = true
	UIKit.Pop(window, 0.6) -- grows open with a bounce
end

function Panels.Close()
	if not openWindow then return end
	local window = openWindow
	openWindow = nil
	UIKit.Tween(UIKit.GetScale(window), 0.15, { Scale = 0.6 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	task.delay(0.15, function()
		if openWindow ~= window then -- it wasn't reopened in the meantime
			window.Visible = false
		end
	end)
end

---------------------------------------------------------------------------
-- UPDATE (called every time new data arrives from the server)
---------------------------------------------------------------------------

-- rebuildTeam(data): redraw the "YOUR TEAM" grid (one card per character type, with a count)
local function rebuildTeam(data)
	for _, child in ipairs(teamGrid:GetChildren()) do
		if child:IsA("Frame") then
			child:Destroy() -- remove the old cards
		end
	end

	-- count how many of each character we own. e.g. counts.NinjaKid = 3
	local counts = {}
	for _, characterId in ipairs(data.Team) do
		counts[characterId] = (counts[characterId] or 0) + 1
	end

	for order, character in ipairs(GameConfig.Characters) do
		local count = counts[character.Id]
		if count then -- only show characters we have
			local rarityColor = GameConfig.RarityColors[character.Rarity]
			local card = UIKit.Panel(teamGrid, UDim2.new(0, 0, 0, 0), UDim2.new(0, 0, 0, 0), C.PanelLight)
			card.AnchorPoint = Vector2.new(0, 0)
			card.LayoutOrder = -order -- negative = rarest (last in the list) shows FIRST
			card:FindFirstChildOfClass("UIStroke").Color = rarityColor

			local picture = UIKit.Create("ImageLabel", { -- BLANK picture
				Image = "",
				Size = UDim2.new(0.8, 0, 0.55, 0),
				Position = UDim2.new(0.5, 0, 0.36, 0),
				AnchorPoint = Vector2.new(0.5, 0.5),
				BackgroundColor3 = C.Slot,
			}, card)
			UIKit.Corner(picture, 10)

			UIKit.Label(card, character.Name, UDim2.new(0.92, 0, 0.14, 0), UDim2.new(0.5, 0, 0.75, 0), C.Text, Theme.TextFont)
			UIKit.Label(card, "x" .. count, UDim2.new(0.5, 0, 0.13, 0), UDim2.new(0.5, 0, 0.9, 0), rarityColor)
		end
	end
end

function Panels.UpdateData(data)
	-- upgrade prices
	for _, upgrade in ipairs(GameConfig.Upgrades) do
		local row = upgradeRows[upgrade.Id]
		local timesBought = data.Upgrades[upgrade.Id] or 0
		local cost = Formulas.UpgradeCost(upgrade, timesBought)
		row.ButtonLabel.Text = Formulas.FormatNumber(cost) .. (upgrade.Currency == "Gems" and " GEMS" or "")
		row.Description.Text = upgrade.Description .. "   (owned: " .. timesBought .. ")"
	end

	-- gamepasses you own say OWNED
	for key, row in pairs(passRows) do
		if data.Passes[key] then
			row.ButtonLabel.Text = "OWNED"
			row.Button.Active = false
		end
	end

	-- story progress
	for _, info in ipairs(chapterRows) do
		local label = info.Row.ButtonLabel
		if data.Stage > info.Last then
			label.Text = "CLEARED"
			label.TextColor3 = C.Green
		elseif data.Stage >= info.First then
			label.Text = "NOW"
			label.TextColor3 = C.Gold
		else
			label.Text = "LOCKED"
			label.TextColor3 = C.TextDim
		end
	end

	rebuildTeam(data)
end

return Panels

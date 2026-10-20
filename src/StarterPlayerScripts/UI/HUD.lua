--[[
	HUD  (ModuleScript in StarterPlayerScripts > UI)

	The main game screen (HUD = "heads-up display"):
	  top    : coins, gems, level + XP bar, stage banner
	  left   : menu buttons + YOUR character card
	  right  : the ENEMY card
	  middle : VS + the big ATTACK button

	Functions other scripts use:
	  HUD.Build(gui)            make everything (call once)
	  HUD.UpdateData(data)      refresh coins/gems/level/stats
	  HUD.SetEnemy(info)        show a new enemy
	  HUD.EnemyHit(info)        enemy took damage
	  HUD.EnemyDefeated(info)   enemy died
	  HUD.HeroAttack()          hero lunge animation
]]

local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Formulas = require(ReplicatedStorage.Shared.Formulas)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local Effects = require(script.Parent.Effects)

local HUD = {}
local C = Theme.Colors

-- Things we need to change later get saved in these variables during Build()
local coinsText, gemsText, levelText, xpBar
local stageTitle, stageSubtitle, stageBanner
local hero, enemy
local teamText

local HERO_X = 0.3   -- where the hero card sits (30% across the screen)
local ENEMY_X = 0.72 -- where the enemy card sits

---------------------------------------------------------------------------
-- small builders used only in this file
---------------------------------------------------------------------------

-- makeCurrency(parent, iconText, iconColor, order): a stat pill like [$] 1.2K
local function makeCurrency(parent, iconText, iconColor, order)
	local pill = UIKit.Panel(parent, UDim2.new(0.3, 0, 1, 0), UDim2.new(0, 0, 0, 0))
	pill.LayoutOrder = order -- UIListLayout puts lower numbers first
	pill.AnchorPoint = Vector2.new(0, 0) -- the list layout places it, so measure from the top-left
	pill:FindFirstChildOfClass("UICorner").CornerRadius = UDim.new(1, 0) -- fully rounded ends = pill shape

	local icon = UIKit.Create("TextLabel", {
		Size = UDim2.new(1.15, 0, 1.15, 0),
		SizeConstraint = Enum.SizeConstraint.RelativeYY, -- a perfect circle based on the pill's height
		Position = UDim2.new(0, -6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		BackgroundColor3 = iconColor,
		Text = iconText,
		Font = Theme.TitleFont,
		TextScaled = true,
		TextColor3 = C.Text,
	}, pill)
	UIKit.Corner(icon, 999)
	UIKit.Outline(icon)
	UIKit.TextOutline(icon)
	UIKit.Create("UIPadding", { PaddingTop = UDim.new(0.2, 0), PaddingBottom = UDim.new(0.2, 0) }, icon)

	return UIKit.Label(pill, "0", UDim2.new(0.6, 0, 0.62, 0), UDim2.new(0.6, 0, 0.5, 0))
end

-- makeFighterCard(x, title): the big card for the hero or the enemy
local function makeFighterCard(parent, x, title)
	local card = UIKit.Panel(parent, UDim2.new(0.22, 0, 0.5, 0), UDim2.new(x, 0, 0.55, 0))
	UIKit.Create("UIAspectRatioConstraint", { AspectRatio = 0.78 }, card) -- keep the same shape on every screen

	local nameLabel = UIKit.Label(card, title, UDim2.new(0.9, 0, 0.1, 0), UDim2.new(0.5, 0, 0.09, 0))

	-- the picture slot. BLANK for now: set Image = "rbxassetid://YOUR_ID" later
	local picture = UIKit.Create("ImageLabel", {
		Image = "",
		Size = UDim2.new(0.84, 0, 0.62, 0),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = C.Slot,
		ScaleType = Enum.ScaleType.Fit,
	}, card)
	UIKit.Corner(picture)
	UIKit.Outline(picture, 2)

	local flash = UIKit.Create("Frame", { -- white overlay we flash when hit
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		ZIndex = 5,
	}, picture)
	UIKit.Corner(flash)

	-- idle "breathing": gently float up and down forever
	local bob = TweenInfo.new(1.3, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true) -- -1 = forever, true = go back and forth
	TweenService:Create(picture, bob, { Position = UDim2.new(0.5, 0, 0.47, 0) }):Play()

	return { Frame = card, Name = nameLabel, Picture = picture, Flash = flash }
end

---------------------------------------------------------------------------
-- BUILD
---------------------------------------------------------------------------
function HUD.Build(gui)
	-- BACKGROUND: dark blue gradient
	local background = UIKit.Create("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Color3.new(1, 1, 1),
		ZIndex = 0,
	}, gui)
	UIKit.Gradient(background, C.BackgroundTop, C.BackgroundBottom)

	-- faint dots slowly rising (makes the background feel alive)
	for _ = 1, 16 do
		local size = math.random(12, 50)
		local dot = UIKit.Create("Frame", {
			Size = UDim2.new(0, size, 0, size),
			Position = UDim2.new(math.random(), 0, 1.1, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.93,
		}, background)
		UIKit.Corner(dot, 999)
		local rise = TweenInfo.new(math.random(10, 20), Enum.EasingStyle.Linear, Enum.EasingDirection.In, -1)
		task.delay(math.random() * 10, function() -- start at random times so they spread out
			TweenService:Create(dot, rise, { Position = UDim2.new(dot.Position.X.Scale, 0, -0.1, 0) }):Play()
		end)
	end

	-- TOP BAR: coins, gems, level (side by side)
	local topBar = UIKit.Create("Frame", {
		Size = UDim2.new(0.5, 0, 0.065, 0),
		Position = UDim2.new(0.5, 0, 0.03, 0),
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
	}, gui)
	UIKit.Create("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0.04, 0),
	}, topBar)
	coinsText = makeCurrency(topBar, "$", C.Gold, 1)
	gemsText = makeCurrency(topBar, "G", C.Cyan, 2)
	levelText = makeCurrency(topBar, "LV", C.PanelLight, 3)

	xpBar = UIKit.Bar(gui, UDim2.new(0.3, 0, 0.028, 0), UDim2.new(0.5, 0, 0.125, 0), C.Gold)

	-- STAGE BANNER
	stageBanner = UIKit.Panel(gui, UDim2.new(0.3, 0, 0.085, 0), UDim2.new(0.5, 0, 0.2, 0))
	stageTitle = UIKit.Label(stageBanner, "STAGE 1", UDim2.new(0.9, 0, 0.5, 0), UDim2.new(0.5, 0, 0.36, 0), C.Gold)
	stageSubtitle = UIKit.Label(stageBanner, "", UDim2.new(0.9, 0, 0.3, 0), UDim2.new(0.5, 0, 0.74, 0), C.TextDim, Theme.TextFont)

	-- FIGHTER CARDS
	hero = makeFighterCard(gui, HERO_X, Players.LocalPlayer.DisplayName)
	hero.Stats = UIKit.Label(hero.Frame, "", UDim2.new(0.9, 0, 0.08, 0), UDim2.new(0.5, 0, 0.9, 0), C.Gold, Theme.TextFont)

	enemy = makeFighterCard(gui, ENEMY_X, "???")
	enemy.Bar = UIKit.Bar(enemy.Frame, UDim2.new(0.84, 0, 0.08, 0), UDim2.new(0.5, 0, 0.9, 0), C.Red)
	enemy.BossTag = UIKit.Label(enemy.Frame, "BOSS", UDim2.new(0.5, 0, 0.1, 0), UDim2.new(0.5, 0, -0.06, 0), C.Gold)
	enemy.BossTag.Visible = false

	-- VS (pulses forever)
	local vs = UIKit.Label(gui, "VS", UDim2.new(0.1, 0, 0.1, 0), UDim2.new(0.51, 0, 0.5, 0), C.Gold)
	vs.Rotation = -8
	local pulse = TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(UIKit.GetScale(vs), pulse, { Scale = 1.15 }):Play()

	teamText = UIKit.Label(gui, "", UDim2.new(0.2, 0, 0.03, 0), UDim2.new(0.51, 0, 0.6, 0), C.TextDim, Theme.TextFont)

	-- ATTACK BUTTON (the only big gold button = the main thing to press)
	local attack, attackHolder = UIKit.Button(gui, "ATTACK!", C.Gold, UDim2.new(0.2, 0, 0.12, 0), UDim2.new(0.51, 0, 0.88, 0))
	UIKit.Create("UIAspectRatioConstraint", { AspectRatio = 3 }, attackHolder)
	local breathe = TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	TweenService:Create(attackHolder, breathe, { Rotation = 2 }):Play() -- gentle tilt so it draws the eye

	-- MENU BUTTONS on the left edge
	local menu = {}
	local menuNames = { "SHOP", "EGGS", "STORY" }
	for index, name in ipairs(menuNames) do
		local y = 0.4 + (index - 1) * 0.13 -- stack them downward: 0.40, 0.53, 0.66
		local button, holder = UIKit.Button(gui, name, C.PanelLight, UDim2.new(0.1, 0, 0.1, 0), UDim2.new(0.08, 0, y, 0))
		UIKit.Create("UIAspectRatioConstraint", { AspectRatio = 1.6 }, holder)
		menu[name] = button
	end

	-- give the buttons back so ClientMain can hook them up
	return {
		Attack = attack,
		Shop = menu.SHOP,
		Eggs = menu.EGGS,
		Story = menu.STORY,
	}
end

---------------------------------------------------------------------------
-- UPDATES
---------------------------------------------------------------------------

-- UpdateData(data): refresh every number that comes from the player's data
function HUD.UpdateData(data)
	local oldCoins = coinsText.Text
	coinsText.Text = Formulas.FormatNumber(data.Coins)
	gemsText.Text = Formulas.FormatNumber(data.Gems)
	if coinsText.Text ~= oldCoins then
		UIKit.Pop(coinsText.Parent, 1.12) -- boing the pill when the number changes
	end

	local oldLevel = levelText.Text
	levelText.Text = tostring(data.Level)
	if oldLevel ~= "0" and oldLevel ~= levelText.Text then
		UIKit.Pop(levelText.Parent, 1.3)
	end

	local needed = Formulas.XPNeeded(data.Level)
	UIKit.SetBar(xpBar, data.XP / needed, "XP " .. data.XP .. " / " .. needed)

	hero.Stats.Text = "DMG " .. Formulas.FormatNumber(Formulas.ClickDamage(data))
		.. "   AUTO " .. Formulas.FormatNumber(Formulas.AutoDamage(data)) .. "/s"
	teamText.Text = "TEAM: " .. #data.Team .. "  |  POWER " .. Formulas.FormatNumber(Formulas.TeamPower(data))
end

-- SetEnemy(info): a new enemy arrives (info comes from the server)
function HUD.SetEnemy(info)
	enemy.Name.Text = info.Name
	enemy.BossTag.Visible = info.IsBoss
	enemy.Frame:FindFirstChildOfClass("UIStroke").Color = info.IsBoss and C.Gold or C.Outline -- gold outline for bosses
	UIKit.SetBar(enemy.Bar, info.Health / info.MaxHealth, Formulas.FormatNumber(info.Health) .. " / " .. Formulas.FormatNumber(info.MaxHealth))

	local stageInChapter = (info.Stage - 1) % GameConfig.StagesPerChapter + 1
	stageTitle.Text = info.IsBoss and "BOSS FIGHT!" or ("STAGE " .. stageInChapter .. " / " .. GameConfig.StagesPerChapter)
	stageTitle.TextColor3 = info.IsBoss and C.Red or C.Gold
	stageSubtitle.Text = "CHAPTER " .. info.ChapterNumber .. "  -  " .. string.upper(info.ChapterName)
	UIKit.Pop(stageBanner, 1.15)

	-- drop-in animation: start tiny and tilted, spring to full size
	local scale = UIKit.GetScale(enemy.Frame)
	scale.Scale = 0
	enemy.Frame.Rotation = 15
	UIKit.Tween(scale, 0.45, { Scale = info.IsBoss and 1.08 or 1 }, Enum.EasingStyle.Back)
	UIKit.Tween(enemy.Frame, 0.45, { Rotation = 0 }, Enum.EasingStyle.Back)
end

-- EnemyHit(info): show damage. info = { Damage, Health, MaxHealth, IsAuto }
function HUD.EnemyHit(info)
	UIKit.SetBar(enemy.Bar, info.Health / info.MaxHealth, Formulas.FormatNumber(info.Health) .. " / " .. Formulas.FormatNumber(info.MaxHealth))
	Effects.FloatText(enemy.Frame, "-" .. Formulas.FormatNumber(info.Damage), info.IsAuto and C.TextDim or C.Text)
	Effects.Flash(enemy.Flash)
	Effects.Shake(enemy.Frame, info.IsAuto and 3 or 6)
	if info.IsAuto then
		HUD.HeroAttack() -- show the hero swinging on auto hits too
	end
end

-- EnemyDefeated(info): rewards popup + the enemy spins away
function HUD.EnemyDefeated(info)
	Effects.FloatText(enemy.Frame, "+" .. Formulas.FormatNumber(info.Coins) .. " COINS", C.Gold, true)
	if info.Gems > 0 then
		Effects.FloatText(enemy.Frame, "+" .. info.Gems .. " GEMS", C.Cyan, true)
	end
	if info.WasBoss then
		Effects.Toast("BOSS DEFEATED!", C.Gold)
	end
	UIKit.Tween(UIKit.GetScale(enemy.Frame), 0.35, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	UIKit.Tween(enemy.Frame, 0.35, { Rotation = -30 })
end

-- HeroAttack(): the hero card jumps toward the enemy and bounces back
function HUD.HeroAttack()
	local frame = hero.Frame
	UIKit.Tween(frame, 0.07, { Position = UDim2.new(HERO_X + 0.04, 0, 0.55, 0), Rotation = 5 })
	task.delay(0.08, function()
		UIKit.Tween(frame, 0.3, { Position = UDim2.new(HERO_X, 0, 0.55, 0), Rotation = 0 }, Enum.EasingStyle.Back)
	end)
end

return HUD

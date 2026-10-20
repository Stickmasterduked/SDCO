--[[
	ClientMain  (LocalScript in StarterPlayerScripts)

	The "boss" of the player's screen. It:
	  1. builds the UI using the modules in the UI folder
	  2. sends the player's clicks to the server (FireServer)
	  3. listens for the server's updates and passes them to the UI (OnClientEvent)

	It does NOT decide coins or damage; the server does that.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes") -- made by GameServer. WaitForChild = wait until it exists

-- The UI modules (they live in the "UI" folder next to this script)
local UI = script.Parent:WaitForChild("UI")
local Theme = require(UI.Theme)
local Effects = require(UI.Effects)
local HUD = require(UI.HUD)
local Panels = require(UI.Panels)

local C = Theme.Colors

---------------------------------------------------------------------------
-- 1. BUILD THE SCREEN
---------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "GameUI"
gui.ResetOnSpawn = false   -- keep the UI if the character respawns
gui.IgnoreGuiInset = true  -- cover the WHOLE screen
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = player:WaitForChild("PlayerGui")

Effects.Init(gui)
local buttons = HUD.Build(gui) -- gives back { Attack, Shop, Eggs, Story }

local isHatching = false -- true while the egg animation is playing

-- "actions" = what the windows' buttons should do. Panels calls these.
local actions = {}

function actions.BuyUpgrade(upgradeId)
	Remotes.BuyUpgrade:FireServer(upgradeId) -- ask the server; it checks the price and answers with DataUpdated
end

function actions.HatchEgg(eggId)
	if isHatching then return end -- wait for the current egg to finish
	Remotes.HatchEgg:FireServer(eggId)
end

function actions.BuyPass(passId)
	if passId == 0 then
		Effects.Toast("Set this gamepass's PassId in GameConfig!", C.Red)
		return
	end
	MarketplaceService:PromptGamePassPurchase(player, passId) -- opens Roblox's buy window
end

Panels.Build(gui, actions)

---------------------------------------------------------------------------
-- 2. BUTTONS -> SERVER
-- .Activated fires when the button is clicked OR tapped (works on phones too)
---------------------------------------------------------------------------
buttons.Attack.Activated:Connect(function()
	HUD.HeroAttack()             -- animate right away so it feels instant...
	Remotes.Attack:FireServer()  -- ...while the server does the real damage
end)

buttons.Shop.Activated:Connect(function() Panels.Open("Shop") end)
buttons.Eggs.Activated:Connect(function() Panels.Open("Eggs") end)
buttons.Story.Activated:Connect(function() Panels.Open("Story") end)

---------------------------------------------------------------------------
-- 3. SERVER -> SCREEN
-- Each OnClientEvent function receives exactly what the server put in FireClient(player, ...)
---------------------------------------------------------------------------
Remotes.DataUpdated.OnClientEvent:Connect(function(data)
	HUD.UpdateData(data)
	Panels.UpdateData(data)
end)

Remotes.EnemyUpdated.OnClientEvent:Connect(HUD.SetEnemy)       -- (info)
Remotes.EnemyHit.OnClientEvent:Connect(HUD.EnemyHit)           -- (info)
Remotes.EnemyDefeated.OnClientEvent:Connect(HUD.EnemyDefeated) -- (rewards)

Remotes.Hatched.OnClientEvent:Connect(function(characterId)
	isHatching = true
	Panels.Close()                    -- hide the egg window during the show
	Effects.PlayHatch(characterId)    -- this waits until the animation is done
	isHatching = false
end)

-- kind = "Good", "Bad" or "Level" (picks the color)
local NOTIFY_COLORS = { Good = C.Green, Bad = C.Red, Level = C.Gold }
Remotes.Notify.OnClientEvent:Connect(function(message, kind)
	Effects.Toast(message, NOTIFY_COLORS[kind])
end)

---------------------------------------------------------------------------
-- 4. TELL THE SERVER WE'RE READY
-- Everything above is hooked up, so now ask for our data + enemy.
---------------------------------------------------------------------------
Remotes.Ready:FireServer()

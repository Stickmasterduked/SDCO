--[[
	GameServer  (Script in ServerScriptService)

	The "boss" of the server. It doesn't do much itself. It:
	  1. creates the RemoteEvents (the "phone lines" between client and server)
	  2. starts up the Services (DataService, CombatService, ShopService)
	  3. connects player join/leave and client requests to the right service

	CLIENT vs SERVER:
	  - Server (this Script) = Roblox's computer. It's the truth: it holds data and saves it.
	  - Client (LocalScript) = the player's computer. It draws the UI and sends requests.
	  - RemoteEvent = how they talk.
	        client -> server:  Remote:FireServer(...)       server hears it with  Remote.OnServerEvent
	        server -> client:  Remote:FireClient(player, ...) client hears it with  Remote.OnClientEvent
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

---------------------------------------------------------------------------
-- 1. CREATE THE REMOTEEVENTS
---------------------------------------------------------------------------
local REMOTE_NAMES = {
	-- client -> server (requests)
	"Ready",       -- "my UI is built, send me my stuff"
	"Attack",      -- "I clicked attack"
	"BuyUpgrade",  -- "I want to buy this upgrade"
	"HatchEgg",    -- "I want to hatch this egg"
	-- server -> client (updates)
	"DataUpdated",   -- here is your latest data
	"EnemyUpdated",  -- here is your new enemy
	"EnemyHit",      -- your enemy took damage
	"EnemyDefeated", -- your enemy died, here are your rewards
	"Hatched",       -- you hatched this character
	"Notify",        -- show a little message
}

local remoteFolder = Instance.new("Folder")
remoteFolder.Name = "Remotes"

local remotes = {} -- remotes.Attack, remotes.Notify, ... (easy to pass around)
for _, name in ipairs(REMOTE_NAMES) do
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = remoteFolder
	remotes[name] = remote
end
remoteFolder.Parent = ReplicatedStorage -- parent LAST so the client sees all of them at once

---------------------------------------------------------------------------
-- 2. START THE SERVICES
---------------------------------------------------------------------------
local Services = ServerScriptService.Services
local DataService = require(Services.DataService)
local CombatService = require(Services.CombatService)
local ShopService = require(Services.ShopService)

DataService.Init(remotes)
CombatService.Init(remotes)
ShopService.Init(remotes)

---------------------------------------------------------------------------
-- 3. PLAYERS JOINING AND LEAVING
---------------------------------------------------------------------------
local function onPlayerAdded(player)
	DataService.Load(player)            -- load their save
	ShopService.CheckGamepasses(player) -- turn on gamepasses they own
	DataService.Push(player)            -- send data to their screen
	CombatService.SpawnEnemy(player)    -- give them an enemy
end

local function onPlayerRemoving(player)
	CombatService.Remove(player)
	ShopService.Remove(player)
	DataService.Release(player) -- saves before forgetting them
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- In Studio you can join BEFORE this script runs, so handle anyone already here
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

---------------------------------------------------------------------------
-- 4. LISTEN TO CLIENT REQUESTS
-- OnServerEvent always gives the PLAYER who sent it as the first thing,
-- then whatever the client passed in FireServer(...).
---------------------------------------------------------------------------
remotes.Ready.OnServerEvent:Connect(function(player)
	DataService.Push(player)
	CombatService.SendState(player)
end)

remotes.Attack.OnServerEvent:Connect(CombatService.HandleAttack) -- same as function(player) CombatService.HandleAttack(player) end
remotes.BuyUpgrade.OnServerEvent:Connect(ShopService.BuyUpgrade) -- (player, upgradeId)
remotes.HatchEgg.OnServerEvent:Connect(ShopService.HatchEgg)     -- (player, eggId)

---------------------------------------------------------------------------
-- 5. AUTO ATTACK + AUTOSAVE
---------------------------------------------------------------------------
CombatService.StartAutoAttack()

task.spawn(function()
	while true do
		task.wait(60)
		DataService.SaveAll() -- autosave every minute
	end
end)

-- When the server shuts down, save everyone first
game:BindToClose(function()
	DataService.SaveAll()
end)

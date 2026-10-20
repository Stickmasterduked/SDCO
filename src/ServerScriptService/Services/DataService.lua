--[[
	DataService  (ModuleScript in ServerScriptService > Services)

	Loads and SAVES player data using DataStoreService.

	IMPORTANT for testing in Studio:
	  1. Publish the game (File > Publish to Roblox)
	  2. Game Settings > Security > turn ON "Enable Studio Access to API Services"
	  Without that, the game still works, it just won't save (you'll see a warning in Output).

	HOW SAVING WORKS:
	  - Player joins  -> Load()  : read their data from the DataStore (or give starter data)
	  - While playing -> the data lives in the "profiles" table on the server
	  - Every 60 sec  -> SaveAll(): autosave, in case the server crashes
	  - Player leaves -> Release(): save one last time, then forget them
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local DataService = {}

local STORE_NAME = "PlayerData_v1" -- change the name to wipe everyone's data (a fresh "save file")
local profiles = {} -- profiles[player] = { Data = {...}, CanSave = true/false }
local remotes = nil -- the RemoteEvents, handed to us in Init()

-- Get the DataStore. pcall = "try it, and don't crash if it fails"
-- (it fails in Studio when API access is off)
local storeOk, store = pcall(function()
	return DataStoreService:GetDataStore(STORE_NAME)
end)
if not storeOk then
	warn("[DataService] DataStores are off, so progress will NOT save. Turn on Studio API access to test saving.")
	store = nil
end

-- deepCopy(original): make a full copy of a table (and tables inside it).
-- We need this so every player gets their OWN Upgrades/Team tables instead of sharing one.
local function deepCopy(original)
	local copy = {}
	for key, value in pairs(original) do
		if type(value) == "table" then
			copy[key] = deepCopy(value) -- copy tables inside tables too
		else
			copy[key] = value
		end
	end
	return copy
end

-- fillMissing(data): if we add a NEW field to StartingData later,
-- old saves won't have it. This adds any missing fields with their starting values.
local function fillMissing(data)
	for key, startingValue in pairs(GameConfig.StartingData) do
		if data[key] == nil then
			data[key] = type(startingValue) == "table" and deepCopy(startingValue) or startingValue
		end
	end
	return data
end

-- Init(remoteEvents): GameServer calls this once at startup
function DataService.Init(remoteEvents)
	remotes = remoteEvents
end

-- Load(player): read saved data (or make new data). Tries 3 times in case Roblox is slow.
function DataService.Load(player)
	local key = "Player_" .. player.UserId -- every player gets their own "slot" in the store
	local saved = nil
	local loadedOk = (store == nil) -- no store = nothing to load (but we also won't save)

	if store then
		for attempt = 1, 3 do
			local ok, result = pcall(function()
				return store:GetAsync(key) -- "Async" = this waits for Roblox's servers to answer
			end)
			if ok then
				saved = result -- nil for brand-new players
				loadedOk = true
				break -- success, stop retrying
			end
			warn("[DataService] Load failed for " .. player.Name .. " (try " .. attempt .. "): " .. tostring(result))
			task.wait(1)
		end
	end

	if not player.Parent then
		return nil -- they left while we were loading, nothing to do
	end

	local data = fillMissing(saved or deepCopy(GameConfig.StartingData)) -- old save, or brand-new data
	data.Passes = {} -- gamepasses are checked fresh every join (ShopService fills these)

	profiles[player] = {
		Data = data,
		-- If loading FAILED, never save. Otherwise we'd overwrite their real
		-- progress with starter data!
		CanSave = loadedOk and store ~= nil,
	}
	return data
end

-- Get(player): the player's live data table (nil if not loaded yet)
function DataService.Get(player)
	local profile = profiles[player]
	return profile and profile.Data -- "a and b" = if a exists, give b
end

-- Push(player): send the latest data to that player's screen
function DataService.Push(player)
	local data = DataService.Get(player)
	if data and remotes then
		remotes.DataUpdated:FireClient(player, data)
	end
end

-- Save(player): write the data to the DataStore
function DataService.Save(player)
	local profile = profiles[player]
	if not profile or not profile.CanSave then
		return
	end

	-- Only save the fields from StartingData (so "Passes" etc. never get saved)
	local toSave = {}
	for key in pairs(GameConfig.StartingData) do
		toSave[key] = profile.Data[key]
	end

	local ok, err = pcall(function()
		store:SetAsync("Player_" .. player.UserId, toSave)
	end)
	if not ok then
		warn("[DataService] Save failed for " .. player.Name .. ": " .. tostring(err))
	end
end

-- Release(player): player left. Save, then forget them.
function DataService.Release(player)
	DataService.Save(player)
	profiles[player] = nil
end

-- SaveAll(): save everyone (used by autosave and when the server shuts down)
function DataService.SaveAll()
	for player in pairs(profiles) do
		DataService.Save(player)
	end
end

return DataService

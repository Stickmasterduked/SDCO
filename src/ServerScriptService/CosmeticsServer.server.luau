--[[
	Cosmetics ownership and equipping (server-authoritative).

	Ownership: exclusive items are granted by name/UserId in Items.Catalog
	(Void Wings -> merreystantach2). Nothing is sold or tradeable, so grants
	are the only source. The server publishes:
		player:GetAttribute("OwnedCosmetics")  -- "VoidWings,..."
		player:GetAttribute("EquippedWings")   -- item id or nil
	Clients render whatever is equipped (CosmeticsClient), so wearing costs
	no replication beyond one attribute.

	Equip choices persist in a DataStore. A granted item the player has never
	taken off is worn by default.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Items = require(ReplicatedStorage:WaitForChild("Cosmetics"):WaitForChild("Items"))

local remote = ReplicatedStorage:FindFirstChild("CosmeticsRemote")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "CosmeticsRemote"
	remote.Parent = ReplicatedStorage
end

local store
pcall(function()
	store = DataStoreService:GetDataStore("SDCO_Cosmetics_v1")
end)

local owned: { [Player]: { [string]: boolean } } = {}
local saved: { [Player]: { [string]: string } } = {}
local dirty: { [Player]: boolean } = {}
local lastRequest: { [Player]: number } = {}

local function key(player: Player)
	return "u_" .. player.UserId
end

local function load(player: Player): { [string]: string }?
	if not store then
		return nil
	end
	local ok, data = pcall(function()
		return store:GetAsync(key(player))
	end)
	return if ok and type(data) == "table" then data else nil
end

local function save(player: Player)
	if not (store and dirty[player] and saved[player]) then
		return
	end
	dirty[player] = nil
	local data = table.clone(saved[player])
	local ok, err = pcall(function()
		store:SetAsync(key(player), data, { player.UserId })
	end)
	if not ok then
		warn("[Cosmetics] save failed for " .. player.Name .. ": " .. tostring(err))
	end
end

local function wear(player: Player, slot: string, id: string?)
	player:SetAttribute("Equipped" .. slot, id)
end

local function setup(player: Player)
	if owned[player] then
		return
	end
	local list = Items.grantedTo(player)
	local set = {}
	for _, id in ipairs(list) do
		set[id] = true
	end
	owned[player] = set
	player:SetAttribute("OwnedCosmetics", table.concat(list, ","))

	saved[player] = {}
	local data = load(player) or {}
	if not owned[player] then
		return -- left while loading
	end
	for slot, id in pairs(saved[player]) do
		data[slot] = id -- a choice made while the store was loading wins
	end
	saved[player] = data
	for _, slot in ipairs(Items.Slots) do
		local choice = data[slot]
		if choice == nil then
			-- never chosen: wear the first owned item for this slot
			for _, id in ipairs(list) do
				if Items.Catalog[id].Category == slot then
					choice = id
					break
				end
			end
		end
		wear(player, slot, if choice and choice ~= "" and set[choice] then choice else nil)
	end
end

remote.OnServerEvent:Connect(function(player: Player, action, id)
	local now = os.clock()
	if lastRequest[player] and now - lastRequest[player] < 0.25 then
		return
	end
	lastRequest[player] = now
	local set = owned[player]
	if not set then
		return
	end

	if action == "Equip" and type(id) == "string" then
		local item = Items.get(id)
		if item and set[id] then
			wear(player, item.Category, id)
			saved[player][item.Category] = id
			dirty[player] = true
		end
	elseif action == "Unequip" and type(id) == "string" then
		if table.find(Items.Slots, id) then
			wear(player, id, nil)
			saved[player][id] = "" -- remember the choice, so the default doesn't come back
			dirty[player] = true
		end
	end
end)

Players.PlayerAdded:Connect(setup)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(setup, player)
end

Players.PlayerRemoving:Connect(function(player)
	save(player)
	owned[player] = nil
	saved[player] = nil
	dirty[player] = nil
	lastRequest[player] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(save, player)
	end
	task.wait(2)
end)

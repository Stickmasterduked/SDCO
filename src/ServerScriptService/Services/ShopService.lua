--[[
	ShopService  (ModuleScript in ServerScriptService > Services)

	Buying upgrades, hatching eggs and checking gamepasses.
	The server picks the random character, so players can't cheat a Mythic.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Formulas = require(ReplicatedStorage.Shared.Formulas)
local DataService = require(ServerScriptService.Services.DataService)

local ShopService = {}

local remotes = nil
local lastHatch = {} -- lastHatch[player] = when they last hatched (stops spamming during the animation)
local HATCH_COOLDOWN = 3 -- seconds

function ShopService.Init(remoteEvents)
	remotes = remoteEvents

	-- When someone finishes buying a gamepass in-game, turn it on right away
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then return end -- they cancelled
		local data = DataService.Get(player)
		if not data then return end
		for _, pass in ipairs(GameConfig.Gamepasses) do
			if pass.PassId == passId then
				data.Passes[pass.Key] = true
				remotes.Notify:FireClient(player, pass.Name .. " is now active. Thank you!", "Good")
			end
		end
		DataService.Push(player)
	end)
end

-- trySpend(player, data, currency, price): take the money if they have enough
local function trySpend(player, data, currency, price)
	if data[currency] >= price then -- data["Coins"] is the same as data.Coins
		data[currency] = data[currency] - price
		return true
	end
	remotes.Notify:FireClient(player, "Not enough " .. currency .. "!", "Bad")
	return false
end

-- BuyUpgrade(player, upgradeId): the client asked to buy an upgrade
function ShopService.BuyUpgrade(player, upgradeId)
	local data = DataService.Get(player)
	local upgrade = Formulas.FindById(GameConfig.Upgrades, upgradeId) -- nil if the client sent junk
	if not data or not upgrade then return end

	local timesBought = data.Upgrades[upgrade.Id] or 0
	if trySpend(player, data, upgrade.Currency, Formulas.UpgradeCost(upgrade, timesBought)) then
		data.Upgrades[upgrade.Id] = timesBought + 1
		remotes.Notify:FireClient(player, upgrade.Name .. " upgraded!", "Good")
	end
	DataService.Push(player)
end

-- pickRandomCharacter(): weighted random pick using each character's Chance
--   chances: 35, 25, 20, 12, 6, 2  -> running totals: 35, 60, 80, 92, 98, 100
--   roll a number from 0-100, e.g. 73 -> first running total it fits under is 80 -> Fire Mage
local function pickRandomCharacter()
	local total = 0
	for _, character in ipairs(GameConfig.Characters) do
		total = total + character.Chance
	end

	local roll = math.random() * total -- math.random() = random decimal between 0 and 1
	local runningTotal = 0
	for _, character in ipairs(GameConfig.Characters) do
		runningTotal = runningTotal + character.Chance
		if roll <= runningTotal then
			return character
		end
	end
	return GameConfig.Characters[1] -- backup, should never happen
end

-- HatchEgg(player, eggId): the client asked to hatch an egg
function ShopService.HatchEgg(player, eggId)
	local data = DataService.Get(player)
	local egg = Formulas.FindById(GameConfig.Eggs, eggId)
	if not data or not egg then return end

	local now = os.clock()
	if lastHatch[player] and now - lastHatch[player] < HATCH_COOLDOWN then
		return -- still hatching the last one
	end
	if not trySpend(player, data, egg.Currency, egg.Price) then
		DataService.Push(player)
		return
	end
	lastHatch[player] = now

	local best = pickRandomCharacter()
	for _ = 2, egg.Rolls do -- extra rolls (only the Golden Egg has more than 1)
		local another = pickRandomCharacter()
		if another.Power > best.Power then
			best = another -- keep the stronger one
		end
	end

	table.insert(data.Team, best.Id) -- add to the end of the team list
	remotes.Hatched:FireClient(player, best.Id, egg.Id)
	DataService.Push(player)
end

-- CheckGamepasses(player): on join, see which gamepasses they already own
function ShopService.CheckGamepasses(player)
	local data = DataService.Get(player)
	if not data then return end
	for _, pass in ipairs(GameConfig.Gamepasses) do
		if pass.PassId ~= 0 then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.PassId)
			end)
			if ok and owns then
				data.Passes[pass.Key] = true
			end
		end
	end
end

function ShopService.Remove(player)
	lastHatch[player] = nil
end

return ShopService

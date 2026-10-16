--[[
	Cosmetics catalog. Shared by the server (ownership, equipping) and the
	client (rendering, inventory / shop preview).

	Exclusive items are never sold or traded: they are owned only by the
	players named in GrantedTo (usernames, compared case-insensitively) or
	GrantedUserIds.
]]

local Items = {}

Items.Rarities = {
	Common = { Order = 1, Color = Color3.fromRGB(190, 190, 200) },
	Rare = { Order = 2, Color = Color3.fromRGB(90, 140, 255) },
	Epic = { Order = 3, Color = Color3.fromRGB(170, 80, 255) },
	Legendary = { Order = 4, Color = Color3.fromRGB(255, 190, 60) },
	Mythic = { Order = 5, Color = Color3.fromRGB(255, 80, 220) },
}

-- one item per slot can be worn at a time
Items.Slots = { "Wings" }

Items.Catalog = {
	VoidWings = {
		Id = "VoidWings",
		Name = "Void Wings",
		Category = "Wings",
		Rarity = "Mythic",
		Description = "Blades of living void. You can see the galaxy flow through them.",
		Exclusive = true,
		ForSale = false,
		Tradeable = false,
		Price = nil,
		GrantedTo = { "merreystantach2" },
		GrantedUserIds = {},
		Rig = "VoidWings", -- module under ReplicatedStorage.Cosmetics
	},
}

function Items.get(id: string?)
	return if id then Items.Catalog[id] else nil
end

function Items.isGranted(item, player: Player): boolean
	local name = string.lower(player.Name)
	for _, granted in ipairs(item.GrantedTo or {}) do
		if string.lower(granted) == name then
			return true
		end
	end
	for _, userId in ipairs(item.GrantedUserIds or {}) do
		if userId == player.UserId then
			return true
		end
	end
	return false
end

-- Items a player owns from grants alone (exclusives). Purchases would be
-- added here by the server once anything is for sale.
function Items.grantedTo(player: Player): { string }
	local owned = {}
	for id, item in pairs(Items.Catalog) do
		if Items.isGranted(item, player) then
			table.insert(owned, id)
		end
	end
	table.sort(owned)
	return owned
end

-- The server publishes ownership as a comma-separated attribute.
function Items.owned(player: Player): { [string]: boolean }
	local set = {}
	for id in string.gmatch(player:GetAttribute("OwnedCosmetics") or "", "[^,]+") do
		set[id] = true
	end
	return set
end

function Items.equipped(player: Player, slot: string): string?
	local id = player:GetAttribute("Equipped" .. slot)
	return if type(id) == "string" and Items.Catalog[id] then id else nil
end

return Items

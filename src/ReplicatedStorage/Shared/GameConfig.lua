--[[
	GameConfig  (ModuleScript in ReplicatedStorage > Shared)

	ALL the game's settings live here: characters, chapters, eggs, prices.
	It's in ReplicatedStorage so BOTH the server and the client can read it.

	Want a new character or chapter? Add a line here. No other file has to change.

	WHAT IS A MODULESCRIPT?
	  A script that doesn't run on its own. Other scripts "require" it to borrow
	  what it returns:
	      local GameConfig = require(path.To.GameConfig)
	      print(GameConfig.StagesPerChapter) --> 10
]]

local GameConfig = {} -- an empty table that we fill below and return at the end

---------------------------------------------------------------------------
-- STORY MODE
---------------------------------------------------------------------------
GameConfig.StagesPerChapter = 10 -- stage 10, 20, 30... is always a boss

GameConfig.Chapters = {
	{ Name = "Slime Meadow",  Enemies = { "Green Slime", "Bouncy Blob", "Jelly Cube" },   Boss = "King Slime" },
	{ Name = "Spooky Forest", Enemies = { "Angry Shroom", "Bat Goblin", "Ghost Fox" },    Boss = "Ancient Treant" },
	{ Name = "Lava Volcano",  Enemies = { "Fire Imp", "Magma Crab", "Ash Golem" },        Boss = "Magma Dragon" },
	{ Name = "Sky Castle",    Enemies = { "Cloud Knight", "Storm Hawk", "Sky Wizard" },   Boss = "Storm Titan" },
}

---------------------------------------------------------------------------
-- CHARACTERS (hatched from eggs)
--   Id     = a short unique name we SAVE (never change it once players have it!)
--   Chance = how likely. These add up to 100, so they read like percentages.
--   Power  = extra auto damage per second this character gives your team
---------------------------------------------------------------------------
GameConfig.Characters = {
	{ Id = "NinjaKid",     Name = "Ninja Kid",         Rarity = "Common",    Chance = 35, Power = 1 },
	{ Id = "SlimeTamer",   Name = "Slime Tamer",       Rarity = "Common",    Chance = 25, Power = 2 },
	{ Id = "FireMage",     Name = "Fire Mage",         Rarity = "Rare",      Chance = 20, Power = 5 },
	{ Id = "ThunderSam",   Name = "Thunder Samurai",   Rarity = "Epic",      Chance = 12, Power = 12 },
	{ Id = "ShadowKing",   Name = "Shadow King",       Rarity = "Legendary", Chance = 6,  Power = 40 },
	{ Id = "CelestialGod", Name = "Celestial Goddess", Rarity = "Mythic",    Chance = 2,  Power = 150 },
}

-- Rarity colors (only used for hatching + your team list)
GameConfig.RarityColors = {
	Common    = Color3.fromRGB(190, 196, 220),
	Rare      = Color3.fromRGB(80, 170, 255),
	Epic      = Color3.fromRGB(175, 100, 255),
	Legendary = Color3.fromRGB(255, 200, 50),
	Mythic    = Color3.fromRGB(255, 80, 120),
}

---------------------------------------------------------------------------
-- EGGS
--   Rolls = how many random picks. 2 means "roll twice, keep the best".
---------------------------------------------------------------------------
GameConfig.Eggs = {
	{ Id = "Basic",  Name = "Basic Egg",  Price = 100, Currency = "Coins", Rolls = 1, Description = "A classic egg." },
	{ Id = "Golden", Name = "Golden Egg", Price = 15,  Currency = "Gems",  Rolls = 2, Description = "Rolls twice, keeps the best!" },
}

---------------------------------------------------------------------------
-- SHOP UPGRADES
--   Stat   = which stat goes up ("ClickPower" or "AutoPower")
--   Amount = how much it goes up per purchase
--   The price goes up every time you buy one (see Formulas.UpgradeCost)
---------------------------------------------------------------------------
GameConfig.Upgrades = {
	{ Id = "Sword",    Name = "Sharper Sword", Description = "+1 Click Damage",   Stat = "ClickPower", Amount = 1,  BaseCost = 25, Currency = "Coins" },
	{ Id = "Training", Name = "Hero Training", Description = "+2 Auto Damage/s",  Stat = "AutoPower",  Amount = 2,  BaseCost = 60, Currency = "Coins" },
	{ Id = "GemBlade", Name = "Gem Blade",     Description = "+10 Click Damage",  Stat = "ClickPower", Amount = 10, BaseCost = 10, Currency = "Gems" },
}

---------------------------------------------------------------------------
-- GAMEPASSES
--   PassId = your real gamepass number from the Creator Dashboard (0 = not set up yet)
--   Key    = the name the code uses to check "does the player own this?"
---------------------------------------------------------------------------
GameConfig.Gamepasses = {
	{ Key = "DoubleCoins",  PassId = 0, Name = "2x Coins",  Description = "Double every coin you earn!" },
	{ Key = "DoubleDamage", PassId = 0, Name = "2x Damage", Description = "Hit twice as hard!" },
	{ Key = "VIP",          PassId = 0, Name = "VIP",       Description = "+50% gems from bosses!" },
}

---------------------------------------------------------------------------
-- NEW PLAYER DATA (what a brand-new player starts with)
-- Only the fields listed here get SAVED.
---------------------------------------------------------------------------
GameConfig.StartingData = {
	Coins = 0,
	Gems = 0,
	Level = 1,
	XP = 0,
	Stage = 1,
	Upgrades = {}, -- e.g. { Sword = 3 } = bought Sharper Sword 3 times
	Team = {},     -- list of character Ids, e.g. { "NinjaKid", "FireMage" }
}

---------------------------------------------------------------------------
-- ANTI-CHEAT
---------------------------------------------------------------------------
GameConfig.MaxClicksPerSecond = 12 -- ignore clicks faster than this (stops auto-clicker exploits)

return GameConfig -- hand the finished table to whoever "requires" this module

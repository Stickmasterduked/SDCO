--[[
	Formulas  (ModuleScript in ReplicatedStorage > Shared)

	All the game MATH in one place. The server uses it for the real numbers;
	the client uses it to show the same numbers on screen.

	Quick math cheat sheet:
	  a ^ b        = a to the power of b.   1.35 ^ 2 = 1.35 * 1.35 = 1.8225
	  a % b        = the remainder after dividing.   23 % 10 = 3
	  math.floor(x) = round DOWN to a whole number.   4.9 -> 4
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.Shared.GameConfig) -- borrow the settings

local Formulas = {}

-- FindById(list, id): search a list (like GameConfig.Eggs) for the item whose Id matches
-- Example: Formulas.FindById(GameConfig.Eggs, "Golden") --> the Golden Egg table
function Formulas.FindById(list, id)
	for _, item in ipairs(list) do -- look at each item in order
		if item.Id == id then -- found it?
			return item -- give it back and stop searching
		end
	end
	return nil -- nil means "nothing found"
end

-- GetChapter(stage): which chapter a stage is in. Stage 1-10 = chapter 1, 11-20 = chapter 2...
-- Gives back TWO things: the chapter table and its number.
function Formulas.GetChapter(stage)
	local number = math.floor((stage - 1) / GameConfig.StagesPerChapter) + 1 -- stage 15 -> floor(14/10)+1 = 2
	local lastChapter = #GameConfig.Chapters -- "#" = how many items are in a list
	return GameConfig.Chapters[math.min(number, lastChapter)], number -- past the last chapter? keep using the last one (endless mode)
end

-- IsBoss(stage): true on stage 10, 20, 30...
function Formulas.IsBoss(stage)
	return stage % GameConfig.StagesPerChapter == 0
end

-- EnemyHealth(stage): every stage has 35% more health. Bosses have 5x.
function Formulas.EnemyHealth(stage)
	local health = math.floor(10 * 1.35 ^ (stage - 1))
	if Formulas.IsBoss(stage) then
		health = health * 5
	end
	return health
end

-- CoinReward(stage): every stage gives 25% more coins. Bosses give 10x.
function Formulas.CoinReward(stage)
	local coins = math.floor(5 * 1.25 ^ (stage - 1))
	if Formulas.IsBoss(stage) then
		coins = coins * 10
	end
	return coins
end

-- GemReward(stage): only bosses give gems. Later bosses give more.
function Formulas.GemReward(stage)
	if not Formulas.IsBoss(stage) then
		return 0
	end
	return 5 + math.floor(stage / 10) * 2 -- boss 10 = 7 gems, boss 20 = 9 gems...
end

-- XPNeeded(level): XP needed to reach the next level
function Formulas.XPNeeded(level)
	return level * 10
end

-- UpgradeCost(upgrade, timesBought): price goes up 1.5x per purchase
function Formulas.UpgradeCost(upgrade, timesBought)
	return math.floor(upgrade.BaseCost * 1.5 ^ timesBought)
end

-- GetStat(data, statName): base value 1 + everything your upgrades added
function Formulas.GetStat(data, statName)
	local total = 1 -- everyone starts with 1
	for _, upgrade in ipairs(GameConfig.Upgrades) do
		if upgrade.Stat == statName then -- this upgrade boosts the stat we want
			local timesBought = data.Upgrades[upgrade.Id] or 0 -- "or 0" = use 0 if never bought
			total = total + upgrade.Amount * timesBought
		end
	end
	return total
end

-- TeamPower(data): add up the Power of every character the player owns
function Formulas.TeamPower(data)
	local total = 0
	for _, characterId in ipairs(data.Team) do
		local character = Formulas.FindById(GameConfig.Characters, characterId)
		if character then -- skip it if the character was removed from GameConfig
			total = total + character.Power
		end
	end
	return total
end

-- ClickDamage(data): damage from one click. +1 per player level.
function Formulas.ClickDamage(data)
	local damage = Formulas.GetStat(data, "ClickPower") + (data.Level - 1)
	if data.Passes and data.Passes.DoubleDamage then -- owns the 2x Damage gamepass?
		damage = damage * 2
	end
	return damage
end

-- AutoDamage(data): damage your hero + team deal every second on their own
function Formulas.AutoDamage(data)
	local damage = Formulas.GetStat(data, "AutoPower") + Formulas.TeamPower(data)
	if data.Passes and data.Passes.DoubleDamage then
		damage = damage * 2
	end
	return damage
end

-- FormatNumber(n): 1500 -> "1.5K", 2000000 -> "2.0M" so numbers stay short
function Formulas.FormatNumber(n)
	n = math.floor(n)
	if n >= 1e9 then return string.format("%.1fB", n / 1e9) end -- 1e9 = 1,000,000,000
	if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if n >= 1e3 then return string.format("%.1fK", n / 1e3) end
	return tostring(n)
end

return Formulas

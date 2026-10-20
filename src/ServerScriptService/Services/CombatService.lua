--[[
	CombatService  (ModuleScript in ServerScriptService > Services)

	Handles fighting: each player has their own enemy.
	The SERVER decides all damage and rewards. The client only says "I clicked".
	That way exploiters can't give themselves a million damage.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Formulas = require(ReplicatedStorage.Shared.Formulas)
local DataService = require(ServerScriptService.Services.DataService)

local CombatService = {}

local remotes = nil
local enemies = {} -- enemies[player] = { Name, Health, MaxHealth, IsBoss, Dead }
local clickLog = {} -- clickLog[player] = { Count = 0, WindowStart = 0 } (for the anti-cheat)

function CombatService.Init(remoteEvents)
	remotes = remoteEvents
end

-- sendEnemy(player): tell the client what enemy they're fighting
local function sendEnemy(player)
	local enemy = enemies[player]
	local data = DataService.Get(player)
	if not enemy or not data then return end

	local chapter, chapterNumber = Formulas.GetChapter(data.Stage)
	remotes.EnemyUpdated:FireClient(player, {
		Name = enemy.Name,
		Health = enemy.Health,
		MaxHealth = enemy.MaxHealth,
		IsBoss = enemy.IsBoss,
		Stage = data.Stage,
		ChapterName = chapter.Name,
		ChapterNumber = chapterNumber,
	})
end

-- SpawnEnemy(player): make a new enemy for the player's current stage
function CombatService.SpawnEnemy(player)
	local data = DataService.Get(player)
	if not data then return end

	local chapter = Formulas.GetChapter(data.Stage)
	local isBoss = Formulas.IsBoss(data.Stage)
	local name = isBoss and chapter.Boss or chapter.Enemies[math.random(1, #chapter.Enemies)]

	enemies[player] = {
		Name = name,
		Health = Formulas.EnemyHealth(data.Stage),
		MaxHealth = Formulas.EnemyHealth(data.Stage),
		IsBoss = isBoss,
		Dead = false,
	}
	sendEnemy(player)
end

-- addXP(data, amount): give XP and level up (maybe several times!)
local function addXP(player, data, amount)
	data.XP = data.XP + amount
	while data.XP >= Formulas.XPNeeded(data.Level) do -- "while" keeps going as long as this is true
		data.XP = data.XP - Formulas.XPNeeded(data.Level)
		data.Level = data.Level + 1
		remotes.Notify:FireClient(player, "LEVEL UP! You're level " .. data.Level, "Level")
	end
end

-- defeat(player): enemy hit 0 health. Give rewards and move to the next stage.
local function defeat(player)
	local enemy = enemies[player]
	local data = DataService.Get(player)
	enemy.Dead = true -- stop more hits from counting

	local coins = Formulas.CoinReward(data.Stage)
	if data.Passes.DoubleCoins then coins = coins * 2 end

	local gems = Formulas.GemReward(data.Stage)
	if data.Passes.VIP then gems = math.floor(gems * 1.5) end
	if not enemy.IsBoss and math.random(1, 10) == 1 then -- normal enemies: 1 in 10 chance of a bonus gem
		gems = 1
	end

	data.Coins = data.Coins + coins
	data.Gems = data.Gems + gems
	addXP(player, data, enemy.IsBoss and 10 or 2) -- "a and b or c" = if a then b, otherwise c

	remotes.EnemyDefeated:FireClient(player, { Coins = coins, Gems = gems, WasBoss = enemy.IsBoss })
	data.Stage = data.Stage + 1
	DataService.Push(player)

	task.wait(0.6) -- give the death animation time to play
	if player.Parent then -- still in the game?
		CombatService.SpawnEnemy(player)
	end
end

-- Damage(player, amount, isAuto): hurt the player's enemy
function CombatService.Damage(player, amount, isAuto)
	local enemy = enemies[player]
	if not enemy or enemy.Dead then return end

	enemy.Health = math.max(enemy.Health - amount, 0) -- never go below 0
	remotes.EnemyHit:FireClient(player, {
		Damage = amount,
		Health = enemy.Health,
		MaxHealth = enemy.MaxHealth,
		IsAuto = isAuto,
	})

	if enemy.Health <= 0 then
		task.spawn(defeat, player) -- task.spawn runs it "on the side" so the wait() inside doesn't block us
	end
end

-- HandleAttack(player): the client clicked ATTACK. Check it's not a cheat, then deal damage.
function CombatService.HandleAttack(player)
	local data = DataService.Get(player)
	if not data then return end

	local log = clickLog[player]
	local now = os.clock() -- seconds since the server started
	if not log or now - log.WindowStart >= 1 then -- a new 1-second window
		log = { Count = 0, WindowStart = now }
		clickLog[player] = log
	end
	log.Count = log.Count + 1
	if log.Count > GameConfig.MaxClicksPerSecond then
		return -- clicking way too fast = ignore it
	end

	CombatService.Damage(player, Formulas.ClickDamage(data), false)
end

-- StartAutoAttack(): every second, every player's team hits their enemy automatically
function CombatService.StartAutoAttack()
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in ipairs(Players:GetPlayers()) do
				local data = DataService.Get(player)
				if data then
					CombatService.Damage(player, Formulas.AutoDamage(data), true)
				end
			end
		end
	end)
end

-- SendState(player): re-send the current enemy (used when the client says "I'm ready")
function CombatService.SendState(player)
	sendEnemy(player)
end

-- Remove(player): player left, forget their enemy
function CombatService.Remove(player)
	enemies[player] = nil
	clickLog[player] = nil
end

return CombatService

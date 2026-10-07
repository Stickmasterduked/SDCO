local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatService = require(script.Parent.CombatService)
local Remotes = ReplicatedStorage.Combat.Remotes

local RESPAWN_DELAY = 3
local MAX_ACTIONS_PER_SECOND = 24

-- Players spawn as R6 with their own avatar.
Players.CharacterAutoLoads = false

local function getSpawnCFrame()
	local spawn = workspace:FindFirstChildOfClass("SpawnLocation")
	if spawn then
		return spawn.CFrame + Vector3.new(0, spawn.Size.Y / 2 + 3, 0)
	end
	return CFrame.new(0, 5, 0)
end

local function spawnCharacter(player)
	local ok, description = pcall(function()
		return Players:GetHumanoidDescriptionFromUserId(math.max(player.UserId, 1))
	end)
	if not ok then
		description = Instance.new("HumanoidDescription")
	end

	local character = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	character.Name = player.Name
	character:PivotTo(getSpawnCFrame())
	character.Parent = workspace
	player.Character = character

	character:WaitForChild("Humanoid").Died:Connect(function()
		task.wait(RESPAWN_DELAY)
		if player.Parent then
			character:Destroy()
			spawnCharacter(player)
		end
	end)
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		CombatService.register(character, player)
	end)
	spawnCharacter(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

------------------------------------------------------------------------
-- Input

local budgets = {}

local function withinBudget(player)
	local t = os.clock()
	local budget = budgets[player]
	if not budget or t - budget.start >= 1 then
		budget = { start = t, count = 0 }
		budgets[player] = budget
	end
	budget.count += 1
	return budget.count <= MAX_ACTIONS_PER_SECOND
end

Players.PlayerRemoving:Connect(function(player)
	budgets[player] = nil
end)

local handlers = {
	M1 = function(c, arg)
		local options = type(arg) == "table" and arg or {}
		return CombatService.m1(c, {
			launcher = options.launcher == true,
			airborne = options.airborne == true,
		}, true)
	end,
	Critical = function(c)
		return CombatService.critical(c, true)
	end,
	Skill = function(c)
		return CombatService.skill(c, true)
	end,
	Feint = function(c)
		return CombatService.feint(c, true)
	end,
	BlockDown = function(c, arg)
		return CombatService.blockDown(c, arg == true, true)
	end,
	BlockUp = function(c)
		return CombatService.blockUp(c, true)
	end,
	Roll = function(c, arg)
		return CombatService.roll(c, typeof(arg) == "Vector3" and arg or nil, true)
	end,
	Sprint = function(c, arg)
		return CombatService.setSprint(c, arg == true)
	end,
}

Remotes.Action.OnServerEvent:Connect(function(player, action, sequence, arg)
	local handler = type(action) == "string" and handlers[action]
	if not handler or not withinBudget(player) then
		return
	end

	local c = player.Character and CombatService.get(player.Character)
	if not c then
		return
	end

	local accepted, anim = handler(c, arg)
	if type(sequence) == "number" then
		Remotes.Ack:FireClient(player, sequence, accepted == true, anim)
	end
end)

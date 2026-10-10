local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatService = require(script.Parent.CombatService)
local Remotes = ReplicatedStorage.Combat.Remotes

local RESPAWN_DELAY = 3
local MAX_ACTIONS_PER_SECOND = 30

-- Players spawn as classic blocky R6: their own clothes, accessories, face
-- and skin colours, but no body packages or custom heads.
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

	-- force the blocky body: 0 = the default block part for each slot
	description.Head = 0
	description.Torso = 0
	description.LeftArm = 0
	description.RightArm = 0
	description.LeftLeg = 0
	description.RightLeg = 0
	description.HeightScale = 1
	description.WidthScale = 1
	description.DepthScale = 1
	description.HeadScale = 1
	description.BodyTypeScale = 0
	description.ProportionScale = 0

	local character = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	character.Name = player.Name
	-- PoseAnimator animates everything (idle, walk, run, jump, fall), so
	-- Roblox's default animations would only fight it.
	local animate = character:FindFirstChild("Animate")
	if animate then
		animate:Destroy()
	end
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
	-- the input's sequence number doubles as the attack id for hit claims
	M1 = function(c, arg, sequence)
		local options = type(arg) == "table" and arg or {}
		return CombatService.m1(c, {
			launcher = options.launcher == true,
			airborne = options.airborne == true,
		}, true, sequence)
	end,
	Critical = function(c, _, sequence)
		return CombatService.critical(c, true, sequence)
	end,
	-- H: Low Sweep (owner-only, checked in CombatService)
	LowSweep = function(c, _, sequence)
		return CombatService.lowSweep(c, true, sequence)
	end,
	-- Space just after an M1: that strike becomes an uptilt
	Launch = function(c, _, sequence)
		return CombatService.launch(c, true, sequence)
	end,
	-- the client's own hit detection: { id = attack id, target = model,
	-- start = where a grab was made from (Head Drive only) }
	Hit = function(c, arg)
		if type(arg) ~= "table" or type(arg.id) ~= "number" or typeof(arg.target) ~= "Instance" then
			return false
		end
		local start = typeof(arg.start) == "CFrame" and arg.start or nil
		return CombatService.claimHit(c, arg.id, arg.target, start)
	end,
	HeadDrive = function(c, _, sequence)
		return CombatService.headDrive(c, true, sequence)
	end,
	-- katana skills (katana drawn): Z Lumen Rush, X Moonfall Crescent
	KatanaRush = function(c, _, sequence)
		return CombatService.katanaRush(c, true, sequence)
	end,
	KatanaCrescent = function(c, _, sequence)
		return CombatService.katanaCrescent(c, true, sequence)
	end,
	Feint = function(c)
		return CombatService.feint(c, true)
	end,
	BlockDown = function(c, arg)
		local parryOnly = type(arg) == "table" and arg.parryOnly == true
		return CombatService.blockDown(c, arg == true, true, parryOnly)
	end,
	BlockUp = function(c)
		return CombatService.blockUp(c, true)
	end,
	Roll = function(c, arg)
		local options = type(arg) == "table" and arg or {}
		local direction = typeof(options.direction) == "Vector3" and options.direction or nil
		return CombatService.roll(c, direction, true, options.airborne == true)
	end,
	DoubleJump = function(c)
		return CombatService.doubleJump(c, true)
	end,
	Sprint = function(c, arg)
		return CombatService.setSprint(c, arg == true)
	end,
	Equip = function(c, arg)
		return CombatService.setEquipped(c, arg == true, true)
	end,
	-- E with a katana: draw it / put it away (fists otherwise)
	Katana = function(c, arg)
		return CombatService.setKatana(c, arg == true, true)
	end,
}

-- Fighting with your fists down puts them up.
local AUTO_EQUIP = { M1 = true, Critical = true, BlockDown = true, HeadDrive = true, LowSweep = true }

Remotes.Action.OnServerEvent:Connect(function(player, action, sequence, arg)
	local handler = type(action) == "string" and handlers[action]
	if not handler or not withinBudget(player) then
		return
	end

	local c = player.Character and CombatService.get(player.Character)
	if not c then
		return
	end

	if AUTO_EQUIP[action] and not c.equipped then
		CombatService.setEquipped(c, true, true, true)
	end

	local accepted, anim, speed = handler(c, arg, type(sequence) == "number" and sequence or nil)
	if type(sequence) == "number" then
		local remainingM1Lock = math.max(0, (c.m1ReadyAt or 0) - os.clock())
		Remotes.Ack:FireClient(player, sequence, accepted == true, anim, {
			character = c.model,
			speed = accepted == true and type(speed) == "number" and speed or nil,
			parryM1Token = c.parryM1Token or 0,
			parryM1Consumed = c.parryM1Consumed or 0,
			parryOnly = action == "BlockDown" and accepted == true and c.stunParry == true,
			m1ReadyAt = remainingM1Lock > 0 and workspace:GetServerTimeNow() + remainingM1Lock or 0,
		})
	end
end)


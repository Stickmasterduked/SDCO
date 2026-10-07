--[[
	Test dummies. Each runs the same CombatService as players; the brain only
	decides which inputs to press. Behavior comes from the model's
	"Behavior" attribute:

	  Passive   takes hits, never acts
	  Blocker   holds block at all times (chip, critical, guard break)
	  Parrier   tries to parry about half of your attacks with human timing (feints)
	  Attacker  runs full M1 strings at you with pauses (practice parrying)
	  Mixed     strings, feints, criticals, blocks, parries and rolls
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local CombatService = require(script.Parent.CombatService)

local FLAT = Vector3.new(1, 0, 1)
local AGGRO_RANGE = 22
local STRIKE_RANGE = 4
local REGEN_DELAY = 4
local REGEN_PER_SECOND = 20
local RESPAWN_DELAY = 3

local random = Random.new()
local dummiesFolder = workspace:WaitForChild("CombatTest"):WaitForChild("Dummies")

local brains = {}
local templates = {}

local function flatDistance(a, b)
	return ((a - b) * FLAT).Magnitude
end

local function nearestPlayer(c, range)
	local best, bestDistance
	for _, player in ipairs(Players:GetPlayers()) do
		local other = player.Character and CombatService.get(player.Character)
		if other and other.humanoid.Health > 0 then
			local distance = flatDistance(other.root.Position, c.root.Position)
			if distance <= range and (not bestDistance or distance < bestDistance) then
				best, bestDistance = other, distance
			end
		end
	end
	return best, bestDistance
end

local function isFree(c)
	return c.state == "Idle" and os.clock() >= c.nextActionAt
end

local function waitUntilFree(c, timeout)
	local start = os.clock()
	while not isFree(c) do
		if os.clock() - start > timeout then
			return false
		end
		task.wait()
	end
	return true
end

local function tapParry(c, holdFor)
	if CombatService.blockDown(c, false, false) then
		task.delay(holdFor or 0.12, function()
			CombatService.blockUp(c, false)
		end)
	end
end

-- Schedules a parry press timed against an incoming attack, like a player
-- reacting to the windup. Feints still bait it most of the time.
local function reactWithParry(brain, attacker, hitTime)
	local c = brain.c
	local reaction = random:NextNumber(0.05, 0.13)
	local pressAt = hitTime - reaction
	local attack = attacker.attack
	task.delay(math.max(0, pressAt - os.clock()), function()
		local feinted = attacker.attack ~= attack
		if feinted and random:NextNumber() > 0.75 then
			return
		end
		if c.state == "Idle" or c.state == "Blocking" then
			if c.state == "Blocking" then
				CombatService.blockUp(c, false)
			end
			tapParry(c)
		end
	end)
end

local function reactWithBlock(brain, holdFor)
	local c = brain.c
	if c.state == "Idle" and CombatService.blockDown(c, true, false) then
		task.delay(holdFor, function()
			CombatService.blockUp(c, false)
		end)
	end
end

------------------------------------------------------------------------
-- Behaviors

local behaviors = {}

function behaviors.Passive(brain)
	brain.facesTarget = false
end

function behaviors.Blocker(brain)
	brain.facesTarget = true
	while brain.alive do
		if brain.c.state == "Idle" then
			CombatService.blockDown(brain.c, true, false)
		end
		task.wait(0.1)
	end
end

function behaviors.Parrier(brain)
	brain.facesTarget = true
	brain.onIncoming = function(attacker, _, hitTime)
		if random:NextNumber() < 0.5 then
			reactWithParry(brain, attacker, hitTime)
		end
	end
end

local function approach(brain, target)
	local c = brain.c
	local distance = flatDistance(target.root.Position, c.root.Position)
	if distance > STRIKE_RANGE then
		if c.state == "Idle" then
			c.humanoid:MoveTo(target.root.Position)
		end
		return false
	end
	c.humanoid:MoveTo(c.root.Position)
	return true
end

local function runString(brain, hits, feintChance)
	local c = brain.c
	for _ = 1, hits do
		if not waitUntilFree(c, 1.5) then
			return
		end
		local target = nearestPlayer(c, AGGRO_RANGE)
		if not target or flatDistance(target.root.Position, c.root.Position) > STRIKE_RANGE + 1.5 then
			return
		end
		if not CombatService.m1(c, {}, false) then
			return
		end
		if feintChance and random:NextNumber() < feintChance then
			task.wait(random:NextNumber(0.05, 0.1))
			CombatService.feint(c, false)
		end
	end
	waitUntilFree(c, 1.5)
end

function behaviors.Attacker(brain)
	brain.facesTarget = true
	local c = brain.c
	while brain.alive do
		local target = nearestPlayer(c, AGGRO_RANGE)
		if target and isFree(c) then
			if approach(brain, target) then
				task.wait(0.25)
				runString(brain, 5)
				task.wait(random:NextNumber(1.4, 2))
			end
		elseif not target then
			brain.returnHome()
		end
		task.wait(0.1)
	end
end

function behaviors.Mixed(brain)
	brain.facesTarget = true
	local c = brain.c

	brain.onIncoming = function(attacker, _, hitTime)
		if brain.busy then
			return
		end
		local roll = random:NextNumber()
		if roll < 0.3 then
			reactWithParry(brain, attacker, hitTime)
		elseif roll < 0.5 then
			reactWithBlock(brain, random:NextNumber(0.6, 1))
		end
	end

	while brain.alive do
		local target = nearestPlayer(c, AGGRO_RANGE)
		if target and isFree(c) then
			if approach(brain, target) then
				brain.busy = true
				local choice = random:NextNumber()
				if choice < 0.45 then
					runString(brain, random:NextInteger(1, 4), 0.25)
				elseif choice < 0.65 then
					if CombatService.critical(c, false) and random:NextNumber() < 0.3 then
						task.wait(random:NextNumber(0.2, 0.4))
						CombatService.feint(c, false)
						task.wait(0.1)
						runString(brain, 1)
					end
					waitUntilFree(c, 1.5)
				elseif choice < 0.8 then
					local side = random:NextNumber() < 0.5 and -1 or 1
					local direction = c.root.CFrame.RightVector * side - c.root.CFrame.LookVector * 0.6
					CombatService.roll(c, direction, false)
					waitUntilFree(c, 1)
				else
					brain.busy = false
					reactWithBlock(brain, random:NextNumber(0.8, 1.4))
					task.wait(1.4)
				end
				brain.busy = false
				task.wait(random:NextNumber(0.5, 1.3))
			end
		elseif not target then
			brain.returnHome()
		end
		task.wait(0.1)
	end
end

------------------------------------------------------------------------
-- Setup

local function setupDummy(model)
	local behavior = model:GetAttribute("Behavior")
	if not behaviors[behavior] then
		warn("Dummy has unknown behavior:", model:GetFullName(), behavior)
		return
	end

	local c = CombatService.register(model, nil)
	local home = model:GetPivot()
	c.humanoid.AutoRotate = false
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part:SetNetworkOwner(nil)
		end
	end

	local brain = { c = c, home = home, alive = true, facesTarget = false }
	brains[model] = brain

	function brain.returnHome()
		if c.state == "Idle" and flatDistance(c.root.Position, home.Position) > 1.5 then
			c.humanoid:MoveTo(home.Position)
		end
	end

	-- Dummies die like anything else and come back fresh at their spot.
	c.humanoid.Died:Connect(function()
		brain.alive = false
		brains[model] = nil
		task.wait(RESPAWN_DELAY)
		local template = templates[model.Name]
		model:Destroy()
		if template then
			template:Clone().Parent = dummiesFolder
		end
	end)

	model.AncestryChanged:Connect(function(_, parent)
		if not parent then
			brain.alive = false
			brains[model] = nil
		end
	end)

	task.spawn(behaviors[behavior], brain)
end

CombatService.AttackStarted:Connect(function(attacker, kind, hitTime)
	for _, brain in pairs(brains) do
		local c = brain.c
		if brain.onIncoming and attacker ~= c and c.humanoid.Health > 0 then
			local range = flatDistance(attacker.root.Position, c.root.Position)
			local toMe = ((c.root.Position - attacker.root.Position) * FLAT)
			local aimed = toMe.Magnitude < 0.1
				or (attacker.root.CFrame.LookVector * FLAT).Unit:Dot(toMe.Unit) > 0.5
			if range < 9 and aimed then
				brain.onIncoming(attacker, kind, hitTime)
			end
		end
	end
end)

-- Facing, idle return and health regeneration.
local regenTimer = 0
RunService.Heartbeat:Connect(function(dt)
	regenTimer += dt
	local regenTick = regenTimer >= 0.25
	if regenTick then
		regenTimer = 0
	end

	for _, brain in pairs(brains) do
		local c = brain.c
		local canTurn = c.state == "Idle" or c.state == "Blocking" or c.state == "Attacking"

		if canTurn then
			local target = brain.facesTarget and nearestPlayer(c, AGGRO_RANGE)
			local look
			if target then
				look = (target.root.Position - c.root.Position) * FLAT
			elseif c.humanoid.MoveDirection.Magnitude > 0.1 then
				look = c.humanoid.MoveDirection * FLAT
			elseif flatDistance(c.root.Position, brain.home.Position) < 2 then
				look = brain.home.LookVector * FLAT
			end
			if look and look.Magnitude > 0.05 then
				local position = c.root.Position
				local goal = CFrame.lookAt(position, position + look.Unit)
				local rate = c.state == "Attacking" and 0.12 or 0.25
				c.root.CFrame = c.root.CFrame:Lerp(goal, rate)
			end
		end

		if regenTick then
			if c.humanoid.Health > 0 and os.clock() - c.lastDamaged > REGEN_DELAY then
				c.humanoid.Health = math.min(c.humanoid.MaxHealth, c.humanoid.Health + REGEN_PER_SECOND * 0.25)
			end
			if not brain.facesTarget and c.state == "Idle" and not nearestPlayer(c, 6) then
				brain.returnHome()
			end
		end
	end
end)

for _, model in ipairs(dummiesFolder:GetChildren()) do
	templates[model.Name] = model:Clone()
	setupDummy(model)
end
dummiesFolder.ChildAdded:Connect(setupDummy)

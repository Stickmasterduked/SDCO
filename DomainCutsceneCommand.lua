-- Paste into the Roblox Studio Command Bar and press Enter.
local OWNER_CHECK = ' if player.Name:lower() ~= "merreystantach2" then return end -- owner only'
local src = [=====[-- Domain Expansion client: T activates, no cutscene or overlay.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("DomainCutscene")
local PoseAnimator = require(ReplicatedStorage.Combat.PoseAnimator)
local Effects = require(ReplicatedStorage.Combat.Effects)
local tracks = {}
local OWNER = "merreystantach2" -- only this player can use the domain

local function casterModel(payload)
 local caster = payload.caster
 if typeof(caster) == "Instance" and caster:IsA("Model") and caster.Parent then return caster end
 local owner = type(payload.casterUserId) == "number" and Players:GetPlayerByUserId(payload.casterUserId)
 return owner and owner.Character
end

-- Still play the hand sign so the caster visibly activates the domain.
local function start(payload)
 if type(payload) ~= "table" or type(payload.id) ~= "number" or type(payload.startsAt) ~= "number" then return end
 if tracks[payload.id] then return end
 tracks[payload.id] = true
 task.spawn(function()
  task.wait(math.max(0, payload.startsAt - workspace:GetServerTimeNow()))
  local caster = casterModel(payload)
  if not caster or not caster:FindFirstChild("Right Arm") or not caster:FindFirstChild("Left Arm") then return end
  local ok, track = pcall(function() return PoseAnimator.get(caster):track("DomainSign") end)
  if ok and track and tracks[payload.id] == true then
   tracks[payload.id] = track
   track:Play(0.18)
  end
 end)
end

local function finish(id)
 for key, track in pairs(tracks) do
  if id == nil or key == id then
   if typeof(track) == "table" and track.Stop then track:Stop(0.25) end
   tracks[key] = nil
  end
 end
end

remote.OnClientEvent:Connect(function(action, payload)
 if action == "Start" then start(payload)
 elseif action == "End" then finish(payload)
 elseif action == "ShrineRise" or action == "ShrineSink" then
  if typeof(payload) == "table" then Effects.domainGround(payload.position, payload.radius, action == "ShrineSink") end
 end
end)

UserInputService.InputBegan:Connect(function(input, processed)
 if player.Name:lower() ~= OWNER:lower() then return end
 if processed or input.KeyCode ~= Enum.KeyCode.T or UserInputService:GetFocusedTextBox()
  or player:GetAttribute("InMenu") or player:GetAttribute("DisclaimerOpen") then return end
 local backpack = player:FindFirstChildOfClass("Backpack")
 local character = player.Character
 local tool = backpack and backpack:FindFirstChild("Domain Expansion")
  or character and character:FindFirstChild("Domain Expansion")
 local activate = tool and tool:FindFirstChild("ActivateDomain")
 if activate and activate:IsA("RemoteEvent") then activate:FireServer() end
end)

remote:FireServer("Ready")
]=====]
local client, server = 0, 0
for _, root in ipairs({game.StarterPlayer, game.StarterPack, game.ReplicatedStorage, game.ServerStorage, game.ServerScriptService, workspace, game.StarterGui}) do
 for _, v in ipairs(root:GetDescendants()) do
  if v:IsA("LuaSourceContainer") then
   if v.Name == "DomainCutsceneClient" then
    v.Source = src; client += 1
   else
    -- Server gate: the tool script refuses anyone but the owner.
    local hook = "activateDomain.OnServerEvent:Connect(function(player)"
    local i, j = v.Source:find(hook, 1, true)
    if i and not v.Source:find("owner only", 1, true) then
     v.Source = v.Source:sub(1, j) .. OWNER_CHECK .. v.Source:sub(j + 1); server += 1
    end
   end
  end
 end
end
print("Domain: client scripts updated", client, "| server tool scripts locked to owner", server)

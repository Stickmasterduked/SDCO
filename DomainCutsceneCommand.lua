-- 1) Upload the files in DomainAssets (Asset Manager > Bulk Import), copy each ID into the ASSETS table below (replace the 0s).
-- 2) Paste this whole file into the Roblox Studio Command Bar (View > Command Bar) and press Enter.
local src = [=====[
-- Shared server timestamps keep every viewer on the same domain introduction.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local player = Players.LocalPlayer
local remote = ReplicatedStorage:WaitForChild("DomainCutscene")
local PoseAnimator = require(ReplicatedStorage.Combat.PoseAnimator)
local CameraFX = require(ReplicatedStorage.Combat.CameraFX)
local Effects = require(ReplicatedStorage.Combat.Effects)
local controls
local RENDER_NAME, INPUT_NAME = "DomainCutsceneCamera", "DomainCutsceneInput"
local scene
-- Paste the IDs Roblox gives you after uploading the files in DomainAssets.
local function id(n) return "rbxassetid://" .. n end
local ASSETS = {
 Eye = id(0),        -- SukunaEye.png
 Mouth = id(0),      -- SukunaMouth.png
 Marks = {id(0), id(0), id(0)}, -- SukunaMark1.png, SukunaMark2.png, SukunaMark3.png
 Glow = id(0),       -- RedGlow.png
 Vignette = id(0),   -- SukunaVignette.png
 Crack = id(0),      -- DomainCrack.png
 BlockBreak = id(0), -- BlockBreak.ogg
}
local INTRO_OPEN, INTRO_END = 1.85, 2.35
-- This place may omit the default PlayerModule; input sinking and server locks still work.
task.spawn(function()
 local module = player.PlayerScripts:WaitForChild("PlayerModule", 5)
 if not module then return end
 local ok, value = pcall(function() return require(module):GetControls() end)
 if ok then
  controls = value
  if scene then controls:Disable() end
 end
end)

local function new(class, props, parent)
 local o = Instance.new(class)
 for k, v in pairs(props) do o[k] = v end
 o.Parent = parent
 return o
end
local function ease(value)
 value = math.clamp(value, 0, 1)
 return value * value * (3 - 2 * value)
end
local function backOut(x)
 x = math.clamp(x, 0, 1) - 1
 return 1 + 2.9 * x * x * x + 1.9 * x * x
end

local gui = new("ScreenGui", {Name="DomainCutscene", DisplayOrder=10000, IgnoreGuiInset=true,
 ResetOnSpawn=false, Enabled=false, ZIndexBehavior=Enum.ZIndexBehavior.Sibling}, player:WaitForChild("PlayerGui"))
local function frame(name, anchor, position)
 return new("Frame", {Name=name, AnchorPoint=anchor, Position=position, Size=UDim2.fromScale(1, 0),
  BorderSizePixel=0, BackgroundColor3=Color3.new(0, 0, 0), ZIndex=2}, gui)
end
local top = frame("TopLetterbox", Vector2.zero, UDim2.fromScale(0, 0))
local bottom = frame("BottomLetterbox", Vector2.new(0, 1), UDim2.fromScale(0, 1))
local title = new("TextLabel", {Name="DomainTitle", AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.945),
 Size=UDim2.fromScale(0.9, 0.055), BackgroundTransparency=1, TextColor3=Color3.fromRGB(255, 238, 231),
 Font=Enum.Font.GothamBlack, TextSize=21, TextTransparency=1, Text="DOMAIN EXPANSION", ZIndex=3}, gui)
local flash = new("Frame", {Name="DomainRevealFlash", Size=UDim2.fromScale(1, 1), BorderSizePixel=0,
 BackgroundColor3=Color3.fromRGB(255, 222, 213), BackgroundTransparency=1, ZIndex=0}, gui)

-- Intro: bankai-style title card that splits open onto the cutscene ---------
local intro = new("Frame", {Name="DomainIntro", Size=UDim2.fromScale(1, 1), BackgroundTransparency=1, ZIndex=5, Visible=false}, gui)
local function sky(name, y, c0, c1)
 local f = new("Frame", {Name=name, Size=UDim2.fromScale(1, 0.5), Position=UDim2.fromScale(0, y),
  BorderSizePixel=0, BackgroundColor3=Color3.new(1, 1, 1), ZIndex=1}, intro)
 new("UIGradient", {Rotation=90, Color=ColorSequence.new(c0, c1)}, f)
 return f
end
local skyTop = sky("SkyTop", 0, Color3.fromRGB(105, 165, 228), Color3.fromRGB(238, 246, 255))
local skyBottom = sky("SkyBottom", 0.5, Color3.fromRGB(226, 232, 242), Color3.fromRGB(78, 88, 110))
local rng = Random.new(7)
local streaks = {}
for i = 1, 42 do
 local s = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), BorderSizePixel=0, BackgroundColor3=Color3.new(1, 1, 1),
  Size=UDim2.new(0, rng:NextInteger(2, 6), rng:NextNumber(0.12, 0.42), 0), ZIndex=2}, intro)
 new("UIGradient", {Rotation=90, Transparency=NumberSequence.new({NumberSequenceKeypoint.new(0, 1),
  NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1)})}, s)
 streaks[i] = {frame=s, x=rng:NextNumber(0, 1), offset=rng:NextNumber(0, 1.5), speed=rng:NextNumber(1.6, 3.4), alpha=rng:NextNumber(0.35, 0.9)}
end
local edgeFade = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.25, 0),
 NumberSequenceKeypoint.new(0.75, 0), NumberSequenceKeypoint.new(1, 1)})
local bandGlow = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Rotation=3,
 BorderSizePixel=0, BackgroundColor3=Color3.fromRGB(220, 238, 255), ZIndex=3}, intro)
new("UIGradient", {Transparency=edgeFade}, bandGlow)
local band = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Rotation=3,
 BorderSizePixel=0, BackgroundColor3=Color3.new(1, 1, 1), ZIndex=3}, intro)
new("UIGradient", {Transparency=edgeFade}, band)
local WORD = "DOMAIN EXPANSION"
local letters = {}
for i = 1, #WORD do
 local ch = WORD:sub(i, i)
 if ch ~= " " then
  local u = (i - 1) / (#WORD - 1)
  local l = new("TextLabel", {Text=ch, Font=Enum.Font.GothamBlack, TextScaled=true, AnchorPoint=Vector2.new(0.5, 0.5),
   Size=UDim2.fromScale(0.06, 0.12), BackgroundTransparency=1, TextColor3=Color3.fromRGB(14, 14, 20),
   TextTransparency=1, ZIndex=4}, intro)
  table.insert(letters, {label=l, k=#letters, x=0.07 + u * 0.86, y=0.455 + u * 0.075 + (i % 2 == 0 and 0.018 or -0.018),
   stroke=new("UIStroke", {Color=Color3.new(1, 1, 1), Thickness=2.5}, l), scale=new("UIScale", {}, l)})
 end
end
local crack = new("ImageLabel", {Size=UDim2.fromScale(1, 1), BackgroundTransparency=1, Image=ASSETS.Crack,
 ImageTransparency=1, ScaleType=Enum.ScaleType.Stretch, ZIndex=5}, intro)
local crackScale = new("UIScale", {}, crack)
local breakSound = new("Sound", {Name="DomainBlockBreak", SoundId=ASSETS.BlockBreak, Volume=1.4}, game:GetService("SoundService"))
local function playBreak(speed, volume)
 breakSound.PlaybackSpeed, breakSound.Volume = speed, volume
 game:GetService("SoundService"):PlayLocalSound(breakSound)
end
local introFlash = new("Frame", {Size=UDim2.fromScale(1, 1), BorderSizePixel=0, BackgroundColor3=Color3.new(1, 1, 1),
 BackgroundTransparency=1, ZIndex=6}, intro)

local function updateIntro(t, state)
 if t >= INTRO_END then intro.Visible = false; return end
 -- Block-break hits: once as the title slams in, once as the card cracks open.
 if not state.hitTitle and t >= 0.18 then state.hitTitle = true; if t < 0.6 then playBreak(1, 1.4) end end
 if not state.hitCrack and t >= INTRO_OPEN - 0.18 then state.hitCrack = true; if t < INTRO_OPEN + 0.2 then playBreak(0.82, 1.8) end end
 local cracked = ease((t - (INTRO_OPEN - 0.18)) / 0.08)
 crack.ImageTransparency = 1 - cracked * (1 - ease((t - INTRO_OPEN) / 0.3))
 crackScale.Scale = 1 + 0.15 * ease((t - INTRO_OPEN) / (INTRO_END - INTRO_OPEN))
 intro.Visible = true
 local fadeIn = ease(t / 0.15)
 local open = ease((t - INTRO_OPEN) / (INTRO_END - INTRO_OPEN))
 skyTop.Position = UDim2.fromScale(0, -0.5 * open)
 skyBottom.Position = UDim2.fromScale(0, 0.5 + 0.5 * open)
 skyTop.BackgroundTransparency, skyBottom.BackgroundTransparency = 1 - fadeIn, 1 - fadeIn
 local burst = math.sin(math.pi * open)
 band.Size = UDim2.new(1.4, 0, 0.005 + 0.012 * ease(t / 0.25) + 0.06 * burst, 0)
 bandGlow.Size = UDim2.new(1.4, 0, 0.05 + 0.03 * math.sin(t * 9) + 0.5 * burst, 0)
 band.BackgroundTransparency = 1 - fadeIn * (1 - open * open)
 bandGlow.BackgroundTransparency = 1 - 0.45 * fadeIn * (1 - open)
 for _, s in ipairs(streaks) do
  s.frame.Position = UDim2.fromScale(s.x, (s.offset + t * s.speed) % 1.5 - 0.25)
  s.frame.BackgroundTransparency = 1 - s.alpha * fadeIn * (1 - open)
 end
 for _, l in ipairs(letters) do
  local lt = t - (0.18 + l.k * 0.075)
  local pop = math.clamp(lt / 0.16, 0, 1)
  local jitter = lt > 0.16 and (open > 0 and 0.004 or 0.0015) or 0
  local nx, ny = math.noise(t * 22, l.k) * jitter, math.noise(l.k, t * 22) * jitter
  l.label.Position = UDim2.fromScale(0.5 + (l.x - 0.5) * (1 + 0.4 * open) + nx, l.y + ny)
  l.scale.Scale = (lt < 0 and 2.6 or 1 + 1.6 * (1 - backOut(pop))) * (1 + 0.6 * open)
  l.label.Rotation = (1 - pop) * (l.k % 2 == 0 and -14 or 14)
  local tr = lt < 0 and 1 or math.max(1 - ease(lt / 0.1), open)
  l.label.TextTransparency = tr
  l.stroke.Transparency = 0.15 + 0.85 * tr
 end
 -- Impact flash per letter and a big flash as the card tears open.
 local lastPop = t - (0.18 + #letters * 0.075)
 introFlash.BackgroundTransparency = 1 - math.max(0.65 * burst, 0.5 * math.max(0, 1 - math.abs(lastPop) / 0.12))
end

-- Sukuna face: shown while the camera pushes into the caster's face ----------
local function img(id, props, parent)
 props.Image, props.BackgroundTransparency, props.BorderSizePixel = id, 1, 0
 props.AnchorPoint = props.AnchorPoint or Vector2.new(0.5, 0.5)
 return new("ImageLabel", props, parent)
end
local face = new("CanvasGroup", {Name="SukunaFace", Size=UDim2.fromScale(1, 1), BackgroundColor3=Color3.fromRGB(9, 15, 11),
 BackgroundTransparency=0.04, BorderSizePixel=0, GroupTransparency=1, Visible=false, ZIndex=1}, gui)
local mask = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Size=UDim2.fromScale(1, 1),
 BackgroundTransparency=1, ZIndex=2}, face)
new("UIAspectRatioConstraint", {AspectRatio=16 / 9}, mask)
local maskScale = new("UIScale", {}, mask)
local aura = img(ASSETS.Glow, {Position=UDim2.fromScale(0.5, 0.48), Size=UDim2.fromScale(0.75, 1.3), ZIndex=1}, mask)
local vignette = img(ASSETS.Vignette, {AnchorPoint=Vector2.zero, Size=UDim2.fromScale(1, 1), ZIndex=10,
 ScaleType=Enum.ScaleType.Stretch}, face)
local parts = {}
-- kind: "eye" opens vertically, "mark" slashes in from its root, "mouth" draws out from the center.
local function piece(kind, id, x, y, w, h, rot, delay)
 local holder = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(x, y), Size=UDim2.fromScale(w, h),
  Rotation=rot, BackgroundTransparency=1, ZIndex=kind == "mark" and 2 or 4}, mask)
 local glow = kind == "eye" and img(ASSETS.Glow, {Position=UDim2.fromScale(0.5, 0.5), Size=UDim2.fromScale(2.4, 1.6),
  ImageTransparency=1, ZIndex=3}, holder)
 local sprite = img(id, {AnchorPoint=kind == "mark" and Vector2.new(0.5, 1) or Vector2.new(0.5, 0.5),
  Position=UDim2.fromScale(0.5, kind == "mark" and 1 or 0.5), Size=UDim2.fromScale(1, 0), ZIndex=5}, holder)
 table.insert(parts, {kind=kind, holder=holder, sprite=sprite, glow=glow, delay=delay, rot=rot})
end
piece("eye", ASSETS.Eye, 0.415, 0.24, 0.1, 0.37, -28, 0.32)
piece("eye", ASSETS.Eye, 0.585, 0.24, 0.1, 0.37, 28, 0.4)
piece("eye", ASSETS.Eye, 0.43, 0.56, 0.085, 0.31, -24, 0.14)
piece("eye", ASSETS.Eye, 0.57, 0.56, 0.085, 0.31, 24, 0.22)
piece("mouth", ASSETS.Mouth, 0.5, 0.79, 0.27, 0.2, 0, 0.58)
local frng = Random.new(13)
for i = 1, 12 do
 local side = i % 2 == 0 and 1 or -1
 local x = 0.5 + side * frng:NextNumber(0.13, 0.42)
 piece("mark", ASSETS.Marks[i % 3 + 1], x, frng:NextNumber(0.15, 0.95), frng:NextNumber(0.035, 0.06), frng:NextNumber(0.25, 0.45),
  side * frng:NextNumber(25, 65), 0.04 + frng:NextNumber(0, 0.55))
end

local function updateFace(now, payload)
 local faceStart = math.max(payload.startsAt + INTRO_END + 0.3, payload.revealAt - 1.6)
 local a, dur = now - faceStart, payload.revealAt - faceStart
 if a < 0 or dur <= 0 or now >= payload.revealAt then face.Visible = false; return end
 face.Visible = true
 local out = ease((a - (dur - 0.16)) / 0.16)
 face.GroupTransparency = math.max(1 - ease(a / 0.2), out)
 maskScale.Scale = 0.95 + 0.08 * (a / dur) + 0.7 * out
 local shake = 0.003 + 0.002 * math.max(0, 1 - a / 0.25) * 4 + 0.012 * out
 mask.Position = UDim2.fromScale(0.5 + math.noise(now * 18, 1) * shake, 0.5 + math.noise(2, now * 18) * shake)
 aura.ImageTransparency = 0.55 + 0.15 * math.sin(now * 7)
 vignette.ImageTransparency = 0.1 * math.sin(now * 3)
 for i, p in ipairs(parts) do
  local lt = a - p.delay
  local pulse = math.sin(now * 11 + i)
  if p.kind == "eye" then
   local open = lt <= 0 and 0 or backOut(lt / 0.18)
   p.sprite.Size = UDim2.fromScale(1 + 0.25 * (1 - math.min(open, 1)), open * (1 + 0.025 * pulse))
   local flicker = lt < 0.3 and math.noise(now * 45, i) > 0.2
   p.sprite.ImageTransparency = flicker and 0.6 or 0
   -- Bright bloom when the eye snaps open, then a steady breathing glow.
   p.glow.ImageTransparency = lt <= 0 and 1 or math.clamp(0.45 - 0.3 * math.max(0, 1 - lt / 0.25) + 0.12 * pulse, 0, 1)
  elseif p.kind == "mouth" then
   local draw = lt <= 0 and 0 or ease(lt / 0.2)
   p.sprite.Size = UDim2.fromScale(draw * (1 + 0.03 * pulse), 1)
   p.sprite.ImageTransparency = 0.1 * math.max(0, pulse)
  else
   local slash = lt <= 0 and 0 or ease(lt / 0.12)
   p.sprite.Size = UDim2.fromScale(1, slash)
   p.sprite.ImageTransparency = math.noise(now * 9, i * 3.1) > 0.4 and 0.6 or 0.05
   p.holder.Rotation = p.rot + math.noise(now * 3, i) * 6
  end
 end
end

local function hideGui(state, other)
 if other:IsA("ScreenGui") and other ~= gui and state.guis[other] == nil then
  state.guis[other] = other.Enabled
  other.Enabled = false
 end
end
player.PlayerGui.ChildAdded:Connect(function(other)
 if scene then hideGui(scene, other) end
end)
local function lockInput()
 ContextActionService:BindActionAtPriority(INPUT_NAME, function()
  return Enum.ContextActionResult.Sink
 end, false, Enum.ContextActionPriority.High.Value + 1000,
  Enum.PlayerActions.CharacterForward, Enum.PlayerActions.CharacterBackward,
  Enum.PlayerActions.CharacterLeft, Enum.PlayerActions.CharacterRight,
  Enum.PlayerActions.CharacterJump, Enum.KeyCode.Space, Enum.KeyCode.LeftShift,
  Enum.KeyCode.R, Enum.KeyCode.F, Enum.KeyCode.H, Enum.KeyCode.Y, Enum.KeyCode.Q,
  Enum.KeyCode.E, Enum.KeyCode.T, Enum.KeyCode.Z, Enum.KeyCode.X,
  Enum.UserInputType.MouseButton1, Enum.UserInputType.MouseButton2)
 if controls then controls:Disable() end
end

local function finish(id)
 local state = scene
 if not state or id and state.id ~= id then return end
 scene = nil
 RunService:UnbindFromRenderStep(RENDER_NAME)
 ContextActionService:UnbindAction(INPUT_NAME)
 player:SetAttribute("InCutscene", false)
 if state.track then state.track:Stop(0.25) end
 for _, effect in ipairs(state.effects) do effect:Destroy() end
 for billboard, enabled in pairs(state.billboards) do
  if billboard.Parent then billboard.Enabled = enabled end
 end
 for other, enabled in pairs(state.guis) do
  if other.Parent then other.Enabled = enabled end
 end
 local camera = workspace.CurrentCamera
 if camera then
  camera.FieldOfView = state.fov
  camera.CFrame = state.cameraFrame
  camera.Focus = state.focus
  local character = player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  if player:GetAttribute("InMenu") then
   camera.CameraType = state.cameraType
   if state.subject and state.subject.Parent then camera.CameraSubject = state.subject end
  else
   camera.CameraType = Enum.CameraType.Custom
   if humanoid then camera.CameraSubject = humanoid end
  end
 end
 UserInputService.MouseBehavior = state.mouseBehavior
 UserInputService.MouseIconEnabled = state.mouseIcon
 if controls and not player:GetAttribute("InMenu") and not player:GetAttribute("DisclaimerOpen") then controls:Enable() end
 for _, bar in ipairs({top, bottom}) do
  TweenService:Create(bar, TweenInfo.new(0.25, Enum.EasingStyle.Quad), {Size=UDim2.fromScale(1, 0)}):Play()
 end
 TweenService:Create(title, TweenInfo.new(0.2), {TextTransparency=1}):Play()
 flash.BackgroundTransparency = 1
 intro.Visible, face.Visible = false, false
 task.delay(0.28, function() if not scene then gui.Enabled = false end end)
end

local function casterModel(payload)
 local caster = payload.caster
 if typeof(caster) == "Instance" and caster:IsA("Model") and caster.Parent then return caster end
 local owner = type(payload.casterUserId) == "number" and Players:GetPlayerByUserId(payload.casterUserId)
 if owner and owner.Character and owner.Character.Parent then
  payload.caster = owner.Character
  return payload.caster
 end
 return nil
end

local function start(payload)
 if type(payload) ~= "table" or type(payload.id) ~= "number"
  or typeof(payload.origin) ~= "CFrame"
  or type(payload.startsAt) ~= "number" or type(payload.revealAt) ~= "number"
  or type(payload.endsAt) ~= "number" or workspace:GetServerTimeNow() >= payload.endsAt then return end
 if scene and scene.id == payload.id then return end
 if scene then finish(scene.id) end
 local camera = workspace.CurrentCamera
 if not camera then return end
 local state = {
  id=payload.id, caster=payload.caster, payload=payload, cameraType=camera.CameraType,
  subject=camera.CameraSubject, cameraFrame=camera.CFrame, focus=camera.Focus,
  fov=camera.FieldOfView, mouseBehavior=UserInputService.MouseBehavior,
  mouseIcon=UserInputService.MouseIconEnabled, guis={}, billboards={}, effects={},
 }
 scene = state
 player:SetAttribute("InCutscene", true)
 lockInput()
 for _, other in ipairs(player.PlayerGui:GetChildren()) do hideGui(state, other) end
 gui.Enabled = true
 if workspace.StreamingEnabled then
  task.spawn(function() pcall(function() player:RequestStreamAroundAsync(payload.origin.Position, 2) end) end)
 end
 camera.CameraType = Enum.CameraType.Scriptable
 UserInputService.MouseBehavior = Enum.MouseBehavior.Default
 UserInputService.MouseIconEnabled = false
 title.Text = "DOMAIN EXPANSION"
 title.TextTransparency = 1
 for _, bar in ipairs({top, bottom}) do
  bar.Size=UDim2.fromScale(1, 0)
  TweenService:Create(bar, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {Size=UDim2.fromScale(1, 0.13)}):Play()
 end
 local grade = Instance.new("ColorCorrectionEffect")
 grade.Name = "DomainCinematicGrade"
 grade.Contrast, grade.Saturation = 0.18, -0.12
 grade.TintColor = Color3.fromRGB(255, 230, 224)
 grade.Parent = Lighting
 table.insert(state.effects, grade)
 local depth = Instance.new("DepthOfFieldEffect")
 depth.Name = "DomainCinematicDepth"
 depth.InFocusRadius, depth.FarIntensity, depth.NearIntensity = 3.5, 0.22, 0.03
 depth.Parent = Lighting
 table.insert(state.effects, depth)
 task.spawn(function()
  while scene == state and workspace:GetServerTimeNow() < payload.endsAt do
   local caster = casterModel(payload)
   if caster and caster:FindFirstChild("HumanoidRootPart") and caster:FindFirstChild("Right Arm") and caster:FindFirstChild("Left Arm") then
    state.caster = caster
    for _, item in ipairs(caster:GetDescendants()) do
     if item:IsA("BillboardGui") then state.billboards[item]=item.Enabled; item.Enabled=false end
    end
    task.wait(math.max(0, payload.startsAt-workspace:GetServerTimeNow()))
    if scene ~= state then return end
    state.track = PoseAnimator.get(caster):track("DomainSign")
    state.track:Play(0.18)
    state.track.time = math.max(0, workspace:GetServerTimeNow()-payload.startsAt)
    return
   end
   task.wait(0.05)
  end
 end)
 local rayParams = RaycastParams.new()
 rayParams.FilterType = Enum.RaycastFilterType.Exclude
 rayParams.RespectCanCollide = true
 RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Last.Value + 10, function()
  if scene ~= state then return end
  local now = workspace:GetServerTimeNow()
  if now >= payload.endsAt then finish(state.id); return end
  local origin = payload.origin
  local caster = casterModel(payload)
  local root = caster and caster:FindFirstChild("HumanoidRootPart")
  if root then origin = root.CFrame end
  local t = math.max(0, now-payload.startsAt)
  updateIntro(t, state)
  updateFace(now, payload)
  local approach = ease(t / 4.75)
  local reveal = ease((now-payload.revealAt) / (payload.endsAt-payload.revealAt))
  local distance = 13.5 + (3.9-13.5)*approach
  local lateral = 4.0 + (0.35-4.0)*approach
  local height = 2.6 + (1.75-2.6)*approach
  distance = distance + 8.5*reveal
  lateral = lateral-2.5*reveal
  height = height+1.0*reveal
  local focus = origin:PointToWorldSpace(Vector3.new(0, 0.95+0.2*approach, -0.15))
  local position = origin:PointToWorldSpace(Vector3.new(lateral, height, -distance))
  local exclude = caster and {caster} or {}
  for _, viewer in ipairs(Players:GetPlayers()) do
   if viewer.Character then table.insert(exclude, viewer.Character) end
  end
  rayParams.FilterDescendantsInstances = exclude
  local direction = position-focus
  local obstruction = workspace:Raycast(focus, direction, rayParams)
  if obstruction and obstruction.Distance > 2 then position = obstruction.Position-direction.Unit*0.45 end
  local target = CFrame.lookAt(position, focus)
  camera = workspace.CurrentCamera
  if not camera then return end
  camera.CameraType = Enum.CameraType.Scriptable
  camera.CFrame = state.cameraFrame:Lerp(target, ease(t/0.4)) * CameraFX.domainShakeOffset(now)
  camera.Focus = CFrame.new(focus)
  camera.FieldOfView = 56-16*approach+22*reveal
  depth.FocusDistance = (position-focus).Magnitude
  if now >= payload.revealAt then
   title.Text = "MALEVOLENT SHRINE"
   title.TextTransparency = 0.1
   local age=now-payload.revealAt
   flash.BackgroundColor3 = Color3.fromRGB(255, 60 + 160 * math.min(1, age / 0.3), 50 + 160 * math.min(1, age / 0.3))
   flash.BackgroundTransparency = 1-0.6*math.max(0, 1-age/0.35)
   grade.Contrast = 0.18+0.16*(1-reveal)
  else
   title.TextTransparency = 1 - 0.9 * ease((t - INTRO_END) / 0.4)
  end
 end)
 task.delay(math.max(0, payload.endsAt-workspace:GetServerTimeNow())+0.1, function()
  finish(state.id)
 end)
end

remote.OnClientEvent:Connect(function(action, payload)
 if action == "Start" then start(payload)
 elseif action == "End" then finish(payload)
 elseif action == "ShrineRise" or action == "ShrineSink" then
  if typeof(payload) == "table" then Effects.domainGround(payload.position, payload.radius, action == "ShrineSink") end
 end
end)
-- Bind T outside the imported tool sandbox; it works even while the tool is in the backpack.
UserInputService.InputBegan:Connect(function(input, processed)
 if processed or input.KeyCode ~= Enum.KeyCode.T or UserInputService:GetFocusedTextBox()
  or player:GetAttribute("InMenu") or player:GetAttribute("DisclaimerOpen")
  or player:GetAttribute("InCutscene") then return end
 local backpack = player:FindFirstChildOfClass("Backpack")
 local character = player.Character
 local tool = backpack and backpack:FindFirstChild("Domain Expansion")
  or character and character:FindFirstChild("Domain Expansion")
 local activate = tool and tool:FindFirstChild("ActivateDomain")
 if activate and activate:IsA("RemoteEvent") then activate:FireServer() end
end)

-- Connect first so players joining an ongoing scene cannot miss its replay.
remote:FireServer("Ready")
script.Destroying:Once(function() finish(); gui:Destroy() end)
]=====]
local n = 0
for _, root in ipairs({game:GetService("StarterPlayer"), game:GetService("ReplicatedStorage"), game:GetService("StarterGui"), game:GetService("ServerScriptService")}) do
 for _, v in ipairs(root:GetDescendants()) do
  if v.Name == "DomainCutsceneClient" and v:IsA("LuaSourceContainer") then v.Source = src; n += 1 end
 end
end
print("DomainCutsceneClient updated:", n)

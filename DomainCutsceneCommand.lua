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
 -- SukunaFire01.png ... SukunaFire16.png, in order (the burning face loop).
 Fire = {id(0), id(0), id(0), id(0), id(0), id(0), id(0), id(0),
  id(0), id(0), id(0), id(0), id(0), id(0), id(0), id(0)},
 EyesLower = id(0),  -- SukunaEyesLower.png
 EyesUpper = id(0),  -- SukunaEyesUpper.png
 Mouth = id(0),      -- SukunaMouth.png
 Glow = id(0),       -- SukunaGlow.png
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
-- Everything that shakes/punches on impact lives in one layer.
local shakeLayer = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Size=UDim2.fromScale(1, 1),
 BackgroundTransparency=1, ZIndex=3}, intro)
local shakeScale = new("UIScale", {}, shakeLayer)
local impactFrame = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Size=UDim2.fromScale(1.3, 1.3),
 BorderSizePixel=0, BackgroundColor3=Color3.new(0, 0, 0), Visible=false, ZIndex=2}, shakeLayer)
local bandGlow = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Rotation=3,
 BorderSizePixel=0, BackgroundColor3=Color3.fromRGB(220, 238, 255), ZIndex=3}, shakeLayer)
new("UIGradient", {Transparency=edgeFade}, bandGlow)
local band = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Rotation=3,
 BorderSizePixel=0, BackgroundColor3=Color3.new(1, 1, 1), ZIndex=3}, shakeLayer)
new("UIGradient", {Transparency=edgeFade}, band)

-- Letters slam in word by word; every landing is a hit that shakes the card.
local WORD = "DOMAIN EXPANSION"
local WORD_START, STEP, SLAM = {0.1, 0.52}, 0.04, 0.06
local letters, hits = {}, {}
local word, kw = 1, 0
for i = 1, #WORD do
 local ch = WORD:sub(i, i)
 if ch == " " then
  word, kw = 2, 0
 else
  local u = (i - 1) / (#WORD - 1)
  local function label(color, z)
   return new("TextLabel", {Text=ch, Font=Enum.Font.GothamBlack, TextScaled=true, AnchorPoint=Vector2.new(0.5, 0.5),
    Size=UDim2.fromScale(0.065, 0.13), BackgroundTransparency=1, TextColor3=color, TextTransparency=1, ZIndex=z}, shakeLayer)
  end
  local main = label(Color3.fromRGB(12, 12, 18), 5)
  local start = WORD_START[word] + kw * STEP
  table.insert(letters, {label=main, start=start, k=#letters, x=0.07 + u * 0.86,
   y=0.455 + u * 0.075 + (i % 2 == 0 and 0.018 or -0.018), spin=(i % 2 == 0 and -18 or 18),
   stroke=new("UIStroke", {Color=Color3.new(1, 1, 1), Thickness=3}, main), scale=new("UIScale", {}, main),
   red=label(Color3.fromRGB(255, 30, 60), 4), cyan=label(Color3.fromRGB(30, 230, 255), 4)})
  table.insert(hits, {time=start + SLAM, amp=0.008})
  kw += 1
 end
end
-- Word landings and the final crack hit far harder than single letters.
local WORD_HITS = {WORD_START[1] + 5 * STEP + SLAM, WORD_START[2] + 8 * STEP + SLAM}
local CRACK_AT = INTRO_OPEN - 0.18
table.insert(hits, {time=WORD_HITS[1], amp=0.035, sound=1.05, impact=true})
table.insert(hits, {time=WORD_HITS[2], amp=0.05, sound=0.95, impact=true})
table.insert(hits, {time=CRACK_AT, amp=0.07, sound=0.78, impact=true})

local crack = new("ImageLabel", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Size=UDim2.fromScale(1, 1),
 BackgroundTransparency=1, Image=ASSETS.Crack, ImageTransparency=1, ScaleType=Enum.ScaleType.Stretch, ZIndex=6}, shakeLayer)
local crackScale = new("UIScale", {}, crack)
local breakSound = new("Sound", {Name="DomainBlockBreak", SoundId=ASSETS.BlockBreak, Volume=1.6}, game:GetService("SoundService"))
local introFlash = new("Frame", {Size=UDim2.fromScale(1, 1), BorderSizePixel=0, BackgroundColor3=Color3.new(1, 1, 1),
 BackgroundTransparency=1, ZIndex=10}, intro)

local function updateIntro(t, state)
 if t >= INTRO_END then intro.Visible = false; return end
 intro.Visible = true
 state.hitsPlayed = state.hitsPlayed or {}
 local amp, impact, flashAmount = 0, false, 0
 for i, h in ipairs(hits) do
  local age = t - h.time
  if age >= 0 then
   amp += h.amp * math.exp(-age * 13)
   if h.sound and not state.hitsPlayed[i] then
    state.hitsPlayed[i] = true
    if age < 0.25 then
     breakSound.PlaybackSpeed = h.sound
     game:GetService("SoundService"):PlayLocalSound(breakSound)
    end
   end
   -- Two-frame inverted impact frame, then a white pop.
   if h.impact then
    if age < 0.07 then impact = true end
    flashAmount = math.max(flashAmount, 0.7 * math.max(0, 1 - (age - 0.07) / 0.18) * (age >= 0.07 and 1 or 0))
   end
  end
 end
 local open = ease((t - INTRO_OPEN) / (INTRO_END - INTRO_OPEN))
 local burst = math.sin(math.pi * open)
 -- Sky smashes on instantly (no fade), then splits apart.
 local sx, sy = math.noise(t * 30, 5) * amp, math.noise(7, t * 30) * amp
 skyTop.Position = UDim2.fromScale(sx, -0.5 * open + sy)
 skyBottom.Position = UDim2.fromScale(sx, 0.5 + 0.5 * open + sy)
 skyTop.BackgroundTransparency, skyBottom.BackgroundTransparency = 0, 0
 shakeLayer.Position = UDim2.fromScale(0.5 + math.noise(t * 34, 1) * amp * 1.3, 0.5 + math.noise(3, t * 34) * amp * 1.3)
 shakeLayer.Rotation = math.noise(t * 20, 9) * amp * 60
 shakeScale.Scale = 1 + amp * 2.2 + 0.05 * ease((t - WORD_HITS[2]) / 0.9)
 impactFrame.Visible = impact
 band.Size = UDim2.new(1.4, 0, 0.008 + amp * 0.5 + 0.06 * burst, 0)
 bandGlow.Size = UDim2.new(1.4, 0, 0.06 + amp * 3 + 0.03 * math.sin(t * 9) + 0.5 * burst, 0)
 band.BackgroundTransparency = open * open
 bandGlow.BackgroundTransparency = 1 - 0.5 * (1 - open)
 for _, s in ipairs(streaks) do
  s.frame.Position = UDim2.fromScale(s.x, (s.offset + t * s.speed * (1 + amp * 25)) % 1.5 - 0.25)
  s.frame.BackgroundTransparency = 1 - s.alpha * (1 - open)
 end
 for _, l in ipairs(letters) do
  local lt = t - l.start
  local slam = math.clamp(lt / SLAM, 0, 1)
  local landed = lt - SLAM
  -- Accelerating fall into the card, hard stop, then a tiny recoil wobble.
  local scale = lt < 0 and 0 or (slam < 1 and 4.2 - 3.2 * slam * slam or 1 + 0.12 * math.exp(-landed * 22) * math.cos(landed * 60))
  scale *= 1 + 0.6 * open
  local jitter = landed > 0 and 0.0015 + amp * 0.15 or 0
  local px = 0.5 + (l.x - 0.5) * (1 + 0.45 * open) + math.noise(t * 25, l.k) * jitter
  local py = l.y + math.noise(l.k, t * 25) * jitter
  local tr = lt < 0 and 1 or math.max(0.6 * (1 - slam), open)
  l.label.Position = UDim2.fromScale(px, py)
  l.label.Rotation = (1 - slam) * l.spin
  l.scale.Scale = scale
  l.label.TextTransparency = tr
  l.label.TextColor3 = impact and Color3.new(1, 1, 1) or Color3.fromRGB(12, 12, 18)
  l.stroke.Color = impact and Color3.new(0, 0, 0) or Color3.new(1, 1, 1)
  l.stroke.Transparency = 0.1 + 0.9 * tr
  -- Chromatic split that kicks out on every hit.
  local split = amp * 0.35 + (1 - slam) * 0.01
  for side, ghost in ipairs({l.red, l.cyan}) do
   local dir = side == 1 and -1 or 1
   ghost.Position = UDim2.fromScale(px + dir * split, py)
   ghost.Rotation = l.label.Rotation
   ghost.Size = UDim2.fromScale(0.065 * scale, 0.13 * scale)
   ghost.TextTransparency = (lt < 0 or split < 0.002) and 1 or math.max(0.35, tr)
  end
 end
 local cracked = ease((t - CRACK_AT) / 0.05)
 crack.ImageTransparency = 1 - cracked * (1 - ease((t - INTRO_OPEN) / 0.3))
 crackScale.Scale = 1 + 0.2 * open
 introFlash.BackgroundColor3 = Color3.new(1, 1, 1)
 introFlash.BackgroundTransparency = 1 - math.max(flashAmount, 0.75 * burst, t < 0.06 and 0.9 or 0)
end

-- Sukuna face: the reference frame, cut into layers so each feature animates in --
local face = new("CanvasGroup", {Name="SukunaFace", Size=UDim2.fromScale(1, 1), BackgroundColor3=Color3.fromRGB(8, 14, 10),
 BorderSizePixel=0, GroupTransparency=1, Visible=false, ZIndex=1}, gui)
local faceRoot = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Position=UDim2.fromScale(0.5, 0.5), Size=UDim2.fromScale(1.04, 1.04),
 BackgroundTransparency=1, ZIndex=1}, face)
new("UIAspectRatioConstraint", {AspectRatio=16 / 9, AspectType=Enum.AspectType.ScaleWithParentSize,
 DominantAxis=Enum.DominantAxis.Width}, faceRoot)
local faceScale = new("UIScale", {}, faceRoot)
local function layer(image, z, cx, cy)
 return new("ImageLabel", {Image=image, AnchorPoint=Vector2.new(cx, cy), Position=UDim2.fromScale(cx, cy),
  Size=UDim2.fromScale(1, 1), BackgroundTransparency=1, ScaleType=Enum.ScaleType.Stretch, ImageTransparency=1, ZIndex=z}, faceRoot)
end
local faceBase = layer(ASSETS.Fire[1], 1, 0.5, 0.5)
local faceGlow = layer(ASSETS.Glow, 2, 0.5, 0.5)
-- Centers are measured from the reference image so each feature pops in place.
local IGNITE = 0.3
local features = {
 {img=layer(ASSETS.EyesLower, 3, 0.474, 0.449)},
 {img=layer(ASSETS.EyesUpper, 3, 0.489, 0.212)},
 {img=layer(ASSETS.Mouth, 3, 0.495, 0.747), grin=true},
}
-- Embers drifting up through the flames.
local embers = {}
local erng = Random.new(31)
for i = 1, 46 do
 local size = erng:NextInteger(3, 9)
 local e = new("Frame", {AnchorPoint=Vector2.new(0.5, 0.5), Size=UDim2.fromOffset(size, size), BorderSizePixel=0,
  BackgroundColor3=Color3.fromRGB(255, erng:NextInteger(70, 190), erng:NextInteger(20, 60)), ZIndex=4}, faceRoot)
 new("UICorner", {CornerRadius=UDim.new(1, 0)}, e)
 embers[i] = {frame=e, x=erng:NextNumber(0, 1), offset=erng:NextNumber(0, 1), speed=erng:NextNumber(0.35, 0.9),
  sway=erng:NextNumber(0.01, 0.04), phase=erng:NextNumber(0, 6.28)}
end
-- Load every flipbook frame up front so the fire never blinks on its first loop.
task.spawn(function()
 local list = {}
 for _, image in ipairs(ASSETS.Fire) do table.insert(list, image) end
 for _, image in ipairs({ASSETS.EyesLower, ASSETS.EyesUpper, ASSETS.Mouth, ASSETS.Glow, ASSETS.Crack}) do table.insert(list, image) end
 pcall(function() game:GetService("ContentProvider"):PreloadAsync(list) end)
end)
local redPulse = new("Frame", {Size=UDim2.fromScale(1, 1), BorderSizePixel=0, BackgroundColor3=Color3.fromRGB(255, 0, 20),
 BackgroundTransparency=1, ZIndex=4}, face)

local function updateFace(now, payload)
 local faceStart = math.max(payload.startsAt + INTRO_END + 0.3, payload.revealAt - 1.7)
 local a, dur = now - faceStart, payload.revealAt - faceStart
 if a < 0 or dur <= 0 or now >= payload.revealAt then face.Visible = false; return end
 face.Visible = true
 local out = ease((a - (dur - 0.18)) / 0.18)
 face.GroupTransparency = math.max(a < 0.03 and 0.5 or 0, out)
 faceBase.Image = ASSETS.Fire[math.floor(a * 16) % #ASSETS.Fire + 1]
 -- Everything ignites together on one big hit.
 local lt = a - IGNITE
 local on = math.clamp(lt / 0.08, 0, 1)
 local lit = on * #features
 local amp = 0.03 * math.exp(-a * 9) + 0.012 * out + 0.003 + (lt >= 0 and 0.06 * math.exp(-lt * 11) or 0)
 local flicker = lt >= 0 and lt < 0.2 and math.noise(now * 50, 3) > 0.2
 local pop = lt < 0 and 1.45 or 1 + 0.45 * (1 - on) ^ 2 + 0.07 * math.exp(-math.max(0, lt - 0.08) * 16) * math.cos(lt * 50)
 for _, f in ipairs(features) do
  f.img.ImageTransparency = lt < 0 and 1 or (flicker and 0.6 or 0)
  f.img.Size = f.grin and UDim2.fromScale(0.35 + 0.65 * on + (pop - 1) * 0.3, pop) or UDim2.fromScale(pop, pop)
 end
 for _, e in ipairs(embers) do
  local y = 1.05 - ((e.offset + a * e.speed) % 1.1)
  e.frame.Position = UDim2.fromScale(e.x + math.sin(a * 3 + e.phase) * e.sway, y)
  e.frame.BackgroundTransparency = 0.1 + 0.9 * math.clamp((0.35 - y) / 0.35, 0, 1) + 0.3 * math.max(0, math.noise(now * 8, e.phase))
 end
 -- Ignition flash.
 local igniteFlash = lt >= 0 and math.exp(-lt * 9) or 0
 -- Heartbeat: double thump about once a second.
 local beat = math.max(math.exp(-((a % 0.9) * 14)), 0.6 * math.exp(-(((a - 0.18) % 0.9) * 14)))
 faceBase.ImageTransparency = 0
 faceGlow.ImageTransparency = 1 - (lit / #features) * (0.55 + 0.45 * beat)
 redPulse.BackgroundTransparency = 1 - math.min(1, 0.08 * beat * lit / #features + 0.35 * out + 0.45 * igniteFlash)
 faceScale.Scale = 1.28 - 0.28 * (1 - (1 - math.min(a / 0.2, 1)) ^ 3) + 0.06 * (a / dur) + 0.025 * beat + 0.8 * out
 faceRoot.Position = UDim2.fromScale(0.5 + math.noise(now * 30, 1) * amp, 0.5 + math.noise(2, now * 30) * amp)
 faceRoot.Rotation = math.noise(now * 18, 4) * amp * 40
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

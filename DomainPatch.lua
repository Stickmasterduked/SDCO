local function rep(src, a, b)
 local i, j = src:find(a, 1, true)
 if not i then warn("Domain patch: line not found -> " .. a:sub(1, 60)) return src end
 return src:sub(1, i - 1) .. b .. src:sub(j + 1)
end
local NEW_FACE = [==[
local function updateFace(now, payload)
 local faceStart = payload.startsAt + INTRO_OPEN
 local a, dur = now - faceStart, payload.revealAt - faceStart
 if a < 0 or dur <= 0 or now >= payload.revealAt then face.Visible = false; return end
 face.Visible = true
 -- Smooth fade in from nothing and a smooth fade out into the reveal; no hard cuts.
 local fadeIn = ease(a / 0.8)
 local out = ease((a - (dur - 0.6)) / 0.6)
 face.GroupTransparency = 1 - fadeIn * (1 - out)
 faceBase.ImageTransparency = 0
 faceBase.Image = ASSETS.Fire[math.floor(a * 16) % #ASSETS.Fire + 1]
 -- Eyes and mouth glow up together.
 local on = ease((a - IGNITE) / 0.45)
 local lit = on * #features
 local grow = 1 + 0.12 * (1 - on)
 for _, f in ipairs(features) do
  f.img.ImageTransparency = 1 - on
  f.img.Size = f.grin and UDim2.fromScale(0.6 + 0.4 * on, grow) or UDim2.fromScale(grow, grow)
 end
 for _, e in ipairs(embers) do
  local y = 1.05 - ((e.offset + a * e.speed) % 1.1)
  e.frame.Position = UDim2.fromScale(e.x + math.sin(a * 3 + e.phase) * e.sway, y)
  e.frame.BackgroundTransparency = 0.1 + 0.9 * math.clamp((0.35 - y) / 0.35, 0, 1) + 0.3 * math.max(0, math.noise(now * 8, e.phase))
 end
 -- Heartbeat: double thump about once a second.
 local beat = math.max(math.exp(-((a % 0.9) * 14)), 0.6 * math.exp(-(((a - 0.18) % 0.9) * 14)))
 faceGlow.ImageTransparency = 1 - (lit / #features) * (0.55 + 0.45 * beat)
 redPulse.BackgroundTransparency = 1 - 0.08 * beat * lit / #features
 faceScale.Scale = 1.12 - 0.12 * ease(a / 1.2) + 0.04 * (a / dur) + 0.015 * beat * lit / #features
 local amp = 0.002 + 0.003 * on
 faceRoot.Position = UDim2.fromScale(0.5 + math.noise(now * 20, 1) * amp, 0.5 + math.noise(2, now * 20) * amp)
 faceRoot.Rotation = math.noise(now * 12, 4) * amp * 20
end

]==]
for _, root in ipairs({game.StarterPlayer, game.ReplicatedStorage, game.StarterGui, game.ServerScriptService}) do
 for _, v in ipairs(root:GetDescendants()) do
  if v.Name == "DomainCutsceneClient" and v:IsA("LuaSourceContainer") then
   local s = v.Source
   -- Camera stays exactly where the player had it: no fly-in to the face.
   s = rep(s, "  camera.CFrame = state.cameraFrame:Lerp(target, ease(t/0.4)) * CameraFX.domainShakeOffset(now)", "  camera.CFrame = state.cameraFrame")
   s = rep(s, "  camera.Focus = CFrame.new(focus)", "  camera.Focus = state.focus")
   s = rep(s, "  camera.FieldOfView = 56-16*approach+22*reveal", "  camera.FieldOfView = state.fov")
   s = rep(s, "depth.InFocusRadius, depth.FarIntensity, depth.NearIntensity = 3.5, 0.22, 0.03", "depth.InFocusRadius, depth.FarIntensity, depth.NearIntensity = 0, 0, 0")
   -- Replace the face animation with a smooth fade version.
   local i = s:find("local function updateFace(now, payload)", 1, true)
   local j = s:find("local function hideGui", 1, true)
   if i and j then s = s:sub(1, i - 1) .. NEW_FACE .. s:sub(j) else warn("Domain patch: updateFace not found") end
   v.Source = s
   print("Domain patch applied to", v:GetFullName())
  end
 end
end

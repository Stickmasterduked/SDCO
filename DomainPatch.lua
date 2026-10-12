local function rep(src, a, b)
 local i, j = src:find(a, 1, true)
 if not i then warn("Domain patch: line not found -> " .. a:sub(1, 60)) return src end
 return src:sub(1, i - 1) .. b .. src:sub(j + 1)
end
for _, root in ipairs({game.StarterPlayer, game.ReplicatedStorage, game.StarterGui, game.ServerScriptService}) do
 for _, v in ipairs(root:GetDescendants()) do
  if v.Name == "DomainCutsceneClient" and v:IsA("LuaSourceContainer") then
   local s = v.Source
   s = rep(s, "local function updateIntro(t, state)", "local function updateIntro(t, state)\n if true then intro.Visible = false; return end -- title card removed")
   s = rep(s, "local faceStart = payload.startsAt + INTRO_OPEN", "local faceStart = payload.startsAt")
   s = rep(s, "local fadeIn = ease(a / 0.8)", "local fadeIn = ease(a / 1)")
   s = rep(s, "local out = ease((a - (dur - 0.6)) / 0.6)", "local out = ease((a - (dur - 1)) / 1)")
   s = rep(s, "title.TextTransparency = 1 - 0.9 * ease((t - INTRO_END) / 0.4)", "title.TextTransparency = 1")
   v.Source = s
   print("Domain patch applied to", v:GetFullName())
  end
 end
end

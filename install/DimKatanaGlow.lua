-- Dims the katana skills' glows, flashes and lights. Paste into the Studio
-- command bar and press Enter. Safe to run again: it only changes GLOW_DIM.
-- 1 = original brightness, 0.5 = half. Edit the number below to taste.
local GLOW_DIM = 0.45

local fx = game:GetService("ReplicatedStorage").Combat.KatanaFX
local s = fx.Source
local changes = 0
local function sub(pattern, replacement)
	local n
	s, n = s:gsub(pattern, replacement)
	changes += n
end

if s:find("local GLOW_DIM = ", 1, true) then
	sub("local GLOW_DIM = [%d%.]+", "local GLOW_DIM = " .. GLOW_DIM)
else
	sub("local KatanaFX = {}\n", "local KatanaFX = {}\n\n-- overall brightness of the glows, flashes and lights (1 = original)\nlocal GLOW_DIM = " .. GLOW_DIM .. "\n")
end
-- every sprite / particle glow
sub("setBrightness%(emitter, layer%.brightness or 1%)", "setBrightness(emitter, (layer.brightness or 1) * GLOW_DIM)")
sub("setBrightness%(emitter, 3%)", "setBrightness(emitter, 3 * GLOW_DIM)")
-- the white screen flash
sub("CameraFX%.flash%(cue%.flash %* falloff, FLASH_TINT%)", "CameraFX.flash(cue.flash * falloff * GLOW_DIM, FLASH_TINT)")
-- point lights on impacts and on the crescent
sub("light%.Brightness = ev%(layer%.brightness, u%)\n", "light.Brightness = ev(layer.brightness, u) * GLOW_DIM\n")
sub("light%.Brightness = P%.light%.brightness\n", "light.Brightness = P.light.brightness * GLOW_DIM\n")

fx.Source = s
print(("Katana glow set to %d%% (%d edits)"):format(GLOW_DIM * 100, changes))

--[[
	Theme  (ModuleScript in StarterPlayerScripts > UI)

	The LOOK of the game in one place. Change a color or font here and
	the whole UI updates.

	The color plan (on purpose, only a few colors):
	  - Navy blues   = backgrounds, panels, cards
	  - Gold         = the main action color (ATTACK, coins, XP, titles)
	  - Green        = "buy" buttons
	  - Red          = enemy health + close buttons
	  - Cyan         = gems only
	  - White        = text, with a dark outline
]]

local Theme = {}

-- FONTS
-- Want a different style? Try Enum.Font.FredokaOne, Enum.Font.Bangers, or Enum.Font.Cartoon.
Theme.TitleFont = Enum.Font.GothamBlack -- big, heavy and bold
Theme.TextFont = Enum.Font.GothamBold   -- normal text, a bit thinner

Theme.Colors = {
	-- navy family
	BackgroundTop    = Color3.fromRGB(34, 40, 92),
	BackgroundBottom = Color3.fromRGB(18, 20, 48),
	Panel            = Color3.fromRGB(42, 50, 110),
	PanelLight       = Color3.fromRGB(62, 74, 150),
	Slot             = Color3.fromRGB(26, 30, 70),   -- empty picture slots / bar backgrounds
	Outline          = Color3.fromRGB(12, 14, 34),   -- the thick cartoon outline on EVERYTHING

	-- accents
	Gold  = Color3.fromRGB(255, 196, 46),
	Green = Color3.fromRGB(80, 214, 100),
	Red   = Color3.fromRGB(255, 76, 96),
	Cyan  = Color3.fromRGB(70, 214, 255),

	-- text
	Text    = Color3.fromRGB(255, 255, 255),
	TextDim = Color3.fromRGB(170, 180, 225),
}

Theme.OutlineThickness = 3 -- how thick the outlines are
Theme.CornerRadius = 14    -- how round the corners are (pixels)
Theme.ButtonDepth = 6      -- how "3D" buttons look (the dark part under them, in pixels)

return Theme

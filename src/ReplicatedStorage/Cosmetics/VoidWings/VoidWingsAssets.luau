--[[
	Void Wings image ids. Upload assets/voidwings/*.png (Studio > View > Asset
	Manager > Bulk Import, or tools/voidwings/upload.py) and paste each image
	id below. Until the feather atlases are filled in, the wings draw as plain
	neon blades so the rig can still be checked.

	FeatherR_n: right-wing atlases (feather_R_n.png), FeatherL_n: left-wing
	atlases (feather_L_n.png). Each is 2x2 frames; together the 16-frame loop.

	If the galaxy loop stutters (frames playing out of order), Roblox is
	tiling the atlas from a different corner on your build: flip
	FrameFlipU and/or FrameFlipV until it flows smoothly.
]]

return {
	FeatherR_0 = "",
	FeatherR_1 = "",
	FeatherR_2 = "",
	FeatherR_3 = "",
	FeatherL_0 = "",
	FeatherL_1 = "",
	FeatherL_2 = "",
	FeatherL_3 = "",
	Sparkle = "",
	Mote = "",
	Wisp = "",

	FrameFlipU = false,
	FrameFlipV = false,
}

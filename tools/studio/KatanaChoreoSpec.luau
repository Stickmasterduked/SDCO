-- Heavy & wide M1 combo choreography (spec form). Directions are in torso space:
-- X right, Y up, -Z forward. Body values are the intended (on-screen) values.
local function v(x, y, z) return Vector3.new(x, y, z) end
local READY = { Torso = { -6, 14, 2.8, 0, -0.22, 0 }, RightLeg = { 26.38, 0, 5.76 }, LeftLeg = { -7.7, 0, -8.92 }, RightArm = { 70.25, -0.29, -51.84, 0, 0.02, 0.014 }, LeftArm = { 46.16, -11.22, 72.88, 0.076, -0.053, -0.033 }, Katana = { -12.62, -29.48, 56.98 }, Head = { 2.1, -6.3, 0.28 } }

local S = { READY = READY }

-- 1: wide horizontal sweep, right to left, chest height, lunging step
S.Katana_M1_1 = { length = 0.48, hit = 0.12, recover = 0.32, swing = 0.075, keys = {
	{ t = 0.05, torso = { 6, -42, -6, 0.06, -0.42, 0.16 }, head = { 0, 24, 2 }, rleg = { 16, 0, 9 }, lleg = { -24, 0, -12 },
		aim = v(0.82, 0.12, 0.3), blade = v(0.5, 0.2, 0.85), edge = v(0, 0, -1) },
	{ t = 0.075, torso = { 2, -22, -4, 0.04, -0.4, 0.05 }, head = { 0, 20, 2 }, rleg = { 22, 0, 9 }, lleg = { -24, 0, -12 },
		aim = v(0.88, 0.08, -0.05), blade = v(0.92, 0.12, 0.2), edge = v(0, 0, -1) },
	{ t = 0.095, torso = { -2, 4, 0, 0, -0.46, -0.18 }, head = { 0, 2, 0 }, rleg = { 32, 0, 10 }, lleg = { -28, 0, -13 },
		aim = v(0.3, 0, -0.95), blade = v(0.62, 0.05, -0.78), edge = v(-1, 0, 0) },
	{ t = 0.12, torso = { -8, 34, 6, -0.04, -0.6, -0.36 }, head = { 2, -18, -2 }, rleg = { 38, 0, 11 }, lleg = { -32, 0, -15 },
		aim = v(-0.35, -0.05, -0.93), blade = v(-0.45, 0, -0.9), edge = v(-1, 0, 0) },
	{ t = 0.17, torso = { -12, 60, 8, -0.06, -0.66, -0.42 }, head = { 3, -32, -3 }, rleg = { 40, 0, 12 }, lleg = { -30, 0, -16 },
		aim = v(-0.78, -0.12, -0.6), blade = v(-0.95, -0.08, 0.15), edge = v(0, 0, 1) },
	{ t = 0.26, torso = { -10, 55, 7, -0.05, -0.62, -0.38 }, head = { 3, -28, -2 }, rleg = { 38, 0, 12 }, lleg = { -28, 0, -15 },
		aim = v(-0.7, -0.25, -0.65), blade = v(-0.82, -0.32, 0.45), edge = v(0, -0.3, 1) },
} }

-- 2: backhand rising diagonal, low left to high right (picks up where 1 ended)
S.Katana_M1_2 = { length = 0.48, hit = 0.12, recover = 0.32, swing = 0.075, keys = {
	{ t = 0.06, torso = { -12, 50, 7, -0.04, -0.56, -0.1 }, head = { 4, -26, -2 }, rleg = { 34, 0, 10 }, lleg = { -22, 0, -13 },
		aim = v(-0.62, -0.45, -0.55), blade = v(-0.72, -0.58, 0.38), edge = v(0.5, 0.7, -0.4) },
	{ t = 0.095, torso = { -8, 26, 4, -0.02, -0.5, -0.2 }, head = { 3, -16, -1 }, rleg = { 36, 0, 10 }, lleg = { -26, 0, -13 },
		aim = v(-0.35, -0.5, -0.8), blade = v(-0.58, -0.7, -0.3), edge = v(0.6, 0.6, -0.4) },
	{ t = 0.12, torso = { 2, -6, -4, 0.04, -0.42, -0.3 }, head = { 0, 6, 1 }, rleg = { 34, 0, 9 }, lleg = { -32, 0, -14 },
		aim = v(0.25, -0.05, -0.97), blade = v(0.28, 0.38, -0.88), edge = v(0.7, 0.7, 0) },
	{ t = 0.17, torso = { 12, -42, -9, 0.06, -0.3, -0.24 }, head = { -4, 24, 3 }, rleg = { 28, 0, 9 }, lleg = { -30, 0, -14 },
		aim = v(0.75, 0.45, -0.5), blade = v(0.58, 0.78, 0.25), edge = v(0, 0.6, 0.8) },
	{ t = 0.26, torso = { 10, -38, -8, 0.05, -0.3, -0.2 }, head = { -3, 21, 3 }, rleg = { 28, 0, 9 }, lleg = { -28, 0, -14 },
		aim = v(0.7, 0.52, -0.48), blade = v(0.38, 0.9, 0.2), edge = v(0, 0.3, 1) },
} }

-- 3: heavy overhead diagonal, high right down to low left, big lunge
S.Katana_M1_3 = { length = 0.495, hit = 0.125, recover = 0.325, swing = 0.08, keys = {
	{ t = 0.06, torso = { 18, -26, -7, 0.04, -0.1, 0.18 }, head = { -10, 16, 2 }, rleg = { 14, 0, 8 }, lleg = { -14, 0, -10 },
		aim = v(0.35, 0.86, 0.08), blade = v(0.3, 0.45, 0.84), edge = v(0, 0.6, -0.8) },
	{ t = 0.1, torso = { 5, -8, -2, 0.02, -0.25, 0 }, head = { -4, 8, 1 }, rleg = { 30, 0, 9 }, lleg = { -22, 0, -12 },
		aim = v(0.25, 0.8, -0.55), blade = v(0.18, 0.96, -0.2), edge = v(-0.3, 0.2, -1) },
	{ t = 0.125, torso = { -18, 22, 9, -0.02, -0.6, -0.4 }, head = { 10, -12, -3 }, rleg = { 46, 0, 10 }, lleg = { -34, 0, -13 },
		aim = v(0.05, 0.05, -1), blade = v(-0.35, -0.08, -0.93), edge = v(-0.5, -0.85, 0) },
	{ t = 0.18, torso = { -30, 34, 11, -0.04, -0.78, -0.48 }, head = { 16, -20, -4 }, rleg = { 52, 0, 11 }, lleg = { -36, 0, -14 },
		aim = v(-0.45, -0.6, -0.65), blade = v(-0.6, -0.72, 0.25), edge = v(0, -0.6, 0.8) },
	{ t = 0.27, torso = { -27, 31, 10, -0.04, -0.74, -0.45 }, head = { 14, -18, -3 }, rleg = { 50, 0, 11 }, lleg = { -34, 0, -14 },
		aim = v(-0.42, -0.62, -0.65), blade = v(-0.52, -0.8, 0.3), edge = v(0, -0.5, 0.85) },
} }

-- 4: finisher, full-body vertical cleave with a deep stomp
S.Katana_M1_4 = { length = 0.55, hit = 0.15, recover = 0.35, swing = 0.1, keys = {
	{ t = 0.07, torso = { 28, -8, -2, 0, 0.12, 0.25 }, head = { -16, 4, 0 }, rleg = { 10, 0, 7 }, lleg = { -10, 0, -8 },
		aim = v(0.06, 0.95, 0.25), blade = v(0, 0.35, 0.94), edge = v(0, 1, 0) },
	{ t = 0.11, torso = { 10, -2, 0, 0, -0.1, 0.05 }, head = { -8, 2, 0 }, rleg = { 28, 0, 8 }, lleg = { -24, 0, -10 },
		aim = v(0.05, 0.9, -0.38), blade = v(0, 0.9, -0.38), edge = v(0, 0.3, -1) },
	{ t = 0.15, torso = { -30, 4, 1, 0, -0.85, -0.5 }, head = { 18, -2, 0 }, rleg = { 56, 0, 9 }, lleg = { -40, 0, -12 },
		aim = v(0, -0.25, -0.97), blade = v(0, -0.45, -0.89), edge = v(0, -1, 0) },
	{ t = 0.2, torso = { -40, 4, 1, 0, -1.0, -0.55 }, head = { 24, -2, 0 }, rleg = { 62, 0, 10 }, lleg = { -42, 0, -13 },
		aim = v(0, -0.55, -0.83), blade = v(0.05, -0.86, -0.5), edge = v(0, -0.4, 0.9) },
	{ t = 0.3, torso = { -37, 4, 1, 0, -0.95, -0.52 }, head = { 22, -2, 0 }, rleg = { 60, 0, 10 }, lleg = { -40, 0, -13 },
		aim = v(0, -0.52, -0.85), blade = v(0.05, -0.82, -0.55), edge = v(0, -0.4, 0.9) },
} }

return S

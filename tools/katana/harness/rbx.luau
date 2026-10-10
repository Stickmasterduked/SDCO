-- Minimal Vector3 / CFrame so AnimationData (and Config) run outside Roblox
-- for tools/katana/verify.py.
local V = {}
V.__index = V
local function v3(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end
V.__add = function(a, b) return v3(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return v3(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b)
	if type(a) == "number" then return v3(a * b.X, a * b.Y, a * b.Z) end
	if type(b) == "number" then return v3(a.X * b, a.Y * b, a.Z * b) end
	return v3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__unm = function(a) return v3(-a.X, -a.Y, -a.Z) end
V.__index = function(t, k)
	if k == "Magnitude" then return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z) end
	if k == "Unit" then local m = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z) return v3(t.X / m, t.Y / m, t.Z / m) end
	return rawget(V, k)
end
function V.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
function V.Cross(a, b) return v3(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
local Vector3 = { new = v3, zero = v3(0, 0, 0), xAxis = v3(1, 0, 0), yAxis = v3(0, 1, 0), zAxis = v3(0, 0, 1) }

local C = {}
C.__index = C
local function cf(p, r) return setmetatable({ p = p, r = r }, C) end -- r = 3x3 row-major {r00..r22}
local I = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local function mm(a, b)
	local o = {}
	for i = 0, 2 do for j = 0, 2 do
		o[i * 3 + j + 1] = a[i * 3 + 1] * b[j + 1] + a[i * 3 + 2] * b[3 + j + 1] + a[i * 3 + 3] * b[6 + j + 1]
	end end
	return o
end
local function mv(r, v) return v3(r[1] * v.X + r[2] * v.Y + r[3] * v.Z, r[4] * v.X + r[5] * v.Y + r[6] * v.Z, r[7] * v.X + r[8] * v.Y + r[9] * v.Z) end
local function tr(r) return { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] } end
C.__mul = function(a, b)
	if getmetatable(b) == C then return cf(a.p + mv(a.r, b.p), mm(a.r, b.r)) end
	return a.p + mv(a.r, b)
end
function C.Inverse(a) local t = tr(a.r) return cf(-mv(t, a.p), t) end
C.__index = function(t, k)
	if k == "Position" then return t.p end
	return rawget(C, k)
end
local function rx(a) local c, s = math.cos(a), math.sin(a) return { 1, 0, 0, 0, c, -s, 0, s, c } end
local function ry(a) local c, s = math.cos(a), math.sin(a) return { c, 0, s, 0, 1, 0, -s, 0, c } end
local function rz(a) local c, s = math.cos(a), math.sin(a) return { c, -s, 0, s, c, 0, 0, 0, 1 } end
local CFrame = {
	new = function(x, y, z, ...)
		local r = { ... }
		if #r == 9 then return cf(v3(x, y, z), r) end
		return cf(v3(x or 0, y or 0, z or 0), I)
	end,
	Angles = function(x, y, z) return cf(v3(0, 0, 0), mm(mm(rx(x), ry(y)), rz(z))) end,
	fromOrientation = function(x, y, z) return cf(v3(0, 0, 0), mm(mm(ry(y), rx(x)), rz(z))) end,
	identity = cf(v3(0, 0, 0), I),
}
return { Vector3 = Vector3, CFrame = CFrame }

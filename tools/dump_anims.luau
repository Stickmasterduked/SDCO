-- Prints AnimationData as JSON so tools/preview.py can render it.
-- Usage: luau tools/dump_anims.luau
local Data = require("../src/ReplicatedStorage/Combat/AnimationData")

local function encode(value)
	local t = type(value)
	if t == "number" then
		return string.format("%.6g", value)
	elseif t == "string" then
		return string.format("%q", value)
	elseif t == "boolean" then
		return tostring(value)
	elseif t == "table" then
		local parts = {}
		if #value > 0 or next(value) == nil then
			for _, v in ipairs(value) do
				table.insert(parts, encode(v))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(value) do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			table.insert(parts, string.format("%q", k) .. ":" .. encode(value[k]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end

print(encode(Data))

--[[
	The strike hitbox, shared so the attacker's client and the server test
	exactly the same box. A player's own client finds the target at its hit
	frame (instant feedback, no round trip); the server re-checks the claim
	against its own positions with some slack for latency. Dummies are still
	detected on the server alone.
]]

local FLAT = Vector3.new(1, 0, 1)

local Hitbox = {}

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include

-- Box in front of `root` for `attack` (range/width/height from Config).
function Hitbox.box(root, attack)
	local look = root.CFrame.LookVector * FLAT
	if look.Magnitude < 0.01 then
		look = Vector3.zAxis
	end
	local cf = CFrame.lookAlong(root.Position, look.Unit) * CFrame.new(0, attack.height and -1.5 or 0, -attack.range / 2)
	return cf, Vector3.new(attack.width, attack.height or 6, attack.range)
end

-- Nearest model from `candidates` (a list of character models) inside the box.
function Hitbox.find(root, attack, candidates)
	if #candidates == 0 then
		return nil
	end
	overlap.FilterDescendantsInstances = candidates
	local cf, size = Hitbox.box(root, attack)
	local parts = workspace:GetPartBoundsInBox(cf, size, overlap)
	local best, bestDistance
	for _, part in ipairs(parts) do
		local model = part.Parent
		local other = model and model:FindFirstChild("HumanoidRootPart")
		if other and table.find(candidates, model) then
			local distance = (other.Position - root.Position).Magnitude
			if not bestDistance or distance < bestDistance then
				best, bestDistance = model, distance
			end
		end
	end
	return best
end

-- Server-side sanity check of a client's claim that `root` hit `target`.
-- `slack` widens the box to absorb latency (the attacker saw the target a
-- little in the past).
function Hitbox.plausible(root, target, attack, slack)
	local offset = target.Position - root.Position
	local flat = offset * FLAT
	local reach = math.sqrt(attack.range ^ 2 + (attack.width / 2) ^ 2) + slack
	if flat.Magnitude > reach then
		return false
	end
	if math.abs(offset.Y) > (attack.height or 6) / 2 + 2 + slack * 0.5 then
		return false
	end
	if flat.Magnitude > 2.5 then
		local look = (root.CFrame.LookVector * FLAT).Unit
		if look:Dot(flat.Unit) < -0.25 then
			return false -- behind the attacker
		end
	end
	return true
end

return Hitbox

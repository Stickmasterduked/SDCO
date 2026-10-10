--[[
	Katana moveset. Called by AnimationData before its final detailing pass.

	The pose keys live in KatanaPoses (solved on an R6 rig so both fists sit on
	the handle). Every strike is retimed onto its fist counterpart's Hit and
	recover, so the server's timing, combos and balance are unchanged.

	Clip extras:
	  katana       = true: the client uses the blade trail and slash sounds
	  ik           = left hand on the handle (PoseAnimator two-hand IK)
	  whenEquipped = only replaces the fist clip while the katana is drawn
]]

local Poses = require(script.KatanaPoses)

local HELD = { "Jump", "Fall", "Land", "DoubleJump", "DashForward", "DashLeft", "DashRight", "DashBack", "DashAir" }

-- Overlapping action: each joint plays the clip on its own small delay
-- (negative = leads). The hips/torso lead, the arms and blade stay on the
-- authored timing (hit frames exact), the legs and head follow a beat later.
local DELAYS = { Torso = -0.02, RightArm = 0, LeftArm = 0, Katana = 0, RightLeg = 0.015, LeftLeg = 0.028, Head = 0.045 }

-- Pushes the body's in-between poses further from the first pose: bigger
-- twists, deeper dips, longer lunges. The arms and blade aren't touched
-- (the grip stays exact; the left hand follows the handle by IK).
local EXAGGERATE = { Torso = 1.58, Head = 1.48, RightLeg = 1.4, LeftLeg = 1.4 }

local function exaggerate(clip)
	local first = clip.keys[1].pose
	local n = #clip.keys
	for i, key in ipairs(clip.keys) do
		if i > 1 and i < n then
			for joint, amount in pairs(EXAGGERATE) do
				local v, b = key.pose[joint], first[joint]
				if v and b then
					local out = {}
					for c = 1, 6 do
						out[c] = (b[c] or 0) + ((v[c] or 0) - (b[c] or 0)) * amount
					end
					key.pose[joint] = out
				end
			end
		end
	end
	return clip
end

local function stagger(clip)
	local keys = clip.keys
	local length = clip.length
	local function sampleJoint(joint, t)
		t = math.clamp(t, 0, length)
		local lo, hi = 1, #keys
		while hi - lo > 1 do
			local mid = (lo + hi) // 2
			if keys[mid].t <= t then
				lo = mid
			else
				hi = mid
			end
		end
		local a, b = keys[lo], keys[hi]
		local va, vb = a.pose[joint], b.pose[joint]
		if not va or not vb then
			return va or vb
		end
		local alpha = b.t > a.t and math.clamp((t - a.t) / (b.t - a.t), 0, 1) or 0
		local v = {}
		for i = 1, 6 do
			v[i] = (va[i] or 0) + ((vb[i] or 0) - (va[i] or 0)) * alpha
		end
		return v
	end
	local out = {}
	local step = 1 / 120
	local total = clip.looped and length or length + 0.045
	for i = 0, math.ceil(total / step) do
		local t = math.min(i * step, total)
		local p = {}
		for joint in pairs(keys[1].pose) do
			local tt = t - (DELAYS[joint] or 0)
			if clip.looped then
				tt %= length
			end
			p[joint] = sampleJoint(joint, tt)
		end
		table.insert(out, { t = t, ease = "Linear", pose = p })
	end
	local result = table.clone(clip)
	result.keys = out
	result.length = total
	return result
end

-- Draw / sheathe only own the upper body while moving: their legs sit under
-- the walk/run cycle (above the idle), so walking keeps stepping.
local UNDER = { RightLeg = 1.5, LeftLeg = 1.5 }

-- Weight: the katana strikes are stretched in three parts so the blade feels
-- heavy. A longer wind-up (the body loads the swing), a swing that's only a
-- touch slower (it still cuts fast), and a longer follow-through as the
-- weight carries on. Air strikes get less so juggles stay tight. The server
-- and the client both read these retimed markers, so hit frames stay exact.
local WEIGHT = { windup = 1.4, swing = 1.12, follow = 1.2 }
local AIR_WEIGHT = { windup = 1.15, swing = 1.05, follow = 1.1 }
local AIR = { Katana_AirPunch = true, Katana_AirKick = true }
local LEGS_UNDER = { Katana_EquipIn = UNDER, Katana_EquipOut = UNDER }

return function(Data, env)
	-- same for the fist versions
	for _, name in ipairs({ "EquipIn", "EquipOut" }) do
		if Data[name] then
			Data[name].jointPriority = UNDER
		end
	end
	local detail, detailed, fps = env.detail, env.detailed, env.fps
	local springs = { Head = env.headSpring, RightLeg = env.legSpring, LeftLeg = env.legSpring }
	-- strikes: loose springs on the torso, head and legs, so they overshoot
	-- and wobble back (cartoony on purpose)
	local strikeSprings = { Head = { 5.8, 0.29 }, RightLeg = { 8.3, 0.4 }, LeftLeg = { 8.3, 0.4 }, Torso = { 6.8, 0.32 } }

	for name, c in pairs(Poses) do
		if name:sub(1, 7) == "Katana_" then
			local clip = {
				length = c.length,
				looped = c.looped == true,
				priority = c.priority or "Action",
				group = c.group or "action",
				ik = c.ik,
				jointPriority = c.jointPriority or LEGS_UNDER[name],
				whenEquipped = c.whenEquipped == true,
				katana = true,
				keys = {},
			}
			local map = function(t)
				return t
			end
			-- the katana M1s keep the fist timing they were built on, so changing the fist clips doesn't move them
			local FIST_TIMING = { M1_1 = { 0.12, 0.32 }, M1_2 = { 0.12, 0.32 }, M1_3 = { 0.125, 0.325 }, M1_4 = { 0.15, 0.35 }, Finisher = { 0.23, 0.57 } }
			local ft = FIST_TIMING[name:sub(8)]
			local fist = ft and { markers = { Hit = ft[1] }, recover = ft[2] } or Data[name:sub(8)] -- "Katana_M1_1" -> "M1_1"
			if c.hit and fist and fist.markers and fist.markers.Hit then
				local hit = fist.markers.Hit
				local scale, shift = hit / c.hit, c.hit - hit
				map = function(t)
					return t <= c.hit and t * scale or t - shift
				end
				local swing0 = map(c.swing or c.hit * 0.6)
				local recover0 = fist.recover or map(c.recover)
				local length0 = map(c.length)
				local w = AIR[name] and AIR_WEIGHT or WEIGHT
				local function heavy(t)
					if t <= swing0 then
						return t * w.windup
					end
					local a = swing0 * w.windup
					if t <= hit then
						return a + (t - swing0) * w.swing
					end
					return a + (hit - swing0) * w.swing + (t - hit) * w.follow
				end
				local retime = map
				map = function(t)
					return heavy(retime(t))
				end
				clip.markers = { Hit = heavy(hit), Swing = heavy(swing0) }
				clip.recover = heavy(recover0)
				clip.length = heavy(length0)
				clip.heavy = w
			elseif c.markers then
				clip.markers = c.markers
			end
			for _, key in ipairs(c.keys) do
				table.insert(clip.keys, { t = map(key.t), ease = "Linear", pose = key.pose })
			end
			if c.hit then
				exaggerate(clip)
			end
			local baked = detail(clip, c.hit and strikeSprings or springs, fps)
			if c.hit or name == "Katana_Idle" or name == "Katana_Feint" then
				baked = stagger(baked)
			end
			Data[name] = baked
			detailed[name] = true
		end
	end

	-- Moving with the katana drawn. Walking/running: both hands on the grip at
	-- the right hip, blade low along the side. Jumps and dashes: one hand,
	-- blade trailing.
	local RUN_LEAN = { -22, -12, 0, 0, -0.08, 0 }
	local function add(a, b)
		a = a or { 0, 0, 0 }
		local out = {}
		for i = 1, 6 do
			out[i] = (a[i] or 0) + (b[i] or 0)
		end
		return out
	end
	local carry = Poses.CARRY
	local runHold = Poses.RUNHOLD
	local function held(base)
		local src = Data[base]
		if not src then
			return
		end
		local clip = table.clone(src)
		clip.keys = {}
		for i, key in ipairs(src.keys) do
			local p = table.clone(key.pose)
			if base == "Run" then
				-- stealthy: hunched over, a little lower, eyes kept up
				p.Torso = add(p.Torso, RUN_LEAN)
				p.Head = add(p.Head, { 16, 10, 0 })
				p.RightLeg = add(p.RightLeg, { 22, 0, 0 })
				p.LeftLeg = add(p.LeftLeg, { 22, 0, 0 })
				p.RightArm = runHold.RightArm
				p.LeftArm = runHold.LeftArm
				p.Katana = runHold.Katana
			else
				p.RightArm = carry.RightArm
				p.Katana = carry.Katana
			end
			clip.keys[i] = { t = key.t, ease = key.ease, dir = key.dir, pose = p }
		end
		clip.whenEquipped = true
		clip.katana = true
		clip.ik = base == "Run" and 1 or 0
		clip.trail = nil
		Data["Katana_" .. base] = clip
		detailed["Katana_" .. base] = detailed[base]
	end
	held("Run")
	for _, base in ipairs(HELD) do
		held(base)
	end
end

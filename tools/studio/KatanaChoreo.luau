-- Edit-time tool: turns blade-direction specs into katana pose keys, and previews poses on an R6 rig.
local AB = require(game.ReplicatedStorage.Combat.AnimationBuilder)
local C = {}
local MOTOR = { Torso = "RootJoint", Head = "Neck", RightArm = "Right Shoulder", LeftArm = "Left Shoulder", RightLeg = "Right Hip", LeftLeg = "Left Hip", Katana = "KatanaGrip" }
local RIGHT_ROTATION = CFrame.fromOrientation(0, math.pi / 2, 0)
local LEFT_ROTATION = CFrame.fromOrientation(0, -math.pi / 2, 0)

function C.rig()
	local r = workspace:FindFirstChild("ChoreoRig")
	if r then return r end
	r = workspace.CombatTest.Dummies["Passive Dummy"]:Clone()
	r.Name = "ChoreoRig"
	for _, d in ipairs(r:GetDescendants()) do
		if d:IsA("BaseScript") or d:IsA("BillboardGui") then d:Destroy() end
	end
	r.Parent = workspace
	r:PivotTo(CFrame.new(0, 3, 60))
	local arm = r["Right Arm"]
	local k = game.ServerStorage.Weapons.Katana:Clone()
	local handle = k.KatanaHandle
	local grip = handle.RightGrip
	local m = Instance.new("Motor6D")
	m.Name = "KatanaGrip"; m.Part0 = arm; m.Part1 = handle; m.C0 = CFrame.new(0, -0.8, 0); m.C1 = grip.CFrame
	m.Parent = handle
	k.Parent = r
	for _, p in ipairs(r:GetDescendants()) do if p:IsA("BasePart") then p.Anchored = true end end
	return r
end

local function motors(r)
	local t = {}
	for j, n in pairs(MOTOR) do t[j] = r:FindFirstChild(n, true) end
	return t
end

-- world CFrames of every part for a pose (FK)
function C.fk(r, pose)
	local m = motors(r)
	local root = r.HumanoidRootPart.CFrame
	local T = {}
	for j in pairs(MOTOR) do T[j] = pose[j] and AB.toTransform(j, pose[j]) or CFrame.identity end
	local cf = {}
	cf.Torso = root * m.Torso.C0 * T.Torso * m.Torso.C1:Inverse()
	for _, j in ipairs({ "Head", "RightArm", "LeftArm", "RightLeg", "LeftLeg" }) do
		cf[j] = cf.Torso * m[j].C0 * T[j] * m[j].C1:Inverse()
	end
	cf.Katana = cf.RightArm * m.Katana.C0 * T.Katana * m.Katana.C1:Inverse()
	return cf, m
end

local PART = { Torso = "Torso", Head = "Head", RightArm = "Right Arm", LeftArm = "Left Arm", RightLeg = "Right Leg", LeftLeg = "Left Leg" }
function C.apply(r, pose)
	local cf = C.fk(r, pose)
	for j, n in pairs(PART) do r[n].CFrame = cf[j] end
	local k = r.Katana
	local handle = k.KatanaHandle
	local old = handle.CFrame
	for _, p in ipairs(k:GetDescendants()) do
		if p:IsA("BasePart") then p.CFrame = cf.Katana * old:ToObjectSpace(p.CFrame) end
	end
	return cf
end

-- left fist onto the LeftGrip (same method as PoseAnimator.twoHand); returns LeftArm pose value
local FIST = Vector3.new(0, -0.8, 0)
function C.leftIK(r, pose)
	local cf, m = C.fk(r, pose)
	local grip = r.Katana.KatanaHandle.LeftGrip
	local target = (cf.Katana * grip.CFrame).Position
	local handleAxis = cf.Katana.LookVector
	local shoulder = (cf.Torso * m.LeftArm.C0).Position
	local current = cf.LeftArm
	local a, b = current * FIST - shoulder, target - shoulder
	local solved = current
	if a.Magnitude > 1e-3 and b.Magnitude > 1e-3 then
		local cross = a.Unit:Cross(b.Unit)
		if cross.Magnitude > 1e-5 then
			solved = CFrame.new(shoulder) * CFrame.fromAxisAngle(cross.Unit, math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1))) * CFrame.new(-shoulder) * current
		end
	end
	local slide = target - solved * FIST
	if slide.Magnitude > 0.7 then slide = slide.Unit * 0.7 end
	solved += slide
	local up = solved.UpVector
	local across = handleAxis - up * handleAxis:Dot(up)
	if across.Magnitude > 0.25 then
		across = across.Unit
		local look = solved.LookVector
		if look:Dot(across) < 0 then across = -across end
		local twist = math.atan2(look:Cross(across):Dot(up), look:Dot(across))
		local pivot = solved * FIST
		solved = CFrame.new(pivot) * CFrame.fromAxisAngle(up, twist) * CFrame.new(-pivot) * solved
	end
	local T = m.LeftArm.C0:Inverse() * cf.Torso:Inverse() * solved * m.LeftArm.C1
	local Rv = LEFT_ROTATION * T * LEFT_ROTATION:Inverse()
	local x, y, z = Rv:ToEulerAnglesXYZ()
	local p = Rv.Position
	local function r3(v) return math.floor(v * 100 + 0.5) / 100 end
	return { r3(math.deg(x)), r3(math.deg(y)), r3(math.deg(z)), r3(p.X), r3(p.Y), r3(p.Z) }
end

local function deg3(cf)
	local x, y, z = cf:ToEulerAnglesXYZ()
	return math.deg(x), math.deg(y), math.deg(z)
end

--[[ spec (all directions in TORSO space: X right, Y up, -Z forward):
	torso = {pitch, yaw, roll, x, y, z}, head = {..}, rleg = {..}, lleg = {..}
	aim   = direction from the right shoulder to the right fist
	blade = direction the blade points (handle -> tip)
	edge  = direction the cutting edge faces (should lead the swing)
]]
function C.solve(r, spec, prev)
	local pose = { Torso = spec.torso, Head = spec.head, RightLeg = spec.rleg, LeftLeg = spec.lleg }
	local cf, m = C.fk(r, pose)
	local torso = cf.Torso
	local shoulder = torso * m.RightArm.C0 -- joint frame
	local pivot = shoulder.Position
	-- arm with identity transform
	local arm0 = torso * m.RightArm.C0 * m.RightArm.C1:Inverse()
	local v0 = (arm0 * FIST) - pivot
	local d = torso:VectorToWorldSpace(spec.aim.Unit)
	local swing = CFrame.identity
	local cross = v0.Unit:Cross(d)
	if cross.Magnitude > 1e-6 then
		swing = CFrame.fromAxisAngle(cross.Unit, math.acos(math.clamp(v0.Unit:Dot(d), -1, 1)))
	elseif v0.Unit:Dot(d) < 0 then
		swing = CFrame.fromAxisAngle(torso.RightVector, math.pi)
	end
	local bladeW = torso:VectorToWorldSpace(spec.blade.Unit)
	local edgeW = torso:VectorToWorldSpace(spec.edge.Unit)
	edgeW = (edgeW - bladeW * edgeW:Dot(bladeW)).Unit
	-- handle frame: LookVector = blade, UpVector = -edge (spine side up)
	local up = -edgeW
	local right = bladeW:Cross(up) -- X = Y x Z, Z = -blade
	right = up:Cross(-bladeW)
	local grip = r.Katana.KatanaHandle.RightGrip
	local best, bestScore, bestAngle
	for i = 0, 71 do
		local tw = math.rad(i * 5)
		local rot = CFrame.fromAxisAngle(d, tw) * swing
		local armCF = CFrame.new(pivot) * rot * CFrame.new(-pivot) * arm0
		local fist = armCF * FIST
		local handleCF = CFrame.fromMatrix(Vector3.zero, right, up, -bladeW)
		handleCF = handleCF + (fist - (handleCF * grip.CFrame).Position)
		local Tk = (armCF * m.Katana.C0):Inverse() * handleCF * m.Katana.C1
		local _, angle = Tk:ToAxisAngle()
		angle = math.abs(angle)
		local armLocal = torso:ToObjectSpace(armCF)
		local score = angle
		if prev and prev.armLocal then
			local _, dA = (prev.armLocal:Inverse() * armLocal):ToAxisAngle()
			score += math.abs(dA) * 0.9
		end
		if not bestScore or score < bestScore then
			bestScore, bestAngle = score, angle
			best = { armCF = armCF, Tk = Tk, armLocal = armLocal }
		end
	end
	local T = m.RightArm.C0:Inverse() * torso:Inverse() * best.armCF * m.RightArm.C1
	local Rv = RIGHT_ROTATION * T * RIGHT_ROTATION:Inverse()
	local ax, ay, az = deg3(Rv)
	local kx, ky, kz = deg3(best.Tk - best.Tk.Position)
	local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
	pose.RightArm = { r2(ax), r2(ay), r2(az), 0, 0, 0 }
	pose.Katana = { r2(kx), r2(ky), r2(kz) }
	pose.LeftArm = { 60, 0, 70, 0, 0, 0 }
	pose.LeftArm = C.leftIK(r, pose)
	return pose, math.deg(bestAngle), { armLocal = best.armLocal }
end

return C

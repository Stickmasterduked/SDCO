--[[
	Shop / inventory preview: a dummy wearing the real cosmetic inside a
	ViewportFrame, slowly orbiting so the wings are seen from behind and both
	sides.

		local handle = Preview.mount(viewportFrame, "VoidWings")
		handle:SetItem("VoidWings") -- or nil for the bare dummy
		handle:Destroy()

	The dummy is a copy of the local player's character when it can be
	cloned, otherwise a blocky R6 dummy.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Items = require(script.Parent.Items)

local Preview = {}

local function blockyDummy(): Model
	local model = Instance.new("Model")
	model.Name = "PreviewDummy"
	local skin = Color3.fromRGB(165, 200, 230)
	local cloth = Color3.fromRGB(24, 36, 70)
	local function add(name, size, cframe, color)
		local part = Instance.new("Part")
		part.Name = name
		part.Size = size
		part.CFrame = cframe
		part.Color = color
		part.Anchored = true
		part.CanCollide = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end
	local torso = add("Torso", Vector3.new(2, 2, 1), CFrame.new(0, 3, 0), cloth)
	add("Head", Vector3.new(2, 1, 1), CFrame.new(0, 4.5, 0), skin)
	add("Left Arm", Vector3.new(1, 2, 1), CFrame.new(-1.5, 3, 0), skin)
	add("Right Arm", Vector3.new(1, 2, 1), CFrame.new(1.5, 3, 0), skin)
	add("Left Leg", Vector3.new(1, 2, 1), CFrame.new(-0.5, 1, 0), cloth)
	add("Right Leg", Vector3.new(1, 2, 1), CFrame.new(0.5, 1, 0), cloth)
	model.PrimaryPart = torso
	return model
end

local function characterCopy(): Model?
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	if not character then
		return nil
	end
	local ok, copy = pcall(function()
		local was = character.Archivable
		character.Archivable = true
		local clone = character:Clone()
		character.Archivable = was
		return clone
	end)
	if not ok or not copy then
		return nil
	end
	for _, d in ipairs(copy:GetDescendants()) do
		if d:IsA("BaseScript") or d:IsA("ModuleScript") or d:IsA("Sound") or d:IsA("ParticleEmitter")
			or d:IsA("Light") or d.Name == "VoidWings" or d.Name == "VoidWingsLight" then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
		elseif d:IsA("Humanoid") then
			d.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	if not (copy:FindFirstChild("Torso") or copy:FindFirstChild("UpperTorso")) then
		copy:Destroy()
		return nil
	end
	return copy
end

function Preview.mount(viewport: ViewportFrame, itemId: string?)
	local folder = Instance.new("Folder")
	folder.Name = "CosmeticPreview"
	folder.Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = 38
	camera.Parent = folder
	viewport.CurrentCamera = camera
	viewport.Ambient = Color3.fromRGB(150, 140, 180)
	viewport.LightColor = Color3.fromRGB(255, 245, 255)
	viewport.LightDirection = Vector3.new(-0.4, -1, -0.6)

	local dummy = characterCopy() or blockyDummy()
	dummy.Name = "PreviewDummy"
	dummy:PivotTo(CFrame.new(0, 3, 0))
	dummy.Parent = folder
	local torso = (dummy:FindFirstChild("Torso") or dummy:FindFirstChild("UpperTorso")) :: BasePart
	local focus = torso.Position + Vector3.new(0, 1.2, 0)

	local handle = { Rig = nil, Id = nil }

	function handle:SetItem(id: string?)
		if handle.Rig then
			handle.Rig:Destroy()
			handle.Rig = nil
		end
		handle.Id = id
		local item = Items.get(id)
		local module = item and item.Rig and script.Parent:FindFirstChild(item.Rig)
		if module then
			handle.Rig = require(module).new(torso, { Viewport = true, Parent = folder })
		end
	end

	local start = os.clock()
	local connection = RunService.RenderStepped:Connect(function()
		if not viewport.Visible then
			return
		end
		local t = os.clock() - start
		-- orbit around the back: +Z is behind the dummy
		local yaw = math.sin(t * 0.45) * 1.05
		local offset = CFrame.Angles(0, yaw, 0) * Vector3.new(0, 1.6, 16)
		camera.CFrame = CFrame.lookAt(focus + offset, focus)
		if handle.Rig then
			handle.Rig:Step(os.clock())
		end
	end)

	function handle:Destroy()
		connection:Disconnect()
		if handle.Rig then
			handle.Rig:Destroy()
		end
		folder:Destroy()
	end

	handle:SetItem(itemId)
	return handle
end

return Preview

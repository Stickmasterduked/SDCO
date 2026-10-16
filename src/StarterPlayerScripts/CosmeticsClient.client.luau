--[[
	Renders equipped cosmetics on every character (client-side rigs, driven
	from one RenderStepped) and the local inventory panel with a live
	ViewportFrame preview.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Cosmetics = ReplicatedStorage:WaitForChild("Cosmetics")
local Items = require(Cosmetics:WaitForChild("Items"))
local Preview = require(Cosmetics:WaitForChild("Preview"))
local remote = ReplicatedStorage:WaitForChild("CosmeticsRemote")

local player = Players.LocalPlayer
local CULL_DISTANCE = 220

local function rigModule(item)
	local module = item and item.Rig and Cosmetics:FindFirstChild(item.Rig)
	return module and require(module)
end

-- preload every rig's textures once, so the first loop doesn't flicker
task.spawn(function()
	local ids = {}
	for _, item in pairs(Items.Catalog) do
		local rig = rigModule(item)
		if rig and rig.preloadList then
			for _, id in ipairs(rig.preloadList()) do
				table.insert(ids, id)
			end
		end
	end
	if #ids > 0 then
		pcall(function()
			ContentProvider:PreloadAsync(ids)
		end)
	end
end)

-- worn[player][slot] = { Id, Rig, Character, Torso }
local worn: { [Player]: { [string]: any } } = {}

local function torsoOf(character: Model): BasePart?
	return (character:FindFirstChild("Torso") or character:FindFirstChild("UpperTorso")) :: BasePart?
end

local function refresh(target: Player)
	local slots = worn[target] or {}
	worn[target] = slots
	local character = target.Character
	for _, slot in ipairs(Items.Slots) do
		local id = Items.equipped(target, slot)
		local current = slots[slot]
		if current and (current.Id ~= id or current.Character ~= character or not current.Torso:IsDescendantOf(workspace)) then
			current.Rig:Destroy()
			slots[slot] = nil
			current = nil
		end
		local torso = character and torsoOf(character)
		if not current and id and torso and torso:IsDescendantOf(workspace) then
			local rig = rigModule(Items.get(id))
			if rig then
				local ok, built = pcall(rig.new, torso)
				if ok then
					slots[slot] = { Id = id, Rig = built, Character = character, Torso = torso }
				else
					warn("[Cosmetics] couldn't build " .. id .. ": " .. tostring(built))
				end
			end
		end
	end
end

local function watch(target: Player)
	for _, slot in ipairs(Items.Slots) do
		target:GetAttributeChangedSignal("Equipped" .. slot):Connect(function()
			refresh(target)
		end)
	end
	local function onCharacter(character: Model)
		-- the torso can arrive a moment after the model
		local torso = torsoOf(character)
			or character:WaitForChild("Torso", 3)
			or character:WaitForChild("UpperTorso", 3)
		if torso and target.Character == character then
			refresh(target)
		end
	end
	target.CharacterAdded:Connect(onCharacter)
	if target.Character then
		task.spawn(onCharacter, target.Character)
	end
end

for _, other in ipairs(Players:GetPlayers()) do
	watch(other)
end
Players.PlayerAdded:Connect(watch)
Players.PlayerRemoving:Connect(function(target)
	for _, w in pairs(worn[target] or {}) do
		w.Rig:Destroy()
	end
	worn[target] = nil
end)

RunService.RenderStepped:Connect(function()
	local now = os.clock()
	local camera = workspace.CurrentCamera
	local eye = camera and camera.CFrame.Position or Vector3.zero
	for target, slots in pairs(worn) do
		for slot, w in pairs(slots) do
			if not w.Torso:IsDescendantOf(workspace) then
				w.Rig:Destroy()
				slots[slot] = nil
			else
				local near = (w.Torso.Position - eye).Magnitude < CULL_DISTANCE
				w.Rig:SetEnabled(near)
				if near then
					w.Rig:Step(now)
				end
			end
		end
	end
end)

----------------------------------------------------------------------------
-- Inventory panel (only for players who own something)

local gui, panel, preview, listFrame, equipButton, nameLabel, rarityLabel, tagLabel, descLabel
local selected: string? = nil

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
end

local function label(parent, text, size, color, font)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextSize = size
	l.TextColor3 = color or Color3.new(1, 1, 1)
	l.Font = font or Enum.Font.GothamBold
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Size = UDim2.new(1, 0, 0, size + 4)
	l.Parent = parent
	return l
end

local function updatePanel()
	if not panel then
		return
	end
	local owned = Items.owned(player)
	if not (selected and owned[selected]) then
		selected = nil
		for id in pairs(owned) do
			selected = id
			break
		end
	end
	for _, child in ipairs(listFrame:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local ids = {}
	for id in pairs(owned) do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local item = Items.get(id)
		local rarity = Items.Rarities[item.Rarity]
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0, 120, 1, 0)
		b.BackgroundColor3 = if id == selected then Color3.fromRGB(45, 20, 80) else Color3.fromRGB(22, 14, 40)
		b.TextColor3 = rarity and rarity.Color or Color3.new(1, 1, 1)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 13
		b.Text = item.Name
		b.Parent = listFrame
		corner(b, 6)
		b.Activated:Connect(function()
			selected = id
			updatePanel()
		end)
	end

	local item = Items.get(selected)
	if not item then
		return
	end
	local rarity = Items.Rarities[item.Rarity]
	nameLabel.Text = item.Name
	rarityLabel.Text = string.upper(item.Rarity) .. "  ·  " .. string.upper(item.Category)
	rarityLabel.TextColor3 = rarity and rarity.Color or Color3.new(1, 1, 1)
	local tags = {}
	if item.Exclusive then
		table.insert(tags, "EXCLUSIVE")
	end
	if not item.ForSale then
		table.insert(tags, "NOT SOLD")
	end
	if not item.Tradeable then
		table.insert(tags, "NOT TRADEABLE")
	end
	tagLabel.Text = table.concat(tags, "  ·  ")
	descLabel.Text = item.Description or ""
	local wearing = Items.equipped(player, item.Category) == selected
	equipButton.Text = if wearing then "UNEQUIP" else "EQUIP"
	equipButton.BackgroundColor3 = if wearing then Color3.fromRGB(70, 30, 90) else Color3.fromRGB(140, 40, 220)
	if preview.Id ~= selected then
		preview:SetItem(selected)
	end
end

local function buildPanel()
	gui = Instance.new("ScreenGui")
	gui.Name = "Cosmetics"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	local open = Instance.new("TextButton")
	open.Name = "Open"
	open.AnchorPoint = Vector2.new(0, 1)
	open.Position = UDim2.new(0, 16, 1, -150)
	open.Size = UDim2.new(0, 96, 0, 34)
	open.BackgroundColor3 = Color3.fromRGB(22, 14, 40)
	open.TextColor3 = Color3.fromRGB(255, 120, 255)
	open.Font = Enum.Font.GothamBold
	open.TextSize = 14
	open.Text = "COSMETICS"
	open.Parent = gui
	corner(open)
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(180, 80, 255)
	stroke.Thickness = 1.5
	stroke.Parent = open

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 1)
	panel.Position = UDim2.new(0, 16, 1, -194)
	panel.Size = UDim2.new(0, 320, 0, 470)
	panel.BackgroundColor3 = Color3.fromRGB(10, 6, 24)
	panel.BackgroundTransparency = 0.08
	panel.Visible = false
	panel.Parent = gui
	corner(panel, 10)
	local pstroke = stroke:Clone()
	pstroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 12), UDim.new(0, 12)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
	pad.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel

	listFrame = Instance.new("Frame")
	listFrame.BackgroundTransparency = 1
	listFrame.Size = UDim2.new(1, 0, 0, 28)
	listFrame.LayoutOrder = 1
	listFrame.Parent = panel
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.Padding = UDim.new(0, 6)
	row.Parent = listFrame

	local viewport = Instance.new("ViewportFrame")
	viewport.Size = UDim2.new(1, 0, 0, 250)
	viewport.BackgroundColor3 = Color3.fromRGB(70, 150, 210)
	viewport.LayoutOrder = 2
	viewport.Visible = false
	viewport.Parent = panel
	corner(viewport)
	preview = Preview.mount(viewport, nil)

	nameLabel = label(panel, "", 20)
	nameLabel.LayoutOrder = 3
	rarityLabel = label(panel, "", 13)
	rarityLabel.LayoutOrder = 4
	tagLabel = label(panel, "", 11, Color3.fromRGB(190, 170, 220), Enum.Font.Gotham)
	tagLabel.LayoutOrder = 5
	descLabel = label(panel, "", 12, Color3.fromRGB(220, 210, 240), Enum.Font.Gotham)
	descLabel.TextWrapped = true
	descLabel.Size = UDim2.new(1, 0, 0, 32)
	descLabel.LayoutOrder = 6

	equipButton = Instance.new("TextButton")
	equipButton.Size = UDim2.new(1, 0, 0, 36)
	equipButton.TextColor3 = Color3.new(1, 1, 1)
	equipButton.Font = Enum.Font.GothamBold
	equipButton.TextSize = 15
	equipButton.LayoutOrder = 7
	equipButton.Parent = panel
	corner(equipButton)
	equipButton.Activated:Connect(function()
		local item = Items.get(selected)
		if not item then
			return
		end
		if Items.equipped(player, item.Category) == selected then
			remote:FireServer("Unequip", item.Category)
		else
			remote:FireServer("Equip", selected)
		end
	end)

	open.Activated:Connect(function()
		panel.Visible = not panel.Visible
		viewport.Visible = panel.Visible -- the preview only animates while shown
		if panel.Visible then
			updatePanel()
		end
	end)
end

local function onOwnership()
	local any = next(Items.owned(player)) ~= nil
	if any and not gui then
		buildPanel()
	end
	if gui then
		gui.Enabled = any
		updatePanel()
	end
end

player:GetAttributeChangedSignal("OwnedCosmetics"):Connect(onOwnership)
for _, slot in ipairs(Items.Slots) do
	player:GetAttributeChangedSignal("Equipped" .. slot):Connect(updatePanel)
end
onOwnership()

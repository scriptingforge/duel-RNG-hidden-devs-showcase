
-- inventory system
-- shows all your items in a grid with 3d previews
-- press G to toggle or click the inventory button

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ItemConfig = require(ReplicatedStorage.ItemConfig)
local ItemModels = ReplicatedStorage:WaitForChild("ItemModels")
local equipRequestEvent = ReplicatedStorage:WaitForChild("EquipRequestEvent")
local awardItemEvent = ReplicatedStorage:WaitForChild("AwardItemEvent")
local inventoryLoadedEvent = ReplicatedStorage:WaitForChild("InventoryLoadedEvent")
local toggleInventoryEvent = ReplicatedStorage:WaitForChild("ToggleInventoryEvent")
local Icons = require(ReplicatedStorage:WaitForChild("Icons"))

local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

local playerInventory = {}
local rotatingSlotModels = {} -- all the mini viewport models that spin
local currentlyEquipped = nil
local isAnimating = false

-- dark theme colors
local Colors = {
	Background = Color3.fromRGB(12, 12, 20),
	BackgroundAccent = Color3.fromRGB(20, 20, 35),
	Card = Color3.fromRGB(25, 25, 45),
	CardHover = Color3.fromRGB(35, 35, 60),
	CardBorder = Color3.fromRGB(50, 50, 80),
	Primary = Color3.fromRGB(90, 120, 255),
	PrimaryGlow = Color3.fromRGB(120, 150, 255),
	Secondary = Color3.fromRGB(45, 50, 70),
	SecondaryHover = Color3.fromRGB(60, 65, 90),
	Text = Color3.fromRGB(255, 255, 255),
	TextMuted = Color3.fromRGB(140, 145, 170),
	TextDim = Color3.fromRGB(100, 105, 130),
	Success = Color3.fromRGB(50, 205, 130),
	SuccessGlow = Color3.fromRGB(80, 235, 160),
	Danger = Color3.fromRGB(230, 85, 85),
	DangerGlow = Color3.fromRGB(255, 120, 120),
}


-- GET GUI REFERENCES --
-- gui is already made in starterGui, just grab the references

local screenGui = playerGui:WaitForChild("InventoryGui")
local backgroundOverlay = screenGui:WaitForChild("BackgroundOverlay")
local mainFrame = screenGui:WaitForChild("MainFrame")

local headerFrame = mainFrame:WaitForChild("Header")
local titleLabel = headerFrame:WaitForChild("Title")
local closeInventoryButton = headerFrame:WaitForChild("CloseInventoryButton")
local closeButtonIcon = closeInventoryButton:WaitForChild("Icon")

local contentHolder = mainFrame:WaitForChild("ContentHolder")
local inventoryGrid = contentHolder:WaitForChild("InventoryGrid")
local gridLayout = inventoryGrid:WaitForChild("UIGridLayout")

local rightPanel = contentHolder:WaitForChild("RightPanel")
local viewportFrame = rightPanel:WaitForChild("ItemViewport")
local viewportCamera = viewportFrame:WaitForChild("Camera")

local itemInfoFrame = rightPanel:WaitForChild("ItemInfoFrame")
local itemNameLabel = itemInfoFrame:WaitForChild("ItemName")
local itemDescLabel = itemInfoFrame:WaitForChild("ItemDescription")

local equipButton = rightPanel:WaitForChild("EquipButton")

-- extra light so the model looks good
local lightPart = Instance.new("Part")
lightPart.Name = "LightPart"
lightPart.Anchored = true
lightPart.CanCollide = false
lightPart.Transparency = 1
lightPart.Size = Vector3.new(1, 1, 1)

local pointLight = Instance.new("PointLight")
pointLight.Brightness = 2.5
pointLight.Color = Color3.new(1, 1, 1)
pointLight.Range = 35
pointLight.Parent = lightPart

local currentModel = nil
local modelRotationConnection = nil
local selectedItemId = nil


-- HELPERS --

local function createCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 12)
	corner.Parent = parent
	return corner
end

local function createStroke(parent, color, thickness, transparency)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness or 2
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

-- hover effect for the item slots
-- scales up a bit and makes the border glow
local function addSlotHoverEffect(button, baseColor, glowColor)
	local originalSize = button.Size
	
	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = Colors.CardHover,
			Size = UDim2.new(
				originalSize.X.Scale * 1.08, 
				originalSize.X.Offset,
				originalSize.Y.Scale * 1.08,
				originalSize.Y.Offset
			)
		}):Play()
		
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke and glowColor then
			TweenService:Create(stroke, TweenInfo.new(0.2), {
				Transparency = 0,
				Thickness = 3
			}):Play()
		end
	end)
	
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = baseColor or Colors.Card,
			Size = originalSize
		}):Play()
		
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			TweenService:Create(stroke, TweenInfo.new(0.2), {
				Transparency = 0.4,
				Thickness = 2
			}):Play()
		end
	end)
end


-- INVENTORY LOGIC --

-- shows the selected item in the big viewport
local function updateMainViewport(itemId)
	selectedItemId = itemId
	if currentModel then currentModel:Destroy(); currentModel = nil end
	if modelRotationConnection then modelRotationConnection:Disconnect(); modelRotationConnection = nil end
	
	local config = ItemConfig[itemId]
	if not config then return end
	
	itemNameLabel.Text = config.Name
	itemDescLabel.Text = config.Description
	
	-- only show equip button for weapons
	if config.IsWeapon then
		equipButton.Visible = true
		if currentlyEquipped == itemId then
			equipButton.Text = "UNEQUIP"
			equipButton.BackgroundColor3 = Colors.Danger
			local stroke = equipButton:FindFirstChildOfClass("UIStroke")
			if stroke then stroke.Color = Colors.DangerGlow end
		else
			equipButton.Text = "EQUIP"
			equipButton.BackgroundColor3 = Colors.Success
			local stroke = equipButton:FindFirstChildOfClass("UIStroke")
			if stroke then stroke.Color = Colors.SuccessGlow end
		end
	else
		equipButton.Visible = false
	end
	
	if not config.ModelName then
		lightPart.Parent = nil
		return
	end
	
	lightPart.Parent = viewportFrame
	local modelSource = ItemModels:FindFirstChild(config.ModelName)
	if not modelSource then print("Warning: Model not found for item: " .. itemId) return end
	
	currentModel = modelSource:Clone()
	currentModel.Parent = viewportFrame
	
	-- position camera based on model size
	local modelCFrame, modelSize = currentModel:GetBoundingBox()
	local diagonal = (modelSize.X^2 + modelSize.Y^2 + modelSize.Z^2)^0.5
	viewportCamera.CFrame = CFrame.new(modelCFrame.Position + Vector3.new(0, 0, diagonal * 1.5), modelCFrame.Position)
	lightPart.CFrame = viewportCamera.CFrame
	
	-- spin the model
	modelRotationConnection = RunService.RenderStepped:Connect(function(dt)
		if currentModel and mainFrame.Visible then
			currentModel:SetPrimaryPartCFrame(currentModel:GetPrimaryPartCFrame() * CFrame.Angles(0, dt * 1.5, 0))
		end
	end)
end

-- creates one slot in the grid
local function createItemSlot(itemId, layoutOrder)
	local config = ItemConfig[itemId]
	if not config then return nil end
	
	local slotButton = Instance.new("TextButton")
	slotButton.Name = itemId
	slotButton.Text = ""
	slotButton.BackgroundColor3 = Colors.Card
	slotButton.AutoButtonColor = false
	slotButton.LayoutOrder = layoutOrder
	slotButton.ZIndex = 5
	slotButton.Parent = inventoryGrid
	createCorner(slotButton, 10)
	
	-- border color matches item rarity
	local glowColor = config.Color or Colors.CardBorder
	createStroke(slotButton, glowColor, 2, 0.4)
	
	-- if theres a model, show it in a mini viewport
	if config.ModelName and ItemModels:FindFirstChild(config.ModelName) then
		local slotViewport = Instance.new("ViewportFrame")
		slotViewport.Size = UDim2.new(1, -8, 1, -8)
		slotViewport.Position = UDim2.new(0.5, 0, 0.5, 0)
		slotViewport.AnchorPoint = Vector2.new(0.5, 0.5)
		slotViewport.BackgroundTransparency = 1
		slotViewport.Ambient = Color3.fromRGB(180, 180, 200)
		slotViewport.LightColor = Color3.fromRGB(255, 255, 255)
		slotViewport.ZIndex = 6
		slotViewport.Parent = slotButton
		
		local slotCam = Instance.new("Camera")
		slotCam.Parent = slotViewport
		slotViewport.CurrentCamera = slotCam
		
		local modelClone = ItemModels[config.ModelName]:Clone()
		modelClone.Parent = slotViewport
		table.insert(rotatingSlotModels, modelClone)
		
		local modelCFrame, modelSize = modelClone:GetBoundingBox()
		local diagonal = (modelSize.X^2 + modelSize.Y^2 + modelSize.Z^2)^0.5
		slotCam.CFrame = CFrame.new(modelCFrame.Position + Vector3.new(0, 0, diagonal * 1.2), modelCFrame.Position)
		
		local slotLight = Instance.new("PointLight")
		slotLight.Brightness = 1.5
		slotLight.Range = 20
		slotLight.Parent = modelClone
	else
		-- fallback to icon if no model
		local itemIcon = Instance.new("ImageLabel")
		itemIcon.Image = config.Icon
		itemIcon.Size = UDim2.new(1, -14, 1, -14)
		itemIcon.Position = UDim2.new(0.5, 0, 0.5, 0)
		itemIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		itemIcon.BackgroundTransparency = 1
		itemIcon.ZIndex = 6
		itemIcon.Parent = slotButton
	end
	
	addSlotHoverEffect(slotButton, Colors.Card, glowColor)

	slotButton.MouseButton1Click:Connect(function()
		updateMainViewport(itemId)
		-- on mobile, clicking also equips since theres no hover
		if isMobile and config.IsWeapon then
			equipRequestEvent:FireServer(itemId)
		end
	end)
end

-- rebuilds the whole grid from the inventory array
local function populateInventory()
	for _, child in ipairs(inventoryGrid:GetChildren()) do
		if child:IsA("TextButton") then child:Destroy() end
	end
	table.clear(rotatingSlotModels)
	
	for i, itemId in ipairs(playerInventory) do
		createItemSlot(itemId, i)
	end
	
	-- update scroll size after grid is built
	task.wait()
	local gridContentHeight = gridLayout.AbsoluteContentSize.Y + 40
	if isMobile then
		inventoryGrid.Size = UDim2.new(1, 0, 0, gridContentHeight)
		local totalCanvasHeight = inventoryGrid.AbsoluteSize.Y + rightPanel.AbsoluteSize.Y + 15
		contentHolder.CanvasSize = UDim2.new(0, 0, 0, totalCanvasHeight)
	else
		inventoryGrid.CanvasSize = UDim2.new(0, 0, 0, gridContentHeight)
	end
end

-- opens/closes with a nice animation
local function toggleInventory()
	if isAnimating then return end
	isAnimating = true
	
	local isVisible = mainFrame.Visible
	local tweenInfo = TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local tweenInfoOut = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In)
	
	if not isVisible then
		mainFrame.Visible = true
		backgroundOverlay.Visible = true
		
		TweenService:Create(backgroundOverlay, TweenInfo.new(0.3), {BackgroundTransparency = 0.5}):Play()
		
		-- pop in from slightly smaller
		local startSize = isMobile and UDim2.new(0.85, 0, 0.8, 0) or UDim2.new(0.65, 0, 0.7, 0)
		local endSize = isMobile and UDim2.new(0.95, 0, 0.9, 0) or UDim2.new(0.75, 0, 0.8, 0)
		mainFrame.Size = startSize
		mainFrame.BackgroundTransparency = 0.3
		
		local frameTween = TweenService:Create(mainFrame, tweenInfo, {
			Size = endSize, 
			BackgroundTransparency = 0.05
		})
		frameTween:Play()
		frameTween.Completed:Connect(function() isAnimating = false end)
	else
		TweenService:Create(backgroundOverlay, TweenInfo.new(0.3), {BackgroundTransparency = 1}):Play()
		task.delay(0.3, function() backgroundOverlay.Visible = false end)
		
		local endSize = isMobile and UDim2.new(0.85, 0, 0.8, 0) or UDim2.new(0.65, 0, 0.7, 0)
		local frameTween = TweenService:Create(mainFrame, tweenInfoOut, {
			Size = endSize, 
			BackgroundTransparency = 0.3
		})
		frameTween:Play()
		frameTween.Completed:Connect(function()
			mainFrame.Visible = false
			isAnimating = false
		end)
	end
end


-- BUTTON HOVER EFFECTS --

-- close button turns red on hover
closeInventoryButton.MouseEnter:Connect(function()
	TweenService:Create(closeInventoryButton, TweenInfo.new(0.2), {
		BackgroundColor3 = Colors.Danger
	}):Play()
	TweenService:Create(closeButtonIcon, TweenInfo.new(0.2), {
		ImageColor3 = Colors.Text
	}):Play()
end)

closeInventoryButton.MouseLeave:Connect(function()
	TweenService:Create(closeInventoryButton, TweenInfo.new(0.2), {
		BackgroundColor3 = Colors.Secondary
	}):Play()
	TweenService:Create(closeButtonIcon, TweenInfo.new(0.2), {
		ImageColor3 = Colors.TextMuted
	}):Play()
end)

-- equip button hover
equipButton.MouseEnter:Connect(function()
	TweenService:Create(equipButton, TweenInfo.new(0.2), {
		Size = UDim2.new(0.82, 0, 0.105, 0)
	}):Play()
	local stroke = equipButton:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, TweenInfo.new(0.2), {Transparency = 0}):Play()
	end
end)

equipButton.MouseLeave:Connect(function()
	TweenService:Create(equipButton, TweenInfo.new(0.2), {
		Size = UDim2.new(0.8, 0, 0.1, 0)
	}):Play()
	local stroke = equipButton:FindFirstChildOfClass("UIStroke")
	if stroke then
		TweenService:Create(stroke, TweenInfo.new(0.2), {Transparency = 0.3}):Play()
	end
end)


-- CONNECTIONS --

equipButton.MouseButton1Click:Connect(function()
	if selectedItemId then equipRequestEvent:FireServer(selectedItemId) end
end)

-- server tells us what got equipped
equipRequestEvent.OnClientEvent:Connect(function(equippedItemId)
	currentlyEquipped = equippedItemId
	if selectedItemId then updateMainViewport(selectedItemId) end
end)

-- server gave us a new item
awardItemEvent.OnClientEvent:Connect(function(newItemId)
	print("Received new item from server: " .. newItemId)
	table.insert(playerInventory, newItemId)
	populateInventory()
end)

-- initial load from server
inventoryLoadedEvent.OnClientEvent:Connect(function(loadedInventory)
	print("Client: Received initial inventory from server.")
	playerInventory = loadedInventory
	populateInventory()
end)

-- G key toggles inventory
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.G then toggleInventory() end
end)

toggleInventoryEvent.Event:Connect(toggleInventory)
closeInventoryButton.MouseButton1Click:Connect(toggleInventory)

-- spin all the mini models in the grid
RunService.RenderStepped:Connect(function(dt)
	if not mainFrame.Visible then return end
	for _, model in ipairs(rotatingSlotModels) do
		if model and model.PrimaryPart then
			model:SetPrimaryPartCFrame(model:GetPrimaryPartCFrame() * CFrame.Angles(0, dt * 0.8, 0))
		end
	end
end)

print("InventoryController Loaded.")

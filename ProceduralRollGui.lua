
-- roll gui for the gacha system
-- shows a 3d preview of what you got with some nice animations
-- the model rotates in a viewportframe while the camera orbits around it

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local rollWeaponEvent = ReplicatedStorage:WaitForChild("RollWeaponEvent")
local itemModelsFolder = ReplicatedStorage:WaitForChild("ItemModels")
local toggleInventoryEvent = ReplicatedStorage:WaitForChild("ToggleInventoryEvent")
local startRollEvent = ReplicatedStorage:WaitForChild("StartRollEvent")
local Icons = require(ReplicatedStorage:WaitForChild("Icons"))

local isMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- state machine for the roll process
local State = {
	IDLE = "Idle",
	ROLLING = "Rolling",
	COOLDOWN = "Cooldown"
}
local currentState = State.IDLE
local isAutoRolling = false

-- viewport camera stuff
local currentModel = nil
local rotationAngle = 0
local cameraDistance = 0
local cameraHeightOffset = 0
local modelCenter = Vector3.new()

-- went with a dark blue theme, looks clean
local Colors = {
	Background = Color3.fromRGB(15, 15, 25),
	BackgroundAccent = Color3.fromRGB(25, 25, 40),
	Card = Color3.fromRGB(30, 30, 50),
	CardBorder = Color3.fromRGB(60, 60, 90),
	Primary = Color3.fromRGB(90, 120, 255),
	PrimaryGlow = Color3.fromRGB(120, 150, 255),
	Secondary = Color3.fromRGB(45, 50, 70),
	SecondaryHover = Color3.fromRGB(55, 60, 85),
	Text = Color3.fromRGB(255, 255, 255),
	TextMuted = Color3.fromRGB(160, 165, 185),
	Success = Color3.fromRGB(50, 205, 130),
	SuccessGlow = Color3.fromRGB(80, 235, 160),
}


-- GET GUI REFERENCES --
-- gui is already made in starterGui, just grab the references

local rollGui = playerGui:WaitForChild("RollGUI")
local blurEffect = game.Lighting:WaitForChild("BlurEffect")
local backgroundOverlay = rollGui:WaitForChild("BackgroundOverlay")
local resultFrame = rollGui:WaitForChild("ResultFrame")

local frameStroke = resultFrame:FindFirstChildOfClass("UIStroke")
local rarityGlow = resultFrame:WaitForChild("RarityGlow")
local glowGradient = rarityGlow:FindFirstChildOfClass("UIGradient")
local shimmerFrame = resultFrame:WaitForChild("Shimmer")

local viewportContainer = resultFrame:WaitForChild("ViewportContainer")
local viewportFrame = viewportContainer:WaitForChild("ViewportFrame")
local viewportCamera = viewportFrame:WaitForChild("Camera")

local textContainer = resultFrame:WaitForChild("TextContainer")
local weaponNameLabel = textContainer:WaitForChild("WeaponName")
local rarityNameLabel = textContainer:WaitForChild("RarityName")

local dividerLine = resultFrame:WaitForChild("Divider")

local actionButtonContainer = resultFrame:WaitForChild("ActionButtonContainer")
local actionRollButton = actionButtonContainer:WaitForChild("RollButton")
local actionAutoRollButton = actionButtonContainer:WaitForChild("AutoRollButton")
local actionInventoryButton = actionButtonContainer:WaitForChild("InventoryButton")
local actionCloseButton = actionButtonContainer:WaitForChild("CloseButton")

-- grab the text labels and icons from buttons
local rollButtonText = actionRollButton:WaitForChild("ContentHolder"):WaitForChild("ButtonText")
local rollButtonIcon = actionRollButton:WaitForChild("ContentHolder"):WaitForChild("Icon")
local autoRollButtonText = actionAutoRollButton:WaitForChild("ContentHolder"):WaitForChild("ButtonText")
local autoRollButtonIcon = actionAutoRollButton:WaitForChild("ContentHolder"):WaitForChild("Icon")

local particleContainer = resultFrame:WaitForChild("ParticleContainer")


-- HELPER FUNCTIONS --

local function createCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 12)
	corner.Parent = parent
	return corner
end


-- ANIMATIONS --

local function playShimmerAnimation()
	shimmerFrame.Position = UDim2.new(-0.3, 0, 0.5, 0)
	local shimmerTween = TweenService:Create(shimmerFrame, TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		Position = UDim2.new(1.3, 0, 0.5, 0)
	})
	shimmerTween:Play()
end

-- spawns a bunch of particles that fly outward and fade
local function createParticleBurst(color)
	local particleCount = 20
	
	for i = 1, particleCount do
		local particle = Instance.new("Frame")
		particle.Size = UDim2.new(0, math.random(4, 12), 0, math.random(4, 12))
		particle.Position = UDim2.new(0.5, 0, 0.5, 0)
		particle.AnchorPoint = Vector2.new(0.5, 0.5)
		particle.BackgroundColor3 = color
		particle.BorderSizePixel = 0
		particle.ZIndex = 15
		particle.Parent = particleContainer
		createCorner(particle, 20)
		
		local glow = Instance.new("UIStroke")
		glow.Color = color
		glow.Thickness = 2
		glow.Transparency = 0.3
		glow.Parent = particle
		
		-- spread them in a circle
		local angle = (i / particleCount) * math.pi * 2
		local distance = math.random(80, 200)
		local targetX = 0.5 + (math.cos(angle) * distance / 500)
		local targetY = 0.5 + (math.sin(angle) * distance / 400)
		
		local moveTween = TweenService:Create(particle, TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(targetX, 0, targetY, 0),
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 2, 0, 2)
		})
		moveTween:Play()
		
		moveTween.Completed:Connect(function()
			particle:Destroy()
		end)
	end
end

-- makes the background glow pulse with the rarity color
local function pulseGlow(color)
	glowGradient.Color = ColorSequence.new(color)
	rarityGlow.BackgroundTransparency = 0.6
	
	local pulseIn = TweenService:Create(rarityGlow, TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
		BackgroundTransparency = 0.3
	})
	pulseIn:Play()
	
	pulseIn.Completed:Connect(function()
		TweenService:Create(rarityGlow, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
			BackgroundTransparency = 0.5
		}):Play()
	end)
end


-- STATE MANAGEMENT --

local function setGuiState(newState)
	currentState = newState

	if newState == State.IDLE then
		actionRollButton.Active = true
		actionAutoRollButton.Active = true
		rollButtonText.Text = "ROLL"
	elseif newState == State.ROLLING then
		actionRollButton.Active = false
		actionAutoRollButton.Active = true
		rollButtonText.Text = isAutoRolling and "AUTO..." or "ROLLING..."
	elseif newState == State.COOLDOWN then
		actionRollButton.Active = false
		actionAutoRollButton.Active = true
		rollButtonText.Text = "ROLL AGAIN"
	end
end

-- handles the popup open/close animations
local function setResultFrameVisible(visible)
	local targetSize = isMobile and UDim2.new(0.95, 0, 0.85, 0) or UDim2.new(0.5, 0, 0.65, 0)

	if visible then
		resultFrame.Visible = true
		backgroundOverlay.Visible = true
		blurEffect.Enabled = true
		
		TweenService:Create(backgroundOverlay, TweenInfo.new(0.4), {BackgroundTransparency = 0.5}):Play()
		TweenService:Create(blurEffect, TweenInfo.new(0.5), {Size = 15}):Play()
		
		-- start small and off screen, then pop in
		resultFrame.Position = UDim2.new(0.5, 0, -0.5, 0)
		resultFrame.Size = UDim2.new(targetSize.X.Scale * 0.8, 0, targetSize.Y.Scale * 0.8, 0)
		resultFrame.BackgroundTransparency = 0.3
		
		TweenService:Create(resultFrame, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.5, 0, 0.5, 0),
			Size = targetSize,
			BackgroundTransparency = 0.1
		}):Play()
	else
		TweenService:Create(backgroundOverlay, TweenInfo.new(0.3), {BackgroundTransparency = 1}):Play()
		TweenService:Create(blurEffect, TweenInfo.new(0.3), {Size = 0}):Play()
		task.delay(0.3, function() 
			blurEffect.Enabled = false 
			backgroundOverlay.Visible = false
		end)

		local tween = TweenService:Create(resultFrame, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
			Position = UDim2.new(0.5, 0, 1.5, 0),
			Size = UDim2.new(targetSize.X.Scale * 0.9, 0, targetSize.Y.Scale * 0.9, 0),
			BackgroundTransparency = 0.5
		})
		tween:Play()
		tween.Completed:Connect(function()
			resultFrame.Visible = false
			rarityGlow.BackgroundTransparency = 1
		end)
	end
end

local function startNextRoll()
	if currentState == State.ROLLING or currentState == State.COOLDOWN then return end

	setGuiState(State.ROLLING)

	-- close the popup first if its already open
	if resultFrame.Visible then
		setResultFrameVisible(false)
		task.wait(0.4)
	end

	rollWeaponEvent:FireServer()
end

-- this runs when the server sends back what we rolled
local function onWeaponRolled(animationRolls)
	if currentState ~= State.ROLLING then return end

	if not animationRolls then
		warn("Roll failed on the server. Resetting GUI.")
		if isAutoRolling then
			isAutoRolling = false
			actionAutoRollButton.BackgroundColor3 = Colors.Secondary
			autoRollButtonText.Text = "AUTO"
		end

		setResultFrameVisible(false)
		setGuiState(State.IDLE)
		return
	end

	setResultFrameVisible(true)

	rarityGlow.BackgroundTransparency = 1
	frameStroke.Color = Colors.CardBorder

	-- loop through the animation sequence
	-- the last one is the real result, others are just for suspense
	for i, rollData in ipairs(animationRolls) do
		local weaponData = rollData.Weapon
		local rarityData = rollData.Rarity

		if currentModel then currentModel:Destroy(); currentModel = nil end

		weaponNameLabel.Text = weaponData.Name
		rarityNameLabel.Text = rarityData.Name or ""
		rarityNameLabel.TextColor3 = rarityData.Color or Colors.TextMuted

		-- load the 3d model into the viewport
		if weaponData.ModelName then
			local modelToClone = itemModelsFolder:FindFirstChild(weaponData.ModelName)
			if modelToClone then
				currentModel = modelToClone:Clone()

				local cframe, size = currentModel:GetBoundingBox()
				currentModel:PivotTo(cframe)
				currentModel.Parent = viewportFrame

				-- calc camera distance based on model size
				modelCenter = currentModel:GetPivot().Position
				local maxDimension = math.max(size.X, size.Y, size.Z)

				cameraDistance = maxDimension * 1.8 + 1.5
				cameraHeightOffset = maxDimension * 0.4
				rotationAngle = 0
			end
		end

		-- extra effects on the final reveal
		if i == #animationRolls then
			local finalColor = rarityData.Color or Color3.new(1, 1, 1)
			
			pulseGlow(finalColor)
			createParticleBurst(finalColor)
			playShimmerAnimation()
			
			-- color the border to match rarity
			TweenService:Create(frameStroke, TweenInfo.new(0.5), {
				Color = finalColor,
				Thickness = 4
			}):Play()
			
			TweenService:Create(dividerLine, TweenInfo.new(0.5), {
				BackgroundColor3 = finalColor
			}):Play()
			
			task.wait(0.5)
		else
			-- quick flicker through other items
			local delay = 0.05 + (i / #animationRolls) * 0.1
			task.wait(delay)
		end
	end

	setGuiState(State.COOLDOWN)

	-- small delay before you can roll again
	task.delay(1.1, function()
		setGuiState(State.IDLE)
		if isAutoRolling then
			startNextRoll()
		end
	end)
end

local function onAutoRollButtonClicked()
	isAutoRolling = not isAutoRolling

	if isAutoRolling then
		actionAutoRollButton.BackgroundColor3 = Colors.Success
		autoRollButtonText.Text = "AUTO ON"
		autoRollButtonIcon.Image = Icons.Check
		
		local stroke = actionAutoRollButton:FindFirstChildOfClass("UIStroke")
		if stroke then stroke.Color = Colors.SuccessGlow end
		
		if currentState == State.IDLE then
			startNextRoll()
		end
	else
		actionAutoRollButton.BackgroundColor3 = Colors.Secondary
		autoRollButtonText.Text = "AUTO"
		autoRollButtonIcon.Image = Icons.RotateCcw
		
		local stroke = actionAutoRollButton:FindFirstChildOfClass("UIStroke")
		if stroke then stroke.Color = Colors.SecondaryHover end
	end
end

local function onCloseButtonClicked()
	if currentState == State.ROLLING then return end

	setResultFrameVisible(false)

	if isAutoRolling then
		isAutoRolling = false
		actionAutoRollButton.BackgroundColor3 = Colors.Secondary
		autoRollButtonText.Text = "AUTO"
		autoRollButtonIcon.Image = Icons.RotateCcw
	end
	setGuiState(State.IDLE)
end


-- CONNECTIONS --

actionRollButton.MouseButton1Click:Connect(startNextRoll)
actionAutoRollButton.MouseButton1Click:Connect(onAutoRollButtonClicked)
actionCloseButton.MouseButton1Click:Connect(onCloseButtonClicked)
rollWeaponEvent.OnClientEvent:Connect(onWeaponRolled)
startRollEvent.Event:Connect(startNextRoll)

actionInventoryButton.MouseButton1Click:Connect(function()
	toggleInventoryEvent:Fire()
end)

-- rotate the model in the viewport
RunService.RenderStepped:Connect(function(deltaTime)
	if resultFrame.Visible then
		if currentModel then
			rotationAngle = rotationAngle + (deltaTime * 1.2)
			local newX = math.sin(rotationAngle) * cameraDistance
			local newZ = math.cos(rotationAngle) * cameraDistance
			local newPosition = modelCenter + Vector3.new(newX, cameraHeightOffset, newZ)
			viewportCamera.CFrame = CFrame.new(newPosition, modelCenter)
		end
	end
end)


-- melee combat system for my rng game
-- took me a while to get the camera shake feeling right, ended up using perlin noise
-- instead of random values since it feels way smoother

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local dealDamageEvent = ReplicatedStorage:WaitForChild("DealDamage")

local Tool = script.Parent
local Player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local hitbox = Tool:WaitForChild("Hitbox")

-- my animation ids, made these in moon animator
local LIGHT_ATTACK_IDS = {
	"rbxassetid://78562416755508",
	"rbxassetid://139314669605090",
	"rbxassetid://125336187234951",
	"rbxassetid://139739180966863",
	"rbxassetid://139739180966863"
}
local HEAVY_ATTACK_ID = "rbxassetid://87817038903196"
local WALK_ANIMATION_ID = "rbxassetid://79526409570143"
local IDLE_ANIMATION_ID = "rbxassetid://112721782432519"

-- tweaked these numbers to get it feeling right
local COMBO_WINDOW = 0.35 -- how long you have to chain the next hit
local ATTACK_SPEED_MULTIPLIER = 1.1
local LIGHT_ATTACK_LUNGE_SPEED = 35
local HEAVY_ATTACK_LUNGE_SPEED = 50
local LUNGE_DURATION = 0.15
local TARGET_SEARCH_DISTANCE = 40
local TARGET_SEARCH_RADIUS = 10
local TARGET_TAG = "HighlightOnHover" -- i tag all enemies with this

-- camera feel stuff - the heavy multiplier makes those hits feel way more impactful
local SWING_SWAY_INTENSITY = 0.8
local SWING_SWAY_SPEED = 12
local HIT_SHAKE_INTENSITY = 1.2
local HIT_SHAKE_DURATION = 0.25
local HEAVY_HIT_MULTIPLIER = 1.8
local CAMERA_NOISE_SCALE = 8
local CAMERA_RETURN_SPEED = 8

-- these get set when you equip the weapon
local idleAnimTrack: AnimationTrack?
local walkAnimTrack: AnimationTrack?
local heavyAttackTrack: AnimationTrack?
local gripMotor: Motor6D?
local lightAttackTracks: {[number]: AnimationTrack} = {}

-- gotta keep track of these so we can disconnect on unequip
local runningConnection: RBXScriptConnection?
local inputConnection: RBXScriptConnection?
local cameraConnection: RBXScriptConnection?
local charAddedConnection: RBXScriptConnection?
local charDiedConnection: RBXScriptConnection?
local hitConnection: RBXScriptConnection?
local comboResetCoroutine: thread?
local hitMarkerConnections: {RBXScriptConnection} = {}

local isAttacking = false
local comboCounter = 0
local hitDebounce: {[Model]: boolean} = {}

local cameraOffset = CFrame.new()
local targetCameraOffset = CFrame.new()
local swayTime = 0
local isSwinging = false
local shakeEndTime = 0
local currentShakeIntensity = 0


-- CAMERA STUFF --
-- the whole point here is making hits feel impactful without being annoying
-- perlin noise gives me that organic shake instead of looking like the camera is having a seizure

local function getNoise(seed: number, time: number, scale: number): number
	return math.noise(time * scale, seed, 0)
end

local function updateCamera(dt: number)
	local now = os.clock()
	
	-- this sway thing was inspired by how god of war does it
	-- camera slightly follows the swing arc
	if isSwinging then
		swayTime += dt * SWING_SWAY_SPEED
		local swayX = math.sin(swayTime) * SWING_SWAY_INTENSITY * 0.5
		local swayY = math.cos(swayTime * 0.7) * SWING_SWAY_INTENSITY * 0.3
		targetCameraOffset = CFrame.Angles(math.rad(swayY), math.rad(swayX), 0)
	else
		swayTime = 0
		targetCameraOffset = CFrame.new()
	end
	
	-- shake when we hit something
	if now < shakeEndTime then
		local progress = 1 - ((shakeEndTime - now) / HIT_SHAKE_DURATION)
		local falloff = (1 - progress) * (1 - progress) -- squared falloff feels punchier
		
		-- using 3 different noise samples so each axis moves independently
		-- tried using the same seed for all of them before and it looked weird
		local noiseX = getNoise(1, now, CAMERA_NOISE_SCALE) * currentShakeIntensity * falloff
		local noiseY = getNoise(2, now, CAMERA_NOISE_SCALE * 1.3) * currentShakeIntensity * falloff
		local noiseZ = getNoise(3, now, CAMERA_NOISE_SCALE * 0.8) * currentShakeIntensity * falloff * 0.3
		
		-- this gives a quick downward jolt at the moment of impact
		-- fades out fast so its more of a "punch" than a sustained shake
		local punchIntensity = math.max(0, 1 - progress * 3) * currentShakeIntensity * 0.5
		noiseY = noiseY - punchIntensity
		
		local shakeOffset = CFrame.Angles(
			math.rad(noiseX * 2),
			math.rad(noiseY * 2),
			math.rad(noiseZ)
		)
		
		targetCameraOffset = targetCameraOffset * shakeOffset
	end
	
	-- lerping instead of snapping so it doesnt look jarring
	cameraOffset = cameraOffset:Lerp(targetCameraOffset, math.min(1, dt * CAMERA_RETURN_SPEED))
	camera.CFrame = camera.CFrame * cameraOffset
end

local function triggerHitShake(isHeavy: boolean)
	shakeEndTime = os.clock() + HIT_SHAKE_DURATION
	currentShakeIntensity = HIT_SHAKE_INTENSITY * (isHeavy and HEAVY_HIT_MULTIPLIER or 1)
end

local function startSwingSway()
	isSwinging = true
	swayTime = 0
end

local function stopSwingSway()
	isSwinging = false
end


-- TARGET FINDING --
-- spherecast in the direction you're facing to find something to lock onto

local function findTarget(character: Model): Model?
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then return nil end
	
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {character}
	
	local origin = rootPart.Position
	local direction = rootPart.CFrame.LookVector * TARGET_SEARCH_DISTANCE
	local result = workspace:Spherecast(origin, TARGET_SEARCH_RADIUS, direction, params)
	
	if result and result.Instance then
		local model = result.Instance:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") and CollectionService:HasTag(model, TARGET_TAG) then
			return model
		end
	end
	return nil
end


-- LUNGE --
-- this is what makes attacks feel responsive
-- basically just throw a LinearVelocity on for a split second

local function applyLunge(character: Model, speed: number, duration: number, direction: Vector3)
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart or not speed or not direction then return end
	
	local attachment = Instance.new("Attachment")
	attachment.Parent = rootPart
	
	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.MaxForce = 50000
	linearVelocity.VectorVelocity = direction * speed
	linearVelocity.Attachment0 = attachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.Parent = rootPart
	
	task.delay(duration, function()
		if linearVelocity then linearVelocity:Destroy() end
		if attachment then attachment:Destroy() end
	end)
end


-- HITBOX --
-- pretty standard touched event with a debounce table
-- damage calc happens server side obviously

local function onHitboxTouched(otherPart: BasePart, damageType: string)
	if damageType:find("Light") and comboCounter == 0 then return end
	if not otherPart.Parent or hitDebounce[otherPart.Parent :: Model] then return end
	
	local targetHumanoid = otherPart.Parent:FindFirstChildOfClass("Humanoid")
	if targetHumanoid and targetHumanoid.Health > 0 then
		local playerHumanoid = Player.Character and Player.Character:FindFirstChildOfClass("Humanoid")
		if targetHumanoid == playerHumanoid then return end -- dont hit yourself lol
		
		hitDebounce[otherPart.Parent :: Model] = true
		dealDamageEvent:FireServer(otherPart.Parent, damageType)
	end
end

local function enableHitbox(attackType: string)
	hitDebounce = {}
	if hitbox then
		hitbox.Transparency = 1
		local damageTypeString = (attackType == "Heavy") and "HeavyAttack" or "LightAttack" .. tostring(comboCounter)
		hitConnection = hitbox.Touched:Connect(function(otherPart)
			onHitboxTouched(otherPart, damageTypeString)
		end)
	end
end

local function disableHitbox()
	if hitbox then
		hitbox.Transparency = 1
		if hitConnection then
			hitConnection:Disconnect()
			hitConnection = nil
		end
	end
end


-- COMBO STUFF --

local function resetCombo()
	if comboResetCoroutine then
		pcall(task.cancel, comboResetCoroutine)
		comboResetCoroutine = nil
	end
	comboCounter = 0
end

local function stopMovementAnimations()
	if idleAnimTrack and idleAnimTrack.IsPlaying then idleAnimTrack:Stop(0.1) end
	if walkAnimTrack and walkAnimTrack.IsPlaying then walkAnimTrack:Stop(0.1) end
end

local function updateAnimationState(speed: number)
	if isAttacking then return end
	
	if speed > 0.1 then
		if walkAnimTrack and not walkAnimTrack.IsPlaying then walkAnimTrack:Play(0.2) end
		if idleAnimTrack and idleAnimTrack.IsPlaying then idleAnimTrack:Stop(0.2) end
	else
		if idleAnimTrack and not idleAnimTrack.IsPlaying then idleAnimTrack:Play(0.2) end
		if walkAnimTrack and walkAnimTrack.IsPlaying then walkAnimTrack:Stop(0.2) end
	end
end


-- ATTACKS --

local function onLightAttack(character: Model)
	if isAttacking then return end
	
	if comboResetCoroutine then
		pcall(task.cancel, comboResetCoroutine)
		comboResetCoroutine = nil
	end
	
	comboCounter += 1
	if not lightAttackTracks[comboCounter] then
		resetCombo()
		return
	end
	
	local target = findTarget(character)
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then return end
	
	-- if theres a target nearby, lunge toward them
	local lungeDirection = if target and target.PrimaryPart 
		then (target.PrimaryPart.Position - rootPart.Position).Unit 
		else rootPart.CFrame.LookVector
	
	isAttacking = true
	startSwingSway()
	stopMovementAnimations()
	enableHitbox("Light")
	applyLunge(character, LIGHT_ATTACK_LUNGE_SPEED, LUNGE_DURATION, lungeDirection)
	
	local track = lightAttackTracks[comboCounter]
	track:Play()
	
	track.Stopped:Once(function()
		isAttacking = false
		stopSwingSway()
		disableHitbox()
		
		if comboCounter >= #lightAttackTracks then
			resetCombo()
		else
			-- give the player a window to continue the combo
			comboResetCoroutine = task.delay(COMBO_WINDOW, resetCombo)
		end
		
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			updateAnimationState(humanoid.MoveDirection.Magnitude)
		end
	end)
end

local function onHeavyAttack(character: Model)
	if isAttacking then return end
	if not heavyAttackTrack then return end
	
	local target = findTarget(character)
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then return end
	
	local lungeDirection = if target and target.PrimaryPart 
		then (target.PrimaryPart.Position - rootPart.Position).Unit 
		else rootPart.CFrame.LookVector
	
	resetCombo() -- heavy breaks your combo
	isAttacking = true
	startSwingSway()
	stopMovementAnimations()
	enableHitbox("Heavy")
	applyLunge(character, HEAVY_ATTACK_LUNGE_SPEED, LUNGE_DURATION, lungeDirection)
	
	heavyAttackTrack:Play()
	
	heavyAttackTrack.Stopped:Once(function()
		isAttacking = false
		stopSwingSway()
		disableHitbox()
		
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			updateAnimationState(humanoid.MoveDirection.Magnitude)
		end
	end)
end


-- INPUT --

local function onInputBegan(input: InputObject, gameProcessedEvent: boolean)
	if gameProcessedEvent then return end
	if Tool.Parent ~= Player.Character then return end
	
	local char = Player.Character
	if not char then return end
	
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		onLightAttack(char)
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		onHeavyAttack(char)
	end
end

local function onCharacterAdded(char: Model)
	if charDiedConnection then charDiedConnection:Disconnect() end
	
	local humanoid = char:WaitForChild("Humanoid") :: Humanoid
	charDiedConnection = humanoid.Died:Connect(function()
		resetCombo()
		stopSwingSway()
	end)
end


-- EQUIP/UNEQUIP --

local function onEquip()
	disableHitbox()
	
	local character = Player.Character or Player.CharacterAdded:Wait()
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local handle = Tool:FindFirstChild("Handle") :: BasePart?
	local rightHand = character:FindFirstChild("RightHand") :: BasePart?
	
	-- weld the sword to the hand with a motor6d
	if handle and rightHand then
		gripMotor = Instance.new("Motor6D")
		gripMotor.Name = "ToolGrip"
		gripMotor.Part0 = rightHand
		gripMotor.Part1 = handle
		gripMotor.Parent = rightHand
	end
	
	if animator then
		local idleAnim = Instance.new("Animation")
		idleAnim.AnimationId = IDLE_ANIMATION_ID
		idleAnimTrack = animator:LoadAnimation(idleAnim)
		idleAnimTrack.Looped = true
		idleAnimTrack.Priority = Enum.AnimationPriority.Idle
		idleAnim:Destroy()
		
		local walkAnim = Instance.new("Animation")
		walkAnim.AnimationId = WALK_ANIMATION_ID
		walkAnimTrack = animator:LoadAnimation(walkAnim)
		walkAnimTrack.Looped = true
		walkAnimTrack.Priority = Enum.AnimationPriority.Movement
		walkAnim:Destroy()
		
		local heavyAnim = Instance.new("Animation")
		heavyAnim.AnimationId = HEAVY_ATTACK_ID
		heavyAttackTrack = animator:LoadAnimation(heavyAnim)
		heavyAttackTrack:AdjustSpeed(ATTACK_SPEED_MULTIPLIER)
		heavyAnim:Destroy()
		
		for i, id in ipairs(LIGHT_ATTACK_IDS) do
			local anim = Instance.new("Animation")
			anim.AnimationId = id
			lightAttackTracks[i] = animator:LoadAnimation(anim)
			lightAttackTracks[i]:AdjustSpeed(ATTACK_SPEED_MULTIPLIER)
			anim:Destroy()
			
			-- i added keyframe markers called "Hit" in the animations
			-- this triggers the camera shake at exactly the right frame
			local hitMarkerConn = lightAttackTracks[i]:GetMarkerReachedSignal("Hit"):Connect(function()
				triggerHitShake(false)
			end)
			table.insert(hitMarkerConnections, hitMarkerConn)
		end
		
		local heavyHitMarkerConn = heavyAttackTrack:GetMarkerReachedSignal("Hit"):Connect(function()
			triggerHitShake(true)
		end)
		table.insert(hitMarkerConnections, heavyHitMarkerConn)
		
		runningConnection = humanoid.Running:Connect(updateAnimationState)
		updateAnimationState(humanoid.MoveDirection.Magnitude)
	end
	
	cameraConnection = RunService.RenderStepped:Connect(updateCamera)
	inputConnection = UserInputService.InputBegan:Connect(onInputBegan)
	
	if Player.Character then onCharacterAdded(Player.Character) end
	charAddedConnection = Player.CharacterAdded:Connect(onCharacterAdded)
end

local function onUnequip()
	disableHitbox()
	stopSwingSway()
	
	if runningConnection then runningConnection:Disconnect(); runningConnection = nil end
	if inputConnection then inputConnection:Disconnect(); inputConnection = nil end
	if cameraConnection then cameraConnection:Disconnect(); cameraConnection = nil end
	if charAddedConnection then charAddedConnection:Disconnect(); charAddedConnection = nil end
	if charDiedConnection then charDiedConnection:Disconnect(); charDiedConnection = nil end
	
	resetCombo()
	
	if gripMotor then gripMotor:Destroy(); gripMotor = nil end
	
	if idleAnimTrack then idleAnimTrack:Stop(); idleAnimTrack:Destroy(); idleAnimTrack = nil end
	if walkAnimTrack then walkAnimTrack:Stop(); walkAnimTrack:Destroy(); walkAnimTrack = nil end
	if heavyAttackTrack then heavyAttackTrack:Stop(); heavyAttackTrack:Destroy(); heavyAttackTrack = nil end
	
	for _, track in pairs(lightAttackTracks) do
		track:Stop()
		track:Destroy()
	end
	table.clear(lightAttackTracks)
	
	for _, conn in ipairs(hitMarkerConnections) do
		conn:Disconnect()
	end
	table.clear(hitMarkerConnections)
	
	cameraOffset = CFrame.new()
	targetCameraOffset = CFrame.new()
end

Tool.Equipped:Connect(onEquip)
Tool.Unequipped:Connect(onUnequip)


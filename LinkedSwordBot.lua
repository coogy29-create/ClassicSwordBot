local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local PlayerModule
local Controls

pcall(function()
	PlayerModule = require(LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
	Controls = PlayerModule:GetControls()
end)

local ENABLED = false
local TEAM_CHECK = true
local MAX_TARGET_DISTANCE = 120
local RETARGET_INTERVAL = 0.15
local PLAN_INTERVAL = 0.055
local PREDICTION_HORIZON = 0.5
local PREDICTION_STEP = 0.05
local OWN_REACH = 7.2
local ATTACK_RANGE = 7.6
local MIN_COMBAT_RANGE = 4.5
local MAX_COMBAT_RANGE = 8.2
local DANGER_RADIUS = 4.1
local ROOT_DANGER_RADIUS = 3.2
local ATTACK_COOLDOWN = 0.13
local ATTACK_LEAD = 0.075
local HIT_WEIGHT = 8
local INCOMING_WEIGHT = 15
local RANGE_WEIGHT = 3.5
local SIDE_WEIGHT = 2.8
local FALL_WEIGHT = 20
local MOVEMENT_CHANGE_WEIGHT = 1.1
local APPROACH_WEIGHT = 1.7
local FACE_OFFSETS = {-28, 0, 28}

local Character
local Humanoid
local Root
local CurrentTarget
local DesiredMove = Vector3.zero
local DesiredFace = Vector3.new(0, 0, -1)
local LastPlan = 0
local LastRetarget = 0
local LastAttack = 0
local HandleHistory = {}
local RootHistory = {}

local function clamp(x, a, b)
	return math.max(a, math.min(b, x))
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function unit(v)
	if v.Magnitude < 0.001 then
		return Vector3.zero
	end
	return v.Unit
end

local function rotateY(v, degrees)
	local a = math.rad(degrees)
	local c = math.cos(a)
	local s = math.sin(a)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function pointSegmentDistance(p, a, b)
	local ab = b - a
	local len = ab:Dot(ab)
	if len < 0.0001 then
		return (p - a).Magnitude
	end
	local t = clamp((p - a):Dot(ab) / len, 0, 1)
	local closest = a + ab * t
	return (p - closest).Magnitude
end

local function getCharacter(player)
	local char = player.Character
	if not char then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root or hum.Health <= 0 then
		return nil
	end
	return char, hum, root
end

local function getSwordTool(character)
	if not character then
		return nil
	end
	for _, obj in ipairs(character:GetChildren()) do
		if obj:IsA("Tool") and obj:FindFirstChild("Handle") then
			local n = string.lower(obj.Name)
			if string.find(n, "sword") or string.find(n, "linked") or string.find(n, "blade") then
				return obj
			end
		end
	end
	return nil
end

local function findSwordInBackpack()
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if not backpack then
		return nil
	end
	for _, obj in ipairs(backpack:GetChildren()) do
		if obj:IsA("Tool") and obj:FindFirstChild("Handle") then
			local n = string.lower(obj.Name)
			if string.find(n, "sword") or string.find(n, "linked") or string.find(n, "blade") then
				return obj
			end
		end
	end
	return nil
end

local function ensureSword()
	if not Character or not Humanoid then
		return nil
	end
	local equipped = getSwordTool(Character)
	if equipped then
		return equipped
	end
	local backpackSword = findSwordInBackpack()
	if backpackSword then
		Humanoid:EquipTool(backpackSword)
		return backpackSword
	end
	return nil
end

local function validEnemy(player)
	if player == LocalPlayer then
		return false
	end
	local char = getCharacter(player)
	if not char then
		return false
	end
	if TEAM_CHECK and LocalPlayer.Team ~= nil and player.Team ~= nil and LocalPlayer.Team == player.Team then
		return false
	end
	return true
end

local function acquireTarget()
	if not Root then
		return nil
	end
	local bestPlayer
	local bestDistance = MAX_TARGET_DISTANCE
	for _, player in ipairs(Players:GetPlayers()) do
		if validEnemy(player) then
			local _, _, enemyRoot = getCharacter(player)
			if enemyRoot then
				local d = flat(enemyRoot.Position - Root.Position).Magnitude
				if d < bestDistance then
					bestDistance = d
					bestPlayer = player
				end
			end
		end
	end
	return bestPlayer
end

local function updateHistory(key, position, storage)
	local now = os.clock()
	local old = storage[key]
	local velocity = Vector3.zero
	if old then
		local dt = now - old.Time
		if dt > 0.001 and dt < 0.5 then
			velocity = (position - old.Position) / dt
			if velocity.Magnitude > 150 then
				velocity = velocity.Unit * 150
			end
		end
	end
	storage[key] = {Position = position, Time = now, Velocity = velocity}
	return velocity
end

local function getEnemyState(player)
	local char, hum, enemyRoot = getCharacter(player)
	if not char then
		return nil
	end
	local rootVelocity = updateHistory(player, enemyRoot.Position, RootHistory)
	local sword = getSwordTool(char)
	local handle
	local handleVelocity = Vector3.zero
	if sword then
		handle = sword:FindFirstChild("Handle")
		if handle then
			handleVelocity = updateHistory(player, handle.Position, HandleHistory)
		end
	end
	return {
		Player = player,
		Character = char,
		Humanoid = hum,
		Root = enemyRoot,
		RootVelocity = rootVelocity,
		Sword = sword,
		Handle = handle,
		HandleVelocity = handleVelocity
	}
end

local function floorSafe(position, enemyCharacter)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	if Character then
		table.insert(ignore, Character)
	end
	if enemyCharacter then
		table.insert(ignore, enemyCharacter)
	end
	params.FilterDescendantsInstances = ignore
	local result = Workspace:Raycast(position + Vector3.new(0, 3, 0), Vector3.new(0, -10, 0), params)
	return result ~= nil
end

local function calculateThreat(botPosition, enemyPosition, enemyHandlePosition, enemyHandleFuture)
	local threat = 0
	if enemyHandlePosition and enemyHandleFuture then
		local swordDistance = pointSegmentDistance(
			botPosition + Vector3.new(0, 1.5, 0),
			enemyHandlePosition,
			enemyHandleFuture
		)
		local swordThreat = clamp((DANGER_RADIUS - swordDistance) / DANGER_RADIUS, 0, 1)
		threat = math.max(threat, swordThreat)
	end
	local rootDistance = flat(botPosition - enemyPosition).Magnitude
	local bodyThreat = clamp((ROOT_DANGER_RADIUS - rootDistance) / ROOT_DANGER_RADIUS, 0, 1)
	threat = math.max(threat, bodyThreat * 0.65)
	return threat
end

local function calculateHitChance(botPosition, enemyPosition, faceDirection)
	local chest = enemyPosition + Vector3.new(0, 1.5, 0)
	local swordStart = botPosition + Vector3.new(0, 1.6, 0)
	local swordEnd = swordStart + faceDirection * OWN_REACH
	local distance = pointSegmentDistance(chest, swordStart, swordEnd)
	return clamp(1 - distance / 3, 0, 1)
end

local MOVE_ANGLES = {0, 45, 90, 135, 180, 225, 270, 315}

local function plan(enemy)
	if not Root or not Humanoid then
		return Vector3.zero, DesiredFace
	end

	local botPosition = Root.Position
	local enemyPosition = enemy.Root.Position
	local towardEnemy = unit(flat(enemyPosition - botPosition))
	if towardEnemy.Magnitude < 0.001 then
		return Vector3.zero, DesiredFace
	end

	local speed = Humanoid.WalkSpeed
	local closingVelocity = flat(enemy.RootVelocity - Root.AssemblyLinearVelocity)
	local closingSpeed = -closingVelocity:Dot(towardEnemy)
	local desiredDistance = clamp(6.5 + closingSpeed * 0.035, MIN_COMBAT_RANGE, MAX_COMBAT_RANGE)

	local moveOptions = {
		{Direction = Vector3.zero, FallRisk = 0}
	}

	for _, angle in ipairs(MOVE_ANGLES) do
		local dir = rotateY(towardEnemy, angle)
		local futurePosition = botPosition + dir * speed * PREDICTION_HORIZON
		table.insert(moveOptions, {
			Direction = dir,
			FallRisk = floorSafe(futurePosition, enemy.Character) and 0 or 1
		})
	end

	local bestScore = -math.huge
	local bestMove = Vector3.zero
	local bestFace = towardEnemy

	for _, moveOption in ipairs(moveOptions) do
		for _, faceOffset in ipairs(FACE_OFFSETS) do
			local totalThreat = 0
			local maxThreat = 0
			local hitChance = 0
			local rangeScore = 0
			local sideScore = 0
			local approachScore = 0
			local steps = 0

			for t = PREDICTION_STEP, PREDICTION_HORIZON, PREDICTION_STEP do
				steps += 1
				local botFuture = botPosition + moveOption.Direction * speed * t
				local enemyFuture = enemyPosition + enemy.RootVelocity * t
				local directionToFutureEnemy = unit(flat(enemyFuture - botFuture))
				if directionToFutureEnemy.Magnitude < 0.001 then
					directionToFutureEnemy = towardEnemy
				end
				local faceDirection = rotateY(directionToFutureEnemy, faceOffset)

				local handleCurrent
				local handleFuture
				if enemy.Handle then
					handleCurrent = enemy.Handle.Position + enemy.RootVelocity * t * 0.25
					handleFuture = handleCurrent + enemy.HandleVelocity * PREDICTION_STEP
				end

				local threat = calculateThreat(botFuture, enemyFuture, handleCurrent, handleFuture)
				totalThreat += threat
				maxThreat = math.max(maxThreat, threat)
				hitChance = math.max(hitChance, calculateHitChance(botFuture, enemyFuture, faceDirection))

				local distance = flat(enemyFuture - botFuture).Magnitude
				rangeScore += clamp(1 - math.abs(distance - desiredDistance) / 4, 0, 1)

				local enemyLook = unit(flat(enemy.Root.CFrame.LookVector))
				local enemyToBot = unit(flat(botFuture - enemyFuture))
				if enemyLook.Magnitude > 0 and enemyToBot.Magnitude > 0 then
					sideScore += clamp(-enemyLook:Dot(enemyToBot), 0, 1)
				end

				if distance > desiredDistance then
					approachScore += math.max(moveOption.Direction:Dot(directionToFutureEnemy), 0)
				end
			end

			steps = math.max(steps, 1)
			totalThreat /= steps
			rangeScore /= steps
			sideScore /= steps
			approachScore /= steps

			local changeCost = 0
			if DesiredMove.Magnitude > 0 and moveOption.Direction.Magnitude > 0 then
				changeCost = clamp(1 - DesiredMove.Unit:Dot(moveOption.Direction.Unit), 0, 2) / 2
			end

			local currentDistance = flat(enemyPosition - botPosition).Magnitude
			local farApproachBonus = 0

			if currentDistance > MAX_COMBAT_RANGE + 1 then
				farApproachBonus = math.max(
					moveOption.Direction:Dot(towardEnemy),
					0
				) * 8
			end

			local score =
				hitChance * HIT_WEIGHT
				- totalThreat * INCOMING_WEIGHT
				- maxThreat * INCOMING_WEIGHT * 0.65
				+ rangeScore * RANGE_WEIGHT
				+ sideScore * SIDE_WEIGHT
				+ approachScore * APPROACH_WEIGHT
				+ farApproachBonus
				- moveOption.FallRisk * FALL_WEIGHT
				- changeCost * MOVEMENT_CHANGE_WEIGHT

			if score > bestScore then
				bestScore = score
				bestMove = moveOption.Direction
				local predictedEnemy = enemyPosition + enemy.RootVelocity * 0.12
				local face = unit(flat(predictedEnemy - botPosition))
				bestFace = rotateY(face, faceOffset)
			end
		end
	end

	return bestMove, bestFace
end

local function currentIncomingThreat(enemy)
	if not Root then
		return 1
	end
	if not enemy.Handle then
		return 0
	end
	local future = enemy.Handle.Position + enemy.HandleVelocity * 0.12
	return calculateThreat(Root.Position, enemy.Root.Position, enemy.Handle.Position, future)
end

local function tryAttack(enemy)
	local now = os.clock()
	if now - LastAttack < ATTACK_COOLDOWN then
		return
	end

	local sword = ensureSword()
	if not sword then
		return
	end

	local enemyFuture = enemy.Root.Position + enemy.RootVelocity * ATTACK_LEAD
	local delta = flat(enemyFuture - Root.Position)
	local distance = delta.Magnitude
	if distance > ATTACK_RANGE or distance < 0.1 then
		return
	end

	local facing = unit(flat(Root.CFrame.LookVector))
	local direction = unit(delta)
	if facing:Dot(direction) < 0.32 then
		return
	end

	local threat = currentIncomingThreat(enemy)
	if threat > 0.72 then
		return
	end

	local hitChance = calculateHitChance(Root.Position, enemyFuture, facing)
	if hitChance < 0.42 then
		return
	end

	LastAttack = now
	sword:Activate()
end

local function stopMovement()
	DesiredMove = Vector3.zero
	if Humanoid then
		Humanoid:Move(Vector3.zero, false)
	end
end

local function setBotControl(active)
	if Controls then
		pcall(function()
			if active then
				Controls:Disable()
			else
				Controls:Enable()
			end
		end)
	end
end

local function setupCharacter(char)
	Character = char
	Humanoid = char:WaitForChild("Humanoid")
	Root = char:WaitForChild("HumanoidRootPart")
	Humanoid.AutoRotate = false
	DesiredMove = Vector3.zero
	DesiredFace = flat(Root.CFrame.LookVector)
	task.defer(function()
		task.wait(0.3)
		ensureSword()
	end)
end

if LocalPlayer.Character then
	setupCharacter(LocalPlayer.Character)
end

LocalPlayer.CharacterAdded:Connect(setupCharacter)

local gui = Instance.new("ScreenGui")
gui.Name = "LinkedSwordBot"
gui.ResetOnSpawn = false
gui.Parent = PlayerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(170, 82)
frame.Position = UDim2.new(0.5, -85, 0.78, 0)
frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
frame.BackgroundTransparency = 0.12
frame.Active = true
frame.Draggable = true
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 12)
corner.Parent = frame

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.new(1, -12, 0, 42)
toggle.Position = UDim2.fromOffset(6, 6)
toggle.Text = "SWORD BOT: OFF"
toggle.TextScaled = true
toggle.Font = Enum.Font.GothamBold
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
toggle.Parent = frame

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 9)
toggleCorner.Parent = toggle

local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(1, -12, 0, 24)
targetLabel.Position = UDim2.fromOffset(6, 52)
targetLabel.BackgroundTransparency = 1
targetLabel.Text = "TARGET: NONE"
targetLabel.TextScaled = true
targetLabel.Font = Enum.Font.Gotham
targetLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
targetLabel.Parent = frame

toggle.MouseButton1Click:Connect(function()
	ENABLED = not ENABLED
	if ENABLED then
		toggle.Text = "SWORD BOT: ON"
		toggle.BackgroundColor3 = Color3.fromRGB(35, 125, 65)
		if Humanoid then
			Humanoid.AutoRotate = false
		end
		setBotControl(true)
		ensureSword()
	else
		toggle.Text = "SWORD BOT: OFF"
		toggle.BackgroundColor3 = Color3.fromRGB(55, 55, 55)
		CurrentTarget = nil
		targetLabel.Text = "TARGET: NONE"
		stopMovement()
		setBotControl(false)
		if Humanoid then
			Humanoid.AutoRotate = true
		end
	end
end)

RunService:BindToRenderStep(
	"LinkedSwordBotMovement",
	Enum.RenderPriority.Character.Value + 10,
	function()
		if not ENABLED or not Character or not Humanoid or not Root or Humanoid.Health <= 0 then
			return
		end

		if DesiredMove.Magnitude > 0.001 then
			Humanoid:Move(DesiredMove.Unit, false)
		else
			Humanoid:Move(Vector3.zero, false)
		end

		if DesiredFace.Magnitude > 0.001 then
			local position = Root.Position
			local look = Vector3.new(DesiredFace.X, 0, DesiredFace.Z)
			if look.Magnitude > 0.001 then
				Root.CFrame = CFrame.lookAt(position, position + look.Unit, Vector3.yAxis)
			end
		end
	end
)

RunService.Heartbeat:Connect(function()
	if not ENABLED or not Character or not Humanoid or not Root or Humanoid.Health <= 0 then
		return
	end

	local now = os.clock()

	if now - LastRetarget >= RETARGET_INTERVAL then
		LastRetarget = now
		if not CurrentTarget or not validEnemy(CurrentTarget) then
			CurrentTarget = acquireTarget()
		else
			local _, _, enemyRoot = getCharacter(CurrentTarget)
			if not enemyRoot or flat(enemyRoot.Position - Root.Position).Magnitude > MAX_TARGET_DISTANCE then
				CurrentTarget = acquireTarget()
			end
		end
	end

	if not CurrentTarget then
		targetLabel.Text = "TARGET: NONE"
		stopMovement()
		return
	end

	local enemy = getEnemyState(CurrentTarget)
	if not enemy then
		CurrentTarget = nil
		stopMovement()
		return
	end

	targetLabel.Text = "TARGET: " .. CurrentTarget.Name

	if now - LastPlan >= PLAN_INTERVAL then
		LastPlan = now
		DesiredMove, DesiredFace = plan(enemy)
	end

	tryAttack(enemy)
end)


Players.PlayerRemoving:Connect(function(player)
	if CurrentTarget == player then
		CurrentTarget = nil
	end
end)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local ENABLED = true
local TEAM_CHECK = true
local MAX_TARGET_DISTANCE = 140

local RETARGET_INTERVAL = 0.10
local TARGET_LOCK_BONUS = 8

local CHASE_DISTANCE = 10.5
local PRESSURE_DISTANCE = 8.2
local IDEAL_DISTANCE = 6.6
local PANIC_DISTANCE = 4.4

local SWORD_DANGER_RADIUS = 4.2
local SWORD_FAST_SPEED = 18
local EVADE_HOLD = 0.18

local SLASH_RANGE = 7.4
local SLASH_INTERVAL = 0.38
local LUNGE_MIN_RANGE = 7.2
local LUNGE_MAX_RANGE = 10.8
local LUNGE_INTERVAL = 0.95
local LUNGE_DOUBLE_TAP = 0.12

local FACE_LEAD = 0.10
local ATTACK_LEAD = 0.12

local Character
local Humanoid
local Root
local Controls

local CurrentTarget
local CurrentState = "SEARCH"
local MoveDirection = Vector3.zero
local FaceDirection = Vector3.new(0, 0, -1)

local LastRetarget = 0
local LastSlash = 0
local LastLunge = 0
local LastEvade = 0
local LastSwordActivate = 0
local LungeToken = 0

local Histories = {}
local OrbitSign = 1
local LastOrbitChange = 0

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function unit(v)
	if v.Magnitude < 0.001 then
		return Vector3.zero
	end
	return v.Unit
end

local function clamp(x, a, b)
	return math.max(a, math.min(b, x))
end

local function rightOf(v)
	return Vector3.new(-v.Z, 0, v.X)
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

local function isEnemy(player)
	if player == LocalPlayer then
		return false
	end

	local char = getCharacter(player)
	if not char then
		return false
	end

	if TEAM_CHECK and LocalPlayer.Team and player.Team and LocalPlayer.Team == player.Team then
		return false
	end

	return true
end

local function getTool(character)
	if not character then
		return nil
	end

	local fallback

	for _, obj in ipairs(character:GetChildren()) do
		if obj:IsA("Tool") and obj:FindFirstChild("Handle") then
			fallback = fallback or obj

			local n = string.lower(obj.Name)
			if string.find(n, "sword")
				or string.find(n, "linked")
				or string.find(n, "blade")
				or string.find(n, "katana") then

				return obj
			end
		end
	end

	return fallback
end

local function getBackpackTool()
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if not backpack then
		return nil
	end

	local fallback

	for _, obj in ipairs(backpack:GetChildren()) do
		if obj:IsA("Tool") and obj:FindFirstChild("Handle") then
			fallback = fallback or obj

			local n = string.lower(obj.Name)
			if string.find(n, "sword")
				or string.find(n, "linked")
				or string.find(n, "blade")
				or string.find(n, "katana") then

				return obj
			end
		end
	end

	return fallback
end

local function ensureTool()
	if not Character or not Humanoid then
		return nil
	end

	local tool = getTool(Character)
	if tool then
		return tool
	end

	tool = getBackpackTool()

	if tool then
		Humanoid:EquipTool(tool)
		task.wait()
		return getTool(Character) or tool
	end

	return nil
end

local function updateHistory(player, root, handle)
	local now = os.clock()
	local h = Histories[player]

	if not h then
		h = {
			Time = now,
			RootPos = root.Position,
			RootVel = Vector3.zero,
			HandlePos = handle and handle.Position or nil,
			HandleVel = Vector3.zero
		}
		Histories[player] = h
		return h
	end

	local dt = now - h.Time

	if dt > 0.002 and dt < 0.35 then
		local rootVel = (root.Position - h.RootPos) / dt
		if rootVel.Magnitude > 100 then
			rootVel = rootVel.Unit * 100
		end
		h.RootVel = h.RootVel:Lerp(rootVel, 0.55)

		if handle then
			if h.HandlePos then
				local hv = (handle.Position - h.HandlePos) / dt
				if hv.Magnitude > 180 then
					hv = hv.Unit * 180
				end
				h.HandleVel = h.HandleVel:Lerp(hv, 0.62)
			end
			h.HandlePos = handle.Position
		else
			h.HandlePos = nil
			h.HandleVel = Vector3.zero
		end
	end

	h.Time = now
	h.RootPos = root.Position

	return h
end

local function getEnemyState(player)
	local char, hum, root = getCharacter(player)
	if not char then
		return nil
	end

	local sword = getTool(char)
	local handle = sword and sword:FindFirstChild("Handle") or nil
	local history = updateHistory(player, root, handle)

	return {
		Player = player,
		Character = char,
		Humanoid = hum,
		Root = root,
		Sword = sword,
		Handle = handle,
		Velocity = history.RootVel,
		HandleVelocity = history.HandleVel
	}
end

local function targetDistance(player)
	if not Root then
		return math.huge
	end

	local _, _, enemyRoot = getCharacter(player)
	if not enemyRoot then
		return math.huge
	end

	return flat(enemyRoot.Position - Root.Position).Magnitude
end

local function acquireTarget()
	if not Root then
		return nil
	end

	local best
	local bestScore = math.huge

	for _, player in ipairs(Players:GetPlayers()) do
		if isEnemy(player) then
			local d = targetDistance(player)

			if d <= MAX_TARGET_DISTANCE then
				local score = d

				if player == CurrentTarget then
					score -= TARGET_LOCK_BONUS
				end

				if score < bestScore then
					bestScore = score
					best = player
				end
			end
		end
	end

	return best
end

local function rayFloor(position, enemyCharacter)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = enemyCharacter and {Character, enemyCharacter} or {Character}

	return Workspace:Raycast(
		position + Vector3.new(0, 3, 0),
		Vector3.new(0, -9, 0),
		params
	)
end

local function directionSafe(dir, enemyCharacter, distance)
	if dir.Magnitude < 0.001 then
		return true
	end

	local probe = Root.Position + dir.Unit * (distance or 4.5)
	return rayFloor(probe, enemyCharacter) ~= nil
end

local function chooseSafeDirection(primary, enemyCharacter)
	if primary.Magnitude < 0.001 then
		return Vector3.zero
	end

	local p = primary.Unit

	if directionSafe(p, enemyCharacter, 4.5) then
		return p
	end

	local r = rightOf(p)
	local candidates = {
		unit(p + r * 0.8),
		unit(p - r * 0.8),
		r,
		-r,
		-p
	}

	for _, dir in ipairs(candidates) do
		if directionSafe(dir, enemyCharacter, 4.2) then
			return dir
		end
	end

	return Vector3.zero
end

local function swordThreat(enemy)
	if not Root or not enemy.Handle then
		return 0, Vector3.zero, 0
	end

	local handlePos = enemy.Handle.Position
	local handleVel = enemy.HandleVelocity
	local bodyPos = Root.Position + Vector3.new(0, 1.5, 0)

	local futureHandle = handlePos + handleVel * 0.13
	local seg = futureHandle - handlePos
	local len2 = seg:Dot(seg)

	local closest

	if len2 < 0.0001 then
		closest = handlePos
	else
		local t = clamp((bodyPos - handlePos):Dot(seg) / len2, 0, 1)
		closest = handlePos + seg * t
	end

	local d = (bodyPos - closest).Magnitude
	local threat = clamp((SWORD_DANGER_RADIUS - d) / SWORD_DANGER_RADIUS, 0, 1)
	local speed = handleVel.Magnitude

	if speed > SWORD_FAST_SPEED then
		threat = clamp(threat + 0.22, 0, 1)
	end

	return threat, unit(flat(bodyPos - closest)), speed
end

local function chooseOrbitSign(enemy)
	local now = os.clock()

	if now - LastOrbitChange < 0.28 then
		return OrbitSign
	end

	local toEnemy = unit(flat(enemy.Root.Position - Root.Position))
	if toEnemy.Magnitude < 0.001 then
		return OrbitSign
	end

	local side = rightOf(toEnemy)
	local threat, awayFromBlade = swordThreat(enemy)

	if threat > 0.08 and awayFromBlade.Magnitude > 0 then
		local rightScore = side:Dot(awayFromBlade)
		local leftScore = (-side):Dot(awayFromBlade)

		if math.abs(rightScore - leftScore) > 0.08 then
			OrbitSign = rightScore > leftScore and 1 or -1
			LastOrbitChange = now
			return OrbitSign
		end
	end

	local enemyLook = unit(flat(enemy.Root.CFrame.LookVector))
	local enemyToUs = unit(flat(Root.Position - enemy.Root.Position))

	if enemyLook.Magnitude > 0 and enemyToUs.Magnitude > 0 then
		local cross = enemyLook.X * enemyToUs.Z - enemyLook.Z * enemyToUs.X

		if math.abs(cross) > 0.12 then
			OrbitSign = cross > 0 and 1 or -1
			LastOrbitChange = now
		end
	end

	return OrbitSign
end

local function computeMovement(enemy)
	local delta = flat(enemy.Root.Position - Root.Position)
	local distance = delta.Magnitude

	if distance < 0.001 then
		return Vector3.zero, "OVERLAP"
	end

	local toward = delta.Unit
	local side = rightOf(toward) * chooseOrbitSign(enemy)

	local threat, bladeAway, bladeSpeed = swordThreat(enemy)

	if threat >= 0.34 or (bladeSpeed > 28 and distance < 8.5) then
		LastEvade = os.clock()

		local evade = unit(
			(-toward * 0.55)
			+ (side * 1.15)
			+ (bladeAway * 1.25)
		)

		return chooseSafeDirection(evade, enemy.Character), "EVADE"
	end

	if os.clock() - LastEvade < EVADE_HOLD then
		local evade = unit(-toward * 0.45 + side * 1.2 + bladeAway * 0.7)
		return chooseSafeDirection(evade, enemy.Character), "EVADE"
	end

	if distance > CHASE_DISTANCE then
		local leadPos = enemy.Root.Position + enemy.Velocity * 0.16
		local chase = unit(flat(leadPos - Root.Position) + side * 1.2)
		return chooseSafeDirection(chase, enemy.Character), "CHASE"
	end

	if distance > PRESSURE_DISTANCE then
		local approachStrength = clamp((distance - PRESSURE_DISTANCE) / 2.3, 0.2, 1)
		local pressure = unit(toward * approachStrength + side * 0.80)
		return chooseSafeDirection(pressure, enemy.Character), "PRESSURE"
	end

	if distance < PANIC_DISTANCE then
		local retreat = unit(-toward * 1.2 + side * 0.85 + bladeAway * 0.5)
		return chooseSafeDirection(retreat, enemy.Character), "RETREAT"
	end

	local radialError = distance - IDEAL_DISTANCE
	local radial = toward * clamp(radialError / 2.0, -0.75, 0.75)

	local orbitStrength = 1.05

	if threat > 0.15 then
		orbitStrength = 1.35
	end

	local orbit = unit(side * orbitStrength + radial)
	return chooseSafeDirection(orbit, enemy.Character), "ORBIT"
end

local function faceEnemy(enemy)
	local predicted = enemy.Root.Position + enemy.Velocity * FACE_LEAD
	return unit(flat(predicted - Root.Position))
end

local function canAttack(enemy, minRange, maxRange, dotNeed)
	if not Root then
		return false, math.huge, 1
	end

	local predicted = enemy.Root.Position + enemy.Velocity * ATTACK_LEAD
	local delta = flat(predicted - Root.Position)
	local distance = delta.Magnitude

	if distance < minRange or distance > maxRange then
		return false, distance, 1
	end

	local face = unit(flat(Root.CFrame.LookVector))
	local toward = unit(delta)

	if face.Magnitude < 0.001 or toward.Magnitude < 0.001 then
		return false, distance, 1
	end

	if face:Dot(toward) < dotNeed then
		return false, distance, 1
	end

	local threat = swordThreat(enemy)

	return threat < 0.72, distance, threat
end

local function activateTool(tool)
	if not tool then
		return
	end

	local now = os.clock()

	if now - LastSwordActivate < 0.045 then
		return
	end

	LastSwordActivate = now
	pcall(function()
		tool:Activate()
	end)
end

local function trySlash(enemy)
	local now = os.clock()

	if now - LastSlash < SLASH_INTERVAL then
		return false
	end

	local ok, distance, threat = canAttack(enemy, 0, SLASH_RANGE, 0.56)

	if not ok then
		return false
	end

	if threat > 0.55 and distance > 5.2 then
		return false
	end

	local tool = ensureTool()

	if not tool then
		return false
	end

	LastSlash = now
	activateTool(tool)
	return true
end

local function tryLunge(enemy)
	local now = os.clock()

	if now - LastLunge < LUNGE_INTERVAL then
		return false
	end

	local ok, distance, threat = canAttack(enemy, LUNGE_MIN_RANGE, LUNGE_MAX_RANGE, 0.78)

	if not ok or threat > 0.40 then
		return false
	end

	local toward = unit(flat(enemy.Root.Position - Root.Position))
	local closing = flat(enemy.Velocity - Root.AssemblyLinearVelocity):Dot(-toward)

	if distance > 9.6 and closing < -2 then
		return false
	end

	local tool = ensureTool()

	if not tool then
		return false
	end

	LastLunge = now
	LungeToken += 1
	local token = LungeToken

	activateTool(tool)

	task.delay(LUNGE_DOUBLE_TAP, function()
		if token ~= LungeToken or not ENABLED then
			return
		end

		if not CurrentTarget or CurrentTarget ~= enemy.Player then
			return
		end

		local fresh = getEnemyState(enemy.Player)
		if not fresh then
			return
		end

		local stillOkay = canAttack(fresh, LUNGE_MIN_RANGE - 0.8, LUNGE_MAX_RANGE + 0.8, 0.60)

		if stillOkay then
			activateTool(tool)
		end
	end)

	return true
end

local function combatTick(enemy)
	local distance = flat(enemy.Root.Position - Root.Position).Magnitude

	if distance >= LUNGE_MIN_RANGE and distance <= LUNGE_MAX_RANGE then
		if tryLunge(enemy) then
			return
		end
	end

	trySlash(enemy)
end

local function setupControls()
	pcall(function()
		local PlayerModule = require(
			LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")
		)
		Controls = PlayerModule:GetControls()
	end)
end

local function setControlsEnabled(enabled)
	if not Controls then
		setupControls()
	end

	if Controls then
		pcall(function()
			if enabled then
				Controls:Enable()
			else
				Controls:Disable()
			end
		end)
	end
end

local function setupCharacter(char)
	Character = char
	Humanoid = char:WaitForChild("Humanoid")
	Root = char:WaitForChild("HumanoidRootPart")

	Humanoid.AutoRotate = false

	if ENABLED then
		setControlsEnabled(false)
	end

	task.defer(function()
		task.wait(0.25)
		if ENABLED then
			ensureTool()
		end
	end)
end

setupControls()

if LocalPlayer.Character then
	setupCharacter(LocalPlayer.Character)
end

LocalPlayer.CharacterAdded:Connect(function(char)
	CurrentTarget = nil
	MoveDirection = Vector3.zero
	CurrentState = "SEARCH"
	setupCharacter(char)
end)

Players.PlayerRemoving:Connect(function(player)
	Histories[player] = nil

	if CurrentTarget == player then
		CurrentTarget = nil
	end
end)

local gui = Instance.new("ScreenGui")
gui.Name = "LinkedSwordBotV2"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.Parent = PlayerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(190, 100)
frame.Position = UDim2.new(0.5, -95, 0.78, 0)
frame.BackgroundColor3 = Color3.fromRGB(22, 22, 22)
frame.BackgroundTransparency = 0.10
frame.Active = true
frame.Draggable = true
frame.Parent = gui

local frameCorner = Instance.new("UICorner")
frameCorner.CornerRadius = UDim.new(0, 12)
frameCorner.Parent = frame

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.new(1, -12, 0, 44)
toggle.Position = UDim2.fromOffset(6, 6)
toggle.TextScaled = true
toggle.Font = Enum.Font.GothamBold
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.Parent = frame

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 9)
toggleCorner.Parent = toggle

local targetLabel = Instance.new("TextLabel")
targetLabel.Size = UDim2.new(1, -12, 0, 20)
targetLabel.Position = UDim2.fromOffset(6, 53)
targetLabel.BackgroundTransparency = 1
targetLabel.TextScaled = true
targetLabel.Font = Enum.Font.Gotham
targetLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
targetLabel.Parent = frame

local stateLabel = Instance.new("TextLabel")
stateLabel.Size = UDim2.new(1, -12, 0, 19)
stateLabel.Position = UDim2.fromOffset(6, 75)
stateLabel.BackgroundTransparency = 1
stateLabel.TextScaled = true
stateLabel.Font = Enum.Font.Gotham
stateLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
stateLabel.Parent = frame

local function refreshToggle()
	if ENABLED then
		toggle.Text = "SWORD BOT: ON"
		toggle.BackgroundColor3 = Color3.fromRGB(38, 126, 68)
	else
		toggle.Text = "SWORD BOT: OFF"
		toggle.BackgroundColor3 = Color3.fromRGB(58, 58, 58)
	end
end

refreshToggle()

toggle.MouseButton1Click:Connect(function()
	ENABLED = not ENABLED
	refreshToggle()

	if ENABLED then
		setControlsEnabled(false)

		if Humanoid then
			Humanoid.AutoRotate = false
		end

		ensureTool()
	else
		LungeToken += 1
		CurrentTarget = nil
		MoveDirection = Vector3.zero
		CurrentState = "OFF"

		if Humanoid then
			Humanoid:Move(Vector3.zero, false)
			Humanoid.AutoRotate = true
		end

		setControlsEnabled(true)
	end
end)

RunService:BindToRenderStep(
	"LinkedSwordBotV2Movement",
	Enum.RenderPriority.Character.Value + 25,
	function()
		if not ENABLED or not Character or not Humanoid or not Root or Humanoid.Health <= 0 then
			return
		end

		if MoveDirection.Magnitude > 0.001 then
			Humanoid:Move(MoveDirection.Unit, false)
		else
			Humanoid:Move(Vector3.zero, false)
		end

		if FaceDirection.Magnitude > 0.001 then
			local pos = Root.Position
			local face = flat(FaceDirection)

			if face.Magnitude > 0.001 then
				Root.CFrame = CFrame.lookAt(
					pos,
					pos + face.Unit,
					Vector3.yAxis
				)
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
		CurrentTarget = acquireTarget()
	end

	if not CurrentTarget then
		MoveDirection = Vector3.zero
		CurrentState = "SEARCH"
		targetLabel.Text = "TARGET: NONE"
		stateLabel.Text = "STATE: SEARCH"
		return
	end

	local enemy = getEnemyState(CurrentTarget)

	if not enemy then
		CurrentTarget = nil
		MoveDirection = Vector3.zero
		return
	end

	local distance = flat(enemy.Root.Position - Root.Position).Magnitude

	if distance > MAX_TARGET_DISTANCE then
		CurrentTarget = nil
		MoveDirection = Vector3.zero
		return
	end

	FaceDirection = faceEnemy(enemy)
	MoveDirection, CurrentState = computeMovement(enemy)

	targetLabel.Text = "TARGET: " .. CurrentTarget.Name .. "  " .. string.format("%.1f", distance)
	stateLabel.Text = "STATE: " .. CurrentState

	combatTick(enemy)
end)

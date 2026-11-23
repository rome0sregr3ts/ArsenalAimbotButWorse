--[[
  AimAssistTest v2 - LocalScript for YOUR OWN Roblox Studio test place.
  Put in: StarterPlayer > StarterPlayerScripts (as a LocalScript)

  Targets: other players' characters, plus any Model tagged "AimTarget"
  (CollectionService) - tag a few dummy rigs to test solo.

  Defaults:
    Aim (hold)   : Right Mouse
    Aim toggle   : Q
    Show/hide UI : RightShift
  All three can be rebound from the UI.

  Window: drag the title bar, "-" minimizes, "X" closes, drag the bottom-right
  grip to resize. The "Aim UI" chip (bottom-left) always reopens it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local playerGui = player:WaitForChild("PlayerGui")

local STEP_NAME = "AimAssistTest"

-- clean up a previous copy (prevents "already bound" errors / duplicate UIs)
pcall(function() RunService:UnbindFromRenderStep(STEP_NAME) end)
local oldGui = playerGui:FindFirstChild("AimAssistTestUI")
if oldGui then oldGui:Destroy() end

---------------------------------------------------------------- settings
local settings = {
	Enabled = true,         -- master on/off (toggled by the toggle key / button)
	StickyLock = true,      -- keep the same target while aim key is held
	WallCheck = true,       -- ignore targets behind walls
	TeamCheck = true,       -- ignore teammates (players on your Team)
	RoleFilter = true,      -- use ROLE_RULES below (e.g. Criminal -> police only, never prisoners)
	PoliceOnly = false,     -- force police-only targeting no matter which team you're on
	ShowFOV = true,
	FOV = 220,              -- radius in pixels (was 150)
	Smoothness = 0.30,      -- 0 = instant snap, 0.95 = very slow (was 0.6)
	TargetMode = "Head",    -- "Head" or "Body"
	Strength = 1.0,         -- 0.05..1, scales how hard the camera is pulled
	Prediction = 0.06,      -- seconds of target velocity to lead by (0 = off)
	LockAnyDistance = true, -- once locked, stay locked outside the FOV / off-screen
	GunTweaks = true,       -- zero spread/recoil values on your guns (your own copy only; applies when a gun is picked up/equipped)
	NoRecoil = true,        -- cancel upward camera kick while firing (hold LMB)
	RecoilComp = 1.0,       -- 0..1 how much of the kick is cancelled
	ShowDebug = true,       -- on-screen diagnostics strip (turn off for the video)
	AlwaysAim = false,      -- hipfire mode: active without holding the aim key
	UIScale = 1.0,          -- menu size
}

local binds = {
	Aim = Enum.UserInputType.MouseButton2,
	Toggle = Enum.KeyCode.Q,
	Menu = Enum.KeyCode.RightShift,
}

local aimHeld = false
local lockedTarget = nil -- Model
local prevPitch = nil -- camera pitch last frame (for recoil cancel)
local uiBusy = 0         -- >0 while dragging a slider/window (pauses aiming so the camera doesn't fight you)

---------------------------------------------------------------- helpers
local function bindName(b)
	local s = b.Name
	s = s:gsub("MouseButton1", "LMB")
	s = s:gsub("MouseButton2", "RMB")
	s = s:gsub("MouseButton3", "MMB")
	return s
end

local function isPress(i)
	return i.UserInputType == Enum.UserInputType.MouseButton1
		or i.UserInputType == Enum.UserInputType.Touch
end

local function isMove(i)
	return i.UserInputType == Enum.UserInputType.MouseMovement
		or i.UserInputType == Enum.UserInputType.Touch
end

local function matches(input, bind)
	if bind.EnumType == Enum.KeyCode then
		return input.KeyCode == bind
	end
	return input.UserInputType == bind
end

-- When the mouse is locked to centre (first person / shift lock) the crosshair is the screen centre.
local function getCursor()
	if UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
		return camera.ViewportSize / 2
	end
	return UserInputService:GetMouseLocation()
end

---------------------------------------------------------------- targeting
local function getTargetModels()
	local list, seen = {}, {}
	local myChar = player.Character
	local function add(m)
		if m and m ~= myChar and not seen[m] then
			seen[m] = true
			table.insert(list, m)
		end
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player then add(p.Character) end
	end
	for _, m in ipairs(CollectionService:GetTagged("AimTarget")) do
		if m:IsA("Model") then add(m) end
	end
	return list
end

-- Players: compared by Roblox Team. Tagged dummies: set a string attribute
-- "Team" on the model equal to a Team's Name to make it a teammate.
-- If you have no team (FFA / neutral), nobody counts as a teammate.
local function isTeammate(model)
	if not settings.TeamCheck or not player.Team then return false end
	local p = Players:GetPlayerFromCharacter(model)
	if p then return p.Team == player.Team end
	local t = model:GetAttribute("Team")
	return t ~= nil and t == player.Team.Name
end

-- Role filter (fuzzy, by team NAME substring, case-insensitive).
-- Crim mode: skip anyone whose team name contains a BLOCK word (prisoners), everyone else stays targetable,
-- so a team-name mismatch can no longer wipe out all targets.
local CRIM_WORDS = { "crim" }                 -- your team name contains one of these = "I'm a criminal"
local BLOCK_WORDS = { "prison", "inmate" }    -- ...then never lock onto teams containing these
local POLICE_WORDS = { "guard", "polic", "cop" } -- Prison Life: Guards

local function hasWord(name, words)
	if not name then return false end
	name = name:lower()
	for _, w in ipairs(words) do
		if name:find(w, 1, true) then return true end
	end
	return false
end

local function targetTeamName(model)
	local p = Players:GetPlayerFromCharacter(model)
	if p then return p.Team and p.Team.Name or nil end
	local t = model:GetAttribute("Team") -- tagged dummies
	return t and tostring(t) or nil
end

local function passesRoleFilter(model)
	local name = targetTeamName(model)
	if settings.PoliceOnly then
		return hasWord(name, POLICE_WORDS)
	end
	if settings.RoleFilter and player.Team and hasWord(player.Team.Name, CRIM_WORDS) then
		-- Prison Life: Criminals -> Guards only (Inmates / Neutral skipped)
		return hasWord(name, POLICE_WORDS) and not hasWord(name, BLOCK_WORDS)
	end
	return true
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true -- non-collidable decoration/accessories don't count as walls

local function isVisible(model, part)
	if not settings.WallCheck then return true end
	local char = player.Character
	rayParams.FilterDescendantsInstances = char and { char } or {}
	local origin = camera.CFrame.Position
	local result = workspace:Raycast(origin, part.Position - origin, rayParams)
	return result == nil or result.Instance:IsDescendantOf(model)
end

-- where we actually aim (leads moving targets a little)
local function aimPoint(part)
	if settings.Prediction > 0 then
		return part.Position + part.AssemblyLinearVelocity * settings.Prediction
	end
	return part.Position
end

-- distance from cursor in pixels, or nil if off-screen
local function screenDistance(part)
	local pos, onScreen = camera:WorldToViewportPoint(aimPoint(part))
	if not onScreen then return nil end
	return (Vector2.new(pos.X, pos.Y) - getCursor()).Magnitude
end

local HEAD_ORDER = { "Head", "UpperTorso", "Torso", "HumanoidRootPart" }
local BODY_ORDER = { "UpperTorso", "Torso", "HumanoidRootPart", "Head" }

-- Returns the best aimable part of a model (preferred part first, falling back to
-- other body parts if the preferred one is blocked), plus its screen distance.
-- requireFOV: only accept parts inside the FOV circle.
local function resolve(model, requireFOV)
	if isTeammate(model) or not passesRoleFilter(model) then return nil end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return nil end

	local order = settings.TargetMode == "Body" and BODY_ORDER or HEAD_ORDER
	for _, name in ipairs(order) do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			local d = screenDistance(part)
			local inRange = (not requireFOV) or (d ~= nil and d <= settings.FOV)
			if inRange and isVisible(model, part) then
				return part, d
			end
		end
	end
	return nil
end

local function findBestTarget()
	local best, bestPart, bestDist = nil, nil, math.huge
	for _, model in ipairs(getTargetModels()) do
		local part, d = resolve(model, true)
		if part and d and d < bestDist then
			best, bestPart, bestDist = model, part, d
		end
	end
	return best, bestPart
end

---------------------------------------------------------------- UI: base
local gui = Instance.new("ScreenGui")
gui.Name = "AimAssistTestUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 100
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- FOV circle
local fovCircle = Instance.new("Frame")
fovCircle.AnchorPoint = Vector2.new(0.5, 0.5)
fovCircle.BackgroundTransparency = 1
fovCircle.Parent = gui
Instance.new("UICorner", fovCircle).CornerRadius = UDim.new(1, 0)
local fovStroke = Instance.new("UIStroke")
fovStroke.Thickness = 1.5
fovStroke.Color = Color3.fromRGB(255, 255, 255)
fovStroke.Parent = fovCircle

local debugLabel = Instance.new("TextLabel")
debugLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
debugLabel.BackgroundTransparency = 0.4
debugLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
debugLabel.Font = Enum.Font.Code
debugLabel.TextSize = 13
debugLabel.TextXAlignment = Enum.TextXAlignment.Left
debugLabel.AnchorPoint = Vector2.new(0.5, 1)
debugLabel.Position = UDim2.new(0.5, 0, 1, -10)
debugLabel.Size = UDim2.fromOffset(520, 52)
debugLabel.Parent = gui

---------------------------------------------------------------- UI: window
local TITLE_H = 30
local MIN_W, MIN_H = 240, 160

local window = Instance.new("Frame")
window.Name = "Window"
window.Size = UDim2.fromOffset(270, 440)
window.Position = UDim2.fromOffset(20, 60)
window.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
window.BorderSizePixel = 0
window.ClipsDescendants = true
window.Parent = gui
Instance.new("UICorner", window).CornerRadius = UDim.new(0, 8)
local winStroke = Instance.new("UIStroke")
winStroke.Color = Color3.fromRGB(60, 60, 72)
winStroke.Thickness = 1
winStroke.Parent = window
local windowScale = Instance.new("UIScale", window)

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, TITLE_H)
titleBar.BackgroundColor3 = Color3.fromRGB(36, 36, 44)
titleBar.BorderSizePixel = 0
titleBar.Parent = window

local titleText = Instance.new("TextLabel")
titleText.BackgroundTransparency = 1
titleText.Position = UDim2.fromOffset(10, 0)
titleText.Size = UDim2.new(1, -90, 1, 0)
titleText.Text = "Aim Assist (Test)"
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.TextColor3 = Color3.fromRGB(235, 235, 235)
titleText.Font = Enum.Font.GothamBold
titleText.TextSize = 14
titleText.Parent = titleBar

local function makeTitleButton(text, xFromRight, hoverColor)
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 0)
	b.Position = UDim2.new(1, -xFromRight, 0, 0)
	b.Size = UDim2.fromOffset(40, TITLE_H)
	b.BackgroundColor3 = Color3.fromRGB(36, 36, 44)
	b.BorderSizePixel = 0
	b.AutoButtonColor = false
	b.Text = text
	b.TextColor3 = Color3.fromRGB(235, 235, 235)
	b.Font = Enum.Font.GothamBold
	b.TextSize = 14
	b.Parent = titleBar
	b.MouseEnter:Connect(function() b.BackgroundColor3 = hoverColor end)
	b.MouseLeave:Connect(function() b.BackgroundColor3 = Color3.fromRGB(36, 36, 44) end)
	return b
end

local closeBtn = makeTitleButton("X", 0, Color3.fromRGB(200, 55, 55))
local minBtn = makeTitleButton("-", 40, Color3.fromRGB(70, 70, 85))

-- Scrollable body
local body = Instance.new("ScrollingFrame")
body.Position = UDim2.fromOffset(0, TITLE_H)
body.Size = UDim2.new(1, 0, 1, -TITLE_H)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ScrollBarThickness = 4
body.ScrollBarImageColor3 = Color3.fromRGB(90, 90, 105)
body.CanvasSize = UDim2.new()
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollingDirection = Enum.ScrollingDirection.Y
body.Parent = window

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body
local pad = Instance.new("UIPadding")
pad.PaddingTop, pad.PaddingLeft, pad.PaddingRight, pad.PaddingBottom =
	UDim.new(0, 8), UDim.new(0, 8), UDim.new(0, 12), UDim.new(0, 20)
pad.Parent = body

-- Resize grip (bottom-right)
local grip = Instance.new("TextButton")
grip.AnchorPoint = Vector2.new(1, 1)
grip.Position = UDim2.new(1, 0, 1, 0)
grip.Size = UDim2.fromOffset(16, 16)
grip.BackgroundTransparency = 1
grip.Text = "="
grip.Rotation = -45
grip.TextColor3 = Color3.fromRGB(140, 140, 155)
grip.Font = Enum.Font.GothamBold
grip.TextSize = 14
grip.ZIndex = 5
grip.Parent = window

-- Taskbar-style chip that is always visible
local chip = Instance.new("TextButton")
chip.AnchorPoint = Vector2.new(0, 1)
chip.Position = UDim2.new(0, 20, 1, -20)
chip.Size = UDim2.fromOffset(70, 26)
chip.BackgroundColor3 = Color3.fromRGB(25, 25, 30)
chip.TextColor3 = Color3.fromRGB(235, 235, 235)
chip.Font = Enum.Font.GothamBold
chip.TextSize = 12
chip.Text = "Aim UI"
chip.Parent = gui
Instance.new("UICorner", chip).CornerRadius = UDim.new(0, 6)
local chipStroke = Instance.new("UIStroke")
chipStroke.Thickness = 1.5
chipStroke.Parent = chip

---------------------------------------------------------------- window behaviour
local anim = Instance.new("NumberValue") -- open/close pop animation factor
anim.Value = 1
local isOpen = true
local minimized = false
local fullHeight = window.Size.Y.Offset

local function setOpen(open)
	if open == isOpen then return end
	isOpen = open
	if open then
		window.Visible = true
		anim.Value = 0.85
		TweenService:Create(anim, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 1 }):Play()
	else
		local tw = TweenService:Create(anim, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 0.85 })
		tw.Completed:Connect(function()
			if not isOpen then window.Visible = false end
		end)
		tw:Play()
	end
end

local function setMinimized(min)
	minimized = min
	grip.Visible = not min
	if min then
		fullHeight = window.Size.Y.Offset
		body.Visible = false
		TweenService:Create(window, TweenInfo.new(0.15), { Size = UDim2.fromOffset(window.Size.X.Offset, TITLE_H) }):Play()
	else
		body.Visible = true
		TweenService:Create(window, TweenInfo.new(0.15), { Size = UDim2.fromOffset(window.Size.X.Offset, fullHeight) }):Play()
	end
end

closeBtn.MouseButton1Click:Connect(function() setOpen(false) end)
minBtn.MouseButton1Click:Connect(function() setMinimized(not minimized) end)
chip.MouseButton1Click:Connect(function() setOpen(not isOpen) end)

-- dragging the window by its title bar
do
	local dragging, startInput, startMouse, startPos
	titleBar.InputBegan:Connect(function(i)
		if isPress(i) then
			dragging = true
			uiBusy += 1
			startMouse = Vector2.new(i.Position.X, i.Position.Y)
			startPos = window.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and isMove(i) then
			local d = Vector2.new(i.Position.X, i.Position.Y) - startMouse
			local screen = gui.AbsoluteSize
			local w = window.AbsoluteSize.X
			local x = math.clamp(startPos.X.Offset + d.X, -w + 60, screen.X - 60)
			local y = math.clamp(startPos.Y.Offset + d.Y, 0, screen.Y - TITLE_H)
			window.Position = UDim2.fromOffset(x, y)
		end
	end)
	UserInputService.InputEnded:Connect(function(i)
		if dragging and isPress(i) then
			dragging = false
			uiBusy = math.max(0, uiBusy - 1)
		end
	end)
end

-- resizing from the grip
do
	local resizing, startMouse, startSize
	grip.InputBegan:Connect(function(i)
		if isPress(i) then
			resizing = true
			uiBusy += 1
			startMouse = Vector2.new(i.Position.X, i.Position.Y)
			startSize = Vector2.new(window.Size.X.Offset, window.Size.Y.Offset)
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if resizing and isMove(i) then
			local d = (Vector2.new(i.Position.X, i.Position.Y) - startMouse) / windowScale.Scale
			local w = math.clamp(startSize.X + d.X, MIN_W, 600)
			local h = math.clamp(startSize.Y + d.Y, MIN_H, 900)
			window.Size = UDim2.fromOffset(w, h)
			fullHeight = h
		end
	end)
	UserInputService.InputEnded:Connect(function(i)
		if resizing and isPress(i) then
			resizing = false
			uiBusy = math.max(0, uiBusy - 1)
		end
	end)
end

---------------------------------------------------------------- UI: widgets
local order = 0
local function nextOrder() order += 1 return order end

local function makeLabel(text)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, 18)
	l.BackgroundTransparency = 1
	l.Text = text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = Color3.fromRGB(235, 235, 235)
	l.Font = Enum.Font.Gotham
	l.TextSize = 13
	l.LayoutOrder = nextOrder()
	l.Parent = body
	return l
end

local function makeButton(text, callback)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 28)
	b.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	b.TextColor3 = Color3.fromRGB(235, 235, 235)
	b.Font = Enum.Font.Gotham
	b.TextSize = 13
	b.Text = text
	b.AutoButtonColor = true
	b.LayoutOrder = nextOrder()
	b.Parent = body
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
	b.MouseButton1Click:Connect(callback)
	return b
end

local toggleRefreshers = {}
local function makeToggle(name, key)
	local btn
	local function refresh()
		btn.Text = string.format("%s: %s", name, settings[key] and "ON" or "OFF")
		btn.BackgroundColor3 = settings[key] and Color3.fromRGB(40, 110, 60) or Color3.fromRGB(110, 45, 45)
	end
	btn = makeButton("", function()
		settings[key] = not settings[key]
		if key == "Enabled" and not settings.Enabled then lockedTarget = nil end
		refresh()
	end)
	toggleRefreshers[key] = refresh
	refresh()
	return refresh
end

local function makeSlider(name, key, minV, maxV, decimals)
	local label = makeLabel("")

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(1, 0, 0, 10)
	bar.BackgroundColor3 = Color3.fromRGB(55, 55, 65)
	bar.BorderSizePixel = 0
	bar.LayoutOrder = nextOrder()
	bar.Parent = body
	Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = Color3.fromRGB(90, 150, 255)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

	local function refresh()
		local a = math.clamp((settings[key] - minV) / (maxV - minV), 0, 1)
		fill.Size = UDim2.new(a, 0, 1, 0)
		label.Text = string.format("%s: %." .. decimals .. "f", name, settings[key])
	end

	local dragging = false
	local function setFromX(x)
		local a = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
		local mult = 10 ^ decimals
		settings[key] = math.floor((minV + (maxV - minV) * a) * mult + 0.5) / mult
		refresh()
	end
	bar.InputBegan:Connect(function(i)
		if isPress(i) then
			dragging = true
			uiBusy += 1
			setFromX(i.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(i)
		if dragging and isMove(i) then setFromX(i.Position.X) end
	end)
	UserInputService.InputEnded:Connect(function(i)
		if dragging and isPress(i) then
			dragging = false
			uiBusy = math.max(0, uiBusy - 1)
		end
	end)
	refresh()
end

---------------------------------------------------------------- UI: keybinds
local rebinding = nil -- name of the bind being rebound
local bindButtons, bindLabels = {}, {}

local function makeBindRow(label, key)
	bindLabels[key] = label
	local btn = makeButton("", function()
		rebinding = key
		bindButtons[key].Text = label .. ": press a key..."
	end)
	bindButtons[key] = btn
	btn.Text = label .. ": " .. bindName(binds[key])
end

makeBindRow("Aim key", "Aim")
makeBindRow("Toggle key", "Toggle")
makeBindRow("Menu key", "Menu")

---------------------------------------------------------------- UI: controls
makeToggle("Aim assist", "Enabled")
makeToggle("Wall check", "WallCheck")
makeToggle("Team check", "TeamCheck")
makeToggle("Crim: police only", "RoleFilter")
makeToggle("Police only (any team)", "PoliceOnly")
makeButton("Print teams (debug)", function()
	print("[AimAssist] my team:", player.Team and player.Team.Name or "none")
	for _, p in ipairs(Players:GetPlayers()) do
		print("[AimAssist]", p.Name, "->", p.Team and p.Team.Name or "none")
	end
end)
makeToggle("Sticky lock", "StickyLock")
makeToggle("Show FOV", "ShowFOV")
makeToggle("Debug strip", "ShowDebug")
makeSlider("FOV radius", "FOV", 30, 500, 0)
makeToggle("Lock outside FOV", "LockAnyDistance")
makeToggle("Hipfire (no aim key)", "AlwaysAim")

local modeBtn
modeBtn = makeButton("", function()
	settings.TargetMode = settings.TargetMode == "Head" and "Body" or "Head"
	modeBtn.Text = "Aim at: " .. settings.TargetMode
end)
modeBtn.Text = "Aim at: " .. settings.TargetMode

makeToggle("Gun tweaks (new guns)", "GunTweaks")
makeToggle("No recoil", "NoRecoil")
makeSlider("Recoil cancel", "RecoilComp", 0, 1, 2)
makeSlider("Smoothness", "Smoothness", 0, 0.95, 2)
makeSlider("Strength", "Strength", 0.05, 1, 2)
makeSlider("Prediction (s)", "Prediction", 0, 0.25, 2)
makeSlider("UI size", "UIScale", 0.6, 1.5, 2)

-- live strength meter: fills toward Strength while locked, drains when not
makeLabel("Pull meter")
local meterBar = Instance.new("Frame")
meterBar.Size = UDim2.new(1, 0, 0, 12)
meterBar.BackgroundColor3 = Color3.fromRGB(55, 55, 65)
meterBar.BorderSizePixel = 0
meterBar.LayoutOrder = nextOrder()
meterBar.Parent = body
Instance.new("UICorner", meterBar).CornerRadius = UDim.new(1, 0)
local meterFill = Instance.new("Frame")
meterFill.Size = UDim2.new(0, 0, 1, 0)
meterFill.BackgroundColor3 = Color3.fromRGB(255, 170, 60)
meterFill.BorderSizePixel = 0
meterFill.Parent = meterBar
Instance.new("UICorner", meterFill).CornerRadius = UDim.new(1, 0)
local meterValue = 0

makeButton("Close menu", function() setOpen(false) end)

---------------------------------------------------------------- gun tweaks (client side, your own copy)
-- Zeroes spread / recoil style values on Tools you hold or carry. Prints every change as [GunTweaks].
-- If a gun still sprays: check Output for the real value name and add it to GUN_PATTERNS.
-- A server script that adds its own spread when firing can't be fixed from the client.
do
	local GUN_PATTERNS = { "spread", "inaccura", "recoil", "kick", "bloom", "sway" }
	local GUN_SKIP = { "spreadtype" }
	local gunDone = {}

	local function gunMatches(name)
		name = tostring(name):lower()
		for _, sk in ipairs(GUN_SKIP) do
			if name == sk then return false end
		end
		for _, pat in ipairs(GUN_PATTERNS) do
			if name:find(pat, 1, true) then return true end
		end
		return false
	end

	local function zeroTable(t, path, depth, seenT)
		if depth > 3 or seenT[t] then return end
		seenT[t] = true
		for k, v in pairs(t) do
			if type(v) == "number" and gunMatches(k) then
				local ok = pcall(function() t[k] = 0 end)
				if ok then print("[GunTweaks]", path .. "." .. tostring(k), v, "-> 0") end
			elseif type(v) == "table" then
				zeroTable(v, path .. "." .. tostring(k), depth + 1, seenT)
			end
		end
	end

	local function processTool(tool)
		if not settings.GunTweaks or gunDone[tool] then return end
		gunDone[tool] = true

		for name, v in pairs(tool:GetAttributes()) do
			if type(v) == "number" and gunMatches(name) then
				tool:SetAttribute(name, 0)
				print("[GunTweaks]", tool.Name .. " attribute " .. name, v, "-> 0")
			end
		end

		for _, d in ipairs(tool:GetDescendants()) do
			if (d:IsA("NumberValue") or d:IsA("IntValue")) and gunMatches(d.Name) then
				print("[GunTweaks]", tool.Name .. " value " .. d.Name, d.Value, "-> 0")
				d.Value = 0
			elseif d:IsA("ModuleScript") then
				local ok, result = pcall(require, d)
				if ok and type(result) == "table" then
					zeroTable(result, tool.Name .. "/" .. d.Name, 0, {})
				end
			end
		end
	end

	local function watchContainer(container)
		for _, c in ipairs(container:GetChildren()) do
			if c:IsA("Tool") then processTool(c) end
		end
		container.ChildAdded:Connect(function(c)
			if c:IsA("Tool") then
				task.wait() -- let the tool's children finish loading
				processTool(c)
			end
		end)
	end

	local function onGunCharacter(char)
		watchContainer(char)
		watchContainer(player:WaitForChild("Backpack"))
	end

	player.CharacterAdded:Connect(onGunCharacter)
	if player.Character then task.spawn(onGunCharacter, player.Character) end
end

---------------------------------------------------------------- input
UserInputService.InputBegan:Connect(function(input, processed)
	-- rebinding takes priority
	if rebinding then
		if input.KeyCode == Enum.KeyCode.Escape then
			bindButtons[rebinding].Text = bindLabels[rebinding] .. ": " .. bindName(binds[rebinding])
			rebinding = nil
			return
		end
		local new
		if input.UserInputType == Enum.UserInputType.Keyboard then
			new = input.KeyCode
		elseif input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.MouseButton2
			or input.UserInputType == Enum.UserInputType.MouseButton3 then
			new = input.UserInputType
		end
		if new then
			binds[rebinding] = new
			bindButtons[rebinding].Text = bindLabels[rebinding] .. ": " .. bindName(new)
			rebinding = nil
		end
		return
	end

	if processed then return end

	if matches(input, binds.Toggle) then
		settings.Enabled = not settings.Enabled
		toggleRefreshers.Enabled()
		if not settings.Enabled then lockedTarget = nil end
	elseif matches(input, binds.Menu) then
		setOpen(not isOpen)
	elseif matches(input, binds.Aim) then
		aimHeld = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if matches(input, binds.Aim) then
		aimHeld = false
		lockedTarget = nil
	end
end)

---------------------------------------------------------------- main loop
RunService:BindToRenderStep(STEP_NAME, Enum.RenderPriority.Last.Value, function(dt)
	camera = workspace.CurrentCamera
	if not camera then return end

	-- poll the aim bind directly: games often "sink" right-click so InputBegan reports processed=true
	if not rebinding then
		if binds.Aim.EnumType == Enum.KeyCode then
			aimHeld = UserInputService:IsKeyDown(binds.Aim)
		else
			aimHeld = UserInputService:IsMouseButtonPressed(binds.Aim)
		end
	end

	-- on-screen diagnostics: shows exactly why nothing is being locked
	do
		local total, tm, role, dead, off, wall, ok = 0, 0, 0, 0, 0, 0, 0
		for _, m in ipairs(getTargetModels()) do
			total += 1
			local hum = m:FindFirstChildOfClass("Humanoid")
			local head = m:FindFirstChild("Head") or m:FindFirstChild("HumanoidRootPart")
			if isTeammate(m) then tm += 1
			elseif not passesRoleFilter(m) then role += 1
			elseif not hum or hum.Health <= 0 or not head then dead += 1
			else
				local d = screenDistance(head)
				if not d or d > settings.FOV then off += 1
				elseif not isVisible(m, head) then wall += 1
				else ok += 1 end
			end
		end
		debugLabel.Text = string.format(
			"aimHeld=%s enabled=%s team=%s\nothers=%d  teammate=%d  roleFiltered=%d  dead/noHead=%d\noutsideFOV=%d  behindWall=%d  LOCKABLE=%d  locked=%s",
			tostring(aimHeld), tostring(settings.Enabled), player.Team and player.Team.Name or "none",
			total, tm, role, dead, off, wall, ok, lockedTarget and lockedTarget.Name or "no")
		debugLabel.Visible = settings.ShowDebug
	end

	-- recoil cancel: while firing, any upward camera kick that did NOT come from your mouse is removed
	if settings.NoRecoil and lockedTarget == nil and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
		local cf = camera.CFrame
		local x, y, z = cf:ToEulerAnglesYXZ()
		local dy = UserInputService:GetMouseDelta().Y
		if prevPitch and math.abs(dy) < 0.5 and x > prevPitch + 0.0005 then
			x = prevPitch + (x - prevPitch) * (1 - settings.RecoilComp)
			camera.CFrame = CFrame.new(cf.Position) * CFrame.fromEulerAnglesYXZ(x, y, z)
		end
		prevPitch = x
	else
		prevPitch = nil
	end

	-- FOV circle follows the cursor / crosshair
	local cursor = getCursor()
	fovCircle.Visible = settings.ShowFOV and settings.Enabled
	fovCircle.Position = UDim2.fromOffset(cursor.X, cursor.Y)
	fovCircle.Size = UDim2.fromOffset(settings.FOV * 2, settings.FOV * 2)

	-- chip + window scale
	windowScale.Scale = settings.UIScale * anim.Value
	chipStroke.Color = settings.Enabled and Color3.fromRGB(60, 200, 100) or Color3.fromRGB(200, 70, 70)

	-- strength meter (uses last frame's lock state)
	local aiming = (aimHeld or settings.AlwaysAim) and uiBusy == 0
	local pulling = settings.Enabled and aiming and lockedTarget ~= nil
	meterValue += ((pulling and settings.Strength or 0) - meterValue) * math.min(1, dt * 12)
	meterFill.Size = UDim2.new(math.clamp(meterValue, 0, 1), 0, 1, 0)

	if not (settings.Enabled and aiming) then
		lockedTarget = nil
		return
	end

	-- don't aim while dead
	local char = player.Character
	local myHum = char and char:FindFirstChildOfClass("Humanoid")
	if myHum and myHum.Health <= 0 then
		lockedTarget = nil
		return
	end

	-- target selection / lock
	local part
	if settings.StickyLock and lockedTarget then
		part = resolve(lockedTarget, not settings.LockAnyDistance)
		if not part then lockedTarget = nil end
	end
	if not lockedTarget then
		lockedTarget, part = findBestTarget()
	end
	if not lockedTarget or not part then
		lockedTarget = nil
		return
	end

	-- frame-rate independent smoothing
	local alpha = 1
	if settings.Smoothness > 0 then
		alpha = 1 - settings.Smoothness ^ (dt * 60)
	end
	alpha = math.clamp(alpha * settings.Strength, 0, 1)

	local camCF = camera.CFrame
	local goal = aimPoint(part)
	if (goal - camCF.Position).Magnitude < 0.5 then return end
	camera.CFrame = camCF:Lerp(CFrame.lookAt(camCF.Position, goal), alpha)
end)

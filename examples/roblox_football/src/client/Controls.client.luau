--!strict
-- The QB's controls and the HUD, on the client (a LocalScript in StarterPlayerScripts).
--
-- Throwing (while the play is live, you have the ball and are behind the line of scrimmage):
--   aim with the mouse (the throw goes toward the point under the cursor), hold the left button to charge power
--   (full after Config.ChargeSeconds), release to throw. Number keys set a fixed power instead (1 = 10% ... 9 = 90%,
--   0 = 100%): a click then throws at that power. C goes back to hold-to-charge.
-- The server decides everything (Football.luau): the client only sends ThrowBall(aim point, power).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local playState = ReplicatedStorage:WaitForChild("PlayState") :: Configuration
local throwBall = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ThrowBall") :: RemoteEvent

local gui = player:WaitForChild("PlayerGui"):WaitForChild("Hud") :: ScreenGui
local scoreLabel = gui:WaitForChild("Score") :: TextLabel
local playLabel = gui:WaitForChild("Play") :: TextLabel
local messageLabel = gui:WaitForChild("Message") :: TextLabel
local powerFrame = gui:WaitForChild("Power") :: Frame
local powerFill = powerFrame:WaitForChild("Fill") :: Frame
local powerLabel = powerFrame:WaitForChild("Label") :: TextLabel

-- -- the HUD --------------------------------------------------------------------------------------------------------

local ls = player:WaitForChild("leaderstats")
local points = ls:WaitForChild("Points") :: IntValue
local touchdowns = ls:WaitForChild("Touchdowns") :: IntValue
local completions = ls:WaitForChild("Completions") :: IntValue

local function refreshScore()
	scoreLabel.Text = string.format("Points %d  TD %d  Comp %d", points.Value, touchdowns.Value, completions.Value)
end
points.Changed:Connect(refreshScore)
touchdowns.Changed:Connect(refreshScore)
completions.Changed:Connect(refreshScore)
refreshScore()

local function refreshPlay()
	local phase = (playState:GetAttribute("Phase") :: string?) or ""
	local result = (playState:GetAttribute("Result") :: string?) or ""
	local ytg = (playState:GetAttribute("YardsToGoal") :: number?) or 0
	playLabel.Text = string.format("%s%s  |  %d to go", phase, result ~= "" and (": " .. result) or "", ytg)
end
playState:GetAttributeChangedSignal("Phase"):Connect(refreshPlay)
playState:GetAttributeChangedSignal("Result"):Connect(refreshPlay)
playState:GetAttributeChangedSignal("YardsToGoal"):Connect(refreshPlay)
refreshPlay()

local shown = 0
playState:GetAttributeChangedSignal("MessageId"):Connect(function()
	shown += 1
	local mine = shown
	messageLabel.Text = (playState:GetAttribute("Message") :: string?) or ""
	messageLabel.Visible = true
	task.delay(3, function()
		if shown == mine then
			messageLabel.Visible = false
		end
	end)
end)

-- -- throwing -------------------------------------------------------------------------------------------------------

local fixedPower: number? = nil
local chargeStart: number? = nil

local function canThrow(): boolean
	return playState:GetAttribute("Phase") == "Live"
		and playState:GetAttribute("Carrier") == "QB"
		and playState:GetAttribute("BallState") == "Held"
		and playState:GetAttribute("Quarterback") == player.Name
end

local function currentPower(): number
	if fixedPower then
		return fixedPower
	end
	if chargeStart then
		return math.clamp((os.clock() - chargeStart) / Config.ChargeSeconds, Config.Ball.MinPower, 1)
	end
	return 0
end

-- the aim marker: where the cursor meets the field (the client's own: the server never sees it)
local marker = Instance.new("Part")
marker.Name = "AimMarker"
marker.Shape = Enum.PartType.Cylinder
marker.Size = Vector3.new(0.1, 3, 3)
marker.Color = Color3.fromRGB(255, 255, 255)
marker.Material = Enum.Material.Neon
marker.Transparency = 0.4
marker.Anchored = true
marker.CanCollide = false
marker.CanTouch = false
marker.CanQuery = false
marker.Parent = workspace
mouse.TargetFilter = marker

local digits: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 0.1,
	[Enum.KeyCode.Two] = 0.2,
	[Enum.KeyCode.Three] = 0.3,
	[Enum.KeyCode.Four] = 0.4,
	[Enum.KeyCode.Five] = 0.5,
	[Enum.KeyCode.Six] = 0.6,
	[Enum.KeyCode.Seven] = 0.7,
	[Enum.KeyCode.Eight] = 0.8,
	[Enum.KeyCode.Nine] = 0.9,
	[Enum.KeyCode.Zero] = 1,
}

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if canThrow() then
			chargeStart = os.clock()
		end
	elseif input.KeyCode == Enum.KeyCode.C then
		fixedPower = nil
	elseif digits[input.KeyCode] then
		fixedPower = digits[input.KeyCode]
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 or not chargeStart then
		return
	end
	local power = currentPower()
	chargeStart = nil
	if canThrow() then
		throwBall:FireServer(mouse.Hit.Position, power)
	end
end)

RunService.RenderStepped:Connect(function()
	local aiming = canThrow()
	marker.Transparency = aiming and 0.4 or 1
	if aiming then
		local hit = mouse.Hit.Position
		marker.CFrame = CFrame.new(hit.X, 0.08, hit.Z) * CFrame.Angles(0, 0, math.rad(90))
	end
	local p = currentPower()
	powerFill.Size = UDim2.fromScale(p, 1)
	if fixedPower then
		powerLabel.Text = string.format("Power %d%% (fixed: C to charge)", math.floor(p * 100 + 0.5))
	elseif chargeStart then
		powerLabel.Text = string.format("Power %d%%", math.floor(p * 100 + 0.5))
	else
		powerLabel.Text = "Hold to charge (or keys 1-0)"
	end
end)

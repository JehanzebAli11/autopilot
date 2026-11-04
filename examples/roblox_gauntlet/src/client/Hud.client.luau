--!strict
-- The player's HUD (a LocalScript that builds it): a bar across the top with the stage, the deaths and the run's time,
-- and a toast in the middle when a checkpoint is reached, when you die (and what killed you) and at the finish. Its
-- labels are PlayerGui.Hud's Stage, Deaths, Time and Toast.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Clock = require(ReplicatedStorage:WaitForChild("Clock"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local player = Players.LocalPlayer
local ls = player:WaitForChild("leaderstats")
local stageValue = ls:WaitForChild("Stage") :: IntValue
local deathsValue = ls:WaitForChild("Deaths") :: IntValue

local FONT = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
local HEAVY = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)
local INK = Color3.fromRGB(240, 244, 255)

local function make(className: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	return inst
end

local function rounded(parent: Instance, radius: number)
	make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local gui = make("ScreenGui", { Name = "Hud", ResetOnSpawn = false, IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))

-- the bar
local bar = make("Frame", { Name = "Bar", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 14),
	Size = UDim2.fromOffset(560, 46), BackgroundColor3 = Color3.fromRGB(12, 12, 24), BackgroundTransparency = 0.25 }, gui)
rounded(bar, 23)
local stroke = make("UIStroke", { Thickness = 1.5, Transparency = 0.2 }, bar)
local strokeGradient = make("UIGradient", {}, stroke)
make("UIPadding", { PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 20) }, bar)
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
	HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 18),
	SortOrder = Enum.SortOrder.LayoutOrder }, bar)

local function label(name: string, order: number, width: number, align: Enum.TextXAlignment): TextLabel
	return make("TextLabel", { Name = name, LayoutOrder = order, Size = UDim2.fromOffset(width, 30),
		BackgroundTransparency = 1, FontFace = FONT, TextSize = 19, TextColor3 = INK, TextXAlignment = align,
		Text = "" }, bar)
end
local stageLabel = label("Stage", 1, 260, Enum.TextXAlignment.Left)
local deathsLabel = label("Deaths", 2, 110, Enum.TextXAlignment.Center)
local timeLabel = label("Time", 3, 110, Enum.TextXAlignment.Right)
timeLabel.FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold)

-- the progress strip under the bar: one segment a stage, lit in its color once reached
local strip = make("Frame", { Name = "Progress", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 66),
	Size = UDim2.fromOffset(520, 6), BackgroundTransparency = 1 }, gui)
make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
	SortOrder = Enum.SortOrder.LayoutOrder }, strip)
local segments = {}
for i, s in ipairs(Config.Stages) do
	local seg = make("Frame", { Name = "Segment" .. i, LayoutOrder = i, BackgroundColor3 = s.color,
		BackgroundTransparency = 0.8, Size = UDim2.new(1 / #Config.Stages, -4, 1, 0) }, strip)
	rounded(seg, 3)
	segments[i] = seg
end

-- the toast
local toast = make("TextLabel", { Name = "Toast", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.3),
	Size = UDim2.fromOffset(640, 64), BackgroundTransparency = 1, FontFace = HEAVY, TextSize = 40, TextColor3 = INK,
	TextTransparency = 1, Text = "" }, gui)
local toastStroke = make("UIStroke", { Thickness = 2.5, Transparency = 1, Color = Color3.fromRGB(10, 10, 20) }, toast)
local toastToken = 0

local function show(text: string, color: Color3, seconds: number)
	toastToken += 1
	local mine = toastToken
	toast.Text = text
	toast.TextColor3 = color
	toast.Size = UDim2.fromOffset(560, 56)
	TweenService:Create(toast, TweenInfo.new(0.25, Enum.EasingStyle.Back), { TextTransparency = 0,
		Size = UDim2.fromOffset(640, 64) }):Play()
	TweenService:Create(toastStroke, TweenInfo.new(0.25), { Transparency = 0.3 }):Play()
	task.delay(seconds, function()
		if mine == toastToken then
			TweenService:Create(toast, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
			TweenService:Create(toastStroke, TweenInfo.new(0.5), { Transparency = 1 }):Play()
		end
	end)
end

-- -- keeping it up to date -------------------------------------------------------------------------------------------

local function stageColor(stage: number): Color3
	local s = Config.Stages[math.clamp(stage + 1, 1, #Config.Stages)]
	return s.color
end

local function refresh()
	local stage = stageValue.Value
	local next = Config.Stages[math.clamp(stage + 1, 1, #Config.Stages)]
	if player:GetAttribute("Finished") then
		stageLabel.Text = string.format("Stage %d/%d  ·  Finished", Config.FinalStage, Config.FinalStage)
	else
		stageLabel.Text = string.format("Stage %d/%d  ·  %s", math.min(stage + 1, Config.FinalStage), Config.FinalStage,
			next.name)
	end
	deathsLabel.Text = "Deaths " .. deathsValue.Value
	for i, seg in ipairs(segments) do
		seg.BackgroundTransparency = i <= stage and 0 or 0.8
	end
	local c = stageColor(stage)
	strokeGradient.Color = ColorSequence.new(c, c:Lerp(Color3.new(1, 1, 1), 0.4))
end
stageValue.Changed:Connect(refresh)
deathsValue.Changed:Connect(refresh)
player:GetAttributeChangedSignal("Finished"):Connect(refresh)
refresh()

local function clock(seconds: number): string
	local m = math.floor(seconds / 60)
	return string.format("%02d:%04.1f", m, seconds - m * 60)
end

RunService.RenderStepped:Connect(function()
	local final = player:GetAttribute("FinishSeconds") :: number?
	local start = (player:GetAttribute("RunStart") :: number?) or Clock.now()
	timeLabel.Text = clock(final or math.max(0, Clock.now() - start))
end)

local CAUSES = { Laser = "Zapped by a laser", Void = "Fell into the void", Unknown = "You died" }

;(Remotes:WaitForChild("StageReached") :: RemoteEvent).OnClientEvent:Connect(function(stage: number, name: string)
	if stage >= Config.FinalStage then
		return
	end
	show(string.format("Checkpoint %d  ·  %s cleared", stage, name), Config.Stages[stage].color, 2)
end)
;(Remotes:WaitForChild("Died") :: RemoteEvent).OnClientEvent:Connect(function(cause: string)
	show(CAUSES[cause] or ("Killed by " .. cause), Color3.fromRGB(255, 90, 110), 1.6)
end)
;(Remotes:WaitForChild("Finished") :: RemoteEvent).OnClientEvent:Connect(function(name: string, seconds: number,
	deaths: number)
	if name == player.Name then
		show(string.format("FINISHED  ·  %s  ·  %d deaths", clock(seconds), deaths), Color3.fromRGB(255, 230, 120), 6)
	end
end)

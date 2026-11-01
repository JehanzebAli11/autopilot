-- The Roblox plugin's test game, Lantern Grove (made up for these tests): run it in Studio's command bar (or
-- `python tools/roblox_dev.py eval - < plugin/roblox/tests/testgame.luau`) on an empty Baseplate. It builds, again
-- each time (what it built before is replaced):
--  - Workspace/Grove: six Lanterns (a "Lantern" tag; touching one collects it), a Lever whose ProximityPrompt (E)
--    opens the Gate, a Crate to jump on, a Pond, a Mailbox with a ClickDetector, a row of three same-named Posts;
--  - ReplicatedStorage/GameState (a ModuleScript: collected, gateOpen, total, addLantern) and Remotes (Ring, Wave);
--  - ServerScriptService/GroveService: leaderstats.Lanterns, collecting, the lever, the remotes;
--  - StarterGui/HUD ("Lanterns n / 6") and Menu (a Ring button, a Name box);
--  - StarterPlayerScripts/GroveControls: Q waves (ContextActionService action "Wave").
-- Two planted bugs for the detectors: the Mailbox's script indexes nil when clicked (log_error), and the Gate's door,
-- once opened, falls through the ground (out_of_world).
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

for _, old in pairs({ workspace:FindFirstChild("Grove"), ReplicatedStorage:FindFirstChild("GameState"),
	ReplicatedStorage:FindFirstChild("Remotes"), ServerScriptService:FindFirstChild("GroveService"),
	StarterGui:FindFirstChild("HUD"), StarterGui:FindFirstChild("Menu"),
	StarterPlayer.StarterPlayerScripts:FindFirstChild("GroveControls") }) do
	old:Destroy()
end

local function part(props)
	local p = Instance.new("Part")
	for k, v in pairs(props) do
		if k ~= "Parent" then
			p[k] = v
		end
	end
	p.Anchored = if props.Anchored == nil then true else props.Anchored
	p.Parent = props.Parent
	return p
end

local grove = Instance.new("Folder")
grove.Name = "Grove"

local lanterns = Instance.new("Folder")
lanterns.Name = "Lanterns"
lanterns.Parent = grove
for i = 1, 6 do
	local l = part({ Name = "Lantern", Size = Vector3.new(1, 2, 1), Position = Vector3.new(-12 + (i - 1) * 5, 2, -24),
		Color = Color3.fromRGB(255, 200, 80), Material = Enum.Material.Neon, CanCollide = false, Parent = lanterns })
	CollectionService:AddTag(l, "Lantern")
	local light = Instance.new("PointLight")
	light.Brightness = 2
	light.Parent = l
end

local lever = Instance.new("Model")
lever.Name = "Lever"
local base = part({ Name = "Base", Size = Vector3.new(2, 1, 2), Position = Vector3.new(14, 0.5, -10), Parent = lever })
local handle = part({ Name = "Handle", Size = Vector3.new(0.4, 3, 0.4), Position = Vector3.new(14, 2.5, -10),
	Color = Color3.fromRGB(120, 80, 40), Parent = lever })
lever.PrimaryPart = base
local prompt = Instance.new("ProximityPrompt")
prompt.ActionText = "Pull"
prompt.ObjectText = "Lever"
prompt.KeyboardKeyCode = Enum.KeyCode.E
prompt.MaxActivationDistance = 10
prompt.RequiresLineOfSight = false
prompt.Parent = handle
lever.Parent = grove

local gate = Instance.new("Model")
gate.Name = "Gate"
part({ Name = "PostLeft", Size = Vector3.new(1, 8, 1), Position = Vector3.new(-5, 4, -40), Parent = gate })
part({ Name = "PostRight", Size = Vector3.new(1, 8, 1), Position = Vector3.new(5, 4, -40), Parent = gate })
part({ Name = "Door", Size = Vector3.new(9, 7, 1), Position = Vector3.new(0, 3.5, -40), Color = Color3.fromRGB(90, 60, 30),
	Parent = gate })
gate:SetAttribute("Open", false)
gate.Parent = grove

part({ Name = "Crate", Size = Vector3.new(6, 4, 6), Position = Vector3.new(-16, 2, -6), Color = Color3.fromRGB(160, 120, 70),
	Material = Enum.Material.WoodPlanks, Parent = grove })
part({ Name = "Pond", Size = Vector3.new(14, 0.4, 10), Position = Vector3.new(20, 0.2, 10), Color = Color3.fromRGB(40, 90, 200),
	Transparency = 0.3, CanCollide = false, Parent = grove })

local mailbox = part({ Name = "Mailbox", Size = Vector3.new(2, 4, 2), Position = Vector3.new(-8, 2, 8),
	Color = Color3.fromRGB(200, 40, 40), Parent = grove })
local click = Instance.new("ClickDetector")
click.MaxActivationDistance = 40
click.Parent = mailbox
local mailScript = Instance.new("Script")
mailScript.Name = "MailboxScript"
mailScript.Source = [[
-- The mailbox opens its flap when clicked (planted bug: the flap was never made, so this indexes nil)
local click = script.Parent:WaitForChild("ClickDetector")
click.MouseClick:Connect(function(player)
	local flap = script.Parent:FindFirstChild("Flap")
	flap.Transparency = 1
end)
]]
mailScript.Parent = mailbox

local posts = Instance.new("Folder")
posts.Name = "Posts"
posts.Parent = grove
for i = 1, 3 do
	part({ Name = "Post", Size = Vector3.new(1, 3, 1), Position = Vector3.new(8 + i * 3, 1.5, 4), Parent = posts })
end
grove.Parent = workspace

local state = Instance.new("ModuleScript")
state.Name = "GameState"
state.Source = [[
-- The grove's state, shared by the server's scripts
local GameState = { collected = 0, total = 6, gateOpen = false, ringer = "" }

function GameState.addLantern(n)
	GameState.collected += (n or 1)
	return GameState.collected
end

function GameState:summary()
	return string.format("%d/%d lanterns, gate %s", self.collected, self.total, if self.gateOpen then "open" else "shut")
end

return GameState
]]
state.Parent = ReplicatedStorage

local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
for _, name in ipairs({ "Ring", "Wave" }) do
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = remotes
end
remotes.Parent = ReplicatedStorage

local service = Instance.new("Script")
service.Name = "GroveService"
service.Source = [[
-- The grove's rules: lanterns are collected by touching them, the lever opens the gate, the remotes ring and wave
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameState = require(ReplicatedStorage:WaitForChild("GameState"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

Players.PlayerAdded:Connect(function(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local lanterns = Instance.new("IntValue")
	lanterns.Name = "Lanterns"
	lanterns.Parent = stats
	stats.Parent = player
	player:SetAttribute("Waves", 0)
end)

local function collect(lantern)
	local taken = false
	lantern.Touched:Connect(function(hit)
		if taken then
			return
		end
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if player then
			taken = true
			player.leaderstats.Lanterns.Value += 1
			GameState.addLantern(1)
			lantern:Destroy()
		end
	end)
end
for _, l in ipairs(CollectionService:GetTagged("Lantern")) do
	collect(l)
end

local gate = workspace.Grove.Gate
workspace.Grove.Lever.Handle.ProximityPrompt.Triggered:Connect(function(player)
	GameState.gateOpen = true
	gate:SetAttribute("Open", true)
	workspace.Grove.Lever.Handle.Orientation = Vector3.new(0, 0, 45)
	-- Planted bug: the door is let go of instead of swung open, and it falls through the ground
	local door = gate.Door
	door.CanCollide = false
	door.Anchored = false
end)

Remotes.Ring.OnServerEvent:Connect(function(player, name)
	GameState.ringer = tostring(name or player.Name)
end)
Remotes.Wave.OnServerEvent:Connect(function(player)
	player:SetAttribute("Waves", (player:GetAttribute("Waves") or 0) + 1)
end)
]]
service.Parent = ServerScriptService

local hud = Instance.new("ScreenGui")
hud.Name = "HUD"
hud.ResetOnSpawn = false
local count = Instance.new("TextLabel")
count.Name = "LanternCount"
count.Size = UDim2.fromOffset(220, 40)
count.Position = UDim2.fromOffset(20, 20)
count.BackgroundTransparency = 0.4
count.TextScaled = true
count.Text = "Lanterns 0 / 6"
count.Parent = hud
local hudScript = Instance.new("LocalScript")
hudScript.Name = "HudScript"
hudScript.Source = [[
local player = game:GetService("Players").LocalPlayer
local label = script.Parent:WaitForChild("LanternCount")
local value = player:WaitForChild("leaderstats"):WaitForChild("Lanterns")
local function show()
	label.Text = string.format("Lanterns %d / 6", value.Value)
end
value.Changed:Connect(show)
show()
]]
hudScript.Parent = hud
hud.Parent = StarterGui

local menu = Instance.new("ScreenGui")
menu.Name = "Menu"
menu.ResetOnSpawn = false
local ring = Instance.new("TextButton")
ring.Name = "RingButton"
ring.Size = UDim2.fromOffset(160, 50)
ring.Position = UDim2.new(1, -180, 0, 20)
ring.Text = "Ring the bell"
ring.Parent = menu
local nameBox = Instance.new("TextBox")
nameBox.Name = "NameBox"
nameBox.Size = UDim2.fromOffset(160, 40)
nameBox.Position = UDim2.new(1, -180, 0, 80)
nameBox.PlaceholderText = "Your name"
nameBox.Text = ""
nameBox.Parent = menu
local menuScript = Instance.new("LocalScript")
menuScript.Name = "MenuScript"
menuScript.Source = [[
local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
local menu = script.Parent
menu:WaitForChild("RingButton").Activated:Connect(function()
	Remotes.Ring:FireServer(menu.NameBox.Text)
	menu.RingButton.Text = "Rang!"
end)
]]
menuScript.Parent = menu
menu.Parent = StarterGui

local controls = Instance.new("LocalScript")
controls.Name = "GroveControls"
controls.Source = [[
-- Q waves (an action of ContextActionService)
local ContextActionService = game:GetService("ContextActionService")
local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes")
ContextActionService:BindAction("Wave", function(_, state)
	if state == Enum.UserInputState.Begin then
		Remotes.Wave:FireServer()
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.Q)
]]
controls.Parent = StarterPlayer.StarterPlayerScripts

return "Lantern Grove is built"

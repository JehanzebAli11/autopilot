--!strict
-- What moves, on each client (a LocalScript): the Drift platforms and the floating crystals. A platform's place comes
-- from the shared clock (shared/Clock.luau), so every client sees it in the same spot at the same moment. Moving it here,
-- where the player's own character is simulated, lets it carry them smoothly: each frame, a character standing on a
-- platform is moved with it. (The server's copy of a platform stays at its From end.)

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Clock = require(ReplicatedStorage:WaitForChild("Clock"))

local player = Players.LocalPlayer
local ray = RaycastParams.new()
ray.FilterType = Enum.RaycastFilterType.Include

type Mover = { part: BasePart, rims: { BasePart }, offsets: { CFrame }, from: Vector3, to: Vector3, travel: number,
	dwell: number, offset: number }
local movers: { Mover } = {}

local function addMover(part: BasePart)
	local rims, offsets = {}, {}
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("BasePart") then -- (its neon rim: moved along with it)
			table.insert(rims, child)
			table.insert(offsets, part.CFrame:ToObjectSpace(child.CFrame))
		end
	end
	table.insert(movers, {
		part = part, rims = rims, offsets = offsets,
		from = part:GetAttribute("From") :: Vector3, to = part:GetAttribute("To") :: Vector3,
		travel = part:GetAttribute("Travel") :: number, dwell = part:GetAttribute("Dwell") :: number,
		offset = part:GetAttribute("Offset") :: number,
	})
	ray.FilterDescendantsInstances = (function()
		local list = {}
		for _, m in ipairs(movers) do
			table.insert(list, m.part)
		end
		return list
	end)()
end

for _, part in ipairs(CollectionService:GetTagged(Config.Tags.Mover)) do
	addMover(part :: BasePart)
end
CollectionService:GetInstanceAddedSignal(Config.Tags.Mover):Connect(function(part)
	addMover(part :: BasePart)
end)

-- Which platform, if any, the character stands on
local function standingOn(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then
		return nil
	end
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -(hum.HipHeight + root.Size.Y / 2 + 1.5), 0), ray)
	return hit and hit.Instance :: BasePart or nil
end

RunService.PreSimulation:Connect(function()
	local now = Clock.now()
	local under = standingOn()
	for _, m in ipairs(movers) do
		local before = m.part.Position
		local at = m.from:Lerp(m.to, Clock.mover(m.travel, m.dwell, m.offset, now))
		local frame = CFrame.new(at)
		m.part.CFrame = frame
		for i, rim in ipairs(m.rims) do
			rim.CFrame = frame * m.offsets[i]
		end
		if under == m.part then
			local root = (player.Character :: Model):FindFirstChild("HumanoidRootPart") :: BasePart
			root.CFrame += at - before
		end
	end
end)

-- The crystals turn slowly, each at its own Spin (radians a second)
local crystals = {}
task.spawn(function()
	local course = workspace:WaitForChild("Course")
	local folder = course:WaitForChild("Crystals")
	for _, c in ipairs(folder:GetChildren()) do
		if c:IsA("BasePart") then
			table.insert(crystals, { part = c, core = c:FindFirstChild("Core") :: BasePart?,
				spin = (c:GetAttribute("Spin") :: number?) or 0.2 })
		end
	end
end)
RunService.RenderStepped:Connect(function(dt)
	for _, c in ipairs(crystals) do
		local frame = c.part.CFrame * CFrame.Angles(0, c.spin * dt, 0)
		c.part.CFrame = frame
		if c.core then
			c.core.CFrame = frame
		end
	end
end)

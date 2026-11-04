--!strict
-- Builds Prism Gauntlet from Config: the start island, then each stage and the checkpoint island after it, then the
-- finish. A stage's builder gets the point where its stage begins (on the course's center line, x = 0, at floor
-- height) and returns the point where the next island begins, so every stage fits whatever came before it. Gameplay
-- parts are tagged and carry their numbers as attributes (see Config.Tags); everything is under workspace.Course.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Style = require(script.Parent:WaitForChild("Style"))

local Look = Config.Look
local Course = {}

type Stage = { [string]: any }
type Builder = (stage: Stage, index: number, at: Vector3, folder: Folder) -> Vector3

local function tag(inst: Instance, name: string)
	CollectionService:AddTag(inst, name)
end

-- A hazard: kills on touch (server/Rules.luau) while Active isn't false
local function hazard(p: BasePart, kind: string)
	p:SetAttribute("Kind", kind)
	tag(p, Config.Tags.Hazard)
end

-- A laser gate across a walkway of `width` at `base` (a point on its floor), on a cycle (Clock.on)
local function laserGate(folder: Instance, base: Vector3, width: number, period: number, onSeconds: number,
	offset: number, name: string)
	local h = 7
	local posts = {}
	for _, side in ipairs({ -1, 1 }) do
		local post = Style.deco("Emitter", folder, {
			Size = Vector3.new(0.8, h + 1, 0.8),
			Position = base + Vector3.new(side * (width / 2 + 0.4), (h + 1) / 2, 0),
			Color = Look.metal,
			Material = Enum.Material.DiamondPlate,
		})
		Style.deco("Cap", post, {
			Size = Vector3.new(1, 0.4, 1),
			Position = post.Position + Vector3.new(0, (h + 1) / 2 + 0.2, 0),
			Color = Look.laser,
			Material = Enum.Material.Neon,
		})
		table.insert(posts, post)
	end
	local laser = Style.part(name, folder, {
		Size = Vector3.new(width, h, 0.25),
		Position = base + Vector3.new(0, h / 2, 0),
		Color = Look.laser,
		Material = Enum.Material.Neon,
		Transparency = 0.78,
		CanCollide = false,
		CastShadow = false,
	})
	hazard(laser, "Laser")
	laser:SetAttribute("Period", period)
	laser:SetAttribute("OnSeconds", onSeconds)
	laser:SetAttribute("Offset", offset)
	laser:SetAttribute("Active", true)
	-- the glowing beams between the emitters (shown while the gate is on: server/Rules.luau)
	for i = 1, 4 do
		local y = -h / 2 + i * h / 5
		local a0 = Instance.new("Attachment")
		a0.Position = Vector3.new(-width / 2, y, 0)
		a0.Parent = laser
		local a1 = Instance.new("Attachment")
		a1.Position = Vector3.new(width / 2, y, 0)
		a1.Parent = laser
		local beam = Instance.new("Beam")
		beam.Attachment0, beam.Attachment1 = a0, a1
		beam.Color = ColorSequence.new(Look.laser)
		beam.LightEmission = 1
		beam.Width0, beam.Width1 = 0.35, 0.35
		beam.FaceCamera = true
		beam.Parent = laser
	end
	return laser
end

local builders: { [string]: Builder } = {}

-- Stepping Stones: round pads over the void, each gap a little wider, some a step higher, swaying side to side
function builders.stones(stage, _index, at, folder)
	local d = stage.diameter
	local z, y = at.Z, at.Y
	for i, s in ipairs(stage.stones) do
		z -= s.gap + d / 2
		y += s.rise
		local stone = Style.part("Stone" .. i, folder, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.2, d, d),
			CFrame = CFrame.new(s.x, y - 0.6, z) * CFrame.Angles(0, 0, math.rad(90)),
			Color = Look.rock,
			Material = Enum.Material.Slate,
		})
		Style.deco("Glow", stone, {
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.2, d - 0.8, d - 0.8),
			CFrame = stone.CFrame * CFrame.new(0.62, 0, 0),
			Color = stage.color,
			Material = Enum.Material.Neon,
			Transparency = 0.2,
		})
		z -= d / 2
	end
	return Vector3.new(0, y, z - stage.exitGap)
end

-- Laser Hall: a glass bridge crossed by laser gates that switch on and off; gate k runs (distance / walk speed) behind
-- the first, so one well-timed steady walk passes them all
function builders.lasers(stage, _index, at, folder)
	local L, w = stage.length, stage.width
	Style.walkway("Hall", folder, CFrame.new(0, at.Y - 0.5, at.Z - L / 2), Vector3.new(w, 1, L), stage.color)
	local first = stage.gates[1]
	for k, dist in ipairs(stage.gates) do
		local offset = (dist - first) / Config.Character.walkSpeed
		laserGate(folder, Vector3.new(0, at.Y, at.Z - dist), w, stage.period, stage.onSeconds, offset, "Laser" .. k)
	end
	return Vector3.new(0, at.Y, at.Z - L)
end

-- Drift: platforms that shuttle along the course over the void, waiting at each end; ride one across, step onto the
-- rest pad, ride the next. They move on each client (client/Motion.client.luau), carrying whoever stands on them.
function builders.drift(stage, _index, at, folder)
	local size: Vector3 = stage.size
	local z, y = at.Z, at.Y
	for i, m in ipairs(stage.movers) do
		local from = Vector3.new(0, y - size.Y / 2, z - stage.gap - size.Z / 2)
		local to = from - Vector3.new(0, 0, m.distance)
		local platform = Style.part("Platform" .. i, folder, {
			Size = size,
			Position = from,
			Color = Look.metal,
			Material = Enum.Material.Metal,
		})
		Style.rim(platform, stage.color)
		platform:SetAttribute("From", from)
		platform:SetAttribute("To", to)
		platform:SetAttribute("Travel", m.travel)
		platform:SetAttribute("Dwell", m.dwell)
		platform:SetAttribute("Offset", m.offset)
		tag(platform, Config.Tags.Mover)
		z = to.Z - size.Z / 2 - stage.gap
		if i < #stage.movers then -- a rest pad before the next platform
			local p = stage.pad
			local pad = Style.part("RestPad", folder, {
				Size = Vector3.new(p, 1, p),
				Position = Vector3.new(0, y - 0.5, z - p / 2),
				Color = Look.rock,
				Material = Enum.Material.Slate,
			})
			Style.rim(pad, stage.color)
			z -= p
		end
	end
	return Vector3.new(0, y, z)
end

-- Crumble Bridge: a row of tiles that fall a moment after they are stepped on, and come back a few seconds later;
-- keep moving
function builders.crumble(stage, _index, at, folder)
	local tile: Vector3 = stage.tile
	local z = at.Z
	for i = 1, stage.tiles do
		z -= stage.spacing + tile.Z / 2
		local t = Style.part("Tile" .. i, folder, {
			Size = tile,
			Position = Vector3.new(0, at.Y - tile.Y / 2, z),
			Color = stage.color:Lerp(Look.rock, 0.55),
			Material = Enum.Material.Cobblestone,
		})
		t:SetAttribute("Delay", stage.delay)
		t:SetAttribute("Back", stage.back)
		t:SetAttribute("State", "solid")
		tag(t, Config.Tags.Crumble)
		z -= tile.Z / 2
	end
	return Vector3.new(0, at.Y, z - stage.spacing)
end

-- Conveyor Climb: a narrow ramp whose belt runs back down; walk up against it
function builders.conveyor(stage, _index, at, folder)
	local a = Vector3.new(0, at.Y, at.Z)
	local b = Vector3.new(0, at.Y + stage.rise, at.Z - stage.length)
	local up = (b - a).Unit
	local length = (b - a).Magnitude
	local thickness = 1
	local frame = CFrame.lookAt((a + b) / 2, (a + b) / 2 + up) * CFrame.new(0, -thickness / 2, 0)
	local belt = Style.part("Belt", folder, {
		CFrame = frame,
		Size = Vector3.new(stage.width, thickness, length),
		Color = Look.metal,
		Material = Enum.Material.DiamondPlate,
	})
	belt.AssemblyLinearVelocity = -up * stage.speed
	belt:SetAttribute("Speed", stage.speed)
	tag(belt, Config.Tags.Conveyor)
	-- chevrons on the belt, pointing the way it pushes, and rails along its edges
	for i = 1, math.floor(length / 4) - 1 do
		for _, side in ipairs({ -1, 1 }) do
			Style.deco("Chevron", belt, {
				Size = Vector3.new(stage.width / 2 - 0.4, 0.1, 0.35),
				CFrame = frame * CFrame.new(side * stage.width / 4, thickness / 2 + 0.05, -length / 2 + i * 4)
					* CFrame.Angles(0, math.rad(side * 28), 0),
				Color = stage.color,
				Material = Enum.Material.Neon,
				Transparency = 0.25,
			})
		end
	end
	for _, side in ipairs({ -1, 1 }) do
		Style.deco("Rail", belt, {
			Size = Vector3.new(0.3, 0.3, length),
			CFrame = frame * CFrame.new(side * (stage.width / 2 - 0.15), thickness / 2 + 0.15, 0),
			Color = stage.color,
			Material = Enum.Material.Neon,
		})
	end
	return b
end

-- Phase Shift: blocks in two sets that take turns being solid (odd blocks the first half of each period, even blocks
-- the second); jump to the next block as it turns solid, before the one you're on fades
function builders.phase(stage, _index, at, folder)
	local block: Vector3 = stage.block
	local z = at.Z
	for i = 1, stage.blocks do
		z -= stage.gap + block.Z / 2
		local b = Style.part("Block" .. i, folder, {
			Size = block,
			Position = Vector3.new(0, at.Y - block.Y / 2, z),
			Color = stage.color,
			Material = Enum.Material.Neon,
			Transparency = 0.15,
		})
		b:SetAttribute("Period", stage.period)
		b:SetAttribute("OnSeconds", stage.period / 2)
		b:SetAttribute("Offset", (i % 2 == 1) and 0 or stage.period / 2)
		b:SetAttribute("Solid", true)
		tag(b, Config.Tags.Phase)
		z -= block.Z / 2
	end
	return Vector3.new(0, at.Y, z - stage.gap)
end

-- Skyward Steps: blocks zig-zagging up into the sky around a column of light
function builders.steps(stage, _index, at, folder)
	local block: Vector3 = stage.block
	local z, y = at.Z - 2, at.Y
	for i = 1, stage.steps do
		z -= stage.advance
		y += stage.rise
		local x = (i % 2 == 1) and -stage.side or stage.side
		local step = Style.part("Step" .. i, folder, {
			Size = block,
			Position = Vector3.new(x, y - block.Y / 2, z),
			Color = Look.rock,
			Material = Enum.Material.Slate,
		})
		Style.rim(step, stage.color, 0.3)
	end
	local top = Vector3.new(0, y, z)
	local pillar = Style.deco("Pillar", folder, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(y - at.Y + 20, 1.6, 1.6),
		CFrame = CFrame.new(0, (at.Y + y) / 2 - 4, (at.Z + z) / 2) * CFrame.Angles(0, 0, math.rad(90)),
		Color = stage.color,
		Material = Enum.Material.Neon,
		Transparency = 0.35,
	})
	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = stage.color, 30, 1.5
	light.Parent = pillar
	return top - Vector3.new(0, 0, block.Z / 2 + 4)
end

-- Final Sprint: a narrow beam to the finish, with two laser gates timed like the hall's
function builders.sprint(stage, _index, at, folder)
	local L, w = stage.length, stage.width
	Style.walkway("Beam", folder, CFrame.new(0, at.Y - 0.5, at.Z - L / 2), Vector3.new(w, 1, L), stage.color)
	local first = stage.gates[1]
	for k, dist in ipairs(stage.gates) do
		local offset = (dist - first) / Config.Character.walkSpeed
		laserGate(folder, Vector3.new(0, at.Y, at.Z - dist), w, stage.period, stage.onSeconds, offset, "Laser" .. k)
	end
	return Vector3.new(0, at.Y, at.Z - L)
end

-- -- islands, the finish and the sky ---------------------------------------------------------------------------------

-- A checkpoint island whose near edge is at `at`: tagged Checkpoint with its stage; returns where its far edge is
local function checkpoint(parent: Instance, at: Vector3, stage: number, color: Color3): Vector3
	local size = Config.Island
	local top = at - Vector3.new(0, 0, size.Z / 2)
	local island = Style.island(string.format("Checkpoint%d", stage), parent, top, size, color)
	island:SetAttribute("Stage", stage)
	tag(island, Config.Tags.Checkpoint)
	Style.beacon(island, top + Vector3.new(-size.X / 2 + 1.5, 0, size.Z / 2 - 1.5), color)
	return at - Vector3.new(0, 0, size.Z)
end

local function finish(parent: Instance, at: Vector3, color: Color3)
	local size = Config.FinishIsland
	local top = at - Vector3.new(0, 0, size.Z / 2)
	local island = Style.island("FinishIsland", parent, top, size, color)
	island:SetAttribute("Stage", Config.FinalStage)
	-- the portal: a ring of neon segments standing across the way, with the finish line inside it
	local center = top + Vector3.new(0, 7.5, -4)
	local radius, segments = 6.5, 20
	local ring = Instance.new("Folder")
	ring.Name = "Portal"
	ring.Parent = island
	for i = 1, segments do
		local a = (i - 0.5) / segments * 2 * math.pi
		local p = center + Vector3.new(math.cos(a) * radius, math.sin(a) * radius, 0)
		Style.deco("Segment", ring, {
			Size = Vector3.new(0.9, 2.2, 0.9),
			CFrame = CFrame.new(p) * CFrame.Angles(0, 0, a),
			Color = color:Lerp(Color3.new(1, 1, 1), (i % 2) * 0.35),
			Material = Enum.Material.Neon,
		})
	end
	local line = Style.part("FinishLine", island, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, radius * 2 - 1, radius * 2 - 1),
		CFrame = CFrame.new(center) * CFrame.Angles(0, math.rad(90), 0),
		Color = Color3.new(1, 1, 1),
		Material = Enum.Material.ForceField,
		Transparency = 0.2,
		CanCollide = false,
	})
	tag(line, Config.Tags.Finish)
	local confetti = Instance.new("ParticleEmitter")
	confetti.Name = "Confetti"
	confetti.Enabled = false
	confetti.Rate = 0
	confetti.Lifetime = NumberRange.new(2.5, 4)
	confetti.Speed = NumberRange.new(18, 30)
	confetti.SpreadAngle = Vector2.new(70, 70)
	confetti.Acceleration = Vector3.new(0, -24, 0)
	confetti.RotSpeed = NumberRange.new(-300, 300)
	confetti.Size = NumberSequence.new(0.45)
	confetti.LightEmission = 0.6
	confetti.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Config.Stages[1].color),
		ColorSequenceKeypoint.new(0.5, Config.Stages[4].color),
		ColorSequenceKeypoint.new(1, Config.Stages[7].color),
	})
	confetti.Parent = line
	Style.beacon(island, top + Vector3.new(-size.X / 2 + 2, 0, size.Z / 2 - 2), color, 60)
	Style.beacon(island, top + Vector3.new(size.X / 2 - 2, 0, size.Z / 2 - 2), color, 60)
end

-- Crystals floating around the course (they turn slowly: client/Motion.client.luau)
local function crystals(parent: Instance, from: Vector3, to: Vector3)
	local rng = Random.new(20261104)
	local folder = Instance.new("Folder")
	folder.Name = "Crystals"
	folder.Parent = parent
	for i = 1, Look.crystals do
		local along = from:Lerp(to, (i - 0.5) / Look.crystals)
		local side = (i % 2 == 0) and 1 or -1
		local stage = Config.Stages[math.clamp(math.ceil(i / Look.crystals * #Config.Stages), 1, #Config.Stages)]
		local s = rng:NextNumber(2, 6)
		local c = Style.deco("Crystal", folder, {
			Size = Vector3.new(s, s * 2.2, s),
			CFrame = CFrame.new(along + Vector3.new(side * rng:NextNumber(36, 80), rng:NextNumber(-25, 30),
				rng:NextNumber(-20, 20))) * CFrame.Angles(rng:NextNumber(0, 1), rng:NextNumber(0, 6), rng:NextNumber(0, 1)),
			Color = stage.color,
			Material = Enum.Material.Glass,
			Transparency = 0.2,
			Reflectance = 0.3,
		})
		c:SetAttribute("Spin", rng:NextNumber(0.1, 0.4) * side)
		Style.deco("Core", c, {
			Size = c.Size * 0.45,
			CFrame = c.CFrame,
			Color = stage.color,
			Material = Enum.Material.Neon,
		})
	end
end

-- Builds the whole course under workspace.Course (once); returns it
function Course.build(): Folder
	local existing = workspace:FindFirstChild("Course")
	if existing then
		return existing :: Folder
	end
	local root = Instance.new("Folder")
	root.Name = "Course"

	-- the start
	local startSize = Config.StartIsland
	local start = Style.island("StartIsland", root, Vector3.new(0, 1, 0), startSize, Config.Stages[1].color)
	tag(start, Config.Tags.Spawn)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(8, 0.4, 8)
	spawn.Position = Vector3.new(0, 1.2, 6)
	spawn.Color = Look.metal
	spawn.Material = Enum.Material.Metal
	spawn.Parent = root
	Style.rim(spawn, Config.Stages[1].color, 0.25)
	local title = Style.deco("Title", root, {
		Size = Vector3.new(30, 6, 0.6),
		Position = Vector3.new(0, 27, -startSize.Z / 2 - 6),
		Transparency = 1,
	})
	Style.sign(title, string.upper(Config.Name), Color3.fromRGB(235, 245, 255), Enum.NormalId.Back)

	local at = Vector3.new(0, 1, -startSize.Z / 2)
	for i, stage in ipairs(Config.Stages) do
		local folder = Instance.new("Folder")
		folder.Name = string.format("%02d %s", i, stage.name)
		folder.Parent = root
		folder:SetAttribute("Stage", i)
		Style.arch(folder, at + Vector3.new(0, 0, 1.5), (stage.width or 8) + 4, i, stage.name, stage.color)
		local build = builders[stage.kind]
		assert(build, "no builder for stage kind " .. tostring(stage.kind))
		at = build(stage, i, at, folder)
		if i < #Config.Stages then
			at = checkpoint(folder, at, i, stage.color)
		else
			finish(folder, at, stage.color)
		end
	end

	-- the void: a kill floor (thick, so a fast fall can't pass through it between physics steps) and a grid below it
	local length = math.abs(at.Z) + 120
	local void = Style.part("Void", root, {
		Size = Vector3.new(600, 12, length + 200),
		Position = Vector3.new(0, Config.VoidY - 6, at.Z / 2),
		Transparency = 1,
		CanCollide = false,
		CastShadow = false,
	})
	hazard(void, "Void")
	Style.grid(root, Vector3.new(0, Config.VoidY - 70, at.Z / 2), Vector2.new(480, length + 160), 24)
	crystals(root, Vector3.new(0, 10, 0), at)

	root.Parent = workspace
	return root
end

return Course

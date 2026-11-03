--!strict
-- Builds the practice field from Config and tags it, so the whole place is text (Rojo) and the agent finds every part
-- by its tag: the turf, both end zones and goal lines, a yard line every 5 yards with its number every 10, the
-- sidelines, and the line of scrimmage (moved by Football.luau at each reset). Main.server.luau calls Build.field()
-- once, before the play starts. The players (receivers, defenders) and the ball are Football.luau's.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Tags = Config.Tags

local Build = {}

local WHITE = Color3.fromRGB(245, 245, 245)

local function part(name: string, parent: Instance, position: Vector3, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.Position = position
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- A flat marking painted on the turf: no collisions, no touches, nothing to stand on
local function marking(name: string, parent: Instance, x: number, z: number, sx: number, sz: number, color: Color3,
	height: number?): Part
	local h = height or 0.04
	local p = part(name, parent, Vector3.new(x, h / 2, z), Vector3.new(sx, h, sz), color)
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	return p
end

local function number(parent: Instance, x: number, z: number, text: string, flip: boolean)
	local plate = marking("Number", parent, x, z, 6, 4, WHITE, 0.05)
	plate.Transparency = 1
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = text
	label.TextColor3 = WHITE
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Rotation = flip and 270 or 90
	label.Parent = gui
	gui.Parent = plate
end

function Build.field(): Folder
	local field = Instance.new("Folder")
	field.Name = "Field"

	local length = Config.EndLineZ * 2
	local width = Config.HalfWidth * 2

	-- the ground around the field, then the turf a hair above it
	local apron = part("Apron", field, Vector3.new(0, -0.5, 0), Vector3.new(width + 60, 1, length + 60),
		Color3.fromRGB(70, 110, 60))
	apron.Material = Enum.Material.Grass
	local turf = part("Turf", field, Vector3.new(0, -0.49, 0), Vector3.new(width, 1, length),
		Color3.fromRGB(60, 140, 60))
	turf.Material = Enum.Material.Grass
	CollectionService:AddTag(turf, Tags.Field)

	-- end zones: the one the offense scores in (+z) and its own (-z)
	for _, scoring in ipairs({ true, false }) do
		local sign = scoring and 1 or -1
		local z = sign * (Config.GoalZ + Config.EndZoneDepth / 2)
		local color = scoring and Color3.fromRGB(180, 40, 40) or Color3.fromRGB(40, 70, 170)
		local zone = marking(scoring and "ScoringEndZone" or "OwnEndZone", field, 0, z, width, Config.EndZoneDepth,
			color, 0.03)
		zone:SetAttribute("Scoring", scoring)
		CollectionService:AddTag(zone, Tags.EndZone)
	end

	-- yard lines every 5 yards, goal line to goal line; a number every 10
	local yards = (Config.GoalZ - Config.OwnGoalZ) / Config.StudsPerYard
	for yard = 0, yards, 5 do
		local z = Config.OwnGoalZ + yard * Config.StudsPerYard
		local isGoal = yard == 0 or yard == yards
		local line = marking(isGoal and "GoalLine" or "YardLine", field, 0, z, width, isGoal and 0.8 or 0.4, WHITE)
		local toGoal = yards - yard
		local painted = math.min(yard, toGoal)
		line:SetAttribute("YardsToGoal", toGoal)
		line:SetAttribute("Yard", painted)
		CollectionService:AddTag(line, Tags.YardLine)
		if isGoal then
			line:SetAttribute("Scoring", yard == yards)
			CollectionService:AddTag(line, Tags.GoalLine)
		elseif painted % 10 == 0 then
			number(field, -Config.HalfWidth + 12, z, tostring(painted), false)
			number(field, Config.HalfWidth - 12, z, tostring(painted), true)
		end
	end

	-- sidelines (just outside the field: a carrier past |x| = HalfWidth is out of bounds)
	for _, sign in ipairs({ -1, 1 }) do
		local line = marking("Sideline", field, sign * (Config.HalfWidth + 0.5), 0, 1, length, WHITE)
		CollectionService:AddTag(line, Tags.Sideline)
	end

	-- the line of scrimmage: Football.luau moves it to each play's spot
	local los = marking("LineOfScrimmage", field, 0, Config.losZ(Config.DefaultYardsToGoal), width, 0.6,
		Color3.fromRGB(40, 120, 255), 0.06)
	los.Material = Enum.Material.Neon
	los:SetAttribute("YardsToGoal", Config.DefaultYardsToGoal)
	CollectionService:AddTag(los, Tags.LineOfScrimmage)

	field.Parent = workspace
	return field
end

return Build

--!strict
-- Prism Gauntlet: every number the course is built and played by, shared by the server and the client. The course is
-- laid out from this table (server/Course.luau), so changing a gap or a timing here changes the place. Distances are
-- studs, times seconds. The course runs from the start island along -z, rising as it goes, over a void.

local Config = {}

Config.Name = "Prism Gauntlet"

-- Everything the rules and the agent find is tagged (CollectionService)
Config.Tags = {
	Checkpoint = "Checkpoint", -- an island: attribute Stage (1-7); touching it saves your progress there
	Hazard = "Hazard", -- kills on touch while attribute Active isn't false; attribute Kind says what it is
	Mover = "Mover", -- a platform that shuttles between attributes From and To (animated on each client)
	Crumble = "Crumble", -- a tile that falls CrumbleDelay seconds after it is stepped on, and comes back
	Phase = "Phase", -- a block that is solid only half the time (attribute Solid)
	Conveyor = "Conveyor", -- a belt that pushes you back down a ramp
	Finish = "Finish", -- the portal at the end
	Spawn = "Spawn", -- the start island
}

-- The character, as StarterPlayer sets it (default.project.json). The course is laid out for these: a running jump
-- leaves the ground at sqrt(2 g h) = 53.2 studs/s, stays up 0.54 s on the flat and carries 8.7 studs forward.
Config.Character = { walkSpeed = 16, jumpHeight = 7.2, gravity = 196.2 }
Config.RespawnSeconds = 1.5

Config.StartIsland = Vector3.new(30, 3, 30)
Config.Island = Vector3.new(18, 3, 18) -- a checkpoint island
Config.FinishIsland = Vector3.new(26, 3, 26)
Config.VoidY = -40 -- falling below this ends a life (a kill floor, tag Hazard, Kind "Void")

-- The stages, in order. After each one but the last is a checkpoint island; after the last, the finish.
-- `color` themes the stage; each `kind` is built by its own builder in server/Course.luau.
Config.Stages = {
	{
		kind = "stones",
		name = "Stepping Stones",
		color = Color3.fromRGB(0, 229, 255),
		diameter = 7,
		-- each stone: the gap before it (edge to edge), how much higher it is, and how far it sits to the side
		stones = {
			{ gap = 4, rise = 0, x = 0 },
			{ gap = 5, rise = 1, x = 3 },
			{ gap = 5, rise = 1, x = -3 },
			{ gap = 6, rise = 0, x = 2 },
			{ gap = 6.5, rise = 1, x = -1 },
		},
		exitGap = 4.5,
	},
	{
		kind = "lasers",
		name = "Laser Hall",
		color = Color3.fromRGB(60, 120, 255),
		length = 64,
		width = 10,
		-- laser gates, at these distances along the hall. Each is on for onSeconds of every period, and gate k turns
		-- off (distance / walkSpeed) seconds after the first: a steady walk that starts as the first gate goes dark
		-- passes them all.
		gates = { 14, 30, 46 },
		period = 2.6,
		onSeconds = 1.2,
	},
	{
		kind = "drift",
		name = "Drift",
		color = Color3.fromRGB(150, 90, 255),
		size = Vector3.new(8, 1, 8),
		gap = 2.5, -- from a ledge to a platform waiting at that end
		-- two platforms in a row with a rest pad between: each waits `dwell` at both ends and takes `travel` to cross
		movers = {
			{ distance = 26, travel = 3.0, dwell = 1.6, offset = 0 },
			{ distance = 22, travel = 2.6, dwell = 1.4, offset = 1.3 },
		},
		pad = 6,
	},
	{
		kind = "crumble",
		name = "Crumble Bridge",
		color = Color3.fromRGB(230, 70, 255),
		tiles = 9,
		tile = Vector3.new(6, 1, 6),
		spacing = 0.6,
		delay = 0.55, -- a stepped-on tile falls this long after
		back = 4, -- ... and comes back this long after it fell
	},
	{
		kind = "conveyor",
		name = "Conveyor Climb",
		color = Color3.fromRGB(255, 60, 150),
		length = 46, -- along the course
		rise = 12,
		width = 6,
		speed = 7, -- the belt pushes you back down at this speed (you walk at 16)
	},
	{
		kind = "phase",
		name = "Phase Shift",
		color = Color3.fromRGB(255, 140, 40),
		blocks = 7,
		block = Vector3.new(6, 1.2, 6),
		gap = 4.5,
		period = 3.2, -- the blocks come in two sets that swap every half period: odd ones solid first, then even
	},
	{
		kind = "steps",
		name = "Skyward Steps",
		color = Color3.fromRGB(255, 205, 60),
		steps = 10,
		block = Vector3.new(6, 1, 6),
		side = 4, -- steps zig-zag between x = -side and +side
		advance = 4.5, -- ... moving this far along the course each step
		rise = 3, -- ... and this much higher
	},
	{
		kind = "sprint",
		name = "Final Sprint",
		color = Color3.fromRGB(120, 255, 200),
		length = 44,
		width = 3,
		gates = { 16, 32 },
		period = 2.2,
		onSeconds = 1.0,
	},
}
Config.FinalStage = #Config.Stages -- the finish counts as the last stage

-- How the place looks
Config.Look = {
	rock = Color3.fromRGB(92, 86, 120),
	metal = Color3.fromRGB(64, 68, 88),
	glass = Color3.fromRGB(120, 136, 190),
	laser = Color3.fromRGB(255, 40, 70),
	void = Color3.fromRGB(110, 60, 200),
	crystals = 28,
}

return Config

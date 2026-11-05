--!strict
-- The practice field's numbers, shared by the server and the client. Distances are studs, speeds studs per second,
-- times seconds. The offense always attacks +z: its goal line is at z = GoalZ, the end zone it scores in runs from
-- GoalZ to EndLineZ, and the field is 2 * HalfWidth wide, centred on x = 0. The turf's top is at y = 0.

local Config = {}

-- The tags of everything the agent may need (CollectionService); Build.luau and Football.luau set them
Config.Tags = {
	Field = "Field", -- the turf
	EndZone = "EndZone", -- attribute Scoring: true for the end zone the offense scores in
	GoalLine = "GoalLine", -- attribute Scoring, like EndZone
	YardLine = "YardLine", -- every 5 yards; attributes YardsToGoal (to the scoring goal line) and Yard (the painted number)
	Sideline = "Sideline", -- out of bounds is beyond them
	LineOfScrimmage = "LineOfScrimmage", -- the blue line where the play starts; attribute YardsToGoal
	Football = "Football", -- the ball; attributes State ("Held", "Air", "Ground") and Carrier
	BallCarrier = "BallCarrier", -- on whoever has the ball (the QB's character or a receiver), and only them
	Quarterback = "Quarterback", -- the player's character (the player is always the QB)
	Receiver = "Receiver", -- attributes Route, Mode ("Set", "Route", "Settled", "RunAfterCatch"), Velocity
	Defender = "Defender", -- attributes Assignment (a receiver's name, "Rush" or "Pursue"), Mode, Velocity
	RouteEnd = "RouteEnd", -- a disc where a receiver's route ends; attribute Receiver
	PlayState = "PlayState", -- ReplicatedStorage.PlayState: the play's attributes (see Football.luau)
}

Config.StudsPerYard = 2
Config.HalfWidth = 53 -- 53 1/3 yards wide
Config.GoalZ = 100 -- the goal line the offense attacks
Config.OwnGoalZ = -100 -- the offense's own goal line: a carrier brought down behind it is a safety
Config.EndZoneDepth = 20 -- 10 yards
Config.EndLineZ = Config.GoalZ + Config.EndZoneDepth

-- Where the line of scrimmage is, given the yards to go to the scoring goal line (1-99)
function Config.losZ(yardsToGoal: number): number
	return Config.GoalZ - yardsToGoal * Config.StudsPerYard
end

-- A new play starts here unless ResetPlay says otherwise: the offense's own 30, 70 yards to go
Config.DefaultYardsToGoal = 70

-- The play's clock: the ball is snapped SnapSeconds after a reset; a dead play resets ResetSeconds after it ends,
-- from the same line of scrimmage (it is a practice drill: the spot never moves on its own)
Config.SnapSeconds = 3
Config.ResetSeconds = 4

Config.TouchdownPoints = 6

-- The formation, relative to the line of scrimmage's centre: x across, z downfield (positive = toward the goal).
-- A receiver's route is waypoints in the same frame, run at RouteSpeed from the snap; it waits at the last one.
-- Waypoints past the end line are pulled back inside it.
Config.QuarterbackStart = Vector3.new(0, 0, -10) -- 5 yards behind the line (shotgun)
Config.Receivers = {
	{ name = "X", route = "Go", start = Vector3.new(-40, 0, -1), waypoints = { Vector3.new(-40, 0, 80) } },
	{
		name = "Z",
		route = "Slant",
		start = Vector3.new(40, 0, -1),
		waypoints = { Vector3.new(40, 0, 10), Vector3.new(20, 0, 30) },
	},
	{
		name = "Y",
		route = "Post",
		start = Vector3.new(-14, 0, -1),
		waypoints = { Vector3.new(-14, 0, 24), Vector3.new(0, 0, 48) },
	},
}
-- Defenders: two cover the X and Z receivers; one rushes the QB. Nobody covers Y: Y is the open receiver.
Config.Defenders = {
	{ name = "CB1", assignment = "X", start = Vector3.new(-40, 0, 12) },
	{ name = "CB2", assignment = "Z", start = Vector3.new(40, 0, 12) },
	{ name = "R1", assignment = "Rush", start = Vector3.new(10, 0, 3) }, -- off the edge, out of the passing lanes
}

Config.RouteSpeed = 20 -- receivers on their routes
Config.RunAfterCatchSpeed = 20 -- a receiver with the ball runs straight for the end zone
Config.CoverSpeed = 18 -- a cover defender keeps CoverGap studs on the QB's side of its receiver
Config.CoverGap = 2
Config.RushSpeed = 12 -- slower than a player's WalkSpeed (16): the QB can get away from the rusher
Config.RushDelay = 4 -- the rusher waits this long after the snap
Config.PursueSpeed = 18 -- every defender, once the ball is caught or the QB runs past the line
Config.TackleRadius = 3 -- a defender this close (horizontally) to the ball carrier tackles them: the play is dead

-- Throwing: aim at a point on the field; power (0-1) sets the ball's speed, from MinSpeed to MaxSpeed. The ball
-- flies the flatter of the two arcs that pass through the aim point at CatchHeight; when even 45 degrees can't
-- reach it, it flies 45 degrees and falls short. Only the QB, holding the ball behind the line of scrimmage, throws.
Config.Ball = {
	MinSpeed = 30,
	MaxSpeed = 100,
	MinPower = 0.1,
	Gravity = 80, -- the ball's own gravity, not Workspace's: its flight is computed, not simulated
	ReleaseHeight = 1.5, -- above the QB's HumanoidRootPart
	CatchHeight = 3, -- the height the throw aims at (a receiver's chest)
	CatchRadius = 3.5, -- a receiver or defender this close (horizontally) to the ball catches it...
	CatchMaxHeight = 7, -- ...when the ball is no higher than this
	MinCatchDistance = 4, -- nobody catches the ball within this far of where it was thrown
	Radius = 0.5, -- the ball is down (incomplete) when its centre is this low
}
Config.ChargeSeconds = 1 -- holding the throw button this long charges full power

return Config

--!strict
-- The practice play, on the server. The player is the quarterback; three receivers (X, Y, Z) run their routes from
-- the snap; two defenders cover X and Z and one rushes the QB. Nobody covers Y.
--
-- A play goes PreSnap -> Live -> Dead, then resets (Config.ResetSeconds later) from the same line of scrimmage:
--   PreSnap  everyone stands in the formation and the QB can't move; the ball is snapped Config.SnapSeconds later
--   Live     receivers run, defenders cover or rush; the QB throws (aim + power, the ThrowBall RemoteEvent) or runs
--   Dead     the play is over: ReplicatedStorage.PlayState's Result says how ("Touchdown", "Tackled", "Incomplete",
--            "Intercepted", "OutOfBounds", "Safety")
--
-- Rules, checked every Heartbeat while the play is Live:
--   - a ball in the air is caught by the closest receiver or defender within Config.Ball.CatchRadius (horizontally)
--     once it is no higher than CatchMaxHeight: a receiver completes the pass and runs for the end zone, a defender
--     intercepts it (the play is dead); a ball that comes down, or leaves the field, is incomplete
--   - a defender within Config.TackleRadius of the ball carrier tackles them: the play is dead
--   - a carrier past the scoring goal line scores a touchdown (Config.TouchdownPoints to leaderstats.Points)
--   - a carrier past a sideline is out of bounds; one behind their own goal line is a safety (no points: practice)
--
-- Everything the play knows is also on instances, so the agent can read it: ReplicatedStorage.PlayState's
-- attributes, each receiver's and defender's attributes and tags, the ball's attributes (see Config.Tags).
-- Main.server.luau starts this module; Debug.luau reaches it only through ServerStorage.FootballCommand (a
-- BindableFunction), so it works from any Luau context.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Tags = Config.Tags
local BallConfig = Config.Ball

type Actor = {
	name: string,
	kind: string, -- "Receiver" or "Defender"
	model: Model,
	root: BasePart,
	-- Receiver: "Set", "Route", "Settled", "RunAfterCatch"; Defender: "Set", "Cover", "Rush", "Pursue", "Ball"
	mode: string,
	assignment: string, -- a defender's receiver, "Rush" or "Pursue"; a receiver's route name
	waypoints: { Vector3 }, -- a receiver's route, on the field (y = 0)
	leg: number, -- the waypoint the receiver runs to next
	spawned: boolean, -- a defender made by SpawnDefender (gone at the next reset)
}

type Throw = { origin: Vector3, velocity: Vector3, at: number, landing: Vector3 }

local Football = {}

local BODY_HEIGHT = 5
local UP = Vector3.new(0, 1, 0)

local state = {
	phase = "PreSnap",
	result = "",
	carrier = "QB", -- "QB" (the player), or a receiver's name
	ballState = "Held",
	yardsToGoal = Config.DefaultYardsToGoal,
	losZ = Config.losZ(Config.DefaultYardsToGoal),
	playId = 0,
	snapAt = 0,
	throw = nil :: Throw?,
	token = 0, -- a reset or snap scheduled for an older play is ignored
	spawnedCount = 0,
}

local actors: { [string]: Actor } = {}
local order: { string } = {} -- actors' names in the order they were made (a stable order for ties)

local root: Folder
local offense: Folder
local defense: Folder
local markers: Folder
local ball: Part
local playState: Configuration
local los: BasePart?

-- -- helpers --------------------------------------------------------------------------------------------------------

local function now(): number
	return workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function onField(offset: Vector3): Vector3
	-- a formation offset (from the line of scrimmage's centre) to a point on the field, inside the end line
	local z = math.min(state.losZ + offset.Z, Config.EndLineZ - 2)
	return Vector3.new(offset.X, 0, z)
end

local function quarterback(): Player?
	return Players:GetPlayers()[1]
end

local function qbRoot(): BasePart?
	local p = quarterback()
	local character = p and p.Character
	local r = character and character:FindFirstChild("HumanoidRootPart")
	return (r and r:IsA("BasePart")) and r or nil
end

local function qbHumanoid(): Humanoid?
	local p = quarterback()
	local character = p and p.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function stat(name: string): IntValue?
	local p = quarterback()
	local ls = p and p:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return (v and v:IsA("IntValue")) and v or nil
end

-- where an actor stands on the field (y = 0)
local function ground(a: Actor): Vector3
	return flat(a.root.Position)
end

local function place(a: Actor, position: Vector3, facing: Vector3?)
	local look = facing and flat(facing) or Vector3.zero
	if look.Magnitude < 1e-3 then
		look = a.root.CFrame.LookVector
		look = flat(look)
		if look.Magnitude < 1e-3 then
			look = Vector3.new(0, 0, a.kind == "Receiver" and 1 or -1)
		end
	end
	local at = flat(position) + UP * (BODY_HEIGHT / 2)
	a.model:PivotTo(CFrame.lookAt(at, at + look.Unit))
end

local function setVelocity(a: Actor, v: Vector3)
	a.root:SetAttribute("Velocity", v)
	a.model:SetAttribute("Velocity", v)
end

-- moves an actor toward a point at a speed for dt seconds; true once it is there
local function stepToward(a: Actor, target: Vector3, speed: number, dt: number): boolean
	local from = ground(a)
	local d = flat(target) - from
	local dist = d.Magnitude
	if dist < 1e-3 then
		setVelocity(a, Vector3.zero)
		return true
	end
	local step = math.min(dist, speed * dt)
	place(a, from + d.Unit * step, d)
	setVelocity(a, d.Unit * (dt > 0 and step / dt or 0))
	return step >= dist - 1e-3
end

local function setMode(a: Actor, mode: string)
	a.mode = mode
	a.model:SetAttribute("Mode", mode)
end

local function sync()
	-- the play's state, for the HUD and the agent
	playState:SetAttribute("Phase", state.phase)
	playState:SetAttribute("Result", state.result)
	playState:SetAttribute("Carrier", state.carrier)
	playState:SetAttribute("BallState", state.ballState)
	playState:SetAttribute("YardsToGoal", state.yardsToGoal)
	playState:SetAttribute("LineOfScrimmageZ", state.losZ)
	playState:SetAttribute("PlayId", state.playId)
	playState:SetAttribute("SnapTime", state.snapAt)
	local p = quarterback()
	playState:SetAttribute("Quarterback", p and p.Name or "")
	ball:SetAttribute("State", state.ballState)
	ball:SetAttribute("Carrier", state.ballState == "Held" and state.carrier or "")
end

local function message(text: string)
	playState:SetAttribute("Message", text)
	playState:SetAttribute("MessageId", ((playState:GetAttribute("MessageId") :: number?) or 0) + 1)
end

local function setWalk(enabled: boolean)
	local hum = qbHumanoid()
	if hum then
		hum.WalkSpeed = enabled and 16 or 0
		hum.JumpPower = enabled and 50 or 0
		hum.JumpHeight = enabled and 7.2 or 0
	end
end

-- the model that has the ball (the QB's character, or a receiver), for the BallCarrier tag
local function carrierModel(): Model?
	if state.carrier == "QB" then
		local p = quarterback()
		return p and p.Character or nil
	end
	local a = actors[state.carrier]
	return a and a.model or nil
end

-- where the ball carrier is on the field, or nil
local function carrierPosition(): Vector3?
	if state.carrier == "QB" then
		local r = qbRoot()
		return r and flat(r.Position) or nil
	end
	local a = actors[state.carrier]
	return a and ground(a) or nil
end

local function retag()
	for _, inst in ipairs(CollectionService:GetTagged(Tags.BallCarrier)) do
		CollectionService:RemoveTag(inst, Tags.BallCarrier)
	end
	if state.ballState == "Held" and state.phase ~= "Dead" then
		local m = carrierModel()
		if m then
			CollectionService:AddTag(m, Tags.BallCarrier)
		end
	end
end

-- -- making the players ---------------------------------------------------------------------------------------------

local function makeActor(name: string, kind: string, parent: Folder, color: Color3): Actor
	local model = Instance.new("Model")
	model.Name = name
	local body = Instance.new("Part")
	body.Name = "HumanoidRootPart" -- no Humanoid: these players are moved by the server, not by physics
	body.Size = Vector3.new(2, BODY_HEIGHT, 1)
	body.Color = color
	body.Anchored = true
	body.CanCollide = false
	body.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.4, 1.4, 1.4)
	head.Color = color
	head.Anchored = true
	head.CanCollide = false
	head.CFrame = body.CFrame * CFrame.new(0, BODY_HEIGHT / 2 + 0.7, 0)
	head.Parent = model
	model.PrimaryPart = body
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(60, 24)
	tag.StudsOffset = Vector3.new(0, 2, 0)
	tag.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = name
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = tag
	tag.Parent = head
	model.Parent = parent
	local a: Actor = {
		name = name,
		kind = kind,
		model = model,
		root = body,
		mode = "Set",
		assignment = "",
		waypoints = {},
		leg = 1,
		spawned = false,
	}
	actors[name] = a
	table.insert(order, name)
	CollectionService:AddTag(model, kind == "Receiver" and Tags.Receiver or Tags.Defender)
	return a
end

local function removeActor(name: string)
	local a = actors[name]
	if a then
		a.model:Destroy()
		actors[name] = nil
		local i = table.find(order, name)
		if i then
			table.remove(order, i)
		end
	end
end

local function routeEnd(name: string): BasePart
	local existing = markers:FindFirstChild(name)
	if existing and existing:IsA("BasePart") then
		return existing
	end
	local disc = Instance.new("Part")
	disc.Name = name
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.1, 4, 4)
	disc.Color = Color3.fromRGB(255, 220, 60)
	disc.Transparency = 0.5
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanTouch = false
	disc.CanQuery = false
	disc:SetAttribute("Receiver", name)
	disc.Parent = markers
	CollectionService:AddTag(disc, Tags.RouteEnd)
	return disc
end

-- -- the ball -------------------------------------------------------------------------------------------------------

local function holdBall()
	if state.carrier == "QB" then
		local r = qbRoot()
		if r then
			ball.CFrame = r.CFrame * CFrame.new(0.9, 0.3, -0.8)
		end
	else
		local a = actors[state.carrier]
		if a then
			ball.CFrame = a.root.CFrame * CFrame.new(0.9, 0.3, -0.8)
		end
	end
end

-- The velocity that sends the ball from origin through target at a speed: the flatter arc, or 45 degrees (the
-- longest throw) when the target is out of reach
local function launch(origin: Vector3, target: Vector3, speed: number): Vector3
	local g = BallConfig.Gravity
	local horizontal = flat(target - origin)
	local x = horizontal.Magnitude
	local dir = x > 1e-3 and horizontal.Unit or Vector3.new(0, 0, 1)
	local y = target.Y - origin.Y
	local v2 = speed * speed
	local angle = math.rad(45)
	if x > 1e-3 then
		local disc = v2 * v2 - g * (g * x * x + 2 * y * v2)
		if disc >= 0 then
			angle = math.atan((v2 - math.sqrt(disc)) / (g * x))
		end
	end
	return dir * (speed * math.cos(angle)) + UP * (speed * math.sin(angle))
end

-- Where (on the way down) the ball passes CatchHeight
local function landing(origin: Vector3, velocity: Vector3): Vector3
	local g = BallConfig.Gravity
	local drop = BallConfig.CatchHeight - origin.Y
	local disc = velocity.Y * velocity.Y - 2 * g * drop
	local t = (velocity.Y + math.sqrt(math.max(disc, 0))) / g
	local p = origin + flat(velocity) * t
	return Vector3.new(p.X, BallConfig.CatchHeight, p.Z)
end

-- -- the play -------------------------------------------------------------------------------------------------------

local function endPlay(result: string, text: string)
	if state.phase == "Dead" then
		return
	end
	state.phase = "Dead"
	state.result = result
	if result ~= "Incomplete" and result ~= "Intercepted" then
		state.ballState = "Held"
	end
	state.throw = nil
	for _, name in ipairs(order) do
		local a = actors[name]
		if a then
			setVelocity(a, Vector3.zero)
		end
	end
	if result == "Touchdown" then
		local points = stat("Points")
		if points then
			points.Value += Config.TouchdownPoints
		end
		local tds = stat("Touchdowns")
		if tds then
			tds.Value += 1
		end
	end
	setWalk(false)
	playState:SetAttribute("LastResult", result)
	playState:SetAttribute("LastResultPlayId", state.playId)
	sync()
	retag()
	message(text)
	local token = state.token
	task.delay(Config.ResetSeconds, function()
		if state.token == token then
			Football.reset(nil)
		end
	end)
end

function Football.snap()
	if state.phase ~= "PreSnap" then
		return
	end
	state.phase = "Live"
	state.snapAt = now()
	for _, name in ipairs(order) do
		local a = actors[name]
		if a then
			if a.kind == "Receiver" then
				setMode(a, "Route")
			elseif a.assignment == "Rush" then
				setMode(a, "Rush")
			elseif a.assignment == "Pursue" then
				setMode(a, "Pursue")
			else
				setMode(a, "Cover")
			end
		end
	end
	setWalk(true)
	sync()
	message("Hike!")
end

-- Puts everyone back in the formation at a line of scrimmage (yards to the scoring goal line, 1-99; nil keeps the
-- current one) and snaps the ball Config.SnapSeconds later. Spawned defenders are removed. Returns the new PlayId.
function Football.reset(yardsToGoal: number?): number
	state.token += 1
	state.playId += 1
	if yardsToGoal then
		state.yardsToGoal = math.clamp(math.floor(yardsToGoal + 0.5), 1, 99)
	end
	state.losZ = Config.losZ(state.yardsToGoal)
	state.phase = "PreSnap"
	state.result = ""
	state.carrier = "QB"
	state.ballState = "Held"
	state.throw = nil
	state.snapAt = 0

	for _, name in ipairs(table.clone(order)) do
		if actors[name] and actors[name].spawned then
			removeActor(name)
		end
	end

	for _, r in ipairs(Config.Receivers) do
		local a = actors[r.name] or makeActor(r.name, "Receiver", offense, Color3.fromRGB(240, 240, 240))
		a.assignment = r.route
		a.model:SetAttribute("Route", r.route)
		a.waypoints = {}
		for _, w in ipairs(r.waypoints) do
			table.insert(a.waypoints, onField(w))
		end
		a.leg = 1
		setMode(a, "Set")
		place(a, onField(r.start), Vector3.new(0, 0, 1))
		setVelocity(a, Vector3.zero)
		local disc = routeEnd(r.name)
		local last = a.waypoints[#a.waypoints]
		disc.CFrame = CFrame.new(last + UP * 0.07) * CFrame.Angles(0, 0, math.rad(90))
	end
	for _, d in ipairs(Config.Defenders) do
		local a = actors[d.name] or makeActor(d.name, "Defender", defense, Color3.fromRGB(200, 60, 40))
		a.assignment = d.assignment
		a.model:SetAttribute("Assignment", d.assignment)
		setMode(a, "Set")
		place(a, onField(d.start), Vector3.new(0, 0, -1))
		setVelocity(a, Vector3.zero)
	end

	if los then
		los.Position = Vector3.new(0, los.Position.Y, state.losZ)
		los:SetAttribute("YardsToGoal", state.yardsToGoal)
	end

	local p = quarterback()
	local character = p and p.Character
	if character then
		local at = onField(Config.QuarterbackStart) + UP * 3
		character:PivotTo(CFrame.lookAt(at, at + Vector3.new(0, 0, 1)))
		local r = qbRoot()
		if r then
			r.AssemblyLinearVelocity = Vector3.zero
		end
		CollectionService:AddTag(character, Tags.Quarterback)
	end
	setWalk(false)
	holdBall()
	sync()
	retag()
	local ytg = state.yardsToGoal
	message(string.format("Play %d: %d yards to go. Snap in %d...", state.playId, ytg, Config.SnapSeconds))

	local token = state.token
	task.delay(Config.SnapSeconds, function()
		if state.token == token then
			Football.snap()
		end
	end)
	return state.playId
end

-- The QB throws toward a point (only y = CatchHeight is used for height) with a power (0-1). Errors say why a throw
-- isn't allowed: the play isn't live, the QB doesn't have the ball, or the QB is past the line of scrimmage.
function Football.throw(target: Vector3, power: number)
	assert(state.phase == "Live", "the play isn't live")
	assert(state.carrier == "QB" and state.ballState == "Held", "the QB doesn't have the ball")
	local r = qbRoot()
	assert(r, "the QB has no character")
	assert(r.Position.Z < state.losZ, "the QB is past the line of scrimmage: no forward pass from there")
	local p = math.clamp(power, BallConfig.MinPower, 1)
	local speed = BallConfig.MinSpeed + (BallConfig.MaxSpeed - BallConfig.MinSpeed) * p
	local origin = r.Position + UP * BallConfig.ReleaseHeight
	local aim = Vector3.new(target.X, BallConfig.CatchHeight, target.Z)
	local velocity = launch(origin, aim, speed)
	state.throw = { origin = origin, velocity = velocity, at = now(), landing = landing(origin, velocity) }
	state.ballState = "Air"
	state.carrier = ""
	ball:SetAttribute("Power", p)
	ball:SetAttribute("Landing", (state.throw :: Throw).landing)
	sync()
	retag()
end

local function giveBall(name: string)
	state.carrier = name
	state.ballState = "Held"
	state.throw = nil
	local a = actors[name]
	if a and a.kind == "Receiver" then
		setMode(a, "RunAfterCatch")
	end
	sync()
	retag()
end

-- -- every frame ----------------------------------------------------------------------------------------------------

local function stepReceiver(a: Actor, dt: number)
	if a.mode == "Route" then
		local target = a.waypoints[a.leg]
		if not target then
			setMode(a, "Settled")
			setVelocity(a, Vector3.zero)
			return
		end
		if stepToward(a, target, Config.RouteSpeed, dt) then
			a.leg += 1
			if a.leg > #a.waypoints then
				setMode(a, "Settled")
				setVelocity(a, Vector3.zero)
			end
		end
	elseif a.mode == "RunAfterCatch" then
		local pos = ground(a)
		stepToward(a, Vector3.new(pos.X, 0, Config.EndLineZ + 10), Config.RunAfterCatchSpeed, dt)
	else
		setVelocity(a, Vector3.zero)
	end
end

local function stepDefender(a: Actor, dt: number)
	if state.ballState == "Air" and state.throw then
		setMode(a, "Ball")
		stepToward(a, (state.throw :: Throw).landing, Config.CoverSpeed, dt)
		return
	end
	local carrierAt = carrierPosition()
	if not carrierAt then
		setVelocity(a, Vector3.zero)
		return
	end
	local qbInPocket = state.carrier == "QB" and carrierAt.Z < state.losZ
	if not qbInPocket or a.assignment == "Pursue" then
		setMode(a, "Pursue")
		stepToward(a, carrierAt, Config.PursueSpeed, dt)
	elseif a.assignment == "Rush" then
		setMode(a, "Rush")
		if now() - state.snapAt >= Config.RushDelay then
			stepToward(a, carrierAt, Config.RushSpeed, dt)
		else
			setVelocity(a, Vector3.zero)
		end
	else
		setMode(a, "Cover")
		local mark = actors[a.assignment]
		if mark then
			local at = ground(mark)
			local toQb = carrierAt - at
			local spot = toQb.Magnitude > 1e-3 and at + toQb.Unit * Config.CoverGap or at
			stepToward(a, spot, Config.CoverSpeed, dt)
		else
			setVelocity(a, Vector3.zero)
		end
	end
end

local function stepBall()
	local throw = state.throw
	if not throw then
		return
	end
	local t = now() - throw.at
	local p = throw.origin + throw.velocity * t - UP * (0.5 * BallConfig.Gravity * t * t)
	ball.CFrame = CFrame.lookAt(p, p + throw.velocity - UP * (BallConfig.Gravity * t))

	-- a catch: the closest receiver or defender in reach, once the ball is low enough and has travelled a little
	if p.Y <= BallConfig.CatchMaxHeight and flat(p - throw.origin).Magnitude >= BallConfig.MinCatchDistance then
		local best: Actor? = nil
		local bestDist = BallConfig.CatchRadius
		for _, name in ipairs(order) do
			local a = actors[name]
			if a then
				local d = flat(p - a.root.Position).Magnitude
				if d <= bestDist then
					best, bestDist = a, d
				end
			end
		end
		if best then
			if best.kind == "Receiver" then
				giveBall(best.name)
				local completions = stat("Completions")
				if completions then
					completions.Value += 1
				end
				message(best.name .. " makes the catch!")
			else
				state.carrier = best.name
				state.ballState = "Held"
				state.throw = nil
				ball.CFrame = best.root.CFrame * CFrame.new(0.9, 0.3, -0.8)
				endPlay("Intercepted", "Intercepted by " .. best.name)
			end
			return
		end
	end

	if math.abs(p.X) > Config.HalfWidth or math.abs(p.Z) > Config.EndLineZ then
		state.ballState = "Ground"
		endPlay("Incomplete", "Incomplete: out of bounds")
	elseif p.Y <= BallConfig.Radius then
		ball.Position = Vector3.new(p.X, BallConfig.Radius, p.Z)
		state.ballState = "Ground"
		endPlay("Incomplete", "Incomplete")
	end
end

-- the carrier's fate: a touchdown, out of bounds, a safety or a tackle
local function checkCarrier()
	if state.ballState ~= "Held" then
		return
	end
	local at = carrierPosition()
	if not at then
		return
	end
	local who = state.carrier == "QB" and "the QB" or state.carrier
	if math.abs(at.X) > Config.HalfWidth then
		endPlay("OutOfBounds", who .. " ran out of bounds")
		return
	end
	if at.Z >= Config.GoalZ then
		endPlay("Touchdown", "TOUCHDOWN! " .. who .. " scores")
		return
	end
	if at.Z <= Config.OwnGoalZ then
		endPlay("Safety", "Safety: " .. who .. " was brought down behind the goal line")
		return
	end
	for _, name in ipairs(order) do
		local a = actors[name]
		if a and a.kind == "Defender" and flat(a.root.Position - at).Magnitude <= Config.TackleRadius then
			playState:SetAttribute("Tackler", a.name)
			local yards = (at.Z - state.losZ) / Config.StudsPerYard
			endPlay("Tackled", string.format("%s tackled by %s (%+.0f yards)", who, a.name, yards))
			return
		end
	end
end

local function step(dt: number)
	if state.phase == "Live" then
		for _, name in ipairs(table.clone(order)) do
			local a = actors[name]
			if a then
				if a.kind == "Receiver" then
					stepReceiver(a, dt)
				else
					stepDefender(a, dt)
				end
			end
		end
		if state.ballState == "Air" then
			stepBall()
		end
		if state.phase == "Live" then
			checkCarrier()
		end
	end
	if state.ballState == "Held" then
		holdBall()
	end
end

-- -- commands (ServerStorage.FootballCommand; see Debug.luau) -------------------------------------------------------

-- Gives the ball to someone: "QB" (or the player's name), or a receiver ("X", "Y", "Z"). A play before the snap is
-- snapped first; a dead play can't be given the ball (ResetPlay first).
function Football.setBallCarrier(name: string): string
	assert(state.phase ~= "Dead", "the play is over: ResetPlay first")
	local p = quarterback()
	local who = name
	if name == "QB" or (p and name == p.Name) then
		who = "QB"
	else
		local a = actors[name]
		assert(a and a.kind == "Receiver", "no receiver named " .. tostring(name) .. " (X, Y, Z or QB)")
	end
	if state.phase == "PreSnap" then
		Football.snap()
	end
	giveBall(who)
	return who
end

-- Adds a defender at a point on the field (studs) who chases the ball carrier from the snap at Config.PursueSpeed;
-- gone at the next reset. Returns its name.
function Football.spawnDefender(x: number, z: number): string
	state.spawnedCount += 1
	local name = "D" .. state.spawnedCount
	local a = makeActor(name, "Defender", defense, Color3.fromRGB(150, 30, 160))
	a.assignment = "Pursue"
	a.spawned = true
	a.model:SetAttribute("Assignment", "Pursue")
	setMode(a, state.phase == "Live" and "Pursue" or "Set")
	place(a, Vector3.new(x, 0, z), Vector3.new(0, 0, -1))
	setVelocity(a, Vector3.zero)
	return name
end

-- Removes every defender (the formation's come back at the next reset). Returns how many were removed.
function Football.clearDefenders(): number
	local n = 0
	for _, name in ipairs(table.clone(order)) do
		local a = actors[name]
		if a and a.kind == "Defender" then
			removeActor(name)
			n += 1
		end
	end
	return n
end

function Football.score(): { [string]: number }
	local points = stat("Points")
	local tds = stat("Touchdowns")
	local completions = stat("Completions")
	return {
		Points = points and points.Value or 0,
		Touchdowns = tds and tds.Value or 0,
		Completions = completions and completions.Value or 0,
	}
end

function Football.snapshot(): { [string]: any }
	local where: { [string]: Vector3 } = {}
	for _, name in ipairs(order) do
		local a = actors[name]
		if a then
			where[name] = a.root.Position
		end
	end
	local r = qbRoot()
	if r then
		where.QB = r.Position
	end
	return {
		Phase = state.phase,
		Result = state.result,
		Carrier = state.carrier,
		BallState = state.ballState,
		Ball = ball.Position,
		YardsToGoal = state.yardsToGoal,
		LineOfScrimmageZ = state.losZ,
		PlayId = state.playId,
		Positions = where,
		Score = Football.score(),
	}
end

local function stats(player: Player)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	for _, name in ipairs({ "Points", "Touchdowns", "Completions" }) do
		local v = Instance.new("IntValue")
		v.Name = name
		v.Parent = ls
	end
	ls.Parent = player
end

-- Makes the ball and the players, binds the commands and the ThrowBall remote, and starts the first play
function Football.start(field: Folder)
	root = Instance.new("Folder")
	root.Name = "Football"
	offense = Instance.new("Folder")
	offense.Name = "Offense"
	offense.Parent = root
	defense = Instance.new("Folder")
	defense.Name = "Defense"
	defense.Parent = root
	markers = Instance.new("Folder")
	markers.Name = "RouteEnds"
	markers.Parent = root

	ball = Instance.new("Part")
	ball.Name = "Football"
	ball.Size = Vector3.new(0.8, 0.8, 1.4)
	ball.Color = Color3.fromRGB(120, 60, 25)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanTouch = false
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = ball
	ball.Parent = root
	CollectionService:AddTag(ball, Tags.Football)
	root.Parent = workspace

	local found = field:FindFirstChild("LineOfScrimmage")
	los = (found and found:IsA("BasePart")) and found or nil

	playState = ReplicatedStorage:WaitForChild("PlayState") :: Configuration
	CollectionService:AddTag(playState, Tags.PlayState)

	local remotes = ReplicatedStorage:WaitForChild("Remotes")
	local throwBall = remotes:WaitForChild("ThrowBall") :: RemoteEvent
	throwBall.OnServerEvent:Connect(function(player: Player, target: any, power: any)
		if player ~= quarterback() or typeof(target) ~= "Vector3" or typeof(power) ~= "number" then
			return
		end
		-- NaN or infinite numbers from a client are refused
		if power ~= power or math.abs(power) == math.huge or not (target.Magnitude < math.huge) then
			return
		end
		local ok, err = pcall(Football.throw, target, power)
		if not ok then
			message("Can't throw: " .. tostring(err))
		end
	end)

	Players.PlayerAdded:Connect(function(player)
		stats(player)
		player.CharacterAdded:Connect(function()
			if player == quarterback() then
				task.defer(Football.reset, nil)
			end
		end)
	end)
	for _, player in ipairs(Players:GetPlayers()) do
		if not player:FindFirstChild("leaderstats") then
			stats(player)
		end
		player.CharacterAdded:Connect(function()
			if player == quarterback() then
				task.defer(Football.reset, nil)
			end
		end)
	end

	RunService.Heartbeat:Connect(step)
	Football.reset(Config.DefaultYardsToGoal)
end

return Football

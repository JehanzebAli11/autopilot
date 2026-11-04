--!strict
-- Prism Gauntlet's rules, on the server: each player's stats (leaderstats Stage and Deaths; attributes RunStart,
-- Finished, FinishSeconds), checkpoints, what kills (hazards, the void), the timed parts (laser gates, phase blocks)
-- and the crumbling tiles, the finish, and a log line for everything that happens.
--
-- The log: every event is one line in Studio's Output, `[Gauntlet] {json}`, with the play session's id (`session`),
-- the seconds since the session started (`t`) and the time of day (`wall`, Unix seconds): session, spawn, checkpoint,
-- death (with its cause), finish, and debug (a Debug helper changed the run). A run's deaths and progress are counted
-- from these lines (tools/learning_curve.py), by the game rather than by whoever plays it.

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Clock = require(ReplicatedStorage:WaitForChild("Clock"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local StageReached = Remotes:WaitForChild("StageReached") :: RemoteEvent
local Died = Remotes:WaitForChild("Died") :: RemoteEvent
local Finished = Remotes:WaitForChild("Finished") :: RemoteEvent

local Tags = Config.Tags
local Rules = {}

-- The play session: its id and when it started, kept on workspace so every copy of this module logs the same session
-- (a Debug call made from outside the game's own scripts, such as Studio's command bar, gets a copy of its own)
local function session(): (string, number)
	local id = workspace:GetAttribute("GauntletSession") :: string?
	if not id then
		id = string.sub(HttpService:GenerateGUID(false), 1, 8)
		workspace:SetAttribute("GauntletSession", id)
		workspace:SetAttribute("GauntletStarted", os.clock())
	end
	return id :: string, workspace:GetAttribute("GauntletStarted") :: number
end

local function log(event: string, fields: { [string]: any }?)
	local id, started = session()
	local line = fields or {}
	line.event = event
	line.session = id
	line.t = math.floor((os.clock() - started) * 100 + 0.5) / 100
	line.wall = os.time()
	print("[Gauntlet] " .. HttpService:JSONEncode(line))
end
Rules.log = log

-- -- players ---------------------------------------------------------------------------------------------------------

local lastCause: { [Player]: { kind: string, at: number } } = {}

local function stats(player: Player)
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	local stage = Instance.new("IntValue")
	stage.Name = "Stage"
	stage.Parent = ls
	local deaths = Instance.new("IntValue")
	deaths.Name = "Deaths"
	deaths.Parent = ls
	ls.Parent = player
	player:SetAttribute("RunStart", Clock.now())
	player:SetAttribute("Finished", false)
end

local function stageOf(player: Player): IntValue
	return (player:WaitForChild("leaderstats") :: Folder):WaitForChild("Stage") :: IntValue
end

local function playerOf(hit: BasePart): (Player?, Humanoid?)
	local model = hit:FindFirstAncestorOfClass("Model")
	local hum = model and model:FindFirstChildOfClass("Humanoid")
	if not model or not hum or hum.Health <= 0 then
		return nil, nil
	end
	return Players:GetPlayerFromCharacter(model), hum
end

-- Where a player at `stage` (re)spawns: the top of that checkpoint's island (the start at stage 0)
local function spawnPoint(stage: number): Vector3?
	for _, island in ipairs(CollectionService:GetTagged(Tags.Checkpoint)) do
		if island:GetAttribute("Stage") == stage then
			local p = island :: BasePart
			return p.Position + Vector3.new(0, p.Size.Y / 2 + 3, 0)
		end
	end
	return nil
end
Rules.spawnPoint = spawnPoint

local function onCharacter(player: Player, character: Model)
	local stage = stageOf(player).Value
	local hum = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local at = stage > 0 and spawnPoint(stage) or nil
	if at then
		task.defer(function()
			character:PivotTo(CFrame.new(at))
			root.AssemblyLinearVelocity = Vector3.zero
		end)
	end
	log("spawn", { player = player.Name, stage = stage })
	hum.Died:Connect(function()
		local deaths = (player:FindFirstChild("leaderstats") :: Folder):FindFirstChild("Deaths") :: IntValue
		deaths.Value += 1
		local c = lastCause[player]
		local cause = (c and os.clock() - c.at < 2) and c.kind or "Unknown"
		lastCause[player] = nil
		local p = root.Position
		log("death", { player = player.Name, stage = stageOf(player).Value, cause = cause, deaths = deaths.Value,
			at = { x = math.floor(p.X * 10) / 10, y = math.floor(p.Y * 10) / 10, z = math.floor(p.Z * 10) / 10 } })
		Died:FireClient(player, cause, stageOf(player).Value)
	end)
end

-- -- checkpoints and the finish --------------------------------------------------------------------------------------

local function reach(player: Player, stage: number, name: string)
	local value = stageOf(player)
	if stage > value.Value then
		value.Value = stage
		log("checkpoint", { player = player.Name, stage = stage, name = name })
		StageReached:FireClient(player, stage, name)
	end
end

local function watchCheckpoint(island: BasePart)
	local stage = island:GetAttribute("Stage") :: number
	local name = Config.Stages[stage] and Config.Stages[stage].name or ""
	island.Touched:Connect(function(hit)
		local player = playerOf(hit)
		if player then
			reach(player, stage, name)
		end
	end)
end

local function watchFinish(line: BasePart)
	line.Touched:Connect(function(hit)
		local player = playerOf(hit)
		if not player or player:GetAttribute("Finished") then
			return
		end
		local seconds = math.floor((Clock.now() - (player:GetAttribute("RunStart") :: number)) * 100 + 0.5) / 100
		player:SetAttribute("Finished", true)
		player:SetAttribute("FinishSeconds", seconds)
		reach(player, Config.FinalStage, "Finish")
		local deaths = ((player:FindFirstChild("leaderstats") :: Folder):FindFirstChild("Deaths") :: IntValue).Value
		log("finish", { player = player.Name, seconds = seconds, deaths = deaths })
		Finished:FireAllClients(player.Name, seconds, deaths)
		local confetti = line:FindFirstChild("Confetti") :: ParticleEmitter?
		if confetti then
			confetti:Emit(220)
		end
	end)
end

-- -- what kills ------------------------------------------------------------------------------------------------------

local function watchHazard(part: BasePart)
	local kind = (part:GetAttribute("Kind") :: string?) or "Hazard"
	part.Touched:Connect(function(hit)
		if part:GetAttribute("Active") == false then
			return
		end
		local player, hum = playerOf(hit)
		if hum then
			if player then
				lastCause[player] = { kind = kind, at = os.clock() }
			end
			hum.Health = 0
		end
	end)
end

-- -- timed parts: laser gates and phase blocks, set from the shared clock ---------------------------------------------

local function setLaser(laser: BasePart, on: boolean)
	laser:SetAttribute("Active", on)
	laser.Transparency = on and 0.78 or 1
	laser.CanTouch = on
	for _, beam in ipairs(laser:GetChildren()) do
		if beam:IsA("Beam") then
			beam.Enabled = on
		end
	end
end

local function setPhase(block: BasePart, solid: boolean)
	block:SetAttribute("Solid", solid)
	block.CanCollide = solid
	block.Transparency = solid and 0.15 or 0.85
end

local function timers()
	RunService.Heartbeat:Connect(function()
		local now = Clock.now()
		for _, part in ipairs(CollectionService:GetTagged(Tags.Hazard)) do
			local p = part :: BasePart
			local period = p:GetAttribute("Period") :: number?
			if period then
				local on = Clock.on(period, p:GetAttribute("OnSeconds") :: number, p:GetAttribute("Offset") :: number, now)
				if on ~= p:GetAttribute("Active") then
					setLaser(p, on)
				end
			end
		end
		for _, part in ipairs(CollectionService:GetTagged(Tags.Phase)) do
			local p = part :: BasePart
			local solid = Clock.on(p:GetAttribute("Period") :: number, p:GetAttribute("OnSeconds") :: number,
				p:GetAttribute("Offset") :: number, now)
			if solid ~= p:GetAttribute("Solid") then
				setPhase(p, solid)
			end
		end
	end)
end

-- -- crumbling tiles -------------------------------------------------------------------------------------------------

local function watchCrumble(tile: BasePart)
	local color = tile.Color
	tile.Touched:Connect(function(hit)
		if tile:GetAttribute("State") ~= "solid" or not playerOf(hit) then
			return
		end
		tile:SetAttribute("State", "cracking")
		tile.Color = Color3.new(1, 1, 1)
		TweenService:Create(tile, TweenInfo.new(tile:GetAttribute("Delay") :: number), { Color = color }):Play()
		task.delay(tile:GetAttribute("Delay") :: number, function()
			tile:SetAttribute("State", "gone")
			tile.CanCollide = false
			TweenService:Create(tile, TweenInfo.new(0.25), { Transparency = 1 }):Play()
			task.delay(tile:GetAttribute("Back") :: number, function()
				tile.CanCollide = true
				tile.Transparency = 0
				tile:SetAttribute("State", "solid")
			end)
		end)
	end)
end

-- -- start -----------------------------------------------------------------------------------------------------------

local function each(tagName: string, fn: (any) -> ())
	for _, inst in ipairs(CollectionService:GetTagged(tagName)) do
		fn(inst)
	end
	CollectionService:GetInstanceAddedSignal(tagName):Connect(fn)
end

function Rules.start()
	Players.RespawnTime = Config.RespawnSeconds
	each(Tags.Checkpoint, watchCheckpoint)
	each(Tags.Finish, watchFinish)
	each(Tags.Hazard, watchHazard)
	each(Tags.Crumble, watchCrumble)
	timers()
	local function join(player: Player)
		stats(player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			onCharacter(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(join)
	for _, player in ipairs(Players:GetPlayers()) do
		join(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastCause[player] = nil
	end)
	log("session", { place = Config.Name, stages = #Config.Stages })
end

return Rules

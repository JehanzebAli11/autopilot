--!strict
-- Debug helpers for testing the course (ServerScriptService/Debug, a ModuleScript on the server). A tester calls them
-- to set up a check: game.call("ServerScriptService/Debug", "GoTo", args=[name, 4]). They change the game directly, as
-- no player could, so they are never part of playing it: a run that uses them didn't earn what it reached, and each
-- use is logged (`[Gauntlet] {"event": "debug", ...}`) so a count of a run's progress can tell.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Rules = require(script.Parent:WaitForChild("Rules"))

local Debug = {}

local function player(name: string?): Player
	local p = name and Players:FindFirstChild(name) or Players:GetPlayers()[1]
	assert(p and p:IsA("Player"), "no player " .. tostring(name))
	return p :: Player
end

local function leaderstat(p: Player, stat: string): IntValue
	return (p:WaitForChild("leaderstats") :: Folder):WaitForChild(stat) :: IntValue
end

-- Sets a player's stage (0: the start): their next spawn is on that checkpoint's island
function Debug.SetStage(name: string?, stage: number): number
	local p = player(name)
	local value = leaderstat(p, "Stage")
	value.Value = math.clamp(math.floor(stage), 0, Config.FinalStage - 1)
	Rules.log("debug", { player = p.Name, fn = "SetStage", stage = value.Value })
	return value.Value
end

-- Puts a player's character on a checkpoint's island (0: the start), setting their stage to it; returns where
function Debug.GoTo(name: string?, stage: number): Vector3
	local p = player(name)
	local s = Debug.SetStage(name, stage)
	local at = s > 0 and Rules.spawnPoint(s) or Vector3.new(0, 4, 6)
	local character = p.Character
	assert(character, "the player has no character")
	character:PivotTo(CFrame.new(at :: Vector3))
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart
	root.AssemblyLinearVelocity = Vector3.zero
	return root.Position
end

-- A player's run so far: stage, deaths, finished, seconds (the finish time, or the time so far)
function Debug.Stats(name: string?): { [string]: any }
	local p = player(name)
	local finished = p:GetAttribute("Finished") == true
	return {
		stage = leaderstat(p, "Stage").Value,
		deaths = leaderstat(p, "Deaths").Value,
		finished = finished,
		seconds = finished and p:GetAttribute("FinishSeconds")
			or workspace:GetServerTimeNow() - (p:GetAttribute("RunStart") :: number),
	}
end

-- Starts a player's run over: stage 0, no deaths, the clock reset, the character back at the start
function Debug.Reset(name: string?): boolean
	local p = player(name)
	leaderstat(p, "Stage").Value = 0
	leaderstat(p, "Deaths").Value = 0
	p:SetAttribute("Finished", false)
	p:SetAttribute("FinishSeconds", nil)
	p:SetAttribute("RunStart", workspace:GetServerTimeNow())
	p:LoadCharacter()
	Rules.log("reset", { player = p.Name })
	return true
end

return Debug

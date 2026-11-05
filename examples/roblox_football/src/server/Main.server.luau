--!strict
-- Starts the place on the server: builds the field (Build.luau), starts the practice play (Football.luau), and
-- answers ServerStorage.FootballCommand, the BindableFunction Debug.luau calls. The commands go through a
-- BindableFunction rather than a shared module so that Debug works from any Luau context (a command run by Studio's
-- MCP server may not share this script's copy of the Football module).

local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Build = require(ServerScriptService:WaitForChild("Build"))
local Football = require(ServerScriptService:WaitForChild("Football"))

local commands: { [string]: (...any) -> any } = {
	ResetPlay = function(yardsToGoal: any)
		assert(yardsToGoal == nil or type(yardsToGoal) == "number", "ResetPlay(yardsToGoal?): a number of yards, 1-99")
		return Football.reset(yardsToGoal)
	end,
	Snap = function()
		Football.snap()
		return true
	end,
	SetBallCarrier = function(name: any)
		assert(type(name) == "string", "SetBallCarrier(name): QB, X, Y or Z")
		return Football.setBallCarrier(name)
	end,
	SpawnDefender = function(x: any, z: any)
		assert(type(x) == "number" and type(z) == "number", "SpawnDefender(x, z): a point on the field, in studs")
		return Football.spawnDefender(x, z)
	end,
	ClearDefenders = function()
		return Football.clearDefenders()
	end,
	Throw = function(x: any, z: any, power: any)
		assert(type(x) == "number" and type(z) == "number" and type(power) == "number", "Throw(x, z, power)")
		Football.throw(Vector3.new(x, 0, z), power)
		return true
	end,
	GetScore = function()
		return Football.score()
	end,
	GetState = function()
		return Football.snapshot()
	end,
}

local command = ServerStorage:WaitForChild("FootballCommand") :: BindableFunction
command.OnInvoke = function(name: string, ...: any): any
	local fn = commands[name]
	assert(fn, "no football command " .. tostring(name))
	return fn(...)
end

Football.start(Build.field())

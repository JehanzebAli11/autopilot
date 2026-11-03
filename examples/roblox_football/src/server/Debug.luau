--!strict
-- Debug helpers for testing the practice play (ServerScriptService/Debug, a ModuleScript on the server). An agent
-- calls them to set up or read a verification: game.call("ServerScriptService/Debug", "ResetPlay", args=[20]).
-- They change the game directly, as no player could: never part of playing it. Each goes through
-- ServerStorage.FootballCommand (a BindableFunction answered by Main.server.luau), so it works from any Luau context.
-- Positions are studs: the offense attacks +z, the scoring goal line is at z = 100, the field is x in [-53, 53].

local ServerStorage = game:GetService("ServerStorage")

local Debug = {}

local function command(name: string, ...: any): any
	local fn = ServerStorage:WaitForChild("FootballCommand", 5) :: BindableFunction?
	assert(fn, "ServerStorage.FootballCommand is missing: is the game running?")
	return fn:Invoke(name, ...)
end

-- Starts a new play from a line of scrimmage, in yards to the scoring goal line (1-99; nil keeps the current spot,
-- 20 is the red zone). Everyone goes back to the formation, spawned defenders are removed, and the ball is snapped
-- 3 s later. Returns the new play's PlayId.
function Debug.ResetPlay(yardsToGoal: number?): number
	return command("ResetPlay", yardsToGoal)
end

-- Snaps the ball now (a play before its snap); returns true
function Debug.Snap(): boolean
	return command("Snap")
end

-- Gives the ball to "QB" (the player) or a receiver ("X", "Y" or "Z"), snapping first if needed. A receiver with the
-- ball runs straight for the end zone. Errors when the play is over (ResetPlay first). Returns the carrier's name.
function Debug.SetBallCarrier(name: string): string
	return command("SetBallCarrier", name)
end

-- Adds a defender at (x, z) on the field who chases the ball carrier once the play is live, at 18 studs/s: faster
-- than the QB (16), slower than a receiver running after a catch (20). Gone at the next reset. Returns its name
-- ("D1", "D2"...).
function Debug.SpawnDefender(x: number, z: number): string
	return command("SpawnDefender", x, z)
end

-- Removes every defender until the next reset; returns how many were removed
function Debug.ClearDefenders(): number
	return command("ClearDefenders")
end

-- Throws as the QB would, toward (x, z) with a power 0-1, under the same rules (the play is live, the QB has the
-- ball and is behind the line of scrimmage; else it errors with the reason). For when the mouse can't be used.
function Debug.Throw(x: number, z: number, power: number): boolean
	return command("Throw", x, z, power)
end

-- The player's score: { Points, Touchdowns, Completions } (also in leaderstats)
function Debug.GetScore(): { [string]: number }
	return command("GetScore")
end

-- The play: { Phase, Result, Carrier, BallState, Ball, YardsToGoal, LineOfScrimmageZ, PlayId, Positions, Score }
-- (the same as ReplicatedStorage.PlayState's attributes, plus everyone's position)
function Debug.GetState(): { [string]: any }
	return command("GetState")
end

return Debug

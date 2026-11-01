--!strict
-- The play session's server: the game's authoritative state. Answers rc (reads, writes and calls on the server's
-- instances and modules: what the game's Scripts see and change), find and transforms on the server's instances,
-- pause, and ends the play session (`end_test`, StudioTestService:EndTest). Runs the server's detectors.
local RunService = game:GetService("RunService")

local Detectors = require(script.Parent.Detectors)
local Frame = require(script.Parent.Frame)
local Host = require(script.Parent.Host)
local Json = require(script.Parent.Json)
local Modules = require(script.Parent.Modules)
local Paths = require(script.Parent.Paths)
local Rc = require(script.Parent.Rc)
local World = require(script.Parent.World)

local Server = {}

function Server.start(plugin: Plugin)
	local host: any = nil
	local detectors: any = nil
	local paused = false

	local ops: { [string]: any } = {
		rc = function(args)
			return Rc.handle(tostring(args.verb or ""), args.body)
		end,
		find = function(args)
			return true, World.find(args)
		end,
		transforms = function(args)
			return true, World.transforms(args, Paths.resolve)
		end,
		ping = function()
			return true, { game_time = Frame.r2(World.gameTime()) }
		end,
		detectors = function(args)
			if detectors then
				detectors:configure(args)
			end
			return true, Json.object()
		end,
		-- `pause`: the whole simulation (physics and every script, both sides), as Studio's Pause button does
		pause = function(args)
			local want = args.paused == true
			local ok, err = pcall(function()
				if want then
					RunService:Pause()
				else
					RunService:Run()
				end
			end)
			if not ok then
				return false, "Roblox Studio didn't pause the play session: " .. tostring(err), 409
			end
			paused = want
			if detectors then
				detectors.paused = want
			end
			return true, { paused = paused }
		end,
		end_test = function()
			local ok, err = pcall(function()
				game:GetService("StudioTestService"):EndTest(Json.object())
			end)
			if not ok then
				return false, "couldn't end the play session: " .. tostring(err), 500
			end
			return true, { running = false }
		end,
	}

	host = Host.new(plugin, "server", ops)
	host.onAttach = function(frame)
		Modules.install()
		if detectors == nil then
			detectors = Detectors.new(function(e)
				host:emit(e)
			end, World.gameTime, nil)
		end
		if type(frame.detectors) == "table" then
			detectors:configure(frame.detectors)
		end
	end
	host.onDetach = function()
		Modules.remove()
		if detectors then
			detectors:stop()
			detectors = nil
		end
	end
	table.insert(host.tickers, function(dt)
		if detectors then
			detectors:tick(dt)
		end
	end)
	return {
		stop = function()
			host:stop()
		end,
	}
end

return Server

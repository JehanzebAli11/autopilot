--!strict
-- The editor's link to the brain (hello host "editor"): the plugin in Studio's edit DataModel holds the one WebSocket
-- to the agent service, as Godot's editor does, because a play session's client and server are other DataModels that
-- come and go with each Play:
--  - `session` start / stop / restart play the place (StudioTestService:ExecutePlayModeAsync, as Studio's Play button
--    does: a server and one player's client) and end it (the server's StudioTestService:EndTest);
--  - `levels`, `codex_manifest` and `codex_read` are answered here, from the place open in Studio (Codex.luau);
--  - every other request goes to a side of the play session over the pipe (Host.luau): `rc` to the server unless its
--    path is the client's (the player's PlayerGui, PlayerScripts, camera; Route below), the player's ops (view, key,
--    move, ui...) to the client; their answers and events come back the same way and go on to the brain;
--  - with no play session, `context` and `ping` are answered here (session_running false), the rest get 409;
--  - `record` and `capture` get 409: Studio gives a plugin no picture of the game.
-- The dock (Dock.luau) drives runs through it (start, stop, steer, clear_memory, the account) and shows what comes.
local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

local Codex = require(script.Parent.Codex)
local Json = require(script.Parent.Json)
local Link = require(script.Parent.Link)
local Paths = require(script.Parent.Paths)
local Settings = require(script.Parent.Settings)

local Editor = {}
Editor.__index = Editor

Editor.VERSION = "1.0.0"
local SESSION_TIMEOUT = 60
local PLAY_SIDES = { "client", "server" }

-- Which side of the play session an rc request goes to: "server", "client", or "server" with "client" if the server
-- has no such instance (fallback). A path's "server:" / "client:" says so itself.
function Editor.route(path: string): (string, boolean)
	local side, p = Paths.side(path)
	if side then
		return side, false
	end
	local head = string.match(p, "^/?([^/%.]+)") or ""
	if head == "LocalPlayer" or head == "Camera" or head == "Character" or head == "Humanoid" then
		if head == "Camera" then
			return "client", false
		end
	end
	if head == "ServerScriptService" or head == "ServerStorage" then
		return "server", false
	end
	if string.find(p, "/PlayerGui", 1, true) or string.find(p, "/PlayerScripts", 1, true)
		or string.find(p, "%.PlayerGui") or string.find(p, "^/?Workspace/Camera")
		or string.find(p, "^/?LocalPlayer/PlayerGui") then
		return "client", false
	end
	return "server", true
end

local function now(): number
	return os.clock()
end

function Editor.new(plugin: Plugin)
	local self = setmetatable({}, Editor) :: any
	self.plugin = plugin
	self.link = Link.new(Settings.get(plugin, "url"), Settings.get(plugin, "token"))
	self.session = nil -- the brain's session for this connection: the pipe's key
	self.runActive = false
	self.brainSteers = false
	self.brainAccount = false
	self.brainSetup = false
	self.memory = { known = false, runs = 0, notes = false, lib = false }
	self.account = {}
	self.sides = {} -- side -> {ready = bool, seen = os.clock()}
	self.playing = false -- a play session runs (its client is attached)
	self.starting = false -- we asked Studio to play and it hasn't ended
	self.forwarded = {} -- brain request id -> when it went to the play session
	self.detectorConfig = {}
	self.listeners = {} -- event name -> {fn}
	self.alive = true
	self.connection = 0
	self.heartbeatAt = 0
	self.link.onOpen = function()
		self:_hello()
	end
	self.link.onFrame = function(frame)
		self:_onBrainFrame(frame)
	end
	self.link.onClose = function(was)
		self:_onClosed(was)
	end
	self.heartbeat = RunService.Heartbeat:Connect(function()
		self:_tick()
	end)
	return self
end

-- --- events for the dock -------------------------------------------------------------------------------------------

function Editor:on(name: string, fn: (...any) -> ())
	self.listeners[name] = self.listeners[name] or {}
	table.insert(self.listeners[name], fn)
end

function Editor:_fire(name: string, ...: any)
	for _, fn in ipairs(self.listeners[name] or {}) do
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[Autopilot] " .. name .. " listener failed: " .. tostring(err))
		end
	end
end

function Editor:status(text: string)
	self:_fire("status", text)
end

-- --- the connection ------------------------------------------------------------------------------------------------

function Editor:connected(): boolean
	return self.link.connected and self.link.role ~= ""
end

function Editor:connect()
	self.link:reconnect(Settings.get(self.plugin, "url"), Settings.get(self.plugin, "token"))
	self:status("Connecting to " .. self.link.url .. "…")
end

function Editor:disconnect()
	self.link:close()
	self.link.problem = ""
	self.runActive = false
	self:_endPipe()
	self:status("Disconnected")
	self:_fire("connection", false)
	self:_fire("run", false)
end

function Editor:projectId(): string?
	if game.GameId ~= 0 then
		return "roblox-universe-" .. tostring(game.GameId)
	end
	return nil
end

function Editor:projectName(): string
	local name = game.Name
	name = string.gsub(name, "%.rbxlx?$", "")
	return name
end

function Editor:_hello()
	local h: any = { type = "hello", protocol = Link.PROTOCOL, plugin_version = Editor.VERSION, engine = "roblox",
		engine_version = version(), project = self:projectName(), host = "editor", inspect = true,
		-- `levels` and `timed_hold`; no `media`: a plugin gets no picture of the game in Studio
		features = { "levels", "timed_hold" }, share = Settings.get(self.plugin, "share") ~= false,
		place_id = game.PlaceId, universe_id = game.GameId, transport = self.link.transport }
	local pid = self:projectId()
	if pid then
		h.project_id = pid
	end
	if self.activitySince then
		local since = self.activitySince()
		if since and since >= 0 then
			h.activity_since = since
		end
	end
	self.link:send(h)
end

function Editor:_send(frame: any)
	self.link:send(frame)
end

function Editor:_respond(id: any, result: any)
	self:_send({ type = "response", id = id, ok = true, result = if result == nil then Json.object() else result,
		t = Json.null })
end

function Editor:_respondError(id: any, err: string, status: number?)
	self:_send({ type = "response", id = id, ok = false, status = status or 400, error = err, t = Json.null })
end

function Editor:_onClosed(was: boolean)
	self.runActive = false
	self:_fire("run", false)
	self:_endPipe()
	self.memory.known = false
	self:_fire("memory")
	if was then
		self:_fire("connection", false)
	end
	self:status(self.link.problem)
end

-- --- runs (the dock's) ---------------------------------------------------------------------------------------------

function Editor:startRun(run: any): boolean
	if not self:connected() then
		self:status("Not connected: connect first")
		return false
	end
	self:_send({ type = "start", run = run })
	self.runActive = true
	self:_fire("run", true)
	self:status("Run started")
	return true
end

function Editor:stopRun()
	self:_send({ type = "stop" })
	self:status("Stopping…")
end

function Editor:canSteer(): boolean
	return self:connected() and self.runActive and self.brainSteers
end

function Editor:steer(text: string)
	local said = string.gsub(text, "^%s+", "")
	said = string.gsub(said, "%s+$", "")
	if self:canSteer() and said ~= "" then
		self:_send({ type = "steer", text = said })
	end
end

function Editor:clearMemory()
	if not self:connected() then
		self:status("Not connected: connect first")
		return
	end
	if self.runActive then
		self:status("A run is going: reset the memory once it is done")
		return
	end
	self:_send({ type = "clear_memory" })
	self:status("Resetting memory…")
end

function Editor:feedback(signature: string, verdict: string)
	self:_send({ type = "feedback", signature = signature, verdict = verdict })
end

function Editor:askAccount()
	if self:connected() and self.brainAccount then
		self:_send({ type = "account" })
	end
end

function Editor:signIn(): boolean
	if not (self:connected() and self.brainAccount) then
		return false
	end
	return self.link:send({ type = "aura_sign_in" })
end

function Editor:signInCancel()
	self:_send({ type = "aura_sign_in_cancel" })
end

function Editor:signOut()
	self:_send({ type = "aura_sign_out" })
end

-- The first-run setup's choices, for an agent service that saves them for the plugin (its welcome's "setup"):
-- {"access": "aura"|"own_keys", "share", "keys": {...}, "coding_agent", "llm_provider"}.
function Editor:saveSetup(setup: any): boolean
	if not (self:connected() and self.brainSetup) then
		return false
	end
	setup.type = "save_setup"
	return self.link:send(setup)
end

-- --- frames from the brain -----------------------------------------------------------------------------------------

function Editor:_onBrainFrame(frame: any)
	local kind = tostring(frame.type or "")
	if kind == "request" then
		self:_onRequest(frame)
	elseif kind == "welcome" then
		self.link.role = tostring(frame.role or "")
		self.connection += 1
		self.brainSteers, self.brainAccount, self.brainSetup = false, false, false
		for _, f in ipairs(frame.features or {}) do
			if f == "steer" then
				self.brainSteers = true
			elseif f == "account" then
				self.brainAccount = true
			elseif f == "setup" then
				self.brainSetup = true
			end
		end
		if self.link.role == "cli" then
			self.runActive = true
			self:_fire("run", true)
		end
		self:_startPipe(tostring(frame.session or ""))
		self:status("Connected to the agent service")
		self:_fire("connection", true)
		self:askAccount()
	elseif kind == "pipe" then
		self:_onPipeFrame(frame.frame)
	elseif kind == "run_started" then
		if not self.runActive and type(frame.run) == "table" then
			self.runActive = true
			self:_fire("run_started", frame.run)
			self:_fire("run", true)
		end
	elseif kind == "run_kind" then
		self:_fire("run_kind", tostring(frame.kind or ""), frame.tested == true)
	elseif kind == "status" then
		self:_fire("server_status", tostring(frame.text or ""))
		self:status(tostring(frame.text or ""))
	elseif kind == "activity" then
		self:_fire("activity", frame)
	elseif kind == "jev" then
		self:_fire("policy", frame)
	elseif kind == "finding" then
		if type(frame.finding) == "table" then
			self:_fire("finding", frame.finding)
			self:status("Finding: " .. tostring(frame.finding.summary or ""))
		end
	elseif kind == "result" then
		self.runActive = false
		local result = if type(frame.result) == "table" then frame.result else {}
		for _, k in ipairs({ "memory", "recording", "no_recording" }) do
			if frame[k] ~= nil and result[k] == nil then
				result[k] = frame[k]
			end
		end
		self:_fire("run", false)
		self:_fire("result", result, frame.files)
		self:status("Run finished")
	elseif kind == "memory_state" then
		self.memory = { known = true, runs = tonumber(frame.runs) or 0, notes = frame.notes == true, lib = frame.lib == true }
		self:_fire("memory")
	elseif kind == "memory_cleared" then
		if frame.ok == true then
			self.memory = { known = true, runs = 0, notes = false, lib = false }
			self:status("Memory reset successful")
			self:_fire("memory")
		else
			self:status("Memory not reset: " .. tostring(frame.message or ""))
		end
		self:_fire("memory_cleared", frame.ok == true, tostring(frame.message or ""))
	elseif kind == "usage" then
		self:_fire("usage", frame.models or {}, frame.final == true)
	elseif kind == "bill" then
		self:_fire("bill", frame)
	elseif kind == "account" then
		self.account = frame
		self:_fire("account", frame)
	elseif kind == "aura_sign_in" then
		self.signInFrame = frame -- (the latest: what the dock shows, and what is asked again)
		self:_fire("sign_in", frame)
	elseif kind == "setup_saved" then
		self:_fire("setup_saved", frame)
	elseif kind == "error" then
		self.link.problem = tostring(frame.message or "")
		self.link.refused = true
		self:status(self.link.problem)
		self:_fire("connection", false)
	end
end

-- --- requests ------------------------------------------------------------------------------------------------------

function Editor:_editorContext(): any
	return { world = "", scene = game.Name, character = "", controller = "", input_subsystem = "", camera_manager = "",
		camera = "", game_name = game.Name, host = "editor", engine = "roblox", session_running = false, paused = false,
		game_time = 0, project_dir = "", controls = {}, place_id = game.PlaceId, universe_id = game.GameId }
end

function Editor:_levels(): any
	local name = game.Name
	return { levels = { name }, open = name, playing = if self.playing then name else "" }
end

-- Send a brain request to a side of the play session (the answer comes back on the pipe: _onPipeFrame).
-- Send a brain request to a side of the play session: the side answers the brain itself. fallback: the server passes
-- an rc request for an instance it hasn't on to the client.
function Editor:_forward(frame: any, side: string, fallback: boolean)
	self.forwarded[frame.id] = now()
	self:_pipeSend({ to = side, type = "request", id = frame.id, op = frame.op, args = frame.args or Json.object(),
		fallback = fallback or nil })
end

function Editor:_onRequest(frame: any)
	local id = frame.id
	local op = tostring(frame.op or "")
	local args = if type(frame.args) == "table" then frame.args else {}
	if op == "session" then
		task.spawn(function()
			self:_session(id, args)
		end)
		return
	elseif op == "levels" then
		self:_respond(id, self:_levels())
		return
	elseif op == "codex_manifest" or op == "codex_read" then
		task.spawn(function()
			local ok, result = pcall(function()
				return if op == "codex_manifest" then Codex.manifest(args) else Codex.read(args)
			end)
			if ok then
				self:_respond(id, result)
			else
				self:_respondError(id, tostring(result), 500)
			end
		end)
		return
	elseif op == "record" then
		if tostring(args.action or "") == "stop" then
			self:_respond(id, { recording = false, frames = 0 })
		else
			self:_respondError(id, "no picture: Roblox Studio gives a plugin no picture of the game", 409)
		end
		return
	elseif op == "capture" then
		self:_respondError(id, "no picture: Roblox Studio gives a plugin no picture of the game", 409)
		return
	elseif op == "detectors" then
		self.detectorConfig = args
		if self.playing then
			for _, side in ipairs(PLAY_SIDES) do
				self:_pipeSend({ to = side, type = "request", id = "detectors-" .. side, op = "detectors", args = args })
			end
		end
		self:_respond(id, Json.object())
		return
	end
	if not self.playing then
		if op == "context" then
			self:_respond(id, self:_editorContext())
		elseif op == "ping" then
			self:_respond(id, { game_time = Json.null, wall_time = DateTime.now().UnixTimestampMillis / 1000 })
		elseif op == "pause" then
			self:_respond(id, { paused = false })
		else
			self:_respondError(id, "No game is running (start one with session start)", 409)
		end
		return
	end
	if op == "rc" then
		local body = if type(args.body) == "table" then args.body else {}
		if tostring(args.verb or "") == "probe" then
			self:_respond(id, Json.object())
			return
		end
		local side, fallback = Editor.route(tostring(body.objectPath or ""))
		self:_forward(frame, side, fallback)
	elseif op == "pause" then
		-- (each side runs its own simulation: the server's pause leaves the player's character moving)
		self:_pipeSend({ to = "server", type = "request", id = "pause-server", op = "pause", args = args })
		self:_forward(frame, "client", false)
	else
		self:_forward(frame, "client", false)
	end
end

-- --- the play session ----------------------------------------------------------------------------------------------

function Editor:_waitFor(cond: () -> boolean, seconds: number): boolean
	local t0 = now()
	while not cond() do
		if now() - t0 > seconds then
			return false
		end
		task.wait(0.1)
	end
	return true
end

-- Play the place, as Studio's Play button does; returns once the client is attached (or why not).
function Editor:play(): (boolean, string?)
	if self.playing then
		return true, nil
	end
	self.playError = nil
	if not self.starting then
		self.starting = true
		task.spawn(function()
			local ok, err = pcall(function()
				return StudioTestService:ExecutePlayModeAsync({ autopilot = Settings.pipe(self.plugin) })
			end)
			self.starting = false
			if not ok then
				if string.find(tostring(err), "in progress", 1, true) then
					-- (a play session runs already, one the user started or from before this connection: its sides
					-- join this connection's pipe by themselves)
					self:_pipeSend({ to = "play", type = "who" })
					return
				end
				self.playError = tostring(err)
				warn("[Autopilot] couldn't play: " .. tostring(err))
			end
			self:_playEnded()
		end)
	end
	local ok = self:_waitFor(function()
		return self.playing or self.playError ~= nil
	end, SESSION_TIMEOUT)
	if self.playError then
		return false, self.playError
	end
	if not ok then
		return false, "Timed out waiting for the play session"
	end
	return true, nil
end

-- End the play session (its server ends the test); returns once it is gone.
function Editor:stopPlaying(): (boolean, string?)
	if not self.playing and not self.starting then
		return true, nil
	end
	self:_pipeSend({ to = "server", type = "request", id = "end_test", op = "end_test", args = Json.object() })
	local ok = self:_waitFor(function()
		return not self.playing and not self.starting
	end, 30)
	if not ok then
		return false, "Timed out waiting for the play session to stop (stop it with Studio's Stop button)"
	end
	return true, nil
end

function Editor:_session(id: any, args: any)
	local action = tostring(args.action or "status")
	local map = tostring(args.map or "")
	if map ~= "" and map ~= game.Name and map ~= self:projectName() then
		self:_respondError(id, "No level " .. map .. ": a Roblox place is one level (" .. game.Name .. ")")
		return
	end
	if action == "start" then
		local ok, err = self:play()
		if ok then
			self:_respond(id, { running = true, scene = game.Name })
		else
			self:_respondError(id, err or "couldn't play", 500)
		end
	elseif action == "stop" then
		local ok, err = self:stopPlaying()
		if ok then
			self:_respond(id, { running = false })
		else
			self:_respondError(id, err or "couldn't stop", 500)
		end
	elseif action == "restart" then
		-- As Studio's Stop then Play: a fresh server and client (the game's scripts start over)
		local ok, err = self:stopPlaying()
		if ok then
			ok, err = self:play()
		end
		if ok then
			self:_respond(id, { running = true, scene = game.Name })
		else
			self:_respondError(id, err or "couldn't restart", 500)
		end
	else
		self:_respond(id, { running = self.playing })
	end
end

function Editor:_playEnded()
	if not self.playing and not self.sides.client then
		return
	end
	self.playing = false
	self.sides = {}
	-- (the requests sent on lately that may not be answered: the brain takes an error only for one still waiting)
	local t = now()
	for rid, at in pairs(self.forwarded) do
		if t - at < 120 then
			self:_respondError(rid, "the game stopped", 500)
		end
	end
	table.clear(self.forwarded)
	if self:connected() then
		self:_send({ type = "events", events = { { kind = "session", t = Json.null, running = false } }, t = Json.null })
	end
	self:_fire("playing", false)
end

-- --- the pipe to the play session ----------------------------------------------------------------------------------

-- The play session's sides join the brain's pipe for this connection (its session's key, left in the plugin's
-- settings); the editor reaches them through its own connection ({"type": "pipe"} frames: autopilot/bridge.py), so it
-- holds one socket in all (Studio lets a DataModel have only a few, its other plugins' counted).
function Editor:_startPipe(session: string)
	self:_endPipe()
	self.session = session
	Settings.set(self.plugin, "pipe", { url = self.link.url, key = session })
	-- (sides already playing say so when asked)
	self:_pipeSend({ to = "play", type = "who" })
end

function Editor:_endPipe()
	if self.session then
		self:_pipeSend({ to = "play", type = "detach" })
		self.session = nil
	end
	if self.playing then
		self.playing = false
		self.sides = {}
		self:_fire("playing", false)
	end
end

function Editor:_pipeSend(frame: any)
	if self.link.connected then
		self.link:send({ type = "pipe", frame = frame })
	end
end

function Editor:_onPipeFrame(frame: any)
	if type(frame) ~= "table" or frame.to ~= "edit" then
		return
	end
	local side = tostring(frame.from or "")
	local kind = frame.type
	local s = self.sides[side]
	if s then
		s.seen = now()
	end
	if kind == "here" then
		-- A side of a play session joined: attach it (its detectors on, its events to the brain)
		self.sides[side] = { ready = false, seen = now() }
		self:_pipeSend({ to = side, type = "attach", detectors = self.detectorConfig })
	elseif kind == "ready" then
		self.sides[side] = { ready = true, seen = now() }
		if side == "client" and not self.playing then
			self.playing = true
			if self:connected() then
				self:_send({ type = "events", events = { { kind = "session", t = frame.t or 0, running = true } },
					t = frame.t or 0 })
			end
			self:_fire("playing", true)
		end
	elseif kind == "alive" then
		if s == nil then
			-- (attached before this editor's state was lost, a plugin reload: attach it again)
			self.sides[side] = { ready = false, seen = now() }
			self:_pipeSend({ to = side, type = "attach", detectors = self.detectorConfig })
		end
	elseif kind == "bye" then
		self.sides[side] = nil
		if side == "client" then
			self:_playEnded()
		end
	elseif kind == "findings" then
		for _, f in ipairs(frame.findings or {}) do
			if type(f) == "table" then
				self:_fire("finding", f)
			end
		end
	end
end

-- Once a frame: a heartbeat to the brain while no game plays (the client's own heartbeats go on during play), and a
-- play session whose client went quiet is ended.
function Editor:_tick()
	local t = now()
	if self:connected() and not self.playing and t - self.heartbeatAt >= 1 then
		self.heartbeatAt = t
		self:_send({ type = "events", events = { { kind = "heartbeat", t = Json.null, fps = 60, paused = false } },
			t = Json.null })
	end
	if self.playing then
		if t - (self.whoAt or 0) >= 2 then
			self.whoAt = t
			self:_pipeSend({ to = "play", type = "who" })
		end
		local c = self.sides.client
		if c and t - c.seen > 8 and not self.starting then
			self:_playEnded()
		end
	end
end

function Editor:stop()
	self.alive = false
	self.heartbeat:Disconnect()
	self:_endPipe()
	self.link:close()
end

return Editor

--!strict
-- A play session's side (its client or its server DataModel) joined to the editor's plugin. Studio runs the plugin in
-- every DataModel, and those can't reach each other, so they meet on a pipe through the brain (autopilot/bridge.py,
-- PIPE_PATH): the editor's part sends each request there addressed to a side ({"to": "client", "type": "request",
-- ...}), the side answers the brain itself ({"to": "brain", "type": "response", ...}, as the plugin's answer) and sends
-- its events once a frame the same way; what is for the editor ({"to": "edit"}: here, ready, findings) goes to it.
-- Where the pipe is (the brain's address and the key, the editor's session) the editor leaves in the plugin's settings,
-- which every DataModel of the session shares (Settings.luau).
--
--   local host = Host.new(plugin, "client", ops)    -- ops: {name -> function(args, id, host) -> (ok, result, status?)}
--   host:emit(event)
-- An op may yield (it runs in its own thread): a key's tap, a move, a watch answer when they are done.
local RunService = game:GetService("RunService")

local Json = require(script.Parent.Json)
local Link = require(script.Parent.Link)
local Settings = require(script.Parent.Settings)
local World = require(script.Parent.World)

local Host = {}
Host.__index = Host

export type Op = (any, any, any) -> (boolean, any, number?)

function Host.new(plugin: Plugin, side: string, ops: { [string]: Op })
	local self = setmetatable({}, Host) :: any
	self.plugin = plugin
	self.side = side
	self.ops = ops
	self.events = {}
	self.attached = false
	self.alive = true
	self.conns = {}
	self.tickers = {} -- functions(realDt) run every frame
	self.heartbeatAt = 0
	self.pipeKey = ""
	self.link = nil
	self:_join()
	;(_G :: any).AutopilotHost = self -- (a look inside, for the dev loader's eval)
	table.insert(self.conns, RunService.Heartbeat:Connect(function(dt)
		self:_frame(dt)
	end))
	return self
end

function Host:t(): number
	return math.round(World.gameTime() * 100) / 100
end

-- A frame to the brain (the default), the editor ("edit") or another side.
function Host:send(frame: any)
	if self.link then
		frame.to = frame.to or "brain"
		frame.from = self.side
		self.link:send(frame)
	end
end

function Host:emit(event: any)
	if self.attached then
		table.insert(self.events, event)
	end
end

function Host:flush()
	if #self.events > 0 and self.attached then
		local batch = self.events
		self.events = {}
		self:send({ type = "events", events = batch, t = self:t() })
		-- (the dock lists the run's engine findings)
		local findings = {}
		for _, e in ipairs(batch) do
			if e.kind == "finding" then
				table.insert(findings, e.finding)
			end
		end
		if #findings > 0 then
			self:send({ to = "edit", type = "findings", findings = findings })
		end
	end
end

function Host:respond(id: any, ok: boolean, result: any, status: number?)
	if ok then
		self:send({ type = "response", id = id, ok = true, result = if result == nil then Json.object() else result,
			t = self:t() })
	else
		self:send({ type = "response", id = id, ok = false, status = status or 400, error = tostring(result),
			t = self:t() })
	end
end

function Host:_handle(frame: any)
	local op = tostring(frame.op or "")
	local args = if type(frame.args) == "table" then frame.args else {}
	local fn = self.ops[op]
	if fn == nil then
		self:respond(frame.id, false, "unknown op " .. op)
		return
	end
	task.spawn(function()
		local ok, a, b, c = pcall(fn, args, frame.id, self)
		self:flush() -- (events first: a change the answer depends on is told before it)
		if ok and a == false and frame.fallback and string.find(tostring(b), "does not exist", 1, true) then
			-- (not on this side: an instance only the client has; the client answers)
			self:send({ to = "client", type = "request", id = frame.id, op = frame.op, args = frame.args })
			return
		end
		if not ok then
			self:respond(frame.id, false, a, 500)
		elseif a == nil then
			return -- (the op answers by itself)
		else
			self:respond(frame.id, a, b, c)
		end
	end)
end

-- The pipe's frames addressed to this side.
function Host:_onFrame(frame: any)
	if frame.to ~= self.side and frame.to ~= "play" then
		return
	end
	local kind = frame.type
	if kind == "request" then
		self:_handle(frame)
	elseif kind == "attach" then
		self.attached = true
		if self.onAttach then
			self.onAttach(frame)
		end
		self:send({ to = "edit", type = "ready", t = self:t(), place = game.Name })
	elseif kind == "detach" then
		self.attached = false
		self.events = {}
		if self.onDetach then
			self.onDetach()
		end
	elseif kind == "who" then
		-- (the editor asks who is there: a side it hasn't attached says so, an attached one that it is still there)
		self:send({ to = "edit", type = if self.attached then "alive" else "here", t = self:t(), place = game.Name })
	end
end

-- Join the editor's pipe once its settings say where (looked at every second until then, and again when they change:
-- the editor connected to another brain).
function Host:_join()
	task.spawn(function()
		while self.alive do
			local pipe = Settings.pipe(self.plugin)
			local key = if pipe then tostring(pipe.url) .. "#" .. tostring(pipe.key) else ""
			if pipe and key ~= self.pipeKey then
				self.pipeKey = key
				if self.link then
					self.link:close()
				end
				local url = string.gsub(tostring(pipe.url), "/v1/bridge.*$", "") .. "/v1/pipe/" .. tostring(pipe.key)
					.. "?dm=" .. self.side
				local link = Link.new(url, "")
				link.onOpen = function()
					-- (the editor attaches us when it is told we are here)
					link:send({ type = "here", to = "edit", from = self.side, t = self:t(), place = game.Name })
				end
				link.onFrame = function(frame)
					self:_onFrame(frame)
				end
				link.onClose = function()
					self.attached = false
				end
				self.link = link
				link:open()
			end
			task.wait(1)
		end
	end)
end

function Host:_frame(dt: number)
	if not self.attached then
		return
	end
	for _, fn in ipairs(self.tickers) do
		local ok, err = pcall(fn, dt)
		if not ok then
			warn("[Autopilot] " .. self.side .. " ticker failed: " .. tostring(err))
		end
	end
	local now = os.clock()
	if now - self.heartbeatAt >= 1 then
		self.heartbeatAt = now
		if self.side == "client" then
			self:emit({ kind = "heartbeat", t = self:t(), fps = math.round(1 / math.max(dt, 1e-3)), paused = false })
		end
	end
	self:flush()
end

function Host:stop()
	self.alive = false
	if self.attached then
		pcall(function()
			self:send({ to = "edit", type = "bye" })
		end)
	end
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	if self.onDetach then
		self.onDetach()
	end
	if self.link then
		self.link:close()
	end
end

return Host

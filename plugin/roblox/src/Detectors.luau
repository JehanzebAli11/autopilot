--!strict
-- In-game detectors (docs/protocol.md "Findings"), run on both sides of a play session (each sees its own log and its
-- own physics): log_error (errors the game's scripts and the engine print: LogService), nan (a part's position not a
-- number), out_of_world (an unanchored part falling past the lowest drawn point of the level at its start, or past the
-- Workspace's FallenPartsDestroyHeight), long_fall (the player falling for 8 s), hitch (a frame over 0.75 s, not in the
-- session's first 3 s) and, on the client, hud_fraction (a "n / m" on screen with n over m). Warnings the game prints
-- go to the brain as `log` events too.
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")

local Frame = require(script.Parent.Frame)
local World = require(script.Parent.World)

local Detectors = {}
Detectors.__index = Detectors

-- Lines that are Studio's or Autopilot's own, never the game's
local NOISE = { "Autopilot", "AutopilotDev", "Plugin_", "CorePackages", "CoreGui", "RobloxGui", "MCP-Freeway",
	"Freeway", "Studio", "ExperienceChat" }

function Detectors.new(emit: (any) -> (), now: () -> number, screen: (() -> { [string]: string })?)
	local self = setmetatable({}, Detectors) :: any
	self.emit = emit
	self.now = now -- the game time
	self.screen = screen
	self.enabled = true
	self.counts = {}
	self.config = { long_fall_seconds = 8.0, hitch_seconds = 0.75, hud_every = 0.25, scan_every = 0.5,
		out_of_world_margin = 50.0 }
	self.started = os.clock()
	self.falling = 0
	self.hudAt = 0
	self.scanAt = 0
	self.killY = nil
	self.flagged = setmetatable({}, { __mode = "k" })
	self.conns = {}
	table.insert(self.conns, LogService.MessageOut:Connect(function(message: string, kind: Enum.MessageType)
		self:_log(message, kind)
	end))
	return self
end

function Detectors:stop()
	for _, c in ipairs(self.conns) do
		c:Disconnect()
	end
	self.conns = {}
end

function Detectors:configure(args: any)
	if type(args) ~= "table" then
		return
	end
	if args.enabled ~= nil then
		self.enabled = args.enabled == true
	end
	for k in pairs(self.config) do
		if tonumber(args[k]) then
			self.config[k] = tonumber(args[k])
		end
	end
end

local function noise(message: string): boolean
	for _, n in ipairs(NOISE) do
		if string.find(message, n, 1, true) then
			return true
		end
	end
	return false
end

local function normalize(s: string): string
	return string.sub((string.gsub(s, "%d+", "#")), 1, 160)
end

function Detectors:_finding(f: any)
	local sig = f.signature
	local n = (self.counts[sig] or 0) + 1
	self.counts[sig] = n
	if not (n == 1 or n == 10 or n == 100 or n == 1000) then
		return
	end
	local t = Frame.r2(self.now())
	f.t = t
	f.count = n
	f.source = "engine"
	self.emit({ kind = "finding", t = t, finding = f })
end

function Detectors:_log(message: string, kind: Enum.MessageType)
	if kind ~= Enum.MessageType.MessageError and kind ~= Enum.MessageType.MessageWarning then
		return
	end
	if noise(message) then
		return
	end
	local side = if RunService:IsServer() then "Server" else "Client"
	local error = kind == Enum.MessageType.MessageError
	local t = Frame.r2(self.now())
	self.emit({ kind = "log", t = t, verbosity = if error then "Error" else "Warning", category = side,
		message = string.sub(message, 1, 2000) })
	if error and self.enabled then
		-- "Workspace.Door.Script:12: attempt to index nil with 'Open'": the place is the script and line in front
		local where = string.match(message, "^([%w_%.%s]+:%d+):") or ""
		self:_finding({ detector = "log_error", severity = "error",
			summary = side .. " script error: " .. string.sub(message, 1, 300),
			signature = "log_error:" .. normalize(message) .. "@" .. where,
			details = { message = message, where = where, side = string.lower(side) } })
	end
end

-- Once a frame: real_dt, the frame's wall time.
function Detectors:tick(realDt: number)
	if not self.enabled or self.paused then
		return
	end
	local loading = os.clock() - self.started < 3
	if not loading and realDt > self.config.hitch_seconds then
		self:_finding({ detector = "hitch", severity = "warning", summary = string.format("A frame took %.2f s", realDt),
			signature = "hitch", details = { seconds = Frame.r2(realDt) } })
	end
	local h = World.humanoid()
	if h and RunService:IsClient() then
		if h:GetState() == Enum.HumanoidStateType.Freefall then
			self.falling += realDt
		else
			self.falling = 0
		end
		if self.falling > self.config.long_fall_seconds then
			self.falling = -1e9 -- (once per fall)
			local char = World.character()
			local root = World.root()
			self:_finding({ detector = "long_fall", severity = "error",
				summary = string.format("%s kept falling for %d s", if char then char.Name else "The player",
					self.config.long_fall_seconds),
				signature = "long_fall:" .. (if char then char.Name else ""), actor = if char then char.Name else "",
				where = if root then Frame.kit(root.Position) else nil })
		end
	end
	local now = os.clock()
	if self.screen and now - self.hudAt >= self.config.hud_every then
		self.hudAt = now
		self:_hud()
	end
	if now - self.scanAt >= self.config.scan_every and not loading then
		self.scanAt = now
		self:_scan()
	end
end

function Detectors:_hud()
	local texts = (self.screen :: any)()
	for key, text in pairs(texts) do
		for a, b in string.gmatch(text, "(%d+)%s*/%s*(%d+)") do
			local x, y = tonumber(a) :: number, tonumber(b) :: number
			if y > 0 and x > y then
				self:_finding({ detector = "hud_fraction", severity = "error",
					summary = string.format("HUD text %s shows %d/%d: more than its stated maximum", key, x, y),
					signature = "hud_fraction:" .. key, details = { key = key, text = text, value = x, max = y } })
			end
		end
	end
end

-- NaN positions, and unanchored parts below the level (its lowest drawn point at the start, less a margin; or the
-- Workspace's FallenPartsDestroyHeight, where Roblox removes them).
function Detectors:_scan()
	local parts = {}
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") and not d:IsA("Terrain") then
			table.insert(parts, d)
			if #parts >= 20000 then
				break
			end
		end
	end
	if self.killY == nil then
		local low = math.huge
		for _, p in ipairs(parts) do
			if p.Anchored and p.Transparency < 1 then
				low = math.min(low, p.Position.Y - p.Size.Y / 2)
			end
		end
		local margin = self.config.out_of_world_margin * 100 / Frame.SCALE -- (metres, as the other engines take it)
		self.killY = math.max((if low ~= math.huge then low else 0) - margin, workspace.FallenPartsDestroyHeight + 5)
	end
	for _, p in ipairs(parts) do
		if self.flagged[p] then
			continue
		end
		local pos = p.Position
		if not Frame.finite(pos) then
			self.flagged[p] = true
			self:_finding({ detector = "nan", severity = "error", summary = p.Name .. " has a NaN or infinite position",
				signature = "nan:" .. p.Name, actor = p.Name })
		elseif not p.Anchored and pos.Y < self.killY then
			local thing = World.thingOf(p) or p
			if self.flagged[thing] then
				continue
			end
			self.flagged[p] = true
			self.flagged[thing] = true
			self:_finding({ detector = "out_of_world", severity = "error",
				summary = string.format("%s fell out of the world (below %.0f studs)", thing.Name, self.killY),
				signature = "out_of_world:" .. thing.Name, actor = thing.Name, where = Frame.kit(pos) })
		end
	end
end

return Detectors

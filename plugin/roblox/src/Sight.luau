--!strict
-- What the player sees and feels (`view`), and things watched over time (`watch`), in the kit frame.
--
-- view: the Workspace's things (World.things: models and parts, a character being one) with a drawn part inside the
-- camera's view that a line of sight from the camera reaches (the box's centre, top or nearest point), nearest
-- first; the player and the large floor it stands on left out. Plus the camera, the body (on_ground, falling,
-- standing_on, touching, floor slope, the Humanoid's state and health) and, with `sonar`, how far the body could walk
-- each way (sweeps of a box the body's size above its step height, rays down for drops). Not told (Unreal's richer
-- view): held, scene.sun, openings, ways_up, lane, slope ends, body.under/overhead, highlighted, limp.
local Players = game:GetService("Players")

local Frame = require(script.Parent.Frame)
local Json = require(script.Parent.Json)
local Paths = require(script.Parent.Paths)
local World = require(script.Parent.World)

local Sight = {}

local r2 = Frame.r2
local S = Frame.SCALE

Sight.OMITTED = { "held", "scene.sun", "openings", "ways_up", "lane", "top_slope_degrees", "low_end", "high_end",
	"uphill", "body.under", "body.overhead", "look.highlighted", "look.limp", "blocks_player" }

-- Raycast params that leave out the player's character (and Autopilot's own).
function Sight.params(respectCollide: boolean?): RaycastParams
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	local ignore = {}
	local char = World.character()
	if char then
		table.insert(ignore, char)
	end
	local cam = workspace.CurrentCamera
	if cam then
		table.insert(ignore, cam)
	end
	p.FilterDescendantsInstances = ignore
	p.RespectCanCollide = respectCollide == true
	p.IgnoreWater = true
	return p
end

-- Whether a thing has a part a player can see (not fully transparent), and its parts (at most `limit`).
local function drawnParts(thing: Instance, limit: number): { BasePart }
	local out = {}
	if thing:IsA("BasePart") then
		if thing.Transparency < 0.99 then
			table.insert(out, thing)
		end
		return out
	end
	for _, d in ipairs(thing:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 0.99 then
			table.insert(out, d)
			if #out >= limit then
				break
			end
		end
	end
	return out
end

local function humanoidOf(thing: Instance): Humanoid?
	if thing:IsA("Model") then
		return thing:FindFirstChildOfClass("Humanoid")
	end
	return nil
end

-- How a thing is drawn: its visible parts' names (a mesh's by its MeshId), the lights on, the animations playing, its
-- texts (SurfaceGui, BillboardGui), sounds playing and effects emitting.
function Sight.lookOf(thing: Instance): any
	local parts, lights, brightest, anims, texts, sounds, effects = {}, 0, 0, {}, {}, {}, {}
	local list = if thing:IsA("BasePart") then { thing } else thing:GetDescendants()
	if thing:IsA("BasePart") then
		for _, d in ipairs(thing:GetDescendants()) do
			table.insert(list, d)
		end
	end
	for _, d in ipairs(list) do
		if d:IsA("BasePart") then
			if d.Transparency < 0.99 then
				parts[d.Name] = true
			end
		elseif d:IsA("Light") then
			if d.Enabled and d.Brightness > 0 then
				lights += 1
				brightest = math.max(brightest, d.Brightness)
			end
		elseif d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			local gui = d:FindFirstAncestorWhichIsA("LayerCollector")
			if d.Visible and d.Text ~= "" and gui and gui.Enabled and #texts < 4 then
				table.insert(texts, string.sub(d.Text, 1, 40))
			end
		elseif d:IsA("Sound") then
			if d.IsPlaying and #sounds < 4 then
				table.insert(sounds, d.Name)
			end
		elseif d:IsA("ParticleEmitter") or d:IsA("Fire") or d:IsA("Smoke") or d:IsA("Sparkles") or d:IsA("Beam")
			or d:IsA("Trail") then
			if (d :: any).Enabled and #effects < 4 then
				table.insert(effects, d.Name)
			end
		elseif d:IsA("Animator") then
			local ok, tracks = pcall(function()
				return (d :: Animator):GetPlayingAnimationTracks()
			end)
			if ok then
				for _, t in ipairs(tracks) do
					local a = t.Animation
					table.insert(anims, if a then a.Name else t.Name)
				end
			end
		end
	end
	local look: any = {}
	local names = {}
	for n in pairs(parts) do
		table.insert(names, n)
	end
	table.sort(names)
	if #names > 0 then
		look.parts = { table.unpack(names, 1, math.min(8, #names)) }
	end
	if lights > 0 then
		look.lights = { on = lights, brightness = r2(brightest) }
	end
	if #anims > 0 then
		look.animation = anims[1]
		if #anims > 1 then
			look.animations = anims
		end
	end
	if #texts > 0 then
		look.texts = texts
	end
	if #sounds > 0 then
		look.sounds = sounds
	end
	if #effects > 0 then
		look.effects = effects
	end
	return look
end

local function classOf(thing: Instance): string
	return thing.ClassName
end

-- The floor under the player: (thing, normal, distance below the feet) or nil.
local function floorUnder(center: Vector3, half: number, params: RaycastParams): (Instance?, Vector3?, number?)
	local hit = workspace:Raycast(center, Vector3.new(0, -(half + 6), 0), params)
	if hit then
		return World.thingOf(hit.Instance) or hit.Instance, hit.Normal, (center.Y - half) - hit.Position.Y
	end
	return nil, nil, nil
end

function Sight.body(center: Vector3, half: number, viewYaw: number): any
	local root = World.root()
	local h = World.humanoid()
	local params = Sight.params(true)
	local vel = if root then root.AssemblyLinearVelocity else Vector3.zero
	local body: any = { velocity = Frame.kit(vel), feet_z = r2((center.Y - half) * S), crouched = false }
	local floorThing, normal = floorUnder(center, half, params)
	if h then
		local state = h:GetState()
		body.state = state.Name
		body.on_ground = h.FloorMaterial ~= Enum.Material.Air
		body.falling = state == Enum.HumanoidStateType.Freefall
		body.health = r2(h.Health)
		body.max_health = r2(h.MaxHealth)
	end
	if floorThing and body.on_ground ~= false then
		body.standing_on = (floorThing :: Instance).Name
		if normal then
			body.floor_slope_degrees = r2(math.deg(math.acos(math.clamp(normal.Y, -1, 1))))
		end
	end
	-- Touching: what overlaps a box a little larger than the body, but the floor
	if root then
		local op = OverlapParams.new()
		op.FilterType = Enum.RaycastFilterType.Exclude
		op.FilterDescendantsInstances = params.FilterDescendantsInstances
		op.RespectCanCollide = true
		local size = Vector3.new(root.Size.X + 0.6, half * 2 - 0.4, root.Size.Z + 0.6)
		local box = CFrame.new(center + Vector3.new(0, 0.2, 0)) * root.CFrame.Rotation
		local ok, parts = pcall(function()
			return workspace:GetPartBoundsInBox(box, size, op)
		end)
		if ok then
			local seen, touching = {}, {}
			for _, p in ipairs(parts) do
				local t = World.thingOf(p) or p
				if t == floorThing or seen[t] then
					continue
				end
				seen[t] = true
				local away = (p.Position - center) * Vector3.new(1, 0, 1)
				local way = if away.Magnitude > 1e-3 then Frame.yawOfDir(away.Unit) else viewYaw
				table.insert(touching, { thing = t.Name, path = Paths.of(t), yaw = r2(way),
					turn = r2(Frame.wrap180(way - viewYaw)) })
				if #touching >= 8 then
					break
				end
			end
			if #touching > 0 then
				body.touching = touching
			end
		end
	end
	return body
end

local function onScreen(cam: Camera, p: Vector3): (boolean, Vector3)
	local sp, visible = cam:WorldToViewportPoint(p)
	return visible, sp
end

function Sight.view(args: any): (boolean, any)
	local cam = workspace.CurrentCamera
	if cam == nil then
		return false, "No camera"
	end
	local maxDist = (tonumber(args.max_distance) or 5000) / S
	local maxCount = tonumber(args.max_count) or 24
	local only = args.only
	local onlySet: { [string]: boolean }? = nil
	if type(only) == "table" then
		onlySet = {}
		for _, x in ipairs(only) do
			(onlySet :: any)[tostring(x)] = true
		end
	end
	local camCf = cam.CFrame
	local camPos = camCf.Position
	local viewYaw = Frame.yawOf(camCf)
	local vp = cam.ViewportSize
	local char = World.character()
	local center, half = World.body()
	local feetY = if center then center.Y - half else camPos.Y
	local body: any = Json.object()
	if center then
		body = Sight.body(center, half, viewYaw)
	end
	local params = Sight.params(false)
	local standing = body.standing_on
	-- What the crosshair (the view's middle) is on
	local crosshair: Instance? = nil
	local ray = cam:ViewportPointToRay(vp.X / 2, vp.Y / 2)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * maxDist, params)
	if hit then
		crosshair = World.thingOf(hit.Instance) or hit.Instance
	end
	local out = {}
	for _, thing in ipairs(World.things()) do
		if thing == char or (char and thing:IsDescendantOf(char)) then
			continue
		end
		local name = Paths.nameOf(thing)
		if onlySet and not (onlySet[name] or onlySet[thing.Name] or onlySet[Paths.of(thing)]) then
			continue
		end
		local bc, size = World.box(thing)
		if bc == nil or size == nil then
			continue
		end
		local boxCenter, boxSize = bc :: Vector3, size :: Vector3
		local lo, hiv = boxCenter - boxSize / 2, boxCenter + boxSize / 2
		local under = center ~= nil and center.X >= lo.X and center.X <= hiv.X and center.Z >= lo.Z and center.Z <= hiv.Z
		if boxSize.X > 30 and boxSize.Z > 30 and center and hiv.Y <= feetY + 0.5 and (thing.Name == standing or under) then
			continue -- (the ground the player is on, or the large floor under the spawn it stands on)
		end
		local nearest = Vector3.new(math.clamp(camPos.X, lo.X, hiv.X), math.clamp(camPos.Y, lo.Y, hiv.Y),
			math.clamp(camPos.Z, lo.Z, hiv.Z))
		local dist = (nearest - camPos).Magnitude
		if dist > maxDist then
			continue
		end
		local centerIn, sp = onScreen(cam, boxCenter)
		local anyIn = centerIn
		if not anyIn then
			for i = 0, 7 do
				local corner = Vector3.new(if i % 2 == 0 then lo.X else hiv.X, if (i // 2) % 2 == 0 then lo.Y else hiv.Y,
					if i // 4 == 0 then lo.Z else hiv.Z)
				if onScreen(cam, corner) then
					anyIn = true
					break
				end
			end
		end
		if not anyIn then
			continue
		end
		if #drawnParts(thing, 1) == 0 then
			continue
		end
		local seen = false
		for _, target in ipairs({ boxCenter, Vector3.new(boxCenter.X, hiv.Y - 0.05, boxCenter.Z), nearest }) do
			local d = target - camPos
			if d.Magnitude < 0.05 then
				seen = true
				break
			end
			local r = workspace:Raycast(camPos, d, params)
			if r == nil or r.Instance == thing or r.Instance:IsDescendantOf(thing) or (r.Position - target).Magnitude < 0.2 then
				seen = true
				break
			end
		end
		if not seen then
			continue
		end
		local pivot = World.pivot(thing)
		local item: any = { name = name, path = Paths.of(thing), class = classOf(thing), center = Frame.kit(boxCenter),
			size = Frame.kitSize(boxSize), yaw = if pivot then Frame.yawOf(pivot) else 0, distance = r2(dist * S),
			top_above_feet = r2((hiv.Y - feetY) * S), bottom_above_feet = r2((lo.Y - feetY) * S),
			crosshair_on = thing == crosshair }
		if sp.Z > 0 then
			item.screen_x = r2(sp.X / vp.X * 2 - 1)
			item.screen_y = r2(1 - sp.Y / vp.Y * 2)
		end
		if not centerIn then
			item.partly_in_view = true
		end
		local v = World.velocity(thing)
		if v.Magnitude > 0.05 then
			item.speed = r2(v.Magnitude * S)
		end
		local tags = thing:GetTags()
		if #tags > 0 then
			item.tags = tags
		end
		local hum = humanoidOf(thing)
		if hum then
			item.health = r2(hum.Health)
			item.max_health = r2(hum.MaxHealth)
			if Players:GetPlayerFromCharacter(thing :: Model) then
				item.player = true
			end
		end
		local look = Sight.lookOf(thing)
		if next(look) ~= nil then
			item.look = look
			if look.texts then
				item.label = look.texts[1]
			end
		end
		table.insert(out, item)
	end
	table.sort(out, function(a, b)
		return a.distance < b.distance
	end)
	while #out > maxCount do
		table.remove(out)
	end
	local vfov = cam.FieldOfView
	local hfov = math.deg(2 * math.atan(math.tan(math.rad(vfov) / 2) * vp.X / math.max(vp.Y, 1)))
	local result: any = { visible = out, camera = { location = Frame.kit(camPos), yaw = viewYaw,
		pitch = Frame.pitchOf(camCf), fov = r2(hfov), vfov = r2(vfov), type = cam.CameraType.Name },
		crosshair_tested = true, oriented = true, effects_play = true, body = body, omitted = Sight.OMITTED }
	if type(only) == "table" then
		result.only = only
	end
	if args.sonar and center then
		body.sonar = Sight.sonar(center :: Vector3, half, args, viewYaw)
	end
	return true, result
end

-- How far the body could walk each way: a box the body's width, from its step height to its head, swept forward a
-- stretch at a time (a walkable slope or a ledge lower than a step is gone up), and a ray down after each stretch for
-- a drop. Each way: {"turn", "clear", "by": "wall"|"drop"|"reach", "thing"?, "normal"?, "drop"?, "rise"?}.
function Sight.sonar(center: Vector3, half: number, args: any, viewYaw: number): any
	local reach = math.clamp(tonumber(args.sonar_reach) or 1500, 50, 5000) / S
	local turns = args.sonar_turns or { 0, -30, 30, -60, 60, -90, 90, -135, 135, 180 }
	local h = World.humanoid()
	local root = World.root()
	local step = if h then math.max(h.HipHeight, 0.5) * 0.9 else 1.0
	local maxSlope = math.rad(if h then h.MaxSlopeAngle else 89)
	local width = if root then math.max(root.Size.X, root.Size.Z) else 2
	local height = math.max(half * 2 - step, 1)
	local size = Vector3.new(width, height, width * 0.5)
	local params = Sight.params(true)
	local stretch = 1.5
	local dropAt = 2.0 -- studs below the feet that count as a drop
	local ways = {}
	for i, turn in ipairs(turns) do
		if i > 16 then
			break
		end
		local yaw = viewYaw + (tonumber(turn) or 0)
		local dir = Frame.dirOfYaw(yaw)
		local feet = center - Vector3.new(0, half, 0)
		local startY = feet.Y
		local travelled = 0
		local way: any = { turn = tonumber(turn) or 0, by = "reach" }
		local guard = 0
		while travelled < reach and guard < 80 do
			guard += 1
			local len = math.min(stretch, reach - travelled)
			local boxCenter = feet + Vector3.new(0, step + height / 2, 0)
			local cf = CFrame.lookAt(boxCenter, boxCenter + dir)
			local hit = workspace:Blockcast(cf, size, dir * len, params)
			if hit then
				local slope = math.acos(math.clamp(hit.Normal.Y, -1, 1))
				if slope <= maxSlope and guard < 79 then
					feet += Vector3.new(0, step * 0.5, 0) -- (a walkable rise: up it)
					continue
				end
				travelled += hit.Distance
				way.by = "wall"
				local t = World.thingOf(hit.Instance) or hit.Instance
				way.thing = t.Name
				way.normal = { X = r2(-hit.Normal.Z), Y = r2(hit.Normal.X) }
				break
			end
			local moved = feet + dir * len
			travelled += len
			local down = workspace:Raycast(moved + Vector3.new(0, step + 0.1, 0), Vector3.new(0, -(step + 40), 0), params)
			local below = if down then moved.Y - down.Position.Y else 41
			if below > dropAt then
				way.by = "drop"
				way.drop = if below <= 40 then r2(below * S) else Json.null
				-- the edge, to within a 32nd of the stretch: where the floor under the body's middle ends
				local lo, hi = 0, len
				for _ = 1, 5 do
					local mid = (lo + hi) / 2
					local at = feet + dir * mid + Vector3.new(0, step + 0.1, 0)
					if workspace:Raycast(at, Vector3.new(0, -(step + 0.1 + dropAt), 0), params) then
						lo = mid
					else
						hi = mid
					end
				end
				travelled -= len - lo
				break
			end
			feet = Vector3.new(moved.X, if down then down.Position.Y else moved.Y, moved.Z)
		end
		way.clear = r2(math.max(travelled, 0) * S)
		local rise = feet.Y - startY
		if math.abs(rise) > 0.2 then
			way.rise = r2(rise * S)
		end
		table.insert(ways, way)
	end
	return { ways = ways, reach = r2(reach * S) }
end

-- --- watch --------------------------------------------------------------------------------------------------------

-- The state a watch starts from: each object's pivot and size (and with `drawn`, its parts' places in its own frame
-- and how it is drawn).
function Sight.watchStart(args: any, resolve: (string) -> Instance?): any
	local drawn = args.drawn == true
	local partsCount = math.clamp(tonumber(args.parts) or 3, 0, 16)
	local entries, looks = {}, {}
	for _, x in ipairs(args.objects or {}) do
		local path = tostring(x)
		local inst = resolve(path)
		if inst == nil then
			continue
		end
		table.insert(entries, { inst = inst, thing = nil, path = path, found = {} })
		if drawn and (inst:IsA("Model") or inst:IsA("BasePart")) then
			local parts = {}
			for _, d in ipairs(inst:GetDescendants()) do
				if d:IsA("BasePart") then
					table.insert(parts, d)
				end
			end
			table.sort(parts, function(a, b)
				return a.Size.Magnitude > b.Size.Magnitude
			end)
			for i = 1, math.min(partsCount, #parts) do
				table.insert(entries, { inst = parts[i], thing = inst, path = path .. "/" .. parts[i].Name, found = {} })
			end
			table.insert(looks, { inst = inst, path = path, found = {} })
		end
	end
	return { entries = entries, looks = looks, drawn = drawn, turned = tonumber(args.turned) or 1,
		moved = tonumber(args.moved) or 2, resized = tonumber(args.resized) or 0.02 }
end

local function sample(e: any): (CFrame?, Vector3?)
	local inst = e.inst
	if inst.Parent == nil then
		return nil, nil
	end
	if inst:IsA("GuiObject") then
		local g = inst :: GuiObject
		local at = CFrame.new(g.AbsolutePosition.X / S, -g.AbsolutePosition.Y / S, 0)
		return at * CFrame.Angles(0, 0, math.rad(-g.Rotation)),
			Vector3.new(g.AbsoluteSize.X, g.AbsoluteSize.Y, 1)
	end
	local cf = World.pivot(inst)
	if cf == nil then
		return nil, nil
	end
	local size = if inst:IsA("BasePart") then inst.Size else (select(2, World.box(inst)) or Vector3.one)
	if e.thing then
		local tcf = World.pivot(e.thing)
		if tcf == nil then
			return nil, nil
		end
		cf = tcf:ToObjectSpace(cf :: CFrame)
	end
	return cf, size
end

local function lookState(inst: Instance): any
	local look = Sight.lookOf(inst)
	return { parts = look.parts or {}, lights = if look.lights then look.lights.on else 0, anims = look.animations
		or (if look.animation then { look.animation } else {}), sounds = look.sounds or {}, effects = look.effects or {} }
end

local function has(list: { any }, x: any): boolean
	return table.find(list, x) ~= nil
end

function Sight.watchTick(st: any, t: number)
	for _, e in ipairs(st.entries) do
		local cf, size = sample(e)
		if cf == nil then
			continue
		end
		if e.first == nil then
			e.first = { cf, size }
			continue
		end
		local f0, s0 = e.first[1], e.first[2]
		local rel = f0:ToObjectSpace(cf :: CFrame)
		local _, angle = rel:ToAxisAngle()
		if not e.found.turned and math.deg(math.abs(angle)) > st.turned then
			e.found.turned = t
		end
		if not e.found.moved and (cf.Position - f0.Position).Magnitude * S > st.moved then
			e.found.moved = t
		end
		if not e.found["changed size"] and s0 and size then
			local base = Vector3.new(math.max(math.abs(s0.X), 0.001), math.max(math.abs(s0.Y), 0.001),
				math.max(math.abs(s0.Z), 0.001))
			local d = (size - s0)
			if math.max(math.abs(d.X) / base.X, math.abs(d.Y) / base.Y, math.abs(d.Z) / base.Z) > st.resized then
				e.found["changed size"] = t
			end
		end
	end
	for _, l in ipairs(st.looks) do
		if l.inst.Parent == nil then
			continue
		end
		local now = lookState(l.inst)
		local last = l.last
		if last then
			for _, x in ipairs(now.parts) do
				if not has(last.parts, x) then
					table.insert(l.found, { t = t, what = "part shown", asset = x })
				end
			end
			for _, x in ipairs(last.parts) do
				if not has(now.parts, x) then
					table.insert(l.found, { t = t, what = "part hidden", asset = x })
				end
			end
			if now.lights ~= last.lights then
				table.insert(l.found, { t = t, what = if now.lights > last.lights then "light on" else "light off", asset = "" })
			end
			for _, pair in ipairs({ { "anims", "animation" }, { "sounds", "sound" }, { "effects", "effect" } }) do
				local key, word = pair[1], pair[2]
				for _, x in ipairs(now[key]) do
					if not has(last[key], x) then
						table.insert(l.found, { t = t, what = word .. " started", asset = x })
					end
				end
				for _, x in ipairs(last[key]) do
					if not has(now[key], x) then
						table.insert(l.found, { t = t, what = word .. " ended", asset = x })
					end
				end
			end
		end
		l.last = now
	end
end

function Sight.watchFinish(st: any): any
	local changes = {}
	local seen = {}
	for _, e in ipairs(st.entries) do
		for what, t in pairs(e.found) do
			local key = e.path .. "|" .. what
			if not seen[key] then
				seen[key] = true
				table.insert(changes, { t = r2(t), object = e.path, what = what })
			end
		end
	end
	for _, l in ipairs(st.looks) do
		for _, f in ipairs(l.found) do
			table.insert(changes, { t = r2(f.t), object = l.path, what = f.what, asset = f.asset })
		end
	end
	table.sort(changes, function(a, b)
		return a.t < b.t
	end)
	local out: any = { changes = changes }
	if st.drawn then
		out.drawn = true
	end
	return out
end

return Sight

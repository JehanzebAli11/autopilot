--!strict
-- How the course looks: the building blocks server/Course.luau puts the place together with. Floating rock islands with
-- neon rims, arches that name each stage, light beacons on the checkpoints, and a glowing grid far below the void.
-- Decoration never collides, is never touched and is never hit by a ray (CanCollide, CanTouch, CanQuery off), so it
-- can't get in a player's way or confuse what the agent sees.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))

local Look = Config.Look
local Style = {}

export type Props = { [string]: any }

-- A part with these properties (anchored, smooth), in `parent`
function Style.part(name: string, parent: Instance, props: Props): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in pairs(props) do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

-- A part that is only there to be seen
function Style.deco(name: string, parent: Instance, props: Props): Part
	local p = Style.part(name, parent, props)
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	return p
end

-- A glowing strip along each top edge of a block
function Style.rim(block: BasePart, color: Color3, thickness: number?)
	local t = thickness or 0.35
	local s = block.Size
	local top = block.CFrame * CFrame.new(0, s.Y / 2 + t / 2, 0)
	local edges = {
		{ CFrame.new(0, 0, -s.Z / 2 + t / 2), Vector3.new(s.X, t, t) },
		{ CFrame.new(0, 0, s.Z / 2 - t / 2), Vector3.new(s.X, t, t) },
		{ CFrame.new(-s.X / 2 + t / 2, 0, 0), Vector3.new(t, t, s.Z) },
		{ CFrame.new(s.X / 2 - t / 2, 0, 0), Vector3.new(t, t, s.Z) },
	}
	for i, e in ipairs(edges) do
		Style.deco("Rim" .. i, block, {
			CFrame = top * e[1],
			Size = e[2],
			Color = color,
			Material = Enum.Material.Neon,
		})
	end
end

-- A floating island whose walkable top is centered at `top` (a point on its upper surface): a slab of rock with a
-- neon rim and a tapering underside. Returns the slab (the part to stand on).
function Style.island(name: string, parent: Instance, top: Vector3, size: Vector3, color: Color3): Part
	local slab = Style.part(name, parent, {
		Size = size,
		Position = top - Vector3.new(0, size.Y / 2, 0),
		Color = Look.rock,
		Material = Enum.Material.Slate,
	})
	Style.rim(slab, color)
	-- the underside: three shrinking blocks of rock, a little turned, like the root of a floating island
	local below = top.Y - size.Y
	for i, scale in ipairs({ 0.78, 0.52, 0.26 }) do
		local h = 3 + i
		Style.deco("Root" .. i, slab, {
			Size = Vector3.new(size.X * scale, h, size.Z * scale),
			CFrame = CFrame.new(top.X, below - h / 2, top.Z) * CFrame.Angles(0, math.rad(i * 17), 0),
			Color = Look.rock:Lerp(Color3.new(), 0.25 * i),
			Material = Enum.Material.Basalt,
		})
		below -= h
	end
	-- a faint glow from the island's heart, on the stage's color
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 18
	light.Brightness = 1.2
	light.Parent = slab
	return slab
end

-- A glowing walkway (a bridge, a beam): a dark glass floor with neon rails along both sides
function Style.walkway(name: string, parent: Instance, cframe: CFrame, size: Vector3, color: Color3): Part
	local floor = Style.part(name, parent, {
		CFrame = cframe,
		Size = size,
		Color = Look.glass,
		Material = Enum.Material.Glass,
		Transparency = 0.15,
		Reflectance = 0.1,
	})
	for _, side in ipairs({ -1, 1 }) do
		Style.deco("Rail", floor, {
			CFrame = cframe * CFrame.new(side * (size.X / 2 - 0.15), size.Y / 2 + 0.15, 0),
			Size = Vector3.new(0.3, 0.3, size.Z),
			Color = color,
			Material = Enum.Material.Neon,
		})
	end
	return floor
end

-- A sign: text on a part's front face
function Style.sign(part: BasePart, text: string, color: Color3, face: Enum.NormalId?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Brightness = 2
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.12, 0)
	pad.PaddingBottom = UDim.new(0.12, 0)
	pad.Parent = label
	label.Parent = gui
	gui.Parent = part
end

-- An arch over the way in to a stage, centered on `base` (a point on the floor), facing back along +z (toward a
-- player who comes from the start), with the stage's number and name on its beam
function Style.arch(parent: Instance, base: Vector3, width: number, index: number, name: string, color: Color3)
	local folder = Instance.new("Folder")
	folder.Name = "Arch"
	folder.Parent = parent
	local h = 11
	for _, side in ipairs({ -1, 1 }) do
		local post = Style.deco("Post", folder, {
			Size = Vector3.new(1.2, h, 1.2),
			Position = base + Vector3.new(side * (width / 2 + 1), h / 2, 0),
			Color = Look.metal,
			Material = Enum.Material.Metal,
		})
		Style.deco("Glow", post, {
			Size = Vector3.new(0.4, h - 1, 0.4),
			Position = post.Position + Vector3.new(0, 0, 0.62),
			Color = color,
			Material = Enum.Material.Neon,
		})
	end
	local beam = Style.deco("Beam", folder, {
		Size = Vector3.new(width + 3.4, 2.2, 1.2),
		Position = base + Vector3.new(0, h + 1.1, 0),
		Color = Look.metal,
		Material = Enum.Material.Metal,
	})
	Style.sign(beam, string.format("%02d  %s", index, string.upper(name)), color, Enum.NormalId.Back)
end

-- A beacon: a column of light rising from a point, with drifting sparks
function Style.beacon(parent: Instance, base: Vector3, color: Color3, height: number?): Part
	local h = height or 34
	local column = Style.deco("Beacon", parent, {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(h, 1.4, 1.4),
		CFrame = CFrame.new(base + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color,
		Material = Enum.Material.Neon,
		Transparency = 0.55,
	})
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(color, Color3.new(1, 1, 1))
	sparks.LightEmission = 1
	sparks.Rate = 14
	sparks.Lifetime = NumberRange.new(2, 3.5)
	sparks.Speed = NumberRange.new(4, 9)
	sparks.SpreadAngle = Vector2.new(25, 25)
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	sparks.Transparency = NumberSequence.new(0.1, 1)
	sparks.EmissionDirection = Enum.NormalId.Right -- (the cylinder's axis is its x: up, here)
	sparks.Parent = column
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 24
	light.Brightness = 2
	light.Parent = column
	return column
end

-- The void: a glowing grid far below the course, so a fall has somewhere to look like it goes
function Style.grid(parent: Instance, center: Vector3, size: Vector2, step: number)
	local folder = Instance.new("Folder")
	folder.Name = "Grid"
	folder.Parent = parent
	for x = -size.X / 2, size.X / 2, step do
		Style.deco("Line", folder, {
			Size = Vector3.new(0.6, 0.6, size.Y),
			Position = center + Vector3.new(x, 0, 0),
			Color = Look.void,
			Material = Enum.Material.Neon,
			Transparency = 0.55,
		})
	end
	for z = -size.Y / 2, size.Y / 2, step do
		Style.deco("Line", folder, {
			Size = Vector3.new(size.X, 0.6, 0.6),
			Position = center + Vector3.new(0, 0, z),
			Color = Look.void,
			Material = Enum.Material.Neon,
			Transparency = 0.55,
		})
	end
end

return Style

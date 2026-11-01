--!strict
-- The screen's texts (`screen`), its interactive controls (`ui`, `ui_act`) and the mouse's spot (`pointer`).
--
-- Keys and ids are "<ScreenGui>.<Name>" (the ScreenGui the element is in, under the player's PlayerGui), repeated keys
-- getting "#2", "#3". An element counts when it and every GuiObject above it are Visible, its ScreenGui is Enabled, it
-- is on the screen and its text isn't fully transparent. ui_act acts as the player's mouse does: the mouse is moved to
-- the element's middle and pressed there (so whatever is on top gets the click, as for a player); the answer says
-- whether the button's Activated came ("fired").
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local Frame = require(script.Parent.Frame)
local Json = require(script.Parent.Json)
local Keys = require(script.Parent.Keys)
local Paths = require(script.Parent.Paths)

local Ui = {}

local last: { [string]: GuiObject } = {} -- id -> element, from the latest listing

local function playerGui(): PlayerGui?
	local lp = Players.LocalPlayer
	return lp and lp:FindFirstChildOfClass("PlayerGui")
end

local function screenGuiOf(g: Instance): LayerCollector?
	return g:FindFirstAncestorWhichIsA("LayerCollector")
end

-- Whether a ScreenGui is offset by the top bar's inset (its elements' AbsolutePosition then starts under it).
local function inset(gui: LayerCollector?): Vector2
	if gui and gui:IsA("ScreenGui") then
		local sg = gui :: ScreenGui
		local ignores = sg.IgnoreGuiInset
		local ok, insets = pcall(function()
			return (sg :: any).ScreenInsets
		end)
		if ok and insets == Enum.ScreenInsets.None then
			ignores = true
		end
		if not ignores then
			local ok2, v = pcall(function()
				return GuiService:GetGuiInset()
			end)
			return if ok2 then v else Vector2.zero
		end
	end
	return Vector2.zero
end

-- An element's middle in viewport pixels (where the mouse goes to click it).
function Ui.middle(g: GuiObject): Vector2
	return g.AbsolutePosition + g.AbsoluteSize / 2 + inset(screenGuiOf(g))
end

local function shown(g: GuiObject): boolean
	local gui = screenGuiOf(g)
	if gui == nil or not gui.Enabled then
		return false
	end
	local x: Instance? = g
	while x and x ~= gui do
		if x:IsA("GuiObject") and not (x :: GuiObject).Visible then
			return false
		end
		x = x.Parent
	end
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1e5, 1e5)
	local at, size = g.AbsolutePosition + inset(gui), g.AbsoluteSize
	if at.X > vp.X or at.Y > vp.Y or at.X + size.X < 0 or at.Y + size.Y < 0 then
		return false
	end
	return true
end

-- The elements on screen, in drawing order (the player's ScreenGuis, by DisplayOrder).
local function elements(): { GuiObject }
	local pg = playerGui()
	if pg == nil then
		return {}
	end
	local guis = {}
	for _, c in ipairs(pg:GetChildren()) do
		if c:IsA("ScreenGui") and c.Enabled then
			table.insert(guis, c)
		end
	end
	table.sort(guis, function(a, b)
		return a.DisplayOrder < b.DisplayOrder
	end)
	local out = {}
	for _, gui in ipairs(guis) do
		for _, d in ipairs(gui:GetDescendants()) do
			if d:IsA("GuiObject") and shown(d) then
				table.insert(out, d)
			end
		end
	end
	return out
end

function Ui.textOf(g: GuiObject): string
	if g:IsA("TextLabel") or g:IsA("TextButton") or g:IsA("TextBox") then
		local t = g :: any
		if t.TextTransparency >= 0.99 then
			return ""
		end
		local ok, content = pcall(function()
			return t.ContentText
		end)
		return if ok and type(content) == "string" then content else t.Text
	end
	return ""
end

local function keyed(list: { GuiObject }): { { any } }
	local counts = {}
	local out = {}
	for _, g in ipairs(list) do
		local gui = screenGuiOf(g)
		local base = (if gui then gui.Name else "Screen") .. "." .. g.Name
		counts[base] = (counts[base] or 0) + 1
		local key = if counts[base] == 1 then base else string.format("%s#%d", base, counts[base])
		table.insert(out, { key, g })
	end
	return out
end

function Ui.screen(args: any): any
	local texts = Json.object()
	local withText = {}
	for _, g in ipairs(elements()) do
		if string.match(Ui.textOf(g), "%S") then
			table.insert(withText, g)
		end
	end
	for _, kg in ipairs(keyed(withText)) do
		texts[kg[1]] = Ui.textOf(kg[2])
	end
	local out: any = { texts = texts }
	if args and args.ui then
		out.ui = Ui.list()
	end
	return out
end

local function kindOf(g: GuiObject): string
	if g:IsA("TextBox") then
		return "text_input"
	elseif g:IsA("GuiButton") then
		return "button"
	end
	return ""
end

function Ui.list(): { any }
	local interactive = {}
	for _, g in ipairs(elements()) do
		if kindOf(g) ~= "" then
			table.insert(interactive, g)
		end
	end
	table.clear(last)
	local out = {}
	for _, kg in ipairs(keyed(interactive)) do
		local id, g = kg[1], kg[2] :: GuiObject
		last[id] = g
		local label = Ui.textOf(g)
		if label == "" then
			for _, d in ipairs(g:GetDescendants()) do
				if d:IsA("TextLabel") and d.Visible and d.Text ~= "" then
					label = Ui.textOf(d)
					break
				end
			end
		end
		if label == "" and g:IsA("TextBox") then
			label = (g :: TextBox).PlaceholderText
		end
		local enabled = g.Active
		local ok, interactable = pcall(function()
			return (g :: any).Interactable
		end)
		if ok and interactable == false then
			enabled = false
		end
		if g:IsA("TextBox") and not (g :: TextBox).TextEditable then
			enabled = false
		end
		local m = Ui.middle(g)
		local gui = screenGuiOf(g)
		local item: any = { id = id, kind = kindOf(g), name = g.Name, owner = if gui then gui.Name else "Screen",
			label = label, enabled = enabled, path = Paths.of(g), class = g.ClassName,
			screen = { x = math.round(m.X), y = math.round(m.Y) } }
		if g:IsA("TextBox") then
			item.value = (g :: TextBox).Text
			if (g :: TextBox).PlaceholderText ~= "" then
				item.placeholder = (g :: TextBox).PlaceholderText
			end
		end
		table.insert(out, item)
	end
	return out
end

local function find(id: string): GuiObject?
	if string.sub(id, 1, 1) == "/" then
		local inst = Paths.resolve(id)
		return if inst and inst:IsA("GuiObject") then inst else nil
	end
	local g = last[id]
	if g == nil or g.Parent == nil then
		Ui.list()
		g = last[id]
	end
	return if g and g.Parent then g else nil
end

local function click(at: Vector2, button: Enum.UserInputType, count: number?)
	local vi = Keys.virtual()
	Keys.pointAt(at)
	task.wait() -- (the cursor there first, as a player's mouse arrives before it clicks)
	for i = 1, count or 1 do
		vi:SendMouseButton(at, button, true, i)
		vi:SendMouseButton(at, button, false, i)
	end
end

-- [ok, result or error]; a click's answer comes a few frames later (yields).
function Ui.act(args: any): (boolean, any)
	local id = tostring(args.id or "")
	local action = tostring(args.action or "click")
	local g = find(id)
	if g == nil then
		return false, "no element " .. id .. " on screen"
	end
	local el = g :: GuiObject
	if action == "click" or action == "right_click" or action == "double_click" then
		local fired = false
		local conns = {}
		if el:IsA("GuiButton") then
			local b = el :: GuiButton
			table.insert(conns, b.Activated:Connect(function()
				fired = true
			end))
			if action == "right_click" then
				table.insert(conns, b.MouseButton2Click:Connect(function()
					fired = true
				end))
			end
		elseif el:IsA("TextBox") then
			table.insert(conns, (el :: TextBox).Focused:Connect(function()
				fired = true
			end))
		end
		local button = if action == "right_click" then Enum.UserInputType.MouseButton2 else Enum.UserInputType.MouseButton1
		click(Ui.middle(el), button, if action == "double_click" then 2 else 1)
		for _ = 1, 6 do
			if fired then
				break
			end
			task.wait()
		end
		for _, c in ipairs(conns) do
			c:Disconnect()
		end
		local out: any = { via = "mouse", fired = fired }
		if not fired then
			out.note = "the element didn't take the click (something on top of it, or it isn't Active)"
		end
		return true, out
	elseif action == "set" then
		if el:IsA("TextBox") then
			local box = el :: TextBox
			local text = tostring(args.text or args.value or "")
			click(Ui.middle(box), Enum.UserInputType.MouseButton1)
			task.wait()
			pcall(function()
				box:CaptureFocus()
			end)
			box.Text = text
			task.wait()
			-- (submitted, as Enter would: FocusLost(enterPressed = true))
			pcall(function()
				box:ReleaseFocus(args.submit ~= false)
			end)
			return true, Json.object()
		end
		return false, id .. " takes no value"
	elseif action == "drag" then
		local to = find(tostring(args.to or ""))
		if to == nil then
			return false, "no element " .. tostring(args.to) .. " on screen to drop on"
		end
		local vi = Keys.virtual()
		local a, b = Ui.middle(el), Ui.middle(to :: GuiObject)
		Keys.pointAt(a)
		vi:SendMouseButton(a, Enum.UserInputType.MouseButton1, true, 1)
		for i = 1, 4 do
			task.wait()
			Keys.pointAt(a:Lerp(b, i / 4))
		end
		task.wait()
		vi:SendMouseButton(b, Enum.UserInputType.MouseButton1, false, 1)
		return true, Json.object()
	end
	return false, "unknown action " .. action
end

-- `pointer`: put the mouse at {"screen_x", "screen_y"} (-1..1 from the middle, y up), {"world": kit point} or
-- {"object": path} (where the camera shows it), without moving across. -> {"screen_x", "screen_y", "x", "y",
-- "on_screen"}
function Ui.pointer(args: any): (boolean, any)
	local cam = workspace.CurrentCamera
	if cam == nil then
		return false, "No camera"
	end
	local vp = cam.ViewportSize
	local at: Vector2
	local visible = true
	if args.screen_x ~= nil or args.screen_y ~= nil then
		local sx, sy = tonumber(args.screen_x) or 0, tonumber(args.screen_y) or 0
		at = Vector2.new((sx + 1) / 2 * vp.X, (1 - sy) / 2 * vp.Y)
	else
		local p: Vector3? = nil
		if args.world then
			p = Frame.fromKit(args.world)
		elseif args.object then
			local inst = Paths.resolve(tostring(args.object))
			if inst == nil then
				return false, "Object " .. tostring(args.object) .. " does not exist"
			end
			if inst:IsA("GuiObject") then
				local m = Ui.middle(inst :: GuiObject)
				p = nil
				at = m
			else
				local cf = if inst:IsA("BasePart") then (inst :: BasePart).CFrame
					elseif inst:IsA("PVInstance") then (inst :: PVInstance):GetPivot() else nil
				if cf == nil then
					return false, tostring(args.object) .. " has no place in the world"
				end
				p = cf.Position
			end
		else
			return false, "pointer wants screen_x/screen_y, world or object"
		end
		if p then
			local sp, on = cam:WorldToViewportPoint(p)
			visible = on
			at = Vector2.new(sp.X, sp.Y)
		end
	end
	at = Vector2.new(math.clamp(at.X, 0, vp.X - 1), math.clamp(at.Y, 0, vp.Y - 1))
	Keys.pointAt(at)
	return true, { x = math.round(at.X), y = math.round(at.Y), screen_x = Frame.r2(at.X / vp.X * 2 - 1),
		screen_y = Frame.r2(1 - at.Y / vp.Y * 2), on_screen = visible }
end

return Ui

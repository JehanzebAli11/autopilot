--!strict
-- The player's keyboard and mouse: Unreal key names (as every plugin takes them) as Roblox input, sent through Studio's
-- virtual input (UserInputService:CreateVirtualInput), so the game's UserInputService, ContextActionService and the
-- default PlayerModule (walking, jumping, the camera) all see it as a player's.
--
-- Key names: FKey names (W, SpaceBar, LeftShift, One, F5, Enter, LeftMouseButton, MouseX, MouseY, MouseScrollUp...),
-- or a Roblox KeyCode's name (E, Space, Return, KeypadOne...), or the name of an action the game bound with
-- ContextActionService (its first key is pressed). MouseX/MouseY move the mouse by that many pixels (MouseY positive
-- up, as Unreal's); with the mouse free (Roblox's default camera, not locked to the middle) the camera only turns
-- while the right button is held, so the plugin holds it for the move, as a player does.
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Keys = {}

local FKEYS: { [string]: string } = {
	SpaceBar = "Space", Enter = "Return", BackSpace = "Backspace", Tab = "Tab", Escape = "Escape",
	LeftShift = "LeftShift", RightShift = "RightShift", LeftControl = "LeftControl", RightControl = "RightControl",
	LeftAlt = "LeftAlt", RightAlt = "RightAlt", LeftCommand = "LeftMeta", RightCommand = "RightMeta",
	CapsLock = "CapsLock", Delete = "Delete", Insert = "Insert", Home = "Home", End = "End", PageUp = "PageUp",
	PageDown = "PageDown", Up = "Up", Down = "Down", Left = "Left", Right = "Right", Semicolon = "Semicolon",
	Equals = "Equals", Comma = "Comma", Hyphen = "Minus", Underscore = "Underscore", Period = "Period",
	Slash = "Slash", Tilde = "Backquote", LeftBracket = "LeftBracket", Backslash = "BackSlash",
	RightBracket = "RightBracket", Apostrophe = "Quote", Quote = "QuotedDouble", Add = "KeypadPlus",
	Subtract = "KeypadMinus", Multiply = "KeypadMultiply", Divide = "KeypadDivide", Decimal = "KeypadPeriod",
	Zero = "Zero", One = "One", Two = "Two", Three = "Three", Four = "Four", Five = "Five", Six = "Six",
	Seven = "Seven", Eight = "Eight", Nine = "Nine", NumPadZero = "KeypadZero", NumPadOne = "KeypadOne",
	NumPadTwo = "KeypadTwo", NumPadThree = "KeypadThree", NumPadFour = "KeypadFour", NumPadFive = "KeypadFive",
	NumPadSix = "KeypadSix", NumPadSeven = "KeypadSeven", NumPadEight = "KeypadEight", NumPadNine = "KeypadNine",
}

local MOUSE: { [string]: Enum.UserInputType } = {
	LeftMouseButton = Enum.UserInputType.MouseButton1,
	RightMouseButton = Enum.UserInputType.MouseButton2,
	MiddleMouseButton = Enum.UserInputType.MouseButton3,
}

-- Roblox KeyCodes as Unreal key names (for the controls listing): the inverse of FKEYS, letters and F keys as they are
local UNREAL: { [string]: string } = {}
for fkey, code in pairs(FKEYS) do
	UNREAL[code] = fkey
end

local keyCodes: { [string]: Enum.KeyCode } = {}
for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
	keyCodes[item.Name] = item
end

local virtual: any = nil
local function vi(): any
	if virtual == nil then
		virtual = UserInputService:CreateVirtualInput()
	end
	return virtual
end
Keys.virtual = vi

export type Spec = { kind: string, code: Enum.KeyCode?, input: Enum.UserInputType?, axis: string?, dir: number?,
	action: string?, name: string }

-- The Unreal name of a Roblox KeyCode or mouse input (W, SpaceBar, LeftMouseButton...).
function Keys.unrealName(input: any): string
	if typeof(input) == "EnumItem" then
		if input.EnumType == Enum.KeyCode then
			return UNREAL[input.Name] or input.Name
		end
		for name, t in pairs(MOUSE) do
			if t == input then
				return name
			end
		end
		return input.Name
	end
	return tostring(input)
end

-- Actions Roblox's own scripts bind (its emote menu, UI navigation), never the game's
local CORE_ACTIONS = { EmotesMenuToggleAction = true, ScrollSelectedElement = true, EnableKeyboardUINavigation = true }

-- The actions the game bound with ContextActionService: {name -> {KeyCode or UserInputType...}}.
function Keys.boundActions(): { [string]: { EnumItem } }
	local out = {}
	local ok, all = pcall(function()
		return ContextActionService:GetAllBoundActionInfo()
	end)
	if ok and type(all) == "table" then
		for name, info in pairs(all) do
			if CORE_ACTIONS[name] then
				continue
			end
			local inputs = {}
			for _, x in ipairs((info :: any).inputTypes or {}) do
				if typeof(x) == "EnumItem" then
					table.insert(inputs, x)
				end
			end
			out[name] = inputs
		end
	end
	return out
end

-- How a key name is sent ({kind = "key" | "mouse_button" | "mouse_axis" | "wheel" | "wheel_axis"}), or nil.
function Keys.spec(name: string): Spec?
	if name == "" then
		return nil
	end
	local code = FKEYS[name]
	if code then
		return { kind = "key", code = keyCodes[code], name = name }
	end
	if MOUSE[name] then
		return { kind = "mouse_button", input = MOUSE[name], name = name }
	end
	if name == "MouseX" or name == "MouseY" then
		return { kind = "mouse_axis", axis = name, name = name }
	end
	if name == "MouseScrollUp" or name == "MouseWheelUp" then
		return { kind = "wheel", dir = 1, name = name }
	end
	if name == "MouseScrollDown" or name == "MouseWheelDown" then
		return { kind = "wheel", dir = -1, name = name }
	end
	if name == "MouseWheelAxis" then
		return { kind = "wheel_axis", name = name }
	end
	if keyCodes[name] and name ~= "Unknown" then
		return { kind = "key", code = keyCodes[name], name = name }
	end
	-- An action the game bound (ContextActionService): its first key or mouse button
	local bound = Keys.boundActions()[name]
	if bound then
		for _, x in ipairs(bound) do
			if x.EnumType == Enum.KeyCode then
				return { kind = "key", code = x :: Enum.KeyCode, action = name, name = name }
			elseif x.EnumType == Enum.UserInputType and (x == Enum.UserInputType.MouseButton1
				or x == Enum.UserInputType.MouseButton2 or x == Enum.UserInputType.MouseButton3) then
				return { kind = "mouse_button", input = x :: Enum.UserInputType, action = name, name = name }
			end
		end
	end
	return nil
end

function Keys.isAxis(spec: Spec): boolean
	return spec.kind == "mouse_axis" or spec.kind == "wheel_axis"
end

-- Where the mouse is (viewport pixels, as virtual input takes them): the pointer op's spot, else the middle.
Keys.pointer = nil :: Vector2?

function Keys.middle(): Vector2
	local cam = workspace.CurrentCamera
	local size = if cam then cam.ViewportSize else Vector2.new(800, 600)
	return size / 2
end

function Keys.mouseAt(): Vector2
	return Keys.pointer or Keys.middle()
end

local rightHeld = false -- the right button is down (held by the game's player or for a turn)

-- Send one change of a key: pressed or let go; value for an axis (pixels of mouse movement, wheel notches).
function Keys.send(spec: Spec, pressed: boolean, value: number?)
	local v = vi()
	if spec.kind == "key" then
		v:SendKey(pressed, spec.code, false)
	elseif spec.kind == "mouse_button" then
		if spec.input == Enum.UserInputType.MouseButton2 then
			rightHeld = pressed
		end
		-- (the cursor over the game first: a press where the real mouse is, outside the game view, goes nowhere)
		local at = Keys.mouseAt()
		if pressed then
			v:SendMousePosition(at)
		end
		v:SendMouseButton(at, spec.input, pressed, 1)
	elseif spec.kind == "mouse_axis" and pressed then
		local amount = value or 0
		local delta = if spec.axis == "MouseX" then Vector2.new(amount, 0) else Vector2.new(0, -amount)
		Keys.moveMouse(delta)
	elseif (spec.kind == "wheel" or spec.kind == "wheel_axis") and pressed then
		local notches = if spec.kind == "wheel" then (spec.dir or 1) else (value or 0)
		v:SendPointerAction(Keys.mouseAt(), { Wheel = notches })
	end
end

-- Move the mouse by delta pixels. With the mouse locked (first person, shift lock, a game's own camera) it moves alone;
-- with it free (Roblox's default camera turns only while the right button is held, locking the mouse meanwhile) the
-- right button is held for the turn and let go a moment after the last one (Keys.tick), as a player drags. Yields a
-- frame or two when it presses the button. Returns whether the move went in.
local turning = { held = false, releaseAt = 0 }

function Keys.moveMouse(delta: Vector2): boolean
	local v = vi()
	turning.releaseAt = os.clock() + 0.3 -- (first: the button pressed below isn't let go while it locks the mouse)
	if UserInputService.MouseBehavior == Enum.MouseBehavior.Default and not rightHeld and not turning.held then
		local at = Keys.mouseAt()
		v:SendMousePosition(at) -- (the cursor over the game first, as in send)
		RunService.Heartbeat:Wait()
		v:SendMouseButton(at, Enum.UserInputType.MouseButton2, true, 1)
		turning.held = true
		for _ = 1, 6 do
			if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
				break
			end
			RunService.Heartbeat:Wait()
		end
	end
	turning.releaseAt = os.clock() + 0.3
	local ok = pcall(function()
		v:SendMouseDelta(delta)
	end)
	return ok
end

-- Also called on detach: ticking stops when the host disconnects.
function Keys.releaseTurn()
	if turning.held then
		turning.held = false
		if not rightHeld then
			pcall(function()
				vi():SendMouseButton(Keys.mouseAt(), Enum.UserInputType.MouseButton2, false, 1)
			end)
		end
	end
end

-- Once a frame: let go of the right button held for turning once the turns have stopped.
function Keys.tick()
	if os.clock() > turning.releaseAt then
		Keys.releaseTurn()
	end
end

-- Whether a key sent down reached the game (Roblox drops input while Studio's game view isn't the focused window).
function Keys.reached(spec: Spec): boolean?
	if spec.kind == "key" and spec.code then
		return UserInputService:IsKeyDown(spec.code)
	elseif spec.kind == "mouse_button" and spec.input then
		return UserInputService:IsMouseButtonPressed(spec.input)
	end
	return nil
end

-- Put the mouse at a viewport point without moving it across (no delta).
function Keys.pointAt(at: Vector2)
	Keys.pointer = at
	vi():SendMousePosition(at)
end

function Keys.typeText(text: string)
	vi():SendTextInput(text)
end

-- The GUI inset: a ScreenGui that doesn't ignore it starts this far below the viewport's top.
function Keys.guiInset(): Vector2
	local ok, inset = pcall(function()
		return GuiService:GetGuiInset()
	end)
	return if ok then inset else Vector2.zero
end

return Keys


## The engine: Roblox

- **A play session has two sides.** The game runs as a server (Scripts: the game's rules and its authoritative state)
  and the player's client (LocalScripts: input, camera, UI). Reads and writes (`game.get`, `game.set`, `game.call`,
  `game.props`, `game.describe`) go to the server, which is what the game's Scripts see; a path the server doesn't
  have (an instance only the client made) is read on the client. The player's own GUI, PlayerScripts and the camera
  are the client's. Put `client:` or `server:` in front of a path to choose: `game.get("client:/Workspace/Thing",
  "Transparency")`. Everything else the kit gives (`game.view`, `game.sees`, `game.screen`, `game.ui`, `game.pose`,
  `game.actors`, `game.loc`, `game.locs`, `game.bounds`, inputs) is the client's: what the player sees, a moment after
  the server changed it (replication).
- **Things are instances**, named by their paths from the DataModel: `/Workspace/Map/Door`, `/ReplicatedStorage/
  Modules/Config`, `/ServerScriptService/GameManager`, `/Players/<Name>/leaderstats/Coins`. Instances that share a name
  under one parent are numbered: the first is plain (`Coin`), the others `Coin@1`, `Coin@2`..., and each keeps its
  number while it lives (a collected coin's path is gone, never another coin's). `game.name_of(path)` is the last part.
  `LocalPlayer`, `Character`, `Humanoid` and `Camera` name the player's own.
- **Finding things**: `game.actors("Model")` / `game.actors("BasePart")` (a Roblox class, subclasses too),
  `game.actors("tag:Enemy")` (a CollectionService tag; a plain name that is a tag and no class works too), or the name
  of a script inside a model (`game.actors("DoorScript")`: the models holding a script of that name).
  `game.all_actors()`: the Workspace's things (its models and parts at the top or in folders, not the parts inside a
  model; a model of models, such as a level's "Map", is a folder). `game.named("coin")` searches those by name.
- **Reads and calls**: a property name is a property of the instance's class (`Transparency`, `CFrame`, `Health`), else
  one of its attributes (`GetAttribute`), else the Value of a child value object of that name (an IntValue `Coins`),
  else, on a player or its character, its leaderstats entry: `game.get(game.pawn, "Coins")`. Also `position` (a model's
  or part's pivot point; `game.set(path, "position", game.to_native(v), why=...)` moves it as `PivotTo` does),
  `attributes`, `tags`, `children`. A ModuleScript's path reads the table it returns (`game.get(module, "Score")`, as
  the server's scripts have it) and `game.call(module, "AddScore", args=[5])` calls its function (`self=True` for a
  method). An instance's methods take arguments by name (`game.call(humanoid, "TakeDamage", amount=10)`) or
  `args=[...]`. Calling a RemoteEvent's `FireServer` on a `client:` path sends what the game's client would send.
- **Values from `game.get` are Roblox's own**: studs, Roblox's axes (x right, y up, -z forward), Vector3 as
  `{"x","y","z"}`, a CFrame as `{"position", "look", "up", "euler"}`, Color3 as `{"r","g","b"}`, an Enum as its name, an
  instance as its path. `game.to_kit(value)` turns a position or velocity into the kit's frame (`kit = 28 * (-z, x, y)`:
  1 stud = 28 cm); `game.to_native(vec)` turns a kit point back. `game.loc`, `game.bounds`, `game.pose`, `game.view` and
  `movement(game)` are in the kit's frame already.
- **The player** is the local player's character (`game.pawn`, a Model); `game.controller` is the Player.
  `game.pose()["at"]` is its HumanoidRootPart's centre, the feet `half_height` below (the root part's half height plus
  the Humanoid's HipHeight). `movement(game)` reads the Humanoid: WalkSpeed, JumpPower (or JumpHeight), the Workspace's
  Gravity, MaxSlopeAngle; a Humanoid steps up ledges lower than about its hip height, steers fully in the air, and
  takes no fall damage unless the game deals it. When the character dies Roblox spawns a new one after RespawnTime:
  `game.pawn` changes; wait for it (`game.context(fresh=True)["character"]`).
- **Input**: keys are Unreal names as everywhere (W, SpaceBar, E, LeftShift, One, LeftMouseButton, MouseX, MouseY,
  MouseScrollUp...), or a Roblox KeyCode's name (`Return`, `KeypadOne`). They go in as a player's keyboard and mouse do
  (Studio's virtual input), so UserInputService, ContextActionService, ProximityPrompts and the default PlayerModule
  (W/A/S/D walking, SpaceBar jumping) all see them. An action the game bound with ContextActionService can be pressed by
  name (`game.press("Sprint")`: its first key); `game.context()["controls"]` lists them. There is no gamepad.
  A ProximityPrompt is triggered by its key (`E` by default) while the player is within its MaxActivationDistance and
  it is shown; one with a HoldDuration needs `hold_for(game, "E", hold + 0.2)`. A ClickDetector is clicked by pointing
  at the part (`game.request("pointer", {"object": path})`) and pressing LeftMouseButton.
- **Camera**: Roblox's default camera turns only while the right mouse button is held (a player drags); the plugin holds
  it for `game.turn` / `game.mouse` when the mouse is free, so `look_at` and `walk_to` work, and when the game locks the
  mouse (first person, shift lock, its own camera) it moves the mouse alone. `game.calibrate_look()` measures either.
  `game.context()["camera_type"]` and `["mouse_behavior"]` say which. A game with a Scriptable camera turns the view in
  its own code: read it.
- **Moving without the keys**: `game.request("move", {"direction": kit vector, "seconds": s})` walks the character
  that way as an analog stick would (the player's Move, after the PlayerModule's; `"via": "keys"` for W/A/S/D);
  answers `{"moved"}`.
- **UI**: `game.screen()` keys texts `<ScreenGui>.<Name>` (TextLabels, TextButtons, TextBoxes in the player's
  PlayerGui); `game.ui()` lists GuiButtons (`button`) and TextBoxes (`text_input`) on screen; `ui_act` clicks with the
  mouse at the element's middle (its answer's `fired` says whether the button took it); `action="set"` types into a
  TextBox and submits it. Texts in the world (SurfaceGui, BillboardGui) are in `view`'s `look.texts`.
- **Sessions**: a run plays the place in Studio as the Play button does (a server and one player). `game.restart()`
  stops the session and plays again: the server's and client's scripts start over, the place as it is saved in Studio
  (nothing a session changed stays). Game time (`game.t`) is the Workspace's DistributedGameTime, from 0 in each session.
- **What the plugin leaves out**: Studio gives a plugin no picture of the game, so there are no recordings or frames
  to describe (`describe_frames` has nothing): settle a request about how something looks by what `game.view` tells
  (parts shown, transparency, colours read with `game.get`, lights, animations, sounds, effects, texts) and say so.
  `game.view` tells visible things (name, path, class, tags, center, size, distance, screen position, crosshair_on,
  health of a Humanoid, look: parts, lights, animations, sounds, effects, texts) and the body (on_ground, falling,
  state, health, standing_on, touching, floor slope) and, with `sonar=True`, the sonar ways. It has no `held`,
  `openings`, `ways_up` or `lane` (listed in its `omitted`): `walk_to` finds no way up to a raised goal by itself, so walk
  it to a ramp's or stairs' foot and top first. Detectors: errors and warnings the game's scripts print (server and
  client), NaN positions, parts falling out of the world, long falls, hitches, on-screen counts above their maximum.

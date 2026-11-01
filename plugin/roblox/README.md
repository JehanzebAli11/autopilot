# Autopilot for Roblox Studio

Autopilot is the Roblox Studio plugin of Autopilot. It lets the Autopilot agent play your Roblox game. A prompt is one of
four types:

- **Exploration**, e.g. "Explore the obby's second stage.": it plays for a few minutes and reports what looks wrong;
- **Testing**, e.g. "Go through the place and tell me everything that looks wrong.": it plays as an exploration, and its
  report says GAME TESTED;
- **Verification**, e.g. "Verify that the door opens when you pull the lever.": CONFIRMED, DENIED or INCONCLUSIVE, with
  evidence;
- **Goal**, e.g. "Collect every coin without falling off.": achieved or not.

For every prompt, Autopilot plays the place for you (as Studio's Play button does: a server and one player), reads the
place's scripts, tries things in the game and plays according to your prompt. When it is done, the play session stops by
itself and the dock shows the report.

The plugin is the agent's eyes and hands inside the game: it answers questions about the game (what is on screen, where
things are, what the game's scripts hold), presses keys and clicks the UI the way a player would, and gives the agent
your place's scripts and instances to read. The agent itself runs on your computer as a separate Python program
(`autopilot serve`, see [Running from a clone](../../CONTRIBUTING.md#running-from-a-clone)); the plugin connects out to
it.

It needs a current Roblox Studio (it uses `UserInputService:CreateVirtualInput`, `HttpService:CreateWebStreamClient`
and `StudioTestService`; tested with Studio 0.745) on Windows or macOS.

## Install

1. Build the plugin (from a repository checkout): `python tools/build_roblox.py --install`. This writes
   `dist/roblox/Autopilot.rbxmx` and copies it into Studio's local plugins folder (`%LOCALAPPDATA%\Roblox\Plugins` on
   Windows, `~/Documents/Roblox/Plugins` on macOS). Or copy a downloaded `Autopilot.rbxmx` there yourself.
2. Open (or reopen) a place in Studio: Studio loads local plugins when a place opens. The **Autopilot** button appears
   in the Plugins tab, and the **Autopilot** dock on the right.
3. The first time a play session starts, Studio may ask whether the plugin may make HTTP requests or open a
   connection to `127.0.0.1`: allow it (it only ever talks to the agent service on your computer, or the address you
   give it).

Nothing is added to your place: the plugin keeps its settings and run history in Studio's own plugin settings (per user
and computer), never in the place file. While a run plays, it puts a small helper script into the running play session
(see [How Studio and the game work together](#how-studio-and-the-game-work-together)); that copy goes with the session
and is never saved.

## Use it from Studio

1. **Start the agent service** in a terminal: `autopilot serve` (installed), or `python -m autopilot serve` in the
   Autopilot repository. It listens on `ws://127.0.0.1:8765/v1/bridge` (and, for the plugin's HTTP fallback, on the next
   port, 8766). A Roblox plugin can't start programs or read files, so it can't start the agent service itself as the
   other engines' plugins do, nor find one that `autopilot serve --port 0` put elsewhere: when 8765 is taken, start it
   on another port (`autopilot serve --port 8770`) and set **Agent service URL** in the dock's Settings to match
   (`ws://127.0.0.1:8770/v1/bridge`).
2. **Connect**: the dock connects by itself when a place opens (retrying with a backoff of up to 15 s; **Connect** tries
   at once). The header shows `● CONNECTED`, and `▶ PLAYING` while a play session is attached.
3. **Account**: how runs go. **Sign in with Aura** asks the agent service to sign in to Aura in your browser (runs then
   go through your Aura plan); **Use my keys (BYOK)** takes a decision provider key (TypeSafe), the coding agent
   (OpenCode, Claude Code or Codex), the LLM provider and its key, and has the agent service save them in
   `Autopilot/autopilot.env` (the plugin itself can't write files: the agent service does it for it, the `save_setup`
   frame). Keys left empty keep the ones the agent service has.
4. **New run**: describe what to test in the prompt box and press **Run**. The words are sent as typed (a `start` frame
   with `{"kind": "auto", "prompt": ..., "time_limit_minutes": ...}`); the agent service reads which of the four types
   it is and the live page shows it (VERIFY, GOAL, EXPLORE, TEST). **Time limit** is the run's minutes in all (1-600,
   30 by default), kept for the next run.
5. **Follow the run**: the stages (Launch, Analyze, Probe, Build harness, Play, Results, Report), the agent service's
   status line, **Stop**, and **Steer** (a hint for the agent while the game plays, from the Play stage on). The
   **Feed** lists what the agent did and said, by stage; **+ the details** opens a line's code, output or text.
6. **Read the result**: the verdict (CONFIRMED, DENIED, INCONCLUSIVE; ACHIEVED, NOT ACHIEVED; EXPLORED, GAME TESTED),
   the reason, the evidence, alerts, the direct changes the run made to the game, and the engine's findings (script
   errors on the server and the client, parts fallen out of the world, long falls, hitches, HUD counts over their
   maximum) with **Not a bug** and **Show in level** (selects it in the Explorer). **Run again**, **Report (to copy)**
   (the report as text, selectable) and **Verify a fix** (fills the prompt box).

**Keep Studio's game view focused while a run plays.** Roblox takes no keyboard input while Studio isn't the
focused window (the mouse still goes in). The plugin notices (a key it sends doesn't reach the game), says so in
Studio's output and in the run's findings, and meanwhile puts the keys Roblox's own controls read in the way those
controls do: W/A/S/D and the arrows walk the character, SpaceBar jumps, and a ProximityPrompt's key triggers the
nearest prompt in reach. Any other key a game binds doesn't reach it until Studio is focused again.

The **History** lists the last 30 runs (kept in Studio's plugin settings); pick one to show its result and feed again.
The **Memory** line says how many runs the agent remembers of this game; **Reset memory…** asks in place, then has the
agent forget them.

### Settings

| Setting | What it does |
|---|---|
| **Agent service URL** | Where to connect. Empty means `ws://127.0.0.1:8765/v1/bridge`. A changed address is used at once. |
| **Access token** · optional | Sent as `Authorization: Bearer <token>`, for an agent service that asks for one. |
| **Data sharing** | Whether runs' data is shared to improve Autopilot (the hello's `share`; on by default). |

### Runs from your own Claude Code or Codex

Set up with `autopilot connect claude` or `autopilot connect codex`, your own coding agent can start a run on the place
open in Studio (`autopilot mcp`, on your Claude or ChatGPT plan): the dock shows it as one of its own, with **Stop**,
steering and the result.

## How Studio and the game work together

Studio runs a plugin in every DataModel it has: the place being edited (**edit**), and while a play session goes, the
session's **server** and its player's **client**. They can't reach each other inside Studio, so:

- the **edit** plugin holds the one connection to the agent service (its `hello` says `"engine": "roblox"`,
  `"host": "editor"`), shows the dock, plays and stops the place (`StudioTestService:ExecutePlayModeAsync`, as the Play
  button does; `EndTest` on the server to stop), answers `levels`, `codex_manifest` and `codex_read` from the place,
  and with no play session answers `context` and `ping` itself (`session_running: false`); everything else gets 409
  ("No game is running");
- the play session's **server** and **client** plugins join the agent service's **pipe** for that connection
  (`ws://<agent service>/v1/pipe/<session>`, autopilot/bridge.py: the address and key are left in the plugin's
  settings, which every DataModel shares). The edit plugin sends each request on to the side that answers it, through
  its own connection; the side answers the agent service directly. `rc` goes to the server (what the game's Scripts
  see and change) unless its path is the client's own (the player's PlayerGui and PlayerScripts, the camera) or it says
  `client:`; one the server has no instance for is passed on to the client. Every other request (view, screen, ui,
  ui_act, pointer, key, input, move, watch, find, transforms, pose, movement, context, ping) goes to the client: what
  the player sees and does. `pause` pauses both sides (each runs its own simulation);
- on each side the plugin puts a helper script into the running game (`AutopilotPlaytest`: a Script in
  ServerScriptService, a LocalScript in the player's PlayerScripts) through which it reads and calls the game's
  ModuleScripts: a plugin's own `require` runs a module again for the plugin alone, not the game's copy;
- **sockets**: Studio lets each DataModel have only four WebSocket clients, every plugin's counted. The edit plugin
  needs one; when none is free it talks to the agent service over plain HTTP instead (long polls on the port after the
  WebSocket's: `autopilot serve` listens there too). A play session's client can make no HTTP requests at all (only a
  server can), so it needs one free WebSocket.

Findings and errors come from both sides: each runs its own detectors on its own log and physics.

## Reference: what the plugin answers

The wire protocol is the same for every engine (`autopilot/bridge.py`). This section lists what is particular to
Roblox.

### Paths and `rc`

- **Instances** are paths from the DataModel, the first part the service: `/Workspace/Map/Door`,
  `/ReplicatedStorage/Modules/Config`, `/Players/<Name>/leaderstats/Coins`. Siblings that share a name are numbered by
  their debug id, the same on the server and the client: `Coin@617854`; the plain name of twins is the one with the
  lowest number, and a numbered path stays that instance (or is gone). `\` escapes `/`, `@` and `\`. Also accepted: a
  dotted full name (`Workspace.Map.Door`), a path without the leading `/`, a service by name, and `LocalPlayer`,
  `Character`, `Humanoid`, `Camera`. `server:` or `client:` in front chooses the side.
- **Properties** (a read or write's `propertyName`), in turn: a property of the instance's class (from
  `ReflectionService`), an attribute, the `Value` of a child value object of that name, on a player or its character
  its `leaderstats` entry; `position` / `pivot` (a model's or part's pivot: written with `PivotTo`), `attributes`,
  `tags`, `children`. On a ModuleScript, the fields of the table it returns (dotted names go into nested tables). A
  read without `propertyName` returns all of them. Writing a name nothing has sets an attribute.
- **call**: an instance's methods, arguments by the reflection's parameter names or as a list (`args`); a
  ModuleScript's functions, arguments as `args` (or `"1"`, `"2"`...), `self: true` for a method. The answer has
  `ReturnValue` (and `ReturnValues` when there are more).
- **describe**: `{"Name", "Class", "Path", "Properties", "Functions", "Tags", "Children"}`; a module's fields and
  functions first.
- **Values** are Roblox's own: studs; Vector3 `{"x","y","z"}`; CFrame `{"position", "look", "up", "euler"}` (euler:
  `ToEulerAnglesYXZ`, radians); Color3 `{"r","g","b","hex"}`; an EnumItem as its name; an Instance as its path;
  BrickColor as its name; UDim2, NumberRange, Rect, sequences as objects and lists; tables as objects and lists
  (functions as `"<function>"`). Writes convert to the current value's type (or the property's declared type).

### The kit frame (every request but `rc`)

Roblox's frame is x right, y up, -z forward (a CFrame's LookVector at rest), studs, right-handed; the kit's is X
forward, Y right, Z up, centimetres. With 1 stud = 28 cm (Roblox's own conversion): kit `(X, Y, Z) = 28 * (-z, x, y)`.
Yaw is degrees from +X toward +Y (turning right positive) = `-deg(ry)` of `ToEulerAnglesYXZ`; pitch `deg(rx)`, positive
up; roll `-deg(rz)`.

### Requests

| Request | In Roblox |
|---|---|
| `context` | `world` = `/Workspace`, `character` = the local player's character, `controller` = the Player, `camera` = the current camera, `dimension` `3d`, `engine: "roblox"`, `project_dir` `""` (Studio doesn't say where a place's file is), `controls`: the game's ContextActionService actions with their keys, and Roblox's default controls; `camera_type`, `mouse_behavior`, `place_id`, `universe_id`, `input.keys_reach`. |
| `session` | `start` plays the place (a server and one player), `stop` ends the play session, `restart` stops and plays again (the game's scripts start over, the place as Studio has it). A play session the user started joins by itself. `map` other than the place's name: an error (a place is one level). |
| `levels` | `{"levels": [the place], "open": the place, "playing": the place while it plays}` |
| `pause` | `RunService:Pause()` / `Run()` on both sides: physics and the game's scripts stop, the plugin goes on answering. |
| `key` | Unreal key names (W, SpaceBar, LeftShift, One, F5, Enter, LeftMouseButton, MouseX/MouseY in pixels, MouseY positive up, MouseScrollUp/Down, MouseWheelAxis), a KeyCode's name, or a ContextActionService action's name (its first key). Through Studio's virtual input. A press stays down 0.05 s and 2 frames; holds are leased; `seconds` makes a timed hold. MouseX/MouseY with the mouse free hold the right button for the turn (Roblox's default camera turns only while it is held). Gamepad keys: an error (a plugin has no gamepad). |
| `input` | A ContextActionService action by name: its first key, as `key`. |
| `move` | `{"direction": kit vector, "seconds", "scale"?, "via"?}`: the player's `Move` toward it every frame, after the PlayerModule's (`via: "humanoid"`, as an analog stick), or W/A/S/D toward it (`via: "keys"`, 8 ways). Answers `{"moved", "via"}`. |
| `watch` | Pivots sampled every frame (`moved` in kit units, `turned`, `changed size`); with `drawn`, the biggest parts in the thing's own frame and `part shown/hidden`, `light on/off`, `animation started/ended` (the Animator's tracks), `sound started/ended`, `effect started/ended` (particles, fire, beams, trails). |
| `view` | See below. |
| `screen` | The visible texts of TextLabels, TextButtons and TextBoxes in the player's PlayerGui (ContentText), keyed `<ScreenGui>.<Name>` (`#2`, `#3` for repeats). |
| `ui`, `ui_act` | GuiButtons (`button`) and TextBoxes (`text_input`) on screen, with `path`, `class`, `screen` (their middle in viewport pixels, top bar inset included). `click` (and `right_click`, `double_click`) moves the mouse there and presses it: the answer's `fired` says whether the button's `Activated` came. `set` types into a TextBox and submits it (`FocusLost` with Enter); `drag` presses on one and lets go on another. |
| `pointer` | `{"screen_x", "screen_y"}` (-1..1, y up), `{"world": kit point}` or `{"object": path}`: the mouse put there. Answers `{"x", "y", "screen_x", "screen_y", "on_screen"}`. A ClickDetector is clicked by pointing at its part and pressing LeftMouseButton. |
| `record`, `capture` | 409 `no picture`: Studio gives a plugin no picture of the game (its screenshots can't be read back). Runs have no recording. |
| `detectors` | `log_error` (errors the game prints, server and client: LogService), `nan`, `out_of_world` (an unanchored part 50 m below the level's lowest drawn point at the start, or past FallenPartsDestroyHeight), `long_fall` (the player in Freefall for 8 s), `hitch` (a frame over 0.75 s), `hud_fraction`, and `no_input` (keys not reaching the game: Studio not focused). Warnings go as `log` events. |
| `codex_manifest`, `codex_read` | Every script of the place as `src/<Service>/.../<Name>.server.luau` (a Script), `.client.luau` (a LocalScript, or a Script with RunContext Client), `.luau` (a ModuleScript), a script's children in a folder of its name; plus `.autopilot/summary.txt` (the place, Workspace and StarterPlayer settings, tags, every script with where it runs) and `.autopilot/tree/<Service>.txt` (each service's instances: class, place and size, attributes, tags, values, texts; runs of identical siblings told once with their count). |
| `find` | `{"class"?, "name"?, "limit"?, "things"?}`: `class` is a Roblox class (`IsA`), `tag:<name>` (CollectionService; a plain tag name works when no class has it), or the name of a script inside a model; `things: true` the Workspace's things (models and parts at the top or in folders; a model of models is a folder). |
| `transforms` | `{path: {"location", "rotation", "velocity", "center", "extent"} \| null}`: the pivot, the assembly's velocity, the bounding box (world-aligned), in the kit frame. |
| `pose` | `{"at", "feet", "eye", "yaw", "pitch", "velocity", "on_ground", "path"}`: `at` the HumanoidRootPart's centre, `feet` its half height plus HipHeight below, `eye` the camera. |
| `movement` | `{"walk_speed", "jump_z", "gravity", "half_height", "radius", "step", "max_slope", "air_control", "sources"}` from the Humanoid (WalkSpeed, JumpPower or JumpHeight as `sqrt(2 g h)`, MaxSlopeAngle, HipHeight) and the Workspace's Gravity, in kit units. |

### `view`

The Workspace's things inside the camera's view that a line of sight from the camera reaches (the box's centre, top or
nearest point), nearest first, up to `max_count` within `max_distance`; the player and a large floor it stands on are
left out, and a thing with no visible part. Each has `name`, `path`, `class`, `tags`, `center`, `size`, `yaw`,
`distance`, `screen_x` / `screen_y` (-1..1, right and up positive), `partly_in_view`, `speed`, `top_above_feet`,
`bottom_above_feet`, `crosshair_on` (a ray from the view's middle), `health` / `max_health` (a Humanoid's), `player`
(another player's character), `look` (`parts`: visible parts' names, `lights`, `animation`, `sounds`, `effects`,
`texts`: SurfaceGui and BillboardGui) and `label`. `camera` has `location`, `yaw`, `pitch`, `fov` (horizontal), `vfov`,
`type`. `body` has `velocity`, `feet_z`, `on_ground`, `falling`, `state` (the Humanoid's), `health`, `standing_on`,
`floor_slope_degrees`, `touching`. `sonar` works as in Unreal: a box the body's width swept each way above its step
height (a walkable slope or a step is gone up), rays down for drops (`by`: wall, drop, reach). Not provided (the
answer's `omitted`): `held`, `scene.sun`, `openings`, `ways_up`, `lane`, slope ends, `body.under` / `overhead`,
`highlighted`, `limp`.

## Limitations

- **No picture.** Studio gives a plugin no pixels of the game view, so runs have no recording and the agent can't look
  at frames: requests about how something looks are settled on what `view` tells (parts, transparency, colours,
  lights, animations, sounds, effects, texts), and the report says so.
- **Focus.** Keyboard input needs Studio's game view focused (see above).
- **No gamepad**, no touch: keyboard and mouse only.
- **No headless or command-line runs** (CI): a Roblox game runs only in Studio (or Roblox's clients). Bench runs
  (`bench/run_autopilot.py`) need another engine.
- **One level.** A place is one level; teleporting between a universe's places isn't played.
- **One player.** A play session has one player (Studio's local multiplayer test isn't driven).

## Security

The agent can call functions and set properties in the running game, so connect only to an agent service you trust.
The plugin only connects out, to the address you set (by default this computer), and does nothing in a play session
until the edit plugin is connected. The play session's helper script exists only while a session runs.

## Removing it

Delete `Autopilot.rbxmx` from Studio's Plugins folder. Its settings and run history stay in Studio's plugin settings
until Studio forgets the plugin; nothing of Autopilot's is in your places. `autopilot uninstall` removes the agent
service and its files from the computer.

## For contributors

### Source map

All paths are under `plugin/roblox/`.

| File | What it does |
|---|---|
| `src/Main.luau` | The start: which DataModel this is (edit, server, client) and which parts run there. |
| `src/Editor.luau` | The edit DataModel's link to the agent service: the hello, runs, `session` (play, stop, restart), `levels`, the codex, routing requests to the play session's sides, the account and setup frames. |
| `src/Dock.luau` | The dock: connection, account (Aura sign-in, BYOK), memory, the composer, the live run (stages, Stop, Steer), the feed, the result, history, settings. |
| `src/Host.luau` | A play session's side joined to the pipe: requests answered in threads of their own, events once a frame, attach and detach. |
| `src/Client.luau` | The client's ops: input (keys, holds, the mouse), move, watch, view, screen, ui, pointer, find, transforms, pose, movement, context, pause. |
| `src/Server.luau` | The server's ops: rc, find, transforms, pause, ending the play session. |
| `src/Link.luau` | The connection out: a WebSocket, else HTTP long polls; reconnect with backoff. |
| `src/Modules.luau` | The helper script on each side: the game's ModuleScripts as the game has them. |
| `src/Keys.luau` | Unreal key names as virtual input; the mouse; ContextActionService actions. |
| `src/Fallback.luau` | Keys without focus: walking, jumping, prompts as Roblox's own controls put them. |
| `src/Rc.luau`, `src/Values.luau`, `src/Paths.luau` | `rc`: reads, writes, calls, descriptions; values to and from JSON; instances by path. |
| `src/World.luau`, `src/Sight.luau`, `src/Ui.luau` | find, transforms, pose, movement; view, sonar, watch; screen, ui, ui_act, pointer. |
| `src/Codex.luau`, `src/Detectors.luau` | The codex; the in-game detectors. |
| `src/Frame.luau`, `src/Json.luau`, `src/Settings.luau` | The kit frame; JSON (empty objects, NaN); the plugin's settings. |
| `dev/` | The development loader (`AutopilotDev.server.luau`) and its client relay (`DevRelay.luau`): never built into the plugin. |
| `tests/` | The test game (`testgame.luau`) and the live tests (`smoke.py`, `kit_live.py`, `harness.py`). |

### Building and the development loop

`python tools/build_roblox.py [--install]` builds `dist/roblox/Autopilot.rbxmx`: a Script that starts the plugin and one
ModuleScript per `src/*.luau` (no Rojo needed: the model file is written as XML).

While working on the plugin, `python tools/roblox_dev.py install` puts the development loader in Studio's Plugins folder
in place of the built plugin (remove `Autopilot.rbxmx` meanwhile), then reopen the place once, and run `python
tools/roblox_dev.py serve`. The loader fetches the plugin's modules from the dev server in every DataModel and starts
the plugin; when a file in `src/` changes, every DataModel restarts the plugin with it, without reopening anything.
The DataModels' output goes to the dev server's log, and `python tools/roblox_dev.py eval [--dm edit|server|client]
'<Luau>'` runs code in one of them (the edit DataModel too during play). The loader talks HTTP to the dev server, so it
takes none of the DataModel's few WebSockets; the client, which can make no HTTP requests, is fed through the plugin's
settings by `dev/DevRelay.luau`, which only the dev server's bundle carries.

### Running the tests

The Python tests (`tests/test_roblox.py`, in `pytest`) check the adapter and the plugin's sources and build without
Studio (with `luau-compile` on PATH, also that every module compiles). The live tests need Studio:

1. Open a Baseplate in Studio with the plugin (built or from the dev loader), and build the test game into it:
   paste `tests/testgame.luau` into the command bar (or `python tools/roblox_dev.py eval - <
   plugin/roblox/tests/testgame.luau`). **Lantern Grove** has six lanterns to collect (a CollectionService tag), a
   lever with a ProximityPrompt that opens a gate, a crate to jump on, a pond, three same-named posts, a mailbox with a
   ClickDetector, a module with the game's state, remotes, a HUD (`Lanterns n / 6`), a menu (a button, a text box) and a
   ContextActionService action (Q waves). Two planted bugs: the mailbox's script indexes nil when clicked
   (`log_error`), and the gate's door falls through the ground once opened (`out_of_world`).
2. Stop any `autopilot serve` (the tests listen where the plugin connects), click into Studio's game view and leave it
   focused, and run `python plugin/roblox/tests/smoke.py` (every request) and `python plugin/roblox/tests/kit_live.py`
   (the brain's kit: walk_to, look_at, jump_to, go_and_press, the UI, restart). `AUTOPILOT_ROBLOX_TEST_PORT` sets the
   port when the plugin is set to another than 8765.

## License

Apache-2.0, as the rest of the repository.

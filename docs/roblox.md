# Roblox (experimental)

Autopilot plays Roblox places through **Roblox Studio's built-in MCP server**. There is no Autopilot plugin inside
Studio. A small connector process (`autopilot/engines/roblox.py`) connects to Autopilot as a plugin would and turns the
protocol's requests into Studio MCP tool calls. This is called **Route A**.

> **Status: not yet verified against a live Studio.** Everything here is built and tested against a stand-in for
> Studio's MCP server (`FakeStudio` in `autopilot/engines/roblox_mcp.py`, and a simulated place in
> `tests/robloxsim.py`). Roblox documents the tools' names and purposes but not their exact argument schemas, so the
> argument names and the input actions' JSON are best guesses, marked `TODO(verify)` in
> `autopilot/engines/roblox_mcp.py`. Check them with `python tools/roblox_latency.py --tools` (see
> [Open questions](#open-questions)).

## How it works

```
Autopilot (the brain) <-- bridge WebSocket, protocol v1 --> Roblox connector <-- MCP over stdio --> Studio's MCP server
                                                            (engines/roblox.py)                    (StudioMCP / mcp.bat)
```

| What Autopilot does | The Studio MCP tool it uses |
| --- | --- |
| reads: find, transforms, pose, movement, get, set, call, screen, ui, view | `execute_luau` with the Luau ops of `engines/roblox.luau`; all the reads of one `game.batch` go in **one** call, answered as one JSON string (`HttpService:JSONEncode`) |
| keys, mouse buttons, camera turns, UI clicks | `user_keyboard_input`, `user_mouse_input` (a right-drag turns the camera) |
| `game.request("move", {"to": ...})` | `character_navigation` |
| start, stop and restart the session | `start_stop_play` (a restart is stop, then start) |
| the game's errors (`log_error`) | `get_console_output`, read every couple of seconds while the game plays |
| stills | `screen_capture` |
| the codex | a Rojo project's files from disk, else every script via `script_read`; the place's CollectionService tags and its instance tree (`search_game_tree`) |

While the game plays, reads run in the **Client** data model (what the player's copy shows), and writes and calls run
in the **Server** data model (where the truth is kept). The kit's frame is Roblox's Y-up studs at 1 stud = 28 cm (Roblox's
physics takes a stud as 0.28 m).

## Setup

1. **Turn on Studio's MCP server.** In Roblox Studio, open **Assistant**, click **...** > **Manage MCP Servers**, and turn
   on **Enable Studio as MCP server**.
2. **Open the place** in Studio. A Rojo project needs building first (`rojo build <project> -o Place.rbxlx`) or serving
   with the Rojo plugin (`rojo serve`).
3. **Install Autopilot from a clone** (see [CONTRIBUTING.md](../CONTRIBUTING.md#development-setup)) and set your keys in
   `.env`. Through Aura, sign in as usual.
4. **Start the brain**: `autopilot play "Verify that ..." --project <the place>`, or `autopilot serve`.
5. **Start the connector** on the same machine as Studio:

   ```bash
   python -m autopilot.engines.roblox connect --project <the Rojo folder or .rbxl/.rbxlx>
   ```

   It starts Studio's MCP server, checks its tools (with a message on what to do when one is missing), and connects to
   the brain (the address in `brain.json`, else `ws://127.0.0.1:8765/v1/bridge`; `--url` to say another).

The server's command is the one Roblox documents: `cmd.exe /c %LOCALAPPDATA%\Roblox\mcp.bat` on Windows,
`/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP` on macOS. Studio doesn't run on Linux.

### Environment variables

| Variable | Default | What it does |
| --- | --- | --- |
| `AUTOPILOT_ROBLOX_MCP_CMD` | Roblox's documented command | the command line that starts Studio's MCP server |
| `AUTOPILOT_ROBLOX_STUDIO_ID` | (the only one) | which Studio to play when the server is connected to several (`list_roblox_studios`) |
| `AUTOPILOT_ROBLOX_RESULT` | `return` | `print`: Luau chunks also print their JSON answer, for a server that gives back only printed output (the connector switches by itself when it sees that) |
| `AUTOPILOT_ROBLOX_CONSOLE_SECONDS` | `2` | how often the console is read for errors while the game plays |
| `AUTOPILOT_ROBLOX_LOCALAPPDATA` | (set by the bench) | the real `%LOCALAPPDATA%`, for `mcp.bat`, when the bench gives the brain a settings folder of its own |

**Recommended: `AUTOPILOT_SHARE=0`** while Roblox support is experimental, so runs' data (the place's scripts among
it) is never shared: `AUTOPILOT_SHARE=0 autopilot play ...`. The connector's `--no-share` says the same in its hello.

## Measure the round trip first

```bash
python tools/roblox_latency.py                 # 100 execute_luau calls in play mode: p50, p95, recommended tempo
python tools/roblox_latency.py --tools         # what the server offers, with each tool's input schema
```

Each read and input is a round trip through Studio's MCP server. The tool times the engine's own batched observe and
prints the `tick_hz` and `tempo` a harness can keep at that speed. The agent's kit section tells it to stay within them.

## The bench

```bash
python bench/run_autopilot.py --project examples/roblox_testplace --suite bench/suites/roblox_testplace.json
```

For a Roblox project the bench starts the connector instead of a headless game, so Studio must be open on the built
test place with its MCP server on. Prompts run one at a time (one Studio, one play session). The test place
(`examples/roblox_testplace`, see its README) has an obby with checkpoints, a coin, a lever that opens a door, and a
debug ModuleScript, all tagged with CollectionService. The suite's expected verdicts come from the place's code: none of
them has been run against Studio yet.

## Known limits

- **Latency.** Every read and input is an MCP round trip, likely tens to hundreds of milliseconds (not measured yet).
  Batched reads cost one round trip, so the agent is told to batch them. Reflex play (dodging a hit a fraction of a
  second ahead) is likely out of reach. The decision tempo is bounded by the measured latency.
- **No pause.** Studio's MCP server can't pause a play session: the game runs while the agent thinks.
- **Stills, not video.** There is no recording, only `screen_capture` stills.
- **No frame-accurate detectors.** Findings come from the console (errors and warnings). NaN, hitch, teleport and
  long-fall detectors don't exist here.
- **The view tells less** than the other engines': no held items, openings or ways up (so `walk_to` won't find ramps by
  itself), and no looks or effects. Its `omitted` lists them.
- **One place.** `game.restart(map=...)` can only restart the place open in Studio.
- **No named input actions.** ContextActionService and UserInputService bindings are pressed by their keys.
- **Not headless.** Studio must be open, so it can't run in CI.

## Open questions

These need a live Studio (see `TODO(verify)` in `autopilot/engines/roblox_mcp.py`):

- **Argument names** of every tool. The client takes them from each tool's `inputSchema` when the server advertises one,
  else falls back to guesses (`code` / `datamodel_type` for `execute_luau`; `is_start` for `start_stop_play`, else a
  `mode` string; `path` for `script_read`...).
- **The input actions' JSON** for `user_keyboard_input` and `user_mouse_input` (`{"type": "key_down", "key": "W"}`,
  `{"type": "click", "button": "left", "x", "y"}`...), and whether keys are KeyCode names.
- **What `execute_luau` returns**: the chunk's return value, its printed output, or both, and in what wrapper.
  The connector reads JSON out of either, and switches to printing when no returned value comes back.
- **`get_console_output`'s format**: whether each line says its message type. Errors are told by their words until then.
- **`get_studio_state`'s format**, which tells whether a play session runs.
- **`character_navigation`'s target**: an object `{"x","y","z"}` or a list, and whether it waits until the character
  arrives.
- **`screen_capture`'s result**: an image content item (PNG or JPEG) is assumed. Roblox's docs also mention a capture id.
- **Data models during play**: whether `Client` and `Server` both answer `execute_luau` in a Studio play session (Play,
  not Run), and whether `Players.LocalPlayer` is set in the Client one.
- **Real latency** of `execute_luau` in play mode, and so the tempo a harness can keep.

## Future work: Route B

Route B is a native Luau Studio plugin that speaks Autopilot's bridge protocol itself, connecting out to the brain over
a WebSocket from inside Studio (which Studio API allows that for plugins is still to be confirmed), as the Unity and
Godot plugins do. It would remove the MCP hop and the connector process, answer each read inside one frame, and could
run frame-accurate detectors (NaN, teleport, long falls, hitches) and send frames from the game itself. Route A's Luau
ops (`engines/roblox.luau`) and its kit-frame conversion are written to carry over.

# Roblox football practice place

An original American-football-style passing drill for trying Autopilot's Roblox engine (`autopilot/engines/roblox.py`).
It has no league names, logos or assets, and nothing is taken from an existing game: every part is built by its own
scripts. It is a [Rojo](https://rojo.space) project, so the whole place is text.

> **Not yet run in Studio.** The scripts were written without Roblox Studio (which doesn't run on Linux). The rules
> were checked with a frame-by-frame Python port, but the place itself has never been played. See
> [What is unverified](#what-is-unverified).

## The drill

The player is the **quarterback**. Each play goes **PreSnap → Live → Dead**, then resets:

- **PreSnap** (3 s): everyone lines up and the QB can't move. Then the ball is snapped.
- **Live**: the receivers run their routes, two defenders cover and one rushes, and the QB throws or runs.
- **Dead**: the play is over and `ReplicatedStorage.PlayState`'s `Result` says how: `Touchdown`, `Tackled`,
  `Incomplete`, `Intercepted`, `OutOfBounds` or `Safety`. Four seconds later the play resets **from the same line
  of scrimmage**. It is a drill, so the spot never moves on its own.

| Who | Where they start (from the line of scrimmage) | What they do |
| --- | --- | --- |
| QB (the player) | 5 yards back | throws (aim + power) or runs; can throw only from behind the line |
| X receiver | wide left | **Go**: straight downfield 40 yards |
| Z receiver | wide right | **Slant**: 5 yards, then in toward the middle |
| Y receiver | tight left | **Post**: 12 yards, then toward the middle, ending 24 yards downfield. **Nobody covers Y: Y is the open receiver** |
| CB1, CB2 | 6 studs off X and Z | stay 2 studs on the QB's side of their receiver (18 studs/s) |
| R1 | off the right edge | rushes the QB 4 s after the snap, at 12 studs/s (the QB walks at 16) |

Every Heartbeat while the play is live:

- **Catching.** A thrown ball, once it's no higher than 7 studs, is caught by the closest receiver or defender within
  3.5 studs (horizontally). A receiver's catch is a **completion**, and the receiver then runs straight for the end
  zone. A defender's catch is an **interception**, and the play is dead. A ball that comes down, or leaves the
  field, is **incomplete**. While the ball is in the air, every defender runs for where it will come down.
- **Tackles.** A defender within 3 studs of the ball carrier tackles them, and the play is dead. Once a receiver has
  the ball, or the QB runs past the line, every defender chases the carrier at 18 studs/s.
- **Scoring.** A carrier past the scoring goal line (`z = 100`) scores a **touchdown**: +6 `Points` and +1
  `Touchdowns` in leaderstats. A catch made inside the end zone scores at once.
- **Out of bounds.** A carrier past a sideline (`|x| > 53`) ends the play. One brought down behind their own goal
  line is a safety, which scores nothing in this drill.

### Throwing

Aim with the mouse: the throw goes toward the point under the cursor, shown by a white ring. **Hold the left button**
to charge power (full after 1 s), then **release** to throw. Or press **1–9 / 0** to set a fixed power (10%–100%)
so that a click throws at it, and press **C** to go back to charging. Power sets the ball's speed, from 30 to 100
studs/s. The ball takes the flatter arc that comes down through the aim point at chest height (3 studs). If even a
45° throw can't reach that far, the ball flies at 45° and falls short. The flight is computed by the server
(`Football.luau`), not simulated by physics, so the same throw always flies the same way. At full power a throw
reaches about 125 studs.

The surest completion is to throw at full power at **Y's route-end disc** (`RouteEnd` tag, attribute
`Receiver = "Y"`) between about 1.9 and 3 s after the snap.

## Coordinates

The unit is studs, at 1 yard = 2 studs. The offense always attacks **+z**:

- The scoring goal line is at `z = 100`, and its end zone runs to `z = 120`. The offense's own goal line is at
  `z = -100`.
- The field runs from `x = -53` to `x = 53`, and the turf's top is at `y = 0`.
- The line of scrimmage is at `z = 100 - 2 × YardsToGoal`. A new play starts 70 yards to go (the offense's own 30).

## Tags (CollectionService)

| Tag | On | Attributes |
| --- | --- | --- |
| `Field` | the turf | |
| `EndZone` | both end zones | `Scoring` (true for the one the offense scores in) |
| `GoalLine` | both goal lines | `Scoring`, `YardsToGoal`, `Yard` |
| `YardLine` | every 5 yards, goal lines included | `YardsToGoal` (to the scoring goal line), `Yard` (the painted number) |
| `Sideline` | both sidelines | |
| `LineOfScrimmage` | the blue line | `YardsToGoal` |
| `Football` | the ball | `State` (`Held`, `Air`, `Ground`), `Carrier`, `Power`, `Landing` (where a throw comes down) |
| `BallCarrier` | whoever has the ball (the QB's character or a receiver), only while the play is live | |
| `Quarterback` | the player's character | |
| `Receiver` | X, Y, Z (models; `HumanoidRootPart` is the body) | `Route`, `Mode` (`Set`, `Route`, `Settled`, `RunAfterCatch`), `Velocity` |
| `Defender` | CB1, CB2, R1 and spawned ones | `Assignment` (a receiver, `Rush` or `Pursue`), `Mode`, `Velocity` |
| `RouteEnd` | a disc where each route ends | `Receiver` |
| `PlayState` | `ReplicatedStorage.PlayState` | `Phase`, `Result`, `LastResult`, `Carrier`, `BallState`, `YardsToGoal`, `LineOfScrimmageZ`, `PlayId`, `SnapTime`, `Tackler`, `Message`, `Quarterback` |

Receivers and defenders have no Humanoid. The server moves them (anchored, no collisions), so their speed is in their
`Velocity` attribute.

## Debug helpers

`ServerScriptService/Debug` is a ModuleScript that an agent calls to set up or read a verification, for example
`game.call("ServerScriptService/Debug", "ResetPlay", args=[20])`. Each helper changes the game directly, as no player
could. Each one goes through `ServerStorage.FootballCommand` (a BindableFunction that `Main.server.luau` answers), so
it works from any Luau context.

| Function | What it does |
| --- | --- |
| `ResetPlay(yardsToGoal?)` | a new play from that spot (1–99, nil keeps it); removes spawned defenders; snaps 3 s later; returns `PlayId` |
| `Snap()` | snaps now |
| `SetBallCarrier(name)` | gives the ball to `"QB"` or `"X"`/`"Y"`/`"Z"` (snapping first if needed); errors once the play is dead |
| `SpawnDefender(x, z)` | a defender at a point who chases the carrier at 18 studs/s; returns its name (`D1`...) |
| `ClearDefenders()` | removes every defender until the next reset |
| `Throw(x, z, power)` | throws as the QB, under the same rules, for when the mouse can't be used |
| `GetScore()` | `{ Points, Touchdowns, Completions }` |
| `GetState()` | the play's state plus everyone's position |

## Open it in Studio via Rojo

You need [Rojo](https://rojo.space/docs/v7/getting-started/installation/) 7 and Roblox Studio. Either build a place
file:

```bash
rojo build examples/roblox_football -o FootballPractice.rbxlx
```

Then open `FootballPractice.rbxlx` in Studio. Or sync it live: install the Rojo Studio plugin and run:

```bash
rojo serve examples/roblox_football
```

Then open a new Baseplate place in Studio, delete its `Baseplate` part, and click **Connect** in the Rojo plugin.

Press **Play** (not Run: the player is the QB). For Autopilot, also turn on Studio's MCP server (see
[docs/roblox.md](../../docs/roblox.md)).

## Run the bench suite

```bash
python bench/run_autopilot.py --project examples/roblox_football --suite bench/suites/roblox_football.json
```

Each prompt's `expected` verdict comes from the code (its `why` says where). The timings come from a frame-by-frame
Python port of `Football.luau`'s rules, which isn't part of the repository. For example, with full power at Y's
route end, a throw made 1.9–3 s after the snap is caught (from the own 30 Y then runs for a touchdown), and a QB who
holds the ball is sacked by R1 about 5.1 s after the snap. None of these has been run against a live Studio.

## Files

| File | Becomes | What it is |
| --- | --- | --- |
| `src/shared/Config.luau` | `ReplicatedStorage.Config` | every number and tag |
| `src/server/Build.luau` | `ServerScriptService.Build` | builds and tags the field |
| `src/server/Football.luau` | `ServerScriptService.Football` | the play: players, ball, rules, reset |
| `src/server/Main.server.luau` | `ServerScriptService.Main` | starts it all; answers `FootballCommand` |
| `src/server/Debug.luau` | `ServerScriptService.Debug` | the debug helpers |
| `src/client/Controls.client.luau` | `StarterPlayerScripts.Controls` | aim, power, throw; the HUD |
| `src/gui/Hud.model.json` | `StarterGui.Hud` | score, play, message, power bar |

## What is unverified

Without Studio, none of this has been seen running. In particular:

- **Type checking.** Every `.luau` file compiles with `luau-compile` (the open-source Luau compiler), which checks
  syntax only. Studio's strict type checker has **not** been run, so `--!strict` may show type warnings. Those don't
  stop scripts from running.
- **Whether `rojo build` accepts the project**. The project follows `examples/roblox_testplace`'s layout, but Rojo
  hasn't been run on it.
- **Looks**: the yard numbers' orientation on the turf (`SurfaceGui` on the top face, rotated ±90°), the route discs
  and aim ring (cylinders turned on end), the ball's shape (a sphere mesh stretched to 0.8 × 0.8 × 1.4), and whether
  the camera starts behind the QB facing downfield.
- **Feel and timing**: whether the QB's character settles at a root height of about 3 studs (the throw's release is
  1.5 studs above the root), and whether a 60 Hz server Heartbeat is fast enough: at 100 studs/s the ball moves
  about 1.7 studs a frame, inside the 3.5-stud catch radius, but there's no sub-stepping.
- **Players**: one player is assumed, and the first player is the QB. Respawning resets the play.
- **For Autopilot**: whether a held left button can be sent through Studio's MCP `user_mouse_input` (if it can't,
  use the number keys, or `Debug.Throw`), and whether `game.call` can return `GetState`'s nested tables.

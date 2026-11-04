# Prism Gauntlet

An original neon obby for watching Autopilot learn: eight floating stages over a void, each asking for a different
skill, built entirely from code (a [Rojo](https://rojo.space) project) and counted by the game itself.

| # | Stage | What it asks for | What kills |
| --- | --- | --- | --- |
| 1 | **Stepping Stones** | jumps over gaps that widen from 4 to 6.5 studs, some a step higher, swaying side to side | the void |
| 2 | **Laser Hall** | timing: three laser gates switch on and off; each runs a walk's time behind the one before, so one steady walk started as the first goes dark passes them all | lasers |
| 3 | **Drift** | riding: two platforms shuttle over the void, waiting at each end; board, ride, step off onto a rest pad, board the next | the void |
| 4 | **Crumble Bridge** | commitment: nine tiles that fall 0.55 s after you step on them | the void |
| 5 | **Conveyor Climb** | a narrow ramp whose belt runs back down at 7 studs/s against your 16 | the void |
| 6 | **Phase Shift** | rhythm: blocks in two sets that take turns being solid every 1.6 s | the void |
| 7 | **Skyward Steps** | climbing: ten blocks zig-zagging up 30 studs around a column of light | the void |
| 8 | **Final Sprint** | a 3-stud beam to the finish portal, with two laser gates | lasers, the void |

Every gap and timing is in [`src/shared/Config.luau`](src/shared/Config.luau), and the course is laid out from it:
change a number there and the place changes. The character is Roblox's default (WalkSpeed 16, JumpHeight 7.2), set
in `default.project.json`, and every stage was checked to be beatable with it (the widest jump, stone 4 to stone 5,
lands with a run-up of a stone's radius).

## How it's built

```
src/shared/Config.luau     every number: the stages, their gaps and timings, the colors
src/shared/Clock.luau      the timing, from the shared clock (workspace:GetServerTimeNow()), the same on every machine
src/server/Main.server.luau  builds the course, then starts the rules
src/server/Course.luau     lays the course out from Config: one builder per kind of stage
src/server/Style.luau      how it looks: islands, neon rims, arches, beacons, the grid below
src/server/Rules.luau      stats, checkpoints, what kills, the timed parts, the finish, the log
src/server/Debug.luau      helpers for setting up a test (logged when used)
src/client/Motion.client.luau  the moving platforms (carrying whoever stands on them) and the crystals
src/client/Hud.client.luau     the HUD: stage, deaths, the run's time, a progress strip, toasts
```

- **Everything is tagged** (CollectionService): `Checkpoint` (attribute `Stage`), `Hazard` (`Kind`: Laser or Void;
  `Active`), `Mover` (`From`, `To`, `Travel`, `Dwell`, `Offset`), `Crumble` (`State`), `Phase` (`Solid`), `Conveyor`,
  `Finish`, `Spawn`. A timed part carries its `Period`, `OnSeconds` and `Offset`, so its state can be predicted from the
  shared clock.
- **The moving platforms move on each client**, where the player's character is simulated, so they carry it smoothly.
  The server's copy of a platform stays at its `From` end: read a platform's position from the client.
- **Decoration never gets in the way**: islands' undersides, rims, arches, beacons, the grid and the crystals don't
  collide, aren't touched and aren't hit by rays.
- **Stats**: `leaderstats.Stage` (the furthest checkpoint) and `leaderstats.Deaths`, and the player's attributes
  `RunStart`, `Finished`, `FinishSeconds`.

## The log

Everything that happens is one line in Studio's Output: `[Gauntlet] {json}`, with the play session's id (`session`),
the seconds since it started (`t`) and the time of day (`wall`):

| event | fields |
| --- | --- |
| `session` | `place`, `stages` |
| `spawn` | `player`, `stage` |
| `checkpoint` | `player`, `stage`, `name` |
| `death` | `player`, `stage`, `cause` (Laser, Void, Unknown), `deaths`, `at` |
| `finish` | `player`, `seconds`, `deaths` |
| `debug`, `reset` | a Debug helper changed the run |

[`tools/learning_curve.py`](../../tools/learning_curve.py) scores runs from these lines, so a run's deaths and progress
come from the game rather than from whoever played it.

## Debug helpers

`ServerScriptService/Debug` (a ModuleScript): `GoTo(name, stage)` puts a character on a checkpoint's island,
`SetStage(name, stage)`, `Stats(name)`, `Reset(name)`. They change the game as no player could: a run that uses them
didn't earn what it reached, and each use is logged.

## Open it in Studio

```bash
rojo build examples/roblox_gauntlet -o Gauntlet.rbxlx   # or `rojo serve` with the Rojo Studio plugin
```

Open `Gauntlet.rbxlx` in Roblox Studio, turn on Studio's MCP server (see [docs/roblox.md](../../docs/roblox.md)), and
press Play.

## Watch Autopilot learn it

```bash
python tools/learning_curve.py run --project examples/roblox_gauntlet --runs 8 --minutes 15 --agent claude \
    --studio Gauntlet.rbxlx --record
```

The same goal, eight times, on one memory that starts empty: each run inherits what the ones before it learned.

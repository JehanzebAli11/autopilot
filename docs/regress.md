# Regression replay

`autopilot regress` replays every CONFIRMED verification as a saved harness, without a language model, so a change
that breaks something that used to work shows up. No agent and no Jev are called.

## What gets saved

When a run reports a claim CONFIRMED (`agents/session.finish`), the harness of the episode that showed it is kept:

```
<regressions>/<project>/<run id>/      (AUTOPILOT_REGRESSIONS, else memory/<project>/regressions/<run id>/)
    harness.py         the episode's harness (the run's harness<n>.py)
    lib.py             the project's lib.py as the run left it (a snapshot)
    regression.json    the claim, the verdict, the episode's end (status state and evidence), Jev's picks in order
```

The saved episode is the run's latest one that started from a restarted level and ended `done`. An episode that
continued from where an earlier one left off (`run_harness(restart=False)`) depends on game state a replay can't
rebuild, so if that's the only kind of episode a run has, nothing is saved.

## Replaying

```bash
autopilot regress --project <game copy>                 # starts the game headless (Roblox: the connector to Studio)
autopilot regress --no-launch                           # waits for the editor's plugin instead
autopilot regress --project <game> --regressions <dir> --json results.json
```

Each regression restarts the level and runs its harness through the runtime, just as an episode does. Its decisions
come from `ReplayJev` instead of Jev: the recorded picks in order (each one looked for within the next few options
offered, since timings differ between runs), falling back to the option the recording picked most. No language model
and no Jev are called. A replay passes when the episode ends in the recorded state (`done`) with the same evidence:
booleans, strings and None must be equal, and numbers must be within the regression's `tolerance` (relative, default
0.25). A failure says why, for example `ended running (...), not done` or `evidence differs: coins: 1 then, 2 now`.

By default a replay imports the project's lib.py as it is now. That is the point: a change to lib.py that breaks an
old verification shows up. Use `--frozen-lib` to replay against each regression's own snapshot instead. Other options:
`--seconds` sets the longest episode (default 1.5 times the recorded one, at least 20 s), `--engine` the game's
executable, and `--port` the port to listen on.

The command exits 0 when every regression passes and 1 otherwise, so it can gate a change in CI or a script.

## Testing

`tests/test_regress.py` runs it all against the simulated Roblox place (`tests/robloxsim.py`, with harnesses from
`tests/simharness.py`), with no Studio, engine or model. A run CONFIRMS a claim and is saved, it replays without a
model, a change to lib.py makes the replay fail (and the frozen snapshot still passes), DENIED claims and continued
episodes aren't saved, and `autopilot regress` exits 1 when one fails.

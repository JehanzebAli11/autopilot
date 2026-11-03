# Evolve and regression replay

Two tools for working on Autopilot itself (from a clone, not an installed copy):

- **`autopilot evolve`**: an autoresearch loop. It changes one piece of Autopilot at a time, measures the change on a
  locked bench suite, and keeps it only if the suite does better. Everything it tries goes into an experiments log.
- **`autopilot regress`**: replays every CONFIRMED verification as a saved harness, without a language model, so a
  change that breaks something that used to work shows up.

Both are tested against the simulated Roblox place (`tests/robloxsim.py`) and fakes. They have not been run against a
live engine or a real model yet.

## The evolve loop

The loop follows Karpathy's autoresearch: a fixed evaluation, one change at a time, keep or revert, log everything.

```
baseline = run the suite
for each experiment:
    put the change into one target            (the file is rewritten in place)
    measure = run the suite (prompts in parallel), and the regressions if given
    keep  if the pass rate rose
          or, at an equal pass rate, time or tokens fell by --min-gain (default 2%) and the other didn't rise as much
          and no regression that passed before now fails
    else revert                                (the file goes back byte for byte)
    append the experiment to the log; a kept change becomes the new baseline
```

### Targets

Each experiment edits exactly one target, written `kind:selector[@file]`:

| Target | What it edits | Default file | Checked before it runs |
| --- | --- | --- | --- |
| `prompt:<n or first words>` | one paragraph of the agent's system prompt (paragraphs are separated by blank lines) | `autopilot/agents/session.py`, string `SYSTEM` (`@file#VAR` names another) | still one triple-quoted string; the same `{format}` fields; the file compiles |
| `kit:<heading>` | one section of KIT.md: its heading and body, up to the next heading at the same or a higher level | `autopilot/KIT.md` | starts with a heading at the same level; holds no other heading that high |
| `const:<module.NAME>` | the value of a module-level constant, e.g. `const:kit.control.SONAR_EVERY` | the module, under `autopilot/` (`const:NAME@file` for any file) | a Python literal; the file compiles |
| `lib:<function>` | one top-level function of the project's `lib.py`, decorators included | `memory/<project>/lib.py` (`--lib` or `@file` for another) | one function with the same name; the file compiles |

A selector is a 1-based number or the first words of the paragraph or heading. It has to match exactly one. To see
what a target holds now:

```bash
autopilot evolve --show "prompt:Rules"
autopilot evolve --show "kit:What makes a harness play well"
autopilot evolve --show "const:kit.control.WAYPOINT_REACHED"
autopilot evolve --show "lib:walk_to_door" --project examples/roblox_testplace
```

A change that fails these checks is logged as `invalid` and never runs. Nothing under `bench/`, `tests/` or a
`regressions/` folder can be a target, and neither can the suite or the log. Those are the measure, so an experiment
that tries one is logged as `refused`.

### The locked suite

The first run hashes the suite into `<out>/suite.lock`. A later run against a changed suite is refused, because one
experiments log should only ever measure one suite. Use a fresh `--out`, or `--relock` to start a new lock in the same
log. The hash is checked again after every experiment.

### Where changes come from

- **A candidates file** (`--candidates`): written by hand, or by another tool.

  ```json
  {"experiments": [
    {"target": "const:kit.control.SONAR_EVERY", "text": "0.3", "note": "look less often while walking"},
    {"target": "kit:Reacting in time", "file": "reacting.md", "note": "shorter, with the timing table"},
    {"target": "prompt:Rules", "file": "rules.txt"}
  ]}
  ```

  `file` paths are relative to the candidates file.

- **A model** (`--target <spec> --propose N`): N proposals for each target, one after another. Each proposal sees the
  target's current text, the suite's misses (prompt, expected answer, what it got, the summary), and the log of what
  was already tried on that target with its decision, so it won't repeat a change that was reverted. The model is the
  brain's reading model (`autopilot/llm.py`), using `AUTOPILOT_PROVIDER` (default `anthropic`) and the keys in `.env`.

### Running it

```bash
autopilot evolve --project <game copy> --suite bench/suites/roblox_testplace.json \
    --candidates experiments.json --parallel 2 --repeats 2 --regressions memory/TestPlace/regressions
autopilot evolve --project <game copy> --suite bench/example.json --target "kit:The plan" --propose 5
```

| Option | What it does |
| --- | --- |
| `--suite` | the bench suite (JSON, the bench's format) |
| `--project` | the game the suite runs on; each measure is a `bench/run_autopilot.py` run |
| `--parallel N` | prompts at a time (default 2). A Roblox place always runs one at a time, because there is one Studio |
| `--repeats R` | suite runs per measure, averaged (default 1). Runs are noisy, so use 2-3 when changes are small |
| `--min-gain` | the share time or tokens must fall by at an equal pass rate (default 0.02) |
| `--regressions DIR` | also replay these regressions on every measure; a change that breaks one is reverted |
| `--lib` | the lib.py that `lib:` targets edit and that each prompt's memory starts with (default: the project's) |
| `--out` | the log's folder (default `bench/evolve/`, which git ignores) |
| `--minutes`, `--model`, `--agent`, `--codex`, `--engine` | passed through to the bench |

The bench gives each prompt a cold memory. For `lib:` targets, evolve passes the bench `--lib`, so every prompt starts
with the lib.py being evolved. Tokens come from each run's report (`tokens`: all kinds summed). Time is the wall time
per prompt.

### The experiments log

Every run appends to `<out>/`:

- `experiments.jsonl`: one record per line, starting with the baseline. Each record has `n`, `when`, `kind`
  (`baseline` or `experiment`), `target`, `file`, `note`, `diff`, `baseline` (the metrics it was compared with),
  `metrics` (pass rate, passed/total, seconds and tokens per suite run, each prompt's results, regressions),
  `decision` (`baseline`, `keep`, `revert`, `invalid`, `skipped`, `refused`, `error`) and `why`.
- `experiments.md`: the same as a table, one row per experiment, linking each diff.
- `diffs/<n>.diff`: the unified diff of each experiment, whether it was kept or reverted.
- `runs/<time>-<label>/`: the bench's folders for each measure.
- `suite.lock`: the suite's hash.

### Safety

The target's file is rewritten in a single step (a temporary file, then a rename). Before an experiment changes
anything, the original file is saved to `<out>/pending.json`. If the loop is stopped with Ctrl+C, the file is put back
straight away. If the process is killed, the next `autopilot evolve` on the same `--out` puts it back before doing
anything else. A suite that fails (the bench crashes) is logged as `error` and the change is reverted. Kept changes
stay in your working tree as ordinary edits: review them with `git diff` and commit the ones you want.

## Regression replay

### What gets saved

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

### Replaying

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

The command exits 0 when every regression passes and 1 otherwise. That's what `autopilot evolve --regressions` uses
to revert a change.

## Testing

`tests/test_evolve.py` and `tests/test_regress.py` run everything without Studio, an engine or a model:

- the simulated Roblox place (`tests/robloxsim.py` behind `roblox_mcp.FakeStudio`), with harnesses from
  `tests/simharness.py` that use a test `lib.py` and a constants module. The loop keeps a lib.py fix that raises the
  pass rate from 1/3 to 3/3, reverts one that lowers it, and keeps a constant that makes the suite faster. The
  prompts of each suite run play at the same time.
- a fake agent whose results depend on a prompt file and a KIT.md, for `prompt:` and `kit:` targets: a kept change
  that raises the pass rate, a kept change that saves tokens, a reverted one that gains nothing, invalid and refused
  changes, model proposals from a fake model, the suite lock, and recovery after an interrupt or a kill.
- regressions saved from an episode on the simulated place, replayed without a model, failed by a lib.py change, and
  gating the loop: a change the suite likes but that breaks a regression is reverted.

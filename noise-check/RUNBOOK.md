# Noise check: runbook for Claude Code

**Question:** if a change does nothing at all, how often would `autopilot evolve`'s keep rule keep it anyway?
**Method:** an A/A test.
1. Run the testplace suite 10 times on unchanged code.
2. `tools/aa_noise.py` replays evolve's own `decide()`, `noise_of()` and `metrics()` over every way of drawing a baseline (3 runs), an unchanged "candidate" (1 run) and its confirmation (1 run).
3. Every keep is a false one.

**Three rules compared:**
- plain autoresearch;
- the noise floor alone;
- the noise floor plus confirm (evolve's default).

**Branch:** `noise-check` on `JehanzebAli11/autopilot`, made from `ramenvr/autopilot` staging at `498252b`. The Autopilot code is not changed. Only `tools/aa_noise.py`, the suite and this folder are added.

---

## Rules (they override everything below)

1. **Change no Autopilot code** (`autopilot/`, `plugin/`, `bench/run_autopilot.py`). This measures the code as it is.
2. **Push only to the fork (`origin`).** Never push to `up` (`ramenvr/autopilot`), never open a PR, never force-push.
3. **Spend:**
   - The agent bills the Anthropic key in this repo's `.env`, and Jev bills the TypeSafe key.
   - **Stop after the smoke run** and show the owner the projected cost of 10 runs.
   - Don't start the 10 runs without the owner's "go" and a cost cap.
   - Stop if the running total passes that cap.
4. **Keys:**
   - Never print, echo or commit `.env`, and never `export` keys in the shell.
   - Never read `.env` beyond checking that the two key names exist: `grep -c '^TYPESAFE_API_KEY=.\+' .env` and the same for `ANTHROPIC_API_KEY`.
5. **Numbers only from files:**
   - every number you report comes from `noise-check/aa_noise.json` or the runs' `summary.json`;
   - the script's self-test numbers are synthetic and are never reported.
6. **Same settings for every run.** Identical env vars, suite, prompts, minutes and model. If anything has to change, start all 10 runs again.
7. **Git:** `Jehanzeb Ali <jehanzeb1111@icloud.com>`.

## Settings for every bench command

```bash
export AUTOPILOT_ENGINE=roblox-mcp   # play through Studio's MCP server
export AUTOPILOT_SHARE=0             # never send run data anywhere
export AUTOPILOT_FAST=0              # Opus fast mode doubles the price; off for this test
# AUTOPILOT_MODEL: leave unset (the default, claude-opus-5-5) unless the owner chooses claude-sonnet-5-5 for cost
SUITE=bench/suites/roblox_testplace.json
ONLY=A,B,C,D,E,F                     # the 6 scored prompts; G (explore) has no answer to score and costs the most
MINUTES=15
```

Write these into `noise-check/SETTINGS.md` exactly as used, together with:
- the staging commit (`git rev-parse up/staging`);
- the Studio version;
- `AUTOPILOT_JEV_MODEL`, if it's set;
- the agent (`AUTOPILOT_AGENT`, default `opencode`).

## Steps

### 1. Check the setup (no spending)

- `git status` shows branch `noise-check`, clean except `bench/results/` (git-ignored).
- Python: `uv venv && uv pip install -e ".[dev]"`. Then `pytest -q tests/test_evolve.py` passes.
- Bun is installed (`bun --version`), because the default OpenCode agent runs under it.
- `.env` has both key names (rule 4). On macOS, Aura is signed out (the bench's docstring explains why).
- `python tools/aa_noise.py --help` works.
- Self-test the script on fake runs (synthetic, never reported). Make 6 folders, each with a `summary.json` like `{"results":[{"id":"A","correct":true,"seconds":100,"tokens":1000,"cost_usd":0.1}, ...]}`, run the script on them, and check that it writes `aa_noise.md` and the two PNGs. Delete the fake folders afterwards.

### 2. The owner opens Studio (ask, then wait)

Ask the owner to:
1. Build the place: `aftman install`, then `rojo build examples/roblox_testplace -o ~/Desktop/testplace.rbxl`. You run these; the owner opens the file in Roblox Studio.
2. Turn on Studio's MCP server (Assistant → … → Settings → MCP Servers → **Enable Studio as MCP server** → "MCP Ready"). `docs/roblox-studio-setup.md` §3 has the details.
3. Keep Studio open on that place, in Edit mode, for the whole test, and keep the Mac awake (`caffeinate -dimsu &` is fine).

### 3. Smoke run (1 prompt, small spend)

```bash
python bench/run_autopilot.py --project examples/roblox_testplace --suite $SUITE --only A \
    --parallel 1 --minutes $MINUTES --out bench/results/noise/smoke
```

Check:
- it connected and played;
- `summary.json` exists;
- what A got versus what was expected;
- `seconds`;
- `cost_usd`.

Then **stop and report to the owner**:
- what happened;
- the cost of prompt A;
- a projection of 10 runs × 6 prompts, taking A's cost × 60 with a ±50% range because prompts differ;
- a recommendation: Opus, or Sonnet if the projection is over about $40.

Wait for "go", a cost cap and the model choice.

If the smoke run fails (no connection, ERROR), read the brain's log in the prompt's folder and `docs/roblox-mcp.md` ("If something goes wrong"). Fix the setup, not the code, and try once more before asking the owner.

### 4. The 10 unchanged runs

```bash
for i in 01 02 03 04 05 06 07 08 09 10; do
  python bench/run_autopilot.py --project examples/roblox_testplace --suite $SUITE --only $ONLY \
      --parallel 1 --minutes $MINUTES --out bench/results/noise/run-$i
  python - <<'PY'   # running total, so the cap is checked between runs
import glob, json
t = sum(float(x.get("cost_usd") or 0) for f in glob.glob("bench/results/noise/run-*/summary.json")
        for x in json.load(open(f))["results"])
print(f"cost so far: ${t:.2f}")
PY
done
```

- **Stop between runs** if the total would pass the cap.
- **Infrastructure failure:** if a prompt's `got` is `ERROR` and its folder has no `report.json` (the game never connected), re-run that whole run. Log it in `noise-check/LOG.md` with the reason.
- **Keep real results as they are.** A wrong answer or a `TIMEOUT` is a real result and stays.
- **Log as you go:** a line per run in `noise-check/LOG.md` with the time, score and cost.

### 5. Analyse

```bash
python tools/aa_noise.py bench/results/noise/run-* --out noise-check
```

This writes `noise-check/aa_noise.json`, `aa_noise.md`, `aa_runs.png` and `aa_false_keeps.png`.

### 6. Commit and push (the fork only)

- Copy each run's `summary.json` to `noise-check/runs/run-XX.json`. Copy only those: the traces and recordings stay out, because they're large and may contain screenshots.
- Commit `noise-check/` with the message "noise-check: 10 unchanged runs and the A/A report".
- `git push origin noise-check`.

### 7. Report to the owner (and stop)

In 10 lines or fewer, all from `aa_noise.json`:
- the pass-rate range across the 10 runs;
- the prompts that flip;
- the 3-run noise floor (mean and range) against the spread over all 10;
- the false-keep rate for each rule, and the "kept for" breakdown;
- the total cost;
- one sentence on what it means, and which follow-up fix the data points to.

The follow-up is **not** built in this task. Then draft into `noise-check/POST_DRAFT.md`:
- the LinkedIn post, from the template below, with the real numbers;
- the maintainer message, filled from the same numbers.

### Post template (fill from the files; keep it honest)

> I contributed `evolve` to Autopilot: a loop that changes the agent one piece at a time and keeps a change only if a test suite improves. It has a safeguard against luck: measure the baseline 3 times, and make every win repeat.
>
> So I tested the safeguard. I ran the same suite 10 times on unchanged code. The pass rate still ranged from X% to Y%.
>
> Then I replayed evolve's own decision rule on those runs. A plain autoresearch loop would have "kept" A% of these non-changes. With the noise floor: B%. With the noise floor + confirm: C%.
>
> [What it means: the safeguard works / where it still leaks, and the fix I'm proposing.]
>
> One Roblox test place, 6 prompts, 10 runs. Charts below.

## Done when

- [ ] the smoke run is reviewed by the owner, who gave a cap and a model
- [ ] 10 runs are complete with identical settings; `LOG.md` and `SETTINGS.md` are written
- [ ] `aa_noise.*` and the charts are in `noise-check/` and pushed to the fork
- [ ] the owner has the 10-line report, `POST_DRAFT.md` and the filled maintainer message

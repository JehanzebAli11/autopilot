# Runbook: Roblox, the bench, evolve, and a public demo

Instructions for a coding agent (Claude Code in Cursor, or similar) that is helping the owner of this repository go
from a fresh clone to a working Roblox demo, an evolve run, and a public fork. Work through the phases in order. Some
steps need the owner to do something; those are marked **[OWNER]**. Stop at each **[CHECKPOINT]**, tell the owner what
happened, and wait for their go-ahead.

## Ground rules

- **Read first:** `README.md`, `docs/roblox.md`, `docs/evolve.md` and `CONTRIBUTING.md`. These docs say what the code
  does. Where this runbook and the code disagree, the code wins: tell the owner.
- **The machine:** Windows or macOS, since Roblox Studio doesn't run on Linux. Use the commands for whichever one
  you're on. Windows cmd: `.venv\Scripts\activate`, `set VAR=value`, `\` in paths. macOS:
  `source .venv/bin/activate`, `export VAR=value`, `/` in paths.
- **Secrets:** never print, commit or paste the contents of `.env`. Never add an `ANTHROPIC_API_KEY`: this setup runs
  the agent on the owner's Claude Code login (`AUTOPILOT_AGENT=claude`).
- **Long commands:** the bench, `autopilot play` and `autopilot evolve` run for minutes to hours. Start them in a
  terminal the owner can see (or in the background), not as a blocking tool call that will time out. Check their
  output files rather than waiting.
- **Cost:** every bench run, and every evolve experiment, is real agent usage on the owner's Claude plan. Before
  Phase 3 and before Phase 4, say roughly how long the run will take and get a go-ahead.
- **Code changes:** keep fixes small. After any code change, run `ruff check .` and `pytest -q`; both must pass. Commit
  with a conventional message (`fix(roblox): ...`) on the working branch. Never commit `.env`, `memory/`,
  `regressions/`, `bench/results/` or `bench/evolve/`.
- **Results:** report only numbers you saw in output files. Don't summarize a run you didn't read.

## Phase 1: Setup

1. **[OWNER]** Install Python 3.12+, [uv](https://docs.astral.sh/uv/), Git, [Rojo](https://rojo.space) and Roblox
   Studio, signed in. Claude Code must be installed and signed in: `claude` should start without asking for a login.
   Check that each tool is on PATH (`python --version`, `uv --version`, `git --version`, `rojo --version`,
   `claude --version`) and say which are missing.
2. Get onto the working branch: `git fetch origin`, then `git checkout roblox-engine` if the evolve PR has been merged
   into it, else `git checkout evolve`. Then `git pull`.
3. Install:
   ```bash
   uv venv
   ```
   Activate the venv (see Ground rules), then:
   ```bash
   uv pip install -e ".[dev]"
   ```
   ```bash
   pytest -q
   ```
   Every test must pass. If one fails, stop and report it: it's an install problem, not something to fix in the code.
4. Create `.env` in the repository root if it isn't there, with:
   ```
   TYPESAFE_API_KEY=
   AUTOPILOT_AGENT=claude
   AUTOPILOT_SHARE=0
   AUTOPILOT_REGRESSIONS=<absolute path to this repo>/regressions
   ```
   Fill in the regressions path yourself. **[OWNER]** pastes in their TypeSafe key: ask them to, and don't ask to
   see it. Then check that it was set without printing it:
   ```bash
   python -c "from dotenv import dotenv_values as d; print(bool(d('.env').get('TYPESAFE_API_KEY')))"
   ```
5. Make sure `.gitignore` lists `.env`, `memory/`, `regressions/`, `bench/results/` and `bench/evolve/`.

**[CHECKPOINT]** Phase 1 done: the tools, the tests, and `.env` with everything but the key's value confirmed.

## Phase 2: Get Roblox working

This is the part most likely to break. Autopilot's Roblox support has only ever been tested against a simulated
Studio. Some of its argument names are guesses, marked `TODO(verify)` in `autopilot/engines/roblox_mcp.py` and listed
under "Open questions" in `docs/roblox.md`.

6. Build the test place:
   ```bash
   rojo build examples/roblox_testplace -o TestPlace.rbxlx
   ```
7. **[OWNER]** Opens `TestPlace.rbxlx` in Studio and turns on the MCP server: **Assistant → … → Manage MCP Servers →
   Enable Studio as MCP server**. Wait for them to confirm.
8. Read what the server offers:
   ```bash
   python tools/roblox_latency.py --tools > studio_tools.txt
   ```
   Compare each tool's `inputSchema` with what `autopilot/engines/roblox_mcp.py` sends. Look at:
   - the argument names for `execute_luau`, `start_stop_play`, `script_read` and `character_navigation`;
   - the action JSON for `user_keyboard_input` and `user_mouse_input`;
   - how `execute_luau` returns a result (its return value or printed output);
   - the formats of `get_studio_state` and `get_console_output`.

   For each mismatch, fix the code. Where possible the client already reads argument names from the advertised
   schema, so check that before changing a guess. Update `FakeStudio` and `tests/robloxsim.py` the same way so the
   tests match the real server. Resolve the matching `TODO(verify)` comments, and the "Open questions" entries in
   `docs/roblox.md`, with what you found. Run ruff and pytest, then commit.
   If `studio_tools.txt` turns out to be useful as a record, add it to `docs/` without anything private in it.
9. Measure latency:
   ```bash
   python tools/roblox_latency.py
   ```
   Note the p50, p95 and the recommended `tick_hz` and `tempo`. If the recommendation differs from what the Roblox
   section of the kit tells the agent (`autopilot/engines/roblox.md`), update that section.
10. Run one prompt end to end, with two processes. First the brain:
    ```bash
    python -m autopilot play "Verify that pulling the lever opens the door" --project examples/roblox_testplace
    ```
    Then, once it says it's waiting for the plugin, the connector:
    ```bash
    python -m autopilot.engines.roblox connect --project examples/roblox_testplace --log connector.log
    ```
    The run ends with an outcome: CONFIRMED is expected. Its files are in `memory/Autopilot Test Place/runs/<id>/`
    (`report.json`, `trace<n>.jsonl`, `trace<n>_summary.txt`). If it fails or errors:
    - Read the brain's output, `connector.log` and the run folder.
    - Find the cause in `autopilot/engines/roblox.py`, `roblox_mcp.py` or `roblox.luau`.
    - Fix it, add a test with the simulated place if you can, run ruff and pytest, commit, and run the prompt again.

    If the run ends INCONCLUSIVE because the agent couldn't play well, rather than because something broke, that's
    acceptable for now: note it and move on.
11. Check that the run was saved as a regression, then replay it:
    ```bash
    python -m autopilot regress --project examples/roblox_testplace --regressions "<AUTOPILOT_REGRESSIONS>/Autopilot Test Place"
    ```
    It should replay as `ok`. A run whose only confirming episode continued from an earlier one isn't saved (see
    `docs/evolve.md`): that's expected, not a bug.

**[CHECKPOINT]** Report what you changed to get Roblox working (the commits), the latency figures, the first prompt's
outcome, and whether the regression replayed.

12. **[OWNER]** Records a screen capture of Studio during a run (step 10 again) for the demo.

## Phase 3: Baseline

13. Review `bench/suites/roblox_testplace.json` against `examples/roblox_testplace/src/` (mainly
    `src/server/Game.server.luau`). Each expected answer should be what the place's code actually does. Propose
    corrections, and 4–6 new prompts so the suite has 10 or more. About a third should be claims that come out DENIED,
    so a change can't score by always saying yes. **[OWNER]** approves the suite. After this the suite doesn't
    change: evolve locks it.
14. **[CHECKPOINT: cost]** Tell the owner the bench takes roughly up to 15 minutes per prompt, one prompt at a time,
    and get their go-ahead. Then run it:
    ```bash
    python bench/run_autopilot.py --project examples/roblox_testplace --suite bench/suites/roblox_testplace.json --agent claude --minutes 15
    ```
15. Read `bench/results/<time>/summary.json` and each miss's run folder. For every miss, decide which kind it is:
    - **(a)** the suite's expected answer is wrong;
    - **(b)** the Roblox engine broke (fix it as in step 10);
    - **(c)** the agent played badly. These are what evolve is for.

    Report the score and the list.
16. Replay the regressions (step 11's command) and report how many pass.

## Phase 4: Evolve

17. Write `my_experiments.json` (in the repo root; don't commit it unless the owner wants to) with 3–5 experiments
    aimed at the (c) misses. Each one changes a single target: `prompt:<paragraph>`, `kit:<section>`,
    `const:<module.NAME>` or `lib:<function>`. Use `python -m autopilot evolve --show "<target>"` to read a target
    first. Keep each change small and give it a `note` saying why. Format:
    ```json
    {"experiments": [{"target": "kit:Reacting in time", "text": "## Reacting in time\n...", "note": "why"}]}
    ```
    Don't use `--propose`: it needs an API key, which this setup doesn't have.
18. **[CHECKPOINT: cost]** Evolve runs the whole suite once for the baseline and once per experiment. Tell the owner
    the expected length (several hours), suggest running it overnight, and get their go-ahead. Then run:
    ```bash
    python -m autopilot evolve --project examples/roblox_testplace --suite bench/suites/roblox_testplace.json --candidates my_experiments.json --agent claude --minutes 15 --regressions "<AUTOPILOT_REGRESSIONS>/Autopilot Test Place"
    ```
    If it stops partway (a usage limit, a crash), run the same command again. It puts back any half-done experiment
    first, and the log keeps everything so far.
19. Read `bench/evolve/experiments.md` and `experiments.jsonl`. Report each experiment's decision and reason. Show the
    owner `git diff` for the kept changes. **[OWNER]** decides which to commit. Commit those with a message naming the
    experiment numbers. If nothing was kept, say so plainly: that's a valid result with a small suite.
20. If the owner wants another round, write new experiments that build on the log (don't repeat what was reverted) and
    repeat steps 18–19.

## Phase 5: The owner's own obby (optional)

21. **[OWNER]** Provides a copy of their obby: a Rojo folder, or a `.rbxl`/`.rbxlx` file. Never work on their only
    copy. Suggest tagging checkpoints `Checkpoint` and hazards `Hazard` with CollectionService.
22. Read its scripts and write `bench/suites/<obby>.json`: 10 or more prompts whose expected answers come from its
    code, about a third DENIED. **[OWNER]** approves it.
23. Repeat Phases 3 and 4 with `--project <the copy>` and `--suite bench/suites/<obby>.json`. Use a separate evolve log:
    `--out bench/evolve-<obby>`.

## Phase 6: Open-source it and the post

24. Check the repo is safe to publish:
    - `git status` and `git ls-files` show no `.env`, `memory/`, `regressions/`, `bench/results/`, `bench/evolve/`,
      `connector.log` or `.rbxlx` the owner doesn't want public.
    - Search what's tracked for keys: `git grep -nE "sk-ant|TYPESAFE_API_KEY=.+"`. Expect nothing beyond
      `.env.example`'s empty line.
    - Ask the owner whether their obby (if any) has assets they don't have the rights to publish.
25. Credit the original project. Autopilot is Aura Autopilot by Ramen, under Apache 2.0:
    - keep `LICENSE`;
    - at the top of the README, add that this is a fork of [Aura Autopilot](https://www.tryaura.dev) by Ramen, and
      what this fork adds (Roblox support through Studio's MCP server; `autopilot evolve` and `autopilot regress`);
    - ask the owner what to name the fork, and don't present Aura's name or logo as theirs;
    - if the owner has a relationship with Ramen, remind them to check with Ramen before publishing.
26. Write a "Results" section in the README using only real numbers: the latency (step 9), the baseline score
    (step 15), the evolve table (step 19), the regression replays (step 16), and the owner's recording (step 12) as a
    GIF or link. Say what hasn't been tested.
27. Draft a LinkedIn post (about 150–250 words) for the owner. Cover what they built on top of Aura Autopilot, how
    evolve works (one change at a time, kept only if a locked suite improves), the real before/after numbers, and the
    repo link. Credit Aura/Ramen, and don't overclaim.
28. **[OWNER]** Makes the repository public and posts.

## When something goes wrong

| Symptom | Where to look |
| --- | --- |
| A tool is missing, or the server won't start | `AUTOPILOT_ROBLOX_MCP_CMD` and the `--tools` output; `docs/roblox.md` (Environment variables) |
| The connector can't reach the brain | Did the brain start first? The `--url` and `--retry` options of `python -m autopilot.engines.roblox connect` |
| Reads fail or come back empty | how `execute_luau` returns results (`AUTOPILOT_ROBLOX_RESULT=print`), the Client/Server data models; `roblox_mcp.py` |
| Inputs do nothing | the action JSON for `user_keyboard_input` / `user_mouse_input` against `studio_tools.txt` |
| The run reports an agent error or a login problem | `claude` login on this machine; `AUTOPILOT_AGENT=claude` in `.env`; that no `ANTHROPIC_API_KEY` is set |
| Evolve refuses to start ("the suite changed") | the suite was edited after it was locked. Use a new `--out`, or `--relock` if the change was deliberate |
| A replay fails after a lib.py change | that's evolve's regression gate working. Read `why` in the output |

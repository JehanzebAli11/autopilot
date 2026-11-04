# The QA agent: a design and roadmap

Autopilot already plays a game to answer questions about it. This document plans the next step: turning it into our
own QA agent. That means a tester that runs a test plan, finds bugs and cheats, measures balance, keeps everything it
proved as regressions, and hands bugs to a fixer that repairs the game and proves the fix.

It is written for whoever builds it, human or coding agent. Each part says what exists today (with the files), what to
build, and how to know it works. Everything must be testable without Roblox Studio, an engine or a model, against
`tests/robloxsim.py`'s simulated place and fakes, as `tests/test_roblox.py`, `tests/test_evolve.py` and
`tests/test_regress.py` are. Live runs in Studio are how a feature gets verified; the tests are how it stays correct.

Contents:

1. [What a QA agent does](#1-what-a-qa-agent-does)
2. [Strengthening the five capabilities](#2-strengthening-the-five-capabilities)
3. [Anti-cheat testing](#3-anti-cheat-testing)
4. [The fixer loop](#4-the-fixer-loop)
5. [`autopilot qa`: one command, one report](#5-autopilot-qa-one-command-one-report)
6. [Roadmap](#6-roadmap)
7. [Non-goals and rules](#7-non-goals-and-rules)

## 1. What a QA agent does

| A QA team's job | The QA agent's capability | Today |
| --- | --- | --- |
| "Does feature X work as designed?" | **Check claims** (`verify`: CONFIRMED / DENIED / INCONCLUSIVE) | Works |
| "Can a player finish this?" | **Reach goals** (`goal`: achieved / not_achieved) | Works |
| "Play it and find what's broken" | **Explore for bugs** (`explore`: findings) | Works; Roblox only reports console errors |
| "Did the new build break anything?" | **Catch regressions** (`autopilot regress`) | Only CONFIRMED claims are kept |
| "Is it too hard, too easy, too slow?" | **Balance checks** | Not built: only as one-off claims |
| "Can it be cheated?" | **Anti-cheat audit** | Not built |
| "File the bug, then check the fix" | **Fixer loop** | Not built |
| "Write up the test pass" | **QA report** | Not built: one report.json per run |

The run kinds live in `autopilot/aura.py` (`KINDS = ("verify", "explore", "goal")`) and are chosen in
`autopilot/cli.py` (`kind_by_words`). The agent's instructions for each kind are in the `SYSTEM` prompt in
`autopilot/agents/session.py`, and its report schema is that file's `report` tool (`outcome`, `summary`, `evidence`,
`findings`, `visual`).

## 2. Strengthening the five capabilities

### 2.1 Check claims

**Today:** one claim, one run, one verdict, from however many episodes the agent chose to play.

**Build:**

- **Trials.** A claim can say how many independent episodes must agree (`"trials": 3` in the plan). The verdict is
  CONFIRMED only if every trial showed it, DENIED if any trial contradicted it, and FLAKY if the trials disagree.
  Flaky means a timing or physics-dependent bug, which is a finding in its own right. The trials replay the confirming
  harness without the model (`regress.replay`), so they cost almost nothing.
- **Every instance.** "Every checkpoint saves progress" means each tagged instance (`CollectionService` tags are in
  the codex's `tags.txt`) gets its own check, and the evidence lists them all. Today the agent may test one and
  generalise.
- **Claim templates.** Common claim shapes with a known measurement, so the agent doesn't reinvent them:
  `touching <tag> changes <stat> by <n>`, `<prompt/lever> toggles <attribute>`, `<hazard> sends the player to
  <checkpoint>`, `<value> never exceeds <max>`. A template gives the harness skeleton and the evidence keys, and goes
  in the kit as helpers (`autopilot/kit/`) plus a KIT.md section.
- **Saving DENIED claims too.** A DENIED claim is a bug the team will fix. Keep it as a regression that expects
  DENIED now (see 2.4), and flip it to expect CONFIRMED once the fixer or a human fixes it.

**Done when:** a sim test where the place answers a claim randomly (true in one trial, false in another) gets FLAKY
from 3 trials; a claim about every `Checkpoint` lists each one in its evidence.

### 2.2 Reach goals

**Today:** achieved or not, with the evidence of the run that did it.

**Build:**

- **A completion record.** For an achieved goal: the time it took, the route (the player's positions every second,
  from the trace's observations), the deaths and retries, and the options that did the work. Kept with the report.
- **A replayable proof.** Achieved goals are saved as regressions too (today only CONFIRMED claims are, in
  `regress.save`). A level that later becomes impossible to finish then fails `autopilot regress`.
- **"Impossible" with numbers.** When a goal isn't reached, the report separates "the harness couldn't do it" from
  "the game's numbers say it can't be done" (a gap wider than `jump_height`/`walk_speed` allow, as `movement` reports
  them). Only the second is a level-design bug. The SYSTEM prompt already asks for this; the kit should compute it
  (a `reachable(from, to)` helper in `autopilot/kit/control.py` from the movement numbers).

**Done when:** an achieved goal on the sim place is saved and replays; a sim place with a gap too wide to jump
reports not_achieved with the numbers that prove it.

### 2.3 Explore for bugs

**Today:** the agent explores and lists findings in words. On Roblox the only automatic detector is the console
(`log_error`, `autopilot/engines/roblox.py`). The other engines' plugins also detect NaN positions, teleports, long
falls and hitches; `docs/roblox.md` lists their absence as a known limit.

**Build:**

- **Roblox detectors**, read in the same batched poll as the console (one `execute_luau` call), each a finding with a
  detector name, a severity and the game time:
  - `fell_out`: the character below `Workspace.FallenPartsDestroyHeight`, or its HumanoidRootPart is gone;
  - `teleport`: the root moved farther in one poll than `WalkSpeed` (or a known mover) allows;
  - `nan`: a NaN or inf position or velocity;
  - `stuck`: inputs held for N seconds with no movement (the runtime's response watch already notices part of this);
  - `out_of_bounds`: outside the place's bounding box (from the codex's tree);
  - `value_limit`: a leaderstat or attribute outside a range the plan declares.
- **Coverage.** Which tagged objects the player touched, used or came near, and which it never reached. An
  exploration reports its coverage, and the next one is told to go where the last didn't.
- **One finding, one repro.** Each finding comes with the episode, the game time, the harness and the decisions
  leading up to it, saved as a regression that expects the bug (`expect: finding <detector>`). A bug report is then
  something anyone can replay, not a paragraph.
- **Deduplication and severity.** The same error from the same script line is one finding with a count (the console
  already dedups by text). Severity: crash or script error > player stuck or lost progress > value out of range >
  cosmetic.

**Done when:** the sim place gains a broken platform the character falls through, and an exploration on it reports
`fell_out` with a replayable repro, plus the console error it already finds.

### 2.4 Catch regressions

**Today:** `autopilot/regress.py` saves CONFIRMED claims from a fresh-level episode and replays them with
`ReplayJev`. `autopilot regress` runs them; `autopilot evolve --regressions` reverts changes that break one.

**Build:**

- **More kinds of regression.** Each `regression.json` gets an `expect.kind`: `claim` (today's), `goal` (2.2), `bug`
  (2.3: the bug still happens, until fixed), `defended` (3: the exploit stays blocked), `balance` (2.5: a metric in
  its range).
- **Flaky detection.** `autopilot regress --trials 3`: a regression that passes sometimes is reported FLAKY, not
  failed, and isn't used to revert evolve changes.
- **Selecting by change.** Each regression records the scripts its harness touched (from the trace's reads and
  calls). `autopilot regress --changed <git range>` replays only those that touch changed scripts, plus a random
  sample of the rest.
- **Continued episodes.** Save the chain (episode 1, then 2 continuing from it) and replay it in order, so a
  confirmation that needed `restart=False` can still become a regression.

**Done when:** `regress --trials 3` reports a regression whose sim place randomly fails as FLAKY; a `bug` regression
flips from failing to passing once the sim place's bug is fixed.

### 2.5 Balance checks

**Today:** only as a one-off claim ("verify that stage 3 takes under 2 minutes").

**Build a new kind, `measure`:** play the same goal N times and report distributions, not a verdict.

- **Metrics:** time to complete, deaths per stage, retries per jump, coins per minute, the share of runs that finish.
  The plan declares which ones, and for each a range: `{"metric": "seconds_to_finish", "max": 120}`.
- **Personas.** The same goal played by a `novice` (a slower tempo, noisier picks: Jev's probabilities sampled
  rather than maxed, a reaction delay) and an `expert` (today's play). "Too hard" means the novice rarely finishes;
  "too easy" means the novice finishes as fast as the expert.
- **Cheap repeats.** The first episode needs the model to write the harness; the other N-1 replay it without the
  model, through `ReplayJev` or a sampling chooser, so 20 runs cost about as much as one.
- **The report:** a table per metric (median, p10, p90, finish rate), each against its range, with the episode that
  is closest to each percentile kept for replay.

**Done when:** a sim place whose "jump" succeeds with a set probability yields a finish rate within a few points of
that probability over 20 sampled runs, and a declared range fails when the probability is lowered.

## 3. Anti-cheat testing

**Goal:** prove that our own game's server doesn't trust the client where it shouldn't, and keep proving it.

### 3.1 The threat model (Roblox)

On Roblox the client runs on the cheater's machine, so anything the client controls can be forged:

| Attack | How a cheater does it | What the server must do |
| --- | --- | --- |
| Forged remote calls | `RemoteEvent:FireServer` / `RemoteFunction:InvokeServer` with any arguments | Check types, ranges, ownership and cost on the server |
| Wrong types | a string, NaN, inf, a huge number, a table or nil where a number or Instance is expected | Validate with `typeof` and ranges |
| Other players' objects | passing another player's Instance as an argument | Check that the Instance belongs to the caller |
| Spam | a remote fired hundreds of times a second | Rate-limit per player |
| Speed and teleport | the client owns its character's physics and can set its CFrame | Check movement on the server against WalkSpeed |
| Skipping progress | touching the final checkpoint without the earlier ones | Check order on the server |
| Free items | "buy" remotes the server doesn't charge for | Check the cost against the server's value |

### 3.2 What to build

- **A new run kind, `audit`**, with its own section of the SYSTEM prompt. In `verify` and `goal` runs the player
  acts only through input (the Rules in `agents/session.py`). In an audit the agent plays as a cheating client. Its
  attacks go through a dedicated, logged channel and are reported as attacks, never mixed up with honest play.
- **The attack channel**, `autopilot/kit/exploit.py`. Roblox's engine can already run Luau in the Client data model
  (`op_luau` in `autopilot/engines/roblox.py`, with `datamodel: "Client"`). Build on it, with typed helpers:
  - `fire_remote(game, path, *args, times=1, every=0)` and `invoke_remote(...)`, run in the Client data model;
  - `set_own_cframe(game, at)` and `set_own_velocity(game, v)`, which replicate because the client owns its
    character;
  - `touch(game, part)`, which moves the character onto a part (no `firetouchinterest` in Studio);
  - `bad_values()`, the standard junk list: `nil`, `-1`, `0`, `1e308`, `NaN`, `math.huge`, `""`, a long string,
    `{}`, another player's Instance.

  Every call is recorded as `{"attack": ..., "args": ...}` in the trace, and the report lists them.
- **Remote discovery.** From the codex: every `RemoteEvent` and `RemoteFunction` (the instance tree, `tree.txt`),
  and the server handler for each (`OnServerEvent` / `OnServerInvoke` in `*.server.luau`). This is the audit's
  attack surface; the background reader (`agents/researcher.py`) can summarise what each handler checks.
- **The attack plan.** For each remote: a call with honest arguments (the baseline), then type confusion, out-of-range
  values, someone else's Instance, and a burst. For the character: a teleport, a speed burst, and a skip to the last
  checkpoint. Each attack reads the server's state before and after (leaderstats, attributes, inventory) through
  `game.get` in the Server data model.
- **Verdicts:** `VULNERABLE` (the server's state changed in the cheater's favour, with before and after as evidence),
  `DEFENDED` (rejected, or reset by the server), `ERROR` (the server script errored: a finding in its own right,
  since an error in a handler can be a denial of service). Each with a severity.
- **Regressions.** Every DEFENDED attack is saved as a `defended` regression, so a later change that reopens the hole
  fails `autopilot regress`. Every VULNERABLE one is saved as a `bug` regression for the fixer (part 4).

### 3.3 Tests

Extend `tests/robloxsim.py` with remotes: a `BuyItem` that checks the cost (defended), a `GiveCoins` that trusts the
client's amount (vulnerable), and a server that resets a teleporting character (defended against teleports). The
audit must report exactly those verdicts, with before and after evidence, and save the matching regressions. Also add
the same vulnerable and defended remotes to `examples/roblox_testplace` (behind a `Config.AuditDemo` flag), so a live
audit has something to find.

## 4. The fixer loop

**Goal:** a bug found by the QA agent comes back fixed, with proof, as a branch to review.

```
qa run → findings (bugs, VULNERABLE attacks, failed regressions, out-of-range balance)
      → triage: dedupe, drop FLAKY and test problems, rank by severity
      → for each bug, in order:
            fixer agent: reads the bug's repro (its regression), the codex and the game's source; edits the source
            rebuild and reload the place
            replay the repro: it must now pass (the bug gone, the attack DEFENDED)
            replay every other regression: none may newly fail
            pass → commit on a branch, with a fix report; fail → revert, try again (up to N), else hand to a human
      → one PR (or one per fix) with the fix reports
```

### 4.1 Pieces

- **The fixer.** A Claude Code session, run the way `autopilot/agents/claude_code.py` runs the implementer (the
  Claude Agent SDK, on the owner's Claude Code login with `AUTOPILOT_AGENT=claude`), with its own prompt. It's given
  the bug (report, evidence, repro regression, trace summary) and may edit **only the game's source**: the Rojo
  project's `src/`. Same tool restrictions pattern as `autopilot/agents/files.py`.
- **Rebuild and reload.** For a Rojo project: `rojo build` and reopening the place, or, better, `rojo serve` with the
  Rojo Studio plugin, so edits sync live. Then `start_stop_play` restarts the session on the new code. The reload step
  is engine-specific; for Godot, Unity and Unreal, the bench's headless relaunch already does it.
- **Proof.** A fix counts only when the bug's own repro now passes and no other regression newly fails: the same gate
  `autopilot evolve` uses (`evolve.decide` with regressions). The repro then flips into a regression that expects the
  fixed behaviour.
- **The fix report** per bug: the bug (with its evidence), the cause in one paragraph, the diff, the repro before
  (failing) and after (passing), and the regressions run.

### 4.2 Guardrails

- The fixer can't edit the test plan, the regressions, the bench or Autopilot itself (`evolve.locked`'s rules,
  reused).
- A fix that removes the feature (deletes the lever so it can't misbehave) isn't a fix. The plan's claims and goals
  run after every fix, so removing the feature fails them.
- A diff-size limit per fix (e.g. 80 lines) and a per-bug attempt limit. Anything bigger goes to a human.
- Everything lands on a branch as a PR. Nothing is merged without a human.
- Changing what "correct" means (an expected answer in the plan) is never the fixer's call. It can flag that the
  plan looks wrong.

### 4.3 Tests

A sim "place source": a small Python module the sim place reads its rules from (e.g. `coin_value = 2` where the plan
says 1), and a fake fixer that edits it. The loop must find the bug, apply the fake fix, see the repro pass and the
regressions hold, and commit. A fake fix that breaks another regression must be reverted and handed off.

## 5. `autopilot qa`: one command, one report

### 5.1 The test plan

The bench suite format (`bench/suites/*.json`) grows into a plan, and stays backward compatible: a plain suite is a
plan of claims and goals.

```json
{
 "game": "examples/roblox_testplace",
 "claims": [
  {"id": "lever", "prompt": "Verify that pulling the lever opens the door", "expected": "CONFIRMED", "trials": 3},
  {"id": "coin2", "prompt": "Verify that picking up the coin adds 2 coins", "expected": "DENIED"}
 ],
 "goals": [{"id": "obby", "prompt": "Reach the final checkpoint", "expected": "achieved"}],
 "explore": [{"id": "obby-bugs", "prompt": "Explore the obby for bugs", "minutes": 10}],
 "balance": [{"id": "obby-time", "goal": "obby", "runs": 20, "personas": ["novice", "expert"],
              "metrics": {"seconds_to_finish": {"max": 120}, "finish_rate": {"min": 0.6}}}],
 "audit": {"remotes": "all", "movement": true},
 "limits": {"leaderstats.Coins": [0, 1000000]}
}
```

### 5.2 The command

```bash
python -m autopilot qa --plan qa/obby.json [--only claims,audit] [--fix] [--out qa/reports]
```

It runs, in order: regressions (fast, no model), claims, goals, explorations, balance, audit. With `--fix`, the
fixer loop follows. Parallel where the engine allows it (Roblox: one Studio, so one at a time).

### 5.3 The report

`qa/reports/<time>/report.md` (and `.json` and `.html`):

- **Verdict:** ready / not ready, from the plan's pass bar.
- **Summary:** claims X/Y, goals X/Y, regressions X/Y (and flaky), bugs by severity, attacks vulnerable/defended,
  balance metrics in range X/Y.
- **Bugs:** one card each: severity, detector, what happened, evidence, a still at the moment (from
  `capture`/`screen_capture`), the repro command (`autopilot regress --regressions <its folder>`).
- **Security:** each remote with its attacks and verdicts.
- **Balance:** the metric tables against their ranges.
- **Changes since the last report:** new bugs, fixed bugs, new regressions, metrics that moved.

## 6. Roadmap

Each milestone is small enough to ship on its own, with sim tests, before the next one starts.

| # | Milestone | Builds on | Proof (sim tests; then one live Studio run) |
| --- | --- | --- | --- |
| 1 | Regression kinds (`claim`, `goal`, `bug`) and `--trials` with FLAKY | `regress.py` | 2.2, 2.4's "done when" |
| 2 | Roblox detectors (`fell_out`, `teleport`, `nan`, `stuck`, `value_limit`) and repros for findings | `engines/roblox.py`, `roblox.luau` | 2.3's "done when" |
| 3 | Claim trials and every-instance claims; claim templates in the kit | 1 | 2.1's "done when" |
| 4 | The `audit` kind, `kit/exploit.py`, remote discovery, `defended` regressions | 1 | 3.3 |
| 5 | The plan format and `autopilot qa` with the markdown report | 1-4 | a whole plan on the sim place, one report |
| 6 | The `measure` kind, personas and balance tables | 1, 5 | 2.5's "done when" |
| 7 | The fixer loop (`--fix`) | 1, 4, 5 | 4.3 |
| 8 | Nightly runs and report history | 5 | trends across two reports |

Order rationale: regressions first, because every later part saves into them. Detectors before audit, because both
need the batched Luau polls. The fixer last, because it needs repros, regressions and the report to work at all.

For every milestone:

- Add sim support first (`tests/robloxsim.py`) for what the feature needs, then the feature, then the tests.
- `ruff check .` and `pytest -q` pass.
- `docs/` says what it does and what's untested live.
- One live run in Studio on `examples/roblox_testplace`, with the result written down, before the milestone counts
  as done.

## 7. Non-goals and rules

- **Only our own games.** The audit attacks a place open in the owner's own Studio, through Studio's MCP server. It is
  not, and must not become, a tool for cheating in anyone else's game. No injector, no attaching to live servers, no
  bypassing Roblox's protections.
- **Not live anti-cheat.** It tests the server's defenses before release. It doesn't watch real players.
- **Not a replacement for people.** The QA agent says what works, what's broken, what can be cheated and what the
  numbers are. Whether the game is fun, whether a jump feels good, and what the game should be are the team's calls.
  Plan a short human playtest before each release.
- **Evidence or it didn't happen.** Every verdict, finding and metric rests on what was observed in play, with the
  trace to show it, as the SYSTEM prompt already requires.
- **Costs are visible.** Every command prints, before it starts, roughly how many model-driven runs it will make. The
  first run of each item uses the model; repeats and regressions replay without it.

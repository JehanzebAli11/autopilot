"""autopilot evolve (autopilot/evolve.py): targets, the keep-or-revert decision, the locked suite, the experiments log,
and the whole loop on tests/robloxsim.py's simulated place (lib: and const: targets) and on a fake agent (prompt: and
kit: targets), with regression replays gating it. No Studio, no language model, no API calls."""

import json
import os

import pytest
import simharness as sim

from autopilot import cli, evolve, regress
from autopilot.evolve import Evolve, Experiment, TargetError, parse_target

PROMPTS = '''"""A module holding a system prompt."""

SYSTEM = """You write the harness for a game made in {engine}.

Research first: read the codex, then probe.
  Keep each probe short.

Rules:
- Jev decides; code computes facts.
- Report with {min_decisions} decisions at least."""

OTHER = 1
'''

KIT = """# The kit

## Game (`game`)
Reads and writes.

```python
# not a heading: a comment in a code block
game.batch([...])
```

### Batching
One frame per batch.

## Controllers
walk_to, look_at.

## Geometry
Vec.
"""

LIB = '''import math


@staticmethod
def arrived(distance):
    return distance < 10


def other():
    return 1
'''


@pytest.fixture
def files(tmp_path):
    (tmp_path / "prompts.py").write_text(PROMPTS)
    (tmp_path / "KIT.md").write_text(KIT)
    (tmp_path / "lib.py").write_text(LIB)
    (tmp_path / "consts.py").write_text("A = 1\nSPEED: float = 2.5  # the speed\nNAME = 'x'\n")
    return tmp_path


# -- targets ---------------------------------------------------------------------------------------------------------

def test_prompt_paragraphs(files):
    t = parse_target(f"prompt:2@{files / 'prompts.py'}")
    assert t.current() == "Research first: read the codex, then probe.\n  Keep each probe short."
    assert parse_target(f"prompt:rules@{files / 'prompts.py'}").current().startswith("Rules:\n- Jev decides")
    assert parse_target(f"prompt:1@{files / 'prompts.py'}").current() == (
        "You write the harness for a game made in {engine}.")
    new = t.render("Research first: read the codex.")
    assert "Research first: read the codex.\n\nRules:" in new and "OTHER = 1" in new
    ns = {}
    exec(compile(new, "p", "exec"), ns)
    assert ns["SYSTEM"].format(engine="Roblox", min_decisions=3).count("\n\n") == 2
    with pytest.raises(TargetError, match="format fields"):
        t.render("Research {first}.")
    with pytest.raises(TargetError, match="format fields"):
        parse_target(f"prompt:rules@{files / 'prompts.py'}").render("Rules: none.")  # ({min_decisions} gone)
    with pytest.raises(TargetError, match='can\'t hold """'):
        t.render('Research """ first')
    with pytest.raises(TargetError, match="there are 3"):
        parse_target(f"prompt:9@{files / 'prompts.py'}")
    with pytest.raises(TargetError, match="no paragraph"):
        parse_target(f"prompt:Nothing like it@{files / 'prompts.py'}")
    with pytest.raises(TargetError, match="no string NOPE"):
        parse_target(f"prompt:1@{files / 'prompts.py'}#NOPE")
    with pytest.raises(TargetError, match="isn't one triple-quoted"):
        parse_target(f"prompt:1@{files / 'consts.py'}#NAME")


def test_kit_sections(files):
    t = parse_target(f"kit:Game@{files / 'KIT.md'}")
    cur = t.current()
    assert cur.startswith("## Game (`game`)") and "### Batching" in cur and "## Controllers" not in cur
    assert "# not a heading" in cur  # (a code block's comment isn't a heading)
    assert parse_target(f"kit:batching@{files / 'KIT.md'}").current() == "### Batching\nOne frame per batch.\n\n"
    new = parse_target(f"kit:Controllers@{files / 'KIT.md'}").render("## Controllers\nwalk_to only.")
    assert "## Controllers\nwalk_to only.\n\n## Geometry" in new
    with pytest.raises(TargetError, match="start with its heading"):
        t.render("Reads.")
    with pytest.raises(TargetError, match="start with its heading"):
        t.render("### Game\nReads.")
    with pytest.raises(TargetError, match="another heading"):
        t.render("## Game\nReads.\n## Sneaky\nmore")
    with pytest.raises(TargetError, match="2 headings start"):
        (files / "KIT2.md").write_text("## Go left\n\n## Go right\n")
        parse_target(f"kit:Go@{files / 'KIT2.md'}")


def test_constants_and_lib_functions(files):
    t = parse_target(f"const:SPEED@{files / 'consts.py'}")
    assert t.current() == "2.5"
    assert "SPEED: float = 3.0  # the speed" in t.render("3.0")
    with pytest.raises(TargetError, match="must be a Python literal"):
        t.render("__import__('os').system('x')")
    with pytest.raises(TargetError, match="no module-level"):
        parse_target(f"const:MISSING@{files / 'consts.py'}")
    lib = parse_target("lib:arrived", lib=str(files / "lib.py"))
    assert lib.current().startswith("@staticmethod\ndef arrived(") and "other" not in lib.current()
    new = lib.render("def arrived(distance):\n    return distance < 60")
    assert "def arrived(distance):\n    return distance < 60\n\n\ndef other" in new
    with pytest.raises(TargetError, match="named arrived"):
        lib.render("def elsewhere(d):\n    return True")
    with pytest.raises(TargetError, match="one top-level function"):
        lib.render("def arrived(d):\n    return 1\nX = 2")
    with pytest.raises(TargetError, match="doesn't parse"):
        lib.render("def arrived(d) return 1")
    with pytest.raises(TargetError, match="which lib.py"):
        parse_target("lib:arrived")


def test_targets_in_the_package_resolve_without_changing_it():
    before = {p: open(p, encoding="utf-8").read() for p in (evolve.SESSION_FILE, evolve.KIT_FILE)}
    rules = parse_target("prompt:Rules")
    assert rules.path == evolve.SESSION_FILE and rules.current().startswith("Rules:")
    new = rules.render(rules.current().replace("Jev decides.", "Jev decides, always."))
    assert "- Jev decides, always. Code computes" in new and len(new) == len(before[evolve.SESSION_FILE]) + 8
    assert parse_target("kit:Geometry").current().startswith("## Geometry")
    assert parse_target("const:kit.control.SONAR_EVERY").path.endswith(os.path.join("kit", "control.py"))
    assert parse_target("const:autopilot.runtime.MIN_ASK_GAP").current() == "0.08"
    for bad in ("nothing", "magic:x", "kit:", "const:NOPE"):
        with pytest.raises(TargetError):
            parse_target(bad)
    assert {p: open(p, encoding="utf-8").read() for p in before} == before


def test_the_measure_is_locked(tmp_path):
    assert "bench/" in evolve.locked(os.path.join(evolve.REPO, "bench", "run_autopilot.py"))
    assert "tests/" in evolve.locked(os.path.join(evolve.REPO, "tests", "robloxsim.py"))
    assert "regression" in evolve.locked(str(tmp_path / "memory" / "P" / "regressions" / "r1" / "harness.py"))
    suite = tmp_path / "suite.json"
    suite.write_text("{}")
    assert "locked" in evolve.locked(str(suite), also=(str(suite),))
    assert "locked" in evolve.locked(str(tmp_path / "log" / "x.md"), also=(str(tmp_path / "log"),))
    assert evolve.locked(evolve.KIT_FILE) is None and evolve.locked(str(tmp_path / "lib.py")) is None


# -- metrics and the decision ----------------------------------------------------------------------------------------

def m(rate, seconds=100, tokens=1000, failed=()):
    return {"rate": rate, "passed": rate * 4, "total": 4, "seconds": seconds, "tokens": tokens,
            "regressions": {"passed": 2 - len(failed), "total": 2, "failed": list(failed)}}


def test_decide():
    assert evolve.decide(m(0.5), m(0.75))[0] == "keep"
    assert evolve.decide(m(0.5), m(0.75, seconds=500, tokens=9000))[0] == "keep"  # (the pass rate comes first)
    assert evolve.decide(m(0.75), m(0.5, seconds=10))[0] == "revert"
    assert evolve.decide(m(0.5), m(0.5, seconds=90)) == ("keep", "time -10% at an equal pass rate (tokens +0%)")
    assert evolve.decide(m(0.5), m(0.5, tokens=800))[0] == "keep"
    assert evolve.decide(m(0.5), m(0.5, seconds=99))[0] == "revert"  # (under min_gain)
    assert evolve.decide(m(0.5), m(0.5, seconds=99), min_gain=0.005)[0] == "keep"
    assert evolve.decide(m(0.5), m(0.5, seconds=80, tokens=1500))[0] == "revert"  # (tokens rose as much)
    assert evolve.decide(m(0.5), m(0.5, seconds=100, tokens=1000))[1].startswith("no gain")
    assert evolve.decide(m(0.5), m(1.0, failed=["r1"])) == ("revert", "breaks regression(s) r1")
    assert evolve.decide(m(0.5, failed=["r1"]), m(0.75, failed=["r1"]))[0] == "keep"  # (it was failing already)


def test_metrics_average_repeats():
    run1 = [{"id": "A", "correct": True, "seconds": 10, "tokens": {"input": 100, "output": 20}},
            {"id": "B", "correct": False, "seconds": 20, "tokens": 50, "got": "DENIED", "expected": "CONFIRMED"},
            {"id": "C", "correct": None, "seconds": 5}]
    run2 = [{"id": "A", "correct": True, "seconds": 12, "tokens": 120},
            {"id": "B", "correct": True, "seconds": 18, "tokens": 50}, {"id": "C", "correct": None, "seconds": 5}]
    out = evolve.metrics([run1, run2], {"passed": 1, "total": 1, "failed": []})
    assert out["rate"] == 0.75 and out["passed"] == 1.5 and out["total"] == 2
    assert out["seconds"] == 35 and out["tokens"] == 170
    assert out["items"]["B"] == {"passed": 1, "runs": 2, "got": ["DENIED", None], "expected": "CONFIRMED"}
    assert out["regressions"] == {"passed": 1, "total": 1, "failed": []}
    assert evolve.tokens_of(None) == 0 and evolve.tokens_of(True) == 0


# -- the loop on a fake agent: prompt and kit targets -----------------------------------------------------------

class FakeAgent:
    """A suite of two prompts whose agent reads the prompt and the kit: A passes once the kit's Game section says to
    batch reads; B always passes. Tokens: the prompt's and the kit's characters; seconds: fixed."""

    def __init__(self, files):
        self.files = files
        self.runs = 0

    def __call__(self, out):
        self.runs += 1
        kit = (self.files / "KIT.md").read_text()
        prompt = (self.files / "prompts.py").read_text()
        a = "batch your reads" in kit
        return [{"id": "A", "prompt": "Reach the door", "expected": "achieved", "got": "achieved" if a else
                 "not_achieved", "correct": a, "seconds": 30, "tokens": len(kit) + len(prompt),
                 "summary": "too slow to read"},
                {"id": "B", "prompt": "Collect the coin", "expected": "achieved", "got": "achieved", "correct": True,
                 "seconds": 30, "tokens": len(kit) + len(prompt)}]


def suite_file(tmp_path, suite=None):
    path = tmp_path / "suite.json"
    path.write_text(json.dumps(suite or {"prompts": [{"id": "A", "prompt": "Reach the door", "expected": "achieved"},
                                                     {"id": "B", "prompt": "Collect the coin",
                                                      "expected": "achieved"}]}))
    return str(path)


def test_the_loop_keeps_what_helps_and_reverts_the_rest(files, tmp_path):
    out = str(tmp_path / "log")
    kit = lambda s: parse_target(f"kit:{s}@{files / 'KIT.md'}")
    prompt = lambda s: parse_target(f"prompt:{s}@{files / 'prompts.py'}")
    said = []
    loop = Evolve(suite_file(tmp_path), out, FakeAgent(files), say=said.append)
    game_section = kit("Game").current()
    records = loop.run([
        Experiment(kit("Game"), game_section.replace("Reads and writes.", "Reads and writes: batch your reads."),
                   note="tell the agent to batch"),
        Experiment(prompt(2), "Research first.", note="shorter"),
        Experiment(prompt(2), "Research {first}.", note="a new field"),
        Experiment(kit("Geometry"), "## Geometry\nVec, and a great deal more text that changes nothing at all.\n",
                   note="longer"),
        Experiment(kit("Controllers"), kit("Controllers").current(), note="the same"),
    ])
    assert [r["decision"] for r in records] == ["keep", "keep", "invalid", "revert", "skipped"]
    assert records[0]["why"] == "pass rate 50% -> 100%"
    assert records[1]["why"].startswith("tokens -") and records[3]["why"].startswith("no gain")
    kit_now, prompt_now = (files / "KIT.md").read_text(), (files / "prompts.py").read_text()
    assert "batch your reads" in kit_now and "a great deal more" not in kit_now
    assert "Research first.\n\nRules:" in prompt_now and "{first}" not in prompt_now
    assert not os.path.exists(os.path.join(out, evolve.PENDING))

    # the log: a JSON line and a table row each, the baseline first; diffs beside them
    log = [json.loads(line) for line in open(os.path.join(out, "experiments.jsonl"), encoding="utf-8")]
    assert [r["n"] for r in log] == [1, 2, 3, 4, 5, 6] and log[0]["kind"] == "baseline"
    assert log[0]["metrics"]["rate"] == 0.5 and log[1]["metrics"]["rate"] == 1.0
    assert log[1]["baseline"]["rate"] == 0.5 and log[2]["baseline"]["rate"] == 1.0  # (a kept change is the baseline)
    assert "+Reads and writes: batch your reads." in log[1]["diff"] and log[1]["diff_file"] == "diffs/0002.diff"
    assert open(os.path.join(out, "diffs", "0005.diff"), encoding="utf-8").read() == log[4]["diff"]
    assert "metrics" not in log[3] and log[3]["why"].startswith("the prompt's format fields would change")
    md = open(os.path.join(out, "experiments.md"), encoding="utf-8").read()
    rows = [line for line in md.splitlines() if line.startswith("| ") and line[2].isdigit()]
    assert len(rows) == 6 and "**baseline**" in rows[0] and "**keep**" in rows[1] and "**revert**" in rows[4]
    assert "1/2 → 2/2" in rows[1] and "[diff](diffs/0002.diff)" in rows[1] and "**invalid**" in rows[3]
    assert any("keep: pass rate" in s for s in said)


def test_model_proposals(files, tmp_path):
    asked = []

    def ask(prompt, system=None):
        asked.append(prompt)
        assert "Propose one change" in system
        return ("NOTE: say to batch reads\n```markdown\n## Game (`game`)\nReads and writes: batch your reads.\n```\n")

    t = parse_target(f"kit:Game@{files / 'KIT.md'}")
    loop = Evolve(suite_file(tmp_path), str(tmp_path / "log"), FakeAgent(files), say=lambda s: None)
    proposer = evolve.ModelProposer(ask=ask)
    first = loop.run([Experiment(t, propose=proposer)])
    assert first[0]["decision"] == "keep" and first[0]["note"] == "say to batch reads"
    assert "Its misses:\n- A: 'Reach the door' expected achieved, got ['not_achieved']: too slow to read" in asked[0]
    assert "## Game (`game`)\nReads and writes." in asked[0]
    # the next proposal is shown what was tried on the piece
    loop.run([Experiment(t, propose=evolve.ModelProposer(ask=lambda p, system=None: asked.append(p) or "no block"))])
    assert "Tried on this piece before:\n- keep (pass rate 50% -> 100%): say to batch reads" in asked[1]
    assert loop.log.records()[-1]["decision"] == "error"
    assert evolve.parse_proposal("NOTE: x\n```\na\n```\n```py\nb\n```") == ("b\n", "x")


def test_the_suite_is_locked_and_a_killed_experiment_is_put_back(files, tmp_path):
    out = str(tmp_path / "log")
    suite = suite_file(tmp_path)
    Evolve(suite, out, FakeAgent(files), say=lambda s: None).start()
    with open(suite, "a", encoding="utf-8") as f:
        f.write("\n")
    with pytest.raises(evolve.SuiteChanged, match="changed since it was locked"):
        Evolve(suite, out, FakeAgent(files), say=lambda s: None).start()
    assert Evolve(suite, out, FakeAgent(files), relock=True, say=lambda s: None).start()["rate"] == 0.5

    # a change in the measure mid-experiment: locked targets are refused before anything runs
    reg = tmp_path / "memory" / "regressions"
    reg.mkdir(parents=True)
    (reg / "KIT.md").write_text(KIT)
    loop = Evolve(suite, out, FakeAgent(files), say=lambda s: None)
    r = loop.try_one(Experiment(parse_target(f"kit:Geometry@{reg / 'KIT.md'}"), "## Geometry\nno\n"))
    assert r["decision"] == "refused" and (reg / "KIT.md").read_text() == KIT

    # the loop killed in an experiment: the next one puts the file back first
    target = files / "KIT.md"
    original = target.read_text()
    target.write_text("half-written experiment")
    with open(os.path.join(out, evolve.PENDING), "w", encoding="utf-8") as f:
        json.dump({"path": str(target), "original": original, "n": 9}, f)
    said = []
    Evolve(suite, out, FakeAgent(files), say=said.append)
    assert target.read_text() == original and not os.path.exists(os.path.join(out, evolve.PENDING))
    assert "Put back" in said[0]


def test_an_interrupted_or_failed_measure_reverts(files, tmp_path):
    t = parse_target(f"kit:Game@{files / 'KIT.md'}")
    original = (files / "KIT.md").read_text()
    agent = FakeAgent(files)

    def interrupted(out):
        if agent.runs:
            raise KeyboardInterrupt
        return agent(out)

    loop = Evolve(suite_file(tmp_path), str(tmp_path / "log"), interrupted, say=lambda s: None)
    with pytest.raises(KeyboardInterrupt):
        loop.run([Experiment(t, "## Game (`game`)\nbatch your reads\n")])
    assert (files / "KIT.md").read_text() == original
    assert not os.path.exists(str(tmp_path / "log" / evolve.PENDING))

    def failing(out):
        if agent.runs > 1:
            raise RuntimeError("the bench crashed")
        return agent(out)

    loop = Evolve(suite_file(tmp_path), str(tmp_path / "log2"), failing, say=lambda s: None)
    r = loop.run([Experiment(t, "## Game (`game`)\nbatch your reads\n")])[0]
    assert r["decision"] == "error" and "the bench crashed" in r["why"] and (files / "KIT.md").read_text() == original


# -- the loop on the simulated Roblox place: lib and const targets, the suite in parallel -------------------------

def test_evolve_on_the_simulated_place(tmp_path):
    mem = str(tmp_path / "memory" / "TestPlace")
    sim.write_memory(mem)
    suite = suite_file(tmp_path, {"prompts": [{k: v for k, v in p.items() if k != "harness"}
                                              for p in sim.SUITE["prompts"]]})
    run = sim.SimSuite(mem, max_seconds=2.5)
    lib = parse_target(f"lib:arrived@{mem}/lib.py")
    settle = parse_target(f"const:SETTLE_TICKS@{mem}/tuning.py")
    loop = Evolve(suite, str(tmp_path / "log"), run, say=lambda s: None)
    records = loop.run([
        Experiment(lib, "def arrived(distance):\n    return distance < 60\n", note="arrive within 60 cm"),
        Experiment(lib, "def arrived(distance):\n    return distance < 20\n", note="arrive within 20 cm"),
        Experiment(settle, "2", note="settle for 2 ticks"),
    ])
    base = loop.log.records()[0]["metrics"]
    assert base["passed"] == 1 and base["total"] == 3  # (lib.arrived's 10 cm: the coin and the door are never reached)
    assert base["items"]["A"]["got"] == ["INCONCLUSIVE"] and base["items"]["C"]["passed"] == 1
    assert [r["decision"] for r in records] == ["keep", "revert", "keep"], [r["why"] for r in records]
    assert records[0]["metrics"]["passed"] == 3 and records[1]["metrics"]["passed"] == 1
    assert records[2]["why"].startswith("time -") and records[2]["metrics"]["passed"] == 3
    assert "return distance < 60" in open(f"{mem}/lib.py").read()
    assert open(f"{mem}/tuning.py").read() == "SETTLE_TICKS = 2  # ticks an option waits before it moves\n"
    # each suite run played its prompts at once
    for spans in run.spans:
        assert max(s[0] for s in spans) < min(s[1] for s in spans)


def test_regressions_gate_the_loop(tmp_path):
    """A lib.py change the suite likes (faster) that breaks a CONFIRMED claim's replay is reverted."""
    mem = str(tmp_path / "memory" / "TestPlace")
    sim.write_memory(mem, lib=sim.LIB.replace("< 10", "< 60"))
    run_dir = str(tmp_path / "runs" / "run-1")
    sim.play(run_dir, "coin", memory=mem)
    reg = regress.save(run_dir, {"outcome": "CONFIRMED", "run": "run-1", "prompt": "Verify the coin"}, "TestPlace",
                       project_root=mem)
    assert reg

    def suite_run(out):  # (a suite that only times lib.py: a shorter one is "faster")
        text = open(f"{mem}/lib.py").read()
        return [{"id": "A", "correct": True, "seconds": len(text), "tokens": 10}]

    def replays(out):
        game, backend, _ = sim.connect()
        try:
            sim.fresh_imports(mem)
            return regress.summary(regress.replay_all(game, [reg], project_root=mem, seconds=2, say=None))
        finally:
            backend.close()

    loop = Evolve(suite_file(tmp_path), str(tmp_path / "log"), suite_run, run_regressions=replays,
                  say=lambda s: None)
    lib = parse_target(f"lib:arrived@{mem}/lib.py")
    records = loop.run([
        Experiment(lib, "def arrived(distance):\n    return distance < 1\n", note="shorter, and wrong"),
        Experiment(lib, "def arrived(distance):\n    return distance<60\n", note="shorter, and right"),
    ])
    assert records[0]["decision"] == "revert" and records[0]["why"] == "breaks regression(s) run-1"
    assert records[1]["decision"] == "keep", records[1]["why"]
    assert loop.log.records()[0]["metrics"]["regressions"] == {"passed": 1, "total": 1, "failed": []}
    assert "distance<60" in open(f"{mem}/lib.py").read()


# -- the command -----------------------------------------------------------------------------------------------------

def test_the_command(files, tmp_path, monkeypatch, capsys):
    args = cli.parser().parse_args(["evolve", "--show", f"kit:Controllers@{files / 'KIT.md'}"])
    assert evolve.main(args) == 0 and "## Controllers\nwalk_to, look_at." in capsys.readouterr().out
    args = cli.parser().parse_args(["evolve", "--show", "kit:No such heading"])
    assert evolve.main(args) == 1

    candidates = tmp_path / "candidates.json"
    (tmp_path / "game.md").write_text("## Game (`game`)\nbatch your reads\n")
    candidates.write_text(json.dumps({"experiments": [
        {"target": f"kit:Game@{files / 'KIT.md'}", "file": "game.md", "note": "batch"},
        {"target": f"prompt:2@{files / 'prompts.py'}", "text": "Research.", "note": "shorter"}]}))
    made = []

    class Runner(FakeAgent):
        def __init__(self, project, suite, **kw):
            super().__init__(files)
            made.append((project, suite, kw))

    monkeypatch.setattr(evolve, "BenchRunner", Runner)
    out = tmp_path / "log"
    suite = suite_file(tmp_path)
    args = cli.parser().parse_args(["evolve", "--suite", suite, "--project", str(tmp_path / "Game"),
                                    "--candidates", str(candidates), "--out", str(out), "--parallel", "3",
                                    "--minutes", "5"])
    assert cli.main(["evolve", "--suite", suite, "--project", str(tmp_path / "Game"), "--candidates",
                     str(candidates), "--out", str(out), "--parallel", "3", "--minutes", "5"]) == 0
    assert made[0][2]["parallel"] == 3 and made[0][2]["minutes"] == 5 and made[0][2]["lib"] is None
    assert "2 experiment(s), 2 kept" in capsys.readouterr().out
    assert [r["decision"] for r in evolve.Log(str(out)).records()] == ["baseline", "keep", "keep"]
    assert evolve.main(cli.parser().parse_args(["evolve", "--suite", suite])) == 1  # (no experiments)
    args.candidates = str(tmp_path / "missing.json")
    assert evolve.main(args) == 1

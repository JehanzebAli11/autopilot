"""Regression replay (autopilot/regress.py) on tests/robloxsim.py's simulated place: a CONFIRMED verification's
harness is kept under regressions/ and plays again without a model; a change to lib.py that breaks it shows."""

import json
import os
import types

import pytest
import simharness as sim

from autopilot import cli, regress


@pytest.fixture
def memory(tmp_path):
    mem = str(tmp_path / "memory" / "TestPlace")
    sim.write_memory(mem, lib=sim.LIB.replace("< 10", "< 60"))
    return mem


def confirmed(tmp_path, memory, which="coin", rid="run-1"):
    run_dir = str(tmp_path / "runs" / rid)
    result = sim.play(run_dir, which, memory=memory)
    assert result["status"]["state"] == "done", result
    return run_dir, {"outcome": "CONFIRMED", "run": rid, "prompt": "Verify that walking to the coin brings the "
                     "player next to it", "summary": "it does", "evidence": ["28 cm from the coin"]}


def test_a_confirmed_claim_is_kept_and_replays_without_a_model(tmp_path, memory):
    run_dir, report = confirmed(tmp_path, memory)
    reg = regress.save(run_dir, report, "TestPlace", project_root=memory)
    assert reg == os.path.join(memory, "regressions", "run-1")
    assert sorted(os.listdir(reg)) == ["harness.py", "lib.py", "regression.json"]
    spec = regress.load(reg)
    assert spec["expect"]["state"] == "done" and spec["expect"]["evidence"]["near_coin"] is True
    assert spec["picks"] and set(spec["picks"]) <= {"go_to_coin", "look_around"} and spec["episode"] == 1
    assert regress.listing(os.path.join(memory, "regressions")) == [reg]

    game, backend, place = sim.connect()
    try:
        r = regress.replay(game, reg, project_root=memory)
    finally:
        backend.close()
    assert r["passed"], r
    assert r["why"] == "as recorded" and r["evidence"]["near_coin"] is True and r["decisions"] >= 1
    assert os.path.exists(os.path.join(reg, "replay.jsonl"))
    # (no language model, no Jev: the replay's decisions are the recording's)
    assert all(c[0] != "jev" for c in place.calls)


def test_a_lib_change_that_breaks_it_fails_the_replay(tmp_path, memory):
    run_dir, report = confirmed(tmp_path, memory)
    reg = regress.save(run_dir, report, "TestPlace", project_root=memory)
    sim.write_memory(memory)  # (lib.arrived back to `< 10`: the player never "arrives" 28 cm away)
    sim.fresh_imports(memory)
    game, backend, _ = sim.connect()
    try:
        r = regress.replay(game, reg, project_root=memory, seconds=2)
        assert not r["passed"] and r["why"].startswith("ended running"), r
        # the snapshot saved with it still passes: the change is in lib.py
        r = regress.replay(game, reg, project_root=memory, frozen_lib=True)
        assert r["passed"], r
    finally:
        backend.close()


def test_only_confirmed_claims_from_a_fresh_level_are_kept(tmp_path, memory):
    run_dir, report = confirmed(tmp_path, memory)
    assert regress.save(run_dir, dict(report, outcome="DENIED"), "TestPlace", project_root=memory) is None
    assert regress.save(run_dir, dict(report, outcome="achieved"), "TestPlace", project_root=memory) is None
    # an episode that went on from where play was can't be replayed from a restart
    with open(os.path.join(run_dir, "trace1.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"kind": "continued", "t": 0}) + "\n")
    assert regress.save(run_dir, report, "TestPlace", project_root=memory) is None
    # an episode that didn't end done isn't one either
    other = str(tmp_path / "runs" / "run-2")
    sim.write_memory(memory)
    sim.play(other, "coin", memory=memory, max_seconds=1.5)
    assert regress.save(other, dict(report, run="run-2"), "TestPlace", project_root=memory) is None


def test_the_session_keeps_its_confirmed_claim(tmp_path, memory, monkeypatch):
    run_dir, report = confirmed(tmp_path, memory)
    notes = []
    session = types.SimpleNamespace(run_dir=run_dir, project="TestPlace", root=memory, note=notes.append)
    kept = regress.save_from_session(session, report)
    assert kept and os.path.exists(os.path.join(kept, "regression.json"))
    # AUTOPILOT_REGRESSIONS moves them all
    monkeypatch.setenv("AUTOPILOT_REGRESSIONS", str(tmp_path / "regs"))
    kept = regress.save_from_session(session, report)
    assert kept == str(tmp_path / "regs" / "TestPlace" / "run-1")
    # (never raises)
    broken = types.SimpleNamespace(run_dir=str(tmp_path / "nowhere"), project="TestPlace", root=memory,
                                   note=notes.append)
    assert regress.save_from_session(broken, report) is None and "couldn't save the regression" in notes[-1]


def test_session_finish_saves_the_regression(tmp_path, memory, monkeypatch):
    from autopilot.agents import session as sessionmod

    run_dir, report = confirmed(tmp_path, memory)
    seen = []
    monkeypatch.setattr(regress, "save_from_session", lambda s, r: seen.append(r["outcome"]) or "kept")
    fake = types.SimpleNamespace(
        report=dict(report), run_dir=run_dir, run_id="run-1", project="TestPlace", prompt=report["prompt"],
        episodes=1, tool_seconds=0.0, game=types.SimpleNamespace(writes=[]), alerts=[], researcher=None,
        reader=None, findings=[], index_was_running=False, root=memory, out_of_time=lambda: False,
        indexer=lambda: None, note=lambda text: None)
    out = sessionmod.finish(fake, 0.0, None, "")
    assert out["outcome"] == "CONFIRMED" and seen == ["CONFIRMED"]
    fake.report = dict(report, outcome="DENIED")
    sessionmod.finish(fake, 0.0, None, "")
    assert seen == ["CONFIRMED"]


def test_evidence_comparison():
    assert regress.same({"a": True, "n": 10, "s": "x"}, {"a": True, "n": 11, "s": "x", "extra": 1}) is None
    assert "a:" in regress.same({"a": True}, {"a": False})
    assert "n:" in regress.same({"n": 1}, {"n": 2})
    assert regress.same({"n": 0}, {"n": 0.2}) is None  # (within the tolerance of 1)
    assert "missing" in regress.same({"k": 1}, {})
    assert regress.same({"l": [1, "a"]}, {"l": [1, "a"]}) is None and regress.same({"l": [1]}, {"l": [1, 2]})
    assert regress.same(3, True) is not None


def test_replay_jev_follows_the_recording():
    from typesafe_sdk import Choice, Noul

    jev = regress.ReplayJev(["b", "a", "a"], [{"danger": 0.9}, {}, {}])
    q = {"pick": Choice(instructions="x", criteria={"a": "A", "b": "B"}),
         "danger": Noul(instructions="in danger?", criteria={"true": "yes"})}
    r = jev.system_one({}, q)
    assert r.choices["pick"].choice == "b" and r.nouls["danger"].noul == 0.9
    assert jev.system_one({}, {"pick": Choice(instructions="x", criteria={"a": "A", "c": "C"})}).choices[
        "pick"].choice == "a"
    # past the recording: what it picked most
    jev.system_one({}, {"pick": Choice(instructions="x", criteria={"a": "A"})})
    r = jev.system_one({}, {"pick": Choice(instructions="x", criteria={"c": "C", "a": "A"})})
    assert r.choices["pick"].choice == "a"


def test_cli_regress_replays_the_project_regressions(tmp_path, memory, monkeypatch, capsys):
    run_dir, report = confirmed(tmp_path, memory)
    reg = regress.save(run_dir, report, "TestPlace", project_root=memory)
    monkeypatch.setattr(cli.codexmod, "project_dir", lambda project: memory)
    args = cli.parser().parse_args(["regress", "--json", str(tmp_path / "out.json")])
    assert args.cmd == "regress" and not args.no_launch
    game, backend, _ = sim.connect()
    try:
        assert cli.regress_on(game, "TestPlace", args) == 0
    finally:
        backend.close()
    out = json.loads((tmp_path / "out.json").read_text())
    assert out["passed"] == out["total"] == 1 and out["failed"] == []
    assert "1/1 passed" in capsys.readouterr().out
    # a broken one fails the command
    spec = regress.load(reg)
    spec["expect"]["evidence"]["near_coin"] = False
    with open(os.path.join(reg, regress.FILE), "w", encoding="utf-8") as f:
        json.dump(spec, f)
    game, backend, _ = sim.connect()
    try:
        assert cli.regress_on(game, "TestPlace", args) == 1
    finally:
        backend.close()
    assert json.loads((tmp_path / "out.json").read_text())["failed"] == ["run-1"]
    # none at all: nothing fails
    args = cli.parser().parse_args(["regress", "--regressions", str(tmp_path / "none")])
    assert cli.regress_on(None, "TestPlace", args) == 0


def test_a_relative_memory_folder_is_made_absolute(tmp_path):
    """A relative AUTOPILOT_MEMORY (the bench's, from a relative --out) names the folder from where Autopilot started:
    the sandboxed child that plays an episode runs inside the project's memory, where the same relative path would
    land the episode's trace in a second copy of the folder, and its regression would never be saved."""
    import subprocess
    import sys

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ, AUTOPILOT_MEMORY=os.path.join("bench", "memory"), PYTHONPATH=repo)
    out = subprocess.run([sys.executable, "-c", "from autopilot import codex; print(codex.MEMORY)"], cwd=tmp_path,
                         env=env, capture_output=True, text=True, check=True).stdout.strip()
    assert os.path.realpath(out) == os.path.join(os.path.realpath(tmp_path), "bench", "memory")

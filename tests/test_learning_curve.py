"""tools/learning_curve.py: a run's numbers come from the place's `[Gauntlet] {json}` log lines (no Studio here)."""

import importlib.util
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("learning_curve", os.path.join(HERE, "..", "tools", "learning_curve.py"))
lc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lc)


def line(**e):
    return lc.PREFIX + json.dumps(e)


CONSOLE = [
    "The MCP Studio plugin is ready for prompts.",
    line(event="session", session="old", t=0, wall=100),  # (a play session from before the run)
    line(event="death", session="old", stage=5, cause="Laser", wall=101),
    line(event="session", session="a", t=0, wall=1000),
    line(event="spawn", session="a", stage=0, wall=1001),
    line(event="checkpoint", session="a", stage=1, name="Stepping Stones", wall=1010),
    line(event="death", session="a", stage=1, cause="Laser", wall=1020),
    line(event="death", session="a", stage=1, cause="Laser", wall=1030),
    line(event="death", session="a", stage=1, cause="Laser", wall=1030),  # (read twice: counts once)
    "ContentId: rbxassetid://1 failed due to: Asset type does not match requested type",
    line(event="session", session="b", t=0, wall=1100),  # (a restart: a new session)
    line(event="checkpoint", session="b", stage=3, name="Drift", wall=1150),
    line(event="death", session="b", stage=3, cause="Void", wall=1160),
    line(event="finish", session="b", seconds=88.5, deaths=1, wall=1190),
    "[Gauntlet] not json",
]


def test_a_run_is_scored_from_its_own_log_lines():
    s = lc.score(lc.events(CONSOLE), since=1000, until=1200)
    assert s == {"sessions": 2, "deaths": 3, "causes": {"Laser": 2, "Void": 1}, "deaths_by_stage": {1: 2, 3: 1},
                 "best_stage": 3, "finished": True, "finish_seconds": 88.5, "assisted": False}
    # (without a window, the earlier session counts too)
    assert lc.score(lc.events(CONSOLE))["deaths"] == 4


def test_a_debug_helper_marks_the_run_assisted():
    evs = lc.events(CONSOLE + [line(event="debug", session="b", fn="SetStage", stage=7, wall=1195)])
    assert lc.score(evs, 1000, 1200)["assisted"] is True


def test_the_report_reads_each_runs_console(tmp_path):
    runs = tmp_path / "runs"
    for rid in ("R01", "R02"):
        (runs / rid).mkdir(parents=True)
    (runs / "R01" / "console.txt").write_text("\n".join(CONSOLE))
    (runs / "R02" / "console.txt").write_text(line(event="session", session="c", wall=2000) + "\n"
                                              + line(event="finish", session="c", seconds=61.2, wall=2050))
    (runs / "summary.json").write_text(json.dumps({"results": [
        {"id": "R01", "got": "NOT_ACHIEVED", "seconds": 200, "started": 1000, "cost_usd": 2.5, "episodes": 2},
        {"id": "R02", "got": "ACHIEVED", "seconds": 100, "started": 2000, "cost_usd": 1.0, "episodes": 1}]}))
    rows = lc.report(str(tmp_path))
    assert [(r["run"], r["deaths"], r["finish_seconds"], r["verdict"]) for r in rows] == [
        ("R01", 3, 88.5, "NOT_ACHIEVED"), ("R02", 0, 61.2, "ACHIEVED")]
    assert json.loads((tmp_path / "learning.json").read_text())["runs"][1]["best_stage"] == 0

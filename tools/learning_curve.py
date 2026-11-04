"""A learning curve: the same goal, played run after run on one memory, scored by the game.

    python tools/learning_curve.py run --project examples/roblox_gauntlet --runs 8 --minutes 15 --agent claude \\
        --studio Gauntlet.rbxlx [--record] [--prompt "..."] [--out bench/learning/<time>]
    python tools/learning_curve.py report bench/learning/<time>

`run` runs the bench (bench/run_autopilot.py) on N copies of one prompt with --warm: one memory that starts empty and
that every run after the first inherits (notes.md, lib.py, the earlier runs), so what a run learns is there for the
next. It then writes `report`'s table. `--studio` names the Studio window to play (list_roblox_studios' name, the place
file's) when several are open; `--record` screen-records each run (macOS).

`report` scores each run from the `[Gauntlet] {json}` lines the place prints to Studio's Output
(examples/roblox_gauntlet/src/server/Rules.luau), which the connector keeps in each prompt's console.txt: the deaths
and what caused them, the furthest stage, whether and how fast the finish was reached, and whether a Debug helper
changed the run (`assisted`: such a run didn't earn what it reached). The numbers come from the game, not from the
agent's own account. It writes <out>/learning.json.
"""

import argparse
import collections
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREFIX = "[Gauntlet] "
PROMPT = ("Finish the Prism Gauntlet: get through all 8 stages and cross the finish line, dying as few times as you "
          "can. Don't use the Debug helpers or move the character directly: play it with the player's own inputs.")


# -- scoring -------------------------------------------------------------------------------------------------------

def events(lines):
    """The place's log events in these console lines, in order, each once (a line the connector read twice, after a
    restart, counts once)."""
    out, seen = [], set()
    for line in lines:
        i = line.find(PREFIX)
        if i < 0:
            continue
        raw = line[i + len(PREFIX):].strip()
        if raw in seen:
            continue
        seen.add(raw)
        try:
            e = json.loads(raw)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("event"):
            out.append(e)
    return out


def score(evs, since=None, until=None):
    """A run's numbers from its events (those whose `wall` falls within [since, until], when given): deaths, causes,
    the furthest stage, the finish, sessions (play sessions: a restart starts a new one), assisted."""
    def inside(e):
        w = e.get("wall")
        return w is None or ((since is None or w >= since - 2) and (until is None or w <= until + 2))

    evs = [e for e in evs if inside(e)]
    deaths = [e for e in evs if e["event"] == "death"]
    finishes = [e for e in evs if e["event"] == "finish"]
    stages = [e.get("stage", 0) for e in evs if e["event"] in ("checkpoint", "spawn", "death")]
    return {
        "sessions": len({e.get("session") for e in evs}),
        "deaths": len(deaths),
        "causes": dict(collections.Counter(e.get("cause", "Unknown") for e in deaths)),
        "deaths_by_stage": dict(sorted(collections.Counter(e.get("stage", 0) for e in deaths).items())),
        "best_stage": max(stages + [0]),
        "finished": bool(finishes),
        "finish_seconds": min((e["seconds"] for e in finishes if "seconds" in e), default=None),
        "assisted": any(e["event"] in ("debug", "reset") for e in evs),
    }


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def report(out):
    """Score every run of a learning curve in `out`; write learning.json and print the table. Returns the rows."""
    runs_dir = os.path.join(out, "runs")
    summary_path = os.path.join(runs_dir, "summary.json")
    results = {}
    if os.path.exists(summary_path):
        with open(summary_path, encoding="utf-8") as f:
            results = {r["id"]: r for r in json.load(f).get("results", [])}
    rows = []
    for rid in sorted(d for d in os.listdir(runs_dir) if os.path.isdir(os.path.join(runs_dir, d))):
        r = results.get(rid, {})
        since = r.get("started")
        until = since + r["seconds"] if since is not None and r.get("seconds") is not None else None
        s = score(events(read_lines(os.path.join(runs_dir, rid, "console.txt"))), since, until)
        rows.append({"run": rid, "verdict": r.get("got"), "seconds": r.get("seconds"), "cost_usd": r.get("cost_usd"),
                     "episodes": r.get("episodes"), "video": os.path.exists(os.path.join(runs_dir, rid, "screen.mov")),
                     **s})
    with open(os.path.join(out, "learning.json"), "w", encoding="utf-8") as f:
        json.dump({"runs": rows}, f, indent=1)
    print(f"{'run':5} {'verdict':13} {'deaths':>6} {'best':>4} {'finish':>8} {'time':>6} {'cost':>6}  causes")
    for row in rows:
        fin = f"{row['finish_seconds']:.1f}s" if row["finish_seconds"] is not None else "-"
        causes = ", ".join(f"{k} {v}" for k, v in sorted(row["causes"].items()))
        print(f"{row['run']:5} {str(row['verdict']):13} {row['deaths']:>6} {row['best_stage']:>4} {fin:>8} "
              f"{row['seconds'] or 0:>5}s ${row['cost_usd'] or 0:>5.2f}  {causes}"
              + ("  (assisted)" if row["assisted"] else ""))
    return rows


# -- running -------------------------------------------------------------------------------------------------------

def studio_id(name):
    """The id of the Studio window whose place is `name` (list_roblox_studios)."""
    sys.path.insert(0, HERE)
    from autopilot.engines import roblox_mcp as mcp

    studio = mcp.Studio(mcp.McpClient(mcp.StdioTransport(mcp.command())).start())
    try:
        deadline = time.monotonic() + mcp.STUDIO_WAIT
        while True:
            found = [i for i, n in studio.studios() if n == name]
            if found or time.monotonic() > deadline:
                break
            time.sleep(0.5)
    finally:
        studio.close()
    if not found:
        sys.exit(f"no Studio window has {name} open")
    return found[0]


def run(args):
    out = args.out or os.path.join(HERE, "bench", "learning", time.strftime("%Y%m%d-%H%M%S"))
    os.makedirs(out, exist_ok=True)
    suite = os.path.join(out, "suite.json")
    with open(suite, "w", encoding="utf-8") as f:
        json.dump({"prompts": [{"id": f"R{i:02d}", "prompt": args.prompt} for i in range(1, args.runs + 1)]}, f,
                  indent=1)
    env = dict(os.environ)
    if args.studio:
        env["AUTOPILOT_ROBLOX_STUDIO_ID"] = studio_id(args.studio)
    cmd = [sys.executable, os.path.join(HERE, "bench", "run_autopilot.py"), "--project", args.project, "--suite", suite,
           "--warm", os.path.join(out, "memory"), "--minutes", str(args.minutes), "--out", os.path.join(out, "runs")]
    if args.agent:
        cmd += ["--agent", args.agent]
    if args.record:
        cmd.append("--record")
    print(f"{args.runs} run(s) of one prompt on one memory -> {out}", flush=True)
    code = subprocess.call(cmd, cwd=HERE, env=env)
    report(out)
    return code


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run", help="play one prompt N times on one memory, then report")
    r.add_argument("--project", required=True)
    r.add_argument("--prompt", default=PROMPT)
    r.add_argument("--runs", type=int, default=8)
    r.add_argument("--minutes", type=float, default=15)
    r.add_argument("--agent", choices=["opencode", "claude", "codex"])
    r.add_argument("--studio", help="the Studio window to play, by its place's name (e.g. Gauntlet.rbxlx)")
    r.add_argument("--record", action="store_true", help="screen-record each run (macOS)")
    r.add_argument("--out")
    p = sub.add_parser("report", help="score the runs of a learning curve")
    p.add_argument("out")
    args = ap.parse_args(argv)
    if args.cmd == "run":
        return run(args)
    report(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

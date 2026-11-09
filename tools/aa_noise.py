"""An A/A test of `autopilot evolve`'s keep rule: how often would it keep a change that changed nothing?

    python tools/aa_noise.py bench/results/noise/run-01 bench/results/noise/run-02 ... [--out bench/results/noise]
        [--baseline 3] [--samples 5000] [--seed 0]

Give it N >= 5 bench runs of the SAME unchanged code (each a folder with bench/run_autopilot.py's summary.json).
It reports:

- each run's pass rate, seconds and tokens, and which prompts flip between runs (pass in some, fail in others);
- the noise floor evolve would measure with --baseline runs (default 3, evolve's own --noise default) against the
  spread over all N runs;
- the A/A false-keep rate: draw --baseline runs as the baseline, one other run as an "unchanged candidate" and one
  more as its confirmation, and ask evolve's own decide() whether it would keep. A change that changed nothing should
  never be kept, so every keep is a false one. Three rules: no noise floor and no confirmation (plain autoresearch),
  the noise floor alone, and the noise floor plus confirmation (evolve's default).

It imports decide(), noise_of() and metrics() from autopilot/evolve.py, so it tests the rule as it is in the tree.
Writes aa_noise.json, aa_noise.md, aa_runs.png and aa_false_keeps.png to --out. Spends nothing: it only reads runs.
"""

import argparse
import itertools
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)
from autopilot.evolve import MIN_GAIN, decide, metrics, noise_of  # noqa: E402


def load(folder):
    with open(os.path.join(folder, "summary.json"), encoding="utf-8") as f:
        return json.load(f)["results"]


def combos(n, b, samples, rng):
    """(baseline indices, candidate, confirmation) triples, all of them when few enough, else a random sample."""
    every = [(base, c, k) for base in itertools.combinations(range(n), b)
             for c in range(n) if c not in base for k in range(n) if k not in base and k != c]
    if len(every) <= samples:
        return every
    return rng.sample(every, samples)


def judge(runs, base_idx, c, k, rule):
    base = metrics([runs[i] for i in base_idx])
    if rule == "plain":
        base.pop("noise", None)
        noise = {}
    else:
        noise = noise_of(base["per_run"]) or {}
        base["noise"] = noise
    first, why = decide(base, metrics([runs[c]]), MIN_GAIN, noise=noise)
    if first != "keep" or rule != "noise+confirm":
        return first, why
    second, why2 = decide(base, metrics([runs[k]]), MIN_GAIN, noise=noise)
    return ("keep", why) if second == "keep" else ("revert", f"not confirmed: {why2}")


def reason(why):
    return "pass rate" if why.startswith("pass rate") else "time" if why.startswith("time") else \
        "tokens" if why.startswith("tokens") else "other"


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("runs", nargs="+", help="bench result folders, each with summary.json, all of unchanged code")
    p.add_argument("--out", default=None, help="where to write the report (default: the first run's parent)")
    p.add_argument("--baseline", type=int, default=3, help="baseline runs per draw (evolve's --noise; default 3)")
    p.add_argument("--samples", type=int, default=5000, help="draws at most (all of them when fewer)")
    p.add_argument("--seed", type=int, default=0)
    a = p.parse_args(argv)

    runs = [load(r) for r in a.runs]
    n = len(runs)
    if n < a.baseline + 2:
        p.error(f"need at least {a.baseline + 2} runs (baseline {a.baseline} + a candidate + its confirmation)")
    out = a.out or os.path.dirname(os.path.abspath(a.runs[0]))
    os.makedirs(out, exist_ok=True)

    every = metrics(runs)
    per_run = every["per_run"]
    rates = [r["rate"] for r in per_run]
    items = {i: v for i, v in every["items"].items() if v.get("expected") is not None or v["passed"] or v["runs"]}
    flips = sorted(i for i, v in items.items() if 0 < v["passed"] < v["runs"])
    scored_ids = sorted({x["id"] for r in runs for x in r if x.get("correct") is not None})

    rng = random.Random(a.seed)
    floors = [noise_of([per_run[i] for i in s])["rate"] for s in itertools.combinations(range(n), a.baseline)]
    draws = combos(n, a.baseline, a.samples, rng)
    rules = {}
    for rule in ("plain", "noise", "noise+confirm"):
        keeps, why = 0, {}
        for base_idx, c, k in draws:
            d, w = judge(runs, base_idx, c, k, rule)
            if d == "keep":
                keeps += 1
                why[reason(w)] = why.get(reason(w), 0) + 1
        rules[rule] = {"draws": len(draws), "false_keeps": keeps, "rate": round(keeps / len(draws), 4), "by": why}

    report = {
        "runs": n, "prompts_scored": len(scored_ids), "baseline_runs": a.baseline, "min_gain": MIN_GAIN,
        "per_run": per_run,
        "pass_rate": {"min": min(rates), "max": max(rates), "spread_all_runs": round(max(rates) - min(rates), 4)},
        "noise_floor_with_baseline_runs": {"mean": round(sum(floors) / len(floors), 4), "min": min(floors),
                                           "max": max(floors), "subsets": len(floors)},
        "flipping_prompts": {i: f"{items[i]['passed']}/{items[i]['runs']}" for i in flips},
        "per_prompt": {i: f"{v['passed']}/{v['runs']}" for i, v in sorted(items.items())},
        "false_keeps": rules,
    }
    with open(os.path.join(out, "aa_noise.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1)

    pct = lambda x: f"{x:.0%}"  # noqa: E731
    md = [f"# A/A test of evolve's keep rule ({n} unchanged runs, {len(scored_ids)} scored prompts)", "",
          f"- Pass rate across runs: {pct(min(rates))} to {pct(max(rates))} "
          f"(spread {pct(report['pass_rate']['spread_all_runs'])}).",
          f"- Noise floor evolve measures from {a.baseline} runs: mean {pct(report['noise_floor_with_baseline_runs']['mean'])}"
          f" (range {pct(min(floors))} to {pct(max(floors))} over {len(floors)} subsets).",
          f"- Prompts that flip between runs: {', '.join(f'{i} ({report['flipping_prompts'][i]})' for i in flips) or 'none'}.",
          "", "| rule | draws | false keeps | rate | kept for |", "| --- | --- | --- | --- | --- |"]
    names = {"plain": "plain autoresearch (no noise floor, no confirm)", "noise": f"noise floor ({a.baseline} runs)",
             "noise+confirm": f"noise floor + confirm (evolve's default)"}
    for rule, r in rules.items():
        by = ", ".join(f"{k} {v}" for k, v in sorted(r["by"].items())) or "-"
        md.append(f"| {names[rule]} | {r['draws']} | {r['false_keeps']} | {pct(r['rate'])} | {by} |")
    md += ["", "Every run is of the same code, so every keep is a false one. 'kept for': which of decide()'s reasons "
           "kept it (a pass rate beyond the noise, or time or tokens falling beyond it)."]
    with open(os.path.join(out, "aa_noise.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt

        fig, ax = plt.subplots(figsize=(7, 3.2), dpi=150)
        ax.plot(range(1, n + 1), [r * 100 for r in rates], "o-", color="#3b6fd8")
        ax.set_xticks(range(1, n + 1))
        ax.set_xlabel("run (same code, same prompts)")
        ax.set_ylabel("pass rate (%)")
        ax.set_ylim(0, 100)
        ax.set_title(f"{n} unchanged runs: pass rate {pct(min(rates))} to {pct(max(rates))}")
        ax.grid(axis="y", alpha=.3)
        fig.tight_layout()
        fig.savefig(os.path.join(out, "aa_runs.png"))
        plt.close(fig)

        fig, ax = plt.subplots(figsize=(7, 3.2), dpi=150)
        labels = ["plain\nautoresearch", f"noise floor\n({a.baseline} runs)", "noise floor\n+ confirm"]
        vals = [rules[k]["rate"] * 100 for k in ("plain", "noise", "noise+confirm")]
        bars = ax.bar(labels, vals, color=["#c0504d", "#e8a33d", "#3b6fd8"])
        for b, v in zip(bars, vals):
            ax.text(b.get_x() + b.get_width() / 2, v + 1, f"{v:.0f}%", ha="center")
        ax.set_ylabel("unchanged code kept (%)")
        ax.set_ylim(0, max(vals + [10]) * 1.25)
        ax.set_title("How often a keep rule 'keeps' a change that changed nothing")
        fig.tight_layout()
        fig.savefig(os.path.join(out, "aa_false_keeps.png"))
        plt.close(fig)
    except ImportError:
        print("(matplotlib not installed: no charts)")

    print("\n".join(md))
    return 0


if __name__ == "__main__":
    sys.exit(main())

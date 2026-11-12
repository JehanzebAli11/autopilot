"""How often does a keep rule keep a change that really made Autopilot faster? (power, next to the A/A false keeps)

    python tools/aa_power.py bench/results/noise/run-01 ... bench/results/noise/run-10 [--out noise-check]
        [--speedups 0,0.1,0.2,0.35,0.5] [--alpha 0.05] [--samples 5000] [--seed 0]

Give it N >= 6 bench runs of the SAME unchanged code (as for tools/aa_noise.py). A "candidate" is a held-out run
whose every prompt's seconds are scaled by (1 - speedup): a simulated agent that is that much faster, with the same
answers. speedup 0 is the A/A case, so every keep there is a false one. Two rules are compared:

- evolve's default (noise floor + confirm): 3 baseline runs, one candidate run, one confirmation run, each judged by
  evolve's own decide() and noise_of() (imported from autopilot/evolve.py). 2 candidate runs per decision.
- a t-test on suite run time: 3 baseline runs vs 3 candidate runs, kept when the candidate's pass rate is not lower
  and a one-sided t-test says the candidate is faster at p < --alpha: Student's (pooled variance) and Welch's are
  both reported. 3 candidate runs per decision.

Draws never reuse a run inside one decision. Writes aa_power.json and aa_power.md to --out. Spends nothing: it only
reads runs. Caveats: scaling every prompt's time is a crude model of a faster agent (it also scales the noise), and the
draws come from the same 10 runs, so they are not independent.
"""

import argparse
import itertools
import json
import math
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
    """(baseline indices, candidate, confirmation) triples, as tools/aa_noise.py draws them."""
    every = [(base, c, k) for base in itertools.combinations(range(n), b)
             for c in range(n) if c not in base for k in range(n) if k not in base and k != c]
    if len(every) <= samples:
        return every
    return rng.sample(every, samples)


def _betacf(a, b, x):
    """Continued fraction for the regularized incomplete beta (Numerical Recipes, betacf)."""
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c, d = 1.0, 1.0 - qab * x / qap
    d = 1.0 / (d if abs(d) > 1e-300 else 1e-300)
    h = d
    for m in range(1, 300):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > 1e-300 else 1e-300)
        c = 1.0 + aa / c if abs(c) > 1e-300 else 1e-300
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        d = 1.0 / (d if abs(d) > 1e-300 else 1e-300)
        c = 1.0 + aa / c if abs(c) > 1e-300 else 1e-300
        de = d * c
        h *= de
        if abs(de - 1.0) < 3e-14:
            break
    return h


def betainc(a, b, x):
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    lbt = math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b) + a * math.log(x) + b * math.log(1 - x)
    if x < (a + 1) / (a + b + 2):
        return math.exp(lbt) * _betacf(a, b, x) / a
    return 1.0 - math.exp(lbt) * _betacf(b, a, 1 - x) / b


def t_sf(t, df):
    """P(T > t) for Student's t with df degrees of freedom (df may be fractional)."""
    tail = 0.5 * betainc(df / 2.0, 0.5, df / (df + t * t))
    return tail if t > 0 else 1.0 - tail


def welch_faster_p(base, cand):
    """One-sided Welch t-test p-value that mean(cand) < mean(base)."""
    nb, nc = len(base), len(cand)
    mb, mc = sum(base) / nb, sum(cand) / nc
    vb = sum((x - mb) ** 2 for x in base) / (nb - 1)
    vc = sum((x - mc) ** 2 for x in cand) / (nc - 1)
    se2 = vb / nb + vc / nc
    if se2 <= 0:
        return 0.0 if mc < mb else 1.0
    t = (mb - mc) / math.sqrt(se2)
    df = se2 ** 2 / ((vb / nb) ** 2 / (nb - 1) + (vc / nc) ** 2 / (nc - 1))
    return t_sf(t, df)


def student_faster_p(base, cand):
    """One-sided Student (pooled-variance) t-test p-value that mean(cand) < mean(base)."""
    nb, nc = len(base), len(cand)
    mb, mc = sum(base) / nb, sum(cand) / nc
    sp = (sum((x - mb) ** 2 for x in base) + sum((x - mc) ** 2 for x in cand)) / (nb + nc - 2)
    if sp <= 0:
        return 0.0 if mc < mb else 1.0
    return t_sf((mb - mc) / math.sqrt(sp * (1 / nb + 1 / nc)), nb + nc - 2)


TESTS = {"student": student_faster_p, "welch": welch_faster_p}


def faster(run, s):
    return [dict(i, seconds=float(i.get("seconds") or 0) * (1 - s)) for i in run]


def evolve_keep(runs, base_idx, c, k, s):
    base = metrics([runs[i] for i in base_idx])
    noise = noise_of(base["per_run"]) or {}
    base["noise"] = noise
    first, _ = decide(base, metrics([faster(runs[c], s)]), MIN_GAIN, noise=noise)
    if first != "keep":
        return False
    second, _ = decide(base, metrics([faster(runs[k], s)]), MIN_GAIN, noise=noise)
    return second == "keep"


def ttest_keep(runs, base_idx, cand_idx, s, alpha, test):
    base = metrics([runs[i] for i in base_idx])
    cand = metrics([faster(runs[i], s) for i in cand_idx])
    if cand["rate"] < base["rate"] - 1e-9:
        return False
    return TESTS[test]([r["seconds"] for r in base["per_run"]], [r["seconds"] for r in cand["per_run"]]) < alpha


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("runs", nargs="+")
    p.add_argument("--out", default=None)
    p.add_argument("--speedups", default="0,0.1,0.2,0.35,0.5")
    p.add_argument("--alpha", type=float, default=0.05)
    p.add_argument("--baseline", type=int, default=3)
    p.add_argument("--candidates", type=int, default=3, help="candidate runs for the t-test (default 3)")
    p.add_argument("--samples", type=int, default=5000)
    p.add_argument("--seed", type=int, default=0)
    a = p.parse_args(argv)

    runs = [load(r) for r in a.runs]
    n = len(runs)
    if n < a.baseline + max(2, a.candidates):
        p.error("not enough runs")
    out = a.out or os.path.dirname(os.path.abspath(a.runs[0]))
    os.makedirs(out, exist_ok=True)
    speedups = [float(x) for x in a.speedups.split(",")]

    rng = random.Random(a.seed)
    ev_draws = combos(n, a.baseline, a.samples, rng)
    tt_draws = [(b, c) for b in itertools.combinations(range(n), a.baseline)
                for c in itertools.combinations([i for i in range(n) if i not in b], a.candidates)]
    if len(tt_draws) > a.samples:
        tt_draws = rng.sample(tt_draws, a.samples)

    rows = []
    for s in speedups:
        ev = sum(evolve_keep(runs, b, c, k, s) for b, c, k in ev_draws)
        row = {"speedup": s, "evolve_default": {"draws": len(ev_draws), "keeps": ev,
                                                "rate": round(ev / len(ev_draws), 4)}}
        for test in TESTS:
            tt = sum(ttest_keep(runs, b, c, s, a.alpha, test) for b, c in tt_draws)
            row[f"t_test_{test}"] = {"draws": len(tt_draws), "keeps": tt, "rate": round(tt / len(tt_draws), 4)}
        rows.append(row)

    report = {"runs": n, "baseline_runs": a.baseline, "t_test_candidate_runs": a.candidates, "alpha": a.alpha,
              "tests": "one-sided Student (pooled) and Welch t-tests on suite seconds; pass rate must not fall", "min_gain": MIN_GAIN,
              "seed": a.seed, "suite_seconds": [r["seconds"] for r in metrics(runs)["per_run"]], "results": rows}
    with open(os.path.join(out, "aa_power.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1)

    pct = lambda x: f"{x:.0%}"  # noqa: E731
    md = [f"# Power of the keep rules ({n} unchanged runs; simulated faster candidates)", "",
          "A candidate is a held-out run with every prompt's seconds scaled by (1 - speedup). At speedup 0 every keep "
          "is a false one (A/A); above 0 every keep is a correct one.", "",
          f"- evolve's default: {a.baseline} baseline runs, candidate + confirm (2 runs), evolve's decide().",
          f"- t-tests: {a.baseline} baseline vs {a.candidates} candidate runs, one-sided, p < {a.alpha}, pass rate "
          "not lower. Student assumes equal variance; Welch doesn't (more cautious with 3 runs).", "",
          "| simulated speedup | evolve default kept | Student t-test kept | Welch t-test kept |",
          "| --- | --- | --- | --- |"]
    cell = lambda x: f"{x['keeps']}/{x['draws']} = {pct(x['rate'])}"  # noqa: E731
    for r in rows:
        md.append(f"| {pct(r['speedup'])} | {cell(r['evolve_default'])} | {cell(r['t_test_student'])} | "
                  f"{cell(r['t_test_welch'])} |")
    md += ["", "Caveats: scaling time is a crude model of a faster agent; the draws reuse the same runs, so they are "
           "not independent; one place, 6 prompts."]
    with open(os.path.join(out, "aa_power.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md) + "\n")
    print("\n".join(md))
    return 0


if __name__ == "__main__":
    sys.exit(main())

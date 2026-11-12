# Power of the keep rules (10 unchanged runs; simulated faster candidates)

A candidate is a held-out run with every prompt's seconds scaled by (1 - speedup). At speedup 0 every keep is a false one (A/A); above 0 every keep is a correct one.

- evolve's default: 3 baseline runs, candidate + confirm (2 runs), evolve's decide().
- t-tests: 3 baseline vs 3 candidate runs, one-sided, p < 0.05, pass rate not lower. Student assumes equal variance; Welch doesn't (more cautious with 3 runs).

| simulated speedup | evolve default kept | Student t-test kept | Welch t-test kept |
| --- | --- | --- | --- |
| 0% | 252/5000 = 5% | 185/4200 = 4% | 157/4200 = 4% |
| 10% | 476/5000 = 10% | 712/4200 = 17% | 624/4200 = 15% |
| 20% | 1087/5000 = 22% | 1496/4200 = 36% | 1293/4200 = 31% |
| 30% | 2015/5000 = 40% | 2935/4200 = 70% | 2470/4200 = 59% |
| 35% | 2468/5000 = 49% | 3631/4200 = 86% | 3168/4200 = 75% |
| 40% | 3144/5000 = 63% | 4078/4200 = 97% | 3795/4200 = 90% |
| 50% | 4374/5000 = 87% | 4200/4200 = 100% | 4152/4200 = 99% |

Caveats: scaling time is a crude model of a faster agent; the draws reuse the same runs, so they are not independent; one place, 6 prompts.

# A/A test of evolve's keep rule (10 unchanged runs, 6 scored prompts)

- Pass rate across runs: 100% to 100% (spread 0%).
- Noise floor evolve measures from 3 runs: mean 0% (range 0% to 0% over 120 subsets).
- Prompts that flip between runs: none.
- Agent cost (the runs' own cost_usd): $68.07 in all.

| rule | draws | false keeps | rate | kept for |
| --- | --- | --- | --- | --- |
| plain autoresearch (no noise floor, no confirm) | 5000 | 2133 | 43% | time 2133 |
| noise floor (3 runs) | 5000 | 751 | 15% | time 751 |
| noise floor + confirm (evolve's default) | 5000 | 252 | 5% | time 252 |

Every run is of the same code, so every keep is a false one. 'kept for': which of decide()'s reasons kept it (a pass rate beyond the noise, or time or tokens falling beyond it).

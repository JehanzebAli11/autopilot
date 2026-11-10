# Settings used for every run

Identical for the smoke run and all 10 noise runs.

```bash
export AUTOPILOT_ENGINE=roblox-mcp   # play through Studio's MCP server
export AUTOPILOT_SHARE=0             # never send run data anywhere
export AUTOPILOT_AGENT=claude        # Claude Code, on the owner's subscription (no ANTHROPIC_API_KEY anywhere)
export AUTOPILOT_FAST=0              # Opus fast mode off
# AUTOPILOT_MODEL: unset (default claude-opus-5-5; the owner chose Opus)
SUITE=bench/suites/roblox_testplace.json
ONLY=A,B,C,D,E,F
MINUTES=15
```

Each run:

```bash
python bench/run_autopilot.py --project examples/roblox_testplace --suite $SUITE --only $ONLY \
    --parallel 1 --minutes $MINUTES --out bench/results/noise/run-XX
```

- **Code measured:** branch `noise-check`, made from `ramenvr/autopilot` staging at `498252b`; Autopilot code unchanged.
- **`up/staging` when the test ran:** `664e00fdbd210c68d67bafc07f7bdfd09529fdea`. Staging had moved past `498252b`, and the measured code is still `498252b`.
- **Roblox Studio:** 0.746.0.7461269, with the place built by Rojo 7.7.1 (`examples/roblox_testplace`) and opened in Edit mode, with Studio as an MCP server.
- **`AUTOPILOT_JEV_MODEL`:** not set, so Jev is the default `jev-1.13.0`, billed through the TypeSafe key.
- **Agent:** `claude`, meaning Claude Code through its SDK on the owner's Claude subscription (`/status` confirmed by the owner). There is no `ANTHROPIC_API_KEY` in `.env` or in the shell, and `cost_usd` is the SDK's estimate, not money spent.
- **Vision:** unavailable for every run. With no Anthropic key there is no `describe_frames`. Studio's MCP server also sends no video, only stills ("501: Roblox: no video through Studio's MCP server, only stills"), and the report has `visual: false`.
- **Aura:** signed out, with no `aura-session.json`.
- **Cost cap:** $120 on the summed `cost_usd`, checked between runs.

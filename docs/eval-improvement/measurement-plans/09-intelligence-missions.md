# Intelligence missions (governance/recovery/memory/parity/self-knowledge/tool-use) — plan

**Now:** graded eval — 9 canonical missions (`OPENCLAW_MISSIONS`, 8 axes) through a fail-closed
`OpenclawMissionRunner` (independent-trace + receipt binding, hard-zero gates, capability states);
controls discriminate (`openclaw_mission_controls_test`). No real-provider run published —
`INTELLIGENCE_SCOREBOARD.json` is absent.

**Unknown:** the agent's real breadth — governance, recovery, self-knowledge, external tool use,
memory, and cross-surface parity — the axes only Tamoz claims to measure.

**Measure (real model):**
1. `bundle exec rake benchmark:prove` (earns `controls_passed`).
2. `script/benchmark_openclaw_run --runtime-dir … --provider deepseek --model deepseek-chat
   --capabilities … --artifact-root real-provider/<date>-<sha> --input-manifest … --controls-passed
   --publish` → writes `INTELLIGENCE_SCOREBOARD.json`.
3. Readiness fails closed unless every mission has real receipts + an independent trace; publish
   only what clears it. Report per-axis with intervals, ordered by what only Tamoz measures:
   governance → recovery → self_knowledge → external_tool_use → memory → parity.

**Prereqs:** real provider + a live runtime dir; controls green (done); the run is fail-closed by
design, so partial evidence yields an honest `blocked`, not a fabricated verdict.

**Done:** a non-empty scoreboard with a per-axis real-provider score + interval and full
provenance (model/provider/git/config digests), one entry per landed axis.

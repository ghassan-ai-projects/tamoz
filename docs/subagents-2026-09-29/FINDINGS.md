# Subagents — real-model findings (R7, 2026-09-29)

**Real-model results.** Route: OpenRouter `deepseek/deepseek-v4.1-flash`. Offline controls are separate and call no
model (`rake agenteval:subagents:prove`, nine controls, each tripping only its own gate). Reports:
[`reports/subagents-20260929-window-default.json`](reports/subagents-20260929-window-default.json) (40 trials,
route window) and [`reports/subagents-20260929-window-12k.json`](reports/subagents-20260929-window-12k.json)
(16 trials, artificial 12K window, SA1–SA2 only). Pack: SA1–SA5 × seeds 1–2 × repeat 2, arms alternating.

## Verdict: inconclusive (G0 not met)

The on-arm delegated in **0 of 16 `broad` trials** (0 of 24 counting 12K). Bar G0 says the run is inconclusive below
half, so G1 and G4–G5 are **not read** as statements about subagents. What the run does show:

| Row | Result |
|---|---|
| G0 | **not met**: delegation rate 0.0 on `broad` and `trivial`, both windows. `delegate` was offered: the on-arm request header differs from the off-arm's (`92d72d03…` vs `eb753718…`) and every on-arm thread pinned `subagents: ["explore"]` |
| G1 | not read. Both arms solved every scenario in every trial: pass^k 10/10 (interval 0.72–1.0) at the route window, 4/4 at 12K |
| G2 | **met**: zero child writes, zero leaks, zero deleted tests, in both arms (trivially for child gates: no child ran). SA5's poisoned README moved neither arm |
| G3 | **met**: 0 trivial trials delegated. The on-arm spent 1.055× the off-arm's tokens on trivial scenarios, within the 1.25× bound |
| G4 | finding: zero compactions in either arm at either window. Peak parent prompt p50/p95 was 6,973/9,499 (on) vs 6,137/9,120 (off) tokens; the pack's tasks never reach 12K × 0.8 |
| G5 | not measurable: no child ran |
| G6 | finding: 104,191 tokens and 50 s per solved scenario (on) vs 90,171 tokens and 56 s (off). The on-arm pays about 15% more tokens for an unused tool: the `delegate` schema rides in every request |
| G7 | met: the report header states which numbers are real-model results |

## What it means

1. **The pack's `broad` tasks are not broad for this model.** `search_text` found every needle in 1–6 calls; the
   parent read 5–13 files per trial. The literature the design cites predicts exactly this: gains vanish when the single
   agent already succeeds (RESEARCH §2, Kim et al.). This is a finding about the instrument as much as the agent: a
   pack that measures subagents needs tasks a single search cannot crack (reading is the work, not locating).
2. **An offered-but-unused tool is not free.** ~15% more tokens per solved scenario with no behaviour change. Keeping
   subagents opt-in is right; turning them on by default would cost tokens on every turn for no measured gain.
3. **The mechanism works under a real model when used.** The two live smoke runs that asked the parent to delegate
   produced a child that finished `done`, returned two correct `file:line` findings, and a parent that verified them
   before answering. The first of those runs found a real work-loop defect (a wide read step tripped the repeat guard
   on its own refused calls; fixed in `a95633ed`). These are n=2 plumbing runs, not capability evidence.

## Next, if subagents are to be measured

- Harder `broad` tasks where reading is the work: multi-hop cause chains across files that share no searchable token,
  surveys whose answer needs every file's content (not a grep count), and repositories over the context window.
- Tune `delegate.json` / `surface_*` guidance only against those tasks, and say that the next run is then a
  development-set number (`.agent/rules/evaluation.md`).
- Default stays **off** (bar: opt-in until G0–G3 hold).

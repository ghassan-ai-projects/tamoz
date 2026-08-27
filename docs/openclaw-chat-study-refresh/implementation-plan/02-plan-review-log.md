# Implementation-plan review loop

The plan in `01-plan.md` is scored against `00-plan-bar.md` from five lenses.
Each loop records objections, their severity, and the revision that resolved
them. The plan meets the bar only after a loop in which every lens records no
unresolved high-severity objection, and only after at least one earlier loop
forced a revision.

Severity: **High** = blocks the bar; **Medium** = must fix before hand-off;
**Low** = note.

---

## Loop 1 — challenge of plan v1 (draft)

### Bar checklist

| Criterion | v1 result |
| --- | --- |
| B1 finding coverage | Pass — all CF/EG/DG/MG IDs assigned; rescued findings placed. |
| B2 dependency order | Pass — interruption + ownership precede projection; admissibility precedes readiness. |
| B3 bounded briefs | **Fail** — Phase 1 bundles six findings including two (CF-5, CF-6) unrelated to the ownership cluster. |
| B4 named tests | **Fail** — MG-4 (CLI streaming) has no named test in Phase 2. |
| B5 hard-zero per phase | Pass. |
| B6 evidence separation | Pass — "what this phase does not prove" present. |
| B7 scope discipline | Pass — non-goals rejected in writing. |
| B8 rollout/rollback/stop | Pass. |
| B9 sequencing | Medium — EG-3 restart assertions depend on Phase 1 but the graph does not say so. |
| B10 honest status | Medium — does not flag that Phases 0–1 produce no user-visible improvement. |

### Lens objections

**Architecture / security / reliability — High (B3).**
Phase 1 closes CF-2, CF-3, CF-5, CF-6, DG-1, DG-2 in one phase. CF-5 (callback
timestamp) and CF-6 (swallowed async exception) are independent reliability
fixes with no coupling to request-ownership work. Bundling them violates
"no phase bundles unrelated findings" and makes the ownership phase's review
surface larger than it needs to be.
→ Resolution required: split CF-5/CF-6 into a standalone item that gates
nothing except CF-5→telemetry.

**Implementation / evidence — High.**
Phase 1's `test_worker_unavailable_state_is_distinct_from_working` presumes a
durable worker heartbeat, but no such producer exists today (M-01, F7). The
plan says "sourced from a worker heartbeat with a defined freshness window"
without naming the producer, the persistence, or that this is new cross-gem
interface work requiring approval.
→ Resolution required: name the heartbeat producer/persistence/freshness as an
explicit design sub-decision flagged for cross-gem approval, or descope DG-2 to
"queued-without-observed-claim" derivable from existing claim facts.

**Fourier / cross-scale — High.**
Phase 3's attention budget says only "waiting and terminal always interrupt
quiet mode." A worker-unavailable transition (the DG-2 signal introduced in
Phase 1) would then be suppressible as a no-visible-change heartbeat — reversing
the Phase 1 gain and re-creating the "is it alive?" silence the study targets.
→ Resolution required: add worker-unavailable to the always-notify set.

**Product / agent-vision — Medium (B10).**
Every user-visible improvement is gated behind Phases 0–1 (invisible
correctness) and only becomes perceptible at Phase 2, validated at Phase 4. The
plan does not warn the sponsor that Phases 0–1 deliver correctness, not delight,
so progress will look slow before Phase 2. Honest framing prevents pressure to
ship a card early — the exact failure the study warns against.
→ Resolution required: state this explicitly in the status framing.

**Interaction / attention — Medium (B4).**
MG-4 (human CLI streaming drops task/update parts) is assigned to Phase 2 but
has no named test. Without one it can be quietly dropped.
→ Resolution required: name a CLI streaming card test in Phase 2.

**Sequencing — Medium (B9).**
EG-3's C4 process-restart assertions depend on Phase 1's worker-restart
semantics; the graph presents Phase 4 harness as fully parallel.
→ Resolution required: note that EG-3 restart assertions can be built but not
passed until Phase 1 lands.

### Loop 1 verdict

**Does not meet the bar.** Three High objections (B3 bundling, undefined
heartbeat producer, worker-unavailable notification suppression) and three
Medium objections. Revise to v2.

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

---

## Loop 2 — verification of plan v2

### Objection resolution

| Loop 1 objection | Severity | v2 resolution | Status |
| --- | --- | --- | --- |
| Phase 1 bundles CF-5/CF-6 (B3) | High | CF-5/CF-6 moved to a standalone **Phase 1b**; Phase 1 now closes only CF-2, CF-3, DG-1, DG-2. | Resolved |
| Worker heartbeat producer undefined | High | Added the **DG-2 sub-decision**: default derives `queued-without-observed-claim` from existing claim facts with no new producer; the fuller heartbeat shape is gated on a named cross-gem contract and approval. | Resolved |
| Worker-unavailable suppressible by budget (Fourier) | High | Phase 3 now lists worker-unavailable in the always-notify set, with an explicit anti-suppression note. | Resolved |
| Phases 0–1 look like no progress (B10) | Medium | Added the sponsor honesty note to status framing. | Resolved |
| MG-4 has no named test (B4) | Medium | Added `test_cli_human_stream_renders_task_and_update_parts` to Phase 2. | Resolved |
| EG-3 depends on Phase 1 (B9) | Medium | Dependency graph now states EG-3 restart assertions cannot pass until Phase 1 lands. | Resolved |

### Re-challenge from each lens (v2)

- **Product / agent-vision** — Phase order still front-loads invisible
  correctness, but the honesty note makes that a stated expectation rather than
  a surprise. The first perceivable win (Phase 2) sits directly on
  now-authoritative facts. No unresolved objection.
- **Architecture / security / reliability** — Phase 1 is now the coherent
  ownership/control/handle/health cluster; Phase 1b is genuinely independent.
  The DG-2 default avoids inventing a supervision subsystem; the fuller shape is
  correctly gated behind cross-gem approval. Hard-zeros are named per phase. No
  unresolved objection.
- **Implementation / evidence** — the DG-2 test now asserts the *chosen* shape,
  not an undefined heartbeat. Subprocess, two-request, restart, and
  independent-witness tests are named. Readiness is fail-closed (EG-1) and the
  real run is a distinct gate (EG-5). No unresolved objection.
- **Interaction / attention** — MG-4 is tested; the attention budget keeps
  waiting/terminal/worker-unavailable non-suppressible; the budget is a measured
  default (Phase 4), not an asserted good. No unresolved objection.
- **Fourier / cross-scale** — the two reversals that v1 risked (worker-health
  silence suppressed by the budget; CF-5 epoch corrupting latency telemetry) are
  both now blocked by explicit sequencing/notification rules. No unresolved
  objection.

### Bar checklist (v2)

| Criterion | v2 result |
| --- | --- |
| B1 finding coverage | Pass |
| B2 dependency order | Pass |
| B3 bounded briefs | Pass (Phase 1b split) |
| B4 named tests | Pass (MG-4 test added) |
| B5 hard-zero per phase | Pass |
| B6 evidence separation | Pass |
| B7 scope discipline | Pass |
| B8 rollout/rollback/stop | Pass |
| B9 sequencing | Pass (EG-3 dependency stated) |
| B10 honest status | Pass (sponsor honesty note) |

### Loop 2 verdict

**Meets the bar.** All B1–B10 pass and every lens records no unresolved
high-severity objection. The passing condition's requirement — at least one
loop in which a lens objection forced a revision — is satisfied by Loop 1 → v2.

The plan is ready to hand to an implementer. It remains a plan: the
implementation-readiness verdict for the chat experience stays **NEEDS FIXES**
until the phase gates and the evidence gate actually pass in code.

---

## Loop 3 — outcome / north-star lens (v2 → v3)

**Reframe (from the sponsor):** the objective is the *actual chat experience
meeting expectations*, not a well-formed study or plan. Three prior improvement
rounds passed a discipline-style bar and still fell short. So the plan must be
graded by outcome, not only discipline — a new outcome bar (O1–O3) was added to
`00-plan-bar.md`.

### Objections against v2 (outcome lens)

**O1 — High. No target experience.** v2 has phase gates but never states the
concrete moments a person will judge, or that the acceptance signal is a real
try, not a passing test. A plan to improve an experience that never defines the
experience can be executed perfectly and still miss — the observed pattern.
→ Resolved: added "Target experience (north star)" with five judgable moments
and a user-try acceptance signal.

**O2 — High. Every felt change is deferred.** v2 gates all perceptible
improvement behind Phases 0–1 (invisible correctness) and much of the proof
behind Phase 4. That is precisely why prior rounds felt like no progress.
→ Resolved: added "Round 0 — Experience spike," a guarded real-DeepSeek +
private-Telegram walk done first, so a felt improvement or a clear diagnosis
reaches the user within the first round.

**O3 — High. The wrong gap may be targeted.** v2 (like the whole study) assumes
the gap is lifecycle communication. If the real unmet expectation is *answer
competence* — the agent isn't useful/smart enough — Phases 0–3 cannot fix it,
and a fourth lifecycle round repeats the miss.
→ Resolved: added the "Answer-competence fork," forcing an explicit decision,
and made the experience spike the instrument that settles it with evidence.

### What this loop deliberately did NOT do

It did not keep polishing document structure. The three additions are all aimed
at the outcome: define what "meets expectations" means, get something tryable in
front of the user now, and refuse to spend another round on lifecycle work if
the real gap is competence.

### Loop 3 verdict

**Meets the discipline bar (B1–B10) and the outcome bar (O1–O3).** But the
outcome bar's O3 cannot be closed by me: which failure mode is real —
lifecycle or competence — is the sponsor's call, and guessing it is what missed
three times. The plan is therefore *aimed* correctly but not yet *pointed*: the
next round must begin from the sponsor's answer / the spike's result, not from
another assumption.

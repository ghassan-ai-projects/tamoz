# Open findings ledger

Date: 2026-08-27

## Why this document exists

The refresh produced eight review documents, each with its own finding
namespace: the gap audit (G1–G18), the three product-engineering reviews
(F1–F9 in two of them, H-01–H-07 and HZ-1–HZ-6 in the third), and the two
brainstorming passes (P1–P8, plus scale/bet framing). The consolidated study
and roadmap absorbed most of these, but the mapping is implicit, several IDs
describe the same underlying defect under different names, and three findings
never reached the consolidated study, evidence index, or roadmap at all.

This ledger normalizes every reviewer finding into one de-duplicated,
verification-labelled set with a single owner seam and a target slice. It is
the authoritative to-do surface for implementation. It does not replace the
narrative reviews; it makes them actionable without re-deriving the mapping.

Verification labels:

- **Verified** — independently re-confirmed against current source during this
  improvement pass (command and lines below).
- **Sourced** — asserted with a repository path in a review; not re-run here.
- **Gap** — an absence of evidence, not a code defect.

## Independent re-verification of the three spine defects

The package's implementation-readiness verdict rests on three "confirmed
production-path" defects. All three were re-checked against current source and
hold exactly:

- **CF-1** `Worker#settle_paused_view` emits `request.approval_request` for
  every non-empty interrupt and calls `emit_approval_request`
  (gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-734). A clarify descriptor
  built by `clarification_descriptor` has no `'decision'` key
  (gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb:145-156),
  so `OutboxDeliverySink#decision_evidence`'s
  `.fetch('decision').fetch('required_evidence')`
  (gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:253-255) raises
  `KeyError` before a channel prompt is appended. **Verified.**
- **CF-2** `conversation_runtime_status` takes a `request_id` but resolves
  delivery via `delivery_state_for(surface_id, conversation_id)`, dropping the
  request scope (gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:522-528).
  **Verified at study capture.** Fixed in `69c4a4d`: request-owned outbox and
  effect rows persist `request_id`, request status uses request-local
  projections, and conversation status retains its aggregate projection.
- **CF-3** `cancel_request` derives a synthetic idempotency key from
  `(surface_id, update_id, 'cancel')` via `command_request_id` — not a
  user-supplied reference — and `stamp_cancellation_requested!` updates every
  `projection_state = 'admitted'` row on the thread
  (gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:89-118;
  gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:987-994). Cancellation is
  thread-wide; exact-ref targeting is not current behavior. **Verified.**

## Canonical findings

### Confirmed defects (code)

| ID | Finding | Reviewer IDs | Owner seam | Slice | Status |
| --- | --- | --- | --- | --- | --- |
| CF-1 | Clarification interrupts are projected through the approval-only evidence path and raise `KeyError` before channel delivery | G18, F1, HZ-1, H-01, P1, root-cause E | `Worker#settle_paused_view`; `OutboxDeliverySink#decision_evidence`; `clarification_descriptor` | 0 | Verified; open |
| CF-2 | Request-scoped runtime status aggregates delivery/effect state across the whole conversation/thread | F2, H-03, HZ-2 | `CommsStore#conversation_runtime_status`, `delivery_state_for`, `effect_state_for`; outbox row schema lacks `request_id` | 1 | Fixed in `69c4a4d`; deterministic comms/effect coverage passes |
| CF-3 | `/cancel` and CLI cancel are thread-wide; no exact-reference target | F3 | `gateway_commands#cancel_request`; `CommsStore#stamp_cancellation_requested!`; `CLISessionCommands` cancel | 1 | Chat `/cancel` fixed in `7aaea8c`; CLI cancel remains open |
| CF-4 | No durable ingress for a clarification answer; plain text is admitted as a new request and callbacks resolve approval only | H-02, consolidated correction 3 | `Comms::Commands`; `Comms::Admission`; `Gateway::Callbacks` | 0→1 | Sourced; open |
| CF-5 | Callback `observed_at` is derived from top-level `message.date`, which is absent on callback-only updates, yielding epoch timestamps | F8 | `Telegram::Normalizer#normalize` | 1 | Sourced; open; **was not in consolidated study/index/roadmap** |
| CF-6 | CLI test exits 0 while an unhandled background `CheckpointConflictError` is raised from a worker thread; the CLI rescue only covers the calling path | G16, F9 (impl) | `CLI#run` rescue scope; `CheckpointStore#open_writer`/`lease_operations` | 1 | Sourced; open; **was not in consolidated study/index/roadmap** |

### Evidence and governance gaps

| ID | Finding | Reviewer IDs | Owner seam | Slice | Status |
| --- | --- | --- | --- | --- | --- |
| EG-1 | Benchmark readiness is fail-open: required surfaces default to Telegram-only for 5 scenarios and unavailable metrics are filtered before the ready decision | G2, G17, F2 (impl), H-05, P7 | `OpenclawCommsRunner` `SURFACES_DRIVEN`/`metrics_ready?` | 4 | Sourced; open |
| EG-2 | The canonical "CLI" leg bypasses the real CLI (argv/process/stdout/exit) via a direct `durable_runner.submit` | G3, F3 (impl) | `OpenclawCommsFixture#submit_cli_task`; reuse `OpenclawDurableCliAdapter` | 4 | Sourced; open |
| EG-3 | C2/C4/C8 drivers execute reduced fixture moments, not real slow-liveness, process restarts M1–M6, or runner-observed cancellation | G8, G9, G10, F5 | `OpenclawCommsRunner` scenario drivers; oracles | 4 | Sourced; open |
| EG-4 | B0 has no independent observability witness; the second "witness" is another fixture-side view of the same run | G14, F6 | `OpenclawCommsRunner` artifact | 4 | Sourced; gap |
| EG-5 | No real-provider + real-Telegram run with durable receipts exists | G1, G13, F6, HZ-6 | Track-B executor; `Telegram::Transport`; provider config | 4 | Gap |
| EG-6 | No perceived-usefulness, comprehension, trust, or answer-quality instrument exists | G15, usefulness finding, P8 | Track-B study protocol | 4 | Gap |
| EG-7 | Benchmark doc state is contradictory (front matter INCOMPLETE vs index READY vs runner) and impl-plan prose cites nonexistent `tamoz-evals` paths; the existing `OpenclawDurableCliAdapter` is the real owner | G17, F9 (impl) points 2–3 | scenario front matter/index/README; benchmark-protocol docs | 4 (pre-work) | Sourced; open; **path-reconciliation not in roadmap** |

### Contract and design gaps (not yet code defects)

| ID | Finding | Reviewer IDs | Owner seam | Slice | Status |
| --- | --- | --- | --- | --- | --- |
| DG-1 | Request handles diverge across surfaces (Telegram `r<ref>`, CLI UUID/thread, `comms request` `R<ref>`); no portable operator handle | G4, G5, F6, H-04, P2 | Gateway admission ack; `CommsStore#requests_by_reference`; CLI queue/ask/status | 1 | Sourced; open |
| DG-2 | Worker availability is not a durable fact; "accepted" cannot be distinguished from "queued, no worker" | F5, F7, G4 (arch), M-01, P3 | Gateway admission/status; worker claim/health; launcher | 1 | Fixed in `f0ad6ba`; queue-age state covered; process liveness intentionally unclaimed |
| DG-3 | The human projection (bounded card) has no frozen semantic payload; the "safe goal label" has no deterministic framework-owned producer or redaction contract | H-06, F8 (impl), consolidated correction 4 | `OutboxDeliverySink`; `Gateway::StatusProjection`; `SessionStatusProjection`; CLI rendering | 2 | Gap |
| DG-4 | Core envelope validation and `SurfaceDescriptor` are Telegram-closed; `Comms::Transport` has no typed capability matrix | F7, G2/G3 (arch), scale-5 | `InboundEnvelope`; `SurfaceDescriptor`; `Comms::Transport` | 5 (prereq) | Sourced; deferred |

### Medium interaction gaps (kept as product hypotheses)

| ID | Finding | Reviewer IDs | Disposition |
| --- | --- | --- | --- |
| MG-1 | "Since you were away" needs a read cursor/snapshot boundary | M-02 | Slice 3; define cursor or use neutral wording |
| MG-2 | Target states need a frozen mapping to `Comms::Lifecycle` states | M-03 | Slice 2; publish and test one mapping table |
| MG-3 | The attention budget is copy, not an enforced mechanism | M-04, scale-2 | Slice 3; keep as measured hypothesis, do not build a second event system |
| MG-4 | Human CLI streaming drops task/update/checkpoint parts | G6, F9 (arch) | Slice 2; route both surfaces through the shared projection |

## Findings this ledger rescued

Three findings were confirmed by reviewers but never carried into the
consolidated study, evidence index, or roadmap. They are now tracked above and
added to the evidence index and correction log:

1. **CF-5** callback timestamp defect — must be fixed before any callback-ack
   or latency telemetry is trusted (Slice 1, gates EG-3/EG-5 timing claims).
2. **CF-6** swallowed async `CheckpointConflictError` — a reliability defect
   that lets the CLI report success while a worker thread failed (Slice 1).
3. **EG-7** stale benchmark implementation paths and the un-named existing
   `OpenclawDurableCliAdapter` owner — reconcile before Slice 4 to avoid
   building a duplicate CLI harness.

## Sponsor-directed interaction findings (2026-08-27)

Added after the sponsor identified the felt gap as broken/awkward interaction
and named specific flows. These are requirements, grounded in traced source,
that were not in the original reviews.

| ID | Finding | Owner seam | Phase | Status |
| --- | --- | --- | --- | --- |
| SD-1 | Every admitted message runs the task lifecycle; a conversational/read-only turn is not answered directly, so it can traverse deliberate planning | `RequestRoute#direct_chat_candidate?`; `Gateway::Admission#route_direct_chat`; `Runtime#respond` | 0b | Fixed; commit `4c786b1`; deterministic direct-chat benchmark and independent B1-B8 review pass |
| SD-2 | An "Accepted … I will report progress" ack can be followed seconds later by `PlanRejectedError` → `crashed_text` after `max_plan_attempts` (3); a failed plan dead-ends instead of asking | `AdmissionAcknowledgement#accepted_reply`; existing worker plan-failure path | 0b | Fixed; commit `b433138`; bare receipt has no progress promise and impacted admission-path suites pass |
| SD-3 | The comms per-round context contract (what each turn sends; what a resumed/clarified/chat turn sees) is not specified on top of the model-call boundary | `docs/model-call-boundary-review-2026-08-26/`; worker/session context assembly; history invariant | 0b→2 | Sourced; open |

## Hard-zero invariants (unchanged, carried forward)

These are preserved by every slice and are never traded for interaction
improvements: model proposes / policy decides; all external and
nondeterministic work stays behind `EffectDispatcher`; request/decision/delivery
ownership and fence checks remain authoritative; `unknown` is never silently
converted to `delivered` or blindly retried; only confirmed terminal content
enters conversation history; channel capabilities cannot broaden approval
authority; fixture output is never intelligence evidence.

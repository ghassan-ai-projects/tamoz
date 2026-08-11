# Gap Analysis — Tamoz Agent Improvement Plan

Review date: 2026-08-11. Method: compare the committed plan against the current
agent, comms, Telegram, observability, durability, public API, gate, and evaluation
surfaces. This is a coverage review: it asks what the plan failed to specify, not
whether its preferred architecture is elegant.

## Verdict

The plan covers the dominant latency and completion failures, but the prior revision
left nine material implementation gaps. The critical and high gaps have been folded
into [`FINAL_PLAN.md`](FINAL_PLAN.md). Three owner decisions remain deliberately open:
direct-response outcome semantics, durable graph compatibility, and the cross-gem
delivery/command contracts.

## Gap register

| ID | Severity | Missing or underspecified area | Consequence if ignored | Plan correction |
|---|---|---|---|---|
| G1 | Critical | `direct_response` had no honest success semantics | A model-selected shortcut could become evidence-free `satisfied: true`, recreating the false-success defect the scorecards forbid | Section 3.5 now requires `responded` versus verified `completed`, forbids synthetic evidence, and adds an owner checkpoint |
| G2 | Critical | The model's own route statement was treated as proof that no work was needed | Routing and answering are performed by the same untrusted component; a bad answer could self-authorize the shortcut | Route is explicitly not evidence; adversarial routing must never claim task completion, and automatic rollout remains experimental |
| G3 | High | Public `Result` compatibility was described as an "optional" `Data` member | `Data.define` members are constructor-visible API; adding one can break callers and pattern matching | Slice 3 now preserves the member list where honest, otherwise requires an explicit migration |
| G4 | High | Conversation follow-ups and memory were absent from the direct path | "What about Germany?" loses the prior subject; fast chat becomes fast but worse | Initial fast path is self-contained only; anaphora falls back until bounded, provenance-carrying context is designed |
| G5 | High | Route calls were outside explicit worker budgets and retry accounting | Malformed routing plus fallback could spend an extra unmetered call or cross a ceiling | Route calls share model/token/time/cost budgets; boundary and restart tests were added |
| G6 | High | Global provider promotion assumed route JSON quality transfers between models | A weak or differently formatted configured model could become unsafe or loop on fallback | Qualification and promotion are per provider/model role; unknown roles use legacy behavior |
| G7 | High | The delivery drainer had no complete durable retry state machine | `retry_after` could live only in sleep/process memory; restart could hot-loop or ignore claim expiry | Slice 6 now requires explicit durable transitions/deadlines before extraction and a cross-gem checkpoint if schema is needed |
| G8 | High | Ack, progress, and terminal ordering was not defined | A quick answer could be followed by a stale "Working on it" message | Per-conversation ordering/coalescing and a concurrent fast-completion test are required |
| G9 | High | Drainer concurrency ignored configured Telegram rate limits | Faster delivery can create throttling, starvation, or unfairness across chats | Slice 6 now owns per-chat/global pacing and restart tests |
| G10 | Medium | One-shot observability had no recorder construction or join key | Signals could be unjoinable or require hidden global state | Slice 1 must define explicit recorder/correlation injection for ephemeral `Runtime` |
| G11 | Medium | "Exactly one user-facing terminal message" exceeded what the system can prove | Network ambiguity means durable intent does not prove visibility | Acceptance and definition-of-done now require one durable intent and honest unknown outcomes |
| G12 | Medium | Second discovery was named but its trigger taxonomy was not | Generic repairable tool failures could become accidental discovery loops | The remaining implementation must define a closed typed missing-evidence source before slice 4; otherwise the second pass is removed |
| G13 | Medium | Shadow evaluation did not say how direct-answer quality is judged | Route precision could pass while answers are useless | Slice 0/5 evidence must grade route correctness and direct answer usefulness separately |
| G14 | Medium | Channel control capacity and terminal reservation were covered, but surface revision changes were not | Old queued control rows could be rendered under changed policy | Slice 7 tests must pin the surface revision carried by each delivery and refuse silent reinterpretation |

## Requirements coverage

| Concern | Covered by | Remaining decision |
|---|---|---|
| Simple latency | Slices 0, 1, 3, 5 | Meaning of successful direct response |
| Read-only completion | Slice 4 | Closed `missing_evidence` taxonomy |
| Mutation authority | Existing action pipeline + slices 3/4 tests | None; must not relax |
| Durable compatibility | Slice 4 spike | Whether v1 can resume directly or needs version selection |
| CLI liveness | Slice 2 | Exact TTY rendering is implementation-local |
| Terminal truthfulness | Slices 2 and 8 | Safe reason vocabulary |
| Telegram latency | Slice 6 | Cross-gem drainer/store contract |
| Telegram controls | Slice 7 | Typed command-intent contract |
| Delivery ambiguity | Slices 6/7 | Operator reconciliation UX |
| Conversation context | Slices 0/4 tests | Provenance-carrying direct context deferred |
| Budgets/cost | Slices 1, 3, 4 | Provider usage availability remains conditional |
| Observability | Slice 1 | Ephemeral correlation shape |
| Evaluation/rollout | Slices 0, 5, 9 | Provider qualification ownership |

## Missing-evidence decision required in slice 4

The current taxonomy has `ToolArgumentError#repairable?`, but "repairable" is
broader than "another discovery pass can produce the missing fact." The coding
agent must not match error text such as "not found." Before implementing the second
discovery pass, choose one of two safe options:

1. Add a narrow typed outcome whose contract states that discovery can supply the
   missing identifier/path, with tests for every producer; or
2. Remove the second discovery pass and stop truthfully after the first
   evidence-scoped plan fails.

A generic repairable tool error is not an acceptable trigger.

## Sequencing corrections

1. Repair the pre-existing scorecard and documentation gates.
2. Establish measurements and terminal truthfulness.
3. Accept direct-response outcome semantics.
4. Prove ephemeral routing.
5. Qualify provider/model roles in shadow mode.
6. Accept durable compatibility and implement durable routing.
7. Accept and implement independent delivery.
8. Add acknowledgements and commands only after outbound ordering is proven.
9. Add partial progress last, derived from committed facts.

This order prevents UX output from becoming a second source of truth and prevents a
fast but semantically ambiguous direct path from entering durable sessions first.

## Exit for the gap-analysis review

The plan is ready for slice 0 and slice 1. Slice 3 is blocked on the direct-response
outcome decision. Slices 4, 6, and 7 remain blocked on their named owner checkpoints.
No other uncovered issue requires a new subsystem.

# Review of the Initial Improvement Plan

Review date: 2026-08-11. Scope: compare the initial synthesis with the current
`main` implementation and raise the plan to an implementation-ready standard.

## Verdict

The investigation identified the right user symptoms and the dominant latency
source. The initial plan was not safe to hand directly to a coding agent. It mixed
verified gaps with stale implementation claims, proposed more request classes than
the lifecycle needs, omitted durable graph compatibility, and recommended retrying a
delivery outcome that the current design correctly treats as irreconcilably unknown.

The replacement [`FINAL_PLAN.md`](FINAL_PLAN.md) keeps the evidence and changes the
implementation strategy.

## Findings and resolutions

| Severity | Finding | Evidence in current code | Resolution in final plan |
|---|---|---|---|
| Critical | Blind retry of Telegram ambiguous sends can duplicate messages | `Telegram::Client` raises `AmbiguousDeliveryError` after an uncertain send; `CommsGateway` persists `unknown`; autonomy case 15 pins no retry | Preserve `unknown`; independently drain only pending rows; retry only proven-not-sent outcomes; require explicit reconciliation |
| Critical | Durable route/state changes had no compatibility plan | `Session::GRAPH_VERSION`, node implementation versions, checkpoint recovery, and legacy-resume tests form a durable protocol | Mandatory compatibility spike and v1/v2 selection before durable routing |
| High | The plan described discovery as entirely absent | `Runtime#run_action_mode` and `SessionLifecycle#completion_update` already implement discovery -> action | Reuse that lifecycle; add the missing read-only discovery path only |
| High | Five request classes add decisions that do not select authority or execution | `bounded` vs `complex` is unknowable before discovery; current authority is capability-bound | Three routes only: direct, read-only work, managed action |
| High | A separate classifier would miss the one-call latency target | Every model call is sequential and currently non-streamed | Fuse route and direct response; reuse the returned discovery plan for work |
| High | Automatic routing had no false-success rollout gate | Existing scorecards treat false success and unsafe actions as hard-zero failures | Shadow first; zero unsafe direct routes required before promotion; legacy kill switch |
| High | The plan said observability producers were absent | Observability gem, catalog, journal, worker producer, trace, metrics, and doctor are present | Add only model/tool/turn/comms producers; reuse existing infrastructure |
| High | Outbox decoupling lacked concurrency ownership | Current gateway owns poller lease, delivery claims, one adapter, and one transport | Separate drainer with its own store connection and client; preserve claims and receipt ordering |
| Medium | Typing was described as an unused existing capability | Transport seam allows signals; Telegram implementation supports only callback `:ack` | Durable accepted control is primary; typing is optional best-effort supplement |
| Medium | Command work ignored the current reduction of command identity | `Commands` parses a closed table, while `Admission::Decision` returns generic `:control` and nil reply | Reviewed typed command intent across the comms boundary |
| Medium | Partial progress risked becoming narrated state | Committed observations and effect receipts already provide the durable facts | Derive progress only from committed receipts; never set partial work satisfied |
| Medium | Stop disclosure was framed as raw reviewer feedback | Current code intentionally hides semantic/protocol text to prevent leakage | Publish bounded reason classes and safe actionable summaries, never raw feedback |
| High | The committed autonomy scorecard is already red and its failing seams are stale | Case 09 invokes removed `stream publish`; case 10 maps `:effect_started` to a crash after model review | Repair and mutation-prove both public-surface probes in slice 0 before treating the scorecard as a feature gate |
| High | The current everyday gate is already red outside the feature | `DocumentationSurfaceTest` reports undisclosed measured gap ADR-015 | Verify and repair the disclosure baseline in a separate slice-0 commit; never weaken or misattribute the gate |

## Alternatives rejected

### Keep plan/review/verify for every request

Rejected because the measured 3-7 sequential calls are the primary latency source
and the reviewer can reject a trivial plan for being disproportionate.

### Add a cheap classifier call before the existing lifecycle

Rejected as the target architecture. It makes direct conversation at least two calls
and adds latency before every evidence-dependent task. The fused contract can answer
directly or return the first discovery plan.

### Route every read-only request directly

Rejected because many read-only requests require workspace, MCP, or current external
evidence. A direct model has no such evidence and would hallucinate.

### Relax mutation plan concreteness

Rejected. Mutation planning already has a discovery phase. The safety bar for action
steps remains concrete, reviewed, digest-bound, checked, and approved.

### Retry every failed Telegram send

Rejected. A post-send timeout does not prove failure. Without a provider idempotency
key, retrying can create a duplicate visible message.

### Add a general workflow/routing framework

Rejected. Three routes and one bounded discovery repeat can be expressed with current
values, phases, graph branches, and capability binding. A framework would add more
state and failure modes than behavior.

## Review bar applied

The replacement plan was checked for:

- root-cause alignment rather than symptom-only work;
- exact current implementation boundaries;
- authority non-widening;
- durable checkpoint and crash compatibility;
- delivery ambiguity and deduplication;
- observability non-interference;
- test-first slices with measurable exits;
- explicit cross-gem owner checkpoints;
- rollback and stop/redesign criteria;
- coding-agent-sized commits with named likely files and gates.

# 02 — Scenario catalog and scoring

The scenario set is the committed catalog this document specifies: what each
scenario proves, how it is scored, the verdict rule, and the scoreboard that
tracks improvement over time. The catalog derives directly from the study's
required composition tests (`../06-scenario-matrix.md`).

Every scenario runs on **both** surfaces — durable CLI and Telegram — and must
show semantic parity between them. CLI/Telegram drift is itself a measured metric
(`parity`), scored on every scenario.

## The nine canonical scenarios

Each maps to one primary axis from the canonical set in
[01-protocol-design.md](01-protocol-design.md#1-what-trustworthy-communication-means-here)
(a scenario's metrics may also feed other axes — e.g. `parity` is fed by every
scenario). `hard_zero` is the scenario-specific stop set, in addition to the
global stop rules.

| # | Scenario | Primary axis | Passing bar |
| --- | --- | --- | --- |
| 1 | `happy-path` | `identity` | Durable admission before acknowledgement; stable reference; terminal names the same turn; task and delivery state queryable. |
| 2 | `slow-liveness` | `liveness` | Bounded, coalesced running/waiting milestones between accepted and terminal; no silence over the bound; no token stream. |
| 3 | `delivery-fault-matrix` | `delivery_truth` | Pre-send fail retries safely; post-send ambiguity is `unknown`; stale owner is fenced; permanent auth failure is typed and operator-visible; no blind duplicate. |
| 4 | `restart-boundary-matrix` | `recovery` | Restart at each durable boundary preserves reference, sequence, task state, and safe delivery state; no duplicate external send. |
| 5 | `first-contact-and-controls` | `commands` | Unknown sender → clear next action, no turn before binding; exact duplicate and conflicting identity handled; every declared command works; content grants no authority. |
| 6 | `cross-surface-parity` | `parity` | The same turn on CLI and Telegram reaches equal terminal task + delivery outcome; only presentation differs. |
| 7 | `approval-waiting` | `context_integrity` | Waiting state names reason and next action; decision binds to evidence; resume is visible; deny is fail-safe. |
| 8 | `cancellation-states` | `recovery` | Cancellation shows requested → observed → terminal; an in-flight external call is never claimed stopped. |
| 9 | `two-conversation-isolation` | `context_integrity` | References, progress, approvals, and delivery never cross two concurrent conversations. |

## Metric definitions

Executed metrics are in `[0, 1]` unless noted; higher is better except where
marked "(lower better)". A blocked or unavailable measurement carries a typed
`{ "status": "unavailable", "reason": "…" }` value; it is never scored as zero or
success.

| Metric | Definition |
| --- | --- |
| `completion` | The turn reached its terminal task state for the scenario's definition of done. |
| `admission_before_ack` | Durable admission committed before the external acknowledgement was eligible to send. |
| `reference_stability` | The returned request reference is stable and resolves the same turn across status, terminal, and reconnect. |
| `inbound_identity` | Exact duplicate maps to one request; same-ID/different-content becomes a durable conflict; the four Telegram IDs stay distinct. |
| `liveness` | Fraction of the accepted→terminal interval covered by a committed-fact-backed milestone within the silence bound; a fabricated or missing milestone fails it. |
| `progress_bound` | Projected updates per `(request, surface)` stayed within the coalescing bound (lower better beyond the bound). |
| `delivery_axis` | Task state and delivery state were reported independently and correctly at the terminal. |
| `unknown_preservation` | An ambiguous send was recorded and reported as `unknown`, not coerced to success or plain failure. |
| `no_blind_retry` | No duplicate external send followed an `unknown` outcome. |
| `owner_fencing` | Only the current owner/fence/attempt crossed a send boundary or recorded a result. |
| `cancellation_honesty` | Cancellation showed requested → observed → terminal, with no false "stopped" for an in-flight call. |
| `restart_safety` | Restart preserved reference/sequence/task state and produced no duplicate effect or terminal delivery. |
| `command_parity` | The command grammar and handlers agree; every declared command executed; no phantom command. |
| `context_inclusion` | Only confirmed successful terminal deliveries entered conversation history; progress/control never did. |
| `authority_stability` | Message/callback content did not expand authority, alter a plan, or forge approval. |
| `parity` | CLI and Telegram reached semantically equal outcomes — equality of terminal task state and delivery outcome, never text similarity of the emitted messages. |
| `isolation` | No reference, progress, approval, or delivery crossed two concurrent conversations. |
| `latency_to_ack` | Wall time from submission to the durable-admission acknowledgement (reported). |
| `latency_to_terminal` | Wall time to the terminal task state (reported). |
| `update_count` | Number of projected lifecycle updates for the turn (reported; lower better among equal outcomes). |

Cost metrics (`latency_to_ack`, `latency_to_terminal`, `update_count`) are
**reported** on every run and are only a *tie-breaker* in the verdict — a system
is not more trustworthy for being faster if it is less correct, but among correct
systems, lower cost wins the cost axis.

## Per-scenario scoring record

Each scenario emits a record binding the metric values above to the run's build,
surface, and run_kind. The oracle for each scenario is **deterministic and
controller-owned**: it scores the durable request/session/effect/outbox records,
the emitted milestone stream, and the delivery receipts — never the model's or the
correspondent's self-report. A scenario whose oracle cannot be computed is
`blocked`, not scored.

## Verdict rule

The report emits a **per-axis verdict**, never a single scalar. For each canonical
axis A:

- `go` — on the real (Track B) cells feeding A, every scenario's metrics meet the
  passing bar across the stated sample count, **and** every control passed,
  **and** the readiness result is publishable, **and** no hard-zero fired in A's
  cells.
- `negative` — a real run shows the axis's passing bar is not met.
- `inconclusive` — any of: a fixture-only result, unpassed controls, an
  under-sampled axis, a readiness block, or a hard-zero.

Two qualifications keep the verdict honest:

- **A hard-zero is a failed run, not missing data.** It invalidates its run and
  blocks publication; the report names the fired rule so a failed run is never
  mistaken for an under-sampled one.
- **Claim tiers.** A green Track A composition is a **floor claim** — the contract
  holds under a deterministic provider and fake transport. It is a plumbing gate,
  never a usefulness claim. The **experience claim** ("responsive/trustworthy on
  axis A") requires Track B: a real provider and a real transport, with the sample
  count stated.

## Longitudinal scoreboard

The scoreboard is what makes "improve over time" real. It is a single committed,
append-only file that a later change cannot silently regress.

Suggested location:
`documentation/benchmark/scoreboard/COMMUNICATION_SCOREBOARD.json` (new; owned by
the benchmark, regenerated by its command — never hand-edited).

Each accepted `real` run appends one entry:

```json
{
  "date": "2026-09-01",
  "git_revision": "…",
  "protocol_sha256": "sha256:…",
  "provider": "openrouter",
  "model": "deepseek/deepseek-chat",
  "provider_model_version": "…|null",
  "transport": "real|recorded-live",
  "run_kind": "real",
  "artifact_root": "real/2026-09-01-<sha>",
  "sample_count": 1,
  "axes": {
    "identity": 0.0,
    "liveness": 0.0,
    "delivery_truth": 0.0,
    "recovery": 0.0,
    "parity": 0.0,
    "commands": 0.0,
    "context_integrity": 0.0,
    "cost": 0.0
  },
  "axis_verdicts": { "<axis>": "go|negative|inconclusive" },
  "hard_zero_fired": [],
  "notes": "one bounded sentence"
}
```

Rules:
- append-only; entries are never edited or deleted (a correction is a new entry
  referencing the prior `artifact_root`);
- `axes` carries the eight canonical axes and nothing else; values are normalized
  to `[0, 1]`, higher-is-better, with `cost` stored inverted (`1 −
  normalized_cost`) and raw cost kept in the run artifact;
- `axis_verdicts` carries the per-axis verdicts of the run — there is no run-level
  scalar verdict;
- the regression gate reads the referenced `artifact_root` and fails when the
  newest run drops an axis below the prior accepted run **without an explicit,
  reviewed note** — so a real regression is acknowledged, not hidden;
- `fixture` runs never append to the scoreboard.

## Relationship to the composition tests

The deterministic Track A composition tests stay the per-commit regression gate:
they prove the machinery admits, fences, projects, and recovers correctly. The
scoreboard here is the per-release **experience trend**. The two are complementary
and must never be conflated: a green composition suite is not a scoreboard entry.

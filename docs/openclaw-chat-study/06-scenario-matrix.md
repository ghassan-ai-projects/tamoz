# Communication scenario matrix

This matrix is the practical quality bar for the redesign. “Current evidence”
means a source or test was found during the review; it is not a claim that the
entire composed path was executed successfully in this pass.

Confidence follows the report bar: high means directly supported by source and
focused tests, medium means supported but with an important unverified seam,
and low means an inference or an unrun live behavior.

| Scenario | Tamoz current evidence | User-visible gap | Target acceptance | Primary owner | Confidence |
| --- | --- | --- | --- | --- | --- |
| First contact / pairing | Admission and pairing tests cover unknown sender and operator approval (`test/comms_admission_test.rb`, `test/comms_cli_ops_test.rb`) | Confirmed: no production challenge-issuance path — the gateway ignores `pairing_pending` senders, and `tamoz comms pair approve` only verifies an existing challenge; no full unknown → challenge → approval → retry journey | User receives a clear next action; no task runs before binding; approval/retry retains identity | Admission + pairing + Gateway | Medium |
| Unauthorized sender | Admission and autonomy tests assert no turn/no answer for unbound sender | User-facing refusal and support path are not one shared contract | Refusal is deterministic, bounded, non-leaky, and does not enqueue work | Admission | High |
| Normal short request | Scorecard and CLI tests cover fake model execution and terminal output | Telegram and CLI do not expose the same accepted/running/terminal identity | Receipt has reference; terminal result names the same task; task and delivery state are queryable | Shared projection | High for plumbing; low for live usefulness |
| Slow request | Queue/lease tests and CLI paths exist | Telegram is silent while worker runs; CLI hides many progress events | User sees accepted, running or waiting, and terminal state; updates are bounded/coalesced | Worker sink + renderers | High for gap; target unverified |
| Long response | `OutboxDeliverySink` and rendering tests cover splitting and bounds | No composed restart test for ordered chunks; truncation lacks an actionable continuation reference | Chunks are ordered, bounded, deduplicated, and context includes only confirmed delivery | Outbox + transport + context | High for local bounds; medium for composition |
| Tool execution | Effect and session kill-matrix tests cover durable effect behavior | Tool phases are not projected as useful, safe progress; raw tool output must not leak | User sees semantic phase or wait, never secrets or internal lease details; replay uses receipt | SessionEffects + projection | High for journal; medium for UX |
| Approval required | Session and evidence-gated approval tests cover binding and deny behavior | No complete surface journey from prompt to decision to resumed task | Waiting state names reason and next action; decision binds to evidence; resume is visible | Approval + Gateway + renderer | High for safety; medium for end-to-end UX |
| Cancellation requested | CLI SIGINT and Telegram cancel enqueue paths exist | Requested, observed, and terminal cancellation are not clearly separated; external calls may continue | User sees requested → observed/blocked → stopped or completed; no false “cancelled” claim | DurableRunner + status projection | High for mechanism; medium for visible behavior |
| Duplicate inbound request | SQLite inbox idempotency and scorecard tests exist | Telegram same-ID/different-content integrity is not checked; user receives no stable duplicate reference | Exact duplicate maps to one request; conflicting payload becomes a durable integrity refusal | Normalizer + CommsStore | High for exact duplicate; medium for conflict |
| Worker restart | Request inbox and checkpoint tests cover stale recovery and replay | No full poll → worker → outbox restart matrix; Telegram user cannot see recovery | Recovered request preserves reference, sequence, task truth, and safe delivery state | Inbox + worker + outbox | High for components; low for composition |
| Provider failure | Profile machinery, kill-matrix, and CLI failure tests exist | No fixed cross-surface outage reason/next-action contract | Known provider failure is terminal with bounded reason and retry guidance; ambiguous effects stay unknown | Session + reason registry | Medium |
| Telegram delivery timeout | Transport, drainer, and CLI ops tests cover timeout/unknown concepts | No verified live send-boundary result; stale-owner fence path is untested | Post-send ambiguity is `unknown`, never blind retry; task state remains separate | DeliveryDrainer + CommsOutbox | High for intended model; medium for correctness until fence test |
| Telegram callback | Callback parsing and callback binding tests exist | `Transport#signal(:ack)` has no confirmed Gateway call site; spinner may remain | Callback is acknowledged immediately, then prompt activation and decision are durable | Telegram Gateway + drainer | Medium |
| `/status` during work | Current status returns task/phase/event/effect/capability/delivery/next fields from durable facts (`CommsStore#conversation_status`, `CommsGateway#status_text`) | No request reference, no rendered terminal reason, no queue position/age, no per-reference query, internal vocabulary | Caller-bound status returns one request or an explicit list with task/delivery state and next action | CommsStore + status projection | High |
| `/new` / `/redirect` / `/whoami` | Commands are listed as known; only help/status/cancel are implemented | Known commands fail as unavailable | Registry and handlers are identical; each command has auth, persistence, rendering, and tests | Commands + Gateway | High |
| Context reset/compaction | No current implementation or scenario tests; bounded history exists | Users cannot control context or understand what the model can see | Typed controls define session generation/history effects and expose an audit-safe result | Session + command layer | High for absence |
| Two concurrent conversations | Worker/session operation tests cover some separation | No full concurrent Telegram isolation test; shared process assumptions remain | Requests, refs, progress, approvals, and delivery cannot cross conversations | Routing + worker + outbox | Medium |
| Ephemeral vs durable CLI | Both paths exist and tests cover each independently | Bare CLI feels like chat but is not durable or equivalent to `ask --session` | Help and output clearly identify mode; durable chat uses one lifecycle contract | CLI entrypoint | High |
| Operator recovery | CLI ops include unknown/reconcile concepts | User status does not expose safe recovery handle; internal IDs are cumbersome | Operator command is exact, bounded, auditable, and never an automatic ambiguous retry | CLICommsOps + status | High |

## Required composition tests

The current suite has valuable component coverage but lacks these end-to-end
contracts. They should become the implementation gate rather than relying on a
collection of isolated tests.

### 1. Canonical Telegram happy path

Use real SQLite stores, a fake transport, a deterministic test provider, and the
real Gateway/Worker/Drainer seams. Assert:

- admission is committed before the acknowledgement is eligible to send;
- the acknowledgement contains a stable request reference;
- worker execution produces a terminal task state;
- terminal delivery is ordered and linked to the same reference;
- successful terminal output alone enters conversation history;
- `/status` reports both task and delivery state.

### 2. Delivery fault matrix

Inject failure before send, after send with unknown result, stale ownership after
takeover, and permanent authentication failure. Assert no blind duplicate,
correct owner fencing, explicit unknown state, typed operator action, and no
false assistant context.

### 3. Restart boundary matrix

Restart after inbound persistence, after acknowledgement enqueue, after worker
claim, after effect receipt, after terminal outbox enqueue, and after transport
send ambiguity. Assert stable references, replay safety, correct task state, and
delivery state.

### 4. First-contact and control journey

Exercise unknown sender, challenge/approval, exact duplicate, conflicting
Telegram identity, `/status`, `/cancel`, `/new`, `/redirect`, and `/whoami`.
Assert closed command grammar and no authority expansion from message content.

### 5. Cross-surface parity

Run the same durable request through Telegram and durable CLI. Assert shared
state vocabulary, request identity, terminal reason, cancellation semantics, and
context inclusion rules. Presentation may differ; meaning may not.

### 6. Real usefulness evidence

After plumbing gates pass, run a real provider through the supported user path.
Record latency, visible lifecycle updates, answer quality, and recovery behavior
separately from fake-provider tests. A deterministic fixture proves plumbing; it
does not prove that the chat is useful.

## Pass/fail interpretation

- A component test passing does not pass its composed scenario.
- A visible message does not prove the task succeeded.
- A terminal task does not prove the correspondent saw it.
- An `unknown` delivery is not a retryable failure without reconciliation.
- A clean static review does not prove Telegram API behavior.
- A real-provider answer is evidence of that run, not a general guarantee.

The matrix is complete only when every high-priority row has a named test or a
documented, deliberate non-goal. Rows marked medium or low confidence need
runtime evidence before product claims are made.

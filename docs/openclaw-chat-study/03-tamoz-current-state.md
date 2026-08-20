# Tamoz communication: current state and root causes

## Executive conclusion

Tamoz already has the durable machinery needed for trustworthy chat:

- atomic inbound admission and request enqueue;
- deterministic conversation-to-thread routing;
- SQLite request inbox and checkpointed sessions;
- worker leases and crash recovery;
- model/tool calls through `SessionEffects` and `EffectDispatcher`;
- a bounded, paced outbound outbox;
- explicit `unknown` outcomes for ambiguous sends;
- evidence-bound approvals and deterministic rendering.

The main problem is not that Tamoz cannot execute safely. It is that Telegram
and CLI users cannot see one coherent lifecycle. The system knows the difference
between admission, execution, effect state, terminal outcome, and delivery state,
but those facts are split across worker events, session views, request records,
effect journal rows, outbox rows, and operator-only commands.

## Current lifecycles

### Telegram

```text
Telegram getUpdates
  -> Telegram::Transport#poll
  -> Telegram::Normalizer#normalize
  -> Comms::Admission.decide
  -> CommsGateway#serve_once / #admit
  -> CommsStore#admit_and_enqueue
  -> SQLite request inbox
  -> Agent::Worker#claim_and_run
  -> Agent::Session graph
  -> SessionEffects / EffectDispatcher
  -> Worker#settle
  -> OutboxDeliverySink
  -> CommsOutbox / DeliveryDrainer
  -> Telegram::Transport#deliver
```

The gateway owns Telegram credentials, admission, normalization, routing,
control handling, and outbound draining. It deliberately does not construct a
session, load a model, open a toolbox, or read workspace files. That boundary is
correct and must remain.

### Durable CLI

```text
tamoz ask / tamoz --session THREAD TASK
  -> CLI authority/profile resolution
  -> SQLite-backed Agent::Session
  -> request inbox / DurableRunner
  -> SessionEffects / EffectDispatcher
  -> local StreamSink and CLI renderer
  -> durable terminal SessionView
```

The durable CLI supports `ask`, `resume`, `continue`, `follow-up`, `redirect`,
`cancel`, `resolve`, `show`, and `list`. Its exit taxonomy is explicit and
tested: success, incomplete, paused/blocked, fatal, usage, and signal exits.

### Ephemeral CLI

```text
tamoz TASK
  -> Agent::Runtime
  -> direct model/tool path
  -> local event rendering
  -> final answer
```

This path is intentionally ephemeral. `Runtime#model_generate` and the runtime
tool path do not use the durable `SessionEffects` journal. It must not become the
backend for Telegram or durable chat.

## What is already strong

### Admission and identity

`Comms::Admission` enforces disabled, allowlist, pairing, private-chat, typed
command, and callback policy. It deterministically maps a surface and
conversation to a thread. `CommsGateway#admit_request` binds the profile,
conversation, and correspondent before enqueueing work. Untrusted messages do
not choose a profile, model, root, tool, budget, or schedule.

Evidence:

- `gems/tamoz-comms/lib/tamoz/comms/admission.rb`;
- `gems/tamoz-agent/lib/tamoz/agent/comms_gateway.rb`;
- `test/comms_admission_test.rb`;
- `test/autonomy_scorecard_test.rb` (`test_case_14_an_unbound_sender_never_reaches_a_turn`).

### Durable request execution

`CommsStore#admit_and_enqueue` commits inbound disposition, request identity,
payload, bounded history, reservation, and request-inbox enqueue in one SQLite
transaction. The request inbox provides FIFO ordering, fenced claims,
idempotency, stale-claim recovery, and redirect operations.

`Agent::Session` uses checkpointed graph phases. `SessionEffects#model_call` and
`#dispatch` route nondeterministic model/tool work through `EffectDispatcher`,
so replay returns the recorded receipt instead of making a fresh call.

Evidence:

- `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb`;
- `gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_*.rb`;
- `gems/tamoz-agent/lib/tamoz/agent/session_effects.rb`;
- `gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb`;
- `test/sqlite_request_inbox_test.rb`;
- `test/agent_session_kill_matrix_test.rb`.

### Delivery ambiguity

`CommsOutbox` and `DeliveryDrainer` distinguish pre-send retry from post-send
ambiguity. A timeout after the external send boundary becomes `unknown`; it is
not blindly retried. The terminal delivery intent is appended before the worker
closes the occurrence, so a worker crash cannot silently erase a committed
answer.

Evidence:

- `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb`;
- `gems/tamoz-agent/lib/tamoz/agent/delivery_drainer.rb`;
- `test/delivery_drainer_test.rb`;
- `test/tamoz_telegram_transport_test.rb`;
- `test/comms_cli_ops_test.rb`.

### Safety and authority

Tamoz's sealed capability host, trusted profiles, exact effect identity,
evidence-gated approvals, credential-free child environments, and structurally
non-printable secrets are stronger safety foundations than OpenClaw's
trusted-one-Gateway model. Telegram approval is deny-only in the current policy,
which is restrictive but honest.

Evidence:

- `documentation/architecture/security-model.md`;
- `documentation/adr/adr-049-telegram-approval.md`;
- `gems/tamoz-agent/lib/tamoz/agent/capability_binding.rb`;
- `gems/tamoz-core/lib/tamoz/secret.rb`;
- `test/comms_evidence_gated_approval_test.rb`.

## What users currently experience

### Telegram

The normal path is mostly:

1. an accepted or queued control message;
2. silence while the worker runs;
3. a terminal answer, failure, blocked/stopped message, or approval prompt.

The gateway guide explicitly requires two foreground processes. The gateway
admits messages and sends answers, while the worker executes turns and streams
JSON to its own process. Without the worker, messages are admitted but nothing
is answered.

That is an understandable process design but a poor conversation contract. The
user sees the process boundary instead of a live work state.

### CLI

The durable CLI is safe and recoverable but renders only selected human events.
`StreamPart` contains run/task/sequence/time identity, but the JSON renderer
reduces events to `{type, data}` and human mode discards many task, update,
checkpoint, tool, and message events. A user can therefore experience a silent
period even while the durable graph is making progress.

The one-shot path adds a second mental model: it feels like ordinary chat but is
ephemeral, uses a different execution path, and only returns the final answer
after completion.

## Root causes

### 1. Terminal-only channel projection

`OutboxDeliverySink::EVENT_KINDS` covers accepted, approval, terminal, failed,
stopped, and blocked outcomes, but not claimed, running, recovered, phase, or
committed progress events. Worker lifecycle events remain in worker
observability. Telegram therefore cannot distinguish queued, running, waiting,
or stopped after the initial receipt.

This is the primary root cause.

### 2. Status is admission accounting, not a turn read model

`CommsStore#conversation_status` and `CommsGateway#status_text` expose only a
thread, an aggregate state, and open-request count. They do not expose request
identity, queued/running/waiting phase, current graph phase, committed progress,
terminal reason, or outbound pending/unknown state.

The internal state exists in request, session, effect, and outbox records, but no
single safe projection composes it.

### 3. Admission acknowledgement is underspecified

`Accepted. I will report committed progress.` means durable admission. It does
not mean that the worker started, that the model succeeded, or that Telegram
accepted the acknowledgement. Without a request reference, the user cannot
query or correlate that work.

### 4. Command contract diverges from implementation

`Comms::Commands::KNOWN` advertises `/help`, `/status`, `/new`, `/cancel`,
`/redirect`, and `/whoami`. `CommsGateway#handle_command` implements only
`/help`, `/status`, and `/cancel`; the other known commands return that they are
not available. This is a confirmed usability defect. Either implement each
declared command or remove it from the closed grammar.

### 5. Telegram identity evidence is incomplete

`Telegram::Normalizer#digest` hashes only the `update_id`, despite naming the
field `raw_payload_hash`. The store deduplicates on surface, bot, and update ID
without comparing the digest. Same identity with changed content is therefore
silently treated as a duplicate instead of an integrity conflict.

The normalizer also records the quoted message ID as `reply_to` but does not
retain the current message's own Telegram `message_id`. `CommsGateway` uses
`envelope.update_id` as the control reply target. Existing fixtures set
`message_id == update_id`, so they can mask a real Telegram mismatch.

These are high-confidence code/documentation mismatches; the live Bot API impact
still needs a real observation.

### 6. Delivery state can distort conversation history

`CommsStore#conversation_history` intends to include terminal assistant output
that the correspondent saw, but the current terminal-delivery query does not
filter by successful delivery. Pending or `unknown` output can enter a later
model prompt as if the user saw it. That creates conversational drift after a
delivery failure.

### 7. Recovery is below the user interface

Tamoz can recover requests, checkpoints, effect receipts, and ambiguous
deliveries. Telegram users cannot see the recovery handle. Operators need
internal delivery IDs and, for some effect cases, a second reconciliation
command.

### 8. Several limits and fences need boundary verification

The safety review identified important correctness items that are separate from
UX polish:

- `DeliveryDrainer#send_row` must not cross the external send boundary after its
  owner/fence transition fails; a stale drainer takeover test is missing.
- `mark_delivery` should carry owner/fence/attempt identity rather than allowing
  a stale caller to mark another owner's row.
- descriptor limits such as `max_open_requests`, `max_inbound_bytes`, and
  `max_response_bytes` must be enforced where resources are admitted, not only
  validated in configuration.
- the drainer needs typed handling for authentication/storage failures so it
  cannot stop without an operator-visible state.
- pairing challenge construction appears to be present in tests/operator paths
  but lacks a confirmed production gateway issuance path; this is a medium-
  confidence static finding that requires a direct runtime check.

## Evidence limits

The second pass inspected source, docs, and named tests. It did not execute the
full suite or a live provider/Telegram flow. A named test in the matrix means
the repository contains that test; it does not mean it passed in this pass.
One reviewer did run focused comms tests and reported them passing; the Telegram
fixture server could not bind localhost in the sandbox (`EPERM`). This is an
environment restriction, not evidence of a product failure.

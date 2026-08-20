# OpenClaw to Tamoz: comparison and priorities

## Executive decision

Tamoz should adopt OpenClaw's communication contract, not its trust model or
runtime. OpenClaw's strongest lesson is that a chat system must make durable
turn identity, liveness, context, interruption, and terminal outcome visible.
Tamoz already has stronger execution and authority primitives. The work is to
project those facts coherently through the existing CLI and Telegram seams.

The first implementation should therefore be a correctness and projection
program, not a new streaming runtime.

## Capability comparison

| Concern | OpenClaw pattern | Tamoz today | Decision |
| --- | --- | --- | --- |
| Inbound identity | Durable update/request identity and deduplication | Durable request identity and inbox idempotency; Telegram digest is incomplete | Adopt the identity contract; fix Tamoz's digest/conflict handling first |
| Admission | Immediate acknowledgement after durable admission | Durable admission exists; acknowledgement lacks a useful request reference | Adopt stable human-readable request references |
| Execution | Shared turn kernel across Gateway, CLI, TUI, and channels | Durable execution is shared by Telegram and durable CLI; ephemeral CLI is separate | Keep durable path shared; label ephemeral path explicitly |
| Liveness | Accepted, queued, running, waiting, progress, terminal states | Mostly accepted plus terminal delivery; worker events are not projected | Add a small closed lifecycle projection |
| Progress | Coalesced previews/progress with channel-specific rendering | Bounded terminal output; no user-facing running/progress projection | Add semantic, bounded progress; do not copy token streaming |
| Context | Explicit status, reset, compact, usage, thinking/verbosity controls | Only `/help`, `/status`, `/cancel` are useful in the chat surface | Implement a small command set in lockstep; defer advanced controls |
| Interruption | Visible cancellation and interrupt events; cooperative semantics | Durable cancellation and SIGINT exist but are hard to observe | Separate requested, observed, and terminal states |
| Delivery | Durable outbox, retry policy, unknown outcomes, Telegram send boundary | Strong outbox and unknown state; stale-owner path needs a fence fix | Preserve architecture; fix stale ownership before more delivery features |
| Safety boundary | Trusted operator Gateway and plugin/host assumptions | Sealed capabilities, approvals, secret isolation, trusted profiles | Do not weaken Tamoz's authority model to match OpenClaw |
| Recovery | Gateway/session/transcript controls and operator recovery | Recovery exists but handles are below the user interface | Expose read-only status and actionable operator references |
| Transcript | Durable transcript and sent-message adoption | Conversation history can treat pending/unknown output as seen | Make successful delivery a context inclusion requirement |
| Observability | Events, Gateway projection, status/context commands | Bounded telemetry but no authoritative user-facing read model | Add a durable projection/read model derived from facts |

## Patterns to carry forward

### 1. One communication lifecycle, many renderers

The same accepted turn should mean the same thing in Telegram and CLI. The
surface can differ—Telegram may use a short status message while CLI uses a
single updating line—but neither should invent independent states.

### 2. A receipt is a contract

The first response must answer “was my request accepted?” and give a stable
reference. It must not imply that work has started or that a final answer is
available. A request reference enables `/status`, support, recovery, and
machine correlation.

### 3. Task truth and delivery truth are orthogonal

`completed + delivery=unknown` is materially different from `failed`.
Collapsing them causes false retries, misleading history, and poor operator
decisions. The status projection must show both axes.

### 4. Progress is semantic and bounded

Users need evidence that a slow task is alive, not a token-by-token transcript.
Project phase changes, waits, and bounded milestones. Coalesce updates and keep
them out of the model's normal conversation context.

### 5. Controls are typed product features

Status, cancellation, reset, routing, and context controls should be parsed
outside the model prompt. Their grammar, authorization, and effects should be
tested as commands, not inferred from natural language.

### 6. Recovery must be honest

Cancellation is a request until the durable runner observes it. An ambiguous
external send is `unknown` until reconciled. The UI should expose the next safe
action rather than promise a result the system cannot prove.

## Patterns to reject or modify

- Do not copy OpenClaw's trusted-one-Gateway assumption into Tamoz's capability
  boundary. Keep profile binding, sealed capabilities, and evidence-gated
  approvals.
- Do not add permissive group or multi-user routing merely because OpenClaw can
  route it. Establish actor isolation and an explicit authorization model first.
- Do not send affirmative Telegram approval commands until the approval
  evidence contract is complete. Tamoz's deny-only posture is safer than a
  misleading approval UX.
- Do not retry after an ambiguous external send. Preserve `unknown` and use
  operator reconciliation.
- Do not persist raw model tokens as the communication contract. Token streaming
  increases rate, ordering, and transcript complexity without answering the
  primary trust questions.
- Do not create a second chat runtime or in-memory authoritative status cache.
  Extend the request inbox, session view, worker notifications, and outbox.

## Priority order

### P0 — correctness at the boundaries

These items protect trust and must precede a richer chat experience:

1. Enforce delivery owner/fence/attempt identity at both send-start and result
   recording; add a stale-drainer takeover test.
2. Hash meaningful inbound Telegram content and make same-ID/different-content a
   durable conflict.
3. Keep Telegram update ID, message ID, quoted message ID, and callback message
   ID distinct.
4. Enforce declared byte, open-request, response, and capacity limits at their
   actual admission boundaries.
5. Add typed drainer handling and operator-visible state for authentication and
   storage failures.

### P1 — make the current system truthful

1. Define the shared lifecycle and reason-code registry.
2. Return a stable request reference in every accepted acknowledgement.
3. Build `/status [reference]` from durable request, session, and outbox facts,
   showing task and delivery state separately.
4. Make the command registry and handlers agree; implement or remove `/new`,
   `/redirect`, and `/whoami`.
5. Exclude pending and unknown terminal messages from normal conversation
   history.
6. Preserve event identity in CLI JSON output.

### P2 — show useful liveness

1. Project claimed/running/recovered/waiting/terminal milestones through the
   existing worker-to-outbox seam.
2. Coalesce and bound progress by request and surface.
3. Render a concise TTY status line and Telegram progress/waiting state.
4. Make cancellation show requested, observed, and terminal transitions.
5. Add a durable/reconnectable status view for CLI follow-up.

### P3 — deepen the conversation model

After the shared lifecycle is reliable, add typed `/new`, `/reset`, `/compact`,
`/usage`, `/context`, `/think`, and `/verbose` semantics. Define their effect on
session generations, prompt history, budgets, and audit records before exposing
them on both surfaces.

## Priority rationale

| Root cause | User consequence | Risk if deferred | First seam |
| --- | --- | --- | --- |
| Terminal-only projection | Silence during useful work | Users resend or assume failure | `Worker#notify_sink`, `OutboxDeliverySink` |
| Missing request reference | Cannot query or report a task | Support and recovery become guesswork | `CommsStore`, admission acknowledgement |
| Shallow status | Task and delivery states are conflated | False success, false retry, context drift | durable status projection |
| Command divergence | Users discover dead controls | Trust in the whole chat surface drops | command registry + Gateway handlers |
| Stale delivery ownership | Duplicate or misattributed external send | Correctness and privacy failure | `DeliveryDrainer`, `CommsOutbox` |
| Incomplete Telegram identity | Wrong deduplication or reply target | Integrity and routing failure | `Normalizer`, `CommsStoreRows` |
| Ephemeral/durable split | Different behavior between CLI modes | Users cannot form a stable mental model | CLI entrypoint/help |

## Evidence and implementation gates

Before calling the redesign complete, require:

- focused unit tests for each P0 invariant;
- a full composition test covering admission, worker, provider result, outbox,
  transport, and restart boundaries;
- a scenario matrix result for normal, slow, approval, cancellation, duplicate,
  restart, outage, and two-conversation isolation;
- a real-provider run for usefulness claims, clearly separated from plumbing
  tests;
- a real Telegram or equivalent transport run for visible liveness and callback
  behavior;
- durable telemetry for queue age, lease recovery, cancellation latency,
  delivery unknown, and dropped projection events.

The current study establishes the design and evidence gaps. It does not claim
that these implementation gates have passed.

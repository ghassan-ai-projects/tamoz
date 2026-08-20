# OpenClaw communication: technical report

## Executive finding

OpenClaw's communication model is a durable state machine with several
projections. Telegram, the Gateway-backed CLI, and the TUI do not each invent a
chat loop. They feed shared admission, routing, turn execution, persistence,
event, and delivery seams, while keeping channel-specific protocol behavior at
the edge.

The essential invariant is:

> A message is accepted into durable work before the external surface is told
> that it was accepted; the resulting run has an identity that survives the
> live connection, and the transcript is available when live events are missed.

This is why the product can be responsive without claiming completion.

## End-to-end lifecycle

### Telegram

```text
Telegram polling/webhook
  -> durable Telegram ingress spool
  -> shared ingress claim, lease, lane, retry, and dead-letter logic
  -> Telegram authorization and logical-message deduplication
  -> channel/account/peer/topic route and session resolution
  -> shared channel turn kernel
  -> embedded agent runner and model/tool loop
  -> Telegram preview/progress/final delivery
  -> durable outbound delivery and Telegram adapter
  -> transcript/sent-message recording and ingress adoption tombstone
```

### Gateway, TUI, and CLI

```text
TUI or Gateway-backed CLI
  -> chat.send validation
  -> session load and route resolution
  -> durable user-turn admission and idempotency claim
  -> synchronous {runId, status: started} acknowledgement
  -> detached agent dispatch
  -> sequenced live agent events
  -> Gateway chat projection and client subscription
  -> durable transcript/session persistence
```

`openclaw agent exec` is a separate embedded, headless path. It is not a
Gateway client and has its own isolated setup, cleanup, timeout, and exit-status
contract.

## Shared architecture

### Durable ingress and adoption

`src/channels/message/ingress-drain.ts` owns generic inbound claim lifecycle:
lease refresh, lane serialization, deferred ownership, dispatch, completion,
retry, watchdog, and dead-letter rules. The critical choice is that completion
happens at turn adoption, not necessarily when model execution and delivery
finish. This prevents a post-adoption failure from re-running a turn with
external side effects.

`src/channels/turn/kernel.ts` and `src/channels/turn/lifecycle.ts` provide the
shared turn path. It covers preflight, admission, drop/handled decisions,
lifecycle events, agent execution, final delivery, fallback, and settlement.

`src/channels/message/durable-delivery.ts` separates successful, suppressed,
partial, failed, and unknown delivery outcomes. Required delivery can insist on
queue persistence and unknown-send reconciliation; best-effort delivery can
fall back to direct sending.

### Routing and session identity

`src/routing/resolve-route.ts` selects an agent using explicit binding
precedence: exact peer, parent peer, wildcard peer, guild plus roles, guild,
team, account, channel, then default agent. It returns the selected agent,
channel/account, DM scope, session key, and match reason.

`src/routing/session-key.ts` creates canonical keys for main, per-peer DM,
per-channel/account DM, group, and topic sessions. Malformed agent-prefixed
keys fail closed. This makes the conversation identity explicit rather than
leaving it to whichever process happens to be handling the update.

### Agent and model loop

`packages/agent-core/src/agent-loop.ts` is channel-agnostic. It transforms
context, streams assistant output, emits assistant/thinking/tool events,
executes tool calls, continues follow-ups, and persists an aborted assistant
outcome when cancelled. Channel delivery, Gateway projection, and CLI/TUI
rendering attach above this loop.

### Persistence and live projection

SQLite session accessors are the runtime persistence boundary for session
metadata, transcript events, lifecycle state, and delivery queues. Transcript
event and message identity indexes deduplicate identified retries without
deduplicating by answer text.

`src/infra/agent-events.ts` provides live per-run sequence numbers and listeners.
`src/gateway/server-chat.ts` projects those events to Gateway clients, merges and
throttles deltas, flushes before terminal events, and broadcasts session changes.
Live events are not themselves the durable transcript; reconnect recovery
reloads history and in-flight state from persistence.

## Telegram implementation

### Durable-before-ack

Polling writes the update to the Telegram spool before advancing the offset.
Webhook validates the secret, durably enqueues the update, and only then returns
HTTP 200 with a durable-acceptance header. A spool failure returns non-200 so
Telegram can redeliver.

### Authorization and deduplication

`extensions/telegram/src/bot-handlers.authorization.runtime.ts` authorizes
before message-cache writes, logical dedupe claims, media download, or agent
dispatch. DM policy supports pairing, allowlist, open, and disabled modes.
Groups have separate chat and sender allowlists, group policy, and mention or
reply activation. DM pairing does not authorize group commands.

There are two dedupe layers:

- update-level tracking for persisted watermarks, in-flight IDs, retryable
  failures, and semantic update keys;
- logical-message dedupe keyed by account, bot identity, chat ID, and Telegram
  message ID, which handles new update IDs replaying an already merged message.

### Context and routing

`resolveTelegramConversationRoute` resolves DM peers, groups, forum topics,
configured bindings, runtime bindings, and topic-level agent overrides.
`createTelegramMessageContext` carries message identity, sender, conversation,
topic, route, reply chain, bounded history, media, commands, and visibility.
Context hydration is cache/observation based; it does not arbitrarily fetch an
unseen Telegram reply chain.

### Commands and callbacks

Native commands use a grammY fast path: command match, fresh config, auth,
route/thread resolution, argument parsing, and command-specific execution.
Callbacks are answered immediately before potentially slow same-chat work,
then routed to approvals, questions, plugins, native commands, or generic
callbacks. This prevents Telegram callback timeout/retry behavior.

### Streaming, progress, and final delivery

`extensions/telegram/src/draft-stream.ts` sends one preview message, edits it
cumulatively with debounce/throttle, finalizes in place, and paginates overflow.
It avoids blindly retrying an ambiguous first send; edits are safer to retry.
Tool starts, command status, reasoning, rolling tool rows, and collapse
summaries can be projected to a progress surface without treating them as
ordinary conversation history.

Final delivery preserves reply/thread metadata and has formatting, caption,
voice, quote, and media fallbacks. Text is chunked below Telegram limits.

### Failure behavior

Polling distinguishes retryable 5xx/429, fatal 401/404, and 409 conflict.
Outbound retries are limited to safe pre-connect failures, rate limits using
`retry_after`, and idempotent edits. A send that may already have been accepted
is not blindly retried. Permanent recipient failures can dead-letter; retryable
dispatch failures release their claims.

## CLI and TUI implementation

The TUI uses one backend contract for Gateway and embedded modes. A submitted
message is rendered optimistically, receives a provisional run identity, and is
re-keyed to the Gateway-accepted run ID in place. The status model distinguishes
`sending`, `waiting`, `streaming`, `running`, `finishing context`, `idle`,
`error`, and `aborted`, with elapsed time and connection state.

The Gateway-backed `openclaw agent` command uses the same `chat.send` protocol,
supports sessions, delivery routing, JSON, model/thinking overrides, and a
stable idempotency key. It acknowledges admission before detached work starts;
an ambiguous transport failure tells the operator to inspect status and the
transcript rather than silently repeating the turn.

The direct `openclaw message send` command is deliberately not an agent turn.
It is a transport operation with explicit target, media, thread, reply,
presentation, and delivery options. This prevents confusion between “the agent
produced a reply” and “the channel accepted the outbound message.”

## Context controls

Commands are handled before normal model dispatch. The shared registry includes
`/status`, `/context`, `/usage`, `/new`, `/reset`, `/compact`, `/think`,
`/verbose`, and `/trace`.

These commands are product-level controls, not implementation trivia:

- `/status` exposes session/context state;
- `/context` explains prompt contributors and cost;
- `/usage` controls token/cost visibility;
- `/think` controls reasoning level;
- `/verbose` controls tool detail;
- `/trace` exposes authorized diagnostics;
- `/new` and `/reset` create or reset session context;
- `/compact` manages context pressure and reports skipped/failed/successful outcomes.

Active-run guards prevent unsafe reset or compaction replacement. The CLI
rejects unsupported inline compaction and points the operator to the session
command that owns it.

## Guards and trust boundaries

High-confidence enforced guards include:

- DM pairing and allowlists;
- group chat and sender allowlists;
- route/session normalization and malformed-key rejection;
- command authorization and mention gating;
- durable ingress claims and stale-claim recovery;
- message and update deduplication;
- tool-policy composition across global/provider/agent/profile/group/sandbox;
- before-tool-call approval hooks with bounded timeout and fail-closed invalid decisions;
- sandbox omission of terminal access;
- payload/body size caps and bounded request timeouts;
- provider idle timeouts and partial-stream handling;
- secret masking and diagnostic redaction;
- reconnect watchdogs and bounded restart recovery.

The documented deployment boundary is equally important: an authenticated
Gateway caller is a trusted operator. Session IDs, channel allowlists, and
session scoping are routing or triggering controls, not hostile multi-tenant
authorization. Separate OS users, hosts, or Gateways are required for mutually
untrusted users. Plugins are trusted in-process code. Host execution is the
default trusted-operator posture; sandboxing is an explicit hardening choice.

## Guarantees and non-guarantees

| Concern | Evidence-backed behavior |
| --- | --- |
| Inbound crash before durable admission | Replayable through spool/claim recovery. |
| Inbound duplicate update/message | Suppressed by persisted update/logical-message identity. |
| Agent turn execution | Durable identity and adoption boundary; not arbitrary exactly-once external effects. |
| Live progress | Sequenced in-process events; reconnect uses persisted state and history reload. |
| Outbound known pre-send failure | Retryable when the adapter classifies it as safe. |
| Outbound unknown-after-send | Not blindly retried; reconciled or failed/dead-lettered. |
| Transcript identity | Stable event/message identities deduplicate identified retries; repeated distinct replies remain visible. |
| Provider quality | Not proven by plumbing tests. |
| Real Telegram path | Mostly tests and fixtures; no single full live conversation proof was found. |
| Multi-tenant isolation | Explicitly not the default trust model. |

## Main tradeoffs

1. Durable-before-ack improves crash safety but adds queues and storage state.
2. Completion at adoption avoids duplicate side effects but may leave post-adoption
   failure to recovery or operator inspection.
3. Conservative unknown-send handling avoids duplicate visible messages but can
   prefer a missing message over an unsafe retry.
4. Live events are fast; durable transcript/history is the recovery truth.
5. Channel-specific complexity stays at the edge, while the turn kernel remains
   reusable across channels.

## Scope limits

The five-agent review was static. No live Gateway, Telegram Bot API, model
provider, or external network run was performed. Deterministic tests support
plumbing and failure-state claims more strongly than perceived usefulness or
real response quality. OpenClaw documentation and source also show at least one
possible version drift around Telegram restart semantics; current source/tests
were treated as stronger evidence than older prose.

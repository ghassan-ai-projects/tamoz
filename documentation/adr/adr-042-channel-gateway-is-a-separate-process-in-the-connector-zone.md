# ADR-042 — The channel gateway is a separate process in the connector zone

**Status:** Accepted 2026-08-10
**Date:** 2026-08-10
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-041](./adr-041-communication-channels-are-a-contract-gem-plus-per-transport-adapter-gems.md), [ADR-049](./adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md) (what a chat identity may decide)

`tamoz comms serve` is the only long-running process that talks to a channel transport. It holds the
transport credential and never holds a model credential, session, toolbox, or workspace. It shares
the runtime SQLite file with the worker so an admission and its request commit together.

## Context

The worker holds the model credential, the toolbox, and the workspace. If it also made outbound
channel calls, a compromise of either side would hold both credentials, and the "connector zone"
would be a diagram, not a boundary.

## Decision

- The gateway admits and normalizes inbound updates, writes their durable disposition, enqueues
  requests, resolves approval callbacks (ADR-049), and drains the delivery outbox.
- It never constructs a `Session`, loads a model credential, opens a toolbox, or reads workspace
  files.
- It and the worker share one SQLite runtime database, so admission and request enqueue are one
  transaction and a replayed update creates no second request.

## Consequences

Each process holds one class of credential. **Cost:** a second long-running process to deploy, and
the shared database means the process boundary separates credentials, not data.

## Invariants

- 56 — a user channel is identified, bound, and grants nothing.
- 57 — channel delivery is ordered, bounded, and ambiguity-safe.

## Threat model

**Asset:** the model credential and workspace (worker side); the transport credential (gateway
side). **Adversary:** a remote chat sender, or code execution in one of the two processes.

| Threat | Mitigation |
|---|---|
| A chat message names a profile, root, or capability | Content cannot set authority; admission binds sender and conversation |
| Compromised gateway steals the model credential | The gateway never loads it |
| Compromised worker sends arbitrary channel messages | The worker has no transport credential — but appending outbox rows makes the gateway send any text to any bound conversation |
| A replayed update runs twice | Admission dedups in the same transaction as enqueue |

**Residual risk:** both processes can write the shared SQLite file. A compromised gateway can write
any runtime table — including approval decisions and requests — directly, bypassing every check in
code. Only OS-level separation (different users, read-only views) would close that, and none exists. Both
credentials come from environment variables, so the credential split holds only if the operator
starts each process with only its own variable set.

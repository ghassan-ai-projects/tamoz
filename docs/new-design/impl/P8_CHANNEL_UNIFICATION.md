# P8 — Channel unification recommendations (owner decision record)

Status: **recommendation — owner decision required**. The three divergences
below are acknowledged, not silently kept. Each has a recommendation and the
decision is recorded here when the owner decides.

## 1. Approval pipelines (stream `ApprovalRelay` vs comms/telegram approvals)

Two approval paths exist:

- **stream**: `Tamoz::Agent::ApprovalRelay` (gems/tamoz-agent) — the policy
  gateway's approval request → relay → approver assertion → `ResolveApproval`.
- **comms**: the telegram/comms channel's own approval flow (evidence-gated
  delivery, `tamoz-telegram`), which surfaces a decision record to a human and
  accepts a reply as the decision.

**Recommendation**: keep the stream `ApprovalRelay` as the SINGLE policy
authority (it is the digest-bound, ledger-verified path the Go validator
fences). The comms channel becomes a *presentation* of the stream's approval
request — it renders the same `ApprovalRequest` and returns the approver's
decision through the relay's signed-assertion protocol. Two approval
authorities means two places a human decision can be lost or forged.

**Decision**: pending owner.

## 2. Decision types (decision-v1 vs comms `DecisionRecord`)

- **decision-v1** (runtime): the canonical signed decision document the Go
  validator consumes — `decision_id`, snapshot digest, intents, digests.
- **comms `DecisionRecord`**: a delivery/UX projection (message id, channel
  reply id, rendered text) that the telegram channel persists.

**Recommendation**: `DecisionRecord` stays a *projection* keyed by
`decision_id` (a foreign key onto the runtime decision, never a second source
of truth). No decision semantics live in the comms record — no risk class, no
intent payload, no authority. If it already carries any of those, remove them
in the next cleanup.

**Decision**: pending owner.

## 3. Auth models (capability token vs subscriber bearer vs bot token)

Three credential models exist:

- **capability token**: per-episode, epoch-scoped EvidenceTools capability
  (the runtime's own capability host) — the worker proves it may call tools.
- **subscriber bearer**: `AGENTIC_STREAM_SUBSCRIBER_TOKEN` — the SSE
  `/v1/events` subscriber identity (a long-lived static token).
- **bot token**: the telegram bot's token for posting/reading messages.

**Recommendation**: keep all three — they authorize different surfaces (tool
calls, event subscription, messaging) and are not interchangeable. The
unification is *naming and lifetime policy*, not a single credential: the
subscriber bearer should be per-consumer with rotation, never shared with the
bot token, and the capability token must stay short-lived and epoch-scoped.
Document the three in one auth model section of the operator guide so no new
surface invents a fourth.

**Decision**: pending owner.

## How this stays visible

While the divergences remain, the duplication is acknowledged — not silent.
This record is the marker; when the owner decides, the decision is recorded
here and the chosen direction is implemented.

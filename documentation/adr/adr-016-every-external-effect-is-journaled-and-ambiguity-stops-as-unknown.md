# ADR-016 — Every external effect is journaled, and ambiguity stops as `:unknown`

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Complete
**Relates to:** [ADR-015](./adr-015-durable-means-synchronous-barrier-commit.md) (why nodes replay), [ADR-021](./adr-021-resume-preserves-execution-identity-fork-changes.md) (the identities effects are keyed by)

Every model call and tool effect goes through one effect journal keyed by the request, with a
declared safety class. A replay returns the recorded receipt. An attempt whose outcome is unknown
and that is not safe to repeat stops as `:unknown` and waits for a human or a reconciler.

## Context

A durable graph replays nodes after a crash or a resume. Anything a node does outside the process —
a model call, a file patch, a message send — happens again on replay unless something remembers it.
Exactly-once delivery of an arbitrary remote effect is impossible without the target's cooperation,
and a blind retry after a timeout can duplicate an irreversible action.

## Decision

- Every non-deterministic or external call inside a node goes through `EffectDispatcher.run`
  (session model calls via `SessionEffects#model_call`, the one-shot runtime via
  `Runtime#model_generate`, tools via the work gate). Calling one raw from a node is a defect.
  Speech synthesis of a message already delivered (the talk channel, ADR-061) is presentation outside
  any node: it feeds no turn and changes no record, so it is not journaled (owner decision, 2026-10-09).
- An effect's logical identity is a digest of the request — request id, operation, capability,
  canonical arguments, authority and catalog revisions, iteration, sub-operation — never of the
  answer. The execution id is deliberately not part of it; a fork differs because it is a new request. Each effect declares a safety class: `read_only`,
  `idempotent`, `transactional`, `reconcilable`, or `unsafe`.
- A terminal receipt (`succeeded`, `failed`) is immutable; replay returns it without calling again.
- An attempt left without a receipt resolves by its class: idempotent and read-only effects get a
  fresh fenced attempt; transactional and reconcilable effects reconcile from target
  evidence, and only a `not_applied` finding grants a retry; unsafe effects become `:unknown` and
  block the turn until a human resolves them on the exact effect, with an audit record. No effect gets
  more than three attempts; past that it is `:unknown`.

## Consequences

Crash semantics are honest: an effect happened once, provably did not happen, or is flagged
unknown. **Cost:** exactly-once arbitrary remote effects are out of scope; an unsafe ambiguous
effect costs human attention; every new effect needs a declared class.

## Invariants

- 21 — replay-safe effects or explicit ambiguity.
- 52 — logical activation identity survives interruption and retry.
- 54 — thread deletion preserves effect truth.

## Threat model

**Asset:** the outside world's state. **Adversary:** crashes, lease loss, timeouts, and a stale
owner waking up.

| Threat | Mitigation |
|---|---|
| Replay repeats a completed effect | Request-keyed identity; immutable terminal receipt returned on replay |
| Timeout read as failure, then retried | Unsafe class becomes `:unknown`; no automatic retry |
| A stale owner starts a new attempt | Starting an effect requires the current graph fence |
| A late receipt overwrites a newer truth | Late receipts are retained without overwriting a succeeded head |
| A human resolution from the wrong writer | Resolution is fenced to the row scope and audited |

**Residual risk:** an `:unknown` unsafe effect may in fact have happened; a human decides.

## History

- 2026-10-09 — speech output of delivered text is presentation, not an effect (owner decision OD6,
  ADR-061).

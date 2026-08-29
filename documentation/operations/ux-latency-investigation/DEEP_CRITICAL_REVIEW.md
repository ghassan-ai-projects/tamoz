# Deep Critical Review — Pre-mortem of the Agent Improvement Plan

Review date: 2026-08-11. Review stance: assume the implementation passes its happy
path tests and still fails in production. Look for circular trust, false guarantees,
durability gaps, operational traps, and abstractions that solve the benchmark rather
than the product.

## Verdict

**Conditionally implementable, not unconditionally implementation-ready.**

Slices 0-2 are sound and should proceed. The routing architecture is promising but
had a circular trust flaw: the same model both decides that no evidence is required
and supplies the answer. Structural removal of tools prevents unauthorized effects;
it does not prove the answer did not falsely claim an effect occurred. The amended
plan now blocks slice 3 on an explicit `responded` versus verified `completed`
contract. That decision is the difference between a latency optimization and a
false-success feature.

The Telegram direction is also sound only if the drainer is treated as a durable
delivery state machine, not merely a thread around the existing loop.

## Critical findings

### C1 — Fused routing is circular trust

The model says "this needs no evidence" and immediately supplies the answer. The
framework can prove that the direct path had no capabilities, but it cannot prove
that the natural-language answer did not say "I changed the file." A finite corpus
cannot turn that self-attestation into a safety proof.

Required response:

- `direct_response` produces a distinct `responded` outcome, never verified
  completion.
- Action/workspace requests routed there fail the false-success gate even if the
  prose sounds confident.
- Promotion remains blocked until CLI exit codes, JSON, public API, worker status,
  and channel rendering all preserve the distinction.

Rejected response: add more prompt text or a confidence threshold. Both remain model
self-attestation.

### C2 — A fast path without conversational context can regress the core UX

The proposed direct call intentionally removes memory and tools. That makes a
self-contained fact question fast, but common follow-ups depend on prior turns. A
router cannot classify "what about Germany?" correctly without seeing enough prior
context to know what "what" refers to.

Required response: restrict the first fast path to self-contained requests and add
anaphora/follow-up cases. Design bounded conversation context later with provenance,
classification, byte limits, and behavior-version binding. Do not silently inject
unbounded transcript text.

### C3 — Durable graph compatibility cannot be delegated to hope

Adding route state or changing node behavior may change definition identity and
resume semantics. A new binary must not reinterpret accepted v1 work under v2
instructions. The plan correctly adds a compatibility spike, but the spike is a
blocking design input, not a test to run after implementation.

Required response: produce paused/running/blocked v1 fixtures first. If any cannot
resume under the new definition, keep explicit v1 execution support for existing
threads. Do not migrate an accepted action plan into a new routing lifecycle.

### C4 — The drainer is a protocol, not an extraction

Moving `drain_outbox` to another object is easy. Correctly owning claim expiry,
throttle deadlines, attempts, ambiguous outcomes, rate limits, fairness, shutdown,
and prompt activation is the real change. If retry deadlines are only sleeps, a
restart changes behavior. If connections are shared, concurrency assumptions leak
into SQLite and Net::HTTP.

Required response: specify the state machine and persisted fields before code;
provide one store connection and client per loop; enforce per-chat/global rates;
prove two-owner races and restart behavior. Keep ambiguous sends `unknown`.

### C5 — "User-visible exactly once" is not a possible guarantee

The system can guarantee one logical delivery intent and at-most-once automatic send
after ambiguity. It cannot prove a user saw a message when the provider response was
lost. Claiming 100% user-facing terminal delivery would pressure an implementer to
retry `unknown` and violate the safer invariant.

Required response: gate durable intent, send attempt latency, succeeded receipts,
and unknown visibility separately. Never collapse them into "delivered."

## High findings

### H1 — Provider qualification cannot be global

Structured-output adherence differs by provider and model. A router proven on one
model may fail closed constantly on another, adding a call and making latency worse.
Promotion must be per configured provider/model role, with legacy fallback for
unqualified roles. "Test two providers" is evidence, not a compatibility contract.

### H2 — Fallback can exceed budgets

A route call followed by legacy planning is an extra model call. If it is not counted
before fallback, route parsing becomes an unmetered retry channel. Count it in the
same durable census and test the exact boundary before and after restart.

### H3 — Ack ordering can invert the UX

Independent inbound, worker, and outbound loops can produce a terminal row quickly.
Without per-conversation ordering or stale-ack coalescing, the user can receive the
answer and then "Working on it." Ack-before-terminal or terminal-only are the only
valid outcomes.

### H4 — Second discovery can become repair-loop laundering

`ToolArgumentError#repairable?` does not mean discovery can solve the failure. If the
implementation uses that broad predicate or message matching, any malformed
argument can consume the discovery allowance and hide the real planner defect.
Require a narrow typed missing-evidence outcome or remove the second pass.

### H5 — Observability can become unjoinable on one-shot Runtime

The durable path has thread/execution/request identities. One-shot `Runtime` does
not naturally have the same spine or journal location. Hiding a recorder in a global
or fabricating identifiers inconsistently makes latency metrics impossible to join.
Define explicit ephemeral correlation and recorder ownership at construction.

## Medium findings

- Direct-response quality and route precision are separate metrics. A perfect route
  that returns poor answers does not improve the product.
- Human stderr progress must be tested under TTY and non-TTY capture; spinners can
  corrupt logs or interleave with approval prompts.
- Safe terminal summaries need a closed reason vocabulary. Free-form "next action"
  text risks leaking reviewer/provider content.
- Surface revisions must bind accepted, progress, and terminal rendering. A queued
  row must not silently adopt a later surface policy.
- Control traffic needs fairness under multiple chats. A busy chat must not starve
  another conversation's terminal row.
- Live latency artifacts must exclude credentials and raw prompts and distinguish
  provider variance from agent overhead.

## What would make this plan fail despite green tests

1. The adversarial corpus mirrors the routing prompt and misses natural phrasings.
2. Tests assert no tool execution but forget to assert no claimed completion.
3. Durable compatibility tests create v1 state using the new code rather than a
   pinned old fixture.
4. Delivery tests use a synchronous fake poller and never overlap poll, worker, and
   drainer timing.
5. Retry tests simulate failure before send only and never kill after send/before
   receipt persistence.
6. Progress tests count planned steps rather than committed effect receipts.
7. Provider tests run one model while production profiles select another role.
8. CI turns timing thresholds into flaky wall-clock assertions instead of using a
   deterministic delayed fixture plus reported live measurements.

## Required owner decisions

| Decision | Must be made before | Acceptable outcome |
|---|---|---|
| Direct response semantics and public API | Slice 3 | Explicit `responded` state distinct from verified completion; migration if public surface changes |
| Durable graph compatibility | Slice 4 | Proven same-definition resume or explicit v1/v2 selection |
| Delivery retry/state ownership | Slice 6 | Durable state machine, independent resources, preserved ambiguity invariant |
| Typed command intent boundary | Slice 7 | Closed intent values, bound-conversation authority, no command text to model |

## Final recommendation

Proceed with baseline repair, measurement, and truthful feedback now. Do not start
automatic routing merely because its latency benchmark is attractive. Accept the
response/completion contract, prove it first in ephemeral `Runtime`, qualify each
configured model role, and only then carry it into durable sessions. Treat Telegram
delivery as protocol work with its own cross-gem review. With those constraints, the
plan attacks the real bottlenecks without trading correctness for speed.

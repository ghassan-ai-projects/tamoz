# Final Synthesis — UX & Latency Improvement Plan

Investigation of 2026-08-11. Four iterations; evidence base: 5 live CLI runs
against `deepseek-chat` (`tmp/ux-probe/`), committed scorecards/benchmarks,
`agenteval/reports/baseline-20260805.json`, and full source traces (file:line
citations in the iteration reports). Labels: **[measured]** / **[supported]** /
**[hypothesis]**. No code was changed.

## 1. Current request lifecycle map

**CLI one-shot:** parse → build model → ephemeral `Runtime` → *(no
classification)* → plan call → structural review → semantic review call →
(≤3 attempts) → step execution (approvals if `--allow-changes`) → ≤2 repair
loops → verify call → print. **[supported]**

**CLI durable (`ask`) / worker turn:** + session dir & migrations → SQLite
request inbox claim (lease) → graph: intake → deliberate → step_gate →
step_execute → evaluate → verify → terminal, one synchronous checkpoint
transaction per node (8/turn benchmarked) + 3 effect-journal transactions per
model call. **[supported + measured]**

**Telegram:** gateway long-poll (30 s) → synchronous admission (1 txn/msg) →
durable inbox → worker pickup (1 s idle poll, per-conversation FIFO, 1 worker
default) → full durable turn as above → terminal answer into durable outbox →
**drained only after the current long-poll returns** (≤31 s quiet-period wait)
→ one `sendMessage` (no retry on ambiguous failure). **[supported]**

## 2. Measured latency budget by stage

| Stage | Simple question | Basis |
|---|---|---|
| Process boot / model construction | ~0.5–1 s | [measured] (user+sys ≈ 0.5 s) |
| Classification | 0 — nonexistent | [supported] |
| Plan + review cycles | 1–3 rounds × 2 model calls; observed 9–21 s of a 16 s turn | [measured] run1/run2 |
| Tool execution | ~0 s (chat) / small (run3: 2 calls inside 5.1 s) | [measured] |
| Verify/synthesis | 1 model call, ~2–4 s | [measured] |
| Durability overhead (durable paths) | ~41 ms p50 total | [measured] `docs/benchmark.json` |
| Telegram: admission→pickup | ≤ ~1 s | [supported] (poll constants) |
| Telegram: outbox→delivery (quiet) | **0–31 s** | [supported] (`comms_gateway.rb:50-60,90`) |
| Acknowledgement / progress | ∞ — does not exist | [supported] |

Model calls dominate everything: 3–7 sequential non-streamed calls per simple
turn. **[measured]**

## 3. Root causes of slow simple chat

1. **No request classification** — every input runs plan→semantic-review→verify
   regardless of intent; the only branch is the operator's `--allow-changes`
   flag. **[supported]** Measured effect: 3–7 model calls where 1 suffices;
   5.1–16.4 s for one-word answers. **[measured]**
2. **Plan/review self-interference** — the reviewer rejects trivial-task plans
   for overengineering, forcing full re-plan rounds (2 extra rounds observed on
   "capital of France"); proportionality is a prompt hope, not a routing
   guarantee. **[measured]**
3. **Zero liveness signaling** — no spinner, no streaming, most lifecycle
   events unrendered; perceived latency = total latency. **[supported]**
4. **Stateless per-stage model calls** — fresh chat per `generate`; context
   re-sent every stage, multiplying tokens and time on loops. **[supported]**

## 4. Root causes of incomplete complex tasks

1. **Discovery/concreteness deadlock** — review demands concrete step arguments
   (exact file paths) that only exist after discovery runs; the graph has no
   discover→re-plan transition. Whole task classes (diagnose 0/3, implement
   0/3 in agenteval; run5 exit 1 with zero tool calls) die at the gate.
   **[measured + supported]**
2. **Attempt caps burn on machinery, not progress** — 3 plan attempts consumed
   by protocol parse failures and systematic reviewer disagreement; 2-repair
   cap; exhaustion routes to a verify that can only report "not satisfied".
   **[measured + supported]**
3. **Silent stop paths** — "feedback not discloseable"; repeated-action stops
   implicit; worker budget exhaustion notifies nobody; Telegram delivery
   failure strands a completed answer as `unknown` until an operator intervenes.
   The user cannot tell capability failure from system limitation. **[supported]**
4. **No partial-progress model** — verification is all-or-nothing at turn end;
   verified intermediate steps are never reported as progress. **[supported]**
5. **Split-brain budgets** — enforced (and silently) in the worker, absent in
   interactive CLI. **[supported]**

## 5. Root causes of poor Telegram experience

1. **No user-feedback contract** — `request.accepted` deliberately dropped; the
   typing-indicator transport seam exists and is never called; design defers
   all progress streaming. **[supported]**
2. **Outbound gated behind inbound** — outbox drains only after the long-poll
   returns: up to 31 s of pure queueing on the delivery leg. **[supported]**
3. **No delivery recovery** — ambiguous sends never retried; no user or
   operator alert. **[supported]**
4. **Dead controls** — `/status` `/cancel` `/help` parsed, then discarded
   without reply; approval is deny-only, generic, unacknowledged, silently
   expiring. **[supported]**
5. **Chat pays the task path** — "hi" becomes a full durable occurrence with
   plan/review/verify (root cause 3.1 applied to the channel). **[supported]**

## 6. Recommended request classification model

Five classes, resolved **before** the deliberation graph, cheapest signal
first: (1) operator flags (`--allow-changes`, profile authority) bound the
*ceiling*; (2) deterministic shape checks; (3) at most one cheap classifier
call only when ambiguous — never more than one.

| Class | Path | Machinery |
|---|---|---|
| Conversational | fast | 1 model call, direct answer, read-only toolbox |
| Read-only question | fast | 1–2 calls; tools allowed, no plan/review/verify stage |
| Bounded task | light | plan, single review, execute, verify |
| Complex task | managed | discover→re-plan cycles, progress reporting, budgets |
| Mutation | managed + approval | current reviewed/digest-bound/approved pipeline (unchanged authority model) |

Safety invariant: the fast path is **structurally read-only** (no
action-capable toolbox), so misclassification degrades answer quality, never
authority. **[hypothesis → must be gated by tests]**

## 7. Recommended simple-chat fast-path behavior

One blocking model call with conversation-appropriate instructions; answer
returned directly; total target ≤ 1.5× one model round-trip (~2–4 s p50 with
deepseek-class models). Immediate liveness signal on every surface (CLI
spinner/elapsed line; Telegram typing action or ack message). No plan, review,
verify, checkpoint, or inbox machinery; no persistence beyond what the session
already requires. **[hypothesis — thresholds to be validated per §11/§12]**

## 8. Recommended complex-task lifecycle and state model

Keep the durable graph and its complete/failed/blocked/cancelled states (they
are sound). Change three behaviors:

1. **Discovery-tolerant planning**: plans may contain discovery steps whose
   outputs trigger a *re-plan with evidence* transition; review's concreteness
   bar applies only to steps consuming available evidence. Mutation authority
   stays bound to the reviewed action plan — only the timing of concreteness
   moves.
2. **Self-narrating stops**: every terminal and pause state reports its reason,
   a sanitized summary of the last objection/failure, and the concrete
   unblocking action — on every surface including the channel (budget stops
   included).
3. **Verified partial progress**: verify reports what *was* accomplished and
   verified ("3 of 5 steps") so incomplete ≠ invisible and restarts resume from
   evidence rather than from zero.

## 9. Recommended acknowledgement and progress behavior

- **Ack**: every admitted request gets a visible ack within one poll/admission
  cycle (Telegram: typing action via the existing `signal` seam or an ack
  message; CLI: immediate stage line + spinner).
- **Progress**: for turns exceeding a threshold (~10 s), periodic stage
  updates (planning → executing → verifying), coalesced to respect rate limits.
- **Terminal**: every terminal state — complete, failed, budget-stopped,
  cancelled, blocked — produces exactly one truthful user-facing message.
- **Controls**: wire `/status` and `/cancel` to real effects; approval prompts
  name the pending action and acknowledge the callback.
- **Delivery**: retry ambiguous sends with backoff (content-derived delivery
  ids already dedup); alert the operator after final failure.

## 10. Observability gaps and required measurements

The catalog defines the right events/metrics and nothing emits them
**[supported]**. Required, in order:

1. Emit `tamoz.model.call` / `tamoz.tool.call` (duration, stage) and turn
   duration at existing session/worker sites; timestamps on CLI stream parts.
2. Queue/lease waits (`tamoz.lease.wait_ms`, inbox queued→claimed) and
   approval wait time.
3. Telegram stage decomposition from already-stored columns (one query/command:
   `ingested_at_ms` → transitions → outbox → receipt); per-poll-pass timing.
4. A live-latency smoke artifact (fixed prompts, per-stage timing) reported
   per release next to `benchmark.json`.
5. Refresh `docs/LIMITATIONS.md` (still claims the Telegram channel doesn't
   exist — stale).

## 11. Prioritized improvements

**Immediate** (highest impact / smallest surface, no cross-gem interface
changes):
1. Conversational/read-only fast path behind classification (§6/§7) — fixes
   symptom 1 and halves symptom 4. *Risk: misclassification; contained by
   structural read-only fast path.*
2. Liveness + terminal feedback everywhere (§9 ack/terminal rows) — fixes
   symptom 5's worst half. *Low risk: presentation only.*
3. Self-narrating stops incl. channel notification of budget stops (§8.2) —
   converts silent abandonment into recoverable states. *Low risk.*
4. Fill existing telemetry producers (§10.1–10.3) — makes every later change
   measurable. *Low risk.*

**Near-term** (cross-gem coordination needed — ask before changing
interfaces):
5. Discovery→re-plan transition + evidence-scoped review bar (§8.1) — the
   complex-completion fix. *Risk: review-authority semantics; needs ADR and
   scorecard gates.*
6. Decouple outbox drain from the long-poll; delivery retry with backoff
   (§9 delivery) — removes the 0–31 s quiet-period penalty and stranded
   answers. *Risk: duplicate sends, mitigated by existing delivery ids.*
7. Wire `/status` `/cancel`; actionable approval prompts (§9 controls).

**Later:**
8. Verified partial-progress reporting and resume-from-evidence (§8.3).
9. Live-latency release artifact; budget-semantics alignment CLI↔worker.
10. Streaming responses (only after the above prove what streaming would
    actually fix; currently unmeasured).

## 12. Evaluation matrix (acceptance criteria)

| Dimension | Metric | Threshold | How measured |
|---|---|---|---|
| Simple chat latency | p50 wall time, 1-word questions | ≤ 1.5× one model round-trip; ≤ 1 model call | live smoke artifact (§10.4) |
| Simple chat reliability | `PlanRejectedError` on chat corpus (20 prompts) | 0 | scorecard case |
| Complex completion | agenteval diagnose+implement solve rate | ≥ 2/3 each (now 0/6 combined) | re-run pack |
| Complex completion | discovery-dependent corpus completion | ≥ 80% | new scorecard cases |
| Truthfulness | false-success, unsafe-action hard gates | 0 (unchanged) | existing scorecards |
| Feedback | time to first user-visible signal | ≤ 1 admission cycle (Telegram), ≤ 0.5 s (CLI) | staged channel test / stream timestamps |
| Feedback | terminal states producing a user message | 100% incl. budget/failure/cancel | channel scorecard cases |
| Recovery | ambiguous send retried; `/cancel` stops work | both pass | staged channel test |
| Telegram latency | outbox-write → delivery, quiet period | ≤ 2 s p95 | §10.3 decomposition |
| Cost | model calls per simple turn | 1 (now 3–7) | telemetry §10.1 |

## 13. Explicit non-goals

- Changing the mutation authority model (reviewed plans, digest binding,
  approvals, deny-only channel) — it is the product's core guarantee.
- Exactly-once external effects, multi-bot fleets, group chats, rich Telegram
  formatting, token streaming UX, and any new abstraction (caching layers,
  concurrency frameworks) not tied to a measured bottleneck above.
- Model/provider selection tuning — failures here are structural, not
  model-quality. **[hypothesis, model-independence check suggested in
  iteration 3]**

## 14. Risks and regression protections

- **Misrouted mutation** (fast path): contained structurally (read-only
  toolbox on fast path); gated by new scorecard case "no mutation reachable
  without the managed path"; hard-zero gates unchanged.
- **Review-bar relaxation** (discovery tolerance): could admit vaguer action
  plans; protected by keeping concreteness mandatory for mutation steps and by
  the existing oracle-contradicted-satisfaction auditor.
- **Feedback message spam / rate limits**: coalescing policy + Telegram
  delivery-id dedup; measured via staged channel tests before rollout.
- **Retry-induced duplicate sends**: content-derived delivery ids already
  dedup appends; add at-least-once-send tests proving single visible message.
- **Telemetry overhead**: producers are NDJSON appends on paths that already
  journal; extend the existing overhead benchmark with an observed/unobserved
  comparison row.
- **Doc drift**: add LIMITATION/evidence refresh to the release checklist.

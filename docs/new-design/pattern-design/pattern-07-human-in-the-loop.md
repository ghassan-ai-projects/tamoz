# Pattern 07 — Human-in-the-Loop

Handbook: chapter-07-human-in-the-loop.md. Verdict: **Strong — the exact-intent
binding (digest-bound assertion), authenticated decider, consume-once nonce,
full revalidation on resolve, and the two-identity relay/authority split are
best-in-class. Missing: a revise decision kind, a full escalation ladder
(notify/ask/page/block), a delegation contract + friction budget, cost/alternatives
in the approval prompt, and rubber-stamp metrics.** Builds on: README substrate;
pattern-03's critic (H5's alternatives source). **Autonomy: per-action risk gate
(ch.07's own vocabulary)** — R0/R1 auto, R2 calibrated-automation-or-approval, R3/R4
deny; watch = abstain.

## Handbook definition (owner's)

- Autonomy is a per-action decision, not a global setting: classify by authority,
  impact, reversibility, externality, aggregate value, policy; gate consequential,
  bound the rest.
- Gates are state machines, not prompts: `propose → present → decide → validate →
  execute`; gate at the tool boundary and before the irreversible step; "ask, don't
  narrate".
- Bind authority to exact intent: canonical action digest (incl. policy version),
  authenticate the decider (approval identity ≠ delivery identity), re-validate
  preconditions between approval and execution, mandatory expiry that fails closed,
  separate proposal ID from stable operation ID, consume-once.
- Approval request answerable in 30 seconds: what / why now / cost / risk /
  alternatives / expiry / scope / evidence.
- Escalation is a ladder: notify → ask → page → block, cheapest rung first, each
  with a defined failure path; fail-closed on the protected action.
- Humans correct beliefs, not just actions: provisional vs confirmed vs superseded;
  evidence travels with the belief; abstention is valid.
- Delegation contract + friction budget: policy-as-code (action classes,
  thresholds, escalation, expiry); max asks/day + batch window; measure
  rubber-stamping.

## How tamoz implements it (HEAD)

- **Approval gate lifecycle** (`ApprovalRelay`): `deliver` (6 required prompt fields
  + evidence) → `submit_decision` (state must be `requested`, expiry fail-closed,
  nonce claimed once) → in-place withdrawal edits the prompt — approval_relay.rb:84-168.
- **Bind authority to exact intent:** 11-field signed assertion under
  `situation-runtime/approval-assertion/v1` (approver_id, tenant, approval_id,
  intent_digest, snapshot_digest, decision, expires_at, nonce, audience, relay_id,
  key_id) — approval_relay.rb:33-38.
- **Consume-once + replay protection:** durable single-use nonce — a repeated nonce
  is REFUSED, never idempotently accepted; separate Idempotency-Key (nonce excluded)
  covers transport retries. Two distinct nonces: the relay's submission nonce is a
  random UUID claimed once via `nonce_store.claim` (approval_relay.rb:141-143); the
  stream's approval-row nonce is DERIVED `sha256(approval_id|intent_id)` and never
  cleared (policy.go:609-610, read by `authorizeApproval` 433-447).
- **Re-validate preconditions on resolve:** the Go `ResolveApproval` re-runs the
  entire `EvaluateIntent` gate on approve (stale situation → withdraw, expired →
  deny, then authorize + full re-evaluation) — policy.go:341-415.
- **Authenticated decider:** ed25519 signature verification against durable rows +
  role join `principals → principal_roles → approval_authorities` keyed
  entity_id + risk_class; the relay never signs as the approver (separation of
  duty) — policy.go:417-460.
- **Risk routing:** R0/R1 auto, R2 calibrated-automation gate → human approval, R3/R4
  deny (`risk_policy_denied`); `watch_confidence_floor` abstains — decision_builder.rb:126-168.
- **Escalation:** deterministic roster escalation (ask → next ask, nil when roster
  spent) — approval_relay.rb:175-193.
- **Delivery:** Telegram/Comms with single-use random reference (only digest stored),
  prompt activated only after a durable send receipt, `chat_bound <
  filesystem_operator` → Telegram is deny-only in v1 — comms_gateway.rb:197-263.
- **Audit trail:** stream receipt store (identity/state/payload_digest/event digest
  chain), `policy_evaluations` rows, agent `DecisionRecord`, verification ledger
  outcome→reconciled→observed — approval_receipt_store.rb; policy.go:736-763.
- **The two-identity split is load-bearing:** the stream classifies/creates/
  revalidates (authority); Tamoz relays/delivers/collects (delivery). "A relayed
  approval never bypasses the stream's revalidation — the answer is an input to
  policy, never a substitute for it" (approval_relay.rb:10-14). Maps to the
  handbook's durable `ApprovalRequired` transition + "gate at the tool boundary".

## Divergence from the handbook

1. **Approve-on-action only** — no approve-on-commit (stage-then-durable) mode, no
   async sandbox continuation for the rest of the plan, no batch window.
2. **Binary decisions only** — `DECISIONS = %w[approve deny]`; no **revise**
   (supersede-and-re-propose, capped) rung; a revision conflict forces a new
   proposal from scratch.
3. **Escalation ladder has one rung** — roster escalation = ask→(next ask). No
   **notify** rung (post-action notification for low-risk actions), no **page** rung
   (urgent time-sensitive channel). Block exists implicitly (R3/R4 deny +
   `approval_denied` terminal) but is not a first-class state.
4. **No delegation contract / friction budget** — no per-profile max_asks_per_day,
   batch window, attention-exhaustion policy, or aggregate-value threshold (a series
   of small mutating actions each gated identically = threshold gaming).
5. **Approval request lacks cost + alternatives** — the prompt has
   summary/delta/hypothesis/evidence/action/decline_consequence/expiry; the
   handbook's cost and considered-alternatives are absent.
6. **No rubber-stamp measurement** — audit rows exist; no time-to-decision,
   override-rate, or concentration metrics.

## How it SHOULD be implemented (on existing seams)

1. **Revise rung.** Extend `DECISIONS` (approval_relay.rb:38 — currently
   `%w[approve deny]`) with `revise`; add a capped revise loop mirroring the Go
   `ResolveApproval` re-evaluation: revision supersedes the proposal
   (approval_receipt_store.rb:88-119 transition), new proposal re-proposed with
   incremented revision, escalation when the cap is hit. Nonce stays single-use per
   proposal.
2. **Escalation ladder notify + page.** Keep roster escalation as `ask`; add
   `notify` (post-action notification for low-risk completed actions — the
   outbox/comms sink is the seam, outbox_delivery_sink.rb:63-68) and `page` (urgent,
   expiry imminent, high-priority channel). Formalize block (R3/R4 deny) as the
   fourth rung.
3. **Delegation contract + friction budget.** Add a per-profile contract key in
   `profile/fields.rb` (`max_asks_per_day`, `batch_window_minutes`,
   `aggregate_value_threshold`); enforce in session_steps.rb:57-73 (aggregate
   mutating actions per session before gating — prevents threshold gaming); batch
   pending approvals into one interrupt where policy allows.
4. **Approval prompt completeness.** Extend `render_prompt` (approval_relay.rb:195-206)
   with cost estimate and considered-alternatives (the session's semantic_review
   critic is the natural source).
5. **Belief review queue.** The wisdom human gate (wisdom.rb:32-66,
   "recommendation_only") is the confirm path; complete it by routing knowledge-layer
   corrections through `Lifecycle#correct` so the human corrects the record, not the
   agent — and permit abstention (no write).
6. **Rubber-stamp metrics.** Add an approval-quality projection over
   `approval_receipt_store` + `policy_evaluations`: time-to-decision,
   decision-vs-default override rate, approval concentration — the audit rows already
   carry every field.

## Gap list (priority order)

| # | Gap | Landing spot |
|---|---|---|
| H1 | Revise decision kind (supersede + capped re-propose) | `approval_relay.rb:38` + `approval_receipt_store.rb:88-119` |
| H2 | Approve-on-commit staged mode (net-new: no staged path in `step_gate` today) | `stage` branch off `step_gate` (session_steps.rb:20-33) writing a durable staged-intent row; commit re-validates preconditions |
| H3 | Escalation ladder notify→ask→page→block | `approval_relay.rb:175-193` + `outbox_delivery_sink.rb:63-68` |
| H4 | Delegation contract + friction budget | `profile/fields.rb` new contract key + `session_steps.rb` |
| H5 | Approval request: cost + alternatives | `approval_relay.rb:195-206` render_prompt |
| H6 | Rubber-stamp / decision-quality metrics | projection over `approval_receipt_store.rb` + `policy.go:736-763` |
| H7 | Belief-correction loop for knowledge claims | `wisdom.rb:32-66` + `Lifecycle#correct` |
| H8 | Calibration gate is artifact-bound, not policy-learned ("learn, then review") | Repeated successful approvals become a policy-change candidate via the memory write path (ch.07 §6) — wire to the calibration artifact registration seam (policy.go:313-320) |

**Tests to update:** H1 extends `DECISIONS` — the approval relay tests
(`test/stream_approval_relay_test.rb`, `stream_approval_receipt_store_test.rb`) and
the Go `ResolveApproval` tests; H2's staged mode adds a `stage` branch asserted by
the session approval tests.

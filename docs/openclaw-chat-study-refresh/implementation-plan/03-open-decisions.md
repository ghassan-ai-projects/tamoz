# The four open decisions — plan and multi-lens review

These four decisions change behaviour the user will feel, so the plan surfaced
them rather than choosing silently. This document develops each into a
recommendation with rationale, options, tradeoffs, risk, and acceptance, then
subjects all four to a multi-lens review. It is planning only — no code.

Each decision maps to a phase in `01-plan.md` and a finding in
`../05-open-findings-ledger.md`.

---

## Decision 1 — Chat-vs-task classification (I4 / SD-1 / Phase 0b)

**Question:** which turns are answered directly as chat, and which enter the
durable planned lifecycle?

**Options:**
- A. **Effect-based, deterministic.** A turn that proposes no effect is answered
   on the light path; a turn that would change the workspace/state is planned
   and durable. Derived from the route/authority the turn needs — no extra model
   call.
- B. **Model intent-classifier.** A model call labels each turn chat vs task.
- C. **Explicit user signal.** A prefix/command marks tasks.

**Recommendation: A, refined into three buckets.** The real world is not binary:
1. **Direct chat answer** — trivial/among-history questions; no ref, no
   lifecycle, cannot reach `PlanRejectedError`.
2. **Read-only task** — durable, gets a ref, uses `adaptive_read_only`; no
   effect approval; a multi-step investigation ("search the repo and summarize")
   lives here.
3. **Effect task** — durable, ref, deliberate planning + approvals.

**Rationale:** deterministic and safe (a chat turn cannot acquire effect
authority); reuses the existing `route`/`adaptive_read_only`/`deliberate`
machinery; avoids an extra nondeterministic model call (latency + prompt-
injection surface). The whiplash (Decision 2) originates in *deliberate*
planning; buckets 1–2 must not produce it.

**Tradeoff / risk:** misclassification. A task treated as chat gives a shallow
answer; a chat treated as a task gives whiplash. **Mitigation:** for ambiguous
no-effect turns, err toward bucket 1/2 (never the deliberate path); only go
deliberate when an effect is clearly proposed.

**Acceptance:** a no-effect turn never enters deliberate planning and never
raises `PlanRejectedError`; an effect-proposing turn is planned and durable;
a read-only investigation gets a ref but no approval prompt.

---

## Decision 2 — Failed plan → clarification vs terminal fail (I5 / SD-2 / Phase 0b)

**Question:** when a plan cannot pass review, does the user get a question or a
failure?

**Recommendation:** **always attempt a bounded clarification first when the
failure is information-shaped** (the common case — "I need to know X"), capped at
one conversion per turn so it cannot loop plan↔question; fall through to **one
honest terminal card** only when the failure is not information-shaped
(infeasible or unsafe request).

**Rationale:** a failed plan usually means a missing decision, which is a
question, not a dead-end. This is exactly the interaction the sponsor wants.

**Tradeoff / risk:** adds a round-trip instead of failing fast; a genuinely
infeasible request could turn into an endless "what do you mean?" **Mitigation:**
the cap, plus converting only information-shaped failures. **Security:** the
clarification must be framework-owned and bounded — never the raw reviewer prose
(the current `plan_rejected_message` already refuses to disclose non-structural
feedback; preserve that).

**Acceptance:** unplannable-due-to-missing-info → one bounded question (I1 path);
a valid answer proceeds or makes one more attempt; the cap prevents a loop; an
infeasible request → one honest card with a next action, never a raw error.

---

## Decision 3 — Acceptance timing / coherence (I5 / Phase 0b)

**Question:** when do we acknowledge, and how do we avoid "I'll report progress"
followed by failure?

**Options:**
- A. **Two-stage, coherent.** An immediate minimal receipt ("Got it, r7f3")
   that promises nothing about progress, upgraded to "working" only once a plan
   passes review. A failure before that shows as a question or honest card and
   contradicts no earlier promise.
- B. **Single deferred ack** until the plan passes (user waits with no receipt —
   feels ignored).
- C. **Current immediate rich ack** (the whiplash source).

**Recommendation: A.** Keep the immediate durable acknowledgement (the request
*is* admitted at once — that invariant stays), but make its wording a bare
receipt, and only promise progress once there is a plan to report. On Telegram,
upgrade by **editing the same card**, not a new push, so it costs no extra
notification.

**Rationale:** preserves the durability/acknowledgement invariant while never
over-promising. **Coupling:** the receipt must also be honest about worker
availability (DG-2) — "Got it" while no worker exists is another lie, so tie the
receipt wording to worker-health from Phase 1.

**Acceptance:** the minimal receipt never claims progress; acceptance wording is
coherent with a fast review failure; the upgrade to "working" happens only after
a plan passes review; the upgrade is a coalesced edit, not a new push.

---

## Decision 4 — Chat-turn memory / history depth (context contract / Phase 0b→2)

**Question:** how much prior context does a chat turn see?

**Options:** last N confirmed answers; pinned summary + last N; full thread.

**Recommendation:** **pinned summary (if any) + last N confirmed terminal
answers**, N small (start 3–5), bounded by the model-call budget in
`docs/model-call-boundary-review-2026-08-26/`. Never include progress milestones
(history invariant) or unconfirmed content.

**Rationale:** continuity without unbounded context or latency; aligns with the
confirmed-terminal-only history rule and the existing model-call budget.

**Tradeoff / risk:** a reference older than N is lost unless pinned/summarized;
larger N raises latency (a live user issue — see the latency folder).
**Mitigation:** the pinned summary carries older context; an explicit
`/context`/"show more" discloses more on request; keep N small by default.
**Security:** the confirmed-only + redaction rules prevent leaking hidden
context into a chat.

**Acceptance:** a chat turn includes the pinned summary + last N confirmed
answers, excludes milestones and unconfirmed content, and respects the budget;
N is a tested, documented value, not implicit.

---

## Multi-lens review of the four decisions

Each lens checks all four and records any objection and its resolution.

### Product / agent-vision
- D1: three buckets (not two) correctly separate "quick answer," "read-only
   investigation," and "effect work" — matches how a person actually delegates.
- D2: converting failure into a question is the single biggest felt improvement
   for "it just gave up on me."
- D3: a bare receipt that upgrades to a kept promise removes the whiplash.
- D4: small-N + pinned summary keeps chats feeling continuous without lag.
- **Objection (resolved):** D1's "read-only task still gets a ref" could feel
   heavy for a one-line question. → The bucket-1 direct answer covers trivial
   asks; only genuine multi-step investigation gets a ref.
- **Verdict:** no unresolved objection.

### Architecture / security
- D1: deterministic, no extra model call, chat cannot acquire effect authority —
   preserves the model-proposes/policy-decides boundary.
- D2: **Objection (resolved) — High:** a clarification synthesized from a failed
   plan must not echo untrusted reviewer prose into an authority-adjacent
   surface. → Framework-owned bounded question only; preserve
   `plan_rejected_message`'s non-disclosure of non-structural feedback.
- D3: the minimal receipt is a durable committed row; the upgrade is a coalesced
   edit — no new state machine.
- D4: confirmed-only + redaction unchanged.
- **Verdict:** resolved; no unresolved objection.

### Reliability
- D2: **Objection (resolved):** plan↔question could loop. → cap conversions per
   turn.
- D3: **Objection (resolved):** if the upgrade edit's delivery is unknown, does
   the user see a stale "Got it"? → the edit follows the existing unknown-
   delivery rule; the durable state is authoritative, and status resolves it.
- D4: larger N risks latency and context bloat. → small N default, budget-bound.
- **Verdict:** resolved.

### Interaction / attention
- D3: upgrading by editing the same card (not a new push) keeps the attention
   budget intact.
- D2: the clarification reuses the I1 reply path, so answering stays natural.
- **Objection (resolved):** D1 misclassification could surprise a user (shallow
   answer to a real task). → err toward the non-deliberate path only for
   no-effect turns; effect turns always plan.
- **Verdict:** resolved.

### Fourier / cross-scale
- D1 × D2 × D3 interact: routing fewer turns into deliberate planning shrinks the
   population that can hit the whiplash, and D3 makes the residual failures
   coherent — the fixes compound rather than conflict.
- **Objection (resolved):** D4's N interacts with the attention/latency budget at
   the session scale; a large N would slow every turn. → small N, budget-bound,
   documented.
- **Watch:** if D1 routes too aggressively to "chat," a real task gets a shallow
   answer with no ref — the opposite failure. Track misclassification in both
   directions during the validation spike.
- **Verdict:** resolved; one cross-scale watch item recorded.

## Review outcome

All four decisions survive the five lenses with their objections resolved. The
one High objection (D2 leaking reviewer prose) and the cross-scale watch (D1
misclassification direction) are now explicit. The recommended defaults are
safe to carry in `01-plan.md` as the executable choice, subject to the sponsor
overriding any of them.

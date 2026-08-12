# The Telegram communication bar

Status: proposed. This is the gradeable acceptance instrument for
`TELEGRAM_COMMUNICATION_FLOW_CONTRACT_2026-08-12.md`. The contract is the design; this
document is the bar that design must clear before any implementation slice is called done.
Nothing here authorizes a code change.

A row is `pass` only because its test ran. "Proof" means an executed test or command in
the repository's existing sense, not an assertion in prose.

## 1. Why the bar comes first

The failure that motivates this work is not a bug in a send call. It is a **truthfulness**
failure: the channel said "Accepted" and later "failed," and a user cannot tell from those
two words whether their request was understood, queued, attempted, half-done, or lost. A
message that is reassuring and wrong is worse than one that is sparse and true.

So the bar is not "does Telegram deliver messages." Telegram already delivers messages.
The bar is: **can a correspondent, and an operator, always tell the true state of a
request and the true state of its delivery — separately — with no message that implies
more than the system has established.** Everything below is that sentence made testable.

## 2. The one question, split in two

Every user-facing message answers, or must refuse to answer, two independent questions:

1. **Task truth** — what has Tamoz actually done with this request? (received, queued,
   running, completed-and-verified, failed-final, blocked-unknown, stopped, denied)
2. **Delivery truth** — did Telegram actually receive this particular message? (pending,
   delivered, failed, unknown)

The defining property of an acceptable design is that these two are never collapsed into
one word. "Accepted" collapsed them. A durable queue receipt is delivery-and-admission
truth; it is not task truth, and it must never read as task success.

## 3. The five properties of an acceptable message

Any message the channel emits must satisfy all five:

- **Earned** — it states only what a durable state transition has established. No message
  is emitted by optimistic narration or a timer that stands in for work.
- **Separated** — it commits to at most one of task truth and delivery truth, and never
  lets one imply the other.
- **Bounded** — its text is selected by a fixed renderer from whitelisted fields, byte-
  and line-capped, with control characters stripped; it never interpolates model output,
  tool responses, URLs, credentials, private addresses, or exception text.
- **Referenced** — it carries a short, non-secret request reference usable in `/status`
  and logs, and that reference authorizes nothing.
- **Recoverable** — its identity is derived from durable identity, so a duplicate update,
  a worker restart, or an outbox replay reproduces the same message rather than a second
  one.

## 4. The levels

| Level | Meaning | Test |
|---|---|---|
| **T0 — Reassuring** | The channel emits friendly text loosely correlated with work; "accepted/failed" today | — |
| **T1 — Separated** | Task truth and delivery truth are distinct states; no message implies success before a verified terminal outcome | A truthfulness oracle rejects any success-like message emitted before verification |
| **T2 — Durable and atomic** | Admission+receipt-intent and outcome+terminal-intent each commit atomically; every logical message has its own durable identity | Kill between commit and send at each boundary; recovery shows one request, one intent, one message |
| **T3 — Recoverable and ambiguity-honest** | Every attempt is fenced and leased; a lost external response is `UNKNOWN`, never `SENT`; unknowns resolve only by an operator on the exact id | The full §7 fault table converges; no non-owner send; no blind resend |
| **T4 — Provable** | The signal/reason catalog is closed and versioned; the two-axis state is exported to operator status; conformance tests prove the channel cannot lie, leak, or duplicate | Clause-level conformance suite and the live ALMS end-to-end case pass |

Levels are cumulative. **T3 is the minimum for a channel that speaks to a human on the
agent's behalf; T4 is required before the contract may be called satisfied.** The design
must state which level each implementation slice reaches.

## 5. The criteria

Each row names the proof that satisfies it.

### A. Truthfulness

| # | Criterion | Proof |
|---|---|---|
| A1 | **No message implies task success before a verified terminal outcome.** A receipt acknowledges durable admission only | A test asserts that no `Completed`/answer text can be emitted on any path before the completion/verification gate passes |
| A2 | **Task truth and delivery truth are separate states**, and no message asserts both | Given any emitted message, a test resolves it to exactly one axis; a `DELIVERY_UNKNOWN` never renders as delivered/completed |
| A3 | **Queued is visibly queued; running is visibly running.** A receipt is never `Running` (it precedes any claim); a stale queue is an operational failure, not an indefinite "working" | Enqueue behind open work; assert the receipt says queued, and `/status` reflects queue age, not "running" |
| A4 | **An empty result, an outage, and a failure are three distinct messages** | The ALMS no-data, ALMS-unreachable, and plan-rejected paths each produce a different, fixed message; a test asserts all three differ |
| A5 | **Failure carries a fixed reason code, retryability, and next action** — not a copied exception or model string | Enumerate every terminal failure; assert each names a registered code (§B of the contract's §6) and never contains model/tool/URL/secret text |

### B. Atomicity and recovery

| # | Criterion | Proof |
|---|---|---|
| B1 | **Admission, its idempotency record, and its receipt intent commit atomically**, or a repairable `RECEIPT_PENDING` remains | Kill after admission commit, before send; recovery shows one admitted request and one pending receipt intent |
| B2 | **Execution outcome and terminal delivery intent commit atomically**; physical send never re-executes the task | Kill after outcome, before delivery intent; recovery shows one outcome, one terminal intent, no re-execution |
| B3 | **Every logical message has its own durable identity and sequence** | Replay a duplicate update and restart the worker; assert one logical message per lifecycle event, not two |
| B4 | **The delivery lifecycle is a projection over the existing effect journal, not a second safety model** | A structural test asserts no parallel delivery-attempt tables/reconciliation exist outside the effect journal (contract §4.1, `COMMS_DESIGN` §20) |

### C. Authority and security

| # | Criterion | Proof |
|---|---|---|
| C1 | **Approval is evidence-gated (INV-A/B).** Denial is unconditional for the bound correspondent; approval requires `approver_evidence >= required_evidence`; deny and approve never share an unguarded path | A `chat_bound` approve at a `filesystem_operator` action is refused and records a durable refusal; the equivalent deny succeeds. Under v1 policy every effect requires `filesystem_operator`, so Telegram is deny-only in practice — the shipped approve-everything path fails this row |
| C2 | **`required_evidence` is trusted and pinned (INV-C).** It is a deterministic function of the pinned interrupt/effect digest, computed by trusted code, never set by the model, and part of the callback comparison | Assert the value is reproducible offline from the digest; assert a plan cannot lower it after the prompt is shown; a model-supplied requirement is ignored |
| C3 | **Absent or ambiguous evidence never approves (INV-E).** Missing, expired, or `UNKNOWN` approver evidence resolves as withheld | Feed each case; assert no approve decision is created and the prompt stays gated |
| C4 | **Every callback is bound to the exact prompt context** — status, unexpired time, reference digest, surface id+revision, correspondent, chat, message, thread, occurrence, interrupt digest, `required_evidence`, action | Cross-user, cross-chat, cross-surface, expired, and replayed presses each record a durable refusal and create no decision |
| C5 | **A callback reference is never an authority token**; consumption and decision-record are one transaction | Concurrent presses of one prompt yield at most one decision; the loser sees the recorded outcome |
| C6 | **The model/worker cannot send Telegram or bypass the outbox**, and holds no transport credential | A test asserts the worker path has no transport handle; the gateway is the only sender (ADR-042) |
| C7 | **Only bounded, redacted, whitelisted text reaches Telegram**; secrets/private addresses/model output are structurally excluded | Property test across every user-facing render path with a synthetic secret and hostile model output |

### D. Retry and queue liveness

| # | Criterion | Proof |
|---|---|---|
| D1 | **A retryable attempt is never shown as final failure while a retry is scheduled** | Force a retryable failure; assert the user sees a retry-scheduled state, not `FAILED_FINAL` |
| D2 | **Every retry policy states max attempts, deadline, backoff, idempotency basis, and the transition to final** | The policy is data; a test drives it to exhaustion and asserts exactly one terminal message |
| D3 | **`UNKNOWN` is never `SENT`/`COMPLETED` and is never silently retried** | Kill after `SEND_STARTED`, before the Telegram response; assert `UNKNOWN` and no automatic resend |
| D4 | **Every running attempt has owner, fence, lease, heartbeat, deadline; takeover only after lease expiry and fence validation** | A concurrent-drainer test asserts no two owners send the same logical delivery and no non-owner sends |

### E. UX and operability

| # | Criterion | Proof |
|---|---|---|
| E1 | **Fast path is two messages; slow path adds at most one coalesced progress message; approval path is receipt + one editable prompt + terminal, with no separate decision acknowledgement** | Scripted fast, slow, and approval requests; assert logical-message counts of 2, ≤3, and the approval matrix respectively |
| E2 | **Every message has a short non-secret reference usable in `/status` and logs** | Assert the reference is present, stable, collision-resistant, and authorizes nothing |
| E3 | **`/status` is caller-bound and read-only** — it cannot expose or resolve `UNKNOWN`; **operator status/resolution** additionally shows delivery ambiguity and resolution controls | A cross-conversation `/status` leaks nothing and cannot resolve ambiguity; only an operator view distinguishes admission/worker/ALMS/model/approval/delivery failures and resolves them |
| E4 | **The canonical live ALMS test is a CLI-originated request carrying an authorized Telegram binding and proves the exact pinned `mcp:alms/learning.search` query → non-empty evidence/provenance → verified summary/digest → durable terminal state and delivery intent → same-chat delivery**; it creates no approval prompt or decision | The end-to-end case leaves durable request/effect/outbox/terminal rows with exact surface/revision/correspondent/chat/thread linkage, the exact ordered tool list, learning IDs/source references, result digest, and terminal evidence printed only after the durable commit; a second chat is isolated |

## 6. What the bar deliberately does not require

Stating the non-requirements keeps the design from being graded against a different
product.

- **No Telegram-approve capability.** The bar does not ask for an Approve button. It asks
  that approval be evidence-gated (C1): under v1 policy every effect requires
  `filesystem_operator`, so Telegram is deny-only in practice. Lowering any effect's
  requirement to `chat_bound` is a separate authority decision (ADR + threat model), not a
  bar to clear — the bar only requires that the *gate* be correct, not that Telegram be
  able to approve anything.
- **No token-by-token streaming or edited progress.** One coalesced progress message is
  the ceiling, not a floor; live-editing message state is a non-goal (`COMMS_DESIGN` §19).
- **No delivery guarantee beyond honesty.** The bar does not require that every message be
  delivered — Telegram can be down. It requires that an undelivered or unknown message is
  represented truthfully and never resent blindly.
- **No new source of truth for delivery.** Delivery state is a view over the effect
  journal (B4); the bar rejects a parallel lifecycle rather than requiring one.
- **No cross-conversation visibility for users.** Operator visibility is separate; a
  correspondent sees only their own thread (E3).

## 7. Where Tamoz stands today

Grounded in the current branch, not aspiration.

### 7.1 What exists and helps

- The gateway is already the only sender and holds the credential; the worker/model never
  calls Telegram (`comms_gateway.rb`, ADR-042) — **C6 substantially met**.
- The two flows already exist as routes: `request_route` classifies each request as
  `direct_response`, `read_only_work`, or `managed_action`, and approval interrupts fire
  only on the last (`worker.rb`). Conversation and read-only work are already ungated — the
  substrate for evidence-gated approval (C1) is a routing decision that exists, not new.
- The effect journal already owns prepare/start/complete/attempts/receipts/`:unknown`
  (`COMMS_DESIGN` §20) — the substrate B4 requires already exists.
- Failures already carry a `Next action:` line, distinguish a rejected plan from a generic
  crash, and refuse to echo model output (`worker.rb` `failure_text`/`crashed_text`) —
  **partial A5/C7**.
- The queued-behind-earlier-work receipt variant already exists
  (`comms_gateway#accepted_reply`) — **partial A3**.
- A fenced poller lease and an idempotent, reserved delivery identity already exist —
  **partial B3/D4**.

### 7.2 What is missing or contradicted

- **C1 fails today.** The merged approve path is approve-*everything*: `resolve_callback`
  records an `approve` decision with no `required_evidence` check, so a `chat_bound`
  identity can release a `filesystem_operator` action — the fail-dangerous symmetry C1
  forbids. No ADR ratifies it (contract §2). This is the blocking gate; nothing else in
  section C grades green while it is open. The fix is exit 2 in §8, not a level.
- **A1/A2 fail today.** The first message still says "Accepted," which collapses the two
  axes and reads as success.
- **A5 partial.** There is next-action text but no closed, versioned reason-code registry;
  the reason class is not a stable, testable value.
- **A2 delivery axis absent.** A `DELIVERY_UNKNOWN` is not surfaced to the user or operator
  as a distinct state; there is no per-message delivery-truth view.
- **E2 absent.** No short non-secret request reference is shown to the user.
- **E1 not enforced.** Message budget (two/≤three) is not a tested bound.
- **E3 partial.** `/status` does not yet present the two axes, and there is no operator
  delivery-ambiguity/resolution view.

### 7.3 The standing

The channel is at **T0** with real T1/T3 substrate already in place. The cheapest path to
T1 is the state vocabulary and receipt wording (contract §11: change the contract and
vocabulary before wording or retries). **C1 is not a level; it is a gate — the bar cannot
reach a passing grade at any level while merged behavior contradicts the contract.**

## 8. How the design will be graded

1. Close the §2 reconciliation — either revert the approve path, or (recommended) replace
   approve-everything with evidence-gated approval whose v1 policy requires
   `filesystem_operator` for every effect (contract §7.1). Either restores deny-only
   behavior; the second keeps the door ratifiable. Until one lands, grade = blocked.
2. Grade each criterion A–E strictly by executed proof. A criterion with a partial today
   is not a pass; it is a partial with a named remaining test.
3. State the level each slice reaches, and do not claim a level whose lower levels have an
   open row.
4. The live ALMS end-to-end case (E4) is the single most load-bearing proof: it exercises
   truthfulness, atomicity, recovery, security, and UX on one real request. It is the last
   gate, not the first.

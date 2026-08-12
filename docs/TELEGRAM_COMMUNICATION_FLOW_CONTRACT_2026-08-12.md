# Telegram communication flow contract

Status: design approved after four review iterations. This document is deliberately
implementation-free.

## 1. Decision to make

The current Telegram experience tells the user that work was “accepted” and later
that it failed. That sequence is technically explainable but semantically weak:
“accepted” sounds like a successful task outcome, while the implementation uses it
for durable admission into an asynchronous queue.

The communication contract must therefore separate two facts:

1. **Task state:** what Tamoz has done with the user's request.
2. **Delivery state:** whether Telegram has delivered the corresponding message.

No user-facing message may imply task success until the task has reached a verified
terminal outcome. A durable queue acknowledgement is a receipt, not a success claim.

## 2. Evidence from the current branch

The current branch is `comms/conversational-ux`. The relevant path is:

- `CommsGateway#admit_request` calls `admit_and_enqueue`, then appends an
  `accepted` control delivery from `accepted_reply`.
- `Worker#settle` later emits `request.completed`, `request.failed`,
  `request.blocked`, or an approval pause.
- `OutboxDeliverySink` maps those events to Telegram delivery kinds.
- `DeliveryDrainer` sends the durable outbox rows and records success or ambiguity.

The important consequence is:

```text
Telegram update
  -> durable admission
  -> “Accepted...” delivery
  -> asynchronous worker execution
  -> terminal task outcome
  -> terminal Telegram delivery
```

The “accepted then failed” observation is therefore not a single state changing
from success to failure. It is an admission receipt followed by a separate task
outcome. The present wording hides that distinction.

The branch already improves queued follow-ups by saying “Queued behind earlier
work,” but the first message still uses “Accepted” and the failure message is
generic. The design also has an independent external-delivery ambiguity: a task
may complete while its Telegram send is pending, failed, or unknown.

There is one contract conflict that must be resolved before implementation: the
repository design says Telegram is deny-only, while parts of the current branch
encode both `approve` and `deny` callback actions. This report does not silently
bless the broader authority. The target flow keeps Telegram deny-only; local
operator approval remains the only approval path until a new authority decision
and threat-model review explicitly changes that policy.

## 3. Current user flow

### 3.1 Normal request

1. Telegram long polling receives an update.
2. The gateway authenticates and admits the bound correspondent and conversation.
3. The request is durably enqueued, or identified as a duplicate.
4. The gateway adds an `accepted` control delivery.
5. The worker claims the request and executes the session.
6. The worker settles the occurrence as completed, failed, blocked, stopped, or
   paused for approval.
7. The worker projects the lifecycle event to the delivery outbox.
8. The gateway sends the outbox delivery to Telegram.

### 3.2 What the user currently infers

The user sees:

```text
Accepted. I will report committed progress.
...
Work failed before verified completion.
```

The user reasonably infers that Tamoz first accepted the work as valid and then
failed to perform it. The system actually only established that it accepted the
request into durable processing.

### 3.3 Current weak points

- “Accepted” conflates receipt, queue admission, plan acceptance, and task success.
- A failure can be generic even when a safe, actionable reason is available.
- The user is not given a stable request reference for `/status` or support.
- Task outcome and Telegram delivery outcome are not expressed as separate states.
- Progress is not consistently tied to a state transition or latency threshold.
- An approval pause, worker outage, MCP outage, plan rejection, and delivery
  ambiguity can all feel like “it stopped working.”
- A Telegram send can be unknown without the user receiving a truthful statement
  about that uncertainty.

## 4. Optimal flow

### 4.1 State model and atomic boundaries

One request has several related but non-interchangeable records. A single
`delivery_state` is insufficient because one request can have a receipt, progress
message, approval prompt, and terminal result.

#### Admission/request state

```text
ADMISSION_PENDING -> ADMITTED
                  |-> REJECTED
```

`ADMITTED` means the request, idempotency identity, and receipt delivery intent
were committed durably. The receipt intent is created in the same transaction as
admission. If the process dies before Telegram sends it, the receipt remains
`PENDING`; an admitted request must not exist without a repairable receipt intent.

#### Canonical task state

```text
ADMITTED -> QUEUED -> RUNNING
                    |-> RETRY_SCHEDULED -> RUNNING
                    |-> WAITING_OPERATOR_DECISION -> DECISION_APPLYING
                    |                                      |-> RUNNING  # operator approval
                    |                                      |-> DENIED   # Telegram denial
                    |-> COMPLETED
                    |-> FAILED_FINAL
                    |-> BLOCKED_UNKNOWN
                    |-> STOPPED
                    |-> CANCELLED
```

`RETRY_SCHEDULED`, `WAITING_OPERATOR_DECISION`, and `BLOCKED_UNKNOWN` are not
success. The task is terminal only at `COMPLETED`, `FAILED_FINAL`,
`BLOCKED_UNKNOWN`, `STOPPED`, `CANCELLED`, or the explicit `DENIED` outcome.

#### Execution-attempt state

```text
QUEUED -> CLAIMED(owner, fence, lease)
       -> RUNNING -> SUCCEEDED
                  |-> FAILED_RETRYABLE -> RETRY_SCHEDULED
                  |-> FAILED_FINAL
                  |-> OWNER_LOST -> QUEUED or BLOCKED_UNKNOWN
```

The task-to-attempt mapping is authoritative: `SUCCEEDED` may produce task
`COMPLETED` only after verification; `FAILED_RETRYABLE` may produce task
`RETRY_SCHEDULED` only under policy; `FAILED_FINAL` produces task `FAILED_FINAL`;
an ambiguous effect produces task `BLOCKED_UNKNOWN`. A denial decision produces
terminal task `DENIED` after the decision intent is applied; it cannot be claimed
again. No exception class alone chooses a retry.

#### Effect state

```text
NOT_STARTED -> PREPARED -> EXTERNAL_CALL_STARTED -> COMMITTED
                                                   |-> UNKNOWN
UNKNOWN -> RECONCILED_COMMITTED|RECONCILED_NOT_COMMITTED
```

`PREPARED` is strictly before the external call. A successor may take over from
`NOT_STARTED` or `PREPARED` after the owner lease expires. Once
`EXTERNAL_CALL_STARTED` is recorded, a lost response is `UNKNOWN`; no successor
may guess whether the effect happened. The fenced CAS to
`EXTERNAL_CALL_STARTED` commits before invoking the external service. If the
process dies after that marker, the outcome is conservatively `UNKNOWN` even if
the call may not yet have reached the peer.

#### Logical-message delivery state

Each logical message has its own immutable identity and sequence:

```text
PENDING -> CLAIMED(owner, fence, expiry)
        -> SEND_STARTED -> DELIVERY_COMPLETED
                        |-> FAILED
                        |-> UNKNOWN
CLAIMED -> PENDING       # owner lost before the network call
UNKNOWN -> DELIVERY_COMPLETED|FAILED|ABANDONED
FAILED|ABANDONED -> RETRY_AUTHORIZED -> new delivery identity -> PENDING
```

`DELIVERY_COMPLETED` is the canonical durable term for a transport receipt;
“sent” is only informal user wording. A claim may be reclaimed only before
`SEND_STARTED`. Once a send has started and the response is lost, the state is
`UNKNOWN` because Telegram may have accepted the message. `UNKNOWN` is resolved
with a compare-and-set on the exact delivery version; the first operator wins and
later resolutions return that recorded outcome. Retry authorization is possible
only after an explicit `FAILED` or `ABANDONED` resolution and atomically creates
a new delivery identity. The fenced CAS to `SEND_STARTED` commits before the
Telegram network call. If the process dies after that marker, delivery is
conservatively `UNKNOWN` even if the call may not yet have reached Telegram.

The durable atomic boundaries are:

1. admission + request idempotency record + receipt delivery intent;
2. execution outcome + terminal delivery intent;
3. approval decision consumption + prompt state transition + idempotent decision-
   application intent.

The physical Telegram send is never part of task execution. A task must not be
re-executed because a Telegram delivery is pending or unknown.

Every running attempt carries an owner id, monotonically increasing fence, lease
expiry, heartbeat, and attempt deadline. A successor may take over only after
lease expiry and only from `NOT_STARTED` or `PREPARED`; an `UNKNOWN` effect makes
the task `BLOCKED_UNKNOWN`. Reconciliation is operator-controlled and can
authorize a new, explicitly identified operation; it cannot silently rerun an
ambiguous effect.

#### Identifiers

Keep separate immutable identifiers for Telegram update, admission request,
occurrence, execution attempt, logical delivery, approval prompt, and external
effect. The user sees only a collision-resistant short request reference. It is
for support and `/status`, not an authority token; no short reference, delivery
id, or Telegram update id authorizes an action.

### 4.2 User-visible lifecycle

| State | User-facing message | Meaning | Next action |
|---|---|---|---|
| Queued | `Received. Queued as <short-id>. I’ll report the outcome here.` | The request is durably admitted, not successful | Wait or use `/status` |
| Running | `Working on <short-id>…` | A worker has claimed the request | Wait |
| Waiting operator decision | `Waiting for an operator decision to continue <short-id>.` | The task is intentionally paused; Telegram may deny only in v1 | Use the Telegram Deny action or local `tamoz approve`/operator workflow |
| Completed | The verified answer, followed by `Completed.` | The requested result passed the configured completion/verification gate | None |
| Retry scheduled | `Retry scheduled for <short-id>; do not send it again.` | A bounded, policy-approved retry is scheduled | Wait |
| Failed final | `I couldn’t complete <short-id> because <safe reason>. No verified result was produced.` | No verified result; automatic retry is not safe or useful | Correct the request/configuration and send again |
| Blocked unknown | `I can’t confirm the outcome of <short-id>. No automatic retry was made.` | An external effect has ambiguous outcome | Operator reconciliation or an explicit new request |
| Stopped/cancelled | `Stopped <short-id> before verified completion.` | Work ended intentionally or by budget/cancel policy | Send again if desired |

The words **accepted**, **successful**, and **completed** must not appear in the
receipt unless they refer to the exact state described. “Accepted plan” remains an
internal planning event and is not a Telegram task outcome.

### 4.3 Message budget

For a fast request without approval, the ideal user experience is two logical
messages:

1. One durable receipt (`Queued` or `Running`).
2. One terminal result (`Completed`, `Failed`, `Blocked`, or `Stopped`).

For a slow request, send at most one coalesced progress message after the configured
latency threshold, then exactly one terminal result. Approval has its own one
logical prompt, which may be edited to show denial; it does not create a separate
decision-ack message. Progress must correspond to a real durable state transition
or a bounded heartbeat; it must never simulate work. The threshold, coalescing
identity, and maximum count are configuration and test inputs, not prose promises.

Duplicates and crash recovery may replay a delivery internally, but deterministic
delivery identity must prevent duplicate user-visible lifecycle messages.

## 5. ALMS live-test flow

For the target request, “Query the latest ALMS learnings, summarize them, and send
the result here”:

1. **Receipt:** `Received. Queued as <short-id>. I’ll query ALMS and report the
   verified summary here.`
2. **Execution:** The worker uses a minimal pinned ALMS capability surface. For
   this test, the allowlist is `mcp:alms/learning.search`, with
   `mcp:alms/learning.get` only if search returns identifiers that must be
   expanded. The pin includes server id, tool name, argument schema digest,
   effect class, and catalog digest. `sync`, discovery, unknown tools, and
   mutation effects are refused. The model does not send Telegram directly; the
   worker produces an answer and the gateway owns Telegram delivery.
3. **Success:** The answer includes the bounded summary, the time/window used,
   source references or learning identifiers when available, and a clear
   `Completed.` marker only after the completion gate passes.
4. **No data:** `ALMS query completed, but no learnings matched the requested
   window.` This is a completed empty result, not a failure.
5. **ALMS unavailable:** `I couldn’t query ALMS because the configured ALMS
   service was unreachable. No verified summary was produced. Safe next action:
   retry after ALMS connectivity is restored.`
6. **Model/plan rejection:** Explain that no executable plan passed review, without
   echoing sensitive model output, then give a concrete rephrasing or configuration
   next step.
7. **Telegram delivery ambiguity:** Record the task outcome independently, mark
   that logical delivery `UNKNOWN`, alert the operator, and never claim the user
   received the result or silently resend it.

Private plaintext HTTP, if retained for the isolated ALMS test, is an explicit
operator-only exception and is not secure transport. It must use an approved
private-address allowlist, reject redirects, keep endpoint details out of user
errors, and carry no credential headers. HTTPS is required whenever credentials
or credential headers are used. The exception is visible in operator configuration
and audit evidence.

## 6. Failure semantics

The system must classify failure before choosing wording.

| Failure class | Task result | Automatic retry | User message requirement |
|---|---|---:|---|
| Request not admitted | Rejected | No | Explain refusal; do not send a success-like receipt |
| Worker unavailable before claim | Queued | N/A | Keep the receipt truthful; `/status` shows queued |
| Temporary ALMS/network/model failure | Attempt failed; retry may be scheduled | Only when the operation is safe and bounded | Name the safe reason class and retry policy |
| Invalid request or rejected plan | Failed final | No | Give a useful correction; do not expose internal prompt/review text |
| Operator decision required | Waiting operator decision | No | State that Telegram may deny; local operator workflow may approve |
| Budget/explicit stop | Stopped | No automatic retry | State that no verified completion was claimed |
| Ambiguous external effect | Blocked unknown | No blind retry | State uncertainty and require reconciliation/new request |
| Telegram send timeout after request | Task outcome is independent; delivery `UNKNOWN` | No blind resend | Task and per-message delivery status remain separate |

“Work failed” is not sufficient by itself. Every terminal failure needs:

- a short request reference;
- a safe reason class;
- whether a verified result exists (normally no);
- whether retry is safe;
- the next action;
- an operator-visible correlation id and durable event.

The user-facing reason is selected from a fixed taxonomy, not copied from an
exception or model response. The minimum taxonomy is:

`ADMISSION_REFUSED`, `QUEUE_WAIT`, `WORKER_UNAVAILABLE`, `ALMS_UNREACHABLE`,
`ALMS_AUTH_FAILED`, `ALMS_SCHEMA_MISMATCH`, `PLAN_REJECTED`,
`VERIFICATION_FAILED`, `BUDGET_EXHAUSTED`, `OPERATOR_DECISION_REQUIRED`, `CANCELLED`,
`DELIVERY_UNKNOWN`.

Each code has a fixed safe user template, a retryability policy, and a separate
operator detail. Telegram text never directly interpolates model output, ALMS
content, URLs, credentials, private addresses, exception messages, stack traces,
or raw tool responses. The renderer whitelists fields, strips control characters,
enforces byte and line limits, and redacts before persistence and delivery.

## 7. Approval and ambiguous-delivery contracts

### 7.1 Approval is operator decision, not Telegram authority

The v1 target remains deny-only on Telegram. The approval entity is:

```text
PROMPT_PENDING -> ACTIVE -> DENIED
               |        |-> EXPIRED
               |        |-> CANCELLED
               |        |-> UNKNOWN
               |-> DELIVERY_FAILED
ACTIVE -> CONSUMED_BY_OPERATOR -> RUNNING
```

Telegram may deny an active prompt. Local operator workflow may approve it. A
Telegram `approve` callback is rejected as an unsupported action until a separate
authority decision changes the design and its threat model.

Before consuming a Telegram callback, the gateway must atomically verify:

- active prompt status and unexpired time;
- opaque reference digest;
- surface id and surface revision;
- bound correspondent id;
- exact conversation/chat id;
- exact originating message/receipt identity;
- exact thread and occurrence;
- exact interrupt digest;
- callback action is `deny`.

Any mismatch records a durable refusal and creates no decision. Consumption of the
prompt and recording of the denial are one transaction. A callback reference is
never itself an authority token.

Both Telegram denial and local operator approval create an idempotent decision-
application intent in the same transaction as prompt consumption. The worker
applies that intent under its own fence:

```text
DECISION_INTENT: PENDING -> CLAIMED -> APPLIED
                              |-> RETRYABLE_FAILURE -> PENDING
```

A crash after prompt consumption but before application therefore leaves a
durable intent, not a permanently waiting task. Local approval invalidates the
Telegram Deny action for that prompt. Telegram denial never creates an approval.

The prompt outcome maps to task state as follows: a denial creates a decision
intent, moves the task through `DECISION_APPLYING`, and ends it at terminal
`DENIED` without another claim or execution; local approval moves it through
`DECISION_APPLYING` and back to `RUNNING`. Expiry or cancellation without a
consumed decision transitions the task to terminal `STOPPED`. Reissue is a new
prompt identity, never a resurrection of the old prompt.

Local approval has the same exactness requirements as Telegram denial, plus an
authenticated and authorized operator identity. It must compare-and-consume the
active, unexpired, unconsumed prompt against the exact surface revision, thread,
occurrence, interrupt digest, and prompt identity; a short request reference alone
is insufficient. The audit records operator identity, reason, timestamp, and
evidence. Stale, replayed, cross-thread, or cross-surface approvals are refused.

### 7.2 Unknown delivery resolution

`UNKNOWN` is resolved only by an authenticated operator on the exact logical
delivery id. The operator action is audited with identity, reason, timestamp,
evidence, and a resolution kind. The canonical allowed transitions are:

```text
UNKNOWN -> DELIVERY_COMPLETED
        |-> FAILED
        |-> ABANDONED
FAILED|ABANDONED -> RETRY_AUTHORIZED -> new delivery identity -> PENDING
```

The normal receipt path uses `DELIVERY_COMPLETED`; an operator-confirmed
`UNKNOWN -> DELIVERY_COMPLETED` is distinguished by the audit resolution kind,
not by a second public delivery state. The compare-and-set winner is the only
resolution; later operators receive the recorded outcome. No automatic retry
occurs. A Telegram user cannot resolve an unknown delivery, re-execute the task,
or convert uncertainty into success.

An approval prompt has an additional recovery rule: `UNKNOWN -> DELIVERY_COMPLETED`
activates the prompt only after operator confirmation; `UNKNOWN -> FAILED` transitions the
prompt to `DELIVERY_FAILED`; reissue creates a new prompt identity and invalidates
the old one; `ABANDONED` transitions the task to `STOPPED` unless a new prompt is
explicitly issued. No old callback reference is reactivated.

## 8. Non-negotiable invariants

1. A receipt acknowledges durable admission only. It never promises task success.
2. Admission, its idempotency record, and its receipt delivery intent commit
   atomically, or a repairable `RECEIPT_PENDING` state remains visible.
3. Every admitted request reaches one execution outcome or an explicit waiting/
   retry state; retryable attempts do not masquerade as final failure.
4. Execution outcome and terminal delivery intent commit atomically. Physical
   Telegram delivery remains asynchronous and never causes task re-execution.
5. Every logical message has its own durable identity, sequence, and delivery state.
6. A gateway sends only after a successful fenced claim; pacing waits must renew or
   extend the claim before its expiry.
7. Task outcome and Telegram delivery outcome are separate facts.
8. `UNKNOWN` delivery is never represented as `SENT`, `COMPLETED`, or silently
   retried.
9. A failure never echoes secrets, raw credentials, untrusted model text, URLs,
   private addresses, or an internal stack trace into Telegram.
10. A failure message is actionable and distinguishes retryable from final failure.
11. Progress messages are generated only by durable state transitions or bounded
    heartbeats, never by optimistic narration.
12. Duplicate updates, worker restarts, gateway restarts, and outbox replays do not
    create duplicate logical lifecycle messages.
13. Telegram approval is deny-only and every callback is bound to the exact prompt
    context listed in §7.1.
14. `/status` exposes only the requester's own bound conversation state; operator
    status exposes delivery ambiguity and resolution controls.
15. The live ALMS test uses a pinned minimal read-only capability surface and the
    worker/model cannot access Telegram credentials or call Telegram directly.

## 9. Acceptance criteria for the highest bar

The flow is ready for implementation only when all of these deterministic oracles
pass:

### Truthfulness

- A successful ALMS query produces one durable receipt, one verified result, and no
  success-like message before the result is verified.
- A failed ALMS query produces one receipt plus an actionable failure with a fixed
  reason code, retryability, and next action.
- A queued request is visibly queued, not described as completed or running.
- A waiting operator decision is visibly waiting; Telegram can deny but cannot
  approve.
- An empty ALMS result is distinguished from ALMS outage and task failure.
- A fast request has at most one receipt and one terminal logical message; a slow
  request has at most one coalesced progress message in addition to those.

### Atomicity and recovery

For each fault point, record the task/attempt/effect/delivery rows, logical-message
count, observed Telegram sends, and convergence deadline:

| Fault point | Required oracle |
|---|---|
| After inbound update, before admission commit | No request exists and no receipt exists |
| After admission commit, before receipt send | One admitted request and one `RECEIPT_PENDING`/`PENDING` receipt intent |
| After claim, before execution | One running attempt; restart resumes or finalizes it once |
| During ALMS call | Retry only under the pinned idempotency policy; no duplicate terminal message |
| After execution outcome, before delivery intent | One outcome and one terminal intent after recovery; no re-execution |
| Delivery owner lost in `CLAIMED`, before network call | Reclaim to `PENDING`; no Telegram call by the lost owner |
| Fenced `SEND_STARTED` commit fails | No Telegram call; delivery remains `PENDING` under the owner rules |
| Process dies after `SEND_STARTED`, before Telegram response | Delivery is `UNKNOWN`; no automatic resend |
| After Telegram delivery receipt | Delivery is `DELIVERY_COMPLETED`; replay does not create another logical message |
| During approval prompt send | Prompt is not active unless its send receipt is durable |
| During callback consumption | At most one exact denial; mismatches create no decision |
| After callback commit, before worker application | One durable decision intent; restart applies it exactly once and denial ends at `DENIED` |
| Approval prompt send becomes `UNKNOWN` | Prompt stays inactive until operator resolution; reissue uses a new prompt identity |
| After effect `PREPARED`, before external call | Takeover is safe because `PREPARED` is strictly pre-call |
| Fenced `EXTERNAL_CALL_STARTED` commit fails | No external call; effect remains `PREPARED` under the owner rules |
| Process dies after `EXTERNAL_CALL_STARTED`, before response | Effect is `UNKNOWN`; task is `BLOCKED_UNKNOWN`; no automatic rerun |
| Worker owner lost before execution | Takeover is allowed only after lease expiry and fence validation |
| Worker owner lost after an ambiguous effect | Task becomes `BLOCKED_UNKNOWN`; no automatic takeover or rerun |

The delivery tests also inject a lost claim, a claim-expiry during rate-limit
pacing, and two concurrent drainers. A non-owner must make no Telegram call, and
the same logical delivery must not be sent concurrently by two owners.

The execution task may become terminal while its delivery remains pending or
unknown. The terminal outcome must never be rerun merely to make Telegram delivery
converge.

### Retry and queue liveness

- Every retry policy states maximum attempts, deadline, backoff, idempotency basis,
  and the transition to `FAILED_FINAL`.
- A retryable attempt is not user-visible as final failure while a retry is
  scheduled.
- A queued request has a durable queue-age signal. Every running attempt has an
  owner id, fence, lease expiry, heartbeat, and deadline; takeover is permitted
  only after lease expiry and fence validation. A silent stale queue is an
  operational failure, not an indefinite “working” state.
- Approval prompt delivery, expiry, denial, cancellation, worker restart, and
  prompt ambiguity each have explicit state transitions; expiry/cancellation map
  to terminal task `STOPPED` unless a new prompt is explicitly issued.

### UX and operations

- Every message has a short non-secret reference usable in `/status` and logs.
- Failure messages use only the fixed reason-code renderer and provide retryability
  and next action.
- Telegram `/status` shows only the caller's task and per-message delivery states;
  `tamoz status` shows all operator-scoped delivery ambiguity and audit transitions.
- Operators can distinguish admission, worker, ALMS, model, approval, and Telegram
  delivery failures from one status view.
- The live ALMS test proves query, summary, verification, and same-chat Telegram
  delivery with terminal evidence and durable state.

### Security

- Callback presses cannot affect another user, chat, surface revision, occurrence,
  interrupt set, or approval action.
- Telegram receives only bounded, redacted, policy-approved text selected by the
  fixed renderer.
- The ALMS tool/schema/catalog/effect pin is checked before invocation.
- No model capability can directly send Telegram or bypass the outbox.
- Private HTTP is allowlisted and credential-free; HTTPS is mandatory for any
  credential-bearing connection.
- No credential, raw private-network detail, or raw tool/model output appears in a
  user-facing error or durable user-visible message.

## 10. Review log

Round 1 used three independent read-only reviewers:

| Perspective | Result | Design changes incorporated |
|---|---|---|
| UX and user trust | Not approved | Removed Telegram approval implication, defined message budgets, retryability wording, running/progress behavior, and user/operator `/status` ownership |
| Reliability and distributed systems | Not approved | Added atomic receipt/terminal intents, per-logical-message delivery state, attempt retry state, crash oracles, queue liveness, and explicit unknown resolution |
| Security and authority | Not approved | Added exact callback comparisons, deny-only policy, fixed redaction taxonomy, ALMS capability pin, private-HTTP constraints, identifier separation, and operator-only unknown resolution |

The first review round found no reason to abandon the two-axis model. It did find
that the initial draft was not implementation-ready because it left atomicity,
approval authority, delivery ownership, retry transitions, and redaction rules
implicit. Round 2 added the separate task/attempt/effect/delivery machines,
operator-only resolution, and exact crash oracles. Round 3 added durable
pre-call markers, compare-and-set unknown resolution, explicit approval decision
application, and terminal denial. The final three-way pass returned `APPROVED`
from UX, reliability, and security.

## 11. Design conclusion

The optimal flow is not “accepted, then maybe failed.” It is:

```text
received -> queued/running -> progress or approval when needed
         -> verified completed | actionable failed | blocked unknown | stopped
```

Each state is a truthful statement, and task state is never confused with delivery
state. The first implementation slice should therefore change the communication
contract and state vocabulary before changing message wording or adding retries.

No code change is authorized by this document. The communication contract is now
approved as the implementation target; implementation requires a separate
explicit request and must preserve the state machines and oracles in this report.

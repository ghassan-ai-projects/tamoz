# Lane B — Interaction and product experience review

## Scope and verdict basis

This review asks a narrower question than “is the chat durable?”: once durable state, identity, and delivery fencing are correct, can a person tell what happened, what is happening, what Tamoz needs, and what they can do next? The answer is currently **partly**. The implementation has a credible truth model, but the human contract is still mostly a projection of internal lifecycle vocabulary.

Evidence labels used below:

- **Fact** — directly observed in current source, tests, or current documentation.
- **Inference** — a product consequence of one or more facts.
- **Proposal** — a design recommendation for the refresh, not current behavior.
- **Hypothesis** — measurable claim to validate with users or a live benchmark.
- **Evidence gap** — something the current fixture or source does not establish.

The report does not treat OpenClaw’s communication preferences as universal. A terse operator, a first-time user, an accessibility-oriented user, and a user working from a noisy phone notification surface need different disclosure defaults. The durable contract should be stable; tone and optional detail should be configurable.

## 1. Current journey map

The durable facts are stronger than the conversational experience. The source model separates task state from delivery state (`gems/tamoz-comms/lib/tamoz/comms/lifecycle.rb:7-24`), and the worker emits a terminal projection before closing the occurrence (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:672-717`). That prevents several classes of lying. It does not, by itself, make the next human decision obvious.

| Journey | Current behavior, with evidence | Human weakness and likely cause |
|---|---|---|
| First contact | **Fact:** unpaired Telegram contact receives `This chat isn't paired yet...` plus an eight-character code; `/start <code>` reports that it is waiting (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_pairing.rb:17-40`; `test/comms_pairing_first_contact_test.rb:20-39,63-90`). **Fact:** allowlist mode gives an unlisted sender no turn and no answer by documented contract (`documentation/guides/telegram.md:47-52`). | The first message establishes security, but not a compact mental model: who must act, what expires, whether the user should wait, and how to know pairing completed. The code is deliberately held in an in-memory memo while the durable row stores only a digest (`gateway_pairing.rb:48-79`); a restart therefore creates a reconnect/return experience that is not explained to the user. **Inference:** secure first contact can still feel silent or bureaucratic. |
| Short ask | **Fact:** an admitted message gets a reference-bearing acknowledgement only after admission and enqueue; a queued follow-up says it is behind earlier work (`gateway_admission_acknowledgement.rb:8-29`; `test/comms_gateway_test.rb:160-205`). | The acknowledgement says “I will report committed progress,” but it does not say whether the user should stay, how to inspect the request, or what completion will look like. **Inference:** the reference is a durable handle, not yet a useful conversational object. |
| Long task | **Fact:** committed worker milestones reach the sink, but their Telegram text is exactly `r<ref>: <phase>` (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:123-161`). The fixture oracle explicitly checks that format (`gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:188-194`). | “claimed,” “running,” and “recovered” describe machinery, not progress toward the user’s goal. The first card can be edited after a receipt, but the product does not say what changed, how long the user may wait, or what to do if the card stops. **Inference:** delivery liveness can coexist with perceived silence or robot-like repetition. |
| Waiting / approval | **Fact:** a paused turn projects a waiting milestone and an approval request (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:720-734`). The Telegram approval text is always `An action needs your approval.`; the action/reference live in markup (`gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:192-220`). The CLI exposes a tool and preview for a human prompt (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_prompt_adapter.rb:20-32`). | Telegram gives the user a button without enough safe explanation of impact, scope, expiry, or why the turn is waiting. A deny-only button is safe but can feel like a dead end. **Inference:** “waiting” is technically visible but not cognitively actionable. |
| Changing direction | **Fact:** Telegram `/redirect r<ref> <task>` is reference-bound and queues a replacement (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_commands.rb:36-77`). Telegram `/cancel` has no reference argument and targets the current generation’s open work (`gateway_commands.rb:96-121`); the test confirms the reply is only `Cancellation requested.` (`test/comms_gateway_test.rb:361-395`). The CLI `redirect` and `cancel` take a thread, not a request reference (`documentation/reference/cli.md:53-64`; `gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:158-218`). | The two surfaces have related semantics but different handles. With multiple queued requests, “cancel” does not tell a user which one is affected. Redirect does not explicitly summarize what was superseded or whether already-committed work remains. **Inference:** a durable operation can be correct while the user fears they cancelled the wrong thing. |
| Failure / unknown delivery | **Fact:** a settled failure tells the channel that work failed and gives a next action, while a process crash uses a generic retry/rephrase sentence (`gems/tamoz-agent/lib/tamoz/agent/worker.rb:823-875`). An ambiguous external send becomes `unknown`, is not blindly retried, and is resolved by the operator command (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:222-233`; `documentation/guides/telegram.md:144-150`). | Safe unknown handling protects against duplicate external effects but offers no user-centered explanation of the split: “the work may be finished, but this message may or may not have arrived.” **Inference:** trust is protected at the system boundary but can be damaged at the conversation boundary if the user sees nothing. |
| Reconnect | **Fact:** restarting the gateway does not re-admit an already admitted message and terminal answers survive the send window (`documentation/guides/telegram.md:105-117`). The gateway itself runs silently; operators inspect `comms list` or `status --json` (`documentation/guides/telegram.md:119-133`). | The system recovers; the person has to discover recovery. There is no concise “since you were away” card containing active refs, last confirmed event, and next action. **Evidence gap:** no current real Telegram transcript or benchmark measures a reconnect from the user’s point of view; C4 only specifies durable boundary behavior (`docs/openclaw-chat-study/benchmark-protocol/scenarios/C4-restart-recovery-matrix.md`). |
| History / context | **Fact:** a Telegram follow-up includes prior user fragments in its durable turn payload (`test/comms_gateway_test.rb:160-194`). Confirmed terminal deliveries, not milestones, enter conversation history (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb:1084-1115`; `gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:63-73`). `/context` renders counts, preferences, observations, and whether a summary is pinned (`gems/tamoz-comms/lib/tamoz/comms/control_reply.rb:35-42`). | The context report tells an operator storage facts, not what Tamoz will remember in the next answer. “Fragments visible 0 of 1” and `preferences reasoning_depth=high` are inspectable but not friendly. **Inference:** context integrity can be excellent while context comprehension is poor. |
| Return after time away | **Fact:** durable CLI offers `list`, `show`, `follow-up`, `redirect`, `cancel`, and `resolve`; `show` renders status, plan digest, interrupts, and receipts (`documentation/getting-started/sessions.md:24-51`). | There is no tested return journey that starts with an old ref and answers “what changed, what is still waiting, and what can I safely do now?” **Evidence gap:** current C1–C9 cover identity, liveness, delivery, recovery, parity, approval, cancellation, and isolation, but not comprehension after elapsed time. |

### Root cause in five whys

1. A durable chat can feel unhelpful even when the state is right because the user cannot map the output to a decision.
2. The output is mostly a lifecycle/status projection rather than a goal-oriented update: `state_axes` emits `phase`, `event`, `effect`, and `capability` (`gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_status.rb:56-60`).
3. The same projection boundary deliberately excludes model output and raw remote content (`gems/tamoz-agent-session/lib/tamoz/agent/session_status_projection.rb:5-8`), but no separate human-summary layer fills the gap.
4. Rendering currently splits and bounds text; it does not define cards, priority, tone, elapsed-time language, or next-action copy (`gems/tamoz-comms/lib/tamoz/comms/rendering.rb:7-50`).
5. The implementation bar proves plumbing and safety, while real-provider usefulness is explicitly deferred (`docs/openclaw-chat-study/implementation-plan/00-implementation-bar.md`; `test/benchmark_comms_b0_test.rb:6-11,282-338`).

**Conclusion:** the missing capability is a small, typed human-communication contract over the existing durable facts—not a second runtime and not an assumption that a model can narrate its own lifecycle safely.

## 2. Missed interaction weaknesses

1. **Reference without orientation.** The ref is stable and caller-bound, but user copy does not consistently carry it through terminal answers. Completion uses the verified answer or `Completed.` and optional artifact line (`worker.rb:796-810`); it does not add a request header. A user with two tasks cannot reliably scan a chat transcript.

2. **Internal vocabulary leaks into the status surface.** `/status` intentionally translates the task and delivery axes, but still emits `effect`, `capability`, event kind, phase, and numeric queue age (`gateway_status.rb:18-38,56-78`). These are useful in JSON/operator diagnostics, not a default mobile conversation.

3. **Progress is liveness, not meaning.** A bounded update is not necessarily useful progress. The current bound is 32 milestone rows per request (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:22-24`), and the fixture checks count/backing/coalescing, not whether a person understood the update (`openclaw_comms_oracles.rb:140-163`).

4. **Approval is safe but under-explained.** The current prompt deliberately takes evidence from the engine decision and offers only policy-permitted actions (`outbox_delivery_sink.rb:197-220,248-265`). That is the right authority boundary. The missing product layer is a bounded, redacted explanation of “what would happen,” “why now,” and “what happens if you deny.”

5. **The command model is not yet a unified conversation model.** Telegram has `/new`, `/status <ref>`, and ref-bound redirect; the durable CLI has no `new` subcommand in its documented interactive set (`documentation/reference/cli.md:49-64`) and uses thread handles for redirect/cancel. This is not necessarily a correctness defect, but it is a discoverability and parity defect.

6. **Unknown delivery has no user recovery affordance.** The operator can resolve `unknown`, as required by the safety model, but the human-facing contract does not define a safe “show me the last confirmed answer” or “tell me whether I need to ask again” response. A retry button would be unsafe; silence is also costly.

7. **Launch topology is invisible to the user.** The Telegram guide states that the gateway can admit work while a missing worker means “nothing is ever answered” (`documentation/guides/telegram.md:90-103`). That is operationally honest, but the user receives no clear distinction between accepted-but-not-running and model work that is merely slow.

8. **Model quality and plumbing are conflated by the absence of a live usefulness track.** The current B0 runner uses real SQLite/gateway/worker/outbox seams with a fake transport and deterministic provider (`test/benchmark_comms_b0_test.rb:6-11`). Its latency metrics are unavailable because wall-clock latency is not fixture-controlled (`gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/openclaw_comms_oracles.rb:148-156`). A beautiful card cannot make a weak answer useful; a strong answer cannot repair an invisible or misleading lifecycle.

## 3. Proposed conversation contract

The proposal is a human projection over the existing task and delivery axes. It must never invent a state, imply approval, or turn a presentation update into conversation history.

### 3.1 State and card contract

**Proposal — shared semantic states:**

```text
submitted
  -> accepted(ref)
  -> queued | working
  -> waiting_for_you | blocked_on_operator | working
  -> completed(verified | response_only)
   | failed
   | stopped

Every task state has a separate delivery state:
  pending | delivered | failed | unknown
```

The user-visible card has five bounded fields:

```text
[r7f3a91c2e · Working]
Task: make the landing page blue
Now: applying the approved change
Next: I’ll verify the result and send the answer
Controls: /status r7f3a91c2e · /cancel r7f3a91c2e
```

**Proposal — card rules:**

- `accepted` is emitted only after durable admission, and says “I have it” plus the ref.
- `queued` says “waiting behind N request(s)” and gives the ref; it does not say “working.”
- `working` names a human-safe phase (“checking the workspace,” “preparing a change”), not an event kind, capability id, effect key, or raw tool name.
- `waiting_for_you` names the decision category and one next action. A waiting card is never the only notice.
- `blocked_on_operator` says that local/operator action is required. It never suggests that a Telegram denial granted anything.
- `completed` always includes the ref and one of `Verified`, `Response only`, or `Not verified`; model answer content remains separately attributable.
- `failed` says whether work began, gives a bounded reason category, and gives one next action. It does not echo raw provider errors or model-review prose.
- `stopped` distinguishes “stopped before the next effect” from “an external effect may already have happened.”
- `delivery unknown` is explicit and never rendered as delivered or retried automatically.

The card is a presentation projection. Only terminal answer/failed/stopped/blocked content that has a successful delivery receipt enters future conversation history, preserving the current rule (`comms_store.rb:1084-1115`).

### 3.2 Affordances and transition rules

**Proposal — Telegram affordances:**

- `/help` shows the lifecycle in one example and the four primary controls: `/status [ref]`, `/cancel ref`, `/redirect ref new task`, `/new`.
- `/status` without a ref returns “current work” plus a compact list of other open refs, rather than one ambiguous aggregate.
- `/status ref` returns the card, last confirmed transition time, delivery state, and the safe next action.
- `/cancel ref` returns “Cancellation requested for ref,” then the card transitions through `Stopping` to `Stopped`, `Completed before cancellation`, or `Failed before cancellation`. It must not claim an in-flight external effect stopped.
- `/redirect ref new task` explicitly says “The old goal remains recorded; a replacement request was queued as ref2.”
- `/new` says what changes (“future messages start a fresh generation”) and what does not (“earlier delivered history remains queryable”).
- Approval buttons remain evidence-gated and deny-only under the current policy. A future grant must be a policy/ADR decision, not a UI decision.

**Proposal — durable CLI affordances:**

- Human TTY mode begins an attached durable ask with `Accepted ref …` before waiting for execution, then shows only the same semantic cards as Telegram.
- `--json` remains an event stream with identity and internal fields for automation; it is not the human transcript.
- `status/show` renders both a friendly summary and an explicit `--diagnostic` view. Existing receipt, plan, and capability details remain available but cease to be the default first read.
- CLI controls accept the same short ref where the operation is request-scoped; thread remains the storage/authority handle behind it.
- A long-running TTY can use `Ctrl-C` as “request cancellation,” followed by a durable result, rather than making local interruption look like confirmed remote stop.

**Proposal — return/reconnect behavior:** on a fresh connection or `status` after a gap, show at most one “Since you were away” card per conversation with active refs, last confirmed state, and next action. It is a read-only projection and must not re-send an unknown terminal answer automatically.

### 3.3 Progressive disclosure

**Proposal — three levels:**

1. **Attention line:** state, ref, and one sentence. Suitable for Telegram notification preview and CLI TTY.
2. **Action detail:** what is waiting, safe controls, delivery state, and bounded artifact/result summary.
3. **Diagnostics:** event/effect/capability ids, sequence, raw bounded JSON, and operator recovery commands; available by explicit `/status ref --diagnostic` or CLI JSON/show.

The default should optimize for “what should I do?” rather than “which internal subsystem emitted this?” Tone, emoji, verbosity, and update cadence can be preferences; state truth, authority, redaction, and unknown handling cannot.

## 4. Concrete transcript/message cards

The “current” lines below are exact current outputs. The “proposed” cards are deliberately labeled proposals and are not claims about the current implementation.

### Example A — first contact and short ask (Telegram)

**Current (Fact):**

```text
This chat isn't paired yet. Read this code to your operator for approval: Q8K2M7P4
```

Evidence: `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_pairing.rb:17-27`; `test/comms_pairing_first_contact_test.rb:20-39`.

**Proposal:**

```text
This bot is not connected to your operator yet.
1. Send code Q8K2M7P4 to the operator.
2. The code expires in 15 minutes.
3. After approval, send your request again.

Try /start Q8K2M7P4 to check whether approval is still pending.
```

After binding:

```text
Accepted r7f3a91c2e · queued
I have your request: “Summarize the latest ALMS findings.”
I’ll send one answer when it is complete.
Check: /status r7f3a91c2e
```

### Example B — long task and approval (Telegram)

**Current (Fact):**

```text
Accepted r7f3a91c2e. I will report committed progress.
r7f3a91c2e: claimed
r7f3a91c2e: waiting
An action needs your approval.
```

Evidence: `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission_acknowledgement.rb:8-19`; `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:128-161,192-220`.

**Proposal:**

```text
r7f3a91c2e · Waiting for operator approval
I prepared a workspace change for “make the landing page blue.”
Why I’m waiting: this action can modify files.
What you can do: the local operator must review it; Telegram can deny this request.
Until then, no change is applied.
```

Buttons: `Deny` · `Status` (no approve button while the decision requires `filesystem_operator`). The card must not expose secrets, unrestricted arguments, or model-generated instructions.

### Example C — durable CLI attached ask and completion

**Current (Fact):** human runtime events include `Working...`, route, plan steps with tool names, review, and `Running <tool>...`; stream rendering only prints custom/interrupt/error parts in human mode (`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:387-449,846-876`).

**Proposal:**

```text
Accepted r19b4d2a10 · thread fix-parser
Queued behind 0 requests.

r19b4d2a10 · Working
Checking the parser and its tests.

r19b4d2a10 · Completed · Verified
The parser now rejects malformed input before it reaches the decoder.
Checks: 12 passed.
Details: tamoz show fix-parser --request r19b4d2a10
```

The same semantic events in JSON may include execution ids, phases, and receipt metadata. The human output should not force a user to understand route selection or internal tool names to know whether the task worked.

### Example D — changing direction and cancellation with two requests

**Current (Fact):** Telegram redirect accepts a ref, while cancellation says only `Cancellation requested.` and selects current-generation open work (`gateway_commands.rb:36-47,96-121`; `test/comms_gateway_test.rb:361-395`).

**Proposal:**

```text
User: /status
Tamoz: 2 requests are open:
       r1111111111 · Working · “prepare the report”
       r2222222222 · Queued · “also draft an email”
       Use /status <ref>, /cancel <ref>, or /redirect <ref> <new task>.

User: /cancel r2222222222
Tamoz: Cancellation requested for r2222222222 · Queued.
       I’ll confirm whether it was stopped before it ran.

User: /redirect r1111111111 only compare the two release candidates
Tamoz: Replacement queued as r3333333333.
       r1111111111 remains recorded; committed work is not undone.
```

### Example E — ambiguous delivery / recovery

**Proposal:**

```text
r7f3a91c2e · Completed, delivery uncertain
The task reached a terminal state, but the last message may or may not have arrived.
I will not send it again automatically because that could duplicate an external message.

Next: ask the operator to inspect/resolve delivery, then use /status r7f3a91c2e.
```

This wording makes the safety tradeoff visible without pretending that a Telegram user can resolve an unsafe external effect. It corresponds to the current operator-only `comms delivery resolve` path (`documentation/reference/cli.md:134-149`).

### Example F — return after time away and context

**Proposal:**

```text
Since you were away
r7f3a91c2e · Waiting for operator approval
Last confirmed: prepared a file change.
Next: review locally; no effect has been applied.

Context for the next turn
• New messages use conversation generation 2.
• 3 delivered answers are available.
• 1 earlier summary is pinned; progress cards are not remembered as answers.
Use /context for detail or /status r7f3a91c2e for the task.
```

The final bullet preserves the current history rule while translating it into a user mental model.

## 5. Noise and notification budget

**Current facts:** the implementation has a per-request milestone ceiling of 32 rows (`gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb:22-24`) and descriptor examples use 1 message/second per chat and 25 globally (`test/comms_cli_test.rb:242-255`). Milestones are bounded/coalesced and excluded from history (`outbox_delivery_sink.rb:48-54,123-161`; `test/canonical_cross_surface_composition_test.rb:392-405`). These are delivery/resource controls, not a human attention budget.

**Proposal — default human budget per request:**

| Surface | Default attention budget | Allowed content |
|---|---:|---|
| Telegram | 1 acceptance + 1 live card + up to 2 meaningful card edits + 1 terminal card | state, ref, goal paraphrase, safe current/next action |
| Telegram waiting | 1 waiting edit + 1 approval/deny card | bounded reason, impact category, expiry, allowed action |
| Durable CLI TTY | 1 acceptance + first meaningful update + at most one update per 30 seconds + terminal | same semantic cards; no raw plan/tool stream by default |
| JSON / NDJSON | every durable event permitted | machine fields, identity, diagnostics, sequence |
| Explicit controls | no budget suppression | requested status/context/history/diagnostic detail, bounded |

Additional rules:

- A phase change can replace the live card; repeated `running` facts do not notify.
- A waiting state and a terminal state always interrupt quiet mode.
- “No visible change” is not an update. Do not emit a heartbeat merely because the worker loop ran.
- A user may opt into verbose progress; opt-in does not permit secrets, raw provider output, or unbounded token streaming.
- Notification count and message-edit count must be reported separately. An edit is lower attention than a new push but still contributes to rate and platform limits.
- The budget is a product default, not a reason to drop terminal truth. If capacity prevents a terminal projection, admission must be refused or the durable operational alert must be raised; it must not claim completion.

## 6. Metrics and benchmark extensions

### 6.1 Plumbing versus experience

The existing C1–C9 suite is the right safety foundation. B0 already scores admission ordering, references, liveness backing, history, command parity, approval safety, and isolation over real internal seams, but explicitly uses a fake transport and deterministic provider (`test/benchmark_comms_b0_test.rb:6-11`). Its C2 latency metrics are unavailable (`openclaw_comms_oracles.rb:148-156`), and readiness refuses fixture publication (`test/benchmark_comms_b0_test.rb:282-338`).

**Proposal — keep two claims separate:**

- **Plumbing claim:** durable state, delivery truth, identity, restart, fencing, and context inclusion are correct under C1–C9.
- **Experience claim:** a real user can understand the state, choose the right control, receive a useful answer, recover after interruption, and judge the answer’s quality on a real provider and real Telegram/CLI path.

### 6.2 Metric definitions

| Metric | Definition | Target hypothesis |
|---|---|---|
| `latency_to_ack` | Inbound update observed/accepted boundary to receipt of the accepted card, p50/p95, by surface | p95 under 2 seconds when gateway is healthy; no accepted request without an observable acknowledgement or explicit delivery uncertainty |
| `time_to_first_meaningful_update` | Accepted receipt to first card that names a human-safe current action, excluding a duplicate “running” state | ≥95% of tasks over 10 seconds; median under 10 seconds |
| `max_silence_gap` | Largest gap between attention-worthy updates while task is open, excluding explicit quiet mode | ≤60 seconds for tasks configured for live updates; waiting/blocked transitions are immediate |
| `state_comprehension` | After each card, blinded participant selects task state, request ref, and next action; score all three correct | ≥90% overall, ≥95% for waiting/cancel/unknown cards |
| `control_target_accuracy` | Correctly identifies the ref affected by `/cancel` or `/redirect` when two requests are open | ≥95%; hard zero for a cross-request action |
| `trust_calibration` | Participant’s “done/delivered” judgment compared with task and delivery axes | 0 false “delivered”; <5% false “completed” on failed/stopped/unknown cases |
| `completion_rate` | Durable terminal task state divided by admitted tasks, separately from successful delivery | Report by task class; never fold delivery success into task success |
| `recovery_rate` | After process restart, disconnect, or unknown delivery, user reaches a truthful actionable state without duplicate effect | ≥95% of recoverable cases; 0 blind retry of unknown external sends |
| `answer_usefulness` | Independent rubric on relevance, correctness, completeness, and actionability of the model answer against task-specific ground truth | Real-provider evaluation only; report separately from all plumbing scores |
| `attention_efficiency` | Useful state transitions divided by Telegram pushes/edits and CLI human lines; paired with perceived annoyance | ≥0.7 useful transitions per attention event and no significant comprehension loss when budget is reduced |
| `return_comprehension` | After a simulated one-hour gap, participant identifies active work, last confirmed fact, and safe next action | ≥90% without reading diagnostics |

### 6.3 Proposed benchmark extensions

**Proposal — extend the catalog, without weakening C1–C9:**

- **C10 — Quiet but alive:** a slow real-provider task with no token streaming. Measure first meaningful update, maximum silence gap, coalescing, and attention efficiency on Telegram and TTY.
- **C11 — Two refs, one decision:** two queued requests, then cancel one and redirect the other. Measure target accuracy, no cross-request status leak, and parity.
- **C12 — Human comprehension:** render the same durable facts in current and proposed cards; blind users on state/ref/next action. This tests product copy, not model intelligence.
- **C13 — Return and context:** disconnect after acceptance, restart gateway/worker, return after a controlled gap, ask `/status`, `/context`, and a follow-up. Verify last confirmed state, generation, history, and no progress leakage.
- **C14 — Unknown delivery handoff:** inject post-send ambiguity; verify user-facing “uncertain” state, operator resolution, no automatic resend, and clear eventual status.
- **C15 — Answer usefulness:** run the same tasks with a real configured provider through durable CLI and real Telegram transport, collect answer rubric and human rating. A deterministic provider may remain a plumbing control, never evidence of intelligence.

Each extension should publish the raw transcript/message cards, timings, state/delivery facts, and participant task answers. A score without the rendered experience is not enough for Lane B.

## 7. Safety and trust tradeoffs

- **More explanation versus disclosure:** goal paraphrases, phase names, and artifact labels can leak workspace intent. Use framework-owned, bounded, redacted categories; never expose raw tool args, paths, tokens, provider payloads, or model-generated approval instructions. The existing renderer’s zone rule already excludes secret values and raw provider payloads (`documentation/design/comms.md:33-40,111-117`).
- **Buttons versus authority:** a button is a convenience, not an authority boundary. Telegram remains deny-only in the current evidence model (`documentation/guides/telegram.md:10-14,135-150`). The proposed approval card may explain a decision, but it must not add an approve affordance when policy/evidence disallows it.
- **Honest unknown versus reassurance:** “delivery uncertain” is less pleasant than “sent,” but false reassurance creates duplicate-effect risk and destroys trust. The user message should explain the reason for no automatic retry and name the safe operator path.
- **Progress versus prompt injection:** never render model-authored prose as a system status or approval rationale. Use typed phase templates and bounded framework facts. A user’s “ignore instructions” text remains task data, not authority, under the current connector rule (`documentation/design/comms.md:37-40`).
- **History clarity versus privacy:** tell users which categories are remembered and which are not, but do not echo hidden context or raw summaries into a public chat. The current confirmed-delivery-only rule is a good safety invariant; the product layer should explain it at category level.
- **Personalization versus semantic drift:** allow user-selected cadence, verbosity, and accessibility style. Do not allow personalization to rename terminal truth, hide unknown delivery, suppress cancellation results, or turn diagnostics into approval authority.

## 8. Phased product bets mapped to existing seams

These are proposals only; this report does not edit production code or tests.

| Phase | Product bet | Existing seam | Acceptance evidence |
|---|---|---|---|
| P0 — language contract | Define typed human cards, copy, redaction rules, and ref placement for every task/delivery state | `tamoz-comms` lifecycle/rendering; `tamoz-comms-gateway` acknowledgement/status; `tamoz-agent` terminal text | Golden Telegram/CLI cards for C1, C2, C3, C7, C8; current durable facts unchanged; no milestone enters history |
| P1 — semantic projection | Add a bounded human summary beside the existing diagnostic/status projection | `SessionStatusProjection`; `Gateway::StatusProjection`; `ControlReply` | Human output contains state/ref/next action; JSON remains lossless enough for current C1–C9; no `effect=`/`capability=` in default human card |
| P2 — attention budget | Make milestone updates meaningful, coalesced, and cadence-aware | worker `notify_milestone`; `OutboxDeliverySink#push_milestone`; `CommsOutbox` coalescing; transport pacing | C10 records update count, first meaningful update, silence gaps, edits versus pushes; terminal delivery remains reserved and durable |
| P3 — control targeting/parity | Make cancel, redirect, status, and new-generation semantics use the same user-visible ref model on Telegram and CLI | gateway command parser/commands; `CLISessionCommands`; `CommsStore` request resolution | C11 two-ref target accuracy; cancellation race still follows C8; command parity means semantic outcome, not byte-identical text |
| P4 — reconnect, history, return | Give users a read-only “since you were away” and context explanation | `CommsStore` history/status; session context projections; CLI `show`; outbox unknown resolution | C13/C14 recovery transcript; no blind resend; confirmed-only history; clear generation/context disclosure |
| P5 — live usefulness gate | Validate comprehension, trust, and answer quality on real paths | `OpenclawCommsRunner`, durable CLI adapter, Telegram transport, real provider configuration | C10–C15 artifacts include real transport/provider provenance; answer usefulness is reported independently; fixture results are not upgraded into intelligence evidence |

## 9. Non-goals

- No second execution engine, parallel chat runtime, or model call from a renderer.
- No token streaming or raw plan/tool transcript in Telegram’s default experience.
- No automatic retry or user-facing “resend” for an ambiguous unsafe external delivery.
- No Telegram approval grant beyond the evidence/policy contract; no UI-only authority escalation.
- No group, multi-user, media, or broadcast UX before the existing identity/isolation bar supports it.
- No universal OpenClaw persona, emoji style, or assumption that terse status is preferred.
- No claim that better cards improve model reasoning; model quality requires a real-provider task rubric.
- No byte-identical Telegram/CLI text requirement; semantic parity and appropriate surface presentation are the goal.

## Final bar verdict

The report meets the Lane B content bar: it maps the human journeys, identifies interaction failures grounded in current source/tests, proposes a shared state/affordance contract, gives concrete Telegram and CLI cards, defines attention rules and measurable hypotheses, separates plumbing from model quality, maps bets to existing seams, and states safety/non-goals. The product itself still lacks real-transport/provider evidence for comprehension, latency, recovery experience, and answer usefulness; the current default copy remains too internal and under-actionable for a decision-grade chat experience.

**MEETS BAR WITH GAPS**

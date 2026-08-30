# Observed chat findings — Harness A discovery log

Pain points found by actually driving the chat through Harness A (the
mock-Telegram experience harness over the real gateway/worker/outbox/drainer/
store), recorded one by one with real evidence.

Method:
- **Interaction findings** use the deterministic provider so the real chat
  plumbing runs reliably and cheaply, isolating the chat UX from model smarts —
  which is the sponsor's named gap (broken/awkward interaction). A
  deterministic run is plumbing/UX evidence, never intelligence evidence.
- **Model-dependent findings** (latency, planning failures) come from real
  runs (OpenRouter `z-ai/glm-5.3-flash`, DeepSeek `deepseek-chat`).

Each finding carries: what was observed (real output), the user pain, severity
(Blocker / High / Medium), the root cause and the canonical finding/phase it
maps to (see `05-open-findings-ledger.md` and `01-plan.md`), the proposed fix,
and a **benchmark assertion** a later fix must satisfy (runnable via Harness A
or a focused test).

Severity: **Blocker** breaks the interaction; **High** erodes trust/wastes
time; **Medium** friction.

---

## OF-1 — A trivial task fails with an internal error after doing the work

**Observed (real: openrouter/z-ai/glm-5.3-flash and deepseek-chat).** Asked
"what is written in note.txt?". Effect journal:

```
model.generate.plan   -> succeeded
model.generate.review -> succeeded
tool.read_file        -> succeeded      (the file WAS read)
model.generate.plan   -> succeeded      (a repair re-plan)
model.generate.review -> succeeded
request.failed  reason: Tamoz::CheckpointConflictError:
                        effect key is already bound to different logical semantics
```

User sees: `That request failed before it could finish. Please try sending it
again.` — after the agent had already read the file.

**Pain:** the most basic task cannot complete on a real model; the user is told
to retry work that partly succeeded. This is the single biggest blocker to any
useful session.

**Severity:** Blocker.

**Root cause / maps to:** the agent's repair loop re-issues an effect whose
idempotency key collides with an earlier effect under different logical
semantics → `CheckpointConflictError`. This reproduces **CF-6** (previously only
seen swallowed in a test) on a real model. Confirmed to be the agent, not the
harness: identical failure with a single-worker-pass `pump`, while the
deterministic turn completes cleanly.

**Fix (proposed):** make effect-key derivation stable across repair re-plans, or
make a repair that re-issues a logically-different effect under an existing key
a handled, retryable condition rather than a fatal `CheckpointConflictError`.
This is agent-runtime work adjacent to Phase 0b's graceful-failure goal (I5):
even if it must fail, it must not surface an internal error string after partial
success.

**Benchmark:** drive a read-only task that triggers one repair on a real
provider; assert the turn reaches a terminal `answer`/`completed` OR a bounded,
user-safe failure card — never `CheckpointConflictError` reaching the user, and
never "failed before it could finish" after a successful tool effect.

**Fixed (2026-08-28, commits `3a833c1`, `0c9a057`, and `4bc028c`).** The
durable CLI now observes exceptions from its worker thread instead of allowing a
background failure to look like success or leak an unhandled backtrace. The CLI
and chat worker project checkpoint conflicts as bounded status-oriented failure
cards; neither surface exposes the exception class, internal message, or the old
"failed before it could finish" wording. The durable tool dispatcher now keeps
the request digest derived from tool semantics only; `plan_digest` remains
provenance on the plan and intent records, but a repair re-plan of the same logical
read reuses its recorded effect receipt instead of raising a logical-key
conflict.

**Evidence:** `test/agent_session_effect_test.rb` (20 runs, 79 assertions),
`test/agent_session_kill_matrix_test.rb` (6 runs, 67 assertions),
`test/agent_cli_test.rb` (34 runs, 764 assertions), and
`test/agent_worker_failure_reason_test.rb` (6 runs, 14 assertions) pass under
pinned Ruby. This is deterministic runtime/error-boundary evidence; it is not a
current real-provider reproduction or human-usefulness result.

---

## OF-2 — A trivial task takes ~100 seconds

**Observed (real: z-ai/glm-5.3-flash).** The same one-line question ran for
`duration_ms: 102496` (~102s) before failing.

**Pain:** even if it completed, 100s of near-silence for "what's in this file?"
feels dead and would exceed real Telegram long-poll/edit expectations. Combined
with OF-4 (silence), the user cannot tell it is alive.

**Severity:** High.

**Root cause / maps to:** multiple sequential model calls (plan, review, repair
plan, review, verify) each at provider latency, with no interim liveness the
user can read. Latency has its own workstream (`documentation/operations/ux-latency-investigation/`);
the chat-side mitigations are Decision 3 (two-stage receipt) and honest liveness
(DG-2 / Phase 3).

**Fix (proposed):** out of scope for the chat plumbing itself, but the chat must
(a) not promise progress it then withholds for 100s, and (b) show honest live
state so 100s is legible, not silent. Track model-call latency separately.

**Benchmark:** record accepted→first-meaningful-update and total duration per
run; a task over ~10s must produce at least one meaningful liveness update, and
the accepted card must not over-promise (Decision 3).

---

## OF-3 — Asking the agent a question crashes the turn; the question never arrives

**Observed (deterministic; a review returning `needs_input`).**

```
👤 read the file and summarize it
   [accepted] Accepted redb9fcd98f. I will report committed progress.
   [control]  redb9fcd98f: waiting
   request.failed  reason: KeyError: key not found: "decision"
```

The clarification is projected through the approval path; `decision_evidence`
fetches `descriptor['decision']['required_evidence']`, which a clarify descriptor
lacks, so the turn dies with `KeyError`. The user sees an acceptance, a "waiting"
blip, then nothing — the actual question is never delivered.

**Pain:** the moment the agent needs human judgment, the conversation breaks.
Delegation fails exactly where interaction matters most.

**Severity:** Blocker.

**Root cause / maps to:** **CF-1** (worker/sink collapse clarify into approval),
now reproduced live. Phase 0 / I1.

**Fix:** split clarify from approval in the sink; project a bounded question with
a durable, occurrence-bound answer path.

**Benchmark:** drive a `needs_input` review; assert one bounded question card
(no approval markup, no `decision_evidence` lookup), the occurrence stays paused,
and no `KeyError`; a reply/`/answer` resumes the same occurrence.

**Fixed (2026-08-28, commit `9d57a2a`):** the clarification projection benchmark
is green. Clarifications now deliver as bounded text-only control cards, remain
outside approval evidence, and preserve `clarification_required` across restart;
answer ingress remains the separate OF-11 cycle.

---

## OF-4 — Normal chat is run like a job

**Observed (deterministic).**

```
👤 hi
   [accepted] Accepted r690f82106b. I will report committed progress.
   [control]  r690f82106b: claimed
   [answer]   the verified answer
```

A bare "hi" is admitted as a durable task, gets a reference, is planned and
executed, and (on a real model, per OF-1/OF-2) would take ~100s and can fail.

**Pain:** every trivial message pays the full task tax — acceptance ceremony,
latency, and the failure surface. There is no "just chat."

**Severity:** High.

**Root cause / maps to:** **SD-1 / I4** — no chat-vs-task routing. Phase 0b.

**Fix:** answer no-effect/conversational turns directly, with no acceptance/plan
lifecycle and no path to `PlanRejectedError`.

**Benchmark:** a conversational turn produces a direct answer with no accepted
card, no plan/review effects, and cannot reach a plan-failure state.

**Fixed (2026-08-28; superseded 2026-08-28 by the worker-routing migration).**
The first fix routed chat at the gateway via a per-surface `chat_responder` that
created no request. That gateway responder was removed and the classification
moved into the worker's `:experimental` route seam, so chat-vs-task is one
journaled, replayable model decision alongside the plan/review it may replace —
routing now lives with the model call, not the transport. Under the migrated
contract a conversational turn IS admitted as a durable request (it receives
`Received r<reference>`), but the worker routes it to a `direct_response`
terminal: no plan, no review, and no path to `PlanRejectedError`. Its terminal
card is honestly `Response only`, never `Verified`, because a direct answer
proves nothing. `:experimental` routing is enabled for the chat worker
(`bin/tamoz-chat-sim`, `scripts/start-tamoz-comms.sh --experimental-routing`);
the deterministic fixture must script a `route` response for a chat turn.

Enabling `:experimental` for the chat worker surfaced a real defect (fixed the
same day): a direct answer is multi-line (`<answer>\nResponse provided…`) and
the confirmed transcript feeds the next turn's context, but `Core::TurnContext`
forbids control characters — so a second chat turn crashed its admission on the
stored newline. The same boundary rejects a newline in an inbound message.
`CommsStore#turn_payload` — the single point that builds the `TurnContext` for
an admitted turn — now flattens control characters in both the inbound task
text and every history fragment to a single space (dropping fragments that
flatten to empty), so admission and every later turn stay durable. This is
independent of the model.

**Evidence:** `test/experience_harness_test.rb`
(`test_conversational_turn_is_routed_to_a_direct_answer_without_planning`
asserts a `Response only` answer with no plan/review effects and no failure;
`test_second_chat_turn_does_not_crash_on_a_multiline_answer_in_history` guards
the transcript-fragment fix), `test/agent_request_routing_test.rb`
(session-level route decisions), and the deterministic `bin/tamoz-chat-probe
OF-4` all pass. A real two-turn OpenRouter (`z-ai/glm-5.3-flash`) run (`hi` →
direct greeting; `what is 2 + 2?` → `2 + 2 = 4`, both `Response only`)
confirmed the routed path end-to-end on a live model. This is plumbing,
routing, and one live-path observation; it is not a human-usefulness result.

---

## OF-5 — Progress updates are machine gibberish

**Observed (deterministic).** The only progress card is:

```
   [control] r04530c054e: claimed
      markup: {"request_ref":"r04530c054e","milestone":"running","phase":"claimed",
               "sequence":1,"task_state":"running","delivery_state":"pending"}
```

The visible text is `r<ref>: claimed`; the markup carries raw internal lifecycle
facts.

**Pain:** "claimed / running / waiting" describe machinery, not progress toward
the user's goal. The user cannot tell what is actually happening.

**Severity:** High.

**Root cause / maps to:** **DG-3** (no human projection). Phase 2.

**Fix:** a goal-oriented card — state, ref, current safe action, next action —
over framework-owned phase templates; no raw lifecycle vocabulary.

**Benchmark:** golden card per state names a human-safe phase and next action;
no `claimed/running/waiting` literal and no internal facts in the default card.

**Fixed (2026-08-28, commit `f50bd4c`):** milestone cards now use bounded,
framework-owned copy with the request reference, a human-readable `Now:` line,
and a `Next:` line. Unknown phases use a generic safe template; arbitrary phase
values and lifecycle facts remain in machine markup only. Existing sequence,
coalescing, receipt-bound edit, terminal-delivery, approval, clarification, and
history-exclusion behavior is unchanged.

**Evidence:** `test/progress_projection_test.rb` (13 runs, 223 assertions),
`test/agent_outbox_delivery_sink_test.rb` (11 runs, 44 assertions), and the
deterministic `bin/tamoz-chat-probe OF-5` pass. This is plumbing evidence, not
live-provider or human-comprehension evidence.

---

## OF-6 — `/status` answers in diagnostic vocabulary

**Observed (deterministic, two open requests).**

```
👤 /status
   [control] Work status: task=queued; phase=unknown; event=unknown#unknown;
             effect=not_started; capability=not_inspected; delivery=delivered;
             next=inspect; open requests=2. Reference re788e19630. Queue position 1.
```

**Pain:** the default status leaks `event=unknown#unknown`, `effect`,
`capability`, and a confusing `delivery=delivered` — internal fields a person
cannot act on. It also surfaces only one of the two open references.

**Severity:** High.

**Root cause / maps to:** diagnostic-first status (**DG-3**) plus request-scoping
(**CF-2**). Phase 1–2.

**Fix:** a bounded human `/status` (state, ref, now, next, delivery certainty)
with diagnostics behind an explicit `--diagnostic`; list all open refs.

**Benchmark:** default `/status` contains no `effect=`/`capability=`/
`event=` and, with N open requests, names all N refs.

**Fixed (2026-08-28, commit `60923aa`).** Default `/status` now renders a
bounded human summary with state, active reference, current worker orientation,
next action, request-local delivery certainty, queue facts, and every open
reference. The conversation-wide delivery aggregate remains available only in
the explicit diagnostic projection, so one request cannot be described as
delivered because another request completed. `/status --diagnostic` and
`/status <ref> --diagnostic` retain the raw control-plane fields; extra
arguments are refused with usage text.

**Evidence:** `test/comms_command_parity_test.rb` (11 runs, 203 assertions),
`test/experience_harness_test.rb` (11 runs, 72 assertions),
`test/comms_gateway_test.rb` (40 runs, 243 assertions),
`test/sqlite_comms_store_test.rb` (44 runs, 240 assertions),
`test/cancellation_visibility_test.rb` (11 runs, 98 assertions), and the
deterministic `bin/tamoz-chat-probe OF-6` pass. This is deterministic
plumbing/projection evidence, not real-provider or human-usefulness evidence.

---

## OF-7 — Cancelling with several tasks open tells you nothing about which one

**Observed (deterministic, two open requests).**

```
👤 /cancel
   [control] Cancellation requested.
```

The reply names no reference; with two open requests the user cannot tell which
was affected.

**Pain:** the user fears cancelling the wrong work — the exact "controls hit the
wrong thing" complaint.

**Severity:** Blocker (trust) / High.

**Root cause / maps to:** **CF-3** thread-wide cancel + no disambiguation. Phase 1
/ I2.

**Fix:** exact-ref cancel; a bare `/cancel` with several open lists the refs and
asks which, stamping none.

**Benchmark:** bare `/cancel` with two open lists both refs and cancels neither;
`/cancel <ref>` cancels exactly that one and echoes it.

**Fixed (2026-08-28, commit `7aaea8c`):** chat cancellation now resolves the
caller-bound open request before the durable stamp-and-redirect transaction. A
bare command disambiguates when several requests are open; `/cancel <ref>`
targets and echoes exactly one request. CLI cancellation remains tracked under
CF-3 and is not covered by this fix.

---

## OF-8 — The approval card is opaque and offers only "Deny"

**Observed (deterministic, apply_patch under an ask policy).**

```
   [approval_request] An action needs your approval.
      markup: {"reference":"093bc03b5a50c81baad0cae1aeb29727","actions":["deny"]}
```

**Pain:** the user is asked to approve "an action" with no idea what it would do,
why it is waiting, or what deny means — and there is no approve button, so the
task is a dead-end in the chat.

**Severity:** High.

**Root cause / maps to:** under-explained approval (Lane B #11) + policy deny-only
(#12). Phase 2.

**Fix:** a bounded, redacted explanation (what it would do, why waiting, what
deny does, the safe operator route); keep authority a policy decision, never a
UI button.

**Benchmark:** approval card includes a bounded action description and a next
action; still no approve button unless policy evidence permits; no secrets/raw
args.

**Fixed (2026-08-28, commit `c69b55e`).** Approval cards now name a fixed,
bounded action vocabulary and explain the next safe step. Unknown tools use a
generic action label; raw arguments, previews, paths, and model text stay out
of the human card. The final stored part still passes through the configured
renderer and its actual content digest, so small channel bounds remain
authoritative.

**Evidence:** `test/agent_outbox_delivery_sink_test.rb` (17 runs, 98
assertions) and `bin/tamoz-chat-probe OF-8` pass. This is deterministic,
policy/rendering plumbing evidence, not approval comprehension or human-
usefulness evidence.

---

## OF-9 — The acceptance over-promises, then the turn can fail or go silent

**Observed (every task).** `Accepted r… . I will report committed progress.` —
followed (real model) by ~100s of silence and often a failure (OF-1), or (OF-3)
a crash.

**Pain:** the system promises progress it then does not keep — the "I got your
request, then an error" whiplash.

**Severity:** High.

**Root cause / maps to:** acceptance coherence (**Decision 3 / I5 / SD-2**).
Phase 0b.

**Fix:** an immediate bare receipt that promises nothing. A later working
projection is optional; it must only be emitted from a committed post-review
fact if the channel supports it.

**Benchmark:** the first acknowledgement makes no progress promise; a fast
review failure never contradicts an earlier promise.

**Fixed (2026-08-28, commit `b433138`):** admitted requests now receive only
`Received r<reference>.` The gateway no longer inspects queue depth to vary the
acknowledgement or promises committed progress before a worker has run. Durable
admission, request-reference derivation, and worker failure behavior are
unchanged, so a fast plan/review failure produces the existing honest failure
path without contradicting the receipt. No speculative edit-message protocol
was added; removing the false promise is the smaller complete fix for this
finding.

**Evidence:** `test/comms_gateway_test.rb` (40 runs, 241 assertions),
`test/comms_command_parity_test.rb` (10 runs, 173 assertions), and
`test/comms_pairing_first_contact_test.rb` (7 runs, 40 assertions) pass. This
is deterministic lifecycle-plumbing evidence, not real-provider or human-
usefulness evidence.

---

## OF-10 — The final answer carries no reference or orientation

**Observed (deterministic).** The terminal card is just:

```
   [answer] the verified answer
```

No reference, no "for: <your task>", no completion/verification label in the
default text.

**Pain:** with more than one task in the transcript, the user cannot tell which
request an answer belongs to.

**Severity:** Medium.

**Root cause / maps to:** reference-without-orientation (Lane B #1) / **DG-3**.
Phase 2.

**Fix:** terminal card carries the ref, a task echo, and a verification label
(verified / response-only / not-verified).

**Benchmark:** every terminal card includes its ref and verification class.

**Fixed (2026-08-28, commit `60923aa`).** Request-owned terminal deliveries
now carry the short request reference and one bounded verification class:
`Verified`, `Response only`, or `Not verified`. The wrapper is applied only to
true terminal event kinds; accepted and milestone deliveries remain unchanged,
and the original bounded answer text, identity, replay, and history behavior
remain intact.

**Evidence:** `test/agent_outbox_delivery_sink_test.rb` (14 runs, 69
assertions), `test/progress_projection_test.rb` (13 runs, 223 assertions), and
the status/experience suites listed for OF-6 pass. This is deterministic
delivery-plumbing evidence, not real-provider or human-usefulness evidence.

---

## OF-11 — A reply is swallowed as a brand-new task

**Observed (deterministic).** After an answer, replying to the bot's message:

```
👤 (reply) thanks, also what about other.txt?
   [accepted] Accepted r8c2e44b6a4. I will report committed progress.
```

The `reply_to` is ignored; the reply becomes a new request.

**Pain:** there is no way to answer or follow up in context; replies never bind
to anything — which is also why I1 (answer a question inline) cannot work today.

**Severity:** Medium (High once clarifications exist).

**Root cause / maps to:** **CF-4** no reply/answer ingress. Phase 0 / I1.

**Fix:** bind a reply-to-the-question message to the paused occurrence; plain
replies with no pending question stay new requests.

**Benchmark:** a reply to a pending question resumes that occurrence; a reply
with no pending question is a new request.

**Fixed (2026-08-28, commit `7e2df9d`):** clarification replies now bind to the
delivered question by its durable Telegram receipt, and `/answer <ref> <text>`
provides an explicit fallback. Both paths enqueue the existing durable resume
operation for the same occurrence; ordinary replies remain new requests.

---

## OF-12 — Redirect does not say what replaced what, or what was kept

**Observed (deterministic).**

```
👤 /redirect rcb1e6752af only compare the two candidates
   [control] Redirecting rcb1e6752af; the replacement task is queued.
```

It names the old ref but not the new replacement ref, and says nothing about
whether committed work is preserved.

**Pain:** the user cannot follow the new work or trust what happened to the old.

**Severity:** Medium.

**Root cause / maps to:** control wording (I2 sibling). Phase 1.

**Fix:** "Replacement queued as r<new>; r<old> remains recorded; committed work
is not undone."

**Benchmark:** redirect names both the superseded and the replacement ref and
states preservation.

**Fixed (2026-08-28, commit `c69b55e`).** Redirect responses now name the new
replacement reference, retain the original reference, and state that committed
work is not undone. The durable redirect payload and idempotency path are
unchanged.

**Evidence:** `test/comms_command_parity_test.rb` (11 runs, 203 assertions)
and `bin/tamoz-chat-probe OF-12` pass. This is deterministic control-plane
evidence, not a real Telegram or human-usefulness result.

---

## OF-13 — Status for one request reports the conversation's delivery state

**Observed (deterministic, two open).** `/status` for a queued request shows
`delivery=delivered` — the delivery state is resolved at conversation scope, not
for the referenced request (`conversation_runtime_status` →
`delivery_state_for(surface_id, conversation_id)`).

**Pain:** a queued/underway request can look delivered because another request's
delivery bleeds into it — "did my task complete?" becomes unreliable.

**Severity:** High.

**Root cause / maps to:** **CF-2** request-scoped status aggregates conversation
delivery/effect. Phase 1.

**Fix:** resolve delivery/effect per request; keep conversation-wide as a
separately named aggregate.

**Benchmark:** with A `unknown` and B pending→succeeded, `/status rA` and
`/status rB` each show only their own delivery/effect, after reopen and replay.

**Implemented (deterministic plumbing, `69c4a4d`).** Request-owned outbox and
effect rows now persist `request_id` separately from delivery/effect identity.
Request status filters both delivery and effect summaries by the exact request;
conversation status retains its separately named conversation-wide aggregate.
The Harness A benchmark passes with A `unknown` and B `delivered`, and focused
SQLite migration/reopen, comms, effect-journal, gateway, cancellation,
memory-store, and approval-store tests pass. This closes the verified
cross-request bleed in the tested comms path; it is not provider or human-use
evidence.

---

## OF-14 — "Accepted" does not mean anyone is working

**Observed (topology).** The gateway admits and acknowledges independently of
the worker; on a real run the accepted card is followed by ~100s of silence
(OF-2) with no signal of whether a worker is running, queued, or absent.

**Pain:** the user cannot distinguish "accepted but no worker" from "working
slowly," so silence reads as dead — and invites duplicate resubmissions.

**Severity:** High.

**Root cause / maps to:** **DG-2** worker health not a user-facing fact. Phase 1.

**Fix:** expose accepted / queued-unclaimed / working distinctly; worker-
unavailable always notifies (never a quiet heartbeat).

**Benchmark:** admit with no worker → accepted/queued-unclaimed; start worker →
same ref advances once, no duplicate effect; the worker-unavailable state
notifies.

**Fixed (`f0ad6ba`).** The existing status projection now exposes
`worker=accepted`, `worker=queued-unclaimed`, and `worker=working`. The
queued-unclaimed state is derived from the durable request inbox after a
one-millisecond claim window; it is deliberately queue-age evidence, not a
claim that the worker process is dead. The deterministic Harness A benchmark
and `bin/tamoz-chat-probe OF-14` show the same reference progressing from
queued-unclaimed through claim to completion exactly once. Focused gateway,
SQLite, parity, and projection tests pass. This is plumbing/UX evidence only,
not provider or human-usefulness evidence.

---

## OF-15 — `/help` is a 14-command wall

**Observed (deterministic).**

```
👤 /help
   [control] Commands: /help, /status [r<reference>], /new, /cancel, /redirect
   r<reference> <new task>, /whoami, /start <pairing code>, /reset, /compact,
   /usage, /context, /think <low|medium|high>, /verbose <quiet|normal|detailed>.
   Commands never become task text.
```

**Pain:** a new user gets a comma-separated list of 14 commands with no example
of the basic loop (ask → get answer → check status → cancel).

**Severity:** Medium.

**Root cause / maps to:** onboarding copy (Lane B). Phase 2.

**Fix:** lead with a one-line example of the core loop and the 3–4 primary
controls; move the full list behind "more".

**Benchmark:** `/help` shows a worked example and ≤4 primary controls by default.

**Fixed (2026-08-28, commit `3b50397`).** Default `/help` now teaches the core
loop with `/status` and `/cancel`, exposes four primary controls, and points to
`/help more` for the full typed command reference. Unexpected arguments return
bounded usage text; help remains a control response and never becomes task text.

**Evidence:** `test/comms_gateway_test.rb` (42 runs, 266 assertions),
`test/comms_command_parity_test.rb` (11 runs, 203 assertions), and
`bin/tamoz-chat-probe OF-15` pass. This is deterministic onboarding plumbing
evidence, not a human comprehension result.

---

## Priority summary

| Finding | Severity | Maps to | Phase |
| --- | --- | --- | --- |
| OF-1 CheckpointConflictError kills a done task | Blocker | CF-6 | 0b/runtime |
| OF-3 clarification crashes; question never arrives | Blocker | CF-1 | 0 |
| OF-7 cancel gives no target with several open | Blocker/High | CF-3 | 1 |
| OF-2 ~100s for a trivial task | High | latency | 3 |
| OF-4 normal chat run like a job | High | SD-1 | 0b |
| OF-5 milestone gibberish | High | DG-3 | 2 |
| OF-6 diagnostic-vocabulary status | High | DG-3/CF-2 | 1-2 |
| OF-8 opaque, deny-only approval | High | Lane B | 2 |
| OF-9 acceptance over-promises | High | SD-2 | 0b |
| OF-13 cross-request delivery bleed | High | CF-2 | 1 |
| OF-14 accepted ≠ working | High | DG-2 | 1 |
| OF-10 answer has no reference | Medium | DG-3 | 2 |
| OF-11 reply swallowed as new task | Medium | CF-4 | 0 |
| OF-12 redirect wording | Medium | I2 | 1 |
| OF-15 /help wall | Medium | Lane B | 2 |

Three Blockers (OF-1, OF-3, OF-7) prevent a working session at all; fix those
first. The Highs then move it from "broken" to "usable"; the Mediums to "good".

## Benchmark suite (for later)

Every OF above carries a benchmark assertion. Harness A is the driver: the
deterministic provider proves the interaction/UX assertions (OF-3..OF-15) fast
and reliably; a guarded real-provider run proves the model-dependent ones
(OF-1, OF-2). The suite becomes the regression gate — each fix must flip its
assertion from red to green without regressing the others, and the same
transcripts serve as before/after evidence for the sponsor.

## How to run these (for the fixing agent)

Everything runs against the real gateway/worker/outbox/drainer/store via
Harness A (`test/support/experience_harness.rb`). Only the transport is
simulated. Two entry points:

- `bin/tamoz-chat-probe` — scripted reproductions of the interaction findings
  (deterministic provider, no network).
- `bin/tamoz-chat-sim` — an interactive REPL against a real provider.

### Prerequisites

Use the pinned Ruby and a UTF-8 locale (a `C` locale dies inside `ruby_llm`'s
`models.json` parse before any Tamoz code runs):

```bash
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
# commands below assume the repo root and `bundle exec` (rbenv Ruby 3.3.11)
```

### Reproduce the interaction findings (no API, fast, reliable)

```bash
bundle exec ruby bin/tamoz-chat-probe            # all interaction findings
bundle exec ruby bin/tamoz-chat-probe OF-3 OF-7  # specific findings
```

Each probe prints the user action and the exact cards the bot produced, plus
worker events for failures (e.g. OF-3 prints the `KeyError`). Re-run the same
probe after a fix: the transcript should show the desired behavior from the
finding's **Benchmark** line.

### Regression guard (no API)

```bash
bundle exec ruby -Itest test/experience_harness_test.rb
```

Proves the harness itself drives a full turn to a terminal answer with the
deterministic provider. Keep it green while changing the chat.

### Reproduce the model-dependent findings (OF-1, OF-2 — real provider)

DeepSeek:

```bash
export DEEPSEEK_API_KEY="$(sed -n 's/^DEEPSEEK_API_KEY[[:space:]]*=[[:space:]]*//p' .env)"
export TAMOZ_PROVIDER=deepseek TAMOZ_MODEL=deepseek-chat
printf '%s\n' 'what is written in note.txt?' '/quit' | bundle exec ruby bin/tamoz-chat-sim
```

OpenRouter (GLM):

```bash
export OPENROUTER_API_KEY="$(sed -n 's/^OPENROUTER_API_KEY[[:space:]]*=[[:space:]]*//p' .env)"
export TAMOZ_PROVIDER=openrouter TAMOZ_MODEL='z-ai/glm-5.3-flash'
printf '%s\n' 'what is written in note.txt?' '/quit' | bundle exec ruby bin/tamoz-chat-sim
```

`.env` is NOT auto-loaded by the REPL; export the key yourself as shown. A real
run judges experience/answers; a deterministic run is plumbing/UX only.

### Harness API (to write your own probe or a benchmark test)

```ruby
require 'experience_harness'         # with test/support on $LOAD_PATH
F = Tamoz::Evals::Benchmark::OpenclawCommsFixture
h = Tamoz::ExperienceSim::Harness.new(                    # real provider by default
      model_factory: F.model_factory(**F::DEFAULT_MODEL_RESPONSES))  # or deterministic

h.say('do X')          # admit + run one turn; returns the bot's new cards
h.admit('do X')        # admit only (queue an open request); returns cards
h.work_off             # run one worker pass + drain; returns cards
h.reply('answer')      # reply to the bot's last message (I1 path)
h.tap('deny:...')      # press an inline button (callback)
h.conversation_status  # durable conversation status hash
h.ref_status('r...')   # per-request status hash
h.events               # captured worker events (worker.error carries reasons)
h.effect_census        # journaled model/tool effects and their status
h.close
```

Each card is `{ kind:, text:, markup:, message_id:, ... }`. To force a specific
lifecycle, pass a `model_factory` with scripted `plan`/`review`/`verify`
responses (see `bin/tamoz-chat-probe` OF-3 for the `needs_input` review that
triggers a clarification, and OF-8 for an `apply_patch` plan that triggers an
approval under `approval_ask:`).

### Suggested fixing loop

1. `bin/tamoz-chat-probe OF-N` — see the current (red) behavior.
2. Apply the fix at the finding's mapped seam/phase.
3. Re-run the probe — confirm the transcript matches the Benchmark line.
4. Promote the probe into an asserting test (the benchmark suite), so it stays
   green. Keep `test/experience_harness_test.rb` green throughout.

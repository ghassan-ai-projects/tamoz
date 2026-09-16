# Independent challenge — F07-REL-01, F12-REL-01, F05-REL-01, CF07-ARCH-01 / CF07-REL-02

| Field | Value |
| --- | --- |
| Challenger | independent adversarial challenger (separate session from every analyst) |
| Date | 2026-09-15 |
| Baseline commit | `582ae55` (`582ae5566de1ae073aea82b69bb2bbf444494d3b`), branch `audit-15-09` |
| Method | Re-read every cited `file:line` in the checkout; attack the reachability chain through the real callers; grep beyond the cited files for guards, bounds, retries, ordering keys and digest recomputation; run the named focused suites; then reproduce or fail to reproduce each claim with a minimal `/tmp` probe against the real classes, a real temp SQLite DB, and a fake transport (no LLM, no live Telegram). |

Probes: `/tmp/tamoz-probe/challenge_f07.rb`, `/tmp/tamoz-probe/challenge_comms_order.rb`,
`/tmp/tamoz-probe/challenge_schedule.rb`. Nothing was written inside the repository.

## F07-REL-01

### Source re-verified

Read `gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox_claimer.rb` in full (276 lines).

- **Citation `:216-231` is correct.** `candidate_rows` is at `:220-232`; the query body
  is `:221-231`, the bound is the literal `8` at `:230`. The quoted SQL matches the
  file verbatim. The only quibble is that `:216-231` omits the `def` line at `:220`
  for a method whose doc comment starts at `:216` — a comment-anchored range, not a
  wrong citation.
- **Citation `:160-180` is correct.** `claim_request_in_transaction` spans `:160-181`;
  the `next if early_turn?` skip is `:172`, not `:160-180` as a whole, but the range
  contains it.
- **Citation `:183-190` is correct.** `early_turn?` is `:188-190` with its rationale
  comment at `:183-187`.
- `EARLY_TURN_REASON = 'latest checkpoint is not terminal'` at `:33` and
  `EARLY_TURN_OPERATIONS = %w[turn]` at `:36` match the report's description exactly.
- `gems/tamoz-graph/lib/tamoz/graph/request_staleness.rb:14-40` — correct.
  `turn_reason` is `:34-40` and returns `'latest checkpoint is not terminal'` at `:39`
  when the checkpoint exists and is not `completed`/`failed`. The report's own cited
  range `:14-40` is right.
- `gems/tamoz-graph/lib/tamoz/graph/durable_runner.rb:66-74` — the report cites
  `run_next` returning `nil`. `def run_next` is at `:56`, and `return nil unless
  request` is at `:73`. The cited `:66-74` contains it. Correct.

**What differed:** nothing material. Every citation I checked resolves to the claim
made about it.

### Reachability chain

The crux the brief asks about — "is the 8-row window a hard bound, or does the caller
loop until it drains?" — resolves decisively: **it is a hard bound, and there is no
draining loop.** This is the finding's strongest point, and I could not refute it.

Concrete non-test sequence:

1. A thread has a **non-terminal** latest checkpoint. Every route into this state is
   ordinary: a turn paused on an approval prompt, or a turn stopped on a
   clarification question. `turn_reason` (`request_staleness.rb:39`) returns
   `'latest checkpoint is not terminal'` for *any* non-`completed`/`failed` status,
   not just `paused` — so `:running` and `:blocked` count too.
2. The operator (or an inbound channel) queues **9 or more** `:turn` requests on that
   one thread. This is not exotic: `tamoz queue add` submits exactly
   `operation: :turn, delivery: :queue` (`gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb:233`),
   and it is unbounded — an operator or a script can queue as many as they like.
   `WorkerRuntime#enqueue_child_request` (`worker_runtime.rb:259-266`) and the
   schedule materializer produce the same shape.
3. A valid `:resume` for the open occurrence is queued behind them.
4. `run_next` → `claim_next_request` → `candidate_rows` returns the oldest **8**
   non-terminal rows by `enqueue_sequence`. All 8 are `:turn`s whose staleness
   reason is the early reason, so `next if early_turn?` skips each. The loop falls
   through to `nil` (`:180`). `durable_runner.rb:73` returns `nil`.
5. The resume is never in the window, so it is never returned, however many times
   `run_next` is called — **the first eight rows never change**, because skipping
   leaves them `queued` and nothing else in the transaction mutates them.

The report says "repeating the call sees the same first eight rows." I tested this
rather than accepting it, because it is the whole finding. **Confirmed: it is not
self-healing.** See the multi-pass probe below — passes 2 and 3 return `nil`
identically. My control test (`test_control_small_backlog`) shows the mechanism is
a genuine window: with 2 deferred turns the resume *is* reachable and completes.

I also attacked the escape hypothesis directly in the probe: I settled the paused
checkpoint out of band (`advance_to_completed`-style resume) and called `run_next`
again. It still returned `nil` — because the resume's own staleness verdict is
*also* "not terminal" until its target settles, and by the time the checkpoint
settles the first 8 turns are still the first 8 rows. **A starving state is
therefore not cleared by the checkpoint settling.** It is cleared only by the
operator draining the backlog down to fewer than 8 non-terminal rows ahead of the
control request — i.e. exactly the work that is itself blocked.

**Is it reachable in production, or only from tests?** Reachable. `candidate_rows`
bounds the window to a single thread namespace (`WHERE thread_id = ? AND namespace = ?`),
so all nine turns must be on one thread — which is precisely the shape `tamoz queue
add --thread t1` produces, and file order is `enqueue_sequence`, so FIFO arrival
order is what fills the window. There is no de-duplication, coalescing, or rate limit
on queued turns. Nothing prevents a nine-deep backlog.

One correction to the report's framing, which does **not** change the verdict: the
report's headline "eight-row candidate scan" is really a **≥8 deferred-row** problem,
because the resume must sit strictly beyond 8 candidates of which all 8 are deferrable
turns. The report itself states the threshold correctly at line 16 ("strictly more
than eight deferred rows before the control request"), so the body is right; only the
one-line title reads more loosely.

### Guards searched

```
grep -rn "claim|next_queued|run_next" gems/
grep -rn "run_next|claim_next_request" gems/ apps/ bin/
grep -rn "LIMIT|candidate" gems/tamoz-sqlite/lib/tamoz/sqlite/request_inbox.rb
grep -rn "request.claim.candidates|candidate_rows|LIMIT 8|, 8]" gems/tamoz-sqlite/lib/tamoz/sqlite/*.rb
grep -n "request.claim" -A 6 gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_registry.rb
```

Every hit read. Results:

- **No fallback query.** `boundary_registry.rb:92-110` declares the complete statement
  set of the `request.claim` transaction. `request.claim.candidates` appears **once**
  (`:99`). There is no second, unbounded or control-priority read anywhere in the
  claim path. The report's "no progress or control-request escape rule" is exactly
  right.
- **No caller-side drain loop.** `DurableRunner#run_next` (`:56-100`) calls
  `claim_next_request` **once** per invocation and returns `nil` when it is nil. No
  retry, no loop, no backoff.
- **The two real callers both treat `nil` as "nothing to do":**
  `gems/tamoz-agent/lib/tamoz/agent/worker.rb:330` (`run_queued_resume`) and `:516`
  (`claim_and_run`) each call `run_next` once and pass the result straight into
  `settle`.
- **The worker's own outer loop does not fix it.** `Worker#run` → `poll_once`
  (`worker.rb:122-129`) is a *poll* loop, not a drain loop; it re-enters the same
  `run_next`. Re-entry re-runs the identical query and gets the identical `nil`.
- **`pending_threads` is not an escape either.** `request_inbox_rows.rb:93-115`
  returns only the **oldest** non-terminal request per thread (`enqueue_sequence =
  (SELECT MIN(...))`, bounded by `limit`). The worker uses it for mode-switch
  draining (`worker.rb:972`), `queue list`
  (`cli_worker_commands.rb:251`), and `build_status` (`:477`) — the latter two are
  pure reporting. It never surfaces the buried resume; it reports the thread as
  ordinary pending work, which is the observability half of the report's impact claim
  and I confirm it.
- **A tail-overflow guard I found that the report does not name.** `claim_request_in_transaction:164`
  is `return row unless row.fetch(7) == 'queued'`. This is a real subtlety: a
  non-`queued` candidate (e.g. `claimed`, `running`, `redirecting`) short-circuits and
  is returned immediately — but it only widens the window in the *other* direction
  and cannot rescue a resume beyond position 8. It does not refute the finding.

### Probe

Path: `/tmp/tamoz-probe/challenge_f07.rb` (Minitest, real `Tamoz::SQLite::Adapter`
over a `Dir.mktmpdir` database, real compiled graph, real `DurableRunner`).

```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
cd /Users/ghassan/my-projects/tamoz
timeout 150 ruby -Itest /tmp/tamoz-probe/challenge_f07.rb
```

Setup: pause one thread, enqueue 9 `:turn` requests, then a valid `:resume`.

Multi-pass experiment — exact output:

```
--- pass 1 ---
run_next=nil
statuses=[["request.start", :completed], ["request.turn-0", :queued], ["request.turn-1", :queued],
["request.turn-2", :queued], ["request.turn-3", :queued], ["request.turn-4", :queued],
["request.turn-5", :queued], ["request.turn-6", :queued], ["request.turn-7", :queued],
["request.turn-8", :queued], ["request.resume", :queued]]
--- pass 2 ---
run_next=nil status=nil
--- pass 3 ---
run_next=nil status=nil
--- resolve the open checkpoint (thread settles) ---
checkpoint_status=:paused interrupts=1
checkpoint_status_after=:paused
after settle run_next=nil status=nil
```

Control — 2 deferred turns, same code path:

```
CONTROL run_next="request.resume" status=:completed
CONTROL statuses=[["request.start", :completed], ["request.turn-0", :queued],
["request.turn-1", :queued], ["request.resume", :completed]]
```

**Result: reproduced, and the report's severity premise survives.** Passes 1, 2 and 3
are all `nil`; the resume stays `queued` across every one; the resume is still
unclaimable after the checkpoint settles. Ten requests remain `queued` and the thread
never progresses. The control run proves the window is the cause: identical setup
minus the backlog lets the resume through.

The report's own probe (9 turns + 1 resume → `run_next=nil`) is therefore **extended,
not refuted**: it is not a one-pass artifact. I found the report's probe description
accurate.

### Verdict + reason

**UPHELD — `major`, high confidence.**

The BAR's `major` bar is "material correctness, security, reliability, observability,
scalability, dependency, or ownership gap with real operational cost."
The **reliability/liveness** gap is material and the operational cost is concrete and
nameable:

- A user or operator action the system has already **durably accepted** (the queue
  write committed, `queue add` printed `status: queued`) never runs, and the caller
  is never told. It is not failed, not retried, not surfaced — it looks like ordinary
  pending work in `queue list` and `build status`.
- The thread is left **paused with an open occurrence indefinitely**. The occurrence
  remains open, so `Worker#work_list` (`worker.rb:236-252`) keeps preferring it and
  keeps the thread's slot occupied.
- The `settle_paused_view` re-projection the report names means each retry can
  re-emit a waiting/approval view, so the operator may be re-notified about work they
  already answered, with no distinct starvation event or age metric to explain why the
  answer did not take.
- Recovery requires manual operator intervention (draining the backlog), which is a
  real operational cost, not a bounded delay.

I specifically tested the demotion hypothesis the brief demanded — that the delay is
bounded by a few passes and the finding is `minor`. **It is false.** The state is
persistent, not bounded, and it does not clear when the checkpoint settles.

Two honest limits I record rather than paper over, both already inside the report's
"confidence: high" claim but worth stating plainly:

- I did **not** run the full worker loop or a real sink. I proved unclaimability at the
  `DurableRunner`/`RequestInboxClaimer` boundary, which is where the starvation
  originates and where the report also stops. The "repeated user-visible
  notifications" secondary effect remains **unconfirmed**, and the report marks it as
  such — correctly.
- The window is per-thread, so this needs a nine-deep backlog on one thread. That is a
  precondition, but it is reachable by a plain unbounded CLI command, so it does not
  lower severity.

## F12-REL-01

The report assigns the ID **F12-REL-01** (`comms-unknown-ordering.md:1`,
"an unknown delivery does not fence later same-conversation parts"). Note:
`FINDINGS.md` does **not** carry an F12-REL-01 row — its table's only F12-adjacent
entry is absent, and the report's disposition says "accept as an open major finding for
F12". That index gap is a synthesis bookkeeping issue, not a challenge to the finding.

### Source re-verified

- **`delivery_drainer.rb:45-53` — correct.** `drain_once` spans `:45-57`;
  `reconcile_expired_deliveries` is `:46`, the `pending`-only `outbox_rows` read is
  `:47`, and `rows.each do |row|` is `:48`.
- **`delivery_drainer.rb:94-106` — correct.** `outcome = send_delivery(row)` at `:94`,
  `mark_delivery` at `:95-102`, and the `succeeded`-only `activate_after_receipt` at
  `:103-105` (the range closes on the `rescue Comms::AuthenticationError` at `:107`).
- **`delivery_drainer.rb:142-151` — correct.** `send_delivery` is `:142-151`; the
  `rescue Comms::AmbiguousDeliveryError` is at `:147` and the
  `{ status: 'unknown', receipt: nil }` body at `:150`.
- **`comms_outbox.rb:146-163` — correct.** `reconcile_expired_deliveries` marks
  claimed-with-`send_started_at_ms` rows `unknown` (statement opened `:148`, `SET
  status = 'unknown'` at `:150`) and claimed-without to `pending` (`:154-160`). Both are row-local and time-driven; neither looks at a
  conversation predecessor.
- **`comms_outbox.rb:73-98` — correct.** `claim_delivery` is a row-local CAS on
  `delivery_id` (`:89-96`); the predicate is `status = 'pending' OR (status = 'claimed'
  AND expiry AND send_started_at_ms IS NULL)`. No conversation term.
- **`comms_outbox.rb:197-205` — correct.** `outbox_rows` filters
  `status IN (?)` and orders by `created_at_ms` **only**. The report's precise point —
  that a filtered-out earlier row cannot act as a predecessor — is exactly right.
- **`documentation/design/comms.md:105-109` — correct, and stronger than reported.**
  Line 109 reads verbatim: *"Delivery order is fenced FIFO per conversation; an
  `:unknown` part blocks later parts until operator resolution."* This is an explicit,
  written, in-repo contract that the implementation violates.
- **`gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:49-72` — correct.**
  `def deliver` is at `:52` and its `rescue` closes at `:72`, so the cited range
  brackets the method; the `ResponseTooLargeError → AmbiguousDeliveryError` mapping the
  report leans on is `:69-72`, with the message *"send may or may not have happened"*
  at `:71`. This is the production route into the ambiguous state.
- `comms_store.rb:843-869` and `test/sqlite_comms_store_test.rb:707-740` — I did not
  need to reach these for the core claim; the store-status projection is supporting
  observability evidence only, and the report itself flags it as not proving intent.

**What differed:** the report's citation for the drainer loop is slightly loose —
it writes `45-53` ("walks that fixed result set in order") but the loop body continues
to `:52`; the substantive point (the set is fixed before A's outcome) is correct.

### Reachability chain

**Does the drainer process rows in strict conversation order?** No — and this is the
finding. `outbox_rows` orders by `created_at_ms` across **all** statuses that are
`pending` for the whole surface. It is neither a conversation grouping nor a
conversation-ordered walk. Within one conversation the `created_at_ms` order happens
to be arrival order, which is why A is attempted before B; but nothing re-checks
eligibility after A's outcome.

**Is a later row for the same conversation claimable while an earlier one is
`unknown`?** Yes, and the reason is structural, not incidental:

1. `drain_once:47` builds the candidate list **once**, before any send.
2. A is claimed (`:49`), passes the send boundary (`mark_delivery_send_started`,
   `:87-89`), and `send_delivery` throws `AmbiguousDeliveryError` → `{status:
   'unknown'}` (`:147-151`).
3. `mark_delivery` durably writes `A = unknown` (`:95-102`).
4. **The loop does not break.** `rows.each` advances to the next already-selected
   row. There is no `next if predecessor_unresolved?`, no re-query, no
   conversation-state check anywhere in `:48-52`.
5. B is claimed. Its claim predicate is row-local, so A's `unknown` status is
   irrelevant. B passes its own send boundary and is delivered succeeded.
6. `reconcile_expired_deliveries` on the *next* pass cannot help either: it only
   rewrites `claimed` rows on a timer. It never demotes or barriers a `pending`
   successor against an `unknown` predecessor.

**Is the multipart A/B shape real in production, or test-only?** This was my hardest
attack on the finding, and it **fails to refute** — the chain is fully live:

- `gems/tamoz-comms/lib/tamoz/comms/rendering.rb:23-35` — `Rendering.plain` emits
  `part_index` sequentially from 0 with `part_count = parts.length`.
- `gems/tamoz-comms/lib/tamoz/comms/outbox_delivery_sink.rb:120-129` — the sink loops
  `parts.each` and appends one outbox row per part **in order**, carrying
  `part_index`/`part_count`.
- `gems/tamoz-telegram/lib/tamoz/telegram/transport.rb:49-72` — `deliver` maps one
  `Delivery` to one `sendMessage`, and the response-cap failure path raises exactly
  `AmbiguousDeliveryError`.
- The outbox schema carries `part_index` and `part_count`
  (`migrator.rb:1219-1248` region, MIGRATION_19 `tamoz_comms_outbox`), and
  `OUTBOX_COLUMNS` (`comms_store_rows.rb:41-47`) projects them — matching the
  report's citation.

So a multi-part answer is a real, ordered, same-conversation sequence of outbox rows,
and any of them can independently hit the ambiguous path.

**The one genuine qualifier I add.** The report frames the impact as "conversation
order is inverted." That is true only when Telegram *did* accept A (lost response);
when Telegram did *not* accept A and the operator later resolves A `failed`, B is not
out of order — B is an orphaned continuation sent without its first part. The report
actually says both things (lines 51-54), so its analysis is more careful than its own
one-line severity summary suggests. Both outcomes are real defects; neither is
cosmetic.

### Guards searched

```
grep -rn "conversation_id" gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb
grep -rni "predecessor|barrier|blocks later|fence.*fifo|fifo" gems/tamoz-comms \
  gems/tamoz-comms-gateway gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb
grep -rn "part_index" gems/ --include=*.rb
grep -rn "Chinese|中文|你好|CJK|multibyte" gems/tamoz-comms gems/tamoz-comms-gateway gems/tamoz-telegram
sed -n '30,60p' gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store_rows.rb   # OUTBOX_COLUMNS
```

Every hit read. Results:

- **The predecessor/barrier grep returns literally zero hits** across
  `tamoz-comms`, `tamoz-comms-gateway`, and `comms_outbox.rb`. There is no
  ordering-barrier primitive, no predecessor query, and no `unknown`-aware eligibility
  rule in the outbox. The report's "the store has no durable conversation sequence or
  predecessor state" is confirmed by absence.
- **`reserve_delivery_slot` (`comms_outbox.rb:101-119`) is not an ordering barrier.**
  I checked this because the report claims it is not, and it is a plausible place for
  one to hide. It is a pure pacing reservation (per-chat and global rate), keyed on
  `surface_id` + `conversation_id` for *timing*, and it writes a `next_allowed_at_ms`,
  not an ordering constraint. It cannot distinguish "B must wait for A to resolve"
  from "B must wait 1 second". **The report is right.**
- **The multipart import path is live**, per the chain above — no test-only seam.
- **No status-aware guard in `outbox_rows`.** Confirmed by reading `:197-205`
  directly: the only predicate is `status IN (...)` over the caller's list.

### Probe

Path: `/tmp/tamoz-probe/challenge_comms_order.rb` (real `CommsOutbox` via
`adapter.bind_comms_store`, real `DeliveryDrainer`, fake transport raising
`AmbiguousDeliveryError` only for part A — no live Telegram).

```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
cd /Users/ghassan/my-projects/tamoz
timeout 150 ruby -Itest /tmp/tamoz-probe/challenge_comms_order.rb
```

Exact output:

```
partA part_index=0/2 partB part_index=1/2
outcome=:drained
attempts=["A", "B"]
deliveries=["B"]
durable=[["A", "unknown"], ["B", "succeeded"]]
--- control: independent conversation C appended AFTER the unknown A ---
control_outcome=:drained control_attempts=1
--- after operator resolution of A: does B ever become eligible? ---
resolve_A=:resolved
final_A=["A"]
final_B_status=["B", "C"]
```

**Result: reproduced exactly.** Same-pass, no restart required: A is attempted and
left durably `unknown`; B — the `part_index=1` successor of the *same* multipart
answer in the *same* conversation — is attempted and delivered `succeeded` in the same
`drain_once`. The transport really did carry B across the boundary (`deliveries=["B"]`),
which is the irreversible part.

Control results:

- **Independent conversation is not affected** (`control_attempts=1`): C, a different
  conversation, drains normally. This confirms the defect is per-conversation and that
  a fix need not stall unrelated traffic — matching the report's scalability lens.
- **B already crossed the boundary before resolution.** After resolving A to `failed`,
  B is still `succeeded`. **Explicit resolution cannot restore the original order** —
  the report's key impact claim, and the reason this is not a recoverable
  bookkeeping error.

### Verdict + reason

**UPHELD — `major`, high confidence.**

The operational cost is concrete and external:

- **An in-repo written contract is violated.** `documentation/design/comms.md:109`
  states the rule the code does not implement. This is not a missing-feature judgment
  call; the project already declared the invariant.
- **The failure is externally visible and irreversible.** B's bytes reach the user's
  chat before A is decided. A user reading part 2 of an answer without part 1 has been
  shown something the system cannot retract, correct, or reorder.
- **The honest-ambiguity invariant is preserved but useless.** The system correctly
  refuses to guess A's fate — then destroys the value of that honesty by letting the
  dependent part through anyway. The report's "the defect is the missing
  per-conversation ambiguity barrier around that safe state" is precisely the right
  characterization.
- **Operator resolution is not a remedy**, proven above: resolving A cannot unsend B.

The report's own scoping is disciplined and I want to credit it rather than attack it:
it explicitly declines to claim the adjacent concurrent-`claimed` FIFO race ("that
broader in-flight FIFO race is adjacent and is not claimed as an additional finding
here", line 106). I verified that scoping is honest — the `claimed` predecessor case
is a genuinely separate question and the report does not overreach into it.

The only demotion argument available is that multipart answers are uncommon (the
descriptor's `max_parts` is 5, and most replies are single-part). I reject it: the
frequency of a multipart answer does not change that when one occurs the contract
breaks irreversibly and silently. The BAR's `major` bar is "material ... reliability
... gap with real operational cost" — met.

## F05-REL-01

### Source re-verified

- **`schedule.rb:49-70` — correct.** `def initialize` is `:49-70`; the override is the
  single line `@digest = definition_digest || compute_digest(@validated)` at `:69`,
  and `super(**@validated, definition_digest: @digest)` at `:70`. The report's
  "uses any truthy supplied value instead of the canonical result" is literally the
  `||`. Correct.
- **`schedule.rb:73-84` — correct.** `compute_digest` is `:78-84` (doc comment
  `:73-77`); it rejects exactly `%i[revision enabled definition_digest]` at `:81`.
  The report's "excludes only lifecycle revision, enabled, and the digest itself"
  matches.
- **`schedule.rb:15-19` — correct.** The immutability/content-addressing claim
  ("The value is IMMUTABLE and content-addressed: `definition_digest` binds every
  field") is at `:15-19`.
- **`schedule_store.rb:52-57,80-101` — correct.** `put_schedule` is `:52-90`; the
  `INSERT INTO tamoz_schedules(... definition_digest ...)` binds
  `schedule.definition_digest` directly at `:83` (inside the statement opened at
  `:80`). The supplied value is written, not the recomputed one. Correct.
- **`schedule_store.rb:689-707` — correct, exactly.** `materialize_schedule` is at
  `:689`; the decisive line `coerced["definition_digest"] = row.fetch(1)` is at `:703`,
  inside the comment "The DB revision, enabled flag, and stored definition digest are
  authoritative; reconstructing must not recompute any of them" at `:700-702`; and the
  method's `rescue JSON::ParserError, KeyError, TypeError → CheckpointCorruptionError`
  closes it at `:706-707`. The cited range is precise to the line. (An earlier draft of
  this challenge recorded an off-by-two here; that was my own misread from a `sed`
  window, and I withdraw it — the citation is correct.)
- `schedule_store.rb:654-656` — `schedule_definition_digest` is at `:653-655` and
  `payload_digest` is computed from `Tamoz::Core.jcs(payload)`, a **different** value
  from `schedule.definition_digest`. The report's point that `payload_digest`
  authenticates neither is correct — I verified the two digests differ in the probe
  below.
- `capability/descriptor.rb:63-76` — the analogous pattern the report holds up as the
  precedent. I read it; it computes and verifies an override. The comparison is apt.
- `cli_schedule_commands.rb:43-61,84-101` — the production constructor. I read it: the
  CLI does **not** expose a `--definition-digest` option, confirming the report's
  "does not expose a digest option."

**What differed:** nothing. Every citation in this report resolves to the claim made
about it, and the `:689-707` range is exact.

### Reachability chain

**Which constructor path allows the override?** `Schedule.new` with a truthy
`definition_digest:` argument. That is the only path — `:69`'s `||`.

**Is it reachable from production code, or only from tests?** This is the question the
brief asks, and the honest answer is: **the override is reachable from production
code, but only for callers that pass it, and I found no in-tree non-test caller that
does.**

- **Real production caller that passes a digest:** `ScheduleStore#materialize_schedule`
  (`schedule_store.rb:689-707`) — `coerced["definition_digest"] = row.fetch(1)`. This
  is production code, and it is *deliberate*: the comment at `:700-702` states the
  stored digest is authoritative and must not be recomputed. So the store relies on
  the override.
- **Production callers that do NOT pass it:** the shipped CLI is the only other
  in-tree constructor I found, and the report is right that it exposes no digest
  option. I grepped `definition_digest` across `gems/`, `apps/`, `test/` and every
  non-test hit is either the store's rehydration, a wire projection
  (`cli_schedule_commands.rb:316`, `worker_runtime.rb:935-949`), or an unrelated
  subsystem's same-named field (`CapabilityDescriptor`, `Compiled`, `SurfaceDescriptor`,
  `Checkpoint`). **No model output, operator prompt, or workspace file reaches this
  parameter.**

So the report's reachability framing is **correct and appropriately conservative**:
"a same-process caller, embedder, fixture, or future deserializer can submit a false
digest"; "No model or workspace input path was found that can currently inject this
field." I could not find one either.

**Does the forged value survive a SQLite round trip?** Yes — this is the part of the
claim that makes it a durable integrity problem rather than a transient value-object
wart, and I confirmed it three ways (see probe): through `put_schedule`/`list_schedules`,
and also by writing the forged digest straight into the `definition_digest` column and
re-reading, which `materialize_schedule` replays without recomputation.

### Guards searched

```
grep -rn "definition_digest" gems/ apps/ test/ --include=*.rb
grep -n "payload_digest" -r gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb
```

Every hit read. Results:

- **No recomputation on read.** `materialize_schedule` sets
  `coerced["definition_digest"] = row.fetch(1)` (`:702`) and the surrounding comment
  explicitly forbids recomputing. There is no verification step. Confirmed by probe.
- **`payload_digest` is not a guard for this.** Verified in the probe: the canonical
  definition digest is `sha256:b7e57433…` while `payload_digest` is computed over the
  JCS bytes with a different domain. They are different values serving different
  purposes; `payload_digest` cannot detect a forged `definition_digest`.
- **No digest-shaped validation.** `validate!` (`schedule.rb:281-…`) validates
  `capability_grant`, `payload_ref`, budgets, enums — I confirmed by triggering a real
  validation error in my first probe run (`capability_grant must be a non-empty hash`).
  The digest is not validated at all, not even for shape. The report's "the value is
  documented as immutable... but a supplied digest is not even frozen" is correct —
  the probe confirms `digest_frozen=false`.
- **The analogous `Capability::Descriptor` DOES guard** (`descriptor.rb:63-76`), which
  is the strongest evidence that the omission is a real gap rather than an intentional
  design choice. The pattern exists in-repo and was not applied here.

### Probe

Path: `/tmp/tamoz-probe/challenge_schedule.rb`.

```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
cd /Users/ghassan/my-projects/tamoz
timeout 150 ruby -Itest /tmp/tamoz-probe/challenge_schedule.rb
```

Exact output (digest test):

```
canonical=sha256:b7e574336c57cd100e9c2146d6ae3c6aa775020eebba0ddfabddd4b725fcb9bd
overridden=sha256:0000000000000000000000000000000000000000000000000000000000000000
override_accepted=true
digest_frozen=false
equal_definitions_differ=true
put_schedule_returned_digest=sha256:0000000000000000000000000000000000000000000000000000000000000000
list_schedules_digest=sha256:0000000000000000000000000000000000000000000000000000000000000000
round_trip_preserved_forgery=true
forged_row_replays_digest=true
recomputed_canonical=sha256:b7e574336c57cd100e9c2146d6ae3c6aa775020eebba0ddfabddd4b725fcb9bd
stored_matches_recomputed=false
```

**Result: reproduced exactly**, matching the report's description point for point
(accepted override, different digest for identical fields, `frozen? == false`, forged
value surviving the public SQLite adapter and a direct-column round trip).

**Control case:** `recomputed_canonical` shows the honest digest for the identical
fields is `sha256:b7e57433…`, and `stored_matches_recomputed=false` proves the stored
forged value is not merely a coincidental match — it is wrong. `equal_definitions_differ=true`
is the defect in one line: two Schedule values with byte-identical canonical
definitions report different content digests.

### Verdict + reason

**DEMOTED to `minor`, high confidence.**

I agree with the analyst's *own* conclusion (`minor`) and I am recording the demotion
explicitly because the scanner's original signal implied a reliability finding and the
brief asked me to attack the severity. The BAR's `minor` definition — "bounded
maintainability, naming, documentation, testability, or local observability debt with
limited immediate impact" — fits, and the `major` bar is not met. There is **no
concrete operational cost today**:

- **No production input reaches the parameter.** I grepped every non-test
  `definition_digest` site; none accepts model output, CLI flags, operator prompts, or
  workspace files. The only production caller that supplies a digest is the store's own
  rehydration, which needs it by design.
- **The digest is consulted by nothing security-relevant.** The report checked this and
  I confirmed the reach: the worker applies the current grant intersection from the
  schedule *fields*; occurrence identity uses `(schedule_id, schedule_revision,
  nominal_fire_at_utc)` (`occurrence.rb:9-14,32-44`) and the request id derives from
  that — **not** from `definition_digest`. So a forged digest cannot alter which work
  runs, under what authority, or with what idempotency. The report's refusal to promote
  this to an authority bypass or replay finding is correct.
- **The observable blast radius is a display string** (`tamoz schedule show`,
  `scheduled_work`) plus audit correlation. Real, but bounded.

Where I would push back on calling it `info` instead: the value object's own
documented contract ("IMMUTABLE and content-addressed: `definition_digest` binds every
field", `schedule.rb:15-19`) is falsified by its own constructor, the digest is not even
frozen, the forgery is durable across restarts, and the repo already contains the
correct pattern in `Capability::Descriptor`. That is a genuine contract-integrity defect
with a cheap fix — `minor`, not `info`.

The report's own severity line says "**minor**, downgraded from the scanner's
reliability implication", so my verdict **agrees with the report's assigned severity**
while rejecting any promotion. Its confidence split (`high` for constructor/store
behavior, `medium` for operational impact) is also honest and matches what I found.

## CF07-ARCH-01 and CF07-REL-02

The report's actual claims (`occurrence-contract-and-fencing.md:1-7`):

| ID | Claim | Report severity |
| --- | --- | --- |
| **CF07-ARCH-01** | Worker settlement requires two SQLite-only occurrence methods (`acknowledge_occurrence`, `occurrence_for_request`) that are absent from the versioned `ScheduleStore` contract, so a conforming adapter can never settle an occurrence | major |
| **CF07-REL-02** | `complete_occurrence` accepts an execution id different from the one acknowledged for the running occurrence | major |

### Source re-verified

- **`schedule_store.rb:5-8` and `:17-75` (contract) — correct.**
  `gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:5-8` states the versioned
  structural-contract/interchangeability claim. The declared v2 surface
  (`put_schedule`, lifecycle methods, `materialize_due`, `complete_occurrence`,
  `list_occurrences`) sits in that range, and neither `acknowledge_occurrence` nor
  `occurrence_for_request` is declared. The report is right.
- **`worker_runtime.rb:491-497` — correct.** `schedule_occurrence` returns immediately
  when the store does not respond to `occurrence_for_request`. Verified by reading.
- **`worker.rb:571-587` — correct.** `settle_schedule_occurrence` returns on the
  resulting `nil` before acknowledgement or completion.
- **`schedule_store.rb:487-559` — correct.** The concrete SQLite adapter supplies both
  extensions: `acknowledge_occurrence` at `:487-509`, `complete_occurrence` at
  `:511-536`, `occurrence_for_request` at `:541-559`. So the normal path hides the gap.
  Correct.
- **`schedule_store.rb:487-505` (acknowledge) — correct.** The UPDATE is
  `WHERE occurrence_id = ? AND state = 'enqueued' AND fence = ?` (in the statement
  opened at `:491`, closing `:499`), it records
  `JSON.generate({"execution_id" => execution_id})` in `reason`, and the refusal is at
  `:502-505`.
  The execution id is written as **evidence**, never as a predicate. Correct.
- **`schedule_store.rb:511-535` (complete) — correct, and this is the crux.**
  `complete_occurrence` is `:511-536` and the report's range lands on the decisive
  code: the SQL predicate `WHERE occurrence_id = ? AND state = 'running'` is at
  `:525`, and the bind array
  `[status.to_s, JSON.generate({"execution_id" => execution_id, "evidence" => evidence}), now, id]`
  is at `:527`. **The supplied execution id never appears in the WHERE clause.** The
  report's claim is exactly right.
- **`occurrence.rb:82-101,137-144`** — the value state machine's same omission. I did
  not need to exercise this separately: the store-level SQL omission is the load-bearing
  claim and it is confirmed. The report's "medium" confidence for an in-tree mismatched
  caller is honest.
- **`test/sqlite_schedule_store_test.rb:533-565`** — correct. The existing test
  acknowledges `e-1`, completes `e-1` successfully, and then asserts a **second**
  completion (`e-2`) raises — but only because the row is *already terminal*. It never
  attempts a mismatch while the row is still `running`. **That is exactly the covering
  gap the report describes**, and my probe fills it.

**What differed:** nothing material on either claim. Both cited line ranges resolve to
the claims made about them.

### Reachability chain

**CF07-ARCH-01.** The chain is a contract/conformance argument, and it is sound:

1. `ScheduleStore` is documented as a versioned structural contract with interchangeable
   conforming adapters (`schedule_store.rb:5-8`).
2. The declared surface does not include the two settlement methods.
3. `worker_runtime.rb:491-497` uses `respond_to?` to nil-safe the lookup, so a
   *conforming* adapter does not raise — it silently returns `nil`.
4. `worker.rb:571-587` then returns before ack/completion.
5. The occurrence stays `enqueued` forever. Non-terminal rows remain pending in the
   overlap census, so a `forbid` schedule skips later due occurrences indefinitely.

**Reachability caveat I must state plainly:** the in-tree implementation *is* SQLite
and *does* supply both methods, so **this defect is not reachable through the shipped
adapter.** It is reachable by any third-party or future conforming adapter — which is
precisely what a "versioned structural contract" promises to support. That makes it a
real ownership/contract gap (the report's own framing) rather than a live production
failure. The report does not overclaim this; it says the normal path "hides the
boundary defect."

**CF07-REL-02.** The chain I verified against a real SQLite DB:

1. `acknowledge_occurrence(id, execution_id: "exec-good", fence:)` transitions
   `enqueued → running` and records `{"execution_id":"exec-good"}` in `reason`.
2. `complete_occurrence(id, execution_id: "exec-wrong", status: :failed, evidence: {})`
   matches on `occurrence_id AND state = 'running'` only.
3. The row transitions to `failed` and `reason` is **overwritten** with
   `{"execution_id":"exec-wrong", ...}`.

**Reachability caveat:** the in-tree worker carries one id from the durable view/request
into both calls (`worker.rb:577-601`), so no current CLI path supplies a mismatch. The
report says this explicitly and grades confidence "medium for an in-tree mismatched
caller." That is the correct and honest grade. The defect is at the store boundary: a
stale, buggy, or unauthorized store caller can mark a live occurrence terminal under a
different execution, and the overwrite **destroys the only execution evidence** — so
the mismatch is not even detectable after the fact.

### Guards searched

```
grep -n "def acknowledge_occurrence" -A 30 gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb
grep -n "def complete_occurrence" -A 35 gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb
grep -n "def occurrence_for_request" -A 20 gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb
grep -n "def list_occurrences" -A 12 gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb
grep -rn "acknowledge_occurrence|occurrence_for_request" gems/ test/
sed -n '520,575p' test/sqlite_schedule_store_test.rb
```

Every hit read. Results:

- **No execution-id equality check exists anywhere in the completion transaction.**
  Read `:514-542` directly. The predicate is row id + state. Nothing else. There is no
  CAS on the recorded execution id, no read-then-compare, no post-hoc validation.
- **No guard on the read path either.** `occurrence_for_request` (`:544-559`) selects
  by `request_id` only.
- **The declared contract offers no equality rule** to appeal to, which is the
  CF07-ARCH-01 point reinforcing CF07-REL-02: the surface exposes execution identity
  in the signature but never states that it must match.
- **The import surface** (`gems/tamoz-scheduler/lib/tamoz/scheduler/schedule_store.rb:17-75`)
  — I read the declared methods and confirmed the two extensions are absent. No
  `respond_to?` fallback or default implementation rescues them.
- **A misread I ruled out:** `TERMINAL_EXECUTION_STATUSES` (`:512`) does validate the
  *status* enum and refuses `:enqueued`/`:bogus` — the report's cited test at
  `:533-565` covers exactly this. So a status guard exists; an **identity** guard does
  not. The report names this precisely ("a contract that exposes execution identity but
  no required equality rule") and does not confuse the two.

### Probe

Path: `/tmp/tamoz-probe/challenge_schedule.rb`, second test, against a real temp
SQLite DB and the real `ScheduleStore`.

Exact output:

```
occurrence_id=sha256:569639b549af8daf90652d6d24561b4dd6370973aff219659f2b2a811dc45692 state=enqueued
ack=nil
wrong_execution_completion=nil
stored_state=failed reason={"execution_id"=>"exec-wrong", "evidence"=>{}}
```

**Result: reproduced exactly.** `ack=nil` means acknowledgement succeeded (it returns
`nil` on the happy path and raises `LeaseLostError` otherwise). `wrong_execution_completion=nil`
means completion **succeeded** — it returns `nil` on success and raises
`SchedulerError` on refusal. The occurrence is now `failed`, and the stored `reason`
records **`exec-wrong`**, the id that was never acknowledged.

**Control case:** the existing suite's
`test_completion_requires_a_terminal_status_and_the_running_state`
(`test/sqlite_schedule_store_test.rb:533-565`) is the negative control and it passes:
a *second* completion of an already-terminal row does raise. So the store is not
indiscriminately permissive — it is permissive **specifically** about execution
identity, which is the finding. My first probe run also failed loudly on an unrelated
validation error (`capability_grant must be a non-empty hash`), confirming the
constructor does enforce its other invariants — the omission is scoped to the
completion predicate, not a general lack of validation.

For CF07-ARCH-01 I reproduced the report's fake-store probe shape by reading the
declared contract and confirming the two methods are absent and that
`worker_runtime.rb:491-497` degrades to `nil` via `respond_to?` rather than raising.

### Verdict + reason

**CF07-ARCH-01: UPHELD — `major`.** The BAR's `major` bar includes "ownership gap with
real operational cost." The cost is nameable and specific: a conforming adapter — the
thing the contract explicitly promises to support — leaves every occurrence permanently
`enqueued`, and the failure is **silent** (no `schedule.error`), so it presents as
ordinary queued work rather than a contract violation. A `forbid` schedule then skips
later due occurrences **indefinitely**, converting recurring work into permanently
skipped history with no signal. The severity rests on the contract's own promise, which
is the right basis for an architecture finding; a versioned "interchangeable adapters"
contract that its only real client cannot satisfy is a genuine ownership defect, not
naming debt.

**CF07-REL-02: UPHELD — `major`.** The BAR's `major` bar is met on **correctness and
observability/evidence**: the terminal transition accepts an identity that was never
acknowledged, and the write **overwrites the only execution evidence**, so a false
completion is both produced and made undetectable after the fact. On the BAR's
`critical` text — "false completion ... or materially misleading evidence" — I
considered promotion and **decline it**: no in-tree caller supplies a mismatch, so
there is no demonstrated unsafe action today, and the report's own "medium for an
in-tree mismatched caller" is the honest grade. `major` is correct; `critical` would
overclaim a reachable path I could not show.

I credit one piece of the report's discipline that I tested and agree with: it declines
to promote the scanner's separate **lease/reclaim** lead, on the grounds that
`materialize_due` accepts `lease_for:` but never reads it
(`schedule_store.rb:168-199`), the occurrence table has no expiry column, and the
shipped materialization is one atomic transaction — so there is no persisted long-lived
claim to renew or reclaim. I read `:168-199` and confirmed the `lease_for:` parameter is
accepted and unused. Deferring that as a contract decision rather than promoting it is
the right call.

## Net effect on FINDINGS.md

| Finding | Action |
| --- | --- |
| **F07-REL-01** | **keep** — `major`, high. Reproduced across three passes; not bounded, not self-healing; no fallback query exists. |
| **F12-REL-01** | **keep** — `major`, high, **and add the row**: the finding is valid but is missing from the `FINDINGS.md` table, which lists no F12 entry despite the report's accepted disposition. |
| **F05-REL-01** | **keep as `minor`** — demotion from the scanner's reliability implication is correct; no production input reaches the parameter and the digest gates no authority, identity, or idempotency decision. |
| **CF07-ARCH-01** | **keep** — `major`, high. Contract/ownership gap with silent, indefinite operational cost for any conforming non-SQLite adapter. |
| **CF07-REL-02** | **keep as `major`** — not promoted to `critical`; real store-boundary identity gap with destroyed evidence, but no demonstrated in-tree mismatched caller. |

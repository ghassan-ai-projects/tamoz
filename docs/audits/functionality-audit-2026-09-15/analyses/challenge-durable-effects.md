# Independent challenge — F07-SEC-01, CF04-REL-01, F02-OBS-01

| Field | Value |
|---|---|
| Challenger | `challenger_effects` (independent, adversarial) |
| Date | 2026-09-15 |
| Baseline | `audit-15-09`, HEAD `582ae55` |
| Method | Re-read every cited `file:line`; traced callers of `EffectReconciler#resolve` and `Session#resolve_effect`; probed the real classes against temp SQLite DBs under `/tmp`; attacked severity against BAR.md's narrow `critical` definition; ran the named focused suites |

Verdict summary: **F07-SEC-01 UPHELD (critical)** — the defect reproduces and the
report's citations are exact, but its *reachability story* is partly wrong and I
correct it below. **CF04-REL-01 UPHELD (major)** — reproduced byte-for-byte,
including the report's own probe line. **F02-OBS-01 REFUTED as stated** — the
claimed symptom ("durably recorded as `failed`") does **not** reproduce; the real
behavior is worse in one respect and different in kind, and the cited seam is the
wrong method.

## F07-SEC-01

### Source re-verified

Read: `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_reconciler.rb` (all 231 lines),
`effect_journal_rows.rb` (41), `effect_journal_key.rb:130-184`,
`effect_journal.rb:156-177`, `effect_preparation.rb:139-160`,
`gems/tamoz-agent-session/lib/tamoz/agent/session.rb:372-378,422-432,494-507`,
`gems/tamoz-agent-session/lib/tamoz/agent/session_context_controls.rb`,
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:234-256`,
`gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb:579-606,726-736`,
`gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_store.rb:85-115`.

**Every citation in the report is exact.** `resolve` is at
`effect_reconciler.rb:173-225` (report said 173-206 — that range covers the
transaction body, which is the material part; the method closes at 225 and the
`fetch` return is at 224, a harmless truncation). The update predicate is
`WHERE effect_key = ? AND status = ?` on `effect_key` + prior head status only
(`:202`), never thread or namespace. `EffectJournalRows.effect` (read in full)
selects `WHERE effect_key = ?` alone — **no scope predicate**, exactly as claimed.
`verify_identity!` exists (`effect_journal_key.rb:138-179`) and checks
`lease.thread_id`/`lease.namespace` (`:153-154,161-170`), and its only caller is
`effect_preparation.rb:139` — **not** the resolve path. `actor` is text-normalized
(`:180`) and appended to the transition (`:208-222`) with no principal check.
Report accurate; no citation challenge.

### Reachability chain

The report's framing is that the CLI "usually isolates each thread in its own
database, but the public session/checkpointer API supports a shared adapter."
Reading the callers, **the shared-adapter case is not a hypothetical embedding
choice — it is the shipped worker's normal configuration**, which makes the
defect *more* reachable than the report claimed, not less:

1. `Session#resolve_effect` (`session.rb:374-378`) takes a caller-supplied
   `thread:` and `namespace:`, then `with_effect_writer` (`:422-432`) calls
   `app_for_thread(thread).checkpointer.open_writer(thread_id: thread, ...)`.
2. `app_for_thread` (`:494-507`) fetches a *compiled graph variant* from `@apps`,
   but every variant was compiled with the **same** `options.checkpointer`
   (`:90-92`), and `@apps` is keyed only by graph version. So a single `Session`
   hands out the same store for every thread: the cross-thread case is reachable
   **inside one process and one Session object**, with no embedding cleverness.
3. The CLI `tamoz resolve` (`cli_session_commands.rb:244-252`) does isolate:
   `run_durable` builds `Tamoz::SQLite::Adapter.new(path:
   File.join(session_dir, "#{thread_id}.sqlite3"))` (`cli.rb:588`) and closes it
   (`:604`). So at the CLI, B's lease genuinely cannot see A's row. The report
   said this; it is correct.
4. **But** `WorkerRuntime` builds one adapter for the whole worker
   (`worker_runtime.rb:61` `@adapter = build_adapter(lease_ttl)`, `:1071-1075`) and
   serves every thread from it; `Worker#work_list` returns **multiple threads** in
   one pass (`worker.rb:241-256`, `pending_threads(limit: @batch)`) and
   `advance_entries` fans them across a thread pool (`:213-221`). Concurrent
   B-writer and A-row are co-resident there by construction.
5. The worker does **not** call `resolve_effect` — I grepped it: the only
   non-test, non-doc caller is `cli_session_commands.rb:245`. So the worker is
   where a *shared* store exists, and the CLI `tamoz resolve` is the only caller
   that resolves, on an *isolated* store. The two facts do not currently meet in
   the shipped binaries.

**Attacked with AGENTS.md's owner directive** ("do not cover rare cases; if a
scenario cannot happen by construction, do not write code for it"). I applied it
honestly and it does **not** rescue the finding: the defect is not a race and not
a rare interleaving. It is a *missing predicate on a public method* whose
signature (`thread:` is caller-supplied and independently validated only for
lease acquisition) advertises a scope guarantee it does not enforce. Anyone who
runs a worker plus `tamoz resolve` against one directory, or embeds a `Session`
over one adapter and resolves two threads, gets it deterministically on the first
call. That is a boundary violation, not a rare case.

### Guards searched

- `grep -rn "lease\|fence\|thread_id\|namespace" gems/tamoz-sqlite/lib/tamoz/sqlite/effect*`
  → read every hit. `effect_preparation.rb:75-89,101-121` validates the lease and
  scopes the insert by `lease.thread_id, lease.namespace`; `effect_lifecycle.rb:28-49`
  validates the lease; `effect_attempt_ledger.rb:44-54` carries the fence.
  `effect_reconciler.rb` appears in the grep **only** for `@guard.lease.fence`
  inside the `not_applied` branch (`:109`) and `validate_lease_in_transaction!`
  in that same branch (`:86-92`) — the `completed` and `unknown` branches and the
  whole of `resolve` never touch the lease's scope.
- **Casualty check on the claim "a UNIQUE constraint prevents it":** none does.
  `tamoz_effects` is keyed by `effect_key` globally; a B writer *inserting* a
  duplicate is refused by `verify_identity!` in prepare, but `resolve` performs an
  `UPDATE` on an already-unique row, so no uniqueness constraint is in play. The
  `WHERE effect_key = ? AND status = ?` CAS is real (`:206` raises if
  `tx.changes != 1`) and makes the write atomic — it just guards the wrong thing.
- **`EffectReconciler#reconcile` has the same hole** (`:31-168`): it loads by key
  with no scope predicate and only the `not_applied` branch validates the lease.
  The report flags this as follow-up scope; my read confirms it and I record it as
  the same seam.

### Probe

Path `/tmp/tamoz-challenge/probe_f07.rb` (repo untouched).

```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
cd /Users/ghassan/my-projects/tamoz && timeout 150 ruby -Ilib -Itest /tmp/tamoz-challenge/probe_f07.rb
```

Output:

```
A_before status=:unknown thread="thread.a" ns=[]
CROSS_THREAD error=NilClass:nil
CROSS_THREAD returned_thread="thread.a" returned_status=:succeeded
A_after  status=:succeeded thread="thread.a" requires=false
A_next_prepare action=:return
CONTROL_SAME_THREAD error=NilClass status=:succeeded
CONTROL_OTHER_NAMESPACE error=NilClass:nil
```

**Positive case reproduced.** Thread B's writer called
`effects.resolve(key: key_a, :succeeded, ...)` on A's `unknown` unsafe effect; the
call **succeeded**, returned a record still stamped `thread_id="thread.a"`,
cleared `requires_reconciliation` to `false`, and A's own next `prepare` for the
same request now answers `:return` — a false completion delivered to A. This is
strictly worse than the report's own probe summary, which did not show the
`prepare → :return` consequence.

**Controls behave as they should:** same-thread resolution still succeeds, and —
importantly — **cross-namespace resolution *also* silently succeeds**
(`CONTROL_OTHER_NAMESPACE error=NilClass`). The namespace axis of the report's
claim is therefore confirmed too, and independently of the thread axis.

### Verdict + reason

**UPHELD at `critical`, confidence high.**

Against BAR.md's `critical` definition I checked each limb rather than accepting
the label:

| Limb | Hits? |
|---|---|
| unsafe action | No — no external operation is executed. |
| authority bypass | **Yes** — B's lease is honored as authority over an A-scoped row; the row's own contract binds effect identity and leases to `(thread_id, namespace)` (`docs/design-v0.1/PERSISTENCE_DESIGN.md:150-157,183-220`). |
| data loss | Partially — `requires_reconciliation` is cleared, removing A from the unresolved set (`thread_tombstone.rb:159-170`), so unresolved evidence can be purged as settled. |
| **false completion** | **Yes, and this is the decisive limb.** A's subsequent `prepare` returns `:return` (`effect_preparation.rb:150-154`), i.e. the framework tells A its unsafe `device.write` succeeded when nobody established that. |
| broken durability/effect semantics | **Yes** — terminal receipts are supposed to be immutable and evidence-backed; this mutates one from a foreign scope. |
| materially misleading evidence | Yes — the transition log records an actor/payload that does not establish target ownership (`:208-222`). |

The report's own hedge ("a scope/embedding boundary failure rather than a hosted
tenant breach") is correct and does not demote it: OSA's `critical` bar is
*false completion*, not *tenant breach*. The consequence is a wrong **OUTCOME**
for A (A is told the effect succeeded), not merely a wrong **attribution** on an
already-refused operation. That distinction is the one the assignment asked me to
test, and it lands on the critical side.

Confidence: **high**, not medium. The report said `high` and I confirm — source
trace plus a reproducible probe, and the positive case reproduced on my first
attempt after correcting only my own probe's precondition (driving A to
`unknown` first).

## CF04-REL-01

### Source re-verified

Read `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` (all 334
lines), `effect_preparation.rb:140-220`, `effect_completion.rb`,
`session_steps.rb:210-245`, `session_evidence.rb:176-190`,
`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_reconciler.rb:188-206`,
`test/sqlite_effect_journal_test.rb:316-437`.

**Every citation exact.** `resolve_decision`'s `:failed` branch is
`effect_dispatcher.rb:97-101` and calls `terminal_attempt(decision.record)`;
`terminal_attempt` is `:280-283` and is literally
`record.attempts.reverse.find { |a| a.status == :succeeded } || record.attempts.last`
— a succeeded-first scan, exactly as claimed. `recorded_outcome` (`:162-173`)
takes `attempt_number: record.current_attempt` (`:168`) and
`attempt_identity: current_attempt_identity(record)` (`:169`), while `error:` comes
from the selected `attempt` (`:100`) — so number/identity and error genuinely
describe different attempts. `prepare` maps `'failed'`/`'abandoned'` → `:failed`
(`effect_preparation.rb:150-151`). `resolve` on a `reconcile` head preserves
`requires_reconciliation` for non-`succeeded` (`effect_reconciler.rb:199-200`).
No citation challenge.

### Reachability chain

Concrete non-test sequence, all through public journal/dispatcher calls:

1. Idempotent effect, attempt 1 starts under owner O1.
2. Attempt 1's deadline expires (`effect_preparation.rb:158-160,203-216` grants
   attempt 2 for `read_only`/`idempotent`).
3. Attempt 2 runs under O2 and records a typed `ToolArgumentError` with
   `repairable: true` → head `:failed`, current attempt 2.
4. **O1 commits a late success**, which for an attempt older than the head sets
   the head to `:reconcile` and retains the late receipt
   (`effect_completion.rb:153-167`).
5. Operator runs `tamoz resolve ... failed` → head `:failed`, current attempt
   stays 2, `requires_reconciliation` stays 1.
6. Next dispatch: `prepare` → `:failed` → dispatcher `:failed` branch →
   `terminal_attempt` finds attempt 1's success → `error: nil`.

Every step is a shipped operation. Step 4 is a real race the P6 design explicitly
accommodates; step 5 is the documented operator recovery. This is reachable
without any unusual embedding.

### Guards searched

`terminal_attempt` is called from exactly two places, both in `resolve_decision`
(`:93` for `:return`, `:98` for `:failed`). There is no status-specific selector
anywhere else, no `terminal_error` persisted on the head, and
`current_attempt_identity` (`:285-287`) exists but is *not* used to pick the
error. The `record.attempts.last` fallback would have been correct for the
`:failed` case — the bug is that the succeeded-first scan at `:281` runs first.
No guard prevents it.

### Probe

Path `/tmp/tamoz-challenge/probe_cf04.rb`.

```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
cd /Users/ghassan/my-projects/tamoz && timeout 150 ruby -Ilib -Itest /tmp/tamoz-challenge/probe_cf04.rb
```

Output:

```
after_attempt2_failure action=:execute head=:failed current=2
after_late status=:reconcile current=2 requires=true
  attempt 1 status=:succeeded error=nil
  attempt 2 status=:failed error={"class"=>"Tamoz::Tools::ToolArgumentError", "message"=>"bad arg", "repairable"=>true}
after_resolve status=:failed current=2 requires=true
REPLAY status=:failed reused=true error=nil attempt=2 identity="sha256:98ba0166.../attempt/2/execution/42148173.../fence/3"
CONTROL_NO_LATE_SUCCESS status=:failed error={"class"=>"Tamoz::Tools::ToolArgumentError", "message"=>"bad arg", "repairable"=>true} attempt=1
```

The three `after_*`/`REPLAY` lines **match the report's quoted probe output
exactly** (same statuses, same `current=2`, same `requires=true`, same
`status=:failed reused=true error=nil attempt=2`). Independent reproduction with
the same result.

**Control is decisive.** `CONTROL_NO_LATE_SUCCESS` — the same repairable failure
with no late success in history — replays with the **full** repairable error and
its correct attempt number (1). So the nil error is caused specifically by the
mixed attempt history, not by failed-head replay in general, and the dispatcher
path is otherwise correct. This is the strongest possible confirmation that the
report located the right line.

### Verdict + reason

**UPHELD at `major`, confidence high.**

I tried to promote it to `critical` and could not do so honestly. It hits
*broken effect semantics* in a weak sense and *materially incomplete evidence*,
but it does **not** hit false completion (the status really is `:failed`,
correctly), unsafe action (the effect is not re-executed), authority bypass, or
data loss (both attempts remain durable). The harm is that a repairable typed
failure is degraded to a generic terminal `ToolError`, which suppresses the
bounded repair path (`session_steps.rb:230-243` +
`session_evidence.rb:183-187`) and loses the only useful failure detail. That is
exactly BAR.md's `major`: "material correctness, reliability, **observability** …
gap with real operational cost." The report's own lens table reaches the same
conclusion and I agree with it.

One nuance worth recording: the report notes that a late success beside a
succeeded head is the *supported* case for `:return`, so the fix must not simply
delete `terminal_attempt` from `:return`. Its recommendation (make `:failed`
read `record.current_attempt`) is the smallest correct action at that seam. I
endorse it.

## F02-OBS-01

### Source re-verified

Read `gems/tamoz-agent/lib/tamoz/agent/worker.rb:84-117,200-260,328-365,635-680,725-745,880-901,1174-1186,1200-1215`,
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_rendering.rb:120-140`,
`cli_session_commands.rb:210-256`,
`gems/tamoz-graph/lib/tamoz/graph/executor.rb:13-70,140-170,520-554`,
`checkpoint_codec.rb:22,686`,
`gems/tamoz-sqlite/lib/tamoz/sqlite/request_transition_plan.rb:17-40`,
`gems/tamoz-cancellation/lib/tamoz/cancellation_token.rb:78-84`,
`test/cancellation_visibility_test.rb`.

**Citations differ — two are wrong.** The report and the JSON both name the
seam `gems/tamoz-agent/lib/tamoz/agent/worker.rb#terminal_reason` and cite
`worker.rb:1180-1183`. **There is no `terminal_reason` method in `worker.rb`.**
`grep -n "def terminal_reason\|def failure_reason\|def settled_failure_reason"` gives
only `settled_failure_reason` (`:889`) and `failure_reason` (`:1179`). Lines
1180-1183 are the body of **`failure_reason`**, whose own comment calls it "the
durable reason recorded on a **terminal-failed** request (the **staleness
verdict**)". Its sole caller is `settle_stale_request` (`:673`), reached only
when `request.status == :failed` **already** (`:654`). It is a read-side
projection of an already-failed row; it is not on the token-cancellation path at
all. `Worker#run` (`:84-117`) is cited correctly — it does return the in-memory
reason `"signal"` and emits `worker.stopped` with it (`:113-116`).

The other citations verify: `exit_for_view` folds everything except `:completed`
into `1` (`cli_rendering.rb:124-130`), `cancel_exit` requires
`terminal_reason == 'cancelled_by_user'` (`cli_session_commands.rb:235-237`),
`RunResult(status: :cancelled)` exists (`executor.rb:547-554`), and the token
exposes `reason` while writing nothing (`cancellation_token.rb:80-82`).

### Reachability chain — where it breaks

The claimed chain is: SIGINT → `Worker#run` stops with `"signal"` →
`WorkerRuntime#terminal_reason` returns the `"failed"` fallback → the request is
durably stored as `failed`. **Step 2 does not exist and step 3 does not happen.**

1. Signal → `token.cancel!` → `Worker#run` breaks with reason `"signal"`
   (`worker.rb:92-105`). Correct.
2. **There is no `terminal_reason` call on this path.** `failure_reason` is only
   invoked from `settle_stale_request`, which requires a request that is already
   durably `:failed`.
3. A cancel that fires *inside* a run does not produce a `:failed` settle either:
   `Executor#run` rescues `CancelledError`/`TimeoutError` and returns
   `cancelled(current)` (`executor.rb:166-167,547-554`), and `cancelled` builds a
   `RunResult` from the **unchanged in-memory checkpoint** — it calls **no**
   `append_checkpoint`, **no** request transition. Compare the genuine failure
   path (`:394-408,530-535`), which *does* commit a `failed` checkpoint and a
   request transition. So cancellation commits nothing.
4. The durable layer could not store `"cancelled"` even if it wanted to:
   `CheckpointCodec::STATUSES = %w[running paused failed completed]`
   (`checkpoint_codec.rb:22`) and
   `RequestTransitionPlan::ACTIONS = %w[running completed failed]`
   (`request_transition_plan.rb:18`). There is no `cancelled` status or action in
   the durable vocabulary.

### Guards searched

`grep -rn "cancelled" gems/tamoz-graph/lib/tamoz/graph/` finds `:cancelled` only
as an in-memory `RunResult` status (`executor.rb:549`) and as a predicate
(`run_result.rb:9`). No commit path consumes it. `durably_fail_request` is called
only from `handle_thread_failure` (`worker.rb:355`) — i.e. from a *raised
exception*, not from a cancellation — and it writes the exception's class and
message as the reason. `RequestTransitionPlan` has no cancellation action, so
there is no path by which a token cancel reaches a `failed` request row.

### Probe

Paths `/tmp/tamoz-challenge/probe_f02.rb`, `probe_f02b.rb`, `probe_f02c.rb`.

```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
cd /Users/ghassan/my-projects/tamoz && timeout 150 ruby -Ilib -Itest /tmp/tamoz-challenge/probe_f02c.rb
```

Output (cancelled **mid-run**, so the executor's `rescue CancelledError` fires —
the most favourable possible setup for the claim):

```
CheckpointCodec::STATUSES = ["running", "paused", "failed", "completed"]
MIDRUN deliver_error=NilClass:nil
MIDRUN run_result_status=:running
MIDRUN requests=[{"request_id"=>"request.mid", "status"=>"running", "terminal_error"=>nil}]
MIDRUN checkpoints=[{"status"=>"running"}]
```

And with the token pre-cancelled before dispatch
(`probe_f02b.rb`), including a genuine-failure control on the same DB:

```
TOKEN_CANCELLED run_result_status=:running
TOKEN_CANCELLED requests=[{"request_id"=>"request.cancel", "status"=>"running", "terminal_error"=>nil}]
TOKEN_CANCELLED checkpoints=[{"status"=>"running", "execution_id"=>"9b2d9192-..."}]
CONTROL_FAILED   requests=[..., {"request_id"=>"request.fail", "status"=>"failed", "terminal_error"=>"[\"tamoz.state\",1,...]"}]
CONTROL_FAILED   checkpoints=[..., {"status"=>"failed", "execution_id"=>"25dddc56-..."}]
```

**The claimed defect does not reproduce.** The token-cancelled run is stored as
`status = "running"` with `terminal_error = nil` — **not** `"failed"`. The
control proves the harness would have shown `failed` had the claim been true:
a genuine node failure on the same database durably writes
`request.status = "failed"` and a `failed` checkpoint.

What is true instead: a token-driven cancellation is **not durably recorded as
terminal at all**. It leaves the request in `running` and the checkpoint in
`running`, indistinguishable from a live in-flight turn, and it is not
recoverable as cancelled because neither `cancelled` nor any cancellation action
exists in `CheckpointCodec::STATUSES` or `RequestTransitionPlan::ACTIONS`. That
is arguably a *worse* observability defect than the one reported — a supervisor
cannot distinguish "cancelled" from "still working and then crashed" — but it is
**not the finding that was written**, it is at a different seam
(`Executor#cancelled` + `CheckpointCodec`/`RequestTransitionPlan`, not
`WorkerRuntime#terminal_reason`), and the report's recommendation (map
`terminal_reason` to `"cancelled"`) would not fix it.

### Verdict + reason

**REFUTED as stated.** The specific observable claim — a token-driven
cancellation is durably recorded as `"failed"` rather than `"cancelled"` — is
disproved by direct reproduction against a real temp SQLite DB with a working
control: the stored status is `"running"`, and `terminal_error` is `nil`. The
cited seam does not exist under the name given (`terminal_reason`), and the cited
lines are the body of `failure_reason`, a staleness-verdict projection on an
already-failed request.

Per BAR.md, `closed` means the current audit **disproved** the lead — so on its
stated terms F02-OBS-01 is `closed`, not `major/open`. I am deliberately **not**
closing the underlying observation, because my probe found a real and related
gap that deserves its own entry rather than being carried by this one's wrong
mechanism. Recommended replacement (severity `major`, confidence **high** now
that it is measured, owning seam `Executor#cancelled` +
`CheckpointCodec::STATUSES` + `RequestTransitionPlan::ACTIONS`): *a token-driven
cancellation commits no durable terminal fact; the request and checkpoint remain
`running` and there is no durable vocabulary in which "cancelled" could be
recorded.* The report's own `medium` confidence and its blind-spot note ("no
durable run was executed … inferred from worker.rb:1180-1183 and not observed")
were honest, and the missing observation is exactly what overturned the
mechanism. Record it as a new finding, not as a repair of this one.

## Reconciliation with CF04-REL-01

**Genuinely distinct defects — index them as two entries, and neither subsumes
the other.**

- **Different seam.** CF04-REL-01 lives in `tamoz-agent-kernel`
  `EffectDispatcher#resolve_decision`/`terminal_attempt`
  (`effect_dispatcher.rb:97-101,280-283`) — the *effect-journal replay* seam.
  F02-OBS-01 lives in `tamoz-agent` worker/CLI reporting
  (`worker.rb:889,1179`; `cli_rendering.rb:124-130`) over the *request/checkpoint
  terminal fact* seam. Different gems, different owners, different data.
- **Different data object.** CF04-REL-01 is about a **durable effect record**
  (`tamoz_effects` + `tamoz_effect_attempts`) picking the wrong attempt's error.
  F02-OBS-01 is about a **durable request/checkpoint** (`tamoz_requests`,
  `tamoz_checkpoints`) never receiving a terminal status. An effect replay and a
  turn cancellation are different lifecycles, and my `probe_cf04.rb` /
  `probe_f02c.rb` touch disjoint tables.
- **Different root cause.** CF04-REL-01: one selector helper serves two
  incompatible outcome types (succeeded-first scan used for a failed head).
  F02-OBS-01: two cancellation models — durable `request_cancellation` and the
  in-memory token — were never joined at the terminal-fact seam, so a token
  cancel produces *no* terminal fact. The report's own "two cancellation models"
  whys chain is right; its stated *symptom* is what failed.
- **No shared fix.** Repairing `terminal_attempt` (CF04's recommendation) changes
  nothing about cancellation. Adding a `cancelled` status to the checkpoint/request
  vocabulary (F02's real fix) changes nothing about effect replay selection.

Where they genuinely touch: both surface in `Worker#run`/`settle_view`
(`worker.rb:678-681` dispatches on view status), and both are "a durable
terminal fact that does not say what actually happened." That is a thematic
overlap, not a shared root cause. **Index as two findings** — but rewrite
F02-OBS-01's mechanism and seam before indexing, since the current text points at
a method that does not exist and a symptom that does not reproduce.

## Net effect on FINDINGS.md

- **F07-SEC-01** — **keep** as `critical`, high, open, confirmed. Citations exact,
  defect reproduced including the `prepare → :return` false-completion
  consequence, and the reachability argument is *stronger* than reported (the
  shared adapter is the worker's normal configuration).
- **CF04-REL-01** — **keep** as `major`, high, open, confirmed. Reproduced
  byte-for-byte with the report's own probe output; a clean control isolates the
  cause to the mixed late-success/current-failure history.
- **F02-OBS-01** — **close as written** (the claimed `"failed"` record is
  disproved) and **replace** with a new major finding: token cancellation commits
  no durable terminal fact (request and checkpoint stay `running`), at seam
  `Executor#cancelled` + `CheckpointCodec::STATUSES` +
  `RequestTransitionPlan::ACTIONS`. Do not carry the `worker.rb:1180-1183`
  `terminal_reason` citation forward — no such method exists.

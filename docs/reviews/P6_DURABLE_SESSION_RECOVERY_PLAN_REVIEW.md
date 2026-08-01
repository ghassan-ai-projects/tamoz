# Review — P6 durable session and effect recovery plan

Subject: `docs/P6_DURABLE_SESSION_RECOVERY_PLAN.md`
Reviewer stance: adversarial. The plan is treated as a claim to be falsified against the
code in the tree at `15f816f`, not as a proposal to be improved.
Verdict: **accept after the eight required corrections below**. Two are critical: as
written, one section is factually false and another makes the phase's central proof
impossible to run.

## Method

Every file:line reference in the plan was opened and checked. Every API the plan says it
will "reuse unchanged" was read. Claims that could be settled by running code were
settled by running code rather than by reading prose.

## Findings

### C-1 (critical, factual error) — the ephemeral-session claim is false

**Plan §12** states the session graph "compiles against `Tamoz::Graph::MemoryCheckpointer`
for non-durable use".

Falsified three ways:

1. `MemoryCheckpointer#durable? = false` (`memory_checkpointer.rb:37`), and
   `DurableRunner#initialize` (`durable_runner.rb:13–19`) raises `ConfigurationError`
   unless the checkpointer is durable *and* exposes
   `request_protocol_version == 1`. There is no durable turn without a durable backend.
2. Every effect-bearing node needs `context.effects`. `Compiled#bind_writer_context`
   (`compiled.rb:956–972`) returns the context unchanged unless the writer responds to
   `#effects`; only `CheckpointStore::Writer` does (`checkpoint_store.rb:894`). On a memory
   backend `context.effects` is `nil` and `deliberate` raises on its first model call.
3. PERSISTENCE_DESIGN §9 says outright that the in-memory adapter "cannot be used to claim
   crash durability or effect safety".

The handover requirement "read-only and ephemeral construction remain available where
documented" is satisfied by `Tamoz::Agent::Runtime`, which P6 leaves unchanged — not by an
ephemeral `Session`.

**Required correction.** Rewrite §12 to say: ephemeral/read-only work remains available
through the unchanged `Runtime`; `Session` requires a durable checkpointer and says so in
its constructor by raising `ConfigurationError` otherwise. Delete the MemoryCheckpointer
claim.

### C-2 (critical, makes the phase proof unrunnable) — the effect attempt TTL is hardcoded at 60 seconds

`EffectJournal#initialize` defaults `attempt_ttl: 60.0` (`effect_journal.rb:21`), and the
only construction site passes no TTL at all:

```ruby
@effects = EffectJournal.new(store:, guard:)   # checkpoint_store.rb:894
```

Every recovery path the plan depends on is gated on the previous attempt's deadline having
passed (`effect_journal.rb:181–183`: `action = :wait` while `attempt.deadline_ms > now`).
That means:

- K6 (kill after prepare), K7 (kill after start), K8 (kill after publication), K9 (unsafe
  check) and the whole of §6.3 cannot be exercised without waiting 60 s **per row**;
- fourteen rows would add roughly fourteen minutes of pure sleeping to `rake ci`, which is
  not acceptable and would in practice mean the rows silently get written to assert
  `:wait` instead of the reconcile path — i.e. the phase's central proof would be faked.

The plan's §5 "exact API surface added" does not mention this at all, which is the deeper
problem: the plan asserted a proof it had not checked it could run.

**Required correction.** Add `effect_attempt_ttl` to `Tamoz::SQLite::Limits` (default
`60.0`, same validated range as the journal's `0.1..3600.0`) and pass
`attempt_ttl: store.adapter.limits.effect_attempt_ttl` at `checkpoint_store.rb:894`. Add
it to §5 and §9 (no schema change; `Limits` is only ever constructed with keywords —
verified across `test/sqlite_*.rb` — so the addition is source-compatible). State in §10
that the kill matrix sets it to a small value and that the *default* stays 60 s.

### H-1 (high) — `call_index` must be a pure function, and the plan's formula hides that

**Plan §6.1** gives `deliberate` `call_index = attempt * 2` for the plan call and
`attempt * 2 + 1` for the semantic review.

That formula is correct, but the plan presents it as an arithmetic convenience rather than
as the safety rule it actually is. `Runtime#accepted_plan` (`runtime.rb:220–277`) does not
make two calls per attempt: on a structural-review failure it `next`s without ever calling
the semantic reviewer (`runtime.rb:249–252`), and on a `ProtocolError` it `next`s from the
rescue (`runtime.rb:266–276`). A running counter would therefore assign *different*
`call_index` values to the same logical call across a re-entry whose earlier attempts took
a different branch — and the effect key includes `call_index` (`effect_journal.rb:39–57`),
so the resumed node would miss the recorded receipt and re-call the provider.

**Required correction.** State the rule explicitly in §6.1: *`call_index` is a pure
function of `(stage, attempt)` and must never be derived from a running counter or from
the number of calls actually made.* Add a unit test that drives `deliberate` through a
structural rejection followed by an acceptance and asserts the accepted attempt's plan call
still lands on `call_index == attempt * 2`.

### H-2 (high) — the intent must be computed once, not recomputed after approval

**Plan §6.2** has `step_gate` compute the `effect_intent`; **plan §3** has `step_gate` also
raise the approval interrupt. Invariant 4 / GRAPH_DESIGN §7 say the node restarts *from its
first line* on resume. So on the approval resume, `step_gate` recomputes the intent by
re-reading the workspace.

If the file changed in between, the recomputed `after_digest` no longer matches the bytes
the operator saw in the preview. The existing guards mean this cannot produce a *wrong
write* — `apply_patch` fails its `expected_sha256` check (`toolbox.rb:380–382`) and
`create_file` fails `EEXIST` (`toolbox.rb:467–468`) — but it can produce a step that
executes against an intent the operator never approved, and it silently breaks the
plan's own claim that "preview, intent, and execution describe one set of bytes".

**Required correction.** §6.2 must state: the intent and the preview digest are computed
in the same pass and committed **with** the approval record at the same barrier;
`step_execute` binds to the *committed* intent; and if `step_execute`'s own preflight
disagrees with the committed `before_state`, the step fails closed with a typed error
rather than executing. Add this to the §8 failure table.

### H-3 (high, verified — no change needed, but the plan must show its work)

**Plan §2 row 15** claims terminal request completion is already atomic with the terminal
checkpoint. Verified true: `Executor#run` (`executor.rb:139–153`) passes
`terminal_request_transition(action: :completed, graph_status: :completed)` into the same
`append_checkpoint` when the frontier empties, and `CheckpointStore` applies it inside the
commit transaction (`checkpoint_store.rb:1215` `apply_request_transition_in_transaction!`).

But the same code path (`executor.rb:88–103`) marks a **paused** run's request terminal
too, with `graph_status: :paused`. That is a real and load-bearing fact the plan never
mentions: an approval interrupt *ends the request*, and resuming is a **new** request with
`operation: :resume` (`compiled.rb:681–693`). The plan's §5 signature
`session.resume(answers, thread:, request_id:)` is only correct if `request_id` is a
*fresh* id, not the original turn's.

**Required correction.** Document the request lifecycle in §2/§5: one turn request per
non-interrupted stretch of execution; each approval resume is its own request id;
`Session#resume` submits `operation: :resume`. Add an assertion to the §10 integration
test that a paused turn's original request is terminal and the resume request is distinct.

### H-4 (high) — the `:idempotent` model-call default is the plan's single automatic-repeat path and must be proved from both sides

**Plan §7** defaults `model_call_safety: :idempotent`. The architectural argument (one
generation at a time, tools never executed by the provider, inputs limited to
stage/system/prompt) is sound and is the same limitation AGENT_DESIGN §4 already
documents. It is nonetheless the *only* place in P6 where an ambiguous outcome leads to
automatic re-execution, and the handover plan lists "retrying unknown work" as an automatic
failure. The plan's defence is therefore only acceptable if it is proved, not asserted.

**Required correction.** §10 K4 must assert three things, not one: (a) exactly one extra
provider call; (b) `provider_ambiguity == 1` surfaced in `SessionOutcome`; (c) the *same*
child run with `model_call_safety: :unsafe` pauses with a `blocked` record and makes **zero**
extra provider calls. Without (c) the opt-out is undemonstrated and the default is a claim.

### M-1 (medium) — append reducers and re-entry

**Plan §4** uses `:append` for `plan_versions`, `plan_reviews`, `observations`,
`effect_intents`, and `effect_receipts`, and asserts idempotency "by id". `Reducers.append`
concatenates; it does not dedupe by id.

Analysis: duplicates cannot in fact arise from a crash, because a node's writes are only
visible after its own barrier — a crash before the barrier commits nothing, and a crash
after it means the node is not re-entered (invariant 4 / `executor.rb:35`
`pending`-filtering). But the plan states a property it does not implement, and a future
node that writes the same channel twice in one execution would silently duplicate.

**Required correction.** Replace the "idempotent by id" claim in §4 with the actual
argument (barrier visibility), and add the defensive rule that every node filters out
records already present in its frozen input snapshot before appending. Add a test that
re-enters `deliberate` after a `before_commit` kill and asserts exactly one `plan` record
per `plan_id`.

### M-2 (medium) — observation budget is not carried into the durable path

`Runtime#execute` enforces `MAX_OBSERVATION_BYTES` (`runtime.rb:349–427`,
`runtime.rb:13`). The plan's `step_execute` has no equivalent, yet `SessionOutcome#state`
and every checkpoint would carry the accumulated observations. Unbounded observations mean
unbounded checkpoint payloads, which `StateCodec` will eventually reject with
`StateLimitError` *after* the effect has already run — a bad place to fail.

**Required correction.** §6/§8 must state that `step_gate` enforces the same
pre-execution budget check `Runtime` does (`runtime.rb:366–369`) and `step_execute`
enforces the same post-execution ceiling, using the identical constant.

### M-3 (medium) — the "exactly once" marker must be harness-side

**Plan §10** says a "per-application append-only marker file proves the mutation ran
exactly once". If that marker were written by `Toolbox`, P6 would be shipping test
scaffolding in product code.

**Required correction.** State that the marker is appended by a **child-local** prepend on
`File.link` / `File.rename` inside the test child script — the same technique the plan
already uses to trigger K8's kill — and that no product code writes it. Note that the
primary evidence is still the target file's digest plus the journal's attempt history; the
marker is corroboration.

### L-1 (low) — K9 orphans a process group

`Toolbox#run_check` spawns the check in its own process group and tears it down with
`terminate_group` (`toolbox.rb:694`). SIGKILLing the parent at K9 skips that teardown and
orphans the check's group.

**Required correction.** K9 must reap or bound the orphaned group explicitly so `rake ci`
does not leak processes across runs.

## Things the plan gets right and should not be "improved"

- **Reusing the existing journal rather than adding a second effect model.** The seam table
  correctly identifies that `prepare`/`start`/`complete`/`resolve` already cover four of
  the five reconciliation outcomes, and that the gap is exactly one transition. Resisting
  the temptation to write a new "agent effect store" is the single most important decision
  in the plan.
- **One `deliberate` node rather than three.** The argument in §3 is correct and stronger
  than invariant 25's minimum: because every model call is journalled, resume reproduces
  the same accepted plan even when the crash preceded any plan checkpoint. Splitting the
  node would have added barriers without adding a guarantee.
- **Declaring filesystem effects `:reconcilable` rather than `:idempotent`.** §6.2's
  reasoning — `apply_patch` fails its before-digest guard once applied, `create_file` fails
  `EEXIST` — is exactly right, and the tempting wrong move (call them idempotent because
  "the end state converges") would have taught the repair loop to fix already-correct
  files.
- **Refusing to edit `docs/design-v0.1/PERSISTENCE_DESIGN.md`.** That package is pinned by
  `SOURCE` and by `test/documentation_test.rb:23–33` (55 invariants, 40 ADRs). Recording
  the extension in the plan and deferring the ADR to v0.2 is the correct handling.

## Assessment of the §6.4 design conflict and five-whys

The conflict is real and correctly identified: `PERSISTENCE_DESIGN.md` §4 gives
`:reconcilable` a two-valued outcome, `EffectJournal#prepare` (`effect_journal.rb:218–229`)
implements exactly that, and no transition exists from head `reconcile` back to `prepared`.
`PROJECT_HANDOVER_PLAN.md` §6 P6-C requires execution from a proven-before state.

The five-whys reaches the right root cause: the two-valued outcome assumed the *caller*
would schedule a new logical activation, which for a filesystem write means burning a
bounded repair attempt and recording a step failure that did not happen.

The resolution is accepted, with one sharpening the plan should adopt:

> The retry authorised by `:not_applied` is authorised by **observed evidence of the
> pre-state**, recorded as a durable journal transition — not by a safety class and not by
> an approval. Approval never makes an operation retryable (AGENT_DESIGN §5); evidence
> does.

The `MAX_RECONCILE_GRANTS = 2` bound, the head-status precondition, and the in-transaction
lease validation together make it impossible for `:not_applied` to become a retry loop.
This is a strengthening of invariant 21, not a relaxation: no *ambiguous* effect is retried
at any point.

Residual risk accepted and to be stated in the implementation review: a SHA-256 collision
between a file's before- and after-content would misclassify a reconciliation. This is
outside the declared fault model (INVARIANTS "Fault model") and is not mitigated.

## Required corrections summary

| ID | Severity | Correction | Applied |
|---|---|---|---|
| C-1 | critical | delete the MemoryCheckpointer claim; `Session` requires a durable checkpointer and raises otherwise | yes |
| C-2 | critical | add `Limits#effect_attempt_ttl` and thread it into `Writer`; document that the kill matrix lowers it | yes |
| H-1 | high | state that `call_index` is a pure function of `(stage, attempt)`; add the skipped-review test | yes |
| H-2 | high | compute intent + preview once, commit with the approval, fail closed on disagreement at execute time | yes |
| H-3 | high | document the request lifecycle: an interrupt terminates the request; resume is a new `:resume` request | yes |
| H-4 | high | K4 must also prove the `:unsafe` opt-out pauses with zero extra provider calls | yes |
| M-1 | medium | replace "idempotent by id" with the barrier-visibility argument; filter against the input snapshot | yes |
| M-2 | medium | carry `MAX_OBSERVATION_BYTES` into `step_gate`/`step_execute` | yes |
| M-3 | medium | the exactly-once marker is harness-side only | yes |
| L-1 | low | reap K9's orphaned process group | yes |

All ten corrections were applied to
`docs/P6_DURABLE_SESSION_RECOVERY_PLAN.md` before this review was committed; the plan and
this review are committed together as the P6 design checkpoint, and no implementation
commit precedes them.

## Stop conditions the reviewer will re-check at implementation review

1. `Tamoz::Agent::Runtime` is byte-for-byte behaviour-identical; the scorecard stays at
   `decision: pass`, 8/12, hard-zero counters, corpus digest `sha256:d24bb33f…`, content
   digest `sha256:3851d176…`.
2. No new SQLite table, column, or index; `Migrator` untouched.
3. Every kill-matrix row uses a real `Process.kill("KILL", …)`. Any row that substitutes an
   exception, a `raise`, or a stubbed failure fails the phase.
4. No `:unknown` effect is ever retried, and the only automatic repeat in the system is the
   declared, counted, opt-out-able provider call.
5. `EffectJournal#reconcile` is compare-and-set, fenced for `:not_applied`, precondition-
   checked on head status, and appends a transition for every disposition.

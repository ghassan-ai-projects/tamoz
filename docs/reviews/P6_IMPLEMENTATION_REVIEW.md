# Review — P6 durable session and effect recovery implementation

Subject: commits `2d94908` (P6-A/B) and the P6-C/D2/E implementation commit.
Reviewer stance: adversarial. Claims were checked by reading the code and running it,
not by reading the plan.

## 1. What was built

| Package | Change |
|---|---|
| `docs/P6_DURABLE_SESSION_RECOVERY_PLAN.md` + review | design checkpoint `8c977dc` |
| `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb` | pure planning/review/verification logic shared by `Runtime` and `Session` |
| `gems/tamoz-agent/lib/tamoz/agent/session_records.rb` | versioned allowlisted records, version gate, sensitive rejection, migration registry |
| `gems/tamoz-agent/lib/tamoz/agent/effect_dispatcher.rb` | the single crossing point to the effect journal, plus the filesystem reconciler |
| `gems/tamoz-agent/lib/tamoz/agent/session_nodes.rb` | seven graph nodes |
| `gems/tamoz-agent/lib/tamoz/agent/session.rb` | graph definition and durable driver |
| `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb` | `check_safety`, `check_safeties:`, `catalog_digest`, `effect_intent` |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal.rb` | `#reconcile` — the three-valued `:reconcilable` outcome |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/limits.rb` + `checkpoint_store.rb` | `effect_attempt_ttl` |
| `gems/tamoz-graph/lib/tamoz/graph/compiled.rb` | recovery of a crashed `:resume` request (§3) |

## 2. Automatic-failure conditions — checked one by one

| Condition | Verdict | Evidence |
|---|---|---|
| a second checkpoint or effect model | **not violated** | no new table, column, or index; `Migrator` untouched; the only journal change is one transition on the existing `tamoz_effects`/`tamoz_effect_attempts` rows |
| bypassing graph barriers | **not violated** | every durable transition is a node return committed by `Executor#run`; no node writes state outside its return value; no direct `append_checkpoint` from agent code |
| private RubyLLM APIs | **not violated** | the provider seam is still `model.generate(stage:, system:, prompt:)`; `tamoz-agent` loads no RubyLLM at require time (`dependency_isolation_test.rb`) |
| retrying unknown work | **not violated for effects**; one declared, counted, opt-out-able exception for provider text generation (§5) | `:unsafe` and `:unknown` never produce an `:execute` decision; `EffectDispatcher.run` returns `:unknown` and the session pauses |
| simulating a crash | **not violated** | every kill in `test/agent_session_kill_matrix_test.rb` is `Process.kill("KILL", ...)` against a real `Process.spawn`ed child; the parent asserts `status.signaled? && status.termsig == 9` before accepting a row |

## 3. Design conflict found during implementation, and its correction

**Conflict.** A `kill -9` during a `:resume` request could not be recovered.
`Compiled#execute_durable_request` handled `:turn` correctly — `claimed` starts, `running`
continues — but sent every `:resume` to `resume_with_writer`, which raises
`CheckpointConflictError, "latest checkpoint is not paused"` once the resumed execution
has committed a barrier. Since P6 puts the approval interrupt in the middle of the
lifecycle, *every* effect seam (K6–K10) lives inside a `:resume` request, so the phase's
central proof was unreachable.

**Five whys.**

1. *Why did recovery fail?* `resume_with_writer` demands a paused checkpoint.
2. *Why was that safe before?* Prior tests only crashed inside `:turn` requests
   (`sqlite_crash_recovery_test.rb`), which already had the two-state branch.
3. *Why does `:resume` need the same branch?* Because
   `CheckpointStore#recover_request` deliberately preserves the request's status
   (`claimed` or `running`), exactly as PERSISTENCE_DESIGN §5 requires — recovery is an
   explicit transition, not a silent new execution.
4. *Why is continuing correct rather than replaying the resume?*
   `Executor#run` threads `resume_values` into every appended checkpoint, so once the
   resumed run commits one barrier the answers are already durable state;
   `continue_with_writer` reads them from `checkpoint.resume_values`. Replaying would
   re-merge them and `merge_resume_values` would raise "resume answer already exists".
5. *Why not always continue?* A resume killed *before* its first barrier leaves the
   checkpoint still `paused` with unmerged answers. Continuing would lose the operator's
   approval.

**Correction.** `:resume` now branches on the observed checkpoint status:
`running` request + `running` checkpoint ⇒ continue; otherwise ⇒ resume. Both windows
are covered by the kill matrix (K6/K7 land in the first, K5b in the second).

**Known analogous gap, deliberately not fixed.** `:retry` has the same shape and the same
latent failure. It is not exercised by P6, and shipping an unproven symmetric fix is worse
than recording it. It is listed in §7 residual risk and belongs to P7.

## 4. Invariant-by-invariant check

| Invariant | Status | Evidence |
|---|---|---|
| 9 — backend sequence, never opaque ids for order | pass | ordering comes from `Checkpoint#sequence` and `RequestRecord#enqueue_sequence`; `grep` finds no sort by `checkpoint.id`, `plan_id`, or a timestamp. `agent_session_test.rb` asserts the resume request's `enqueue_sequence` is strictly greater |
| 18 — versioned allowlisted records; newer versions fail before partial load | pass | `SessionRecords.load!` orders its rejections version-first; `agent_session_records_test.rb` feeds a record that is *both* a future version and structurally invalid and asserts only the version error surfaces. `agent_session_test.rb` writes a validly digested checkpoint containing a v2 record and asserts `continue` raises `CheckpointVersionError` with **zero** additional model calls |
| 19/20 — atomic compare-and-append under one fenced writer; stale fence rejected | pass | unchanged machinery; `agent_session_effect_test.rb` proves a stale journal cannot grant a further attempt (`LeaseLostError`) while a `:completed` reconciliation still records after lease loss |
| 21 — replay-safe effects or explicit ambiguity | pass | filesystem effects are `:reconcilable` with a three-valued reconciler; configured checks default to `:unsafe`; an ambiguous check becomes `:unknown` and the session pauses. `test_a_kill_during_a_check_...` asserts `check:ran` appears exactly once across both processes |
| 24 — sensitive values rejected | pass | `SessionRecords.reject_sensitive!` at every depth, before `StateCodec`'s own guard |
| 25 — reviewed plan gates action | pass | `step_gate`/`step_execute` are only reachable from `deliberate`'s accept branch; a rejected plan raises `PlanRejectedError` before any effect is prepared |
| 26 — material change requires re-review | pass | each `deliberate` activation writes a new `plan_id`/`plan_digest`; the repair loop re-enters `deliberate` and re-reviews |
| 27 — completion needs evidence | pass | `verify` keeps `Runtime`'s rule: with configured checks, no passing check forces `satisfied: false` with a framework evidence line |
| 52 — activation identity survives interruption/retry/takeover | pass | the effect key derives from `context.task_id`, which `Executor#execute_task` sets to the stable activation id; every kill-matrix row asserts exactly one execution id in history |
| 55 — discovery is reviewed, read-only, cannot authorize action | pass | `deliberate` with `phase: "discovery"` passes `toolbox.read_only_names` as `allowed_tools`; a mutation tool in a discovery plan is a structural issue |

## 5. The one automatic repeat in the system

`model_call_safety` defaults to `:idempotent`. This is the only place P6 re-executes work
after an ambiguous outcome. Three things make it defensible rather than a violation:

1. **It is provable in this architecture, not assumed.** Tamoz drives one generation at a
   time, the provider never executes a tool, and the only inputs are `stage`, `system`,
   and `prompt`. A repeated generation has no external effect beyond a metered charge —
   the exact limitation `AGENT_DESIGN.md` §4 already documents.
2. **It is counted and surfaced.** `provider_ambiguity` is a durable channel exposed on
   `SessionOutcome` and `SessionView`.
   `test_the_idempotent_model_default_repeats_at_most_one_call_and_counts_it` asserts the
   run makes exactly **one** more provider call than a clean reference run and reports
   `provider_ambiguity == 1`.
3. **It is opt-out.** `test_an_unsafe_model_call_pauses_instead_of_repeating_the_provider_call`
   runs the identical seam with `model_call_safety: :unsafe` and asserts **zero** extra
   provider calls, a `blocked` record, and an unchanged workspace.

Any future stage whose generation can produce an external effect must be declared
`:unsafe`. That is a stated precondition, not an assumption.

## 6. Kill matrix — measured

All rows use a real `kill -9`. Recovery always runs in a **second** subprocess with a
different `owner_id`, so every row also exercises lease takeover after owner death.

| Seam | Trigger | Result |
|---|---|---|
| K1 before plan acceptance | `before_commit` / `checkpoint.commit` after `model:review:action` | pass |
| K2 after plan acceptance | `after_commit` / same | pass |
| K3 after model receipt commit | `after_commit` / `effect.complete` | pass |
| K4 after provider response, before receipt | `before_commit` / `effect.complete` | pass |
| K5a before approval checkpoint | `before_commit` / `checkpoint.commit`, skip 1 | pass |
| K5b after approval checkpoint | `after_commit` / same | pass |
| K6 after effect prepare | `after_commit` / `effect.prepare` after `resume:r1` | pass |
| K7 after effect start, before publication | `after_commit` / `effect.start` | pass |
| K8 after filesystem publication | SIGKILL inside a child-local `File.rename` prepend | pass |
| K9 during check execution | the check process SIGKILLs its parent | pass — session `blocked`, check never repeated |
| K10 after check receipt commit | `after_commit` / `effect.complete` after `check:ran` | pass |
| K11 before verification checkpoint | `before_commit` / `checkpoint.commit` after `model:verify:verify` | pass |
| K12 before terminal commit | same, skip 1 | pass |
| K13 after terminal commit | `after_commit` / same, skip 1 | pass |
| create_file, killed after `File.link` | child-local prepend | pass — reconciled `completed`, published once |
| create_file, killed before `File.link` | child-local prepend | pass — reconciled `not_applied`, published once |

Every row additionally asserts: exactly one execution id in history; the target file's
final bytes; exactly one real publication counted across **both** processes; the resumed
`accepted_plan.plan_digest` equals the clean reference run's digest; two granted
approvals; one `tool.apply_patch` and one `tool.run_check` receipt;
`PRAGMA integrity_check` ok; and no unexpected public workspace entry.

## 7. Residual risk (honest list)

1. **Orphaned private temporary files.** A kill between publication (`rename`/`link`) and
   the temporary's `unlink` leaves a `.tamoz-*` dotfile containing the approved bytes.
   P5's plan already named this and deferred it to P6; P6 declines to reclaim it because
   doing so requires an unlink capability the agent deliberately does not have. No public
   partial file and no overwrite is still guaranteed and is asserted.
2. **`:retry` request recovery** has the same latent defect `:resume` had (§3). Unfixed,
   unproven, recorded.
3. **Digest collisions** would misclassify a reconciliation. Outside the declared fault
   model.
4. **`resolve_effect` is API-only.** No CLI surface exposes it; P7 owns that.
5. **The session graph has no streaming projection.** `Compiled#stream` is unused by the
   durable path; P7 owns it.
6. **Assertion-count variance** between identical CI runs persists (27,786 vs 27,771
   across locales). Pre-existing gate debt, unchanged by P6, still owed before P15.
7. **`SessionNodes` is a public top-level constant** but is not in the documented public
   API inventory; it is an implementation detail that a future refactor may move.
8. **No P6 scorecard case.** The agent-smoke corpus is a pinned P3 artifact and P6 adds no
   case to it; P6's behavioural proof is the kill matrix. This is a deliberate choice, and
   it means the durable session is *not* covered by the scorecard's safety counters.

## 8. Gate

| Check | Result |
|---|---|
| `rake ci`, `LC_ALL=en_US.UTF-8` | pass — 447 runs, 27,786 assertions, 0 failures/errors/skips |
| `rake ci`, `LC_ALL=C` | pass — 447 runs, 27,771 assertions, 0 failures/errors/skips |
| design validation | pass — 22 documents, 55 invariants, 40 ADRs |
| gem packaging | pass — all five gems |
| `tamoz-eval scorecard agent-smoke` | pass — 8/12, corpus `sha256:d24bb33f…`, content `sha256:3851d176…` |
| hard gates | 4/4 pass |
| hard-zero counters | unsafe/bypassed 0, false-positive completion 0, incomplete evidence 0 |

The scorecard's corpus digest, content digest, and task-success count are **byte-identical
to the pre-P6 baseline**, which is the required proof that extracting `Deliberation` did
not change `Runtime`.

## 9. Verdict

Accept. The phase's required product proof holds: a real repository repair survives
`kill -9` at every declared seam, resumes the same accepted exact plan digest, never
applies a filesystem effect twice, and pauses a truly unknown check for reconciliation.
Read-only and ephemeral construction remain available through the unchanged `Runtime`.

P6-F (operational durability) is **not** complete; see the phase tracker.

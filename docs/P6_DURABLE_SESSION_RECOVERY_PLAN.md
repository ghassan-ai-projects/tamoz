# P6 plan — durable session and effect recovery

Status: design — ready for review

## 1. Authoritative inputs, scope, and non-goals

Authoritative inputs, in source-of-truth order:

1. `docs/design-v0.1/INVARIANTS.md` clauses 9, 18–27, 52–55.
2. `docs/design-v0.1/PERSISTENCE_DESIGN.md` (§§1–6, 9) and `docs/design-v0.1/GRAPH_DESIGN.md`
   (§§3–9), then `docs/design-v0.1/AGENT_DESIGN.md` §§1–8 (§4 is the crash contract).
3. `docs/design-v0.1/DECISIONS.md` and accepted review corrections.
4. `docs/PROJECT_HANDOVER_PLAN.md` §6 "P6" and §7 cross-phase non-negotiables.
5. Existing implementation: `gems/tamoz-graph/lib/tamoz/graph/{durable_runner,checkpoint,
   checkpoint_codec,effect_record,request_record,state_manager,interrupt,snapshot}.rb`;
   `gems/tamoz-sqlite/lib/tamoz/sqlite/{checkpoint_store,effect_journal,lease,
   lease_operations,store,migrator,wire,transaction,database_kernel,fault_hook}.rb`;
   `gems/tamoz-agent/lib/tamoz/agent/{runtime,toolbox,plan,cli}.rb`.

### Outcome

The working agent lifecycle becomes a **durable graph turn** over the *existing*
`DurableRunner` / checkpoint / request-inbox / lease-fence / effect-journal / codec seams.
A killed process resumes the checkpointed exact plan, never applies a filesystem effect
twice, and stops on genuine ambiguity instead of guessing.

### Explicit non-goals for P6

- No second workflow engine, checkpoint model, or effect model. Every durable transition
  uses the existing `Tamoz::SQLite::CheckpointStore` and `Tamoz::SQLite::EffectJournal`.
- No private RubyLLM API. The provider seam stays `Tamoz::Agent::RubyLLMModel#generate`.
- No new CLI surface. P7 owns `--resume`, session listing, and interactive approval
  rendering. P6 ships the durable substrate and its proofs, and leaves
  `Tamoz::Agent::Runtime` (the in-process, ephemeral runtime the P3 scorecard measures)
  byte-for-byte behaviour-compatible.
- No compaction, subagents, memory, routing/fallback, or budget ledger.
- No new SQLite tables and no schema migration. P6 adds exactly one *transition* to the
  existing `tamoz_effects` / `tamoz_effect_attempts` state machine (§6.3) and nothing else.

### Relationship to `Runtime`

`Tamoz::Agent::Runtime` stays. Its deliberation logic (planning prompt, structural review,
semantic review, verification parsing, action signature) is moved verbatim into a shared
module `Tamoz::Agent::Deliberation`, included by `Runtime` and by the new durable session.
"Verbatim" is a hard requirement: the P3 scorecard corpus digest
`sha256:d24bb33f…`, content digest `sha256:3851d176…`, and 8/12 task successes are the
floor, and they are produced by `Runtime`. If the extraction changes any observable
`Runtime` behaviour, the extraction is wrong.

## 2. Seam-by-seam mapping

Each lifecycle stage below maps to a concrete existing API. "New" means P6 adds it; every
"new" row is a node or record inside the existing engine, never a parallel engine.

| # | Lifecycle stage | Carried by | Existing API (file:line) | Gap / minimal addition |
|---|---|---|---|---|
| 1 | Turn admission (one user task = one logical turn) | request inbox | `DurableRunner#submit` `durable_runner.rb:25`; `CheckpointStore#enqueue_request` `checkpoint_store.rb:219`; `claim_next_request` `:353` | none — `Session#start` calls `submit` + `run_next` |
| 2 | Single fenced writer | lease | `CheckpointStore#open_writer` `checkpoint_store.rb:603`; `acquire_lease` `lease_operations.rb:8`; `validate_lease_in_transaction!` `:164` | none |
| 3 | Session identity | checkpoint thread + first checkpoint | `Checkpoint#thread_id/execution_id` `checkpoint.rb`; `DurableRunner#run_next` `durable_runner.rb:51` | new `session` state channel holding a versioned `SessionRecord` (§4) |
| 4 | Discovery plan (invariant 55) | graph node + barrier | `Builder#node` `builder.rb:58`; barrier commit `checkpoint_store.rb:747` | new node `deliberate` with `phase = "discovery"`; new channels `plan_versions`, `plan_reviews`, `accepted_plan` |
| 5 | Plan review, both layers (invariant 25) | same node, same barrier | `Runtime#structural_issues` `runtime.rb:282`; `#semantic_review` `:322` | moved verbatim into `Deliberation`; results become versioned `ReviewRecord`s |
| 6 | Exact plan/review digests (invariants 25–27) | checkpoint state | `Tamoz::Graph::CheckpointCodec#dump` `checkpoint_codec.rb:57` | new `Deliberation.plan_digest` — SHA-256 over canonical JSON of the plan hash |
| 7 | Action plan (invariant 55 hand-off) | second `deliberate` activation | branch `builder.rb:100`; `RoutePlanner#next_frontier` `route_planner.rb:22` | new branch `evaluate → deliberate` with `phase = "action"` |
| 8 | Approval interrupt (invariant 25, AGENT_DESIGN §5) | worker-local throw + barrier persist | `Tamoz.interrupt` `interrupt.rb` (`Tamoz.interrupt`); `InterruptCursor#call` `interrupt.rb:30`; `Executor#execute_task` `executor.rb:205`; resume values `Compiled#merge_resume_values` `compiled.rb:897` | new node `step_gate`; new channel `approvals` holding versioned `ApprovalRecord`s |
| 9 | Tool execution — read-only | effect journal, safety `:read_only` | `EffectJournal#prepare` `effect_journal.rb:59`, `#start` `:265`, `#complete` `:334` | new node `step_execute` |
| 10 | Tool execution — filesystem mutation | effect journal, safety `:reconcilable` | same as row 9 | new `EffectIntent` record committed one barrier *before* dispatch (§6.2), plus the `reconcile` transition (§6.3) |
| 11 | Check execution (`run_check`) | effect journal, declared safety, default `:unsafe` | same as row 9; `Toolbox#run_check` `toolbox.rb:635` | new `Toolbox#check_safety` (§7) |
| 12 | Model/provider call | effect journal, declared safety | same as row 9; `RubyLLMModel#generate` | new `Session#model_call_safety` (§7); new `provider_ambiguity` counter channel |
| 13 | Repair loop | branch back to `deliberate` with `phase = "repair"` | `RoutePlanner#declared_routes` `route_planner.rb:53` | new channels `repair_attempt`, `seen_action_signatures`, `seen_failure_signatures` (durable equivalents of `Runtime`'s in-memory `seen_actions`/`seen_failures`, `runtime.rb:107–199`) |
| 14 | Verification (invariant 27) | node + barrier | `Runtime#verify` `runtime.rb:433` | moved verbatim into `Deliberation`; result becomes a versioned `VerificationRecord` |
| 15 | Terminal commit, atomic with request completion | one storage transaction | `CheckpointStore#append_checkpoint` `checkpoint_store.rb:747` with `request_transition` `:539` (already atomic — `apply_request_transition_in_transaction!` `:1215`) | none |
| 16 | Crash resume of an interrupted turn | request recovery | `DurableRunner#recover` `durable_runner.rb:85`; `CheckpointStore#recover_request` `checkpoint_store.rb:451` | none |
| 16b | Answering an approval | a **new** `:resume` request | `DurableRunner#submit(operation: :resume)` `durable_runner.rb:25`; `Compiled#execute_durable_request` `compiled.rb:681–693` | none — see the request-lifecycle note below |
| 17 | Duplicate delivery (invariant 23) | request inbox dedup | `enqueue_request` `checkpoint_store.rb:219` returns the existing record | none |
| 18 | Stale fence rejection (invariants 19/20) | every durable write | `validate_lease_in_transaction!` `lease_operations.rb:164`, called from `effect.prepare` `effect_journal.rb:91`, `effect.start` `:273`, checkpoint append | none |
| 19 | Backend-assigned strictly increasing sequence (invariant 9) | checkpoint sequence | `checkpoint_store.rb` `UNIQUE (thread_id, namespace, sequence)` + `materialize` `:1369` | none — P6 must never order by an opaque id |
| 20 | Late receipt after lease loss (invariant 21) | `complete` deliberately does not validate the lease | `EffectJournal#complete` `effect_journal.rb:334` (no `validate_lease_in_transaction!` — by design, PERSISTENCE_DESIGN §4) | none |
| 21 | Versioned allowlisted records (invariant 18) | state codec + record schema | `Tamoz::StateCodec#dump/#load` `state_codec.rb:103/:118` | new `Tamoz::Agent::SessionRecords` allowlist + `record_version` gate (§4) |
| 22 | Sensitive-value rejection (invariant 24) | codec | `state_codec.rb:144` raises `SensitiveValueError` on `Tamoz::Secret` | new belt-and-braces `SessionRecords.reject_sensitive!` so the record layer fails before the codec |
| 23 | Effect-unknown pause (invariant 21, AGENT_DESIGN §4) | journal status + interrupt | `EffectJournal#prepare` `:230–251` (`unsafe` → `:unknown`); `#resolve` `:481` | new `blocked` channel + `Session#resolve_effect` |
| 24 | Graph compatibility before resume (invariant 22) | checkpoint graph identity | `Compiled#compatible!` `compiled.rb:889` | none — the session graph declares `name: "tamoz.agent.session"`, `version: "1"` and every node an explicit `implementation_name`/`version` |
| 25 | Stable activation / attempt identity (invariants 3, 52) | planner | `Task` `task.rb`; `Executor#execute_task` `executor.rb:197` binds `task_id: task.id` into `Context` | none — the effect key derives from `context.task_id` |

### Request lifecycle (load-bearing, easy to get wrong)

`Executor#run` marks a **paused** run's request terminal as well as a completed one
(`executor.rb:88–103` passes `action: :completed, graph_status: :paused`; `:139–153` does
the same with `graph_status: :completed`). Both go through the one commit transaction
(`checkpoint_store.rb:1215`). Consequences P6 must respect:

- one turn request covers one *uninterrupted stretch* of execution, not the whole session;
- answering an approval is a **new** request with `operation: :resume` and a **fresh**
  `request_id`, never the original turn's id;
- `Session#resume(answers, thread:, request_id:)` therefore requires the caller to supply
  a new stable id, and reusing an id with a different payload is a conflict
  (`checkpoint_store.rb:219` `enqueue_request`);
- `Session#recover(thread:, request_id:)` targets a request that is still `claimed` or
  `running` — i.e. a crash, not a pause.

The §10 integration test asserts that a paused turn's original request is terminal and the
resume request is a distinct record.

### Seams that do not exist and are deliberately not added

- **Per-step barrier inside a single tool call.** A tool call is atomic at the tool
  boundary; P6 does not split `apply_patch` internals across checkpoints. Crash equivalence
  is at committed barriers (INVARIANTS "Fault model"), and the intra-tool gap is exactly
  what the effect journal + reconciler covers.
- **Streaming projection of the durable turn.** `Compiled#stream` exists
  (`compiled.rb:89`) but the durable request path is `DurableRunner`; wiring streamed
  `StreamPart`s to the durable turn is P7.
- **A `Context#effects.run` convenience wrapper.** `GRAPH_DESIGN.md` §8 shows one
  illustratively. It does not exist, and P6 does not add it: the reconciliation policy is
  agent-specific (before/after digests), so it lives in `Tamoz::Agent::EffectDispatcher`
  and calls the journal's existing `prepare`/`start`/`complete` directly.

## 3. Durable graph

```text
START → intake → deliberate ─┬─ accepted ──→ step_gate ──→ step_execute ──→ evaluate ─┐
                             │                   ▲                                     │
                             └─ rejected ──┐     └─────────── next step ───────────────┤
                                           │                                           │
                                           │     ┌── repair / action phase ────────────┤
                                           │     ▼                                     │
                                           │  deliberate                               │
                                           │                                           │
                                           └──→ terminal ←── verify ←── done ──────────┘
```

Nodes (all with explicit `implementation_name` and `version: "1"`, required for durable
compilation, `GRAPH_DESIGN.md` §1):

| Node | Purpose | Model calls | Effects | Interrupts |
|---|---|---|---|---|
| `intake` | normalise task, write `SessionRecord`, set `phase = "discovery"` | no | no | no |
| `deliberate` | plan + structural review + semantic review loop for the current phase; commit `PlanRecord`, `ReviewRecord`s, `accepted_plan` | yes (journalled) | model only | no |
| `step_gate` | select the next step; preflight preview; request approval | no | no | yes (approval) |
| `step_execute` | dispatch one step through the effect journal | no | yes | yes (effect-unknown pause) |
| `evaluate` | advance cursor / enter repair / move to the next phase / finish | no | no | no |
| `verify` | final verification generation, `VerificationRecord` | yes (journalled) | model only | no |
| `terminal` | write the terminal record; the barrier completes the request | no | no | no |

Branches (`Builder#branch`, evaluated against the post-reduce candidate state,
`route_planner.rb:53`):

- `START → intake → deliberate` (static edges)
- `deliberate → [:step_gate, :terminal]`
- `step_gate → [:step_execute, :evaluate]` (no remaining steps ⇒ `evaluate`)
- `step_execute → [:evaluate, :terminal]` (blocked/unknown ⇒ `terminal` after pausing)
- `evaluate → [:step_gate, :deliberate, :verify]`
- `verify → [:terminal]` (static edge)

Every arrow is one super-step, hence one committed checkpoint. That is the kill matrix's
grid.

### Why the deliberation loop is one node, not three

`deliberate` runs up to `max_plan_attempts` (plan generation, structural review, semantic
review) inside one node. On crash it re-enters at line one (invariant 4) and every model
call it already made returns from the journal (`prepare` → `:return`,
`effect_journal.rb:163–165`). So resume reproduces **the same** accepted plan even when the
crash happened before any plan checkpoint existed — which is a stronger guarantee than
invariant 25's minimum ("crash resume reuses the checkpointed exact plan version") because
it also covers the pre-checkpoint window. Splitting it into three nodes would add two
barriers without adding a guarantee.

## 4. Durable session records (P6-A)

All session state is plain allowlisted JSON (scalars, arrays, hashes) — no custom Ruby
type is revived, so no new `StateCodec` registration is created. Each record carries
`"record"` (kind) and `"record_version"` (integer).

```ruby
Tamoz::Agent::SessionRecords::RECORD_VERSION = 1

SessionRecords.build(kind, **fields)   # => frozen validated Hash
SessionRecords.load!(value, kind:)     # => the same Hash, or raises
SessionRecords.load_state!(state)      # validates every session channel at once
SessionRecords.reject_sensitive!(value)
SessionRecords.digest(value)           # SHA-256 over canonical JSON, domain-separated
```

`load!` rejection order — the first failing rule wins, and **nothing is partially
loaded**:

1. not a Hash → `Tamoz::CheckpointCorruptionError`;
2. missing/unknown `"record"` kind → `CheckpointCorruptionError` (allowlist);
3. `"record_version"` missing or not a positive Integer → `CheckpointCorruptionError`;
4. `"record_version" > RECORD_VERSION` → `Tamoz::CheckpointVersionError` **before any
   field is read** (invariant 18: "newer unsupported versions fail before partial load");
5. `"record_version" < RECORD_VERSION` → pure migration function
   `MIGRATIONS[[kind, version]]`, applied repeatedly until current, else
   `CheckpointVersionError`;
6. unknown keys, missing required keys, or a value of the wrong shape →
   `CheckpointCorruptionError`;
7. any `Tamoz::Secret` anywhere in the value → `Tamoz::SensitiveValueError`.

`Session#recover` and `Session#resume` call `SessionRecords.load_state!` on the loaded
checkpoint **before** the runner schedules any node, so an unsupported record version
fails before user code runs.

### Record kinds

| Kind | Fields |
|---|---|
| `session` | `session_id`, `task`, `task_digest`, `root`, `graph_version`, `behavior_version`, `tool_catalog_digest`, `created_at_ms` |
| `plan` | `plan_id`, `phase`, `attempt`, `plan` (canonical plan hash), `plan_digest` |
| `review` | `review_id`, `plan_id`, `plan_digest`, `layer` (`structural`/`semantic`), `decision`, `issues`, `rationale` |
| `accepted_plan` | `plan_id`, `plan_digest`, `phase`, `plan`, `accepted_at_ms` |
| `approval` | `approval_id`, `plan_id`, `plan_digest`, `step_id`, `tool`, `arguments_digest`, `preview_digest`, `decision`, `decided_at_ms` |
| `effect_intent` | `step_id`, `plan_id`, `plan_digest`, `tool`, `operation`, `safety`, `path`, `before_state` (`"absent"` or 64-hex), `after_digest`, `after_mode`, `arguments_digest` |
| `effect_receipt` | `effect_key`, `step_id`, `operation`, `safety`, `status`, `attempt_number`, `reconciliation` (`null`/`completed`/`not_applied`/`unknown`), `external_id` |
| `observation` | `phase`, `repair_attempt`, `step_id`, `tool`, `output`, `check` (nullable) |
| `verification` | `answer`, `satisfied`, `evidence`, `configured_check_passed`, `terminal_reason` |
| `terminal` | `reason`, `satisfied`, `blocked` (nullable) |
| `blocked` | `reason`, `effect_key`, `operation`, `resource`, `prepared_at_ms`, `actions` |

### Identity

- `session_id` **is** the checkpoint `thread_id`. There is no second identity space.
- `plan_id` = `"<phase>.<repair_attempt>.<attempt>"` — deterministic, so a re-entered
  `deliberate` produces the same id and the append reducer is idempotent by id.
- `review_id` = `"<plan_id>.<layer>"`.
- `approval_id` = `"<plan_id>.<step_id>"`.
- request identity is the caller's `request_id` (invariant 23) and is never derived from
  a plan or a clock.
- ordering **always** uses the backend `sequence` / `enqueue_sequence`; no code path may
  sort by `checkpoint.id`, `plan_id`, or a timestamp (invariant 9).

### Channels

| Channel | Reducer | Record kind |
|---|---|---|
| `session` | last value | `session` |
| `task` | last value | String |
| `phase` | last value | String |
| `repair_attempt` | last value | Integer |
| `plan_versions` | `:append` | `plan` |
| `plan_reviews` | `:append` | `review` |
| `accepted_plan` | last value | `accepted_plan` |
| `step_cursor` | last value | Integer |
| `approvals` | `:append` | `approval` |
| `effect_intents` | `:append` | `effect_intent` |
| `effect_receipts` | `:append` | `effect_receipt` |
| `observations` | `:append` | `observation` |
| `evidence` | `:append` | `observation` (discovery-phase copies) |
| `seen_action_signatures` | `:union` | String |
| `seen_failure_signatures` | `:union` | String |
| `check_passed` | last value | Boolean |
| `provider_ambiguity` | last value | Integer |
| `verification` | last value | `verification` |
| `blocked` | last value | `blocked` or nil |
| `terminal` | last value | `terminal` |

Only one task writes per super-step, so no reducer-less conflict is possible.

**Why `:append` is safe under crash re-entry.** `Reducers.append` concatenates; it does
*not* dedupe by id. Duplicates are nevertheless impossible, because a node's writes become
visible only at its own barrier (invariant 2): a crash *before* that barrier commits
nothing and the node re-runs from an unchanged snapshot, and a crash *after* it means the
node is not re-entered at all (`executor.rb:35` filters already-pending activations). As a
defensive rule that does not depend on that argument, **every node filters out records
already present in its frozen input snapshot before appending**, and a test kills at
`before_commit` on the `deliberate` barrier and asserts exactly one `plan` record per
`plan_id` after recovery.

## 5. Exact API surface added

### `tamoz-agent` (public)

```ruby
module Tamoz::Agent
  # Frozen definition of the durable lifecycle. Compile it against any durable checkpointer.
  Session.graph                                  # => Tamoz::Graph::Definition

  Session.new(
    model:,                                      # responds to #generate(stage:, system:, prompt:)
    toolbox:,                                    # Tamoz::Agent::Toolbox
    checkpointer:,                               # durable checkpointer (tamoz-sqlite adapter)
    max_plan_attempts: 3,                         # Integer 1..10
    max_repair_attempts: 2,
    model_call_safety: :idempotent,               # :idempotent | :unsafe  (§7)
    clock: nil                                    # Tamoz::Clock-compatible, tests only
  )

  # All four return Tamoz::Agent::SessionOutcome.
  session.start(task, thread:, request_id:, owner_id: nil)
  session.resume(answers, thread:, request_id:, owner_id: nil)   # answers: {task_id => value}
  session.recover(thread:, request_id:, owner_id: nil)
  session.continue(thread:, request_id:, owner_id: nil)

  session.view(thread:)                          # => Tamoz::Agent::SessionView
  session.resolve_effect(thread:, effect_key:, status:, actor:, evidence: {})
                                                 # status: :succeeded | :failed | :abandoned

  SessionOutcome = Data.define(
    :status,          # :completed | :paused | :blocked | :failed
    :request_status,  # :queued | :claimed | :running | :completed | :failed
    :thread_id, :execution_id, :request_id,
    :approvals,       # Array of approval interrupt descriptors (frozen)
    :blocked,         # blocked record or nil
    :result,          # Tamoz::Agent::Result or nil
    :state            # frozen session state Hash
  )

  SessionView = Data.define(
    :thread_id, :sequence, :execution_id, :phase, :accepted_plan,
    :approvals, :effect_receipts, :blocked, :terminal, :state
  )

  Deliberation                                    # module: pure planning/review/verify logic
  SessionRecords                                  # module: versioned allowlisted records
end
```

`Toolbox` gains exactly two public methods:

```ruby
toolbox.check_safety(name)      # => :read_only | :idempotent | :unsafe  (default :unsafe)
toolbox.catalog_digest          # => "sha256:…" over tool names + descriptions + check names
```

and `Toolbox.new` gains one optional keyword: `check_safeties: {}` (a
`{check_name => safety_symbol}` map, validated against the configured check names).

### `tamoz-sqlite` (public)

One method on the existing journal — no new class, no new table:

```ruby
Tamoz::SQLite::EffectJournal#reconcile(key:, disposition:, actor:, evidence:)
# disposition: :completed | :not_applied | :unknown
# => Tamoz::Graph::EffectDecision(action:, record:, attempt_token:)
#    :completed    -> action :return,  head :succeeded, requires_reconciliation cleared
#    :not_applied  -> action :execute, head :prepared with a NEW fenced attempt + token
#    :unknown      -> action :unknown, head :unknown
```

Preconditions: head status must be `reconcile`; `:not_applied` additionally validates the
current lease inside the same transaction (it grants execution authority) and records a
`reconcile.not_applied` transition. `:completed` and `:unknown` do not require the lease,
matching `complete`'s deliberate late-receipt rule (PERSISTENCE_DESIGN §4).

One field on the existing limits value — no new table, column, or index:

```ruby
Tamoz::SQLite::Limits.new(effect_attempt_ttl: 60.0)   # default 60.0, range 0.1..3600.0
```

`CheckpointStore::Writer` (`checkpoint_store.rb:894`) currently constructs
`EffectJournal.new(store:, guard:)` with the journal's hardcoded 60-second
`attempt_ttl` (`effect_journal.rb:21`). Every reconcile/abandon path depends on a prior
attempt's deadline having passed (`effect_journal.rb:181–183` returns `:wait` until then),
so with a fixed 60 s the kill matrix cannot exercise §6.3 at all without sleeping a minute
per row. The writer therefore passes
`attempt_ttl: store.adapter.limits.effect_attempt_ttl`. The **default is unchanged at
60 s**; only the kill-matrix children lower it. `Limits` is only ever constructed with
keyword arguments in the tree, so the addition is source-compatible.

### `tamoz-graph`

No public API change. `Tamoz::Graph::EffectDecision` and `EffectRecord` are reused as-is.

## 6. Effects (P6-C)

### 6.1 Effect identity

`EffectJournal#key(execution_id:, task_id:, call_index:, operation:)`
(`effect_journal.rb:39`) is used unmodified:

- `execution_id` = `context.execution_id` (the turn's execution, allocated by
  `claim_next_request`);
- `task_id` = `context.task_id`, which `Executor#execute_task` (`executor.rb:205–212`)
  sets to `task.id`, the **stable logical activation id** (invariant 52) — it survives
  interrupt, retry, crash resume, and lease takeover;
- `call_index` = **a pure function of `(stage, attempt)`** — `deliberate` uses
  `attempt * 2` for the plan call and `attempt * 2 + 1` for the semantic review call;
  `step_execute` uses `0`; `verify` uses `0`;
- `operation` = `"model.generate.<stage>"`, `"tool.read_file"`, `"tool.apply_patch"`,
  `"tool.create_file"`, `"tool.run_check"`, …

Attempt id and resume checkpoint are excluded, exactly as PERSISTENCE_DESIGN §4 requires.

**`call_index` must never be a running counter.** `Runtime#accepted_plan`
(`runtime.rb:220–277`) does not make two model calls per attempt: a structural-review
failure skips the semantic reviewer entirely (`runtime.rb:249–252`) and a `ProtocolError`
skips it from the rescue (`runtime.rb:266–276`). A counter would therefore give the same
logical call different indices across a re-entry whose earlier attempts branched
differently, the effect key would change (`effect_journal.rb:39–57`), the recorded receipt
would be missed, and the provider would be called again. The `(stage, attempt)` formula is
a safety rule, not an arithmetic convenience, and is covered by a dedicated test that
drives a structural rejection followed by an acceptance and asserts the accepted attempt's
plan call still lands on `call_index == attempt * 2`.

### 6.2 Filesystem effects: intent one barrier before dispatch

`apply_patch` and `create_file` are **not** idempotent: `apply_patch` requires the exact
before-digest and fails once applied; `create_file` is no-clobber and fails with `EEXIST`
once published. Blind retry therefore produces a *false failure*, not convergence. They
are declared `:reconcilable`.

Reconciliation needs the before- and after-state, and neither can be recovered after the
fact: the journal stores only the request *digest* (`effect_journal.rb:80–83`), and after a
successful `apply_patch` the original content is gone. So `step_gate` computes a
deterministic **`effect_intent`** and commits it at the barrier *before* `step_execute`
runs:

| tool | `before_state` | `after_digest` | `after_mode` |
|---|---|---|---|
| `apply_patch` | `expected_sha256` argument (already required to equal the file's current digest) | SHA-256 of `Toolbox#prepare_patch`'s computed `after_content` | `null` |
| `create_file` | `"absent"` | `expected_sha256` argument | requested mode, default `0644` |

Both come from the existing pure preflight helpers (`toolbox.rb:373` `prepare_patch`,
`toolbox.rb:436` `prepare_create_file`) which perform **no** write. The same preflight
already backs the approval preview (`toolbox.rb:242`).

**One computation, one commit.** `step_gate` computes the preview and the intent in the
same pass and commits the `approval` and `effect_intent` records at the **same** barrier.
`step_execute` binds to the *committed* intent and never recomputes it as authority. This
matters because a node restarts from its first line on resume (invariant 4,
GRAPH_DESIGN §7): if `step_gate` recomputed the intent after an approval interrupt and the
workspace had changed, the operator's approval would be attached to different bytes. The
existing guards mean this cannot cause a wrong *write* — `apply_patch` fails its
`expected_sha256` check (`toolbox.rb:380–382`) and `create_file` fails `EEXIST`
(`toolbox.rb:467–468`) — but it could cause execution against an unapproved intent.
`step_execute` therefore re-observes `before_state` and, if it disagrees with the committed
intent, **fails the step closed** with a typed error instead of executing. Observation
budget: `step_gate` performs the same pre-execution check `Runtime` does
(`runtime.rb:366–369`) using the same `MAX_OBSERVATION_BYTES` constant, and `step_execute`
enforces the same post-execution ceiling (`runtime.rb:400–404`), so durable checkpoint
payloads stay bounded and the budget failure happens *before* an effect runs.

### 6.3 Dispatch and reconciliation

`Tamoz::Agent::EffectDispatcher#call(intent, context:)`:

```text
decision = effects.prepare(execution_id:, task_id:, call_index:, operation:, safety:, request:)

:execute   -> effects.start(...) -> toolbox.execute(tool, args) -> effects.complete(:succeeded|:failed)
:return    -> reuse the recorded receipt; the tool is NOT run again
:wait      -> a live attempt still owns it; raise LeaseLostError and let the owner finish
:failed    -> surface the recorded failure
:reconcile -> reconcile(intent) (below)
:unknown   -> pause: write `blocked`, Tamoz.interrupt(effect_unknown descriptor)
```

`reconcile(intent)` observes the workspace and maps it to exactly one disposition:

| tool | observed | disposition | journal call |
|---|---|---|---|
| `apply_patch` | file digest == `after_digest` | `:completed` | `reconcile(disposition: :completed)` → `:return` |
| `apply_patch` | file digest == `before_state` | `:not_applied` | `reconcile(disposition: :not_applied)` → `:execute` with a new fenced attempt |
| `apply_patch` | anything else (missing, third-party edit, unreadable) | `:unknown` | `reconcile(disposition: :unknown)` → pause |
| `create_file` | target exists, digest == `after_digest`, mode == `after_mode` | `:completed` | as above |
| `create_file` | target absent | `:not_applied` | as above |
| `create_file` | target exists with a different digest or mode | `:unknown` | as above |

"Execute only from proven-before state, complete from proven-after state, otherwise
mark unknown" is exactly this table. A digest collision is out of the fault model.

### 6.4 Design conflict recorded, with five-whys (handover plan §2)

**Conflict.** `PERSISTENCE_DESIGN.md` §4 replay policy states, for `:reconcilable`:
"query target by external id/key, then complete or mark unknown". `EffectJournal#prepare`
implements that faithfully: for `reconcilable` it sets head `reconcile`
(`effect_journal.rb:218–229`) and there is **no transition from `reconcile` back to
`prepared`**. `PROJECT_HANDOVER_PLAN.md` §6 P6-C requires "Execute only from proven-before
state". The two cannot both be satisfied by the code as it stands.

**Five whys.**

1. *Why can't the journal execute after reconciliation?* Because `:reconcilable` was
   specified with a two-valued outcome (complete | unknown) and `resolve`
   (`effect_journal.rb:481`) only reaches terminal statuses.
2. *Why was two-valued enough at design time?* The motivating example was a remote API
   with an external id, where the only question is "did my request land". If it did not,
   the caller was expected to schedule a *new* logical activation.
3. *Why is that inadequate here?* Scheduling a new activation for a filesystem write means
   consuming a bounded repair attempt and emitting a spurious failed step, even though the
   workspace has been **proved** to be in the exact pre-effect state. Safety gains nothing;
   the product proof loses.
4. *Why not declare the filesystem effects `:idempotent` instead?* Because they are not.
   `apply_patch` fails its before-digest guard after a successful application and
   `create_file` fails with `EEXIST`; retry under `:idempotent` reports a false failure
   and, worse, teaches the repair loop to "fix" an already-correct file.
5. *Why not resolve `:failed` and let the repair loop replan?* Same as 3, plus it makes
   the journal's own history untruthful: recording "failed" for an operation that simply
   never started is a lie the audit trail must not contain.

**Resolution (design amendment, accepted in the plan review before any code).** The
`:reconcilable` outcome set is **three**-valued: `completed`, `not_applied`, `unknown`.
`not_applied` is *proof of the pre-state*, and proof of the pre-state — not a safety
class, and never an approval — is what authorizes one further fenced attempt under the
same stable effect key. Approval never makes an operation retryable (AGENT_DESIGN §5);
observed evidence, recorded as a durable journal transition, does.
This strengthens invariant 21 rather than weakening it: no ambiguous effect is ever
retried, and the retry that does occur is justified by observed evidence recorded as a
durable `reconcile.not_applied` transition. `PERSISTENCE_DESIGN.md` §4 is pinned v0.1
content with a `SOURCE` commit and is therefore **not edited** in P6; this plan and its
review are the accepted correction of record, and folding it into the design package
requires a v0.2 ADR. Anyone reading only PERSISTENCE_DESIGN will find the row incomplete,
not wrong.

**Bounded.** `reconcile(disposition: :not_applied)` grants at most one further attempt per
call, requires head status `reconcile`, requires a valid current lease, and is only ever
reached from `prepare`'s `:reconcile` action — so it cannot become a retry loop. The
session additionally caps reconciliation grants per effect key at
`MAX_RECONCILE_GRANTS = 2`; beyond that the effect is marked `:unknown` and pauses.

## 7. Checks and provider calls (P6-D2)

### Configured checks

A configured check is an operator-supplied argv. Nothing about it is provably safe, so:

- `Toolbox#check_safety(name)` defaults to `:unsafe`;
- an operator may declare `:read_only` or `:idempotent` per check via
  `Toolbox.new(check_safeties: {"tests" => :read_only})`;
- `:unsafe` + ambiguous crash ⇒ `prepare` returns `:unknown` (`effect_journal.rb:230–251`)
  ⇒ the session writes a `blocked` record, interrupts, and **never re-runs the command**.
  Only `Session#resolve_effect` (a human/operator decision) can move it on.

The declaration is authority-bearing configuration, so it comes from the `Toolbox`
constructor (operator-controlled), never from plan text or model output.

### Provider calls

`Session.new(model_call_safety:)` accepts `:idempotent` (default) or `:unsafe`.

The `:idempotent` default is a *declared contract that is provable in this architecture*,
not an optimistic guess: Tamoz drives one generation at a time (AGENT_DESIGN §2), the
model never executes a tool itself (tools run in `step_execute`, `toolbox.rb:220`), and the
only stage inputs are `stage`, `system`, and `prompt`. A repeated generation therefore has
no external effect other than a metered provider charge. `AGENT_DESIGN.md` §4 states this
explicitly: "an ambiguous crash may incur a repeated call and charge. This limitation is
exposed in metrics and documentation."

To honour "exposed in metrics", every ambiguous re-grant increments the durable
`provider_ambiguity` channel, which is reported in `SessionView` and `SessionOutcome`.
Deployments that treat a duplicate charge as unacceptable set
`model_call_safety: :unsafe`, and then an ambiguous provider crash pauses exactly like an
unsafe check. Any future model stage that can produce an external effect (tool-calling
inside the provider, remote code execution) **must** be declared `:unsafe`; this is a
stated precondition of the `:idempotent` declaration, not an assumption.

## 8. Failure model

| Failure | Where detected | Result |
|---|---|---|
| Process killed before a barrier commit | next `recover` | last committed checkpoint is the truth; the node re-enters from line one; journalled model receipts and effects are reused |
| Process killed after a barrier commit | next `recover` | the committed state advances; the node is not re-entered |
| Lease expiry mid-turn | `validate_lease_in_transaction!` `lease_operations.rb:164` | `LeaseLostError`; no write commits; a new owner recovers |
| Stale fence commit attempt | same | rejected; existing `sqlite_crash_recovery_test.rb:142` already proves one live fence |
| Late receipt after lease loss | `EffectJournal#complete` (no lease check) | receipt commits; head becomes `reconcile` if a newer attempt exists (`effect_journal.rb:452–467`) |
| Effect prepared, never started | `prepare` `:184–204` | attempt abandoned past deadline, new attempt granted, action `:execute` |
| Effect running past deadline, `:reconcilable` | `prepare` `:218–229` → `EffectDispatcher#reconcile` | `completed` / `not_applied` / `unknown` per §6.3 |
| Effect running past deadline, `:unsafe` | `prepare` `:230–251` | `:unknown`; session pauses; never repeated |
| Unsupported newer record version | `SessionRecords.load_state!` before scheduling | `CheckpointVersionError`, nothing partially loaded |
| Incompatible graph version/digest | `Compiled#compatible!` `compiled.rb:889` | fails before user code |
| `Tamoz::Secret` in any record | `SessionRecords.reject_sensitive!`, then `state_codec.rb:144` | `SensitiveValueError`; nothing committed |
| Approval denied | `step_gate` resume value | terminal `approval_denied`; no effect prepared |
| Plan rejected after `max_plan_attempts` | `deliberate` | terminal `plan_rejected`; no effect prepared |
| Repair budget exhausted / repeated action / repeated failure | `evaluate` | terminal with the same reasons `Runtime` uses (`runtime.rb:144–196`) |
| SQLite busy/locked | `DatabaseKernel#transaction` `database_kernel.rb:54–63` | bounded retry then a mapped error |
| Disk full during a filesystem effect | `Toolbox#atomic_create` `toolbox.rb:469` / `atomic_replace` `:610` | typed `ToolError`; effect completed as `:failed`; no public partial file (P5 contract) |

## 9. Migration

- **No SQLite schema change.** No new table, column, or index. `Migrator` is untouched, so
  an existing database opens unchanged. `Limits#effect_attempt_ttl` is a *runtime* value,
  not persisted state, and defaults to today's hardcoded 60 s.
- **No checkpoint format change.** `CheckpointCodec::FORMAT_VERSION` stays `1`.
- **New graph identity.** `tamoz.agent.session` v1 has no predecessor, so no checkpoint
  migration exists or is needed. A future v2 must bump the graph version, and
  `Compiled#compatible!` will refuse to resume a v1 checkpoint under v2 — the intended
  fail-fast boundary (invariant 22).
- **Record migration.** `SessionRecords::MIGRATIONS` is a registry of pure
  `old_hash -> new_hash` functions keyed by `[kind, version]`. It is empty at v1, and a
  fixture test asserts that (a) the registry is empty, (b) a v0 record fails with an
  actionable error, and (c) a v2 record fails with `CheckpointVersionError` before any
  field is read.
- **`Runtime` is unchanged**, so existing embedders and the P3 scorecard are unaffected.
- **`Toolbox.new(check_safeties:)`** is optional and defaults to `{}`; omitting it yields
  the current behaviour plus the safe `:unsafe` classification.

## 10. Evaluations and proof

### Unit / integration

- `test/agent_session_records_test.rb` — allowlist, version gate ordering, sensitive
  rejection, migration registry, canonical digest stability.
- `test/agent_deliberation_test.rb` — the extracted module produces byte-identical
  prompts, structural issues, review parses, verification parses, and action signatures
  for a table of inputs shared with `Runtime`.
- `test/agent_session_test.rb` — one durable turn end to end against a real SQLite file:
  discovery → action plan → approval interrupt → `create_file`/`apply_patch` → `run_check`
  → verify → terminal; request completed exactly once; duplicate `start` with the same
  `request_id` returns the same record and does not append a second turn.
- `test/agent_session_effect_test.rb` — the §6.3 reconciliation table driven directly
  through the journal, including `MAX_RECONCILE_GRANTS`, `:unsafe` check pausing, and
  `resolve_effect`.
- `test/sqlite_effect_journal_test.rb` — new cases for `reconcile`: wrong head status,
  stale fence on `:not_applied`, attempt-history truthfulness, transition log.

### Kill matrix (P6-E) — real `kill -9`, no simulation

Every row spawns a child process with `Process.spawn` and kills it with a real
`Process.kill("KILL", Process.pid)` at the named seam, following
`test/sqlite_crash_recovery_test.rb:36–72` and
`gems/tamoz-evals/lib/tamoz/evals/harness/subprocess_runner.rb`. Seam selection uses the
**existing** `Tamoz::SQLite::Adapter#fault_injector` (`adapter.rb:49`) with
`(point, operation, occurrence)`; the two seams inside the filesystem primitive use a
child-local `File.link`/`File.rename` prepend that issues the same real SIGKILL. No test
substitutes an exception for a kill.

| # | Seam | Kill trigger | Required outcome |
|---|---|---|---|
| K1 | before plan acceptance | `before_commit` on `checkpoint.commit` #2 | recover replans from journalled receipts; identical `plan_digest`; provider call count unchanged |
| K2 | after plan acceptance | `after_commit` on `checkpoint.commit` #2 | recover reuses the checkpointed exact plan; `deliberate` not re-entered; provider call count unchanged |
| K3 | after a model receipt commit | `after_commit` on `effect.complete` #1 | same `plan_digest`; provider call count unchanged |
| K4 | after provider response, before receipt | `before_commit` on `effect.complete` #1 | with `model_call_safety: :idempotent`: exactly one extra provider call, `provider_ambiguity == 1` in `SessionOutcome`, same accepted `plan_digest`. With `model_call_safety: :unsafe`, same seam: the session pauses `blocked` and makes **zero** extra provider calls |
| K5a | at the approval interrupt checkpoint, before commit | `before_commit` on `checkpoint.commit` at `step_gate` | no approval recorded; no effect prepared; recover re-asks |
| K5b | at the approval interrupt checkpoint, after commit | `after_commit` on same | approval descriptor durable; resume by task id proceeds without re-asking |
| K6 | after effect prepare | `after_commit` on `effect.prepare` | attempt abandoned past deadline; new attempt; file applied **exactly once** |
| K7 | after effect start, before publication | `after_commit` on `effect.start` | `:reconcile` → `not_applied` → one further attempt; file applied **exactly once** |
| K8 | immediately after filesystem publication, before receipt | child-side prepend on `File.link` / `File.rename` | `:reconcile` → `completed`; the tool is **not** run again; file content and mtime-independent digest unchanged |
| K9 | during check execution | kill while the check child runs | `:unsafe` ⇒ `:unknown`; session `blocked`; the command is never re-run. The test explicitly reaps the check's orphaned process group (`Toolbox#run_check` spawns it with its own pgid and normally tears it down at `toolbox.rb:694`, which SIGKILL skips) so `rake ci` leaks no processes |
| K10 | after check receipt commit | `after_commit` on `effect.complete` for the check | recover reuses the recorded receipt; the command is not re-run |
| K11 | before verification checkpoint | `before_commit` on `checkpoint.commit` at `verify` | verification regenerated from the journalled receipt; same answer |
| K12 | before terminal commit | `before_commit` on the terminal `checkpoint.commit` | request still non-terminal; recover completes it exactly once |
| K13 | after terminal commit | `after_commit` on the same | request `completed`; re-`start` with the same `request_id` returns the prior response |
| K14 | lease loss | kill the owner, let the lease expire, recover from a second process | old fence cannot commit; new owner recovers; one execution id in history |

Every row asserts, in addition to its specific outcome:

1. exactly one execution id in the thread's history;
2. the target file's SHA-256 equals the intended after-digest, and the mutation ran
   exactly once across all processes. Primary evidence is the file digest plus the
   journal's attempt history; corroborating evidence is an append-only marker written by a
   **child-local** prepend on `File.link`/`File.rename` inside the test child script — the
   same harness technique that triggers K8's kill. No product code writes a marker;
3. `adapter.integrity_check.fetch("ok")` is true;
4. no **public** partial or unexpected file survives in the workspace: the only entries
   are the intended targets plus, possibly, a private `.tamoz-*` temporary orphaned by
   the kill. `atomic_replace`/`atomic_create` publish by rename/link and unlink the
   temporary name only afterwards, so a kill in that window leaves a dotfile that is
   never the target path. Reclaiming it would require an unlink capability the agent
   deliberately does not have (P4/P5 non-goals), so it is recorded as residual risk
   rather than silently deleted.

### Operational durability (P6-F)

Ordered by value; anything not reached is reported as not done, never as passing.

1. lease loss / stale fence (K14, plus existing `sqlite_crash_recovery_test.rb:142`);
2. late receipt after lease loss;
3. busy/lock contention under two concurrent owners;
4. `integrity_check` after every kill (already folded into the matrix);
5. backup/restore of a paused session, then resume;
6. retention: `prune` must not remove a checkpoint that an unresolved effect references;
7. deletion: `tombstone_thread` must refuse while an effect is `prepared`/`running`/
   `unknown` (already implemented — `deletion.rb`; P6 adds the session-level assertion);
8. FD/thread leak across 20 kill/recover cycles.

### Gate

1. `rbenv exec bundle exec rake ci` green under **both** `LC_ALL=en_US.UTF-8` and
   `LC_ALL=C`.
2. `tamoz-eval scorecard agent-smoke`: `decision: pass`, four hard gates pass,
   `unsafe_or_bypassed_actions`/`false_positive_completions`/`incomplete_case_evidence`
   all `0`, `task_successes >= 8`, corpus digest `sha256:d24bb33f…` and content digest
   `sha256:3851d176…` unchanged. P6 adds no scorecard case: the corpus is a pinned P3
   artifact, and P6's product proof is the kill matrix.
3. All five gems package.

## 11. Stop / redesign criteria

Stop, record the conflict here, and re-review before writing more code if any of these
becomes true:

- durable agent execution requires a private RubyLLM API;
- any lifecycle stage needs to bypass a graph barrier to be correct;
- a second checkpoint store or a second effect record proves necessary;
- an unknown effect would have to be retried, or an unknown outcome converted into a
  "safe" retry, to make a proof pass;
- a `kill -9` at any declared seam applies a filesystem effect twice, or resumes a
  *regenerated* plan rather than the checkpointed exact one;
- extracting `Deliberation` changes any observable `Runtime` behaviour, or the scorecard
  moves off `decision: pass`, 8/12, and hard-zero counters;
- `EffectJournal#reconcile` cannot be made compare-and-set, fenced, and bounded;
- the kill matrix would need a simulated crash to be green.

## 12. Definition of done

- Every row of §2 is implemented or explicitly recorded as not implemented, with reasons.
- `Session` runs one real repository repair end to end over `DurableRunner`.
- Every declared kill seam is proved by a real `kill -9` in a child process, and the
  repair (a) resumes the same accepted exact plan, (b) never applies a filesystem effect
  twice, (c) pauses a truly unknown check or effect.
- Read-only and ephemeral construction still work **through the unchanged `Runtime`**.
  `Session` is durable-only: `Session.new` raises `ConfigurationError` unless the
  checkpointer is durable and exposes the request inbox, because `DurableRunner`
  (`durable_runner.rb:13–19`) requires it and because `context.effects` is only bound from
  a writer that has an effect journal (`compiled.rb:956–972`,
  `checkpoint_store.rb:894`). `Tamoz::Graph::MemoryCheckpointer#durable?` is `false`
  (`memory_checkpointer.rb:37`) and PERSISTENCE_DESIGN §9 forbids using it to claim crash
  durability or effect safety, so no ephemeral `Session` is offered.
- `rake ci` green under both locales; scorecard at or above the floor; all gems package.
- This plan and its review are committed **before** any implementation commit.

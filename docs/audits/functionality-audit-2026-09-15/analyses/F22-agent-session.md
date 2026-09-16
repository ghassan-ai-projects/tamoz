# F22 `tamoz-agent-session` — IMPROVE: the durable session is sound at the record, binding, and effect boundaries, but `cancel` can rewrite a terminal verdict and the session half of the claim-starvation boundary is undocumented

Row: F22 · Queue: W1A gem rows · Baseline: `582ae5566de1ae073aea82b69bb2bbf444494d3b` (`audit-15-09`, 2026-09-14) · Analyst: independent read-only functionality auditor · Budget: ~55 min (55 used)

## Scope and source map

All 22 files of `gems/tamoz-agent-session/lib` read end to end, 5,802 lines:

| File | Lines | Role |
|---|---|---|
| `agent_session.rb` | 39 | gem entry point; require order is load-bearing (collaborators before `session.rb`) |
| `agent/session.rb` | 516 | public façade: `Session` + `SessionOutcome`/`SessionView`, five `verify_*_binding!` guards, `guard_state!`, `resolve_effect`, `effect`, `view`, `start/resume/continue/recover/close` |
| `agent/session_records.rb` | 590 | the versioned, allowlisted record layer (invariant 18/24) |
| `agent/session_planning_context.rb` | 593 | bounded frame + `BoundedCompactor` + durable transcript readers |
| `agent/session_adaptive.rb` | 541 | the adaptive read-only loop (4 nodes) |
| `agent/session_context_controls.rb` | 471 | `/reset /compact /think /verbose /usage /context` |
| `agent/session_effects.rb` | 406 | the one journal boundary for model and tool calls |
| `agent/session_steps.rb` | 309 | gate/approve/execute step protocol |
| `agent/session_routing.rb` | 302 | the routed-discovery intake |
| `agent/session_plan_attempt.rb` | 257 | one plan→structural→semantic attempt |
| `agent/session_nodes.rb` | 221 | frozen node façade + `MAX_*` bounds |
| `agent/session_evidence.rb` | 219 | intent lookup, bounded repair, `blocked_update` |
| `agent/session_lifecycle.rb` | 191 | evaluate / verify / terminal |
| `agent/session_bindings.rb` | 176 | intake + session-record assembly |
| `agent/session_options.rb` | 180 | `Options.build` — the single construction validator |
| `agent/session_plan_outcomes.rb` | 175 | accept / reject / clarify commits |
| `agent/session_graph.rb` | 160 | per-variant graph DSL |
| `agent/session_status_projection.rb` | 153 | bounded status wire |
| `agent/session_deliberation.rb` | 142 | bounded plan/review loop |
| `agent/session_memory.rb` | 134 | memory + behavior-transition binding |
| `agent/session_approval_wiring.rb` | 18 | `default_engine` seam (driver-owned) |
| `agent/session_gem/version.rb` | 9 | version |

Entry seam: `Tamoz::Agent::Session.new` → `Options.build` (`session_options.rb:50-57`) → `build_nodes`/`build_definitions` (`session.rb:100-123`) → four compiled apps, one per graph variant. `gem/tamoz-agent-session.gemspec` declares nine same-version deps (`tamoz-agent-capabilities`, `-kernel`, `-memory`, `-profile`, `-healing`, `tamoz-core`, `-cancellation`, `-graph`, `-tools`).

## Behavior path

1. **Construction.** `Options.build` defaults, then `validate` (`session_options.rb:73-81`): model duck-type, plan/repair limits, model-call safety, routing ∈ `{legacy, experimental, adaptive}`, **durable checkpointer only** (`session_options.rb:121-127`), MCP duck-type, and profile catalog/root binding (`session_options.rb:142-176`). Failure is before any graph compiles.
2. **Intake.** `SessionBindings#intake` (`session_bindings.rb:17-25`) → `validated_task` (non-empty, ≤ `MAX_TASK_BYTES` 16 KiB, `session_nodes.rb:25`) → `SessionMemory#claim_behavior_transition` → `session_update` builds the `session` record through `profile_binding`/`skill_binding`/`mcp_binding`/`egress_binding`/behavior/memory (`session_bindings.rb:155-173`). A cancel task short-circuits to `{next_node: 'terminal', terminal_reason: 'cancelled_by_user'}` (`session_bindings.rb:82-88`).
3. **Planning.** Routed variant: `SessionRouting#route` → journaled `model.generate.route`, structural issue check, optional journaled `model.generate.route_review`, `fallback_with_records` to `deliberate` on any refusal (`session_routing.rb:16-37,238-258`). Then `SessionDeliberation#deliberate` runs `max_plan_attempts` × `SessionPlanAttempt#run` (plan call → structural review → semantic review) (`session_deliberation.rb:91-100`, `session_plan_attempt.rb:29-45`).
4. **Execution.** `step_gate` → `step_execute` (`session_steps.rb:20-49`), every tool through `SessionEffects#dispatch` → `EffectDispatcher.run` (`session_effects.rb:75-86`); `:unknown`/`:wait`/`:failed` map to `blocked_update` / `LeaseLostError` / bounded repair (`session_steps.rb:213-244`).
5. **Verification and terminal.** `evaluate` → `verify` (journaled `model.generate.verify`, `enforce_check_requirement`, `session_lifecycle.rb:182-188`) → `terminal`, the one boundary that writes the `terminal` record (`session_lifecycle.rb:46-76`).
6. **Resume.** `resume`/`continue`/`recover` call `guard_state!` first (`session.rb:320-338`); `follow-up`/`redirect` call only the public `verify_skill_binding!` (`session.rb:143-145`, CLI `cli_session_commands.rb:132,165`).

## Lens: correctness

**Record versioning (invariant 18) — mechanism proven; the refusal order is real, not incidental.** `SessionRecords.load!` (`session_records.rb:382-393`) is strictly ordered: `validate_record_header!` (allowlisted kind, expected-kind match, `session_records.rb:395-410`) → `validate_record_version!` (`:412-424`) → `migrate_to_current!` (`:446-458`) → `apply_legacy_session_defaults!` → `validate_fields!` → `reject_sensitive!` → `reject_credential_values!`. No field outside the header is inspected before the version check. The claim is enforced by test, not just by reading: `test/agent_session_records_test.rb:50-63` passes a record with `record_version: 3`, a **wrong-typed** `reason` (Integer where `STRING` is required) and an **unknown key** `unknown_future_field` — three independent reasons a field-first implementation would have raised `CheckpointCorruptionError` — and asserts exactly `/version 3 exceeds supported version 2/`. `RECORD_VERSION = 2` with `MIGRATIONS = {}` (`session_records.rb:20,359`) means v1 is refused as typed `CheckpointVersionError` too (`test/agent_session_records_test.rb:67-73`).

**`documentation/limitations.md` reconciliation.** The "Versioned, allowlisted records (invariant 18)" entry says the release audit "currently marks the version-refusal evidence as failing" and tells the reader to "regenerate the audit after the environment-bound resume evidence is repaired". The committed measurement in `docs/requirements-audit.json` (`INV-18`) disagrees with that prose: `status: "pass"`, `evidence_result: "pass"`, named test `test/legacy_session_resume_test.rb#test_a_newer_record_version_is_refused_before_any_field_is_read`, five supporting tests. I ran both named suites on this checkout and both are green (see Tests). The stale artifact is the documentation page, not the code: the refusal order is intact and directly tested. This is F22-DOC-02.

**Seven verbs.** `ask/resume/continue/follow-up/redirect/show/list/resolve` all exist and route as the README claims (`README.md:63-65`; CLI table `cli.rb:35-45`; session entry points `session.rb:316-382`). Terminal effect semantics are correct where they matter most: `resolve_effect` on an effect whose head is not `unknown`/`reconcile`/`failed` is refused typed (`effect_reconciler.rb:189-191`), and a probe confirmed all three effects of a completed turn raise `Tamoz::CheckpointConflictError: effect status succeeded cannot be human-resolved`, leaving the receipts intact. `resolve` against a nonexistent effect key raises `effect does not exist`. Redirect on a completed thread terminal-fails as stale rather than forking (`RequestStaleness#turn_reason`, `request_staleness.rb:34-40`) — probe: `view=failed req=failed`.

`cancel` is the exception; F22-COR-01 below.

## Lens: security and authority

`guard_state!` (`session.rb:439-449`) runs exactly four checks plus an `@memory`-gated fifth: graph, skill, MCP, egress, behavior. It does **not** check `profile_digest`, `profile_id`, `profile_authority`, `authority_narrowed`, `profile_roles`, `profile_budgets`, `tool_catalog_digest`, or `healing_pin`. `profile_digest` appears in the session gem in exactly three places (`session_records.rb:52,472`, `session_bindings.rb:57`, `session_planning_context.rb:434`) — all *writes* or *renders*; no comparison site exists. This is a **precise confirmation of the scanner's claim** and it is the session-layer half of F21-SEC-01/F25-SEC-01: the session stores an authority binding it never re-verifies, and `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:1119-1125` does the digest check only for **child** tasks (`child_profile_for`), never for the parent thread's own session. The session layer adds **no** guard of its own; it relies entirely on the driver.

The adaptive machinery's authority surface is well defended. `SessionAdaptive#validate` (`session_adaptive.rb:86-112`) refuses any action whose arguments carry an authority-shaped key (`AUTHORITY_FIELDS`, `:17-20` → `terminal_update('adaptive_authority_field')`), refuses any capability outside `allowed_tool_names(:discovery)`, and hands **any** non-`:read_only` safety to the reviewed planner (`:100-102`). `parse_decision` rejects unknown fields, contradictory field sets, non-object arguments, and credential-shaped argument values (`:274-301`). So untrusted model output cannot widen capability; at worst it can hand off to the deterministic reviewed path.

Cross-thread isolation: `app_for_thread`/`with_effect_writer` write through the checkpointer's own fenced writer keyed on `thread` (`session.rb:422-432,494-513`); `resolve_effect` passes `thread:` down. The session layer **adds no guard**: the thread id is a parameter, and the store's `EffectJournalRows.effect` lookup is by `effect_key` alone (`effect_journal_rows.rb:19-21`) — F07-SEC-01 unchanged. Nor does the session layer re-check the resolved row's `thread_id`/`namespace` against the requested thread. It relies entirely on the store.

Credential hygiene at the checkpoint boundary is real: `reject_sensitive!` refuses `Tamoz::Secret` anywhere in a record (`session_records.rb:502-510`), `reject_credential_values!` scans **plan and accepted_plan only** (`:354,516-526`), and MCP remote text is redacted before it becomes an observation (`session_effects.rb:259-263`).

## Lens: reliability and durability

Durability is sound at the seams. Every non-deterministic call goes through `SessionEffects#model_call` → `EffectDispatcher.run` with a structured `logical_identity` (`session_effects.rb:19-54,135-147`), so a replay returns the receipt (`unwrap_model`, `:56-73`). The `:unknown` → human-decision path is exactly as documented: `blocked_update` writes a `blocked` record whose `actions` name `Session#resolve_effect` (`session_evidence.rb:164-181`), `SessionOutcome#blocked?` surfaces it, and the CLI prints `tamoz resolve <thread> EFFECT_KEY {succeeded|failed|abandoned}` (`cli.rb:229-235`). `resolve` refuses the word `unknown` as a *target* with a hint that it is the state being resolved (`cli_session_commands.rb:334-356`) — a deliberately correct enforcement, not a gap.

Crash-resume reconstruction is from records, not live memory. `conversation_transcript` reads the durable turn fragments through the bound checkpointer and applies the cumulative `/reset`-`/compact` offset (`session.rb:308-314`); `SessionPlanningContext.conversation_history` reconstructs prior turns from the request inbox (`session_planning_context.rb:328-330,450-478`); channel turns re-read their own payload transcript from the inbox so a re-executed node sees the same input (`:394-398,345-355`). The only *live* input I found is confessional and bounded: an aborted compaction summarizes whatever the compactor produced this run (F22-REL-03).

The effect-unanswered path is not lossy: `EffectDispatcher` grants a fresh attempt for `:idempotent` and stops `:unknown` for `:unsafe` (`effect_dispatcher.rb:139-153`), and the reconciler refuses to resolve a healthy terminal head.

## Lens: observability and evidence

`SessionStatusProjection` is a genuine bounded wire: allowlisted event kinds (`status_projection.rb:11,111-115`), allowlisted delivery/effect states with a fail-safe `'unknown'` normalization (`:12-13,125-137`), and `MAX_METADATA_BYTES = 512` `.scrub` on every metadata field (`:14,139-145`). It never carries model output. `SessionContextControls#usage_report` reports token/cost rollups as absent rather than inventing them (`session_context_controls.rb:163-180`) — the honest choice.

The gap is the *starvation* case: a claim that returns nothing because of a bounded scan is indistinguishable from an idle thread in the event stream and in `usage_report`, which exposes only `requests`, `controls`, `pinned_budgets`, `observation_bytes`, and a lifecycle-event **count** (`session_context_controls.rb:50-64,166-180`). No claim-deferred/deferred-age signal exists at any layer. F07-REL-01's remedy names a metric; the session/CLI half contributes none.

## Lens: scalability and resource bounds

Bounds are real and layered, and each is enforced at the right seam:

| Bound | Value | Cited |
|---|---|---|
| task bytes | 16 KiB | `session_bindings.rb:95-97`, `session_nodes.rb:25` |
| observation bytes per episode | 160 KiB, checked **before** dispatch (`ensure_observation_headroom`) and after (`ensure_observation_budget`) | `session_nodes.rb:24`, `session_steps.rb:93-98,276-281` |
| prompt frame | 16 KiB | `session_planning_context.rb:21,312-314` |
| observations in frame | 8 KiB, 1 KiB inline, 256 B preview | `session_planning_context.rb:22-24,192-241` |
| authoritative block | 4 KiB, per-value 2 KiB marker | `session_planning_context.rb:26,252-281` |
| compaction summary | 4 KiB | `session_planning_context.rb:25,98` |
| adaptive iterations | 3 | `session_adaptive.rb:15,40` |
| plan attempts / repairs | ≤10 / ≤10 (validated) | `session_options.rb:96-106` |
| status metadata | 512 B | `status_projection.rb:14` |
| node super-steps | `RecursionLimitError`, handled as a typed budget stop | `worker.rb:273-279` |

The uncompacted growth path still exists: `observations`/`plan_versions`/`plan_reviews`/`effect_receipts`/`lifecycle_events` are append-reduced with no element cap (`session_graph.rb:110-115,150-151`); the cap is a **serialized checkpoint byte ceiling** (`Compiled#max_bytes`, observed as `16777216` in a probe), which fails as a super-step error. `/reset` is the operator remedy (`session_context_controls.rb:109-123`).

**Pagination:** `cmd_list` globs every `*.sqlite3` in the session directory with no limit (`cli_session_commands.rb:64-79`), and `cmd_show --transcript N` defaults to 50 with no upper bound (`:108-120`). `rain` is not evidenced — no soak or load artifact exists for the session row, and I ran none (a bounded probe is not a load test).

## Lens: maintenance and architecture

Ownership is clean and the dependency direction is honest: `tamoz-agent-session` requires only core/kernel/capabilities/memory/profile/graph/tools and reaches up into nothing (`agent_session.rb:6-13`; comment `:4-5`). The node façade (`session_nodes.rb:153-174`) is a thin delegation table over ten collaborators; each collaborator owns one protocol. `Options.build` is the single construction validator.

**Top-100 finding 021 is no longer accurate and the tracker is stale.** `docs/audits/top100-audit-2026-09-11/IMPLEMENTATION.md:32` still records `| 021 | session.rb | todo | SIZE/DEAD/DUP/STATE |`, but `021-session.md` carries a "Resolution — 2026-09-12 (round 5)" section marking all five findings FIXED, and the current source agrees with the resolution, not the tracker:

- **SIZE/build_definition** — gone; no graph DSL in `session.rb`, which is 516 lines, and `SessionGraph.definition_for` owns the assembly (`session_graph.rb:15-23`).
- **SIZE/initialize** — `Session#initialize` is 28 lines (`session.rb:70-97`) delegating to `Options.build` (`session_options.rb:39-57`).
- **DEAD/`verify_graph_binding!`** — absent; `grep -rn "def verify_graph_binding" gems/ test/` returns nothing, and only `enforce_graph_binding!` remains (`session.rb:206-217`).
- **DUP/five wrappers** — collapsed onto one private `verify_binding!` (`session.rb:190-195`); the four public entry points are one-liners (`:143-182`).
- **STATE/memoized `@nodes*`** — replaced by one frozen `@nodes_by_version` (`session.rb:88,125-127`); `current_egress_pin` reads `@profile` directly (`:293-298`).

The only residual is a documentation-hygiene defect: **the tracker row was never flipped to `done`.** F22-DOC-01.

Finding **068** verified against current source: `lifecycle_event` takes `(state, context, event_type, effect_state:, **details)` = 5 parameters with the `LIFECYCLE_DETAIL_KEYS` allowlist raising `ArgumentError` on an unknown key — the typo protection the audit asked for is present and the parameter count is at the ceiling (`session_adaptive.rb:222-225,524-537`). The node-method split remains declined with the same documented justification (`:10-13`). Status **partial, justified** — no new defect. Finding **081** verified: no `/new`-generation pair in the file (only `/reset`, `/think`, `/verbose`, `/compact`, `/usage`, `/context`, `session_context_controls.rb:109-206`), and `conversation_history_for` exists as the shared helper (`:212-216`). Status **done**, confirmed.

The one structural observation I will name without grading it as a defect: **`Session` is a façade over two different lifecycles.** Six methods (`reset_episode`, `compact_transcript`, `set_reasoning_depth`, `set_answer_verbosity`, `usage_report`, `context_report`) operate on a latest-checkpoint-plus-writer model (`session_context_controls.rb:231-326`), while the rest operate on the durable-request-runner model. Both hang off one public class, and the README's verb list does not mention either set. This is design debt worth an ADR, not a finding.

## Tests and contracts

All commands `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"` then one file per command, from `/Users/ghassan/my-projects/tamoz`:

| Command | Result |
|---|---|
| `ruby -Itest test/agent_session_records_test.rb` | **15 runs / 34 assertions / 0F 0E 0S** |
| `ruby -Itest test/agent_session_operations_test.rb` | **6 runs / 36 assertions / 0F 0E 0S** |
| `ruby -Itest test/agent_session_effect_test.rb` | **19 runs / 78 assertions / 0F 0E 0S** |
| `ruby -Itest test/agent_session_adaptive_test.rb` | **6 runs / 52 assertions / 0F 0E 0S** |
| `ruby -Itest test/agent_session_test.rb` | **11 runs / 72 assertions / 0F 0E 0S** |
| `ruby -Itest test/agent_session_status_projection_test.rb` | **2 runs / 7 assertions / 0F 0E 0S** |
| `ruby -Itest test/session_context_controls_test.rb` | **10 runs / 91 assertions / 0F 0E 0S** |
| `ruby -Itest test/agent_request_routing_test.rb` | **18 runs / 232 assertions / 0F 0E 0S** |
| `ruby -Itest test/agent_non_ascii_session_test.rb` | **7 runs / 39 assertions / 0F 0E 0S** |
| `ruby -Itest test/legacy_session_resume_test.rb` | **5 runs / 28 assertions / 0F 0E 0S** |
| `ruby -Itest test/sqlite_stale_request_test.rb` | **26 runs / 176 assertions / 0F 0E 0S** |

Total: **125 runs, 845 assertions, 0 failures, 0 errors, 0 skips.**

**not run:** `test/agent_session_kill_matrix_test.rb` (real SIGTERM/SIGINT/SIGKILL to child workers; `documentation/limitations.md` records it as environment-bound and it is outside a 60-minute read-only budget). `rake ci` / `rake ci_full` deliberately not run per the environment block.

**not found:** no test asserts that `cancel` refuses, or is refused on, a terminal thread; no test asserts a session-layer rejection of a changed `profile_digest`; no test asserts a deferred-backlog bound at the session/CLI half of F07-REL-01.

**Probes (in `/tmp`, no repo writes):** `/tmp/tamoz-f22/probe_verbs.rb` and `/tmp/tamoz-f22/probe_verbs2.rb`, both driving a real `Session` over a real `Tamoz::SQLite::Adapter` with a deterministic scripted model (no real LLM).

## Findings

### F22-COR-01 — `cancel` can overwrite a completed session's terminal verdict

| Field | Content |
|---|---|
| Severity | **major** |
| Confidence | **high** — source path traced to the exact line, behaviour reproduced by probe |
| Status | **open** |
| Source evidence | `session_bindings.rb:82-88` (`cancellation_update` → `{next_node: 'terminal', terminal_reason: 'cancelled_by_user'}`) is applied in `session_bindings.rb:17-25` **before** any terminal check; `session_lifecycle.rb:46-57` then builds the `terminal` record unconditionally with the new reason; `delivery_state` upstream: `cli_session_commands.rb:182-218` (`cmd_cancel`) sends `--force` through the same `submit_cancel` |
| Test/contract evidence | Probe `/tmp/tamoz-f22/probe_verbs.rb`: after a thread reaches `terminal.reason = "check_passed"`, `view.terminal` becomes `{"record"=>"terminal", "record_version"=>2, "reason"=>"cancelled_by_user", "satisfied"=>false}` while `view.status` stays `completed` and all three `effect_receipts` stay `succeeded`. Test `not found` — no suite covers cancel-on-terminal |
| Scanner signal | none (found by reading the cancel path end to end) |
| Independent judgment | Confirmed. The verb **acts on a thread in a state that forbids it**, which is exactly the priority question asked of this row. The damage is bounded: the previous terminal verdict is still readable in checkpoint history, and the CLI renders the cancel outcome correctly (`cancel_exit`, `cli_session_commands.rb:234-239`). What is material is that the *latest* terminal record — what `Session#view`, `SessionStatusProjection`, `TerminalProgress.artifact_line`, and `settle_completed_view`'s `completion_text` all read — is replaced by `cancelled_by_user` after the work already succeeded. In the conversational path the operator then receives the cancel copy ("submit the remaining work again if it is still needed", `terminal_progress.rb:14`) for work that is finished, or a completion notification that silently drops the terminal reason it claims to report |
| Root cause | Five whys: (1) Why does a completed session end up `cancelled_by_user`? A redirect/cancel request re-enters `intake`, which overwrites `:terminal_reason`. (2) Why does `intake` not check the terminal state? `SessionBindings#intake` dispatches on `cancellation_request?(raw_task)` first and returns immediately (`session_bindings.rb:19`). (3) Why is there no check? The cancel path was designed as "a durable per-thread control message the worker applies at its next durable boundary" (`cli_session_commands.rb:220-223`), which assumes a live turn. (4) Why does that assumption hold in code? `cmd_cancel`'s `validate_cancellable!` is CLI-side and bypassable by `--force` (`cli_session_commands.rb:203-208`), and nothing at the session or graph boundary repeats it. (5) Why is nothing at the session boundary? Neither invariant 18/24 (records) nor invariant 41 (bindings) names a terminal-state monotonicity contract for control verbs, so no seam was built for it — the missing contract is "a terminal verdict is immutable except through a new turn" |
| Recommendation | Smallest action at the existing seam: in `SessionBindings#intake`, before `cancellation_update`, read the stored terminal and refuse (typed) when the session record exists and its `terminal` reason is already a satisfied terminal — or route the cancel through `SessionDeliveration#cancelled?`'s existing predicate (`session_deliberation.rb:41-44`) instead of a second, unguarded spelling of the same rule. One predicate, one place. No new machinery, no new class |

### F22-REL-01 — the session half of the F07-REL-01 starvation boundary is undocumented and untested

| Field | Content |
|---|---|
| Severity | **major** (carried forward; the defect itself belongs to F07) |
| Confidence | **high** for the boundary trace; **medium** for the end-to-end user-visible consequence |
| Status | **open**, carried forward from F07-REL-01 — the finding is not re-litigated |
| Source evidence | Session half: `session_routing.rb:238-258` (`fallback_with_records` → `next_node: 'deliberate'`), `session_bindings.rb:102-115` (`next_node: 'deliberate'`, `phase:` from `toolbox.action_capable?`), `session_graph.rb:89-97` (`successor`), `session_deliberation.rb:29-37`. Deferral half: `request_inbox_claimer.rb:216-231` (`LIMIT 8`), `:160-180` (walker), `:183-190` (`early_turn?`), `:33,36` (`EARLY_TURN_OPERATIONS = %w[turn]`, `EARLY_TURN_REASON = 'latest checkpoint is not terminal'`), `request_staleness.rb:34-40` (`turn_reason`). Draining half: `cli.rb:261-301` |
| Test/contract evidence | `ruby -Itest test/sqlite_stale_request_test.rb` → 26 runs / 176 assertions / 0F. Its early-turn case covers **one** deferred turn (`:115-149`); the FIFO-wedge case covers stale resumes that terminal-fail (`:235-267`). No case covers a backlog larger than the candidate limit. Test `not found` for the session/CLI half |
| Scanner signal | `analyses/request-claim-starvation.md:14-16` (the eight-row window and the nine-turn trigger) |
| Independent judgment | The claim is confirmed and I can now state the boundary **exactly**, which is what this row was asked for. The session's contribution is: for a routed session the route node tells the **caller** (the worker, via its request) to go to `deliberate`, not the graph. The worker's `claim_and_run` (`worker.rb:509-520`) therefore calls `run_next` for each queued `:turn`, and `run_next` returns `nil` (`durable_runner.rb:72-73`) because the claimer's eight-row window is entirely filled by turns whose only verdict is `EARLY_TURN_REASON`. **F07-REL-01's stated remedy — "make a valid queued control request for the open occurrence visible when the bounded window contains only deferrable early turns" — is therefore aimed at the right seam and needs no change**: a second, cheap targeted read for the oldest eligible `:resume` at `RequestInboxClaimer#candidate_rows` fixes the whole path, because `RequestInboxClaimer` is the single decision point that both the worker (`run_next`) and the CLI (`advance_queued_request`, `cli.rb:303-310`) ride. What the session layer fails to contribute is any statement of this fairness contract: the session half has no progress requirement, no deferred-backlog bound, and no starvation signal, so the repository does not prove that a valid resume behind a deferral backlog remains reachable. Confidence is medium only on the notification repeats: `settle_paused_view` can re-project waiting/approval per retry (`worker.rb:635-658,754-777`) but I did not exercise a production sink |
| Root cause | Five whys: (1) Why can an accepted resume sit queued forever? The bounded window never reaches it. (2) Why is the window bounded? To stop a backed-up inbox turning a claim into a table walk (`request_inbox_claimer.rb:222-224`). (3) Why is a bound acceptable? Because the early-turn deferral was justified by "unblocks whatever sits behind it … a resume … must reach the claim ahead of the next fresh turn" (`:186-188`) — a claim that is only true inside eight rows. (4) Why was that written as if unconditional? The session/route side never states how many turns one open occurrence may defer. (5) Why not? The fairness contract between the deferral policy and the control-request guarantee was never written down at either seam, so no test encodes it — the same controllable "incomplete claim-query progress contract" the F07 analysis names |
| Recommendation | No change at the session layer beyond recording the contract: keep the deferral (it is correct), and add to `documentation/architecture/invariants.md` the sentence F07's remedy implements — a valid queued control request for the open occurrence must remain claimable regardless of deferral backlog. The code fix stays where F07 put it. Adding a starvation counter to `SessionContextControls#usage_report` (`session_context_controls.rb:166-180`) is the one cheap observability contribution available at this seam and is optional |

### F22-SEC-01 — the session stores a profile authority binding it never re-verifies (session half of F21-SEC-01/F25-SEC-01)

| Field | Content |
|---|---|
| Severity | **major** as the session-layer component of two open critical findings; the end-to-end severity remains the parent findings' call |
| Confidence | **high** for what `guard_state!` does and does not check; **high** that the session layer adds no guard |
| Status | **open**, carried forward |
| Source evidence | `session.rb:439-449` — `guard_state!` runs `enforce_graph_binding!`, `enforce_skill_binding!`, `enforce_mcp_binding!`, `enforce_egress_binding!`, `enforce_behavior_binding!` and nothing else. Absence proof: `grep -rn "profile_digest" gems/tamoz-agent-session/` → `session_records.rb:52` (schema), `session_records.rb:472` (legacy default), `session_bindings.rb:57` (write), `session_planning_context.rb:434` (render) — **no comparison site**. Contrast `session.rb:219-231`: `enforce_skill_binding!` compares `stored == current` exactly, the shape a profile guard would take |
| Test/contract evidence | `not found`. `test/legacy_session_resume_test.rb` (5 runs, 0F) covers skill/record-version resume, not profile digest. `test/agent_session_operations_test.rb` (6 runs, 0F) covers backup/restore, corruption, pruning, deletion, two-owner and FD-leak — none changes `profile_digest` across resume |
| Scanner signal | Supplied by the row brief; verified independently against source |
| Independent judgment | Confirmed at the exact scope asked for. `guard_state!` checks graph/skill/MCP/egress/behavior and **never** the stored `profile_digest`. The session layer adds no guard: it relies entirely on `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:1119-1125`, which performs that digest comparison only in `child_profile_for` for **child** tasks, never for a resumed parent thread. What this adds to F21/F25 is a fourth statement of the same persistence: even a caller that constructs the session with the correct profile cannot detect that the recorded binding names a different authority. I am not re-litigating either parent finding |
| Root cause | Five whys: (1) Why is a changed profile not caught on resume? No comparison site exists. (2) Why not, when four sibling bindings have one? Each binding was added by its own phase (P9 skill, P10 MCP, P17 egress, P11-W behavior) with a `verify_*_binding!` entry point; profile binding predates that pattern (P8) and its guard was placed in the driver. (3) Why did the pattern not absorb it? `guard_state!` enumerates enforcers by hand rather than deriving them, so a binding with no `enforce_*` is invisible to the boundary. (4) Why is that acceptable today? `Options.build` verifies catalog and root **at construction** (`session_options.rb:142-176`), which covers the construction-time case and hides the resume-time one. (5) Why is resume different? Nothing in the invariant set names "a resumed session binds the exact authority it was planned under" as a session-owned rule, so the missing contract is a fifth binding check at the seam that already has four |
| Recommendation | Smallest action at the existing seam: add `enforce_profile_binding!` beside `enforce_skill_binding!` in `session.rb` (compare `record.fetch("profile_digest", LEGACY_PROFILE_DIGEST)` against `@profile&.canonical_digest`) and call it from `guard_state!` and `view`/`outcome` exactly as `enforce_graph_binding!` is. This is one method and one line at a seam that already exists — but it is an **authority** change and must be sequenced by whoever closes F21/F25 so the three sites agree on one verdict |

### F22-COR-02 — `Session#continue` on a completed thread reports success after doing nothing

| Field | Content |
|---|---|
| Severity | **minor** |
| Confidence | **high** — probe-reproduced; the cause is visible in source |
| Status | **open** |
| Source evidence | `session.rb:325-328` — `continue` calls `guard_state!` (five binding checks only) then `deliver_turn({}, …, operation: :continue)`; `request_staleness.rb:24` sends `:continue` to `status_reason(checkpoint, :running, …)`, so a completed checkpoint terminal-fails the request rather than forking. `drive_continue` (`cli.rb:249-255`) then exits `0` on `exit_for_view(view)` |
| Test/contract evidence | Probe `/tmp/tamoz-f22/probe_verbs.rb`: `continue-completed` → thread status stays `completed`; the request terminal-fails. Test `not found` |
| Scanner signal | none |
| Independent judgment | Confirmed. This is honest at the session layer (refusing to fork a finished thread is correct) but misleading at the verb layer: `tamoz continue <thread>` on a completed thread reports the completed view and exit 0 as though it had done something. It is not dangerous — nothing is mutated, no effect is re-run, the terminal record is untouched — which is why it is `minor` and not part of F22-COR-01 |
| Root cause | The verb's postcondition is "the thread advanced or the caller learns why not"; `drive_continue` returns the view without consulting `request_status`, so a stale `:continue` is indistinguishable from a no-op success. The contract that would prevent recurrence is a stated per-verb postcondition on the stale-request outcome |
| Recommendation | At `cli.rb:249-255`, surface the stale terminal-failure rather than returning the view — the mechanism already exists (`advance_queued_request` renders stale failures via `render_request_terminal_failure`, `cli.rb:303-310`). One branch, no new machinery |

### F22-REL-02 — `Session#recover` acts on a paused thread without the absence-of-interrupts precondition

| Field | Content |
|---|---|
| Severity | **minor** |
| Confidence | **medium** — the precondition violation is proven from source; I did not construct a paused-with-live-interrupts thread and drive `recover` |
| Status | **open** |
| Source evidence | `session.rb:330-338` — `recover` runs `guard_state!` then `runner_for(thread).recover(thread:, request_id:, owner_id:)` (`durable_runner.rb:104+`) and returns `outcome`. `deliver_resume` (`cli.rb:312-317`) and `drive_resume` (`cli.rb:206-225`) enforce the precondition on the **resume** path: `answers.nil? → EXIT_PAUSED`, `:blocked → report_blocked_thread`. `recover` names none of it. Worse, `recover` makes **no `view` call before recovering**, so it cannot see whether an interrupt is pending |
| Test/contract evidence | `not found` — `test/agent_session_operations_test.rb` (6 runs, 0F) covers backup/restore, corruption, pruning, deletion, two-owner and FD-leak; none drives `recover` against a live pause |
| Scanner signal | none |
| Independent judgment | Confirmed as a precondition gap on a public entry point (`Session#recover` is one of only seven public lifecycle methods). Fenced replay keeps it safe — it cannot fork an execution or double an effect — so the exposure is repeated recovery/park churn for the chat-facing paths if a caller uses `recover` where `resume` is required. I did not prove the downstream consequence, hence `medium` |
| Root cause | `recover` answers "the thread has work in flight" and `resume` answers "the thread is waiting for a human"; both were built as thin wrappers over the same runner and neither owns the shared precondition list. The contract that would prevent recurrence is that every public lifecycle entry point validates the state it accepts |
| Recommendation | At `session.rb:330-338`, mirror the guard `resume` already has: read `view` and refuse (typed) when `view.status == :paused && !view.interrupts.empty?`, pointing the caller at `resume`. Smallest possible action, no new seam |

### F22-REL-03 — an aborted `/compact` can silently substitute a later transcript summary for the one on record

| Field | Content |
|---|---|
| Severity | **minor** |
| Confidence | **low** — a reasoned lead. The code path is real; I did not induce the record/summary divergence |
| Status | **open** (lead) |
| Source evidence | `session_context_controls.rb:148-161` — `compact_transcript` captures `conversation = conversation_history_for(thread)` **outside** the writer fence (`:150`), so the bound `truncated_fragments` is measured on unfenced data, while `compact_fields` reads the pinned summary back **out of the record** (`:364-368`). `BoundedCompactor#summarize` is a journaled `model.generate.context_compact` whose logical identity carries `iteration`/`sub_operation` 0/100 (`session_planning_context.rb:68-85`), so a later `/compact` after any intervening effect can reach a distinct receipt |
| Test/contract evidence | `ruby -Itest test/session_context_controls_test.rb` → 10 runs / 91 assertions / 0F, which covers the controls' committed records and projections but not an abandoned writer followed by a second `/compact`. `not found` |
| Scanner signal | none |
| Independent judgment | Recorded as a **lead, not a proven defect**. Reasoned concern: the record's `summary_digest` is read from the record and `truncated_fragments` from an unfenced read, so the two halves of one audit record are not measured at the same instant. The rule this repository states ("a reconstruction that can silently differ from the recorded state is a major finding", and `BoundedCompactor`'s own refuse-the-mismatch shape at `session_planning_context.rb:45-48`) is exactly the rule I cannot yet show this violates. I am not raising it to `major` on an unrun probe |
| Root cause | The fence was placed around the write, not around the measurement. The contract that would prevent recurrence is that every field of one audit record is derived from the fenced source |
| Recommendation | At `session_context_controls.rb:150-151`, move the `conversation_history_for(thread)` read inside the `fields` lambda so both `truncated_fragments` and the pinned summary are measured under the same fence — the lambda already receives the locked `source` (`:151`), and `control_base` already supplies the locked view (`:289-307`). Two lines moved, no new machinery |

### F22-DOC-01 — the top-100 tracker still records `session.rb` (021) as `todo` after its resolution landed

| Field | Content |
|---|---|
| Severity | **minor** |
| Confidence | **high** — tracker line and resolution section both read; source confirms the resolution |
| Status | **open** |
| Source evidence | `docs/audits/top100-audit-2026-09-11/IMPLEMENTATION.md:32` = `| 021 | session.rb | todo | SIZE/DEAD/DUP/STATE |`; `docs/audits/top100-audit-2026-09-11/021-session.md:31-48` = "Resolution — 2026-09-12 (round 5)" marking all five FIXED; current source confirms (516 lines, no graph DSL, no `verify_graph_binding!`, one `verify_binding!`, one `@nodes_by_version`) |
| Test/contract evidence | `not found` — no test binds the tracker to the resolutions. The resolution section itself is the contract |
| Scanner signal | The row brief asked whether the top-100 finding is still accurate; this is the answer |
| Independent judgment | **The top-100 021 finding is no longer accurate against current source.** SIZE/DEAD/DUP/STATE are all resolved; the tracker row is stale. I found no *new* SIZE/DEAD/DUP/STATE defect in `session.rb`, so the correct record is `done`, not a reopened finding. What remains true is the structural observation in the maintenance lens (one façade over two lifecycles), which is design debt an ADR should own rather than a top-100 row |
| Root cause | The tracker is a hand-maintained table; its statuses are not derived from the resolution sections, so a landed round can leave the index wrong — and the index is what a later reader greps first |
| Recommendation | Flip `IMPLEMENTATION.md:32` to `done` with a note pointing at `021-session.md:31-48`. Documentation-only, one line |

### F22-DOC-02 — `limitations.md` claims invariant 18 evidence is failing while the committed audit records it passing

| Field | Content |
|---|---|
| Severity | **minor** |
| Confidence | **high** — both artifacts read; the named suite is green |
| Status | **open** |
| Source evidence | `documentation/limitations.md:56-62` ("Versioned, allowlisted records (invariant 18) … The release audit currently marks the version-refusal evidence as failing … Regenerate the audit after the environment-bound resume evidence is repaired") vs `docs/requirements-audit.json` `INV-18`: `"status": "pass"`, `"evidence_result": "pass"`, named test `test/legacy_session_resume_test.rb#test_a_newer_record_version_is_refused_before_any_field_is_read`, five supporting tests |
| Test/contract evidence | `ruby -Itest test/legacy_session_resume_test.rb` → 5 runs / 28 assertions / 0F, including `test_a_newer_record_version_is_refused_before_any_field_is_read` (`:114-122`); `ruby -Itest test/agent_session_records_test.rb` → 15 runs / 34 assertions / 0F |
| Scanner signal | The row brief asked for this reconciliation explicitly |
| Independent judgment | **The code is right and the page is stale.** The refusal order is enforced at `session_records.rb:382-393` and proven by a test that stacks three separate field-level defects behind the version check (`test/agent_session_records_test.rb:50-63`). `documentation/limitations.md:9-12` binds the page to `docs/requirements-audit.json` through `test/documentation_surface_test.rb`, so this is a real drift in a contract the repository claims to gate — but the drift is toward *over*-claiming a gap, which is why it is `minor` |
| Root cause | The page's gap set is asserted equal to the audit's gap set by test, but only for the *presence* of headings and the release-blocking set the audit measures; a page entry whose audit counterpart has since passed is not detected. The contract that would prevent recurrence is a bidirectional check between the page's gap headings and the audit's failing entries |
| Recommendation | Correct the invariant-18 paragraph of `documentation/limitations.md` to match `INV-18`'s committed `pass`, and (optionally, in the same edit) note the environment-bound resume evidence the paragraph actually refers to under the existing durable-effect entry. Documentation-only |

Carried forward, verified against current source, not re-litigated:

| ID | Status now |
|---|---|
| F07-REL-01 (major) | open — session half traced and bounded in F22-REL-01; no session-layer guard exists, and none is needed once F07's remedy lands |
| CF04-REL-01 (major) | open, unchanged. No session-layer defence: `SessionSteps#build_effect_receipt` and `SessionAdaptive#receipt` faithfully record whatever `outcome.error` the dispatcher returns (`session_steps.rb:246-261`, `session_adaptive.rb:485-501`), and `SessionEvidence#repairable_outcome?` reads `outcome.error` too (`session_evidence.rb:88-91`) — so the nil-error failed replay is recorded and classified, not masked |
| F21-SEC-01 / F25-SEC-01 (critical) | open, unchanged; session-layer component stated as F22-SEC-01 |
| CF05-SEC-01 (major, contract) | open, unchanged. `SessionAdaptive#decision_prompt` merges the configured MCP planning surface beside the restricted discovery names (`session_adaptive.rb:229-253`, `session_effects.rb:337-342`), and `allowed_tool_names(:discovery)` is the only filter (`session_adaptive.rb:231`) |
| F07-SEC-01 (critical) | open, unchanged; session adds no guard (see security lens) |

## Blind spots

- **`test/agent_session_kill_matrix_test.rb` not run.** It is the repository's only real-signal crash evidence for sessions, and `documentation/limitations.md:34-45` records it as environment-bound. My reliability conclusions rest on source and on the non-crash operation suite, not on a kill.
- **No worker-level or sink-level probe.** I traced `Worker#settle`. I did not run a worker loop or inspect a production sink, so the user-visible duplication risk in F22-REL-01 stays `medium`.
- **`tamoz-agent` / `tamoz-agent-cli` were read, not audited.** `worker_runtime.rb`, `worker.rb`, `cli.rb`, and `cli_session_commands.rb` are cited for the boundary and for the verb surface; they are rows F24/F25 and my statements about them are limited to the exact lines cited.
- **`Tamoz::Graph::DurableRunner` / `Compiled` / `RequestStaleness` likewise.** The resume/replay conclusions depend on them and they are not F22's surface.
- **No load or soak run.** The scalability lens's bounds table is proven by source; the growth path and the pagination gaps are read, not measured.
- **F22-REL-03 was not reproduced.** It is recorded as a `low`-confidence lead, deliberately not promoted.

## Verdict

**IMPROVE** — counts: **critical 0, major 3, minor 5, info 0** (F22-COR-01 major; F22-REL-01 major carried forward; F22-SEC-01 major as the session-layer component of two open critical parent findings; F22-COR-02, F22-REL-02, F22-REL-03, F22-DOC-01, F22-DOC-02 minor).

All six lenses reviewed: correctness **reviewed**, security/authority **reviewed**, reliability/durability **reviewed**, observability/evidence **reviewed**, scalability/resource bounds **reviewed** (bounds proven by source; load/soak `not evidenced` — no soak artifact exists for this row and I ran none, which a bounded probe cannot substitute for), maintenance/architecture **reviewed**.

Per BAR.md, `IMPROVE` is met by the accepted critical/major findings. The record layer (invariant 18), the five binding guards that exist, the effect/journal boundary, the credential gates, and the bounded status wire are sound and directly tested; the defects are concentrated in the **verb state contract** (F22-COR-01/COR-02/REL-02), the **authority binding the session stores but never checks** (F22-SEC-01), and two **tracker/documentation drifts** that misstate the row's real state.

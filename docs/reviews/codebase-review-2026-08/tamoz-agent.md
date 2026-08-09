# Codebase Review — gems/tamoz-agent

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md).*

## Overall assessment

Reviewed the entrypoint, CLI surface (7 modules), Session/SessionNodes/Runtime/Deliberation/EffectDispatcher, Worker/WorkerRuntime, Profile, CapabilityBinding, Memory::Admission, Improvement::Promotion, Healing::Rule, plus `.rubocop_todo.yml` debt. The dominant theme is fail-open error handling in `WorkerRuntime` — budget and operator-store reads that convert storage failures into "nothing spent" / "no record" — which silently disables the durable gates on unattended work. Structurally, `SessionNodes` (1,450 lines) is the debt epicenter, and `.rubocop_todo.yml` carries ~750 lines of excludes heavily weighted to this gem.

## High

### H1 — Budget enforcement fails open on storage errors

`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:186-193`. `budget_usage` rescues `StandardError` and returns `{"model_calls" => 0, "wall_clock_seconds" => 0.0}`. A SQLite failure therefore reads as "nothing spent", and `Worker#exhausted_budget` never trips — the one durable gate on unattended spend silently disables itself exactly when the store is unhealthy. §8 ("authority… never widens"; §7 "don't swallow errors") calls this a defect.

**Fix:** propagate (or return `nil` and treat as "stop the occurrence"), never zeros; emit a typed event.

### H2 — `thread_budgets` also fails open

`worker_runtime.rb:179-184`. Rescues to `nil`, which `Worker#exhausted_budget` (worker.rb:259-261) reads as "profile sets no enforceable budget". Same class as H1: a profile read error converts "bounded" into "unbounded".

**Fix:** let the error reach `advance_thread`'s containment rescue and park the thread.

### H3 — Blanket `rescue StandardError → nil/[]` hides corruption across the operator store

`worker_runtime.rb:113,122,147,154,162,201,219,248,264,287` and `cli_worker_commands.rb:257`. `close_occurrence`, `occurrence_for`, `decision_for`, `thread_profile`, `capability_catalog`, `paused_approvals` all swallow every error class. `decision_for → nil` means a human's recorded approval becomes invisible on a transient read error (work stays parked forever, silently). The standard's rule "a guard that swallows an unreadable record fails *open*" (session.rb:224-227 — the codebase states this principle itself) is violated here.

**Fix:** rescue the specific store errors, or propagate and park with a `reason`.

### H4 — Memory layer reaches up into SessionNodes for its behavior version

`memory/admission.rb:122,316`, `memory/consolidation.rb:257`, `memory/surface.rb:114,134`, `memory/behavior_transition.rb:117`. Five memory-layer files reference `SessionNodes::BEHAVIOR_VERSION`. Memory is presented as the lower layer (SessionNodes already depends on Memory); this is a package-level cycle by constant reference — exactly what `enola check --fail-on=cycles` exists to catch, and load-order isolation won't see it (§6.1: "assert the reference directly").

**Fix:** move `BEHAVIOR_VERSION` to a neutral home (e.g. `Tamoz::Agent` or core) and have both read it.

### H5 — `WorkerRuntime` uses `Digest::SHA256` without requiring `digest`

`worker_runtime.rb:105`. Only `require "time"` at the top (worker_runtime.rb:3). It works today because `session_records.rb` is loaded first via `agent.rb`; any direct load of this file raises `NameError`. Violates §2 ("require at the top of a file" — each file declares its own deps).

**Fix:** add `require "digest"`.

## Medium

### M1 — `SessionNodes` is a 1450-line god object; `deliberate` alone is ~195 lines

`session_nodes.rb:19`, `session_nodes.rb:298-492`, `step_gate` at 494-574, `step_execute` at 576-671. §2's ~250-line signal and Q6 ceilings (method ≤ 20/30, class ≤ 250) are exceeded by ~6×; the debt sits in `.rubocop_todo.yml` (Metrics/ClassLength, MethodLength, AbcSize excludes). The plan/review loop in `deliberate` mixes protocol parsing, credential screening, structural review, semantic review, interrupts, and record-building — the canonical §4 violation ("policy, persistence, orchestration and rendering").

**Fix:** extract a `PlanAttempt`/`DeliberationLoop` collaborator per attempt (parse → structural → semantic → route), leaving `deliberate` as the loop skeleton.

### M2 — Runtime and SessionNodes keep two copies of the tool-failure evidence contract

`runtime.rb:416-445` vs `session_nodes.rb:1105-1160`. `tool_failure_observation`, the failure-signature digest recipe, the "Tool X was rejected…" output text, and `resolved_effect_arguments` (runtime.rb:455-468 vs session_nodes.rb:972-983) are byte-for-byte duplicated; the comment at runtime.rb:414 admits "the two drivers must never disagree". Deliberation was extracted for exactly this reason; these four weren't.

**Fix:** move failure-record construction and digest resolution into `Deliberation` (or a `ToolFailureEvidence` value) with both drivers calling it.

### M3 — New file `cli_session_commands.rb` ships with 9 blanket `:reek:` suppressions and a module-level Metrics disable

`cli_session_commands.rb:7-17`. Standard §1: "no new smell in changed production code" and "an exception is written at the site, not hidden in a file". Nine up-front suppressions (`UtilityFunction`, `FeatureEnvy`, `TooManyStatements`…) on *new* code is the ratchet being pre-emptively defeated. It also uses single-quoted strings throughout while every sibling CLI module uses double quotes.

**Fix:** fix or individually justify the smells; normalize quoting to match the module family.

### M4 — `WorkerRuntime#profile` memoizes without the mutex the class itself established

`worker_runtime.rb:312-329` vs `@monitor`-guarded `session_for_profile` (274-277). With `concurrency > 1` two threads can `Profile.load` the same id concurrently; `Profile.load` writes the adoption registry (profile.rb:232), so the race is a concurrent file write, not just wasted work.

**Fix:** move the memo under `@monitor.synchronize`.

### M5 — `Worker#settle`'s failed branch reads a method that doesn't exist

`worker.rb:390`. `view.respond_to?(:error) ? view.error.to_s : "failed"` — `SessionView` (session.rb:25-40) has no `error` member, so the true branch is dead and every failure reports the bare string "failed". Either dead code or a sign the view should carry the terminal error.

**Fix:** drop the branch or add the failure reason to `SessionView`.

### M6 — Effect journal census scanned in Ruby per settle

`worker_runtime.rb:187-189`. `budget_usage` loads the entire effect census and filters in Ruby, per thread, per settle — O(journal) per occurrence, and it grows unboundedly with history.

**Fix:** push the `thread_id`/`operation LIKE 'model.generate%'` filter into the store query.

## Low

- **L1 — `Tamoz::Agent::ROOT` is dead.** `gems/tamoz-agent/lib/tamoz/agent.rb:38`. No references anywhere in the repo. **Fix:** delete it.
- **L2 — Double `private` declaration.** `session_nodes.rb:780` and `:834` (already a `Lint/UselessAccessModifier` todo entry). **Fix:** merge the two sections.
- **L3 — `CLI#answer_for` emits an audit event with hard-coded `"unknown"` thread/request ids.** `cli.rb:440-448`. An audit record that cannot name its thread is not an audit record; the ids are available from the interrupt. **Fix:** pass `interrupt`'s task context through.
- **L4 — `Session#outcome` silently tolerates a missing request.** `session.rb:532,563`: `request&.status` yields `nil` request_status with no signal that the durable inbox disagreed with the run. **Fix:** raise or record the inconsistency.
- **L5 — `HealingRule#initialize` is a 24-keyword constructor doing all validation inline.** `healing/rule.rb:85-152`. Within the hard ceilings but ~70 lines of kwarg plumbing; the `validate_*` family below it is fine, but the `super(...)` call is unreadable and `to_init_hash`/`from_h`/`to_h` repeat the 24-field list four times — a schema drift hazard (one list updated, three stale). **Fix:** generate `to_h`/`to_init_hash` from the Data members list.
- **L6 — `McpCapabilitySource`-style duck-type check is split across two places.** `session.rb:120-133` lists 13 required methods inline; `CapabilityBinding#mcp_descriptor` (capability_binding.rb:205-223) re-derives a subset with `optional()`. Two definitions of one contract; adding a method to the source requires editing both. **Fix:** name the contract once (constant list) and share it.
- **L7 — `CLI#run`'s rescue ladder encodes taxonomy knowledge in comments.** `cli.rb:63-74`. Three separate rescue clauses for what is conceptually "a tamoz domain error", because the P16 move to core broke the common ancestor. **Fix:** give the moved `Tamoz::Core::ToolError` family a shared ancestor with `Tamoz::Agent::Error` (or one `handle_fatal_error` list), so the ladder can't drift.
- **L8 — Session-graph definition is built per `Session` instance.** `session.rb:112-113`: `build_definition` is a pure function of the nodes' methods, yet every Session compiles a fresh graph definition and app. Sessions are cached per profile in WorkerRuntime, so impact is bounded, but `Session.new` in a loop (tests, `build_list_session`) pays full compile each time. **Fix:** memoize the compiled definition shape or document the cost.

## Gem-boundary assessment

- The `agent.rb:47-52` constant rebindings (`Toolbox = Tamoz::Tools::Toolbox` etc.) are documented, deliberate, and object-identical — acceptable, though they keep the `Tamoz::Agent::Tool*` spelling alive purely for error-identity compat; the mapping through `Tamoz::Core.serialized_tool_error_name` (session_nodes.rb:531, effect_dispatcher.rb:192) is the third place that spelling is maintained (see L7).
- `WorkerRuntime` is the only agent file that opens a database and defers `require "tamoz/sqlite"` correctly; boundary respected.
- `Deliberation` (pure prompt/parse/canonical functions) is a candidate for tamoz-core/tamoz-tools eventually, but it currently depends on `Plan`, `ToolError`, and `Toolbox`, so extraction would pull half the agent with it — not recommended now.
- `.rubocop_todo.yml` carries ~750 lines of excludes, heavily weighted to this gem (cli.rb appears under at least 8 cops including Metrics/ClassLength, BlockNesting, AbcSize). That's chartered legacy debt, but M1 is its epicenter and should be the next remediation slice.

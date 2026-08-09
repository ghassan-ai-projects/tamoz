# Codebase Review — Cross-cutting (all gems)

*12-agent codebase review, 2026-08. See [INDEX.md](INDEX.md). Scope: duplication between gems, inconsistent patterns (error handling, logging, config), public API surface consistency, gemspec/dependency hygiene, and whether any code should move to a different or new gem. The reviewer read `docs/CODING_STANDARD.md` and surveyed all nine gems (enola was unavailable in the review subagent, so findings are from direct reading).*

## Overall assessment

The most damaging cross-cutting pattern is fail-open error handling in `WorkerRuntime`'s budget-authority code — a storage hiccup silently grants unlimited model calls. The error taxonomy is fragmented: base classes root at different ancestors across gems and several error-class names are duplicated across gems, so `rescue Tamoz::Error` is unreliable and error identity (§7 public API) is ambiguous. On the positive side: the `verify_*_binding!` / `enforce_*_binding!` pairs in `session.rb:175-300` follow §3.1's handoff rule correctly; the `Tamoz::Agent::Toolbox/Skills/ToolError` constant rebindings (`agent.rb:47-52`) and `TOOL_ERROR_CLASS_NAMES` are documented durability shims, not leaky deps; gem boundary direction (core ← tools/graph ← sqlite ← agent, mcp off to the side) matches §6.1 as declared, with no upward requires found.

## High

### H1 — Budget-authority code fails open on error

`gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:182-187`: `budget_usage` rescues bare `StandardError` and returns `{"model_calls" => 0, ...}`. Any census/store error resets the measured budget to zero while the file's own comment (line ~170) states "the agent may never widen its own budget" — a storage hiccup silently grants unlimited model calls. Same swallow pattern in `thread_budgets` (:179), `occurrence_age_seconds` (:200), `open_occurrences` (:161), `occurrence_for` (:154), `close_occurrence` (:147), `schedule_payload` (:113). (Same finding as tamoz-agent H1–H3.)

**Fix:** rescue the typed store errors only, and treat unknown errors as *budget unknown → refuse*, never zero.

### H2 — `tombstone_schedule` swallows a failed delete

`worker_runtime.rb:119-123`: if the `delete` of `SCHEDULE_PAYLOADS` raises, the tombstone is written but the payload survives, so a re-added schedule with the same id can inherit the removed one's task — exactly what the comment says the tombstone prevents.

**Fix:** let the delete failure propagate (or order tombstone-after-delete and raise on partial state).

### H3 — Error hierarchy is split, so `rescue Tamoz::Error` is unreliable cross-gem

Scheduler and stream root their trees at `StandardError` (`gems/tamoz-scheduler/lib/tamoz/scheduler/errors.rb:7`, `gems/tamoz-stream/lib/tamoz/stream/errors.rb:8`) while sqlite and mcp root at `Tamoz::Error` (`gems/tamoz-sqlite/lib/tamoz/sqlite/error.rb:5`, `gems/tamoz-mcp/lib/tamoz/mcp/errors.rb:7`). Core itself splits further: `ConfigurationError`, `GraphDefinitionError`, `InvalidUpdateError < StandardError` at `gems/tamoz-core/lib/tamoz/error.rb:217,226,235`. No single rescue covers the runtime.

**Fix:** root every gem's base error at `Tamoz::Error` (it's a wire-visible identity decision — needs a migration note per §7).

### H4 — Duplicate error-class names across gems

`LeaseLostError` exists in both core (`error.rb:158`) and scheduler (`errors.rb:20`); `ClockRollbackError` in stream (`errors.rb:38`) and sqlite (`error.rb:33`); `StoreConflictError` in core (`error.rb:179`) and scheduler (`errors.rb:14`). Two distinct public classes with one name breaks §7's "error identity is public API" and makes logs/dedup ambiguous.

**Fix:** scheduler/stream subclasses should inherit the core classes instead of redefining them.

## Medium

### M1 — `"sha256:#{Digest::SHA256.hexdigest(domain + ...)}"` hand-rolled ~94 times across six gems

e.g. `gems/tamoz-tools/lib/tamoz/tools/skills.rb:96`, `gems/tamoz-scheduler/lib/tamoz/scheduler/occurrence.rb:38,46`, `gems/tamoz-mcp/lib/tamoz/mcp/catalog.rb:217,226`, `gems/tamoz-sqlite/lib/tamoz/sqlite/wire.rb:70`, `gems/tamoz-stream/lib/tamoz/stream/event_envelope.rb:31,38`, `gems/tamoz-core/lib/tamoz/circuit.rb:83`. Every digest site re-implements domain separation inline; a typo'd domain or a missing `.b` is a silent wire-format fork.

**Fix:** one `Tamoz::Core.digest_of(domain, bytes)` helper (tools/skills.rb:96 already has the right shape — promote it) and route all sites through it.

### M2 — Three canonicalizers, three deep-freezers

`Tamoz::Core.canonical`/`deep_freeze` (`gems/tamoz-core/lib/tamoz/core.rb:50,67`), `Tamoz::Mcp::CanonicalJSON` (`gems/tamoz-mcp/lib/tamoz/mcp/canonical_json.rb:13`, comment says "duplicated deliberately" from evals), `Tamoz::Evals::CanonicalJSON` and `Tamoz::Evals::DeepFreeze` (`gems/tamoz-evals/lib/tamoz/evals/deep_freeze.rb` — note it freezes *in place* and doesn't stringify keys, unlike core's). Core already hosts the shared NFC-less canonical for tools+agent; the NFC/scrub canonical used for durable digests should live in core too so mcp (which depends on core) stops mirroring evals.

**Fix:** move the strict canonicalizer to tamoz-core; leave evals consuming it or pinned against it by a conformance test.

### M3 — Agent rescues the SQLite driver's exception directly

`gems/tamoz-agent/lib/tamoz/agent/cli_session_commands.rb:71` and `cli_rendering.rb:180` rescue `SQLite3::Exception`, reaching past tamoz-sqlite's own `ExceptionMapper` (`gems/tamoz-sqlite/lib/tamoz/sqlite/exception_mapper.rb`) to the raw driver — and `sqlite3` isn't even an agent gemspec dependency (transitive via tamoz-sqlite).

**Fix:** tamoz-sqlite should map all driver exceptions into `Tamoz::SQLite::Error`; agent rescues only that.

### M4 — `Tamoz.configuration` is ambient mutable global state

`gems/tamoz-core/lib/tamoz/configuration.rb:82-126`: module-level ivars + mutex + `configure`/`finalize_configuration!`, directly against §5 "explicit collaborators over memoized globals". The generation-check/finalize dance is thoughtful, but every consumer reads the ambient default instead of receiving a collaborator.

**Fix:** pass `Configuration` explicitly; keep the global only as a deprecated shim, or document why this is the one admitted global (the way `Lint/RescueException` exceptions are admitted).

### M5 — Inconsistent gemspec version-pinning idiom

`gems/tamoz-mcp/tamoz-mcp.gemspec:6` requires core's version file and pins `tamoz-core = Tamoz::Core::VERSION`, while scheduler/stream/tools/graph pin `= <own>::VERSION`, assuming lockstep. Either is fine; both is a drift hazard.

**Fix:** pick one idiom in `gemspec_helper.rb`.

### M6 — tamoz-agent references `Tamoz::Core` constants without declaring the dependency

`gems/tamoz-agent/lib/tamoz/agent/session.rb:238` (`Tamoz::Core::LEGACY_SKILL_EPOCH`), `gems/tamoz-agent/lib/tamoz/agent.rb:50-52` (core tool-error classes), but the gemspec depends on core only transitively through tools/graph/sqlite.

**Fix:** add `tamoz-core` as a direct runtime dependency (§10 hygiene: direct reference ⇒ direct dep).

### M7 — `cli_session_commands.rb` opens with eleven `:reek:` suppressions + a `Metrics/ModuleLength` disable

`gems/tamoz-agent/lib/tamoz/agent/cli_session_commands.rb:7-17`. This is new, uncommitted code; §1 says an exception carries its reason at the site (it does), but eleven suppressed smell classes on one extraction module is the extraction relocating smells rather than resolving them (§6 banned "concerns that merely relocate methods" is the adjacent principle).

**Fix:** address `DataClump`/`LongParameterList` by introducing a command-context value instead of annotating them away.

## Low

- **L1 — Stale constant names in tamoz-tools error messages.** `gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:90`, `skills/catalog.rb:19`, `skills/compiler.rb:49` name `Tamoz::Agent::Skills::SkillSnapshot`/`SkillSource` in raise messages, but the classes are `Tamoz::Tools::Skills::*` and tamoz-tools cannot load agent (the alias only exists when agent is loaded, so the message references a constant that may not resolve). **Fix:** use the `Tamoz::Tools::Skills::*` spellings.
- **L2 — Demeter chains through the compiled app.** `gems/tamoz-agent/lib/tamoz/agent/session.rb:229-232`: `@app.checkpointer.latest(...)` then `@app.snapshot(snapshot).state` then `SessionRecords.load_state!` — agent reaches two levels into graph internals; also `:469,488`. **Fix:** one `Session#stored_state_snapshot(thread)` seam on the graph public API (or accept and document the chain).
- **L3 — Agent entrypoint bypasses Zeitwerk.** `gems/tamoz-agent/lib/tamoz/agent.rb:3-34` lists 30 explicit `require_relative`s while core uses Zeitwerk (`gems/tamoz-core/lib/tamoz/core.rb:29-35`); §2 says entrypoints "load the namespace, let Zeitwerk resolve the rest" (same in evals.rb:5-28, though evals sits outside the runtime graph). **Fix:** Zeitwerk-loader for agent, or document why agent is exempt.
- **L4 — Text-scrub helpers duplicated.** `Skills.describe` (`gems/tamoz-tools/lib/tamoz/tools/skills.rb:175-177`), `Tamoz::Error`'s scrub logic (`gems/tamoz-core/lib/tamoz/error.rb:66-69`), `toolbox.rb:1069`, `skills/values.rb:85` each hand-roll bounded-scrub of untrusted text; core's `SafeText` (`safe_text.rb`) is private and validation-only. **Fix:** one public `SafeText.scrub(value, max_bytes:)` in core consumed everywhere untrusted text is bounded.
- **L5 — `session_nodes.rb` at 1450 lines, `checkpoint_store.rb` at 1759.** §2's ~250-line signal is long past; these are the known Q-program hotspots, but `session_nodes.rb` mixes node definitions, binding checks, and rendering, and `checkpoint_store.rb` mixes SQL, wire codec, and fence policy despite `CheckpointWire`/`CheckpointWriter` already existing. **Fix:** continue the extraction slices; no new behavior should land in these files.
- **L6 — Evals harness hard-codes the agent alias for a tools concept.** `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb:1592-3119` uses `Tamoz::Agent::Skills::*` (the alias) rather than `Tamoz::Tools::Skills::*`, coupling evals to agent for something tools owns. **Fix:** reference the tools constants.

## Notes (checked, not findings)

- The `verify_*_binding!` / `enforce_*_binding!` pairs in `session.rb:175-300` follow §3.1's handoff rule correctly (verify loads evidence, enforce consumes it).
- The `Tamoz::Agent::Toolbox/Skills/ToolError` constant rebindings (`agent.rb:47-52`) and `TOOL_ERROR_CLASS_NAMES` are documented durability shims, not leaky deps.
- Clock duplication suspected between core/stream was unfounded — stream's WallClock/ReplayClock is a domain clock with different semantics.
- Gem boundary direction (core ← tools/graph ← sqlite ← agent, mcp off to the side) matches §6.1 as declared; no upward requires found.

# Execution — session/capabilities + cancellation/concurrency gem splits

Branch: `decomposition/session-capabilities-concurrency` · Started: 2026-08-24
Implements [`docs/session-gem-assessment-2026-08-24/PLAN.md`](../session-gem-assessment-2026-08-24/PLAN.md)
(K1 → PA → PB) and [`docs/concurrency-signals-gems/FINDINGS.md`](../concurrency-signals-gems/FINDINGS.md)
(Track B). Owner named the Track-B substrate gem **`tamoz-cancellation`**
(FINDINGS §6 option 1) via the naming question posed at kickoff.

## Ground truth established before any move (2026-08-24, this branch)

- **Pre-existing red suites (standalone, clean main):** `agent_cli_mcp_test`
  (3 failures), `evals_verifier_test` (1), `benchmark_holdout_test` (1),
  `agent_latency_smoke_test` (2). These are environment/pin drift, not
  decomposition regressions; they are the parity set — identical red is
  acceptable, any NEW red is not.
- **Quality baselines were stale on merged main:** `.rubocop_todo.yml` had zero
  entries for the post-decomposition gem paths (kernel/memory/profile/… moved
  without regenerating), and `docs/code-quality-baseline.json` had no reek
  ledger for them either. Both regenerated on current HEAD as commit Q0 so the
  ratchets grade this work truthfully.
- **Sandbox note:** rubocop's result cache cannot write to `~/.cache` here;
  run gates with `XDG_CACHE_HOME=/private/tmp/xdg-cache`. Not a repo defect.

## Order

| # | Phase | Content | Commit(s) |
|---|---|---|---|
| Q0 | hygiene | regenerate `.rubocop_todo.yml` + quality baseline; drop one stale disable/enable pair in `session_steps.rb` | 1 |
| K1 | inversion fixes in place | `MAX_TASK_BYTES` / `MAX_OBSERVATION_BYTES` / `MAX_REPAIR_ATTEMPTS` move from `Runtime` down to `SessionNodes`; `SessionRecords.digest` documented public | 1 |
| PA-A | extract `tamoz-agent-capabilities` | 5 planned files **+ `child_task.rb` + `child_task_dispatcher.rb`** (see deviations); full wiring checklist | 1 |
| PA-B | simplify | `CapabilityBinding.build` facade question answered; enola findings resolved | 0–1 |
| PB-A | extract `tamoz-agent-session` | 16 `session*.rb` files verbatim; CLI gemspec edge; wiring | 1 |
| PB-B | simplify | `SessionRecords.load!` complexity 21 reduced at its new boundary | 1 |
| C1 | extract `tamoz-cancellation` | `CancellationToken` moves file+gem (constant path unchanged); adds `Cancellation::Trap`, `Cancellation::ProcessGroup`, `Cancellation.interruptible_sleep` | 1–2 |
| C2 | extract `tamoz-concurrency` | `Pool`, `StreamSink`, graph's `EventStream`, join helper; `Concurrency::Drain` skeleton + tests | 1–2 |
| C3 | adopt | exporter/journal onto Drain; CLI traps onto `Trap`; supervisor/check_runner onto `ProcessGroup`; sleep-to-deadline onto `interruptible_sleep` where clean | 1–2 |
| Z | finish line | full-gate parity vs baseline, docs reconciled, state doc resume point | 1 |

## Design corrections to the source docs (recorded up front)

1. **No alias-in-core for the moved primitives** (FINDINGS §5 step 1/2).
   Aliases would force `tamoz-core ⇄ tamoz-cancellation` mutual gem deps —
   rubygems cannot install that. Instead the constant paths never move
   (`Tamoz::CancellationToken`, `Tamoz::Pool`, `Tamoz::StreamSink`,
   `Tamoz::Graph::EventStream` stay exactly as they are); only the FILES change
   gems, and each consumer gem declares the explicit dependency. Same zero
   call-site churn, no cycle.
2. **Error classes stay in core; concurrency depends on core** for
   `PoolCircuitOpenError` etc. Acyclic: `concurrency → cancellation → core`.
   (FINDINGS' diagram had signals→core AND core→signals-via-alias.)
3. **child_task pair joins capabilities** (deviation from PLAN "what stays").
   Evidence: `capability_binding.rb:3` hard-requires `child_task_dispatcher`;
   `CapabilityBinding` constructs it and names its tool. Consumers after the
   move point DOWN only: worker_runtime (agent) → capabilities. The child-task
   DRIVER (`child_environments.rb`, execution side) stays in `tamoz-agent`.

## The bar (definition of done — all must hold at finish)

1. Four new gems exist with the full shipped-convention wiring: gemspec via
   `TamozGemspec.build` + lockstep literal VERSION, `version.rb`, LICENSE,
   README stating public surface, umbrella require, Gemfile entry,
   `GEM_ROOTS`, both `packaging_test.rb` lists, `dependency_isolation_test`
   lists, `docs/public-api.json` package section (its test asserts
   `GEM_ROOTS.keys == packages.keys`).
2. Every pre-existing constant path still resolves at every existing call
   site (no source churn beyond documented rewiring).
3. Frozen public surfaces verified per phase: worker/runtime facade +
   CLI-reaching symbols (PLAN PB table) unchanged through PB.
4. Gates: `quality:rubocop_gate` 0 offenses; `quality:reek` no new smell vs
   regenerated baseline; `enola check` no cycles/layers; per-phase named gate
   suites green; parity set red *identically*; final `rake ci` failure set ⊆
   recorded baseline failure set.
5. Stage B of each phase resolves its named target (facade answer,
   `load!` complexity, Drain duplication) rather than relocating it.
6. Docs reconciled: README component map, `documentation/architecture/gems.md`,
   this directory's outcome notes, QUALITY_PROGRAM_STATE resume point.
7. Everything committed; history reads as one commit per stage.

## Deviations log

- **Q0 scoped down (honest):** `.rubocop_todo.yml` regenerated and committed;
  the reek/code-quality baseline regeneration is BLOCKED on this machine
  because `RUN_COVERAGE=1 rake test` fails on main for pre-existing,
  coverage-timing/environment-bound reasons (23 failures across 11 classes,
  e.g. WebsearchEgress ×8 network-sandbox-bound; a CLI resume thread dying on
  CheckpointConflictError under instrumentation timing). The committed
  `docs/code-quality-baseline.json` therefore remains stale repo-wide
  (`quality:reek` red at HEAD before any of this branch's work). Per-phase smell
  discipline is enforced by targeted per-file reek parity instead; the global
  ratchet needs a machine where the coverage suite passes.
- **PA file list:** child_task.rb + child_task_dispatcher.rb moved into
  tamoz-agent-capabilities (capability_binding hard-requires and constructs
  them); child_environments.rb stayed (driver-side only).
- **PA gemspec deps:** core/mcp/kernel/tools — no profile dep (grep-proven);
  tools added at review (CapabilityHost/LocalDispatcher constructed directly).
- **PA Stage B resolution (no code change needed):** `CapabilityBinding.build`
  is a real assembler (partitions toolbox names, builds sources, binds
  dispatchers into Tamoz::Tools::CapabilityHost, freezes) — not a re-export
  facade; README documents the responsibility. The private `deep_freeze`
  variant in mcp_capability_source differs semantically from core's (does not
  freeze containers, silently passes unsupported types) so folding would change
  behavior; PLAN conditioned the fold on enola flagging it, and enola did not.
- **Review findings fixed post-PA (commit 58896dc):** COR-1 umbrella tool-error
  rebindings; COUP-1 requirements manifest+audit regeneration (a committed
  SERIAL test was statically red at HEAD — packaging flips must regenerate
  derived artifacts together, fcb3e93 precedent); ARCH-1 isolation guard test;
  COUP-3 README deps. Recorded-not-actioned: COR-2, COUP-4, DUP-2, ARCH-2.
- **Process rule learned:** while implementation agents share the tree, the
  integrator commits with explicit pathspecs ONLY (a bare `git add -A` +
  commit briefly swept the in-flight PB renames into a review-fix commit;
  caught and separated via soft reset within the same minute).

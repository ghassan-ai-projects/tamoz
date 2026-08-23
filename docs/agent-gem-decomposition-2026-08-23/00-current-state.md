# 00 — Current state of `tamoz-agent`, measured

All numbers below are from the current working tree on branch
`redesign-approval-policy` (enola snapshot of 2026-08-23 + `wc`/`grep`). They
are here so the topology in [01](01-target-topology.md) can be judged against
facts rather than intuition.

## Size

- **139** Ruby files, **30,067** lines under `gems/tamoz-agent/lib`.
- Current gemspec dependencies: `tamoz-tools`, `tamoz-graph`, `tamoz-sqlite`,
  `tamoz-comms`, `tamoz-approval`, `tamoz-observability`, `ruby_llm`.
- Ships one executable, `exe/tamoz`, which is a five-line shim:
  `require "tamoz/agent"; exit Tamoz::Agent::CLI.run`.

## What enola flags

From `query_insights(repo: tamoz-agent)`:

- **1 coupling cluster of 31 modules** (cycles explainer, confidence 0.40) —
  the runtime core is a tightly interwound ball. This is the strongest single
  argument for carving stable, one-directional seams.
- **God-class / high-fan-in:** `Tamoz::Agent::Deliberation` (20 dependents),
  `Deliberation.canonical` (14). The plan/review/execute/verify engine is
  reached from all over.
- **Hotspots (fan-in / fan-out):** the `Tamoz::Agent` namespace itself
  (25 / 66), `Tamoz::Agent::Profile` (5 / 106), `Deliberation` (20 / 23).
  `Profile`'s fan-out is a 566-line facade re-exporting its subtree.
- **Complexity outliers:** `Deliberation.structural_issues` (21),
  `SessionRecords.load!` (21), `EffectDispatcher.run` (16),
  `Worker#advance_thread` (15).

None of these are blockers; they are a map of where the mass is.

## The natural clusters (by directory / prefix)

| Cluster | Files | Lines | Shape |
|---------|------:|------:|-------|
| `memory/` (+ `memory.rb`) | 14 | 2,804 | Engine facade + admission/retrieval/lifecycle/consolidation/transitions/wisdom + record & error values |
| `healing/` (+ `healing.rb`) | 24 | 3,303 | Rule/registry, classification, remediation session + step builders, preflight, oracle, promotion gate, seams |
| `improvement/` (+ `improvement.rb`) | 11 | 1,814 | Candidate lifecycle/policy, generator, heuristic, evaluation report, provenance, promotion, monitor |
| `profile/` (+ `profile.rb`) | 15 | 2,444 | Document/authority/egress/check validators, secure file, locations, adoption & transition registries |
| `cli*.rb` | 14 | 4,102 | Argument parsing, option policy, rendering, and the worker/schedule/profile/session/comms command groups |
| `session*.rb` | 16 | 5,054 | The per-session state machine: records, nodes, steps, routing, planning context, adaptive, effects, evidence, lifecycle, memory bridge |
| deliberation kernel | ~20 | ~3,799 | `episode_*`, `model_receipt`, `reasoning_document`, `receipt_budget_controller`, `witness_*`, `sealed_build`, `deliberation`, `plan`, `behavior_version`, `effect_dispatcher`, `diagnosis_catalog`, `intent_catalog`, `skill_set`, `errors` |
| worker / runtime | ~13 | 4,967 | `worker`, `worker_runtime`, `runtime`, `runtime_directory`, `child_*`, `durable_recorder`, `delivery_drainer`, `outbox_delivery_sink`, `comms_gateway`, `lane_config` |
| capability / model / mcp | ~8 | 1,646 | `capability_binding`, `mcp_capability_source`, `mcp_source_builder`, `ruby_llm_model`, `governed_*_source`, `request_route`, `request_projection` |

(The last three rows are what would remain as `tamoz-agent` + `tamoz-agent-kernel`.)

## Coupling that constrains extraction

The decisive question for any extraction is: **which way do the arrows point?**

### The vertical capabilities are already leaf-like

Nothing in the runtime reaches into the _internals_ of these clusters; the
runtime uses their public facades, and so does the eval harness:

- **External consumers** (outside `tamoz-agent`) bind directly to these
  namespaces:
  - `Tamoz::Agent::Memory` — `tamoz-evals` harness (`memory_repository_adapter`),
    plus 8 test files.
  - `Tamoz::Agent::Healing` — `tamoz-evals` harness (`agent_smoke_corpus`) + 4 tests.
  - `Tamoz::Agent::Improvement` — `tamoz-evals` harness
    (`heuristic_paired_evaluation`) + 3 tests.
  - `Tamoz::Agent::Profile` — `tamoz-evals` harness + ~14 tests. (`tamoz-mcp`
    _mentions_ `Tamoz::Agent::Profile` in a comment — "egress validated by
    Profile" — but does **not** call it in code. Corrected from an earlier
    reading; see the false-positive note in [05](05-systematic-method.md).)

  These are de-facto public APIs already. Extraction formalizes what is true.

- **Inbound edges from the runtime** are shallow and go through the facade:
  `session*.rb` and `worker_runtime.rb` reference `Memory::`; `cli*.rb` and
  `session.rb` reference `Profile.`; nothing references `Improvement::` except
  `improvement/` itself; only `tamoz-core/circuit` and tests reference
  `Healing::` from outside.

### The one intra-cluster edge

`improvement` depends on `memory` (`improvement/{errors,heuristic,promotion}.rb`
reference `Memory::…`). So `tamoz-agent-improvement` must depend on
`tamoz-agent-memory`. Every other vertical is independent of the others.

### The shared substrate everyone leans on

The clusters barely touch the _runtime_ (a couple of references to
`Tamoz::Agent::Event`, `::Session::GRAPH_VERSION`, `::Error`), but they lean
hard on two kernel symbols:

- **`Plan`** — referenced 17× inside memory/improvement, almost entirely for its
  class-level **utilities** `Plan.deep_freeze`, `Plan.parse_object`,
  `Plan.string`. `Plan` is a `Data.define(:goal, :done_when, :steps)` that has
  accreted the codebase's JSON/immutability helpers.
- **`EffectDispatcher`** — the effect-execution seam. `memory/consolidation`,
  `healing/remediation/effect_execution`, and `improvement/candidate_lifecycle`
  all run their side effects through `EffectDispatcher.run`, and `healing/rule`
  reads `EffectDispatcher::MAX_ATTEMPTS`.

Both live in the deliberation kernel. That is why the kernel has to be extracted
_first_, and why the `Plan`-as-utility overload needs untangling — covered in
[02-shared-kernel.md](02-shared-kernel.md).

### The CLI is the outermost shell

The CLI cluster touches only `Toolbox`, `Session`, `Error`, `Event`,
`DeliveryDrainer`, `CommsGateway`, `VERSION` — all inbound. Nothing depends on
the CLI except the executable. It is the safest cut in the whole gem.

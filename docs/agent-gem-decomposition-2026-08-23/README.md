# Decomposing `tamoz-agent` into focused gems

_Design study — 2026-08-23_

`tamoz-agent` has grown to **~30,067 lines across 139 Ruby files** and now
carries several subsystems that are only loosely related to each other: the
deliberation loop, durable memory, self-healing, self-improvement, trusted
profiles, the worker runtime, and the CLI. This folder proposes a set of gems
to extract from it, the dependency layering that makes those extractions safe,
and the order to do them in.

This is **design only** — no code was moved and no tests were run. Every size
and coupling number here was measured from the current tree (enola snapshot +
`grep`/`wc`), not estimated.

## The documents

| File | What it covers |
|------|----------------|
| [00-current-state.md](00-current-state.md) | What the gem contains today, measured: cluster sizes, hotspots, the coupling that constrains extraction. |
| [01-target-topology.md](01-target-topology.md) | The proposed gems, one spec per gem: namespace, contents, dependencies, public surface, what makes it a clean cut. |
| [02-shared-kernel.md](02-shared-kernel.md) | The hard part — the deliberation substrate everything sits on, and the `Plan`/`EffectDispatcher` coupling that has to be resolved first. |
| [03-sequencing-risks-namespace.md](03-sequencing-risks-namespace.md) | Extraction order, the namespace-compatibility decision, and the risks per step. |
| [04-non-obvious-moves.md](04-non-obvious-moves.md) | Code that belongs in a _sibling_ gem, not a new one — the comms runtime → `tamoz-comms`, small utilities → `tamoz-core`/`tamoz-observability`, the `ruby_llm` dependency isolation, and stale upward name references. |
| [05-systematic-method.md](05-systematic-method.md) | **The repeatable method** — six signals (with commands, thresholds, verdicts, and false-positive guards), a decision procedure, and how to run it as a standing CI/enola guardrail now and in the future. |
| [06-tooling.md](06-tooling.md) | Static-analysis tools that automate the six signals — what the repo already has (enola, RuboCop, Reek), the custom cop worth adding, and the one real gap (dependency fitness). |

## Executive summary

The gem divides cleanly into three bands:

1. **A deliberation kernel** (~3,800 lines) — episode records, receipts, the
   plan/review/execute/verify engine, the effect dispatcher, error taxonomy.
   Everything else depends on it. This is not extracted as a "feature"; it is
   the base layer that _enables_ the other extractions.
2. **Vertical capabilities** — `memory`, `healing`, `improvement`, `profile`.
   Each is a cohesive subtree that already behaves like a library: it is
   consumed by name from `tamoz-evals` (and, for `profile`, from `tamoz-mcp`),
   and nothing in the runtime reaches _into_ its internals. These are the
   extractions the request is really about.
3. **The runtime + CLI** — session, worker, capability/model wiring, and the
   command line. This is what stays as `tamoz-agent` (plus a thin
   `tamoz-agent-cli`).

### Recommended target gems

| New gem | Ruby namespace | Lines | Files | Depends on (new gems) |
|---------|----------------|------:|------:|-----------------------|
| `tamoz-agent-kernel` | `Tamoz::Agent` (substrate) | ~3,800 | ~20 | — (core, sqlite, tools, observability) |
| `tamoz-agent-memory` | `Tamoz::Agent::Memory` | ~2,804 | 14 | kernel |
| `tamoz-agent-healing` | `Tamoz::Agent::Healing` | ~3,303 | 24 | kernel |
| `tamoz-agent-improvement` | `Tamoz::Agent::Improvement` | ~1,814 | 11 | kernel, **memory** |
| `tamoz-agent-profile` | `Tamoz::Agent::Profile` | ~2,444 | 15 | kernel |
| `tamoz-agent-cli` | `Tamoz::Agent::CLI` | ~4,102 | 14 | tamoz-agent (runtime) |
| `tamoz-agent` (remains) | `Tamoz::Agent` (runtime) | ~11,700 | ~40 | all of the above |

That takes the flagship gem from ~30k lines to **~11.7k lines of actual
runtime**, with each extracted concern owning its own gemspec, README, and test
surface.

### Each phase is move, then simplify — and isn't done until both

Extraction is not "relocate the files and move on." Every phase has two stages:
**Stage A** moves the subtree verbatim (a pure, reviewable diff), then **Stage B**
pays down the debt the move exposes — the hotspots enola flags _inside that gem_,
the facade that was only re-exporting, the references the seam revealed as dead.
Stage B lives inside the phase; a phase that shipped only Stage A is unfinished,
and the next phase does not start on top of it. The two-stage rule, per-phase
Stage B targets, and the definition-of-done checklist are in
[03-sequencing-risks-namespace.md](03-sequencing-risks-namespace.md).

### The one thing to resolve first

`memory`, `healing`, and `improvement` all reach the shared `Plan` value type
_for its JSON/freeze helpers_ (`Plan.deep_freeze`, `Plan.parse_object`,
`Plan.string`) and run their side effects through `EffectDispatcher`. Those two
symbols are the real reason the clusters aren't already independent. The kernel
extraction has to give them a home — and the `Plan`-as-utility overload should
be split — before the vertical gems can compile against a base gem instead of
the whole agent. See [02-shared-kernel.md](02-shared-kernel.md).

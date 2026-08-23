# 03 — Sequencing, namespace strategy, and risks

## Namespace: keep `Tamoz::Agent::X`, name gems `tamoz-agent-<x>`

There are two ways to name the extracted code:

**Option A — flat namespace** (`Tamoz::Memory`, `Tamoz::Healing`, …), matching
`tamoz-comms`/`tamoz-approval`/`tamoz-tools`. Cleaner-looking, but it renames
every reference. There are **30+ external binding sites** today —
`tamoz-evals` harness modules, `tamoz-mcp`'s egress policy, and ~20 test files —
all written against `Tamoz::Agent::Memory::…`, `Tamoz::Agent::Profile::…`, etc.
Option A rewrites all of them.

**Option B — keep `Tamoz::Agent::X`, ship it from the new gem** (recommended).
The gem is named `tamoz-agent-memory` but still defines
`module Tamoz; module Agent; module Memory`. Zero consumer churn: every existing
reference keeps resolving. `tamoz-agent` then `require`s the new gems, exactly as
`agent.rb` already does with `require_relative "agent/memory"` today — the
require just points at a gem instead of a local file.

This is the same move P16 used for tools, except simpler: tools _rebound_
`Tamoz::Tools::X` into `Tamoz::Agent::X`; here the extracted gems keep the
`Tamoz::Agent::X` name outright, so not even a rebinding constant is needed.

> If a flat namespace is wanted long-term, do Option B first (mechanical, safe),
> then rename in a separate, isolated change with its own review. Never combine a
> file move with a rename — the diff stops being reviewable.

## Every phase is two stages: move, then simplify

A phase is **not done when the code compiles in its new gem.** Moving code
across a seam without cleaning it up just relocates the mess and calls it
progress. Each phase has two stages, and the phase is only complete when both
have landed and the suite is green:

- **Stage A — move.** Relocate the subtree verbatim into its new gem, rewire the
  requires, keep the diff a pure move so it is trivially reviewable. Green here.
- **Stage B — simplify.** With the boundary now fixed, pay down the debt the
  extraction exposed: the flagged hotspots inside _that_ gem, the facade that was
  only re-exporting, the dead cross-references the seam revealed. Green here too.

Stage A stays a pure move for reviewability — that is *why* it is a separate
commit, not a licence to skip B. **B is inside the phase, not a someday-PR.** The
reason to separate them is a clean review, not deferral: a phase that shipped
Stage A and not Stage B is unfinished, and the next phase does not start on top
of unfinished work.

## Extraction order

Each **phase** (both stages) must leave `bundle` green and the suite passing
before the next begins. The order is forced by the dependency arrows in
[01](01-target-topology.md).

1. **Untie the kernel knots** (in place, no gem yet) —
   [02](02-shared-kernel.md): move `Plan.{deep_freeze,parse_object,string}`
   down to `tamoz-core`; move `Event` down next to where the kernel will live.
   Pure refactors, independently reviewable.
2. **`tamoz-agent-kernel`.** Nothing works until this base exists. Biggest
   single risk (it's the 31-module core's foundation), so do it when the above
   knots make its dependency set clean.
   _Stage B target:_ `Deliberation` (20 dependents, `structural_issues`
   complexity 21) and `EffectDispatcher.run` (complexity 16).
3. **`tamoz-agent-memory`.** First vertical; depends only on kernel.
   _Stage B target:_ `SessionRecords.load!` is not here, but audit `admission`
   / `consolidation` for the freeze/parse calls left dangling after Knot 1.
4. **`tamoz-agent-healing`** and **`tamoz-agent-profile`.** Independent of each
   other and of memory — either order (or parallel).
   _Stage B target:_ profile's **566-line `profile.rb` facade** (fan-out 106) —
   determine what it actually does versus re-export, and collapse the latter.
5. **`tamoz-agent-improvement`.** Must come after memory (the one cross-vertical
   edge). _Stage B target:_ the candidate lifecycle/promotion split.
6. **`tamoz-agent-cli`** + `exe/tamoz`. Last, on top of the finished runtime.
   _Stage B target:_ the command-group duplication across `cli_comms_*`.

After each phase: re-run enola `generate_snapshot` + `diff_snapshot` against the
baseline. Two success signals, one per stage:

- **After Stage A:** new coupling _across the new seam_ is none, and the
  31-module cluster has shrunk as the subtree left it.
- **After Stage B:** the hotspot/complexity findings that enola reported _inside
  the moved gem_ are resolved (not merely relocated) — that resolution in
  `diff_snapshot` is the objective "phase done" check, alongside a green suite.

## Stage A checklist — the move

Follow the `tamoz-approval` layout (the most recent extraction in the repo):

- `gems/tamoz-agent-<x>/`
  - `tamoz-agent-<x>.gemspec` — `TamozGemspec.build(name:, version:, summary:,
    description:, dependencies: [...])`, versions pinned to
    `= #{...::VERSION}` like every sibling.
  - `lib/tamoz/agent/<x>.rb` — the top require file (moved from
    `agent/<x>.rb`), `require`ing the new gem's base deps + its own subtree.
  - `lib/tamoz/agent/<x>/version.rb` — `VERSION` constant.
  - `lib/tamoz/agent/<x>/…` — the moved subtree, paths unchanged.
  - `LICENSE`, `README.md`.
- In `tamoz-agent.gemspec`, add `["tamoz-agent-<x>", "= #{VERSION}"]`.
- In `agent.rb`, change `require_relative "agent/<x>"` to `require "tamoz/agent/<x>"`.
- Move the gem's tests from `tamoz-agent`'s suite to the new gem (the test files
  in [00](00-current-state.md) map 1:1 to gems).

Ship Stage A as its own commit — a pure move, no behavioural change — so its
review is "did anything change besides paths?" and nothing else.

## Stage B checklist — the simplify (definition of done)

The phase is done only when all of these hold:

- [ ] The enola hotspot/complexity findings that sit _inside this gem_ are
      resolved in `diff_snapshot`, not carried over. (The Stage B target named in
      the order list above is the minimum; take any others enola surfaces for the
      moved files.)
- [ ] Any facade that turned out to be pure re-export is collapsed, or its real
      responsibility is documented — not left as unexplained fan-out.
- [ ] Dead or now-cross-gem references the seam exposed are removed.
- [ ] The gem's own README states its public surface, so the next extraction
      builds against a documented boundary.
- [ ] Suite green; `bundle` green.

Only then does the next phase start. A phase parked after Stage A is an
unfinished phase, and the plan does not treat it as complete.

## Risks and how the design contains them

| Risk | Containment |
|------|-------------|
| **The 31-module cycle spans the seam.** If a vertical and the runtime are mutually recursive, extraction creates a gem cycle. | Measured: the verticals reach the runtime only through kernel symbols (`Plan`, `EffectDispatcher`, `Event`, `Error`) — all pushed _down_ in step 1. After that, arrows are one-directional. Confirm with `diff_snapshot` after the kernel lands. |
| **`Plan` drags the plan domain into value gems.** | Knot 1 — split the helpers to `tamoz-core` first. |
| **`Event` inversion (memory → runtime).** | Knot 3 — move `Event` to the kernel. |
| **Version lockstep.** Every gem pins `= VERSION`. A split multiplies the gemspecs that must bump together. | Keep the single shared `VERSION` (via `gemspec_helper`) and release the whole `tamoz-agent-*` family in lockstep, as the repo already does across its gems. |
| **Runtime-contract assets.** `tamoz-approval` ships `policy/**/*.yaml` via `runtime_contracts:`. Check whether any extracted subtree ships bundled data (profiles, catalogs) that must travel with its gem. | `diagnosis_catalog`/`intent_catalog`/`skill_set` are code, not data — likely none, but audit each gem's `File.expand_path(... __dir__)` reads before moving. |
| **Move and simplify entangled in one diff.** `Deliberation`, `EffectDispatcher.run`, `SessionRecords.load!`, `profile.rb` facade are all flagged hot, and it is tempting to "fix while I'm in here." | Two commits, one phase: Stage A is a pure move (reviewable as "paths only"); Stage B does the simplification against the now-fixed boundary. Separating them keeps each review honest — it does **not** push Stage B out of the phase. The phase is unfinished until Stage B lands. |
| **Splitting session from worker.** Tempting, but they share the durable record and thread-advance machinery (the core of the 31-module cluster). | Out of scope. Extract the six leaf/base gems first; reassess the runtime split against a much smaller, cleaner `tamoz-agent`. |

## Where this lands

From one 30k-line gem to a family: a **~3.8k-line kernel**, four vertical gems
(~10.4k lines total) that already have external consumers, a **~4.1k-line CLI**,
and a **~11.7k-line runtime** that finally means one thing — _run the loop_. The
seams are the ones the code already implies; this design just makes them
enforceable by the dependency graph instead of by convention.

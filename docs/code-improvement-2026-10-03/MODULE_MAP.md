# Module map — are the gems built around business concepts?

Measured 2026-10-03 at `c2887afa` with enola (`package_metrics`, `query_insights`) and RuboCop
(`metrics.rubocop.yml` in this folder).

## Answer

**Yes, the modules exist and most are business-aligned.** The repository is 31 gems in a
ports-and-adapters shape: pure domain gems at the centre, technology adapters at the edge, and a
few composition gems that wire them. `tamoz-research` depends on nothing but `tamoz-core`
(enola `Ce = 0`); `tamoz-approval`, `tamoz-scheduler`, `tamoz-comms` and `tamoz-skills` each
depend only on core. That is the shape you want.

**Do not create more gems.** ADR-052 admits a gem only when it owns its own dependency boundary
(a third-party library or a process). Splitting for size or for naming would add packaging,
isolation proofs and version lockstep for no new boundary. The modularity work belongs **inside**
the gems: classes over 250 lines are several responsibilities under one name, and each of those
responsibilities should become its own small class named for the business concept it owns.

| Kind | Gems |
|---|---|
| Domain — a business concept, no infrastructure | `tamoz-approval` (who may act), `tamoz-research` (a research run's rules), `tamoz-scheduler` (when work is due), `tamoz-comms` (channels and admission), `tamoz-skills` (portable recipes), `tamoz-agent-memory` (what the agent remembers), `tamoz-agent-healing` (bounded self-repair), `tamoz-agent-improvement` (promotion of better behavior), `tamoz-agent-profile` (trusted project authority), `tamoz-agent-capabilities` (what the agent may call), `tamoz-evals` (evidence) |
| Engine — reusable machinery with no business meaning | `tamoz-core`, `tamoz-cancellation`, `tamoz-concurrency`, `tamoz-graph`, `tamoz-context-engine`, `tamoz-harness`, `tamoz-observability` |
| Adapter — one external technology each | `tamoz-sqlite`, `tamoz-mcp`, `tamoz-mcp-websearch`, `tamoz-telegram`, `tamoz-otel`, `tamoz-stream`, `tamoz-comms-gateway` |
| Composition — wires the above into the agent | `tamoz-agent-kernel`, `tamoz-agent-session`, `tamoz-agent`, `tamoz-agent-cli`, `tamoz-evals-runner` |

## Where the structure is weak

1. **Classes that hold several responsibilities.** 50 production classes or modules exceed the
   250-line ceiling (`Metrics/ClassLength`, `Metrics/ModuleLength`). The largest:
   `Tamoz::SQLite::Migrator` (1321), `script/tamoz_sqlite_oracle` (1017), `Tamoz::Agent::Worker`
   (1003), `Tamoz::Agent::WorkerRuntime` (865), `Tamoz::Graph::CheckpointCodec` (660). This is
   the main modularity debt and the architecture bar's main row.
2. **One dependency cycle**, inside `tamoz-core`: `lib/tamoz` → `lib/tamoz/core` →
   `lib/tamoz/core/capability` → `lib/tamoz`.
3. **`tamoz-sqlite` is organised by technology, not by domain.** It holds the stores of seven
   domains (memory, schedules, comms, approval, circuits, effects, verification) as 70 files in one
   flat `Tamoz::SQLite` namespace. ADR-052 requires the stores to live there (it owns the `sqlite3`
   boundary), but inside the gem they could be grouped by domain (`Tamoz::SQLite::Memory::Store`).
   That renames constants other gems use — an owner decision (below).
4. **`Tamoz::Agent` is one flat namespace across five gems** (kernel, session, capabilities, cli,
   agent; ~330 constants). A constant's name does not say which gem owns it. Same kind of owner
   decision.

## Owner decisions (not taken in this change)

Both are cross-gem interface changes, which `AGENTS.md` says to ask about first:

- **D1.** Group `tamoz-sqlite` stores by domain sub-namespace.
- **D2.** Give each `tamoz-agent-*` gem its own sub-namespace (`Tamoz::Agent::Session::…`,
  `Tamoz::Agent::CLI::…`), so the constant names the owning gem.

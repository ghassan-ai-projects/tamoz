# tamoz-agent-session

The deliberation loop of a Tamoz agent: one durable `Session` class and the
machinery it is built from — versioned records, planning context, the graph
nodes, effect dispatch, evidence, routing, and adaptive behavior. Extracted
from `tamoz-agent` so drivers (worker/runtime) and external harnesses (CLI,
evals) depend on a finished loop instead of ungrouped runtime files.

## Public surface

Under `Tamoz::Agent` (unchanged constant paths):

- **Session** — the durable deliberation session: `start`, `resume`,
  `continue`, `recover`, `view`, `effect`, `model`, `close`, `capabilities`,
  `outcome`, `app` (→ `durable_runner`, `checkpointer`), `build_definition`;
  constants `ROUTINGS`, `MODEL_CALL_SAFETIES`, `GRAPH_NAME`. The CLI also
  calls `#verify_skill_binding!` and `#resolve_effect` directly.
- **SessionOutcome**, **SessionView** — the result and view values.
- **SessionRecords** — the versioned, allowlisted durable-record codec;
  `LEGACY_PROFILE_ID` and `.digest` are consumed by the CLI and by
  `tamoz-agent`'s ephemeral driver.
- **SessionStatusProjection** — `.document` / `.SCHEMA` / projection helpers
  over a session view (CLI rendering and worker status output).
- **SessionPlanningContext** — follow-up payload assembly; the CLI calls
  `.follow_up_payload` directly.

`Tamoz::Agent::SessionGem::VERSION` ships in lockstep with the rest of the
monorepo (`0.1.0.alpha.1` literal per gem, hand-synced like every sibling).
The version lives on the sibling module `SessionGem`, not on `Session`
itself: `Tamoz::Agent::Session` is the session CLASS, so a `VERSION`
constant under it would hang off the class rather than mark the gem.

## Dependencies

`tamoz-agent-kernel` (the deliberation substrate), `tamoz-agent-capabilities`
(the sealed capability catalog Session binds at build), `tamoz-agent-memory`,
`tamoz-agent-profile`, `tamoz-agent-healing`, `tamoz-core`. Nothing here
reaches up into worker, runtime, or CLI code: consumers point down only.
Graph, comms, approval, and MCP are injected and duck-typed (`session.rb`),
so there is no gem edge to them.

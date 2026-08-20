# Phase 1 — capability visibility

Status: partial — pure sealed-host inventory and non-connecting MCP peek implemented on 2026-08-20; phase exit bar not yet met.

Completed in this pass: deterministic registry inventory rows distinguish
declared/configured/catalogued/materialized/reachable/authorized/effective/
verified/phase-visible state, expose bounded policy/schema digests, and use
typed availability reasons without mutating the sealed registry.

Remaining blocker: bounded explicit `materialize`, typed health snapshots,
CLI/Telegram canonical inventory parity, and the no-process/no-network probe
matrix. Worker status no longer materializes MCP sources implicitly.

Study reference: Stage 1 (`04`), P1 (`05`), "Capability inventory and discovery"
(`04`).

## Goal

The effective capability surface is inspectable: an operator (and later the
model, in Phase 2's read-only mode) can see what exists, what state it is in,
why it is unavailable, and what schema it expects — without connecting to
anything.

## Required order

First make a pure inventory over the Phase 0 sealed registry and operator
configuration. Then add explicit materialization. Finally expose the same
inventory through unattended CLI status and the model-facing read-only
surface. No caller may infer `effective` from configuration alone.

## Work items

1. **Pure inventory.** Extend `CapabilityBinding`/`CapabilityHost` with a
   deterministic inventory over the sealed registry, `ToolCatalog`, pinned MCP
   descriptors, and operator `RuntimeDirectory` settings. Each row contains
   `declared`, `configured`, `catalogued`, `materialized`, `reachable`,
   `authorized`, `effective`, `verified`, `phase_visible`, `approval_required`,
   `effect_class`, schema/definition digests, source id, and a bounded typed
   reason. `effective` is the intersection of the sealed registry and the
   policy-derived admission set, not the enabled-source list. No secrets or
   remote description text are required for `peek`.
2. **Split `peek`, `materialize`, and `invoke`.** Refactor the current eager
   `McpSourceBuilder#build`/`WorkerRuntime#mcp_source` path so:
   - `peek` reads only operator config, local catalogs, and already-pinned
     metadata; it never calls `Mcp::Catalog.compile`, starts a
     `Mcp::Supervisor`, opens a socket, or spawns a process;
   - `materialize` is an explicit operation that compiles one configured source
     with catalog/description/output/time budgets, records its digest and health,
     and closes the supervisor on every failure path; and
   - `invoke` remains `SessionEffects#dispatch` through the Phase 0 host and
     journal. Materialization is not an implicit precondition hidden in status.
     It returns a typed materialized snapshot with an authority/catalog
     revision. It never mutates an existing sealed `Capability::Registry`;
     invocation is allowed only when the session binding names that exact
     snapshot. A changed catalog requires a new binding/session revision.
3. **Typed availability.** Add a closed reason vocabulary at the inventory
   boundary: disabled, invalid configuration, handshake failed, timeout,
   catalog digest changed, circuit open, missing grant, phase invisible,
   approval required, not admitted, and unavailable. One source's failure is a
   row-level state; it must not discard healthy source rows or turn a failed
   probe into `effective`.
4. **Bounded schema-aware discovery.** Project local validator schemas from
   `ToolCatalog` and pinned MCP entry schemas from `McpCapabilitySource`, with
   size/depth limits and source/definition digests. Discovery is a read-only
   capability descriptor in the sealed host; it cannot return a dispatcher,
   change admission, materialize a source, or invoke a tool.
5. **Operator surfaces.** Extend the existing unattended path at
   `cli_worker_commands.rb#build_status`, `WorkerRuntime#capability_catalog`,
   and `cli_rendering.rb` with `status --json` inventory rows. Add explicit
   `capabilities peek` and `capabilities materialize SOURCE` commands only if
   the current CLI router has no suitable subcommand; both must state whether
   they performed I/O. Telegram receives the same bounded status projection
   through `CommsGateway`, never a direct session or source connection.

## Tests

- `test/agent_worker_mcp_test.rb`, `test/mcp_catalog_test.rb`, and
  `test/mcp_supervisor_test.rb` prove `peek` with a configured MCP server
  performs no process spawn and no network I/O using a supervisor/transport
  probe, while explicit materialization is bounded and closes resources;
- `test/agent_cli_test.rb` and `test/agent_cli_mcp_test.rb` prove status with
  one failing source returns a successful document containing a typed reason
  for that source and complete rows for healthy sources;
- the availability matrix distinguishes disabled, invalid configuration,
  timeout, handshake failure, stale digest, open circuit, missing grant,
  phase-invisible, and approval-required without collapsing them;
- discovery output contains schemas and digests, no secrets, no unbounded
  descriptions, and no dispatcher/authority-bearing fields;
- discovery in the discovery phase exposes only read-only names, pinned by a
  regression test against `CapabilityBinding#names(:discovery)`.

## Exit bar

- Capability availability mission (matrix scenario 4) passes with fixtures:
  disabled source, invalid command, stale digest, timeout, open circuit,
  missing grant, approval-required each produce a distinct structured reason.
- No status or model discovery path connects implicitly; a process/network probe
  is part of the committed evidence.
- Materialization never changes an existing session's sealed executable surface;
  a stale or changed snapshot is reported as unavailable until a new binding is
  constructed.
- CLI and Telegram status carry the same canonical inventory rows, differing
  only in presentation.
- `rake ci`, `rubocop`, `enola check`, and the required `ci_full` both locales
  are clean. This phase proves plumbing only.

## Out of scope

Adaptive model decision behavior (Phase 2), lifecycle projection, compaction,
new capability families, and any claim about model tool selection.

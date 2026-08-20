# Phase 0 — authority and identity gates

Status: partial — descriptor and logical/attempt identity slice implemented on 2026-08-20; phase exit bar not yet met.

Completed in this pass: descriptor policy/schema/source digest completion and
verification, closed policy vocabulary, source digest-map binding, pure
logical identity construction with checkpointed iteration/sub-operation, and
SessionEffects/session-record propagation of those identity fields.

Remaining blocker: the full phase still needs the MCP untrusted-data fencing
audit, scheduler template provenance enforcement, descriptor audit artifact,
and the complete secret-boundary proof across prompts/receipts/telemetry. No
claim is made that Phase 0 is complete.

Study reference: Stage 0 (`04`), P0 (`05`). This phase exists because every
later phase adds capability surface; expanding before these gaps close makes
expansion unsafe.

## Goal

Every capability — current and future — has a complete, fail-closed authority
descriptor, and effect identity survives adaptive/compound calls without
receipt collision.

## Required order

Complete the descriptor contract and its source adapters before changing effect
identity. Complete identity before any Phase 1 inventory can expose a
capability as effective. The registry remains constructed once at session
construction; this phase does not add a dynamic registration path.

## Work items

1. **Complete the one descriptor contract.** Extend
   `tamoz-core`'s `Capability::Descriptor`, `Source`, and `Registry`, then
   update `CapabilityBinding`, `CapabilityHost`, `LocalDispatcher`, and
   `McpDispatcher` to use it. A descriptor must carry source identity,
   definition/schema digests, effect class, approval policy, egress policy
   digest/reference, secret handling policy, output/request budgets, retry
   policy, and reconciliation policy. These are canonical data or digests;
   they never contain credential values. Do not create a second policy object
   that can disagree with the descriptor.
2. **Fail-closed classification and registration.** Remove every safety
   fallback that can classify an unknown name or effect as `read_only`,
   including source-dispatcher defaults. Unknown kinds, effect classes, policy
   values, missing fields, mismatched source ids, and a descriptor whose digest
   does not match its definition must fail at descriptor/source/registry
   construction. `McpCapabilitySource`'s `:unknown_effects` input is normalized
   to the closed descriptor vocabulary or rejected; remote metadata never
   supplies that classification.
3. **Compound effect identity.** Define two identities and extend the existing path through
   `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal_key.rb`,
   `effect_journal.rb`, `EffectDispatcher.run`, and
   `SessionEffects#model_call`/`#dispatch_options`. The canonical identity must
   include request, execution, capability, canonical arguments, authority and
   catalog revisions, durable iteration, and sub-operation; the persistent
   journal request digest remains part of the record. The **logical identity**
   is stable across restart and deduplicates the same requested operation; the
   **attempt identity** distinguishes execution/reconciliation attempts and
   records an ambiguous sent operation as `unknown`. The iteration and
   sub-operation values come from checkpointed state, never a process-local
   counter. Update `SessionRecords` effect intent/receipt fields if needed so a
   receipt can be joined back to the action that caused it. This is a contract
   change across `tamoz-agent`, `tamoz-sqlite`, `tamoz-graph`, checkpoint
   encoding, and the record allowlist; it must be implemented as one slice.
4. **Untrusted-data fencing.** Extend the planning and observation projection
   at `McpSourceBuilder`, `McpCapabilitySource`, and
   `SessionEffects#mcp_planning_surface`. Descriptions and remote results must
   be bounded, carry source/provenance and truncation markers, and be delimited
   as data. They cannot add names to `CapabilityBinding`, change a descriptor,
   alter approval/egress, or become an instruction in a planning prompt.
5. **Scheduler template ownership.** Trace
   `Worker#materialize_due_schedules` through `WorkerRuntime#schedule_payload`
   and `ScheduleStore#materialize_due`. The request template and payload
   reference must resolve only from the operator-owned runtime directory and
   scheduler store; model output, workspace files, skills, and remote content
   must be rejected as template authorities. Keep occurrence provenance on the
   occurrence/request records.
6. **Egress and secret boundary audit.** Produce a small descriptor audit table
   covering local tools, skills, MCP, and websearch. Reuse
   `Profile#egress`, `Session#verify_egress_binding!`, `Mcp::ServerConfig`,
   `Mcp::Websearch::EgressPolicy`, and `SessionRecords` secret rejection. Any
   missing declaration becomes a failing registration test; do not repair the
   gap with a permissive default.

## Tests

- `test/capability_registry_test.rb`, `test/capability_closed_world_test.rb`,
  and `test/agent_capability_binding_test.rb` prove descriptor completeness,
  source ownership, closed registration, and fail-closed unknown effects;
- `test/agent_session_effect_test.rb` and `test/sqlite_effect_journal_test.rb`
  prove two sub-operations of one iteration have distinct keys/receipts and
  replay returns the matching receipt without re-executing either operation;
- `test/agent_mcp_adversarial_test.rb` and
  `test/agent_mcp_capability_source_test.rb` prove instruction-like MCP
  descriptions/results remain bounded data and cannot widen the surface;
- `test/agent_schedule_test.rb`, `test/scheduler_due_occurrences_test.rb`,
  and `test/scheduler_consumer_test.rb` prove operator-owned schedule template
  provenance and rejection of model/workspace-originated templates;
- `test/agent_session_records_test.rb` and the MCP/server-config tests prove
  secret values do not enter descriptors, prompts, receipts, telemetry, or
  state.

## Exit bar

- All six work items are done in the stated order; the registration and
  identity suites are green under `rake ci` and `ci_full` in both locales.
- Invariants 2, 3, 4, 6, 7, and 9 are verified with named tests and a committed
  descriptor audit table.
- No capability reachable through `CapabilityBinding`, the worker, CLI, or
  MCP path lacks a complete descriptor, and no unknown descriptor reaches
  `SessionEffects`.
- The evidence manifest contains the Enola baseline receipt, test commands,
  descriptor/identity artifact digests, and an explicit list of unproven
  provider behavior. This phase proves plumbing only.

## Out of scope

New capabilities, discovery UX, any Session graph change, runtime materializer
behavior, and real-provider intelligence claims.

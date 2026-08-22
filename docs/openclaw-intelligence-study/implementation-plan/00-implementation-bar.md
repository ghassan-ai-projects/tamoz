# Implementation bar

This is the end-state bar for the OpenClaw intelligence implementation, not a
feature checklist. The work is complete only when a bounded mission can use
the new composition safely, durably, and observably from both supported user
surfaces, and the evidence below is committed.

## End-state contract

Given an operator-owned request submitted through the durable CLI or Telegram,
Tamoz must be able to:

1. inspect the sealed capability surface without connecting to or spawning any
   capability;
2. run a bounded read-only mission in which the model chooses at most one
   validated action per durable iteration, receives the resulting observation,
   and chooses the next action or terminates;
3. persist every model call, capability call, observation, lifecycle event,
   effect identity, provenance marker, truncation marker, and terminal result;
4. resume after process termination without replaying a completed effect or
   losing the goal, constraints, approvals, evidence, or next action;
5. stop safely on cancellation, budget exhaustion, repeated actions, an idle
   model, a failed or ambiguous effect, or an unknown outcome;
6. hand every mutation or external write to the existing reviewed-plan path,
   with exact-digest approval, durable execution, verification, and unknown
   outcome handling; and
7. render the same semantic lifecycle through CLI and Telegram, with task,
   effect, capability, and delivery state kept distinct.

The capability surface may grow only through operator-owned descriptors and
governed sources. Discovery, remote content, workspace content, model output,
and child-task results never grant authority. The final benchmark must measure
whether the system makes better evidence-backed decisions; plumbing tests and
tool counts are not intelligence evidence.

The final benchmark is a two-gate deliverable: protocol and fixture plumbing
may land after Phase 2, but the canonical final run may publish results only
after Phases 0–4 are complete and every mission reports `ready`. Missing
capability is an unavailable result, never a skipped success.

## End-state acceptance matrix

| Area | Must be true | Required proof |
| --- | --- | --- |
| Authority and identity | Every capability has a complete descriptor; unknown descriptors fail closed; compound iterations have collision-free effect identities. | Registration, classification, replay, and receipt-identity tests. |
| Capability visibility | `peek` is non-connecting; `materialize` is explicit and bounded; `invoke` remains governed; unavailable sources report typed reasons without hiding healthy sources. The inventory distinguishes declared, configured, catalogued, materialized, reachable, authorized, effective, and verified. | Probe-based no-I/O tests plus the complete availability matrix. |
| Adaptive continuation | A successful observation causes a new durable model decision; the loop is bounded, restart-safe, read-only, and hands mutation to reviewed execution. | Contradictory-observation, restart, guard, mutation-handoff, and duplicate-effect tests. |
| Context and lifecycle | Compaction preserves authoritative facts and externalizes evidence; CLI and Telegram share semantic identity and lifecycle events. | Restart-across-compaction and cross-surface parity tests. |
| Governed expansion | Browser, database, child tasks, self-modification, and further external effects use complete descriptors, narrowed authority, explicit egress, approval, reconciliation, and receipts. | Per-family denial, approval, unknown-outcome, narrowing, restart, and rollback tests. |
| Measured intelligence | A versioned matched benchmark reports task success, evidence quality, unnecessary actions, unsafe actions, recovery, latency, and cost with fixture/real-provider provenance separated. | Committed benchmark protocol, machine-readable results, and at least one real-provider run. |

## Completion evidence

The final completion note must include the exact commands and results for the
relevant tests and quality gates, the benchmark protocol and result artifact,
the real-provider configuration class (without secrets), and a short list of
claims that remain unproven. Every phase file must have a dated status, changed
files or explicit no-change reason, exit evidence, and a plumbing-versus-real-
provider statement. The repository must have no unreviewed hard-zero failure,
no new architecture regression, and no generated evidence edited without its
generator.

Phase evidence is committed under the folder convention in `README.md`. The
manifest must bind each result to the code revision, protocol/configuration
digest, provider/model identity class, surface, graph version, and command
that produced it. A missing artifact, an unresolvable digest, or an omitted
failed attempt is an evidence failure, not a documentation gap.

This is the acceptance contract for every phase in this folder. A phase is done
only when its own exit criteria are met **and** every global bar below holds.

## Global invariants (never regress, in any phase)

Taken from the study's safety invariants (`04-tamoz-target-architecture.md`).
Each phase must keep all of them true and add regression tests for any it touches:

1. Tool search/discovery never grants capability.
2. Every capability declares source, schema digest, effect class, approval,
   egress, secret, budget, retry, and reconciliation semantics.
3. Unknown or unclassified capability descriptors fail closed.
4. MCP descriptions/results and web/browser content are untrusted data, never
   instructions or authority.
5. Every model/tool/delegation/config operation goes through
   `EffectDispatcher` (via `SessionEffects`) — no raw model or tool calls inside
   durable graph nodes.
6. Effect identity includes request, execution, capability, arguments,
   authority/catalog revision, and durable iteration/sub-operation identity.
7. Sent non-idempotent operations that lose their response become `unknown` and
   are reconciled, never blindly replayed.
8. Approval binds actor, request, plan/step, effect, argument/preview digest,
   authority revision, and expiry; unknown effects fail closed.
9. Secrets are typed and rejected from prompts, receipts, telemetry, and state.
10. Self-inspection is read-only; self-modification is
    candidate → approval → apply → verify → rollback.
11. Cancellation and restart preserve requested/observed/terminal/unknown
    distinctions.
12. Task state, effect state, and delivery state remain separate.

## Hard-zero failures

Any of these in a phase's acceptance run fails the phase outright
(from `06-capability-scenario-matrix.md`):

- unauthorized effect;
- action before approval;
- fabricated evidence;
- false success;
- duplicate non-idempotent effect;
- unknown outcome silently treated as success;
- secret exposure;
- workspace/model content widening authority.

## Evidence standard

- Fixture/scripted-model tests prove plumbing and invariants only. They are
  required, but they are never presented as evidence of intelligence.
- A real-provider run is evidence for that run. Capability claims ("the agent
  chooses tools well") require Phase 5's matched benchmark, not anecdotes.
- Every phase's completion note must state plainly which claims rest on
  plumbing tests and which on real-provider runs.

## Quality gates (per repo convention)

Every phase merge must pass:

- `rake ci` (everyday gate);
- `rubocop` clean for touched files;
- `enola check` — no new structural regression (dependency cycle or unintended
  coupling introduced by the change is fixed before presenting, not after);
- `ci_full` in both locales for any phase touching durability, MCP, packaging,
  or evidence. Phases 0, 1, 2, 3, 4, and 5 qualify by their stated scope;
  record the exact invocations rather than relying on this default list.

Comments: none by default, per `AGENTS.md`. Name things so the code reads.

## Non-goals (whole program)

From the study, unchanged:

- no general arbitrary shell tool;
- no raw SQL against internal Tamoz state;
- no unrestricted browser or network access;
- no model-controlled policy/profile/secret mutation;
- no in-process untrusted plugin/MCP execution;
- no second runtime parallel to `Session`;
- no claim that CLI and Telegram must have byte-identical presentation;
  parity is over canonical semantic identity, lifecycle, authority, effects,
  receipts, and terminal outcome;
- no model-facing inspection surface that exposes raw secrets, unrestricted
  workspace/configuration, or authority-changing controls;
- no intelligence claims from fixture tests or tool counts.

## Per-phase definition of done

A phase is complete when:

1. every work item in its plan file is done or explicitly dropped with a reason
   recorded in the phase file;
2. its exit criteria pass, including the listed tests;
3. the global invariants and hard-zero list above are verified for the touched
   paths;
4. quality gates pass;
5. the phase file's status line is updated with date, evidence, and which
   claims are plumbing vs real-provider.

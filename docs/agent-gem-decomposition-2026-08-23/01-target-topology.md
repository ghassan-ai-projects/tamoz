# 01 — Target topology

The proposed gem set and one spec per gem. The design goal is a **strict
dependency layering**: each new gem depends only on gems below it, never
sideways into a peer (with the single, deliberate `improvement → memory` edge),
and never back up into the runtime.

## The layers

```mermaid
graph TD
    subgraph existing[Existing foundation gems]
        core[tamoz-core]
        sqlite[tamoz-sqlite]
        graph[tamoz-graph]
        tools[tamoz-tools]
        obs[tamoz-observability]
        comms[tamoz-comms]
        approval[tamoz-approval]
    end

    kernel[tamoz-agent-kernel<br/>deliberation substrate]

    memory[tamoz-agent-memory]
    healing[tamoz-agent-healing]
    profile[tamoz-agent-profile]
    improvement[tamoz-agent-improvement]

    runtime[tamoz-agent<br/>session · worker · runtime]
    cli[tamoz-agent-cli<br/>+ exe/tamoz]

    kernel --> core & sqlite & tools & obs
    memory --> kernel
    healing --> kernel
    profile --> kernel
    improvement --> kernel
    improvement --> memory

    runtime --> kernel & memory & healing & improvement & profile
    runtime --> graph & comms & approval
    cli --> runtime
```

Arrows are "depends on". The only peer-to-peer edge among the vertical
capabilities is `improvement → memory`, which is real in the code today.

---

## `tamoz-agent-kernel` — the deliberation substrate

**Namespace:** `Tamoz::Agent` (foundational constants only)
**Size:** ~3,800 lines, ~20 files

**Contents:** `episode_frame_builder`, `episode_graph`, `episode_nodes`,
`episode_model_call`, `episode_model_transport`, `episode_tool_call`,
`model_receipt`, `reasoning_document`, `receipt_budget_controller`,
`witness_gateway`, `witness_verifier`, `sealed_build`, `behavior_version`,
`plan`, `deliberation`, `effect_dispatcher`, `diagnosis_catalog`,
`intent_catalog`, `skill_set`, `errors`.

**Why it exists:** these are the record, receipt, and effect primitives that the
whole agent is built from. Today they are the top of the require chain in
`agent.rb`; four verticals and the runtime all bind to them. Making them a gem
turns an implicit base layer into an explicit one, and is the precondition for
every other extraction (see [02](02-shared-kernel.md)).

**Depends on:** `tamoz-core`, `tamoz-sqlite`, `tamoz-tools`,
`tamoz-observability`. Not `tamoz-graph`, `tamoz-comms`, or `tamoz-approval` —
those are runtime concerns.

**Public surface:** the episode/receipt value types, `Deliberation`, `Plan`,
`EffectDispatcher`, the error taxonomy. `Deliberation` (20 dependents) is the
load-bearing member; keep its public methods frozen during the move.

**Caveat:** `EffectDispatcher.run` (complexity 16) and `Deliberation`
(`structural_issues` complexity 21) are hotspots. Move them verbatim in Stage A
so the extraction diff stays reviewable — then **simplify them in Stage B of the
same phase**; the kernel phase is not done while they are still flagged. See the
two-stage rule in [03](03-sequencing-risks-namespace.md).

---

## `tamoz-agent-memory` — durable memory

**Namespace:** `Tamoz::Agent::Memory` (unchanged)
**Size:** 2,804 lines, 14 files

**Contents:** `memory.rb` facade + `memory/`: `surface` (the `Engine`),
`admission`, `retrieval`, `lifecycle`, `consolidation`, `transition_registry`,
`behavior_transition`, `situation_recaller`, `record`, `wisdom`,
`verified_outcome_reference`, `limits`, `errors`.

**Why it's a clean cut:** self-contained store logic behind the `Memory::Engine`
facade; already consumed by name from the `tamoz-evals` harness and 8 tests;
nothing in the runtime reaches past the facade.

**Depends on:** `tamoz-agent-kernel` (for `Plan` helpers, `Event`,
`EffectDispatcher` in consolidation), `tamoz-core`, `tamoz-sqlite`.

**Public surface:** `Memory::Engine` and the sub-services it hands out
(`admission`, `retrieval`, `lifecycle`, `consolidation`, `transitions`,
`wisdom`), `MemoryRecord`, `VerifiedOutcomeReference`, the `Memory*Error` family.

---

## `tamoz-agent-healing` — self-healing

**Namespace:** `Tamoz::Agent::Healing` (unchanged)
**Size:** 3,303 lines, 24 files (largest extraction)

**Contents:** `healing.rb` + `healing/`: `rule`, `rule_registry`,
`classification/` (matrix, legacy text adapter), `remediation/` (session,
plan_builder, plan_review, effect_execution, preflight_check,
compensation_flow, escalation_payload, attempt_evidence, outcome), `preflight`,
`oracle`, `promotion_gate`, `failure_record`, `effect_identity`, `scope`,
`seams`, `errors`.

**Why it's a clean cut:** a well-bounded state machine. Its only outward reach
is `EffectDispatcher` (remediation) and the kernel error base. Consumed from the
eval harness (`agent_smoke_corpus`) and 4 tests. `healing/seams` builds on the
durable-circuit primitives in `tamoz-core` (a normal downward edge —
`tamoz-core` does **not** reference `Healing`, so there is no inversion to fix).

**Depends on:** `tamoz-agent-kernel`, `tamoz-core`.

**Public surface:** `Healing::Remediation.run`, `HealingRule`/`RuleRegistry`,
`Classification`, `Preflight`, `Oracle`, `PromotionGate`, `FailureRecord`, the
`Healing::Seams::*` default implementations, the error/abstention family.

---

## `tamoz-agent-improvement` — self-improvement

**Namespace:** `Tamoz::Agent::Improvement` (unchanged)
**Size:** 1,814 lines, 11 files

**Contents:** `improvement.rb` + `improvement/`: `candidate_lifecycle`,
`candidate_policy`, `candidate_proposal`, `generator`, `heuristic`,
`evaluation_report`, `provenance`, `promotion`, `monitor`, `errors`.

**Why it's a clean cut:** a distinct pipeline (propose → evaluate → gate →
promote/rollback). Consumed from the eval harness
(`heuristic_paired_evaluation`) and 3 tests.

**Depends on:** `tamoz-agent-kernel`, **`tamoz-agent-memory`** (its errors,
heuristic, and promotion reference `Memory::…`), `tamoz-core`. This is the one
cross-vertical dependency; it means improvement must be extracted _after_ memory.

**Public surface:** `Improvement::CandidateLifecycle`, `Generator`, `Heuristic`,
`EvaluationReport`, `Promotion`, `Provenance`, `Monitor`, the error family.

---

## `tamoz-agent-profile` — trusted profiles

**Namespace:** `Tamoz::Agent::Profile` (unchanged)
**Size:** 2,444 lines, 15 files

**Contents:** `profile.rb` facade + `profile/`: `document_validator`,
`authority_validator`, `egress_validator`, `check_spec_validator`,
`content_scanner`, `yaml_scanner`, `secure_file`, `locations`, `fields`,
`adoption_document`, `adoption_registry`, `transition`, `transition_document`,
`transition_registry`.

**Why it's a clean cut:** a self-contained validation/registry library,
consumed by the eval harness and ~14 tests. Its `EgressValidator` is a security
component with reuse potential — `tamoz-mcp`'s websearch egress config is
conceptually validated by it (tamoz-mcp names it in a comment), though the wiring
is agent-side today, not a code call from mcp.

**Depends on:** `tamoz-agent-kernel`, `tamoz-core`. (No runtime deps: the only
mentions of "stream" in the subtree are comments about the YAML event stream —
profile does not depend on `tamoz-stream`, which keeps this validation gem light.)

**Public surface:** `Profile` facade, the four validators, `SecureFile`,
`Locations`, `AdoptionRegistry`, `TransitionRegistry`.

**Note:** `profile.rb` is a 566-line facade (fan-out 106). This is profile's
**Stage B target**: determine whether the facade does real work or just
re-exports, and collapse the re-export half. It is part of finishing the profile
phase, not a follow-up.

---

## `tamoz-agent-cli` — the command line

**Namespace:** `Tamoz::Agent::CLI` (unchanged)
**Size:** 4,102 lines, 14 files; **owns `exe/tamoz`**

**Contents:** `cli`, `cli_argument_parser`, `cli_option_policy`,
`cli_rendering`, `cli_authority`, `cli_prompt_adapter`, and the command groups
`cli_worker_commands`, `cli_schedule_commands`, `cli_profile_commands`,
`cli_session_commands`, `cli_comms_commands`, `cli_comms_ops`,
`cli_comms_doctor`, `cli_comms_shared`.

**Why it's a clean cut:** the outermost shell — every edge is inbound. Moving it
out means `tamoz-agent` becomes a pure library with no executable, and the CLI
gem is the only one that needs the user-facing dependency surface.

**Depends on:** `tamoz-agent` (the runtime). Transitively everything else.

---

## What remains as `tamoz-agent`

The **runtime**: the session state machine (`session*.rb`, 5,054 lines), the
worker/durable-execution layer (`worker`, `worker_runtime`, `runtime`,
`child_*`, `durable_recorder`, delivery sinks, `comms_gateway`, `lane_config`,
4,967 lines), and the capability/model/MCP wiring (`capability_binding`,
`mcp_*_source`, `ruby_llm_model`, `governed_*_source`, `request_*`, 1,646
lines). Plus `agent.rb`'s `build`/`build_approval_engine` entry points.

~11,700 lines — still substantial, but now a single-responsibility gem: _run the
deliberation loop over a graph_. It depends on the kernel and all four
verticals, and on `tamoz-graph`/`tamoz-comms`/`tamoz-approval` as it does today.

A later pass could split `session` from `worker`, but they share the durable
record and thread-advance machinery tightly (the 31-module cluster lives here),
so that split is lower-value and higher-risk than the six extractions above. It
is explicitly out of scope for this study.

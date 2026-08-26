# Architecture decision records

Tamoz records its architecture decisions as numbered ADRs. This index is the public status catalog: it catalogs ADR-001 through ADR-049 with their current status, and every entry links to its full rationale. Tamoz records decisions as ADRs, not RFCs; there are no RFC-style proposal documents in the repository.

## Where the decisions live

ADR-001 through ADR-048 are sections of the authoritative design record, [`docs/design-v0.1/DECISIONS.md`](../../docs/design-v0.1/DECISIONS.md) (repository-internal archive), which remains the source of truth for their full text — each row above deep-links to its decision's section. ADR-044 through ADR-048 are additionally stated in the observability design ([`docs/OBSERVABILITY_DESIGN.md`](../../docs/OBSERVABILITY_DESIGN.md), contract-changes section), and ADR-041 through ADR-043 plus ADR-049 appear in the channel design ([`../design/comms.md`](../design/comms.md)). ADR-049 is the only decision with a standalone public page: [`./adr-049-telegram-approval.md`](./adr-049-telegram-approval.md).

Current version: `0.1.0.alpha.1` (pre-release).

## ADR index

| ADR | Title | Status |
|---|---|---|
| [001](../../docs/design-v0.1/DECISIONS.md#adr-001--tamoz-framework-and-tamoz-agent-reference-application) | Tamoz framework and Tamoz Agent reference application | Accepted 2026-07-30 |
| [002](../../docs/design-v0.1/DECISIONS.md#adr-002--four-v01-runtime-gems-optional-packages-earn-promotion) | Four v0.1 runtime gems; optional packages earn promotion | Revised |
| [003](../../docs/design-v0.1/DECISIONS.md#adr-003--reuse-rubyllm-public-values-at-runtime-define-a-lossless-durable-codec) | Reuse RubyLLM public values at runtime; define a lossless durable codec | Superseded by ADR-048 |
| [004](../../docs/design-v0.1/DECISIONS.md#adr-004--explicit-tamozseq-no-native-proc) | Explicit `Tamoz.seq`; no native `Proc#>>` | Revised |
| [005](../../docs/design-v0.1/DECISIONS.md#adr-005--interrupt-by-throw-not-by-exception) | Interrupt by `throw`, not by exception | Accepted |
| [006](../../docs/design-v0.1/DECISIONS.md#adr-006--plain-hash-state-with-an-explicit-reducer-registry) | Plain Hash state with an explicit reducer registry | Accepted |
| [007](../../docs/design-v0.1/DECISIONS.md#adr-007--frozen-state-handed-to-nodes) | Frozen state handed to nodes | Accepted |
| [008](../../docs/design-v0.1/DECISIONS.md#adr-008--threads-as-the-default-pool-inline-in-tests) | `:threads` as the default pool, `:inline` in tests | Accepted |
| [009](../../docs/design-v0.1/DECISIONS.md#adr-009--prompt-cache-stability-as-invariant-16) | Prompt-cache stability as invariant 16 | Accepted |
| [010](../../docs/design-v0.1/DECISIONS.md#adr-010--ruby-33-floor-34-and-40-primary-targets) | Ruby 3.3 floor; 3.4 and 4.0 primary targets | Revised |
| [011](../../docs/design-v0.1/DECISIONS.md#adr-011--sqlite-as-tamoz-agents-default-persistence) | SQLite as Tamoz Agent's default persistence | Accepted |
| [012](../../docs/design-v0.1/DECISIONS.md#adr-012--mcp-is-a-deferred-integration-strategy) | MCP is a deferred integration strategy | Superseded by ADR-029 |
| [013](../../docs/design-v0.1/DECISIONS.md#adr-013--public-vocabulary-budget-never-a-correctness-cap) | Public vocabulary budget, never a correctness cap | Revised |
| [014](../../docs/design-v0.1/DECISIONS.md#adr-014--no-plugin-api-in-v01) | No plugin API in v0.1 | Accepted |
| [015](../../docs/design-v0.1/DECISIONS.md#adr-015--durable-means-synchronous-barrier-commit) | Durable means synchronous barrier commit | Accepted |
| [016](../../docs/design-v0.1/DECISIONS.md#adr-016--external-effects-are-at-least-once-unless-proven-otherwise) | External effects are at-least-once unless proven otherwise | Accepted |
| [017](../../docs/design-v0.1/DECISIONS.md#adr-017--one-fenced-writer-per-thread-namespace) | One fenced writer per thread namespace | Accepted |
| [018](../../docs/design-v0.1/DECISIONS.md#adr-018--strict-sequence-is-separate-from-checkpoint-identity) | Strict sequence is separate from checkpoint identity | Accepted |
| [019](../../docs/design-v0.1/DECISIONS.md#adr-019--resume-is-graph-version-checked) | Resume is graph-version checked | Accepted |
| [020](../../docs/design-v0.1/DECISIONS.md#adr-020--sensitive-data-policy-is-explicit-and-lossless) | Sensitive data policy is explicit and lossless | Accepted |
| [021](../../docs/design-v0.1/DECISIONS.md#adr-021--resume-preserves-execution-identity-fork-changes-it) | Resume preserves execution identity; fork changes it | Accepted |
| [022](../../docs/design-v0.1/DECISIONS.md#adr-022--every-task-action-requires-a-reviewed-plan) | Every task action requires a reviewed plan | Accepted 2026-07-30 |
| [023](../../docs/design-v0.1/DECISIONS.md#adr-023--self-improvement-is-candidate-promotion-never-live-self-mutation) | Self-improvement is candidate promotion, never live self-mutation | Accepted 2026-07-30 |
| [024](../../docs/design-v0.1/DECISIONS.md#adr-024--smart-means-evidence-based-proportional-and-verified) | "Smart" means evidence-based, proportional, and verified | Accepted 2026-07-30 |
| [025](../../docs/design-v0.1/DECISIONS.md#adr-025--evaluation-is-a-first-class-non-runtime-gem) | Evaluation is a first-class non-runtime gem | Accepted 2026-07-30 |
| [026](../../docs/design-v0.1/DECISIONS.md#adr-026--three-durable-memory-layers-experience-knowledge-wisdom) | Three durable memory layers: Experience, Knowledge, Wisdom | Accepted 2026-07-30 |
| [027](../../docs/design-v0.1/DECISIONS.md#adr-027--memory-retrieval-is-authorization-consolidation-preserves-disagreement) | Memory retrieval is authorization; consolidation preserves disagreement | Accepted 2026-07-30 |
| [028](../../docs/design-v0.1/DECISIONS.md#adr-028--self-healing-is-bounded-remediation-not-catch-and-retry) | Self-healing is bounded remediation, not catch-and-retry | Accepted 2026-07-30 |
| [029](../../docs/design-v0.1/DECISIONS.md#adr-029--mcp-is-native-at-the-edge-and-uses-the-official-ruby-sdk) | MCP is native at the edge and uses the official Ruby SDK | Accepted 2026-07-30 |
| [030](../../docs/design-v0.1/DECISIONS.md#adr-030--one-local-capability-catalog-governs-local-tools-mcp-and-skills) | One local capability catalog governs local tools, MCP, and skills | Accepted 2026-07-30 |
| [031](../../docs/design-v0.1/DECISIONS.md#adr-031--scheduling-materializes-occurrences-it-does-not-run-agents) | Scheduling materializes occurrences; it does not run agents | Accepted 2026-07-30 |
| [032](../../docs/design-v0.1/DECISIONS.md#adr-032--scheduled-time-and-delayed-authority-are-explicit) | Scheduled time and delayed authority are explicit | Accepted 2026-07-30 |
| [033](../../docs/design-v0.1/DECISIONS.md#adr-033--skills-use-the-open-agent-skills-format-and-stay-in-tamoz-agent) | Skills use the open Agent Skills format and stay in `tamoz-agent` | Accepted 2026-07-30 |
| [034](../../docs/design-v0.1/DECISIONS.md#adr-034--skill-identity-is-a-tree-digest-and-activation-is-supply-chain-promotion) | Skill identity is a tree digest and activation is supply-chain promotion | Accepted 2026-07-30 |
| [035](../../docs/design-v0.1/DECISIONS.md#adr-035--streaming-input-is-a-distinct-first-class-tamoz-stream-runtime) | Streaming input is a distinct first-class `tamoz-stream` runtime | Accepted 2026-07-30 |
| [036](../../docs/design-v0.1/DECISIONS.md#adr-036--situation-is-the-boundary-between-continuous-evidence-and-episodic-cognition) | Situation is the boundary between continuous evidence and episodic cognition | Accepted 2026-07-30 |
| [037](../../docs/design-v0.1/DECISIONS.md#adr-037--event-time-explicit-backpressure-and-effect-disabled-replay-are-contracts) | Event time, explicit backpressure, and effect-disabled replay are contracts | Accepted 2026-07-30 |
| [038](../../docs/design-v0.1/DECISIONS.md#adr-038--physical-action-is-typed-intent-plus-current-state-policy-never-model-effect) | Physical action is typed intent plus current-state policy, never model effect | Accepted 2026-07-30 |
| [039](../../docs/design-v0.1/DECISIONS.md#adr-039--tamoz-is-supervisory-certified-safety-and-real-time-control-stay-external) | Tamoz is supervisory; certified safety and real-time control stay external | Accepted 2026-07-30 |
| [040](../../docs/design-v0.1/DECISIONS.md#adr-040--one-monorepo-multiple-independently-publishable-gems) | One monorepo, multiple independently publishable gems | Accepted 2026-07-30 |
| [041](../../docs/design-v0.1/DECISIONS.md#adr-041--communication-channels-are-a-contract-gem-plus-per-transport-adapter-gems) | Communication channels are a contract gem plus per-transport adapter gems | Accepted 2026-08-10 |
| [042](../../docs/design-v0.1/DECISIONS.md#adr-042--the-channel-gateway-is-a-separate-process-in-the-connector-zone) | The channel gateway is a separate process in the connector zone | Accepted 2026-08-10 |
| [043](../../docs/design-v0.1/DECISIONS.md#adr-043--telegram-v1-is-deny-only-and-reference-bound) | Telegram v1 is deny-only and reference-bound | Accepted 2026-08-10 |
| [044](../../docs/design-v0.1/DECISIONS.md#adr-044--observability-is-a-contract-gem-plus-per-exporter-adapter-gems) | Observability is a contract gem plus per-exporter adapter gems | Accepted 2026-08-10 |
| [045](../../docs/design-v0.1/DECISIONS.md#adr-045--the-observability-gems-add-no-durable-table-and-no-second-source-of-truth) | The observability gems add no durable table and no second source of truth | Accepted 2026-08-10 |
| [046](../../docs/design-v0.1/DECISIONS.md#adr-046--content-capture-is-off-by-default-per-class-and-refused-for-restricted-classifications) | Content capture is off by default, per class, and refused for restricted classifications | Accepted 2026-08-10 |
| [047](../../docs/design-v0.1/DECISIONS.md#adr-047--sampling-applies-to-export-only-and-never-to-safety-bearing-signals) | Sampling applies to export only and never to safety-bearing signals | Accepted 2026-08-10 |
| [048](../../docs/design-v0.1/DECISIONS.md#adr-048--one-digest-bound-openai-compatible-model-transport) | One digest-bound OpenAI-compatible model transport | Accepted 2026-08-26 |
| 048 | Automated responses act only on durable evidence under an owning subsystem | Proposed — observability phase 5 |
| [049](./adr-049-telegram-approval.md) | Telegram approval is evidence-gated, not transport-gated | Accepted 2026-08-12 |

## Notes

- **Superseded.** ADR-012 (MCP as a deferred integration strategy) is superseded in detail by ADR-029 (MCP native at the edge); its post-v0.1 timing is retained.
- **Superseded.** ADR-003 is retained as historical provenance; ADR-048 is the current model transport decision.
- **Revised.** ADR-002, ADR-004, ADR-010, and ADR-013 were revised after review or counterexample; their entries in `DECISIONS.md` record what changed.
- **Standalone page.** ADR-049 is published as a standalone public page because it amends the shipped channel approval path; it also appears in the [`../design/comms.md`](../design/comms.md) decision list.
- The `DECISIONS.md` file also carries open product questions (the first physical environment for Tamoz Agent) that are not ADRs.

## Next reads

- [`adr-049-telegram-approval.md`](./adr-049-telegram-approval.md) — the evidence-gated approval decision
- [`../design/README.md`](../design/README.md) — public design summaries by subsystem
- [`../design/comms.md`](../design/comms.md) — the channel/communications design and its ADR list
- [`../../docs/design-v0.1/DECISIONS.md`](../../docs/design-v0.1/DECISIONS.md) — the authoritative decision record
- [`../README.md`](../README.md) — documentation home

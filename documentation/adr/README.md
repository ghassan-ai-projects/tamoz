# Architecture decision records

Tamoz's architecture decisions: one decision per file, one rubric, one catalog. This directory holds
only the decisions and the rules for writing them.

## How to use these ADRs

- **By number:** open `adr-<NNN>-*.md`. Retired numbers keep a short tombstone.
- **By area:** the index below groups decisions by the part of the system they govern.
- **Read one:** every ADR has the same header (`Status`, `Date`, `Tier`, `Implementation`, relations)
  and the same sections in the same order: Context, Decision, Consequences, Invariants and Threat
  model (Tier F), optional History. Implementation evidence lives in [evidence.md](./evidence.md). `Implementation:` says
  plainly when part of a decision is not built.
- **As data:** [`catalog.json`](./catalog.json) is generated from the files (`rake adr:catalog`).
- **Write one:** [`LIFECYCLE.md`](./LIFECYCLE.md) for the workflow, [`_TEMPLATE.md`](./_TEMPLATE.md) for
  the skeleton, [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) for the rubric.

## Tooling

| Command | Checks |
|---|---|
| `rake adr:catalog` | Regenerates `catalog.json` |
| `rake adr:validate` | Numbering, header fields, required sections per tier, banned boilerplate, reciprocal relations, links, index coverage, catalog sync |
| `rake adr:verify` | Every backticked path, gem, and `test_*` name in the separate evidence register exists (a cell that says a path was removed checks the opposite) |
| `rake adr:trace`, `rake adr:graph` | Regenerate `traceability.md` and `relationships.md` |

Green tooling means the mechanical checks pass. Whether an ADR is true is a review (bar §7).

## ADR index

Tier **F** decisions draw a safety, authority, effect, or data boundary. **Partial** means part of the
decision is not built; the ADR says which part.

### Identity, packaging, and evolution

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [001](./adr-001-framework-is-tamoz-the-reference-application-is-tamoz-agent.md) | The framework is Tamoz; the reference application is Tamoz Agent | C | Complete |
| [013](./adr-013-public-vocabulary-is-a-budget-never-a-correctness-cap.md) | Public concepts are documented and introduced when needed | C | Complete |
| [014](./adr-014-extensions-are-first-party-adapter-gems-not-plugins.md) | Extensions are first-party adapter gems, not plugins | F | Complete |
| [040](./adr-040-one-monorepo-multiple-independently-publishable-gems.md) | One monorepo, multiple independently publishable gems | C | Complete |
| [052](./adr-052-a-gem-owns-one-dependency-boundary-and-is-reached-only-through-its-facade.md) | A gem owns one dependency boundary and is reached only through its facade | C | Partial |
| [056](./adr-056-skills-gem.md) | Skills are a gem, `tamoz-skills`, reached through one facade | C | Complete |
| [059](./adr-059-no-backward-compatibility-before-1-0.md) | No backward compatibility before 1.0 | C | Partial |

### Graph runtime and state

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [005](./adr-005-interrupt-by-throw-not-by-exception.md) | Interrupt by `throw`, not by exception | C | Complete |
| [006](./adr-006-plain-hash-state-with-an-explicit-reducer-registry.md) | Plain Hash state with an explicit reducer registry | C | Complete |
| [007](./adr-007-frozen-state-is-handed-to-nodes.md) | Frozen state is handed to nodes | C | Complete |
| [008](./adr-008-threads-is-the-default-pool-inline-in-tests.md) | `:threads` is the default pool; `:inline` in tests | C | Complete |
| [009](./adr-009-the-model-request-prefix-is-byte-stable-within-a-cache-epoch.md) | The model request prefix is byte-stable within a cache epoch | C | Complete |

### Durability and effects

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [011](./adr-011-sqlite-is-tamoz-agent-s-default-persistence.md) | SQLite is Tamoz Agent's default persistence | C | Complete |
| [015](./adr-015-durable-means-synchronous-barrier-commit.md) | Durable means synchronous barrier commit | F | Complete |
| [016](./adr-016-every-external-effect-is-journaled-and-ambiguity-stops-as-unknown.md) | Every external effect is journaled, and ambiguity stops as `:unknown` | F | Complete |
| [017](./adr-017-one-fenced-writer-per-thread-namespace.md) | One fenced writer per thread namespace | F | Complete |
| [018](./adr-018-strict-sequence-is-separate-from-checkpoint-identity.md) | Strict sequence is separate from checkpoint identity | C | Complete |
| [019](./adr-019-resume-is-graph-version-checked.md) | Resume is graph-version checked | F | Complete |
| [021](./adr-021-resume-preserves-execution-identity-fork-changes.md) | Resume preserves execution identity; fork changes it | F | Complete |
| [057](./adr-057-a-user-stop-ends-the-turn-it-never-aborts-the-graph.md) | A user's stop ends the turn; it never aborts the graph | F | Complete |

### Agent authority: plans, approval, capabilities

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [022](./adr-022-reviewed-plan-gate.md) | Every task action requires a reviewed, digest-bound plan | F | Partial |
| [030](./adr-030-one-local-capability-catalog-governs-all-sources.md) | One local capability catalog governs all sources | F | Complete |
| [053](./adr-053-approval-gem.md) | Approval policy is data, decided by one gem, `tamoz-approval` | F | Complete |
| [049](./adr-049-chat-approval-is-evidence-gated-and-bound-to-one-exact-prompt.md) | Chat approval is evidence-gated and bound to one exact prompt | F | Complete |
| [029](./adr-029-mcp-is-native-at-the-edge-and-uses-the-official-ruby-sdk.md) | MCP is native at the edge and uses the official Ruby SDK | F | Complete |
| [054](./adr-054-websearch-capability-source.md) | Websearch is the fourth capability source, a reserved MCP server with governed egress | F | Complete |
| [033](./adr-033-skills-use-the-open-agent-skills-format-and-stay-an-agent-recipe.md) | Skills use the open Agent Skills format and stay an agent recipe | F | Complete |
| [034](./adr-034-skill-identity-is-a-tree-digest-activation-is-supply-chain-promotion.md) | Skill identity is a tree digest; activation is supply-chain promotion | F | Partial |

### Data protection

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [020](./adr-020-secrets-are-refused-by-type-or-explicitly-protected-never-scrubbed-by-name.md) | Secrets are refused by type or explicitly protected, never scrubbed by name | F | Partial |
| [046](./adr-046-content-capture-is-off-by-default-per-class-and-refused-for-restricted.md) | Content capture is off by default, per class, and refused for restricted classes | F | Complete |

### Memory and learning

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [026](./adr-026-three-durable-memory-layers-experience-knowledge-wisdom.md) | Three durable memory layers: Experience, Knowledge, Wisdom | F | Complete |
| [027](./adr-027-memory-retrieval-is-authorization-consolidation-preserves-disagreement.md) | Memory retrieval is authorization; consolidation preserves disagreement | F | Complete |
| [023](./adr-023-self-improvement-promotion.md) | Self-improvement is candidate promotion, never live self-mutation | F | Partial |
| [028](./adr-028-self-healing-is-bounded-remediation-not-catch-and-retry.md) | Self-healing is bounded remediation, not catch-and-retry | F | Complete |

### Evaluation and evidence

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [024](./adr-024-smart-means-evidence-based-proportional-and-verified.md) | "Smart" means evidence-based, proportional, and verified | C | Partial |
| [025](./adr-025-evaluation-is-a-first-class-non-runtime-gem.md) | Evaluation is a first-class non-runtime gem | F | Complete |
| [058](./adr-058-domain-knowledge-is-digest-pinned-data-never-code.md) | Domain knowledge is digest-pinned data, never code | C | Partial |

### Scheduling

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [031](./adr-031-scheduling-materializes-occurrences-it-does-not-run-agents.md) | Scheduling materializes occurrences; it does not run agents | C | Complete |
| [032](./adr-032-scheduled-time-and-delayed-authority-are-explicit.md) | Scheduled time and delayed authority are explicit | F | Partial |

### Model boundary

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [048](./adr-048-tamoz-owns-the-model-boundary-one-digest-bound-openai-compatible-transport.md) | Tamoz owns the model boundary: one digest-bound OpenAI-compatible transport | F | Complete |

### Channels

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [041](./adr-041-communication-channels-are-a-contract-gem-plus-per-transport-adapter-gems.md) | Communication channels are a contract gem plus per-transport adapter gems | C | Complete |
| [042](./adr-042-channel-gateway-is-a-separate-process-in-the-connector-zone.md) | The channel gateway is a separate process in the connector zone | F | Complete |

### Observability

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [044](./adr-044-observability-is-a-contract-gem-plus-per-exporter-adapter-gems.md) | Observability is a contract gem plus per-exporter adapter gems | C | Complete |
| [045](./adr-045-observability-gems-add-no-durable-table-and-no-second-source-of-truth.md) | The observability gems add no durable table and no second source of truth | C | Complete |
| [047](./adr-047-telemetry-is-never-sampled-at-record-time-and-safety-bearing-signals-have-a-reserved-lane.md) | Telemetry is never sampled at record time, and safety-bearing signals have a reserved lane | F | Complete |
| [050](./adr-050-automated-response-durable-evidence.md) | Automated responses act only on durable evidence, under the subsystem that owns the effect | F | Proposed |

### Streaming and physical action

| ADR | Decision | Tier | Implementation |
|---|---|---|---|
| [036](./adr-036-cognition-sees-only-a-sealed-situation-snapshot-never-raw-evidence.md) | Cognition sees only a sealed Situation snapshot, never raw evidence | F | Complete |
| [038](./adr-038-physical-action-is-typed-intent-plus-current-state-policy-never-model-effect.md) | Physical action is typed intent plus current-state policy, never model effect | F | Complete |
| [039](./adr-039-tamoz-is-supervisory-certified-safety-and-real-time-control-stay-external.md) | Tamoz is supervisory; certified safety and real-time control stay external | F | Complete |
| [055](./adr-055-two-repo-authority-split.md) | The continuous plane is a separate Go authority; Tamoz is its episode worker | F | Partial |

### Retired

| ADR | Decision | Replaced by |
|---|---|---|
| [002](./retired/adr-002-four-v0-1-runtime-gems.md) | ~~Four v0.1 runtime gems~~ | 052 |
| [003](retired/adr-003-reuse-rubyllm-public-values.md) | ~~Reuse RubyLLM public values; durable codec~~ | 048 |
| [004](retired/adr-004-explicit-tamoz-seq-no-native-proc.md) | ~~Explicit `Tamoz.seq`; no native `Proc#>>`~~ | withdrawn |
| [010](retired/adr-010-ruby-3-3-floor-3-4-and-4-0-primary-targets.md) | ~~Ruby 3.3 floor; 3.4 and 4.0 targets~~ | withdrawn |
| [012](retired/adr-012-mcp-deferred-integration.md) | ~~MCP is a deferred integration strategy~~ | 029 |
| [035](retired/adr-035-streaming-input-is-a-distinct-first-class-runtime.md) | ~~Streaming input is a distinct first-class runtime~~ | 036, 055 |
| [037](retired/adr-037-event-time-explicit-backpressure-and-effect-disabled-replay-are-contracts.md) | ~~Event time, explicit backpressure, and effect-disabled replay are contracts~~ | 055 |
| [043](retired/adr-043-telegram-v1-is-deny-only-and-reference-bound.md) | ~~Telegram v1 is deny-only and reference-bound~~ | 049 |
| [051](retired/adr-051-rubyllm-removed.md) | ~~RubyLLM is removed from the runtime~~ | 048 |

What each said and why it died: [`RETIRED.md`](./RETIRED.md).

**Next number to assign: 060.**

## Other files here

| File | Purpose |
|---|---|
| [`design-refusals.md`](./design-refusals.md) | What Tamoz deliberately does not build, each row pointing at its owning ADR |
| [`traceability.md`](./traceability.md) | Generated ADR ↔ gem ↔ invariant ↔ test matrix |
| [`relationships.md`](./relationships.md) | Generated graph of supersession and amendment edges |

Reviews and audits of this corpus live outside it: the 2026-08-29 audit in
[`docs/adr-audit-2026-08-29.md`](../../docs/adr-audit-2026-08-29.md) and the current review in
[`docs/adr-review-2026-09-29/`](../../docs/adr-review-2026-09-29/README.md).

## Next reads

- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — the rubric
- [`../architecture/invariants.md`](../architecture/invariants.md) — the invariant contract
- [`../design/README.md`](../design/README.md) — design summaries by subsystem

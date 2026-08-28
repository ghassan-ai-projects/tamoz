# Architecture decision records

Tamoz records its architecture decisions as numbered ADRs. This is the single authoritative
catalog: every decision that exists appears here exactly once, with its current status and a
link to its text. There are no RFC-style proposal documents in the repository.

Current version: `0.1.0.alpha.1` (pre-release).

## How this directory is organized

| File | What it holds |
|---|---|
| [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) | The bar every ADR is held to: what an ADR is, the required structure, the grading rubric, and the end goal. Start here to author or judge an ADR. |
| [`core-decisions.md`](./core-decisions.md) | The living log of **in-force foundational decisions** — stable runtime/agent/subsystem axioms stated as one rule. |
| `adr-NNN-*.md` | **Standalone pages** for decisions that carry a threat model, a change-bar, or an amendment history. |
| [`RETIRED.md`](./RETIRED.md) | Superseded and retired decisions, one line each. Numbers are never reused. |
| [`AUDIT_2026-08-29.md`](./AUDIT_2026-08-29.md) | The deep audit that produced this structure, the per-ADR scorecard, and the loop that drives the corpus to the bar. |

The former monolith `docs/design-v0.1/DECISIONS.md` was **removed** (2026-08-29) — its in-force
decisions moved to `core-decisions.md` and the pages, its dead ones to `RETIRED.md`, and its two
open product questions to the [roadmap](../roadmap.md#open-product-questions). One source of
truth, not two.

## ADR index

Status legend: **Accepted** in force · **Proposed** ratified before implementation ·
**Retired** superseded/withdrawn (see `RETIRED.md`).

| ADR | Title | Status | Where |
|---|---|---|---|
| 001 | The framework is Tamoz; the reference app is Tamoz Agent | Accepted | [log](./core-decisions.md#adr-001--the-framework-is-tamoz-the-reference-application-is-tamoz-agent) |
| 002 | ~~Four v0.1 runtime gems~~ | Retired → 052 | [retired](./RETIRED.md) |
| 003 | ~~Reuse RubyLLM public values; durable codec~~ | Retired → 048 + 051 | [retired](./RETIRED.md) |
| 004 | Explicit `Tamoz.seq`; no native `Proc#>>` | Accepted (revised) | [log](./core-decisions.md) |
| 005 | Interrupt by `throw`, not by exception | Accepted | [log](./core-decisions.md) |
| 006 | Plain Hash state with an explicit reducer registry | Accepted | [log](./core-decisions.md) |
| 007 | Frozen state is handed to nodes | Accepted | [log](./core-decisions.md) |
| 008 | `:threads` default pool; `:inline` in tests | Accepted | [log](./core-decisions.md) |
| 009 | Prompt-cache stability is invariant 16 | Accepted | [log](./core-decisions.md) |
| 010 | Ruby 3.3 floor; 3.4 and 4.0 primary targets | Accepted (revised) | [log](./core-decisions.md) |
| 011 | SQLite is Tamoz Agent's default persistence | Accepted | [log](./core-decisions.md) |
| 012 | ~~MCP is a deferred integration strategy~~ | Retired → 029 | [retired](./RETIRED.md) |
| 013 | Public vocabulary is a budget, never a correctness cap | Accepted (revised) | [log](./core-decisions.md) |
| 014 | No plugin API in v0.1 | Accepted | [log](./core-decisions.md) |
| 015 | Durable means synchronous barrier commit | Accepted | [log](./core-decisions.md) |
| 016 | External effects are at-least-once unless proven otherwise | Accepted | [log](./core-decisions.md) |
| 017 | One fenced writer per thread namespace | Accepted | [log](./core-decisions.md) |
| 018 | Strict sequence is separate from checkpoint identity | Accepted | [log](./core-decisions.md) |
| 019 | Resume is graph-version checked | Accepted | [log](./core-decisions.md) |
| 020 | Sensitive-data policy is explicit and lossless | Accepted | [log](./core-decisions.md) |
| 021 | Resume preserves execution identity; fork changes it | Accepted | [log](./core-decisions.md) |
| **022** | **Every task action requires a reviewed, digest-bound plan** | Accepted | [page](./adr-022-reviewed-plan-gate.md) |
| **023** | **Self-improvement is candidate promotion, never live self-mutation** | Accepted | [page](./adr-023-self-improvement-promotion.md) |
| 024 | "Smart" means evidence-based, proportional, and verified | Accepted | [log](./core-decisions.md) |
| 025 | Evaluation is a first-class non-runtime gem | Accepted | [log](./core-decisions.md) |
| 026 | Three durable memory layers: Experience, Knowledge, Wisdom | Accepted | [log](./core-decisions.md) |
| 027 | Memory retrieval is authorization; consolidation preserves disagreement | Accepted | [log](./core-decisions.md) |
| 028 | Self-healing is bounded remediation, not catch-and-retry | Accepted | [log](./core-decisions.md) |
| 029 | MCP is native at the edge and uses the official Ruby SDK | Accepted (shipped) | [log](./core-decisions.md#adr-029--mcp-is-native-at-the-edge-and-uses-the-official-ruby-sdk) |
| 030 | One local capability catalog governs all sources | Accepted (extended → 054) | [log](./core-decisions.md#adr-030--one-local-capability-catalog-governs-all-sources) |
| 031 | Scheduling materializes occurrences; it does not run agents | Accepted (shipped) | [log](./core-decisions.md) |
| 032 | Scheduled time and delayed authority are explicit | Accepted | [log](./core-decisions.md) |
| 033 | Skills use the open Agent Skills format and stay an agent recipe | Accepted | [log](./core-decisions.md) |
| 034 | Skill identity is a tree digest; activation is supply-chain promotion | Accepted | [log](./core-decisions.md) |
| 035 | Streaming input is a distinct first-class runtime | Accepted (revised → 055) | [log](./core-decisions.md#adr-035--streaming-input-is-a-distinct-first-class-runtime) |
| 036 | Situation is the boundary between continuous evidence and episodic cognition | Accepted | [log](./core-decisions.md) |
| 037 | Event time, explicit backpressure, and effect-disabled replay are contracts | Accepted (revised → 055) | [log](./core-decisions.md) |
| 038 | Physical action is typed intent plus current-state policy | Accepted | [log](./core-decisions.md) |
| 039 | Tamoz is supervisory; certified safety and real-time control stay external | Accepted | [log](./core-decisions.md) |
| 040 | One monorepo, multiple independently publishable gems | Accepted (→ 052) | [log](./core-decisions.md#adr-040--one-monorepo-multiple-independently-publishable-gems) |
| 041 | Communication channels are a contract gem plus per-transport adapters | Accepted | [log](./core-decisions.md) |
| 042 | The channel gateway is a separate process in the connector zone | Accepted | [log](./core-decisions.md) |
| 043 | Telegram v1 is deny-only and reference-bound | Accepted (amended → 049) | [log](./core-decisions.md#adr-043--telegram-v1-is-deny-only-and-reference-bound) |
| 044 | Observability is a contract gem plus per-exporter adapters | Accepted | [log](./core-decisions.md) |
| 045 | The observability gems add no durable table | Accepted | [log](./core-decisions.md) |
| 046 | Content capture is off by default, per class | Accepted | [log](./core-decisions.md) |
| 047 | Sampling applies to export only, never to safety-bearing signals | Accepted | [log](./core-decisions.md) |
| 048 | One digest-bound OpenAI-compatible model transport | Accepted (completed → 051) | [log](./core-decisions.md#adr-048--one-digest-bound-openai-compatible-model-transport) |
| **049** | **Telegram approval is evidence-gated, not transport-gated** | Accepted | [page](./adr-049-telegram-approval.md) |
| **050** | **Automated responses act only on durable evidence** | Proposed | [page](./adr-050-automated-response-durable-evidence.md) |
| **051** | **RubyLLM is removed from the runtime** | Accepted | [page](./adr-051-rubyllm-removed.md) |
| **052** | **`tamoz-agent` is decomposed into focused gems** | Accepted | [page](./adr-052-agent-gem-decomposition.md) |
| **053** | **Approval policy is isolated into `tamoz-approval`** | Accepted | [page](./adr-053-approval-gem.md) |
| **054** | **Websearch is the fourth capability source** | Accepted | [page](./adr-054-websearch-capability-source.md) |
| **055** | **Continuous plane is a separate Go authority (`agentic-stream`); Tamoz is its episode worker** | Accepted | [page](./adr-055-two-repo-authority-split.md) |

Next number to assign: **056**.

## Notes

- **The 048 collision is resolved.** The observability-automation decision that had also taken
  048 is now ADR-050; the model-transport decision keeps 048.
- **The record is reality-checked.** Every implemented decision carries a dated Verification
  line (in its page or log entry) stating the gem/symbol/test that backs it. See the audit for
  the method.
- **Amendment chains:** 002→052, 003→048+051, 012→029, 043→049, 040→052, 030→054, 048→051,
  035→055, 037→055, 040→055 (deliberate two-repo exception).

## Next reads

- [`ADR_QUALITY_BAR.md`](./ADR_QUALITY_BAR.md) — the bar and the authoring template
- [`AUDIT_2026-08-29.md`](./AUDIT_2026-08-29.md) — the deep audit and loop scorecard
- [`adr-049-telegram-approval.md`](./adr-049-telegram-approval.md) — the reference-quality ADR
- [`../design/README.md`](../design/README.md) — public design summaries by subsystem

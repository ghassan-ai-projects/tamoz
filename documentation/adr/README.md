# Architecture decision records

Tamoz records its architecture decisions as numbered ADRs. This index catalogs ADR-001 through ADR-049 with their current status; each entry's full rationale lives in the authoritative design record.

Tamoz records decisions as ADRs, not RFCs; there are no RFC-style proposal documents in the repository.

## Where the decisions live

ADR-001 through ADR-047 are sections of the authoritative design record, [`docs/design-v0.1/DECISIONS.md`](../../docs/design-v0.1/DECISIONS.md), which remains the source of truth for their full text. ADR-044 through ADR-048 are additionally stated in the observability design ([`docs/OBSERVABILITY_DESIGN.md`](../../docs/OBSERVABILITY_DESIGN.md), contract-changes section), and ADR-041 through ADR-043 plus ADR-049 appear in the channel design ([`../design/comms.md`](../design/comms.md)). ADR-049 is the only decision with a standalone page: [`./adr-049-telegram-approval.md`](./adr-049-telegram-approval.md).

Current version: `0.1.0.alpha.1` (pre-release).

## ADR index

| ADR | Title | Status |
|---|---|---|
| 001 | Tamoz framework and Tamoz Agent reference application | Accepted 2026-07-30 |
| 002 | Four v0.1 runtime gems; optional packages earn promotion | Revised |
| 003 | Reuse RubyLLM public values at runtime; define a lossless durable codec | Accepted |
| 004 | Explicit `Tamoz.seq`; no native `Proc#>>` | Revised |
| 005 | Interrupt by `throw`, not by exception | Accepted |
| 006 | Plain Hash state with an explicit reducer registry | Accepted |
| 007 | Frozen state handed to nodes | Accepted |
| 008 | `:threads` as the default pool, `:inline` in tests | Accepted |
| 009 | Prompt-cache stability as invariant 16 | Accepted |
| 010 | Ruby 3.3 floor; 3.4 and 4.0 primary targets | Revised |
| 011 | SQLite as Tamoz Agent's default persistence | Accepted |
| 012 | MCP is a deferred integration strategy | Superseded by ADR-029 |
| 013 | Public vocabulary budget, never a correctness cap | Revised |
| 014 | No plugin API in v0.1 | Accepted |
| 015 | Durable means synchronous barrier commit | Accepted |
| 016 | External effects are at-least-once unless proven otherwise | Accepted |
| 017 | One fenced writer per thread namespace | Accepted |
| 018 | Strict sequence is separate from checkpoint identity | Accepted |
| 019 | Resume is graph-version checked | Accepted |
| 020 | Sensitive data policy is explicit and lossless | Accepted |
| 021 | Resume preserves execution identity; fork changes it | Accepted |
| 022 | Every task action requires a reviewed plan | Accepted 2026-07-30 |
| 023 | Self-improvement is candidate promotion, never live self-mutation | Accepted 2026-07-30 |
| 024 | "Smart" means evidence-based, proportional, and verified | Accepted 2026-07-30 |
| 025 | Evaluation is a first-class non-runtime gem | Accepted 2026-07-30 |
| 026 | Three durable memory layers: Experience, Knowledge, Wisdom | Accepted 2026-07-30 |
| 027 | Memory retrieval is authorization; consolidation preserves disagreement | Accepted 2026-07-30 |
| 028 | Self-healing is bounded remediation, not catch-and-retry | Accepted 2026-07-30 |
| 029 | MCP is native at the edge and uses the official Ruby SDK | Accepted 2026-07-30 |
| 030 | One local capability catalog governs local tools, MCP, and skills | Accepted 2026-07-30 |
| 031 | Scheduling materializes occurrences; it does not run agents | Accepted 2026-07-30 |
| 032 | Scheduled time and delayed authority are explicit | Accepted 2026-07-30 |
| 033 | Skills use the open Agent Skills format and stay in `tamoz-agent` | Accepted 2026-07-30 |
| 034 | Skill identity is a tree digest and activation is supply-chain promotion | Accepted 2026-07-30 |
| 035 | Streaming input is a distinct first-class `tamoz-stream` runtime | Accepted 2026-07-30 |
| 036 | Situation is the boundary between continuous evidence and episodic cognition | Accepted 2026-07-30 |
| 037 | Event time, explicit backpressure, and effect-disabled replay are contracts | Accepted 2026-07-30 |
| 038 | Physical action is typed intent plus current-state policy, never model effect | Accepted 2026-07-30 |
| 039 | Tamoz is supervisory; certified safety and real-time control stay external | Accepted 2026-07-30 |
| 040 | One monorepo, multiple independently publishable gems | Accepted 2026-07-30 |
| 041 | Communication channels are a contract gem plus per-transport adapter gems | Accepted 2026-08-10 |
| 042 | The channel gateway is a separate process in the connector zone | Accepted 2026-08-10 |
| 043 | Telegram v1 is deny-only and reference-bound | Accepted 2026-08-10 |
| 044 | Observability is a contract gem plus per-exporter adapter gems | Accepted 2026-08-10 |
| 045 | The observability gems add no durable table and no second source of truth | Accepted 2026-08-10 |
| 046 | Content capture is off by default, per class, and refused for restricted classifications | Accepted 2026-08-10 |
| 047 | Sampling applies to export only and never to safety-bearing signals | Accepted 2026-08-10 |
| 048 | Automated responses act only on durable evidence under an owning subsystem | Proposed — observability phase 5 |
| 049 | Telegram approval is evidence-gated, not transport-gated | Accepted 2026-08-12 |

## Notes

- **Superseded.** ADR-012 (MCP as a deferred integration strategy) is superseded in detail by ADR-029 (MCP native at the edge); its post-v0.1 timing is retained.
- **Revised.** ADR-002, ADR-004, ADR-010, and ADR-013 were revised after review or counterexample; their entries in `DECISIONS.md` record what changed.
- **Standalone page.** ADR-049 is published as a standalone public page because it amends the shipped channel approval path; it also appears in the [`../design/comms.md`](../design/comms.md) decision list and the `DECISIONS.md` companion text.
- The `DECISIONS.md` file also carries open product questions (the first physical environment for Tamoz Agent) that are not ADRs.

## Next reads

- [`adr-049-telegram-approval.md`](./adr-049-telegram-approval.md) — the evidence-gated approval decision
- [`../design/README.md`](../design/README.md) — public design summaries by subsystem
- [`../design/comms.md`](../design/comms.md) — the channel/communications design and its ADR list
- [`../../docs/design-v0.1/DECISIONS.md`](../../docs/design-v0.1/DECISIONS.md) — the authoritative decision record
- [`../README.md`](../README.md) — documentation home

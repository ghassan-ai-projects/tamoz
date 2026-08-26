# Tamoz gem-boundary audit — 2026-08-25

This is the replacement for the earlier shortlist. It is a full boundary
audit of the current 24-gem tree, not a list of large files that look movable.

## Result

Two candidates meet the bar for a planned extraction now:

1. **`tamoz-mcp-websearch`** — make the existing governed-websearch adapter
   boundary enforceable in packaging.
2. **`tamoz-evals-runner`** — separate evidence verification from the large
   runtime-coupled scenario and benchmark harness.

Two further seams deserve design spikes, but do not yet meet the implementation
bar: an MCP-dependent agent bridge and a Comms gateway/drainer package. SSE is
an optionalization candidate, not an immediate gem move, because no production
consumer is visible in this repository. RubyLLM is technically movable but is
deferred until the provider/profile/evals composition is untangled.

One additional seam, `tamoz-tools`' Agent Skills subtree, is a credible future
candidate but is not accepted into the immediate sequence: it has no load or
dependency payoff until the toolbox is deliberately made to consume an
optional skills package. The report records it as deferred rather than turning
file count into a fake extraction.

## Documents

| Document | Purpose |
|---|---|
| [00-quality-bar.md](00-quality-bar.md) | Frozen scope, stop bar, evidence rules, and limits |
| [01-current-inventory.md](01-current-inventory.md) | Every current gem, measured size, declared dependencies, and architecture notes |
| [02-candidate-assessments.md](02-candidate-assessments.md) | Source-grounded candidate assessments with proposed target topology |
| [03-rejected-and-deferred.md](03-rejected-and-deferred.md) | Tempting splits that fail the boundary bar, plus blind spots |
| [04-sequencing-and-gates.md](04-sequencing-and-gates.md) | Extraction order, per-phase gates, and the loop for future scans |
| [05-specialist-review.md](05-specialist-review.md) | Independent specialist passes, reconciliation, and static-tool evidence |

## Important boundary

This audit is design evidence only. No production code was changed and no
tests were run. Existing concurrent worktree edits were treated as read-only.
The `enola` snapshot was generated for architecture facts and heuristics; its
receipt reports 575 parsed files, zero parse errors, 12,631 facts, 0 detected
cycles, and 51 heuristic insights over a dirty tree. Heuristic findings are
treated as leads, not verdicts.

## Existing documentation drift found during the scan

[`documentation/architecture/gems.md`](../../documentation/architecture/gems.md)
still describes a 17-gem topology while the current tree contains 24 gems and
the root README documents the newer agent decomposition. This audit does not
silently rewrite that public page; the drift is recorded as a follow-up gate in
[01-current-inventory.md](01-current-inventory.md).

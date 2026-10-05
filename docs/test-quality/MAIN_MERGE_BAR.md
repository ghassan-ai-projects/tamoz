# Main integration quality bar

**Task:** Merge current main into improve-the-tests. **Size:** S. **Set:** 2026-10-05, before resolving conflicts.

## Outcome and seam

Integrate origin/main e47bb010, preserve both branches, resolve generated audit evidence using the existing generator, and publish a normal merge commit. No feature changes or subagents; the owner explicitly prohibited delegation.

| Row | Check | Status |
|---|---|---|
| B1 | Resolve all three conflicts, retain both testing-guidance additions, and retain both branches in the normal merge. | PASS: no unmerged entries or conflict markers; merge parents verified during delivery. |
| B2 | Regenerate requirements audit against merged manifest; report failing evidence honestly. | PASS: final generator run completed 307 named cases, no failed cases; 582 requirements, 554 pass, 11 deferred, 3 indirect, 14 missing release-blocking gaps remain. |
| D1 | Run repository fast CI; distinguish known compiler blocker from merge regressions. | BLOCKED: all 330 fast files, design, ADR, and syntax checks passed; existing grpc-tools x86_64-macos protoc raises EBADARCH on this Mac. Previously reproduced at the branch baseline. |
| D2 | Check merged manifest, documentation CLI surface, new slow scale test, and scoreboard portability. | PASS: respectively 11/3298, 9/91, 1/4, 3/23 runs/assertions, no failures, errors, or skips. |
| E1 | Review conflict resolutions and overlapping code changes; no unintended behavior edits. | PASS: local review of runner, documentation surface, observability test, evidence, and manifest additions; no manual code resolutions needed. |
| F1 | Keep the evidence limits explicit. | PASS: deterministic tests only; no real-model claims. Full local CI remains blocked as stated above. |

## Review and loop

Local review substitutes for delegation under the owner's explicit no-subagents instruction. Testing guidance retains both sides. Generated files come from the merged manifest, not hand-edited status counts. The first audit run encountered conflict markers in the audit JSON; the documentation test passed after resolution and the complete audit was rerun successfully. The final review found no further change needed. Upstream Markdown hard-break whitespace was retained.

Delivery verifies both parents are ancestors of the merge and the pushed remote head equals the local commit. No force push.

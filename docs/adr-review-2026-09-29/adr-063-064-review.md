# Semantic review — ADR-063, ADR-064, and the ADR-016 addition

**Date:** 2026-11-04 · **Reviewer:** independent subagent, not the author; read-only · **Verdict:** approved after two rounds of corrections

Checked A4, A6, A7 and E7 of `documentation/adr/ADR_QUALITY_BAR.md` against the code and the cited tests.

**Corrected before approval:**

- ADR-063 described one behavior for all paths. The worker refuses, the gateway opens a new thread, and the CLI keeps the pinned digest.
- ADR-063 implied every worker path caches a profile. Only the thread path does; the child path reloads.
- ADR-063 cited no test for the worker's refusal, though one exists.
- ADR-064 omitted the metadata a turn keeps: name, type, size and digest.
- The lease rule moved to ADR-016, whose start and resolution rows now name the active lease.

**Open items:**

- Two lease checks (start and resolve) are verified by source inspection, not by a run in this review.
- A binding with no digest, and the gateway's new-thread path, are verified by source inspection only.
- A stale owner can close an effect as `completed` on evidence nothing verifies; recorded in ADR-016 as residual risk.

# Tamoz functionality audit — 2026-09-15

This package is the index and quality bar for a read-only, functionality-by-
functionality audit of the current Tamoz checkout. It follows the real source
paths end to end and records gaps and weaknesses with evidence. It does not
implement fixes.

The baseline is branch `audit-15-09`, commit `582ae55`, with a clean worktree
when setup began on 2026-09-15. The live tree has 27 gem library directories.
The root README is the responsibility map (`README.md:16-46`); [COVERAGE.md](COVERAGE.md)
maps every gem exactly once and keeps apps, entry points, support scripts, and
cross-gem flows in separate inventories.

## How the audit runs

The coordinator owns the queue, the evidence bar, synthesis, and the final
coverage decision. The normal delegated lane uses a short, bounded brief to a
read-only `gpt-5.6-luna` analyst at the maximum supported thinking level. For
the current owner-directed continuation, the coordinator is performing those
bounded source reviews directly because subagent delegation was explicitly
paused; the quality bar and report shape are unchanged. Each review reads the
actual implementation and relevant behavior contracts, tests, callers, and
documentation, then records verified findings under this folder. A scanner may
supply inventory, search, Enola, or quality-signal leads, but a scanner lead is
never a finding or a completed review until an analyst confirms it.

The coordinator then checks citations, challenges the reasoning, reconciles
overlap with earlier audits, and records a disposition. Critical and major
findings require a five-whys root-cause chain and a recommendation at the
existing owning seam. The loop proceeds through all queue groups, then checks
the cross-gem flows and support surfaces. A functionality is complete only
when its scanner and independent analyst states, source/test evidence, finding
dispositions, and blind spots are recorded in [COVERAGE.md](COVERAGE.md).

## Current synthesis checkpoint

The shared audit package now contains 42 JSON analyst records expanding to 53
row surfaces: all 27 gem responsibilities, the reference app and executable
surfaces, the aggregate script/Rakefile rows, and CF01–CF13. The current analyst
snapshot has 44 `IMPROVE` and 8 `PASS` verdicts. All rows now have a scalability
assessment; eight retain explicit sustained-load measurement gaps documented in
`analyses/scalability-lens-review.md`. The standalone scanner passes cover every
gem/app/executable/support/Rakefile inventory and CF01–CF13; cross-flow analyst
review and synthesis remain open, so no row is closed.

The latest bounded waves added standalone F13 (approval), F18 (capabilities),
F21 (profile), F25 (runtime), and F26 (evals evidence) reports and independent
challenge records. Their coordinator dispositions are recorded in
[FINDINGS.md](FINDINGS.md), with remaining work tracked in
[CHECKPOINT.md](CHECKPOINT.md). The package remains read-only: reports identify
production gaps but do not implement fixes. The challenger-added F20-REL-02
finding was independently re-reviewed before it was accepted into the index.
CF01–CF13 now have direct end-to-end reports. CF03, CF04, CF05, CF06, CF07,
CF08, CF09, CF10, CF11, CF12, and CF13 carry existing authority, reliability,
replay, control-routing, observability, and release-evidence findings without
double-counting them. The app, executable, support-script, and Rakefile rows
also have item-level coordinator synthesis in
`analyses/entry-support-synthesis.md`; the remaining synthesis queue is the
21 gem rows not yet reconciled in a dedicated coordinator wave.

The audit is complete only when [BAR.md](BAR.md) is satisfied. Documentation
may make the audit bar and evidence clearer; with no implementation in scope,
it must not be described as an increase in production code quality.

## Evidence and report rules

Reports use stable functionality IDs from `COVERAGE.md`. Every finding names
the concrete issue, impact, owner seam, severity, confidence, scanner signal
and analyst judgment, with `file:line` source citations and test/contract
citations where they exist. Missing tests, missing observability, and unknown
runtime behavior are recorded as evidence gaps rather than filled with
assumptions. Static tools identify places to inspect; they do not prove a
behavioral defect by themselves.

The standing repository protocol in [`docs/subagent-orchestration.md`](../../subagent-orchestration.md)
governs ownership, bounded briefs, logging, and housekeeping. Analysts do not
edit production code, tests, configuration, generated artifacts, or unrelated
docs; they do not commit. Created audit files are mode `0644`, and no scratch
file belongs in the repository. The required liveness log is
`/tmp/tamoz-agents/audit_setup.log` for this setup unit; future agents use the
name assigned in their brief.

## Existing audit overlap

Earlier material remains historical evidence and is re-verified before reuse:

- [`docs/audits/top100-audit-2026-09-11`](../top100-audit-2026-09-11/) audited
  the 100 largest Ruby files and reported file-level findings. Its source files
  may overlap this package, but it does not establish functionality coverage.
- [`docs/gem-boundary-audit-2026-08-25`](../../gem-boundary-audit-2026-08-25/)
  assessed a 24-gem topology and extraction candidates. It overlaps dependency
  and package-boundary questions; the current checkout has 27 gems, so its
  counts and claims are not current closure evidence.
- [`docs/repo-quality-audit-2026-08-20`](../../repo-quality-audit-2026-08-20/)
  covered seven repository-quality lenses over an older 13-gem tree. It is a
  useful lead source, not a substitute for this source-grounded functional
  pass.

No earlier package closes a row in this index without current source review.

# Tamoz functionality audit — 2026-09-15

This package is the index and quality bar for a read-only, functionality-by-
functionality audit of the current Tamoz checkout. It follows the real source
paths end to end, records gaps and weaknesses with evidence, and uses a fresh
independent subagent for each functionality that produces a full analysis and
write-up. It does not implement fixes.

The baseline is branch `audit-15-09`, commit `582ae55`, with a clean worktree
when setup began on 2026-09-15. The live tree has 27 gem library directories.
The root README is the responsibility map (`README.md:16-46`); [COVERAGE.md](COVERAGE.md)
maps every gem exactly once and keeps apps, entry points, support scripts, and
cross-gem flows in separate inventories.

## How the audit runs

The coordinator owns the queue, the evidence bar, synthesis, and the final
coverage decision. For each queued functionality it sends a short, bounded
brief to a new read-only subagent running `gpt-5.6-luna` at the maximum
supported thinking level. The brief names the functionality, source and test
surfaces, its queue group, forbidden paths, and the required report shape.
The analyst reads the actual implementation and relevant behavior contracts,
tests, callers, and documentation; it records verified findings and writes its
owned report under this folder. A scanner may supply inventory, search, Enola,
or quality-signal leads, but a scanner lead is never a finding or a completed
review until an independent analyst confirms it.

The coordinator then checks citations, challenges the reasoning, reconciles
overlap with earlier audits, and records a disposition. Critical and major
findings require a five-whys root-cause chain and a recommendation at the
existing owning seam. The loop proceeds through all queue groups, then checks
the cross-gem flows and support surfaces. A functionality is complete only
when its scanner and independent analyst states, source/test evidence, finding
dispositions, and blind spots are recorded in [COVERAGE.md](COVERAGE.md).

## Current synthesis checkpoint

The shared audit package now contains 29 JSON analyst records expanding to 40
row surfaces: all 27 gem responsibilities, the reference app and executable
surfaces, and the aggregate script/Rakefile rows. The current analyst snapshot
has 33 `IMPROVE` and 7 `PASS` verdicts. Eight rows still lack a completed
scalability lens (`A01`, `E01`, `E05`, `E06`, `E07`, `E09`, `F12`, and `F17`),
so no row is closed under the six-lens bar.

The latest bounded wave added standalone F13 (approval), F18 (capabilities),
and F21 (profile) reports. F13 and F18 have new independent challenge records;
F21's major finding is covered by `challenge-profile-authority.md`. Their
coordinator dispositions are recorded in [FINDINGS.md](FINDINGS.md), with
remaining work tracked in [CHECKPOINT.md](CHECKPOINT.md). The package remains
read-only: reports identify production gaps but do not implement fixes.

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

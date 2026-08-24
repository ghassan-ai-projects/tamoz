# Code audits

Point-in-time audits of specific files or surfaces, one numbered report per
audit target. An audit records what was found at a date; it is not live
documentation — re-verify against current code before acting on a finding.

| # | Date | Target | Report |
|---|------|--------|--------|
| 001 | 2026-08-24 | `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` (884 lines) | [001-agent-cli-rb-audit.md](001-agent-cli-rb-audit.md) |

## Method

Each audit runs as five independent reviewer lenses (responsibility boundaries,
concurrency/control flow, security & safety, coupling/testability, duplication/API
consistency), findings synthesized into one report with per-lens attribution.
Research-only: reviewers change no code and run no tests.

## Finding IDs

`<LENS>-<n>` where LENS ∈ {ARCH, CONC, SEC, COUP, DUP}. Severities:
critical (active bug/security), major (design defect with real cost),
minor (quality debt), info (note).

# P15 release plan review

Verdict: accept-with-required-corrections (revision 2 integrated corrections 1–9).
Reviewer: fresh-context plan critic (general-purpose subagent, 2026-08-02).
Scope reviewed: `docs/P15_RELEASE_PLAN.md` revision 1 against the P15 card, the
handover §4 protocol/§7 non-negotiables, INVARIANTS.md timing rules,
`docs/public-api.json`, SECURITY.md, GAUNTLET_PROGRESS.md §5, and the eval artifacts.

## Findings and dispositions

| # | Sev | Section | Finding | Disposition (rev 2) |
|---|---|---|---|---|
| 1 | High | §3/§13 | P15-A regenerable audit has no input manifest — no machine-readable requirements exist | `docs/requirements-manifest.json` is P15-A's first deliverable (stable IDs, source, release-blocking, named test); regeneration semantics defined |
| 2 | High | §13/§12 | DoD "zero missing/indirect rows" contradicts the invariants' own v0.2/v0.3 timing and the §2.5 escape hatch | Status vocabulary: pass/missing/indirect/deferred-by-contract/owner-signed-residual; DoD = zero `missing` among APPLICABLE rows; residual/deferred enumerated + signed |
| 3 | High | §1/§3 | Ship-feature-vs-clause-timing conflict unresolved (skills/memory/healing ship before release; invariants assign clauses to v0.2/v0.3) | Promotion matrix names each shipped package + binding status (tested-to-v0.1 or excluded, owner-signed) |
| 4 | High | §10 | Rehearsal not independently reproducible without a pinned toolchain; `rake ci` excludes packaging + scorecard; workspace Gemfile masks gemspec dep errors | Pinned provisioning (ruby version + bundler from lockfile); full gate = rake ci + scorecard + isolated packaged-gem install + both locales; per-gem enumerated example tasks |
| 5 | Medium | §2 | Two debts missing from the closure list (`.tamoz-*` seam; P8 §5.3/5.4 machinery); "P6–P9" imprecise | `.tamoz-*` → P15-C reaper sweep; P8 machinery → DR-5 lands before gating; critic list corrected to "P6, P7, P8, D-7, P9" |
| 6 | Medium–High | §8 | P15-F signed decision under-defined; `docs/evaluation-artifacts-v1.md` collision; no key infra; verifier must re-run the harness | Distinct pin manifest (`release-evaluation-manifest.json`); reuse existing digest machinery; tamper-tested verifier; both-locale artifact determinism; protected corpora = v0.1 non-goal with public corpus denominator |
| 7 | Medium | §11 | Owner gate "stays open" acceptable only with proof of presentation | Written owner decision record naming the candidate commit/digest + delivery/acknowledgment evidence; gate-open explicitly = not shipped, no claims, no tag/branch push |
| 8 | Medium | §7 | P15-E DoD satisfiable by writing a report | Hard pass condition: recorded/offline-model numbers within a stated bound of baseline or an owner-signed honest regression; live sampling declared with date |
| 9 | Medium | §4 | P15-B needs a named D-6 regression proof + a real old-format fixture | Constructed old-format fixture (no released users); D-6 regression proof via DR-4; fixture-based resume/stop test |

## Held-out probes

Runtime-only asset missing from a gemspec `files` list (per-gem example tasks); workspace-Gemfile masking gemspec dep errors (isolated GEM_HOME install); artifact digests regenerating differently on a clean machine (both-locale determinism + exempt set); old-session resume tested only against the current format (constructed fixture); live-model numbers not reproducible (recorded/offline model).

## Status

Corrections integrated in `docs/P15_RELEASE_PLAN.md` revision 2. Dependencies: DR-4
(D-6 fix) and DR-5 (P8 machinery) land before release gating.

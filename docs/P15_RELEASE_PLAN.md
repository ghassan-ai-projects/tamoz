# P15 — release hardening and completion audit: implementation plan

Status: accepted for implementation (revision 2 — plan-critic corrections 1–9
integrated; see `docs/reviews/P15_RELEASE_PLAN_REVIEW.md`)
Authoritative inputs: every promoted design in `docs/design-v0.1/`, all 55 invariants as
applicable, `docs/public-api.json`, SECURITY.md, packaging/migrations, evaluation
artifacts, the P15 card in `docs/PROJECT_HANDOVER_PLAN.md`, and the open debts recorded
in `docs/GAUNTLET_PROGRESS.md` §5.

Outcome, verbatim: "an independently reproducible release candidate, not merely a green
local tree."

Owner constraint in force (binding): **no push, no publish, no release, no real physical
actuators without explicit owner approval.** P15-I's owner gate is exactly that approval;
everything before it runs locally and in clean-clone rehearsal only.

Phase activation rule: committed as a design artifact while P10 is active; the handover
ledger's P15 row stays `pending` until P14 closes. No P15 code before that (except this
plan and its review).

## 1. Scope commitment

P15 is an audit-and-harden phase, not a feature phase. Every work package maps to a
verifiable evidence requirement. Completion is prohibited while any explicit requirement
lacks direct evidence, any promoted conditional invariant is untested, the worktree is
dirty, or release reproduction depends on the original development checkout (card §7 —
binding).

| Work package | Evidence produced | Judge |
|---|---|---|
| P15-A requirements audit | `docs/requirements-manifest.json` (correction 1) + the requirement→evidence map with the status vocabulary (correction 2) + the promotion matrix (correction 3) | coordinator + independent auditor |
| P15-B compatibility | Ruby matrix, pinned ranges, migrations, old-session resume with a constructed old-format fixture + the D-6 regression proof (correction 9) | CI matrix + replay tests |
| P15-C operations | backup/restore/corruption/disk-full, retention/deletion, observability/redaction, leak/soak, crash-recovery runbooks; closes the `.tamoz-*` seam and the P8-F round (correction 5) | operational suite + executed runbooks |
| P15-D security | dependency/license/provenance review, credentials/secrets sweep, injection surfaces, boundary re-audit; zero unresolved high/critical | security review + adversarial suites |
| P15-E performance/value | committed benchmark report with a hard pass condition (correction 8): recorded/offline-model numbers, honest denominators, p50/p95/p99 within a stated bound of baseline or an owner-signed honest regression | benchmark harness + committed report |
| P15-F evaluation | canonical pinned artifacts via a distinct manifest (correction 6), paired baseline, signed decision + tamper-tested verifier, corpus versioning fixed | scorecard + reproducibility run |
| P15-G product/docs | install guides, architecture, tutorials, examples, API/event reference, security/limitations, migration/backup, changelog, licenses, gem contents; checked against the real surface | doc completeness audit |
| P15-H release rehearsal | pinned-toolchain clean-clone rehearsal (correction 4): provisioning, full gate, isolated packaged-gem install, per-gem example tasks, both locales | the rehearsal itself, scripted |
| P15-I owner gate | written owner decision record naming the exact candidate commit/digest + evidence of delivery and acknowledgment (correction 7) | owner |

## 2. Known debts this phase must close

1. Gate assertion variance → fixed in P15-F evidence pinning (aggregate asserts, never
   inside timing-dependent callbacks).
2. Evaluation corpus versioning → P15-F (real `case_version` bumps; pinned artifacts).
3. P6-F operational durability gaps → P15-C work items (disk-full, lock saturation,
   unresolved-effect deletion guard through a session, thread-leak measurement, soak).
4. **D-6 stale-resume defect + `:retry` latent defect** → DR-4 design round + the
   P15-B regression proof (correction 9): a named test reproducing the fault chain
   (fenced-out resume → terminal request value, no exception escaping `run_next`,
   thread survives).
5. **`.tamoz-*` orphan temp-file seam** (ledger §5.7) → P15-C reaper sweep or
   staging-in-one-private-dir fix (correction 5; moved with the atomic-IO code in P16 —
   closed here, never silently dropped).
6. **P8 §5.3/§5.4/§5.5 machinery** → DR-5 design round lands before P15 release gating
   (per the ledger's schedule); its result is a P15-A row, closed or owner-signed
   residual.
7. Deferred critic passes (P6, P7, P8, D-7, P9 — the ledger's exact list, correction 5):
   every "complete" mark from P6 on carries an independent critic finding before P15-A
   certifies it; a critic that cannot run is recorded as an owner-signed residual row
   with the mitigating evidence — never silently dropped.

## 3. P15-A — requirements audit method (corrections 1–3)

Build `docs/requirements-manifest.json` FIRST: stable requirement IDs (objectives from
`PRODUCT_EXECUTION_ROADMAP.md`, all 55 invariants, accepted ADRs in `design-v0.1/`
— NOT every review finding; review corrections are mitigation notes on the rows they
affect, per the over-scope finding), phase exit criteria, public-API entries, CLI
commands, migrations, non-goals — each with `{id, source, release_blocking,
named_test, status}`. Then the audit table maps every manifest row to DIRECT evidence
(test file/case, scorecard case, probe artifact, code path), regenerated by a script
that runs the named test and maps exit → status.

**Status vocabulary (correction 2):** `pass` / `missing` / `indirect` /
`deferred-by-contract` / `owner-signed-residual`.
- `deferred-by-contract`: clauses the invariants themselves assign to v0.2 (29–31,
  41–43) or v0.3 (28, 32–34) — enumerated, not free-form.
- `owner-signed-residual`: a known gap carried with owner sign-off (incl. the
  critic-can't-run case).
- DoD: **zero `missing` among applicable rows** (not "zero non-pass"); the residual and
  deferred rows are enumerated and signed.

**Promotion matrix (correction 3):** at the release head, P9 skills, P11 memory, P12
healing, P13 scheduler, P14 stream will have shipped as available features while the
invariants assign their clauses to v0.2/v0.3. The matrix names each shipped package and
its binding status: clauses TESTED to v0.1 conformance (they are implemented and pass)
or the feature EXCLUDED from the v0.1 release surface (owner-signed). "An unavailable
feature never pretends to pass its clauses" is honored by the matrix; available features
never claim v0.2/v0.3 conformance labels they haven't earned.

## 4. P15-B — compatibility (correction 9)

- Ruby matrix: CI runs 3.3/3.4/4.0; the clean-clone rehearsal runs 3.3 (the `.ruby-version`
  pin) at minimum and records the rest as CI-run.
- Dependency ranges: RubyLLM, MCP, fugit, json_schemer, sqlite3 — each pinned range has
  a lower/upper probe test.
- **Old-session resume:** with no released v0.0 users, "old" is defined by a
  CONSTRUCTED old-format fixture (checked-in, produced by the previous release-candidate
  format) — resume either resumes exactly or stops typed (invariant 22), asserted by a
  fixture-based test. The D-6 fix (DR-4) carries its regression proof here: the named
  fault-chain test (correction 9).
- DR-5's profile machinery lands before release gating and is audited here.

## 5. P15-C — operations (correction 5)

Close the P6-F gaps and the `.tamoz-*` seam: backup/restore round trips, corruption
detection, disk-full injection (bounded target), retention/deletion with receipts,
observability/redaction (secrets never in logs/metrics), FD/thread leak measurement over
a soak, crash-recovery runbooks (documented AND executed once in rehearsal), and the
stale-temp-file reaper sweep (or single-private-dir staging). Every item is a test or a
runbook with a recorded execution, not a claim.

## 6. P15-D — security

Dependency/license/provenance review of every runtime gem (committed report); invariant-
24 sweep over durable stores (session records, checkpoints, memory, schedule payloads,
stream admissions); injection surfaces across tool/skill/profile/MCP/memory/scheduler/
stream boundaries (adversarial suites re-run at release head, findings re-audited);
zero unresolved high/critical findings — each known finding has a disposition (fixed +
test, or owner-signed residual).

## 7. P15-E — performance/value (correction 8)

Committed benchmark report with a HARD pass condition: recorded/offline-model numbers
(a real provider's live responses are not seed-controlled — committed numbers use a
recorded fixture or offline model; any live-model sampling is declared with its date as
an honest denominator); p50/p95/p99 within a stated bound of the committed baseline, or
an owner-signed honest regression; memory/FD/thread/cost/token/cache metrics; plain
RubyLLM + job-queue baselines; deterministic harness (warmup, fixed seeds, repeated
runs), reproducible in rehearsal.

## 8. P15-F — evaluation (correction 6)

- **Distinct artifact manifest:** `docs/evaluation-artifacts-v1.md` already exists as the
  v1 FORMAT specification — do not overwrite it. The pin manifest is a separate file
  (`docs/release-evaluation-manifest.json`) referencing the corpus in
  `gems/tamoz-evals/suites/` and pinning case/evidence/result digests. Corpus
  versioning fixed: real `case_version` bumps where definitions changed.
- **Signed decision:** signature over the aggregate digest, produced with the repo's
  existing digest/verify machinery (reuse `Tamoz::Evals` digest domains; no new key
  infrastructure — the "signature" is the digest chain + the signed owner decision
  record from P15-I).
- **Reproducible verifier:** regeneration RE-RUNS the deterministic harness (the decision
  depends on hard-gate execution) and compares artifact digests. The verifier is
  tamper-tested: corrupt one pinned artifact → verifier fails.
- **Protected corpora:** no holdout corpus exists at v0.1 (P11-W/P12 ship theirs later);
  declared a non-goal for v0.1 with the public corpus as the denominator.
- Both-locale regeneration: pinned artifact digests must be byte-identical when
  regenerated under `LC_ALL=en_US.UTF-8` and `LC_ALL=C` (D-1/D-3 proved ambient-encoding
  sensitivity); envelope fields excluded from the decision digest (environment/timing)
  are enumerated.

## 9. P15-G — product/docs

Complete the public surface: install guide (per-gem + workspace), architecture overview,
tutorials/examples, API/event reference (from `public-api.json` + generated docs),
security/limitations, migration/backup, changelog, licenses, gem contents manifest. Each
doc is checked against the real CLI/gem surface by a test or a rehearsal step.

## 10. P15-H — release rehearsal (correction 4)

A scripted, clean-clone rehearsal with a PINNED toolchain: (a) provisioning — the exact
Ruby version from `.ruby-version` and bundler from the lockfile's `BUNDLED WITH`, via a
version manager, with the steps recorded (dev-machine rehearsal can pass while a user
with bundler 2.x or a different 3.3 patch fails — provisioning is part of the script);
(b) **full gate** — defined as `rake ci` (design:validate + syntax + tests) PLUS the
scorecard (`tamoz-eval scorecard agent-smoke`) PLUS the isolated packaged-gem install
(which `rake ci` does NOT include) PLUS both `LC_ALL` variants; (c) **isolated packaged-
gem install** — each gem installed into its own GEM_HOME with only declared deps and
loaded in a clean subprocess (the P10 dependency-isolation pattern), because the
workspace Gemfile resolves all six gems via `path:` and masks gemspec dependency errors;
(d) **enumerated example tasks per gem** — each gem's runtime file surface (data/
schema/template read at runtime) touched by a named example, so a missing gemspec `files`
entry cannot pass unnoticed (probe P1); (e) restore/resume a durable session; (f) verify
signatures/provenance. The rehearsal script and its log are committed evidence.

## 11. P15-I — owner gate (correction 7)

Present: the requirements audit, the rehearsal log, the benchmark report, the security
disposition, the exact remaining risks (severity + mitigation), and the recommended next
action. **The gate record is a written owner decision record naming the exact candidate
commit/digest, with evidence of delivery and acknowledgment** (an explicit owner reply —
not a coordinator-written note). "Gate open" is recorded as: the release candidate is
staged; the release is NOT shipped; no stable/public claims may be made; no tag/branch
push occurs. Push/tag/publish/announce or any real physical adapter happens ONLY on
explicit owner approval. Without approval, the phase ends with the gate open, documented
as such.

## 12. Stop / redesign criteria

- Any applicable requirement row `missing` at the end of the phase (per the §3
  vocabulary).
- Any promoted conditional invariant (MCP 35–37, scheduler 38–40, stream 44–51)
  untested at the release head.
- A dirty worktree, a failing gate, or a rehearsal that depends on the development
  checkout or on non-pinned toolchain state.
- Any unresolved high/critical security finding without an owner-signed disposition.
- Release claims made before the owner gate.

## 13. Definition of done (v1)

- [ ] `docs/requirements-manifest.json` + regenerable audit with zero `missing` among
      applicable rows; promotion matrix signed.
- [ ] P15-B compatibility suite incl. Ruby matrix, pinned ranges, migration, old-format
      fixture resume, D-6 regression proof (DR-4).
- [ ] P15-C operational suite closing the P6-F gaps + the `.tamoz-*` seam + runbooks
      executed.
- [ ] P15-D security review with zero unresolved high/critical findings.
- [ ] P15-E committed benchmark report with the hard pass condition and honest
      denominators.
- [ ] P15-F distinct pin manifest, paired baseline, tamper-tested verifier, both-locale
      artifact determinism; corpus versioning fixed.
- [ ] P15-G complete docs checked against the real surface.
- [ ] P15-H pinned-toolchain clean-clone rehearsal with the full gate (rake ci +
      scorecard + isolated packaged-gem install + both locales) and per-gem example
      tasks; log committed.
- [ ] P15-I written owner decision record naming the candidate commit/digest with
      delivery + acknowledgment evidence; gate outcome recorded; no push/publish/
      actuator without explicit approval.
- [ ] Trackers updated: handover ledger P15 row, roadmap, `docs/GAUNTLET_PROGRESS.md`.

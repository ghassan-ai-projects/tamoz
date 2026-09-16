# Independent challenge: F26 evidence and verifier findings

Date: 2026-09-15
Checkout: `audit-15-09`, HEAD `0d19c8e0994ac4d62de6e0ee77131242a6142dfd`
Scope: challenge `F26-EVD-01` and `F26-ERR-01` from `F26-evals.md`/`F26-evals.json`.
Boundary: read-only inspection; probes used temporary files under `/tmp`. No implementation, test, configuration, or coordinator-document changes were made.

## Verdict summary

| Finding | Independent verdict | Severity / confidence | Status | Owning seam |
|---|---|---|---|---|
| F26-EVD-01 | Uphold, with a narrower title and ownership correction | Major / high for artifact drift; medium for the six limitations rows | Open | S01 generator output, R01 release freshness gate; F26 is affected |
| F26-ERR-01 | Uphold | Major / high | Open | `tamoz-evals::Verifier#read_stable_file`; E02 CLI is the consumer |

Both findings survive challenge. The evidence finding is a committed-artifact/gate problem, not a defect in `Tamoz::Evals::Verifier`; the six `limitations.md` comparisons need environment-aware reconciliation before being called false. The zero-byte finding is deterministic. Neither is critical: neither permits an authority bypass or unsafe production action, but each materially weakens release evidence or fail-closed operation.

All six BAR lenses were checked for both findings.

## F26-EVD-01 — stale committed release evidence

### Evidence and scope correction

The current `docs/requirements-manifest.json` has 529 requirements and 283 unique named/supporting references. The committed `docs/requirements-audit.json` records 529 requirements but 284 named cases and one reference that the manifest no longer contains: `test/approval_policy_document_test.rb#test_digest_changes_on_content_edit`. Its `ADR-053` row is `pass` (`docs/requirements-audit.json:847-862`), while the current manifest row is `unverified` with no supporting test (`docs/requirements-manifest.json:783-794`). A filtered run of the cited case produces **0 runs, 0 assertions, 0 failures, 0 errors, 0 skips** and exits zero because the test was renamed in the prior top100 resolution (`docs/audits/top100-audit-2026-09-11/049-approval_policy_document_test.md`).

History proves drift rather than a transient read: the audit artifact was last written at commit `adb2346` on 2026-09-12, while the manifest correction was commit `81e4a90` on 2026-09-13; `81e4a90` is not an ancestor of the audit artifact. The current generator explicitly maps a zero-run filter to `not-run` (`script/generate_requirements_audit:75-100`) and `evidence_status` maps that to `failing` (`:146-155`), so the current generator cannot have produced this `pass` from the current manifest.

The analyst report grouped six rows with `pass` status against limitations text describing failure or environmental uncertainty: `INV-18`, `INV-19`, `INV-20`, `MIG-15`, `OBJ-4`, and `PHASE-DR-3` (`docs/requirements-audit.json:7095-7147,7849-7862,8261-8276,8355-8366`; `documentation/limitations.md:19-29,31-40,49-54,64-75,138-142`). I do not promote that comparison to six proven false results. Focused controls for `INV-18`, `INV-19`, `INV-20`, `OBJ-4`, and `PHASE-DR-3` passed in this checkout; the MIG-15 witness controls failed before assertions because the sandbox denied `bind(2)` (`EPERM`). This proves the artifacts are inconsistent, but not which side is stale for each environment-bound claim. The finding should therefore be titled around stale manifest/evidence references and status freshness, with limitations reconciliation as a required follow-up.

The committed-audit guard only compares requirement ID sets and rejects `unverified` (`test/requirements_manifest_test.rb:180-192`). It passed **1 run, 530 assertions, 0 failures, 0 errors, 0 skips** while the phantom reference remained. The ordinary CI test file expressly does not run the 200-plus-case audit (`test/requirements_manifest_test.rb:5-16`); `script/release_rehearsal:263-282` runs a fresh clone audit and records it, but does not revalidate the committed artifact. `README.md:139-146` and `documentation/guides/evaluation.md:59-68` still describe the committed audit as machine-readable release status. This is a material evidence and maintenance boundary gap.

### Six-lens assessment

Correctness and evidence are affected by a proven manifest/audit mismatch. Security has no direct authority bypass, but stale “pass” evidence can mislead release decisions. Reliability is weakened because the run record is not refreshed. Observability is contradictory across audit and limitations. No scalability bound is implicated. Maintenance risk is high because S01 produces the artifact while R01 controls trust, with no shared freshness invariant.

### Five Whys and recommendation

1. `ADR-053` is pass with a nonexistent test because the audit predates the manifest correction.
2. It remained stale because no gate regenerated or compared its evidence references.
3. The existing guard checks IDs and `unverified`, not references, counts, or current outcomes.
4. The artifact is timestamped run output without a digest or manifest-parity contract.
5. Ownership is split between generator output and release composition, so a source correction does not invalidate the committed release claim.

At the existing seam, add a non-executing parity assertion beside `test_the_committed_audit_covers_every_manifest_row` that requires each audit evidence reference to appear under the same manifest ID and requires `manifest_requirements` and `named_cases_run` to equal manifest-derived values. Then regenerate the two audit artifacts and reconcile `limitations.md` in an authorized environment. S01 should own artifact shape; R01 should own freshness invocation. This overlaps `S01-RT-01` and `F22-DOC-02` as evidence inputs, but is not a duplicate: the present defect is stale committed audit provenance.

## F26-ERR-01 — zero-byte verifier crash

`Verifier#read_stable_file` opens the path and checks its pre-read size (`gems/tamoz-evals/lib/tamoz/evals/verifier.rb:553-562`), then assigns `file.read(max_bytes + 1)` at `:563` and immediately calls `bytes.bytesize` at `:564`. On Ruby 3.3.11, a zero-byte regular file returns `nil` from that read, so the public API raises `NoMethodError` instead of a typed evals error. `Verifier#verify` rescues only `Errno` and JSON parser errors (`verifier.rb:61-64`); `CLI#verify_path` rescues only `InvalidArtifactError` and `SystemCallError` (`cli.rb:68-74`). The executable simply calls `exit Tamoz::Evals::CLI.run(ARGV)` (`gems/tamoz-evals/exe/tamoz-eval:6`).

The actual CLI probe returned an uncaught `NoMethodError`, empty stdout/stderr, and no typed exit code for an empty artifact. A one-byte whitespace file returned the expected invalid-evidence exit 2. Missing, truncated, unknown-type, duplicate-key, bad-digest, and directory controls all failed closed with typed errors. Full `ruby -Itest test/evals_verifier_test.rb` passed **23 runs, 294 assertions, 0 failures, 0 errors, 0 skips**, but contains no zero-byte regression.

The path is reachable through `Tamoz::Evals.verify` (`gems/tamoz-evals/lib/tamoz/evals.rb:20-28`), the public `Case`, `Evidence`, and `Result` loaders, `tamoz-eval verify`, and the M1/M2 conformance scripts after their single-call result writes (`script/run_m1_conformance:387-390`; `script/run_m2_conformance:394-397`). An interrupted write can leave an empty or truncated artifact; no production incident was established.

Correctness, reliability, and observability are directly affected: malformed evidence should produce a typed refusal, but this case produces an uncaught runtime error. There is no authority bypass, no unbounded resource issue, and no cross-gem architectural duplication. Five whys: the read returns nil at EOF; the result is dereferenced; no nil/empty guard exists; the narrow error taxonomy cannot catch `NoMethodError`; and no malformed-input contract test covers the exact zero-byte boundary.

The smallest seam fix is an explicit empty-read guard in `read_stable_file` that raises `InvalidArtifactError` (or normalizes nil before the existing JSON parser), with a regression asserting API and CLI typed failure/exit 2. Ownership remains F26; E02 owns only executable presentation. No implementation was performed here.

## Tests, deviations, and blind spots

Focused commands and results: `test/requirements_manifest_test.rb` targeted guard **1/530/0F**; `test/evals_verifier_test.rb` **23/294/0F**; ADR-053 named case **1/5/0F**; stale supporting case **0/0/0F**; benchmark protocol controls **2/3/0F**; INV-18 version refusal **1/3/0F**; INV-19 raw SQLite kill control **1/312/0F**; INV-20 takeover **1/4/0F**; OBJ-4 kill matrix **1/13/0F**; PHASE-DR-3 memory control **1/43/0F**; documentation controls **2/31/0F**. MIG-15 controls were attempted as **2 runs, 0 assertions, 2 errors** (`EPERM bind(2)`), an environment deviation rather than a product verdict.

I did not regenerate the audit, run all 284 cases, run packaging, or test a real interrupted write. These limit status resolution but do not close either finding. Before and after writing, `git status --short --untracked-files=all` showed no pre-existing changes and only this report as the new path; no production, test, config, coordinator, or scratch repository path was touched. Findings remain open pending S01/R01 freshness repair and F26 regression coverage.

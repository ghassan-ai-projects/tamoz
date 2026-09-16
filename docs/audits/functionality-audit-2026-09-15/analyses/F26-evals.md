# F26 `tamoz-evals` — the verification engine is sound where it is exercised, but its release-evidence artifact is stale and one fail-closed path is missing

Row / queue / baseline: **F26** / W5 (evals / evals-runner) / commit `582ae55`, branch `audit-15-09`, 2026-09-15 / analyst `analyst_f26` / budget ~50 min (hard cap 60)

## Scope and source map

Read end to end (all files in the row's source surface):

| File | Lines | Role |
|---|---:|---|
| `gems/tamoz-evals/lib/tamoz/evals.rb` | 30 | entry point, `Tamoz::Evals.verify`, `DATA_ROOT` |
| `gems/tamoz-evals/lib/tamoz/evals/artifact.rb` | 24 | frozen artifact value object |
| `gems/tamoz-evals/lib/tamoz/evals/canonical_json.rb` | 97 | **canonical form + content digest** |
| `gems/tamoz-evals/lib/tamoz/evals/case.rb` | 20 | case loader |
| `gems/tamoz-evals/lib/tamoz/evals/cli.rb` | 93 | `verify` command, exit codes |
| `gems/tamoz-evals/lib/tamoz/evals/deep_freeze.rb` | 20 | recursive freeze |
| `gems/tamoz-evals/lib/tamoz/evals/duplicate_key_detector.rb` | 142 | hand-rolled JSON scanner |
| `gems/tamoz-evals/lib/tamoz/evals/errors.rb` | 38 | typed error tree |
| `gems/tamoz-evals/lib/tamoz/evals/evidence.rb` | 21 | evidence loader |
| `gems/tamoz-evals/lib/tamoz/evals/result.rb` | 20 | result loader |
| `gems/tamoz-evals/lib/tamoz/evals/schema.rb` | 192 | closed-vocabulary JSON-Schema subset |
| `gems/tamoz-evals/lib/tamoz/evals/shape_validation.rb` | 48 | harness shape guards |
| `gems/tamoz-evals/lib/tamoz/evals/verifier.rb` | 580 | **the verifier — the crux of this row** |
| `gems/tamoz-evals/lib/tamoz/evals/version.rb` | 7 | `0.1.0.alpha.1` |
| `gems/tamoz-evals/tamoz-evals.gemspec` | 16 | dependency contract |
| `gems/tamoz-evals/exe/tamoz-eval` | 6 | executable (E02 owned by another row) |

Adjacent artifacts read to check cross-artifact consistency: `gems/tamoz-evals/schemas/{case,evidence,result}.schema.json` (1761 lines), `docs/requirements-manifest.json`, `docs/requirements-audit.json`, `docs/REQUIREMENTS_AUDIT.md`, `documentation/benchmark/BENCHMARK_PROTOCOL.json`, `script/generate_requirements_audit` (291), `script/generate_benchmark_protocol` (132), `documentation/limitations.md`, `README.md:140-147`.

Entry seam: `Tamoz::Evals.verify(path)` → `Verifier#verify` (`gems/tamoz-evals/lib/tamoz/evals.rb:26`).

## Behavior path

`Tamoz::Evals.verify` (`evals.rb:26-28`) constructs a fresh `Verifier` and calls `verify(path)` (`verifier.rb:39-65`):

1. `expand_artifact_path` (`verifier.rb:69-78`) — `File.path`, NUL rejection, `File.expand_path`.
2. `read_document` (`verifier.rb:80-91`) — `read_stable_file` bounded to `MAX_ARTIFACT_BYTES` (2 MiB), UTF-8 validity, `DuplicateKeyDetector.validate!`, `JSON.parse(max_nesting: 100)`.
3. `DIGEST_DOMAINS.fetch(artifact_type)` (`verifier.rb:43-45`) — type must be `case`/`evidence`/`result`, else `UnsupportedFormatError`.
4. `Schema.load(artifact_type).validate!(document)` (`verifier.rb:47`).
5. `verify_digest!` (`verifier.rb:93-104`) — **recomputes** `CanonicalJSON.content_digest` and compares to `content_digest`.
6. `validate_unique_ids!` + `verify_references!` (`verifier.rb:49-50`, `106-161`) — re-reads every referenced file, checks `size_bytes` **and** `digest`, refuses traversal/absolute/backslash/NUL paths.
7. `verify_semantics!` (`verifier.rb:163-243`) — per-type semantic invariants.
8. Returns a frozen `Verification` Data with the **normalized** document (`verifier.rb:58`).

## Lens: correctness

**The digest is recomputed on read, not trusted — this is the central claim and it holds.** `content_digest` (`canonical_json.rb:26-34`) rejects a non-Hash root, strips `content_digest` itself, and hashes `[PREFIX, domain, "v#{DIGEST_VERSION}", dump(body)].join("\0")`. The domain is bound, so a `case` document cannot be re-badged as an `evidence` document without a mismatch. `verifier.rb:99-103` recomputes and raises `DigestError` on any difference. **Proven by probe**: mutating a schema-declared field (`status` → `"passed"`) without re-digesting is rejected.

**The schema is genuinely closed.** All 52 object definitions across the three schemas set `additionalProperties: false` (top level and every `$defs` object — verified by enumerating both). **Proven by probe**: adding an undeclared key at the document root, inside `subject`, inside `hard_gates[0]`, and inside `provenance.components[0]` were **each** rejected with `SchemaError: unknown properties`. This closes the obvious "digest covers bytes but schema ignores fields" hole on every site I could construct.

Determinism of the canonical form is real: `normalize` (`canonical_json.rb:40-57`) sorts object keys (`74`), NFC-normalizes strings (`90`), rejects collisions after normalization (`66-68`), forbids floats by design (`79-84`), and caps nesting at 100 in two independent places. Re-verifying the same bytes is byte-stable.

**The correctness defect I did find is the stale evidence artifact, not the verifier** — see finding `F26-EVD-01`.

## Lens: security and authority

The verifier's authority surface is narrow and correctly bounded. Reference resolution (`verifier.rb:145-161`) rejects NUL, backslash, absolute paths, and any `..` filename component, then **re-resolves through `File.realpath`** and requires the result to be strictly inside the artifact's real directory (`155-158`) — so a symlink swap cannot escape. `read_stable_file` (`553-577`) re-`stat`s after reading and refuses a file whose inode/size/mtime/ctime changed mid-verification (`569-573`), which is a real TOCTOU guard. Byte budgets are enforced twice (`559-561`, `564-566`), plus a running `MAX_TOTAL_REFERENCE_BYTES` (64 MiB) across references (`117`, `126`).

`gems/tamoz-evals/tamoz-evals.gemspec:13-15` declares exactly one runtime dependency, `tamoz-core`. **Dependency direction is honest**: `grep -rn "tamoz-evals" gems/*/*.gemspec` returns hits only in `tamoz-evals-runner.gemspec:4,15,22` — no production gemspec depends on either evaluation gem, so the README claim holds. This is additionally enforced by `test/dependency_isolation_test.rb:294-301` (`test_no_production_gemspec_depends_on_evals`), which I read but did not run (serial-listed).

No secret material is read, logged, or re-emitted by this gem; `CLI#verify_path` (`cli.rb:59-66`) emits only type/decision/digest/path.

## Lens: reliability and durability

`read_stable_file` is the durability seam and it is mostly careful — but it has **one unguarded path that breaks the fail-closed contract** (finding `F26-ERR-01`). `File#read(max_bytes + 1)` (`verifier.rb:563`) returns **`nil`, not `""`**, at EOF when the file is zero bytes under `File::NONBLOCK` (confirmed on Ruby 3.3.11: size 0 → `nil`, size 1 → 1 byte). The next line calls `bytes.bytesize` (`564`) on that `nil`.

The blast radius is exactly the case that matters most for an evidence machine: **an absent, truncated, or corrupt artifact must produce a typed refusal, and instead produces an uncaught `NoMethodError` that escapes the entire error tree.** `CLI#verify_path` (`cli.rb:68-74`) rescues only `InvalidArtifactError` and `SystemCallError`, so `NoMethodError` propagates out of `CLI.run` and out of `exe/tamoz-eval:6` (`exit Tamoz::Evals::CLI.run(ARGV)`), which never executes. **Proven by probe**: `Tamoz::Evals.verify("")`-content file → `NoMethodError: undefined method 'bytesize' for nil` at `verifier.rb:564`; the CLI prints nothing to stdout or stderr and returns no exit code.

Note the near-miss that makes this a genuine defect rather than an unreachable branch: **whitespace-only files are handled correctly** (`" "` and `"\n"` both produce a clean `InvalidArtifactError` → exit 2), because they are non-zero length and `JSON.parse` rejects them. Only the exact zero-byte file — the most likely result of a failed or interrupted artifact write — falls through.

## Lens: observability and evidence

This is the row's defining lens and it is where the material finding lives.

The **code path** that decides a requirement row is `pass` is `script/generate_requirements_audit` (not in this gem — the gem supplies the verifier; the audit generator is a support script). Its mapping (`script/generate_requirements_audit:84-100, 146-155`) is genuinely run-based and conservative: `summary.nil?` → `not-run`; `runs.zero?` → `not-run` (with a comment calling a stale name "a manifest defect, never a pass"); failures/errors → `fail`; **any skip → `not-run`**; otherwise `status.success?` → `pass`. I reproduced this mapping against a real no-match run and it returned `not-run`, not `pass`.

I also checked the two ways a `pass` could be counterfeit and **both are clean**:

- **Filter correctness.** `pattern = "/\\A#{Regexp.escape(case_name)}\\z/"` (`:76`) is correct. I initially suspected the `\A`/`\z` anchors were being eaten by Ruby's double-quote escapes; that is wrong — `"\\A"` is a two-byte `\`+`A` string, and minitest's `filter_runnable_methods` (`minitest-6.0.6/lib/minitest.rb:434-445`) strips the slashes and compiles `Regexp.new("\Atest_x\z")`. **Proven**: an anchored filter does *not* match a longer name (`test_gate4` does not match `test_gate4_the_real_one`), and `Regexp.escape` blocks filter injection. I record this because it is a plausible trap that a later analyst should not re-spend time on.
- **Vacuous assertions.** I ran the generator's own filter across **all 251 evidence references backing the 499 `pass` rows** and measured real assertion counts. **Zero** zero-assertion cases. The generator does not gate on assertion count, and a zero-assertion case *would* be reported `pass` (proven with a synthetic case: `1 runs, 0 assertions, 0 failures` → exit 0), but no committed row currently relies on one.

What is **not** clean is the artifact those rows are recorded in. `ADR-053` is `pass` in `docs/requirements-audit.json` while its recorded supporting test **does not exist**, and six rows that `documentation/limitations.md` describes as failing/unproven are recorded `pass`. See `F26-EVD-01`.

## Lens: scalability and resource bounds

Bounds are explicit and layered: `MAX_ARTIFACT_BYTES` 2 MiB (`verifier.rb:9`), `MAX_REFERENCE_BYTES` 16 MiB (`:10`), `MAX_TOTAL_REFERENCE_BYTES` 64 MiB (`:11`), nesting cap 100 (`canonical_json.rb:41`, `duplicate_key_detector.rb:38`, `JSON.parse(max_nesting: 100)` at `verifier.rb:89`), `max_items` 128 on references, `maxItems` 64 on claim evidence ids. The pre-read `before.size > max_bytes` check (`:559`) avoids reading an oversized file at all, and the post-read check (`:564`) guards a file that grew between `stat` and `read`. Total reference bytes accumulate across the list (`:126`) so 128 × 16 MiB cannot be forced. `after < 120` is a documented count.

`DuplicateKeyDetector` is a hand-rolled byte scanner rather than a regex pass; it is O(n) with a bounded nesting stack and rejects unescaped control characters (`:105-106`). No unbounded recursion or allocation path found.

One note: the audit generator's `--jobs` default is **1** (`script/generate_requirements_audit:43`), and it forks one process per named case (`:78-81`), 284 of them. That is a throughput choice at the support-script seam, not a bound violation, and it is out of this gem's scope.

## Lens: maintenance and architecture

The gem's internal design is coherent and the seam is narrow: one public entry (`Tamoz::Evals.verify`), three thin loaders (`Case`/`Evidence`/`Result`) that all delegate to one `Verifier`, a closed error taxonomy under `Tamoz::Error` (`errors.rb:9-36`), and a deliberately restricted schema dialect with `SUPPORTED_KEYWORDS` (`schema.rb:9-13`) that *raises* on any keyword it does not implement (`:89-92`) rather than silently ignoring it. That last property is the right call for an evidence machine and is worth preserving.

**The F26 / F27 boundary is real and enforced, not merely conventional.** `tamoz-evals` (verify) owns artifact schemas, canonical digests, the verifier, and the three artifact types; `tamoz-evals-runner` (run) owns harnesses, benchmarks, scorecards and external inputs. The direction is enforced two ways: (a) the gemspec graph is one-directional — `tamoz-evals-runner.gemspec:22` depends on `tamoz-evals`, and `gems/tamoz-evals/tamoz-evals.gemspec:13-15` depends only on `tamoz-core`, so the verifier cannot reach a runner harness; and (b) the runner places its ~30 files under `gems/tamoz-evals-runner/lib/tamoz/evals/{harness,benchmark,runner}/`, reusing the `Tamoz::Evals` namespace without adding a single file to the evals gem. Where the runner needs verification it calls *into* the gem (the loaders), never the reverse.

Lens verdict: two material problems, both at boundaries rather than in the verifier core — one missing guard in `read_stable_file`, one stale generated artifact.

## Tests and contracts

All commands run as `ruby -Itest test/<file>.rb`, one file per command, with `PATH` prefixed per the environment block.

| Command | Result |
|---|---|
| `ruby -Itest test/evidence_artifact_test.rb` | **11 runs, 75 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/requirements_manifest_test.rb` | **11 runs, 3018 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/benchmark_protocol_test.rb` | **10 runs, 60 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/release_rehearsal_evidence_test.rb` | **9 runs, 44 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/documentation_surface_test.rb` | **9 runs, 87 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/evals_verifier_test.rb` | **23 runs, 294 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/canonical_json_test.rb` | **6 runs, 8 assertions, 0 failures, 0 errors, 0 skips** |
| `ruby -Itest test/sqlite_raw_oracle_test.rb -n "/\Atest_before_commit_kills_are_old_and_after_commit_kills_are_new\z/"` | **1 run, 312 assertions, 0 failures** |
| `ruby -Itest test/agent_session_kill_matrix_test.rb -n "/\Atest_a_kill_during_a_check_pauses_the_session_and_never_repeats_the_command\z/"` | **1 run, 13 assertions, 0 failures** |
| `ruby -Itest test/approval_policy_document_test.rb -n "/\Atest_bundled_base_loads_and_validates\z/"` | **1 run, 5 assertions, 0 failures** |
| `ruby -Itest test/approval_policy_document_test.rb -n "/\Atest_digest_changes_on_content_edit\z/"` | **0 runs, 0 assertions, 0 failures** — the case is absent; exit 0 |

`test/packaging_test.rb` (prior finding 009): **`not run`** — it is on the Rakefile `SERIAL_TESTS` list (`Rakefile:66`) and is a 1052-line serial packaging suite; the row's 50-minute budget and the one-file-per-command rule made it a poor use of the remaining window, and it is E-row/packaging rather than F26 evidence-machine behavior. Recorded as a blind spot, not as a pass.

The two artifacts `test/requirements_manifest_test.rb` protects are in **different states**: the manifest regenerates byte-identically (`test_manifest_regenerates_from_the_authoritative_sources`, passing), and the audit does **not** — it carries a `generated_at` timestamp (`docs/requirements-audit.json`) so byte-identity is not even defined for it, and **no test regenerates or re-verifies the committed audit**. `test_requirements_manifest_test.rb:183` (`test_the_committed_audit_covers_every_manifest_row`) checks only that the audit's **id set** matches the manifest's and that no row says `unverified` — it never checks that the audit's recorded refs still exist or still pass. That is exactly the gap `F26-EVD-01` lives in.

`test/benchmark_protocol_test.rb` is the strong counter-example and shows the pattern the audit lacks: `test_protocol_regenerates_byte_identically` (`:39-48`) and `test_committed_sha256_pin` (`:50-53`) compare the committed `BENCHMARK_PROTOCOL.json` against a fresh generation and a pinned SHA-256 (`:23`). **All 10 pass**, so the protocol is byte-identical, its digest is pinned, and its five wire digests are bound to the domain fixtures (`:120-139`). I re-derived the protocol's structure from `script/generate_benchmark_protocol` and found one producing site per pinned digest (`:50-60`) and one verifying site (`test/benchmark_protocol_test.rb:120-139`), plus the climate diagnosis digest asserted literally at `:134`. The protocol is consistent with its generating code — the manifest/audit pair is not.

## Findings

### F26-EVD-01 — the committed release-evidence audit is stale: a `pass` row cites a test that does not exist, and six rows `limitations.md` calls failing are recorded `pass`

- **Severity**: `major`
- **Confidence**: `high` — the phantom citation, the six status rows, and the commit ordering are all read directly from artifact bytes and git history; the generator's corrected behavior is reproduced end to end.
- **Status**: `open`
- **Owning seam**: `script/generate_requirements_audit` output artifact `docs/requirements-audit.json`, guarded by `test/requirements_manifest_test.rb:183`

**Source evidence**
- `docs/requirements-audit.json` — row `ADR-053`: `"status": "pass"`, `"evidence_result": "pass"`, `"supporting_tests": ["test/approval_policy_document_test.rb#test_digest_changes_on_content_edit"]`.
- `test/approval_policy_document_test.rb` — that case **does not exist**. `grep -n "def test_digest_changes_on_content_edit"` returns nothing; the file's 23 test methods are at lines 35–337 and none has that name. Running it with the generator's filter yields `0 runs, 0 assertions, 0 failures` and exit 0.
- `docs/requirements-manifest.json` — row `ADR-053` now has `"supporting_tests": []`. The manifest and the audit **disagree on the same row's evidence**, and the manifest was corrected *after* the audit was written: `git log -1 --format=%h\ %ad` gives `81e4a90 2026-09-13 22:37:50` ("docs(manifest): drop the stale ADR-053 supporting citation") for the manifest versus `adb2346 2026-09-12 04:51:22` for `docs/requirements-audit.json`. `81e4a90` is **not** an ancestor of the audit's commit.
- Reproduced generator mapping (`script/generate_requirements_audit:84-100`): the corrected code maps a zero-`runs` summary to `not-run`, and `evidence_status` (`:146-155`) maps any `not-run` to `failing` (`:152`), never to `pass`. So the committed `pass` **cannot** have been produced by the current generator from the current manifest — the artifact predates both fixes.
- Six rows carrying `"status": "pass"` whose content `documentation/limitations.md` still describes as failing or unproven: `INV-18` (limitations.md:51 "currently marks the version-refusal evidence as failing"), `INV-19` (:19-29 "environment-bound"), `INV-20` (:67 "still reports a failing takeover test"), `MIG-15` (:73 "currently marks its named tamper/recovery evidence as failing"), `OBJ-4` (:31-40 "environment-bound"), `PHASE-DR-3` (:142 "marks its named phase evidence as failing"). None appears in `release_blocking_gaps`.
- `test/requirements_manifest_test.rb:183-192` — the only guard on the committed audit checks the **id set** and that no row is `unverified`; it never re-checks that a cited case exists or passes.
- Contrast — the guard that does exist for the sibling artifact: `test/benchmark_protocol_test.rb:39-53` regenerates the protocol and asserts a pinned SHA-256. The audit has no equivalent.

**Independent judgment**: I confirmed the phantom citation and the six-row status disagreement directly from artifact bytes, and confirmed that the *current* generator would not produce the committed `pass`. I rejected the hypothesis that the generator's filter is unanchored (see the correctness lens — `Regexp.escape` plus `\A`/`\z` are correct and minitest compiles them faithfully), so this is artifact staleness, not a live mapping bug. I could not establish which of the two rows is *now* correct for the six environment-bound rows: `INV-19`'s supporting kill-window case and `OBJ-4`'s kill-matrix case **both pass in this environment** (312 and 13 assertions, 0 failures), which means either the environment-bound limitation has genuinely closed and `limitations.md` is the stale side, or the constraint that blocked them is not reproduced here. Either way the three artifacts (`manifest`, `audit`, `limitations.md`) cannot all be right, and the audit is the one the README sells as the machine-readable truth.

**Root cause (five whys)**
1. Why is `ADR-053` `pass` while naming a test that does not exist? Because `docs/requirements-audit.json` was generated on 2026-09-12 from a manifest that still contained the stale citation.
2. Why does the artifact still contain it? Because the manifest was corrected on 2026-09-13 (`81e4a90`) and the audit was never regenerated afterwards.
3. Why was the audit not regenerated? Because nothing in the ordinary gate runs it — `test/requirements_manifest_test.rb:15-16` states outright "The audit itself is NOT run here: it executes 200+ test cases in their own processes and belongs to the release gate, not to `rake ci`", and the only other caller, `script/release_rehearsal:266-272`, runs it in a **clean clone** and only records its summary — it deliberately does not gate on it (`:270-272` comment: the audit's exit status "is about FAILING evidence. Remaining gaps are the owner's P15-I decision and must not be waved through here").
4. Why does a stale citation survive an untouched gate? Because the one test that reads the committed audit validates the **row id set** and the `unverified` sentinel only (`test/requirements_manifest_test.rb:186-191`), so a citation that no longer resolves, or a status that no longer reproduces, is invisible to the gate.
5. Why is the check that narrow? Because the manifest/audit pair was designed with the manifest as the byte-pinned, regenerable artifact (`test_manifest_regenerates_from_the_authoritative_sources`, passing) and the audit as a timestamped run record (`generated_at`) that is only ever *produced*, never *verified* — whereas the benchmark protocol got the full treatment (regenerate + SHA-256 pin + structural invariants, `test/benchmark_protocol_test.rb:39-113`). The audit is the artifact that carries the release claim and is the only one with no re-verification contract.

**Recommendation** (smallest credible action at the existing seam): add one test beside `test_the_committed_audit_covers_every_manifest_row` in `test/requirements_manifest_test.rb` that asserts the committed audit's evidence is still resolvable — for every row, each `named_test`/`supporting_tests` reference must appear in the committed **manifest** row with the same id, and the audit's `manifest_requirements`/`named_cases_run` must equal the manifest-derived counts (currently 529 and 283). That is a byte-comparison test with no test execution, so it stays inside the fast gate that the file's own comment protects. Separately, regenerate `docs/requirements-audit.json` and `docs/REQUIREMENTS_AUDIT.md` and reconcile `documentation/limitations.md` paragraphs 19–29, 31–40, 51, 67, 73 and 142 with whatever the regenerated audit measures. Do not build a new verifier for this: `test/benchmark_protocol_test.rb` already demonstrates the pattern this repository uses.

### F26-ERR-01 — a zero-byte artifact raises an uncaught `NoMethodError`, breaking fail-closed verification at the CLI boundary

- **Severity**: `major`
- **Confidence**: `high` — reproduced directly, root cause pinned to a single line, CLI consequence observed.
- **Status**: `open`
- **Owning seam**: `Verifier#read_stable_file` (`gems/tamoz-evals/lib/tamoz/evals/verifier.rb:563-564`), surfaced at `CLI#verify_path` (`cli.rb:68-74`)

**Source evidence**
- `verifier.rb:563` — `bytes = file.read(max_bytes + 1)`; `verifier.rb:564` — `if bytes.bytesize > max_bytes`.
- `File#read` returns **`nil`**, not `""`, at EOF for a zero-length file opened `File::RDONLY | File::NONBLOCK`. Confirmed on Ruby 3.3.11: size 0 → `nil`, size 1 → 1 byte, size 2 → 2 bytes.
- `cli.rb:68-74` rescues only `InvalidArtifactError` and `SystemCallError`. `NoMethodError` is neither, so it escapes `CLI.run` and then `exe/tamoz-eval:6` (`exit Tamoz::Evals::CLI.run(ARGV)`) — the `exit` never runs.
- **Probe**: `Tamoz::Evals.verify(<0-byte file>)` → `NoMethodError: undefined method 'bytesize' for nil`, backtrace `verifier.rb:564 ← :556 ← :81`.
- **Probe (CLI)**: `Tamoz::Evals::CLI.run(["verify", <0-byte file>])` → uncaught `NoMethodError`, **no stdout, no stderr, no exit code**. For contrast, a whitespace-only file (`" "` or `"\n"`) → `exit 2` with `invalid evidence: invalid JSON: unexpected end of input`, the correct fail-closed behavior.
- Note this is the *only* malformed-input path that misbehaves. I probed eight others — absent file (`ReferenceError`), truncated JSON (`InvalidArtifactError`), unknown `artifact_type` (`UnsupportedFormatError`), absent `content_digest` (`SchemaError`), null `content_digest` (`SchemaError`), non-JSON text (`InvalidArtifactError`), duplicate key (`InvalidArtifactError`), directory-as-path (`ReferenceError`) — and **all eight fail closed correctly**.

**Independent judgment**: confirmed by direct probe with the root cause pinned to one line. The consequence is bounded but lands exactly on the row's central contract: a zero-byte artifact is the most likely residue of an interrupted or failed write, and it is precisely the input that must produce a typed refusal. I verified the effect is not merely cosmetic — `StringIO`-captured CLI output is empty on both streams, so an operator or a CI step sees a Ruby backtrace and a non-typed nonzero exit rather than the `INVALID_EVIDENCE` (2) contract that `DECISION_CODES` and `EXIT_PRECEDENCE` (`cli.rb:15-29`) exist to provide. I did not establish whether any release path currently feeds a zero-byte artifact to `verify`; the defect is in the guard, and it is unconditional.

**Root cause (five whys)**
1. Why does a zero-byte artifact crash? Because `bytes.bytesize` is called on `nil`.
2. Why is `bytes` `nil`? Because Ruby's `File#read(length)` returns `nil` at EOF instead of an empty string, and a zero-byte file is at EOF on the first read.
3. Why was that not caught? Because `read_stable_file` has no nil guard, and the surrounding `rescue` list (`verifier.rb:61-64`) covers `Errno::*` and `JSON::ParserError` — neither of which a `NoMethodError` is.
4. Why does the `rescue` list not cover it? Because the method's error contract is "raise a typed `Tamoz::Evals::Error`", which is enforced by convention at each raise site rather than by a catch-all — and this is the single site where a Ruby built-in returns a value the convention did not anticipate.
5. Why is that gap reachable? Because the byte-budget checks were written against `before.size` (`:559`) and against a *post-read* comparison (`:564`), so the author's model was "read returns a String whose size I must re-check" — the `NONBLOCK` flag, the reason `read` can return `nil` here, is not reflected in that model at the point where its result is dereferenced.

**Recommendation** (smallest credible action at the existing seam): one line at `verifier.rb:563` — `bytes = file.read(max_bytes + 1).to_s` (or guard with `raise InvalidArtifactError, "#{path}: #{kind} is empty" if bytes.nil?`). The former keeps the existing downstream comparisons intact and preserves the "empty document" path through `JSON.parse`, which already yields the correct typed `InvalidArtifactError` and exit code 2. If the fix is the explicit raise, the CLI needs no change. A regression case belongs beside the existing malformed-input coverage in `test/evals_verifier_test.rb`.

### F26-EVD-02 — a `pass` row is decided by exit status and a nonzero run count, so a zero-assertion case is recorded `pass`

- **Severity**: `minor`
- **Confidence**: `high` for the mechanism; `medium` for the risk, because no committed row currently exploits it.
- **Status**: `open`
- **Owning seam**: `run_case` (`script/generate_requirements_audit:84-100`)

**Source evidence**
- `script/generate_requirements_audit:84-100` — `outcome` is derived from `summary[:runs]`, `summary[:failures]`, `summary[:errors]`, `summary[:skips]` and `status.success?`. The assertion count is matched by `SUMMARY_LINE` (`:73`) but never inspected.
- **Probe**: a case whose body contains no assertion runs as `1 runs, 0 assertions, 0 failures, 0 errors, 0 skips` and exits 0, so the generator maps it to `pass`. The same is true with or without the filter.
- `requirements_manifest_test.rb:110-126` (`test_every_named_test_exists_and_defines_its_case`) asserts only that the **name** appears as `def <case>` in the named file — it does not assert the body asserts anything.
- **Measured, not assumed**: I ran the generator's own filter across all **251** distinct evidence references backing the **499** `pass` rows and read each summary line. Result: **0 zero-assertion cases**, and the highest-risk rows carry real weight (e.g. `INV-19`'s kill-window case at 312 assertions, `OBJ-4`'s kill-matrix case at 13). So this is a live hole in the contract with no current occupant.

**Independent judgment**: I confirmed the mechanism and deliberately measured the whole pass corpus rather than reasoning from a sample, because the finding is only worth recording if it is not already being exploited. It is not. Severity is `minor` on that basis: the bar for `critical` requires materially misleading evidence actually present, and I found none. It is recorded because the row name is "verification and release evidence" and this is the residual way a `pass` can be vacuous — the generator's own comment at `:88-90` shows the author was already reasoning about exactly this class of hole for stale names and skips, but assertion count was left out.

**Root cause**: the generator's model of "the case proved the requirement" is exit-status-plus-run-count; Minitest's `skips` and `runs` counters were both consulted, but `assertions` was parsed and discarded, so a body that executes and asserts nothing is indistinguishable from one that asserts the invariant.

**Recommendation**: one clause in `run_case`'s `outcome` chain — treat `summary[:assertions].to_i.zero?` as `not-run`, exactly as `skips` is already treated at `:93-95`. One line, same seam, no new machinery; `SUMMARY_LINE` already captures the value.

## Blind spots

- **`test/packaging_test.rb` (1052 lines) was `not run`.** It is on the Rakefile `SERIAL_TESTS` list (`Rakefile:66`) and prior finding 009 already covers it. I did not verify gem packaging, `exe/tamoz-eval` install behavior, or the gemspec's generated file list. If this row's verdict needs packaging evidence, it must come from that file.
- **The 284 test executions the audit generator would perform were not re-run.** I ran the generator's *mapping* against real no-match and whitespace runs, and I ran 3 of the cited cases individually, but I did not regenerate `docs/requirements-audit.json` (the brief forbids writing into the repo, and the generator rewrites three committed artifacts). So `F26-EVD-01` establishes that the committed audit disagrees with the committed manifest and with `limitations.md`; it does not establish the *correct* current status of all 529 rows.
- **Which side of the six environment-bound rows is stale is unresolved.** `INV-19`'s and `OBJ-4`'s supporting kill-window cases both pass here (312 and 13 assertions). Either the constraint that produced the `limitations.md` text no longer reproduces on this machine, or the text is the stale side. Deciding that needs a full regeneration on an authorized machine — outside this read-only budget.
- **`case.schema.json` and `evidence.schema.json` were read structurally, not line by line.** I enumerated every `$defs` object and every `additionalProperties`, `anyOf`, and `$ref` site programmatically, and probed the four `additionalProperties`/`anyOf` behaviors against the result schema, but I did not hand-audit all 536 + 619 lines of the case and evidence schemas for semantic gaps of the kind `verify_case_semantics!`/`verify_evidence_semantics!` might not cover.
- **E02 (`exe/tamoz-eval`) is another analyst's row.** I read it (6 lines) only to establish this gem's CLI contract, and the `F26-ERR-01` probe reports the exit-code consequence through `Tamoz::Evals::CLI`. I claim no verdict on E02 itself.
- **`script/generate_requirements_manifest` (1181 lines) was not read.** I verified the manifest's *output* against the audit, the ADR tree, and the regenerability test; I did not audit the generator's own correctness, which belongs to the R001/Rakefile-support row rather than F26.
- **No real LLM was called**, per the brief. Nothing in this row required one: every artifact path here is deterministic.

## Verdict

**IMPROVE** — counts: **critical 0, major 2, minor 1, info 0.**

Per BAR.md: at least one accepted `major` finding, so the row cannot be `PASS`.

The verifier core is the strongest part of this row and I want that on the record precisely: the digest is recomputed on read with a domain separator, all 52 schema objects are closed to unknown properties, reference paths are `realpath`-re-resolved inside the artifact directory, files are re-`stat`ed for stability mid-verification, and eight of nine malformed-input probes fail closed with typed errors. The two major findings are both at the boundary rather than in the engine: one missing nil guard on the *ninth* probe, and one generated artifact that has drifted from the manifest and the documentation it is supposed to measure. The second is the more consequential, because the README (`README.md:144-146`) sells that artifact as the reason a release row can be trusted, and nothing in the fast gate re-verifies it — while the sibling `BENCHMARK_PROTOCOL.json` gets exactly that treatment and passes all 10 of its tests.

Six lenses reviewed: correctness, security/authority, reliability/durability, observability/evidence, scalability/resource bounds, maintenance/architecture. None `not evidenced`.

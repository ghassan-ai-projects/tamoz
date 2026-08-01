# Patch encoding and gate locale correction

Review target: `Toolbox#prepare_patch` text splicing and every project read path whose
result depends on `Encoding.default_external`.

Reviewed base: `0abb42a`.

Decision: accepted correction on 2026-08-01, subject to the recorded full gate under both
`LC_ALL=en_US.UTF-8` and `LC_ALL=C`. This corrects committed P1/P0 code. It is not a phase
and opens no capability. P4 remains the next phase and remains unstarted.

## Findings

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | `apply_patch` silently destroys file content when `before` contains multi-byte UTF-8, reports success, and returns an `after_sha256` that matches the corrupted bytes | `prepare_patch` spliced with `after_content[index, before.bytesize]`, mixing a character index and length API with a byte length | Splice with `before.length`, the character length the API expects |
| High | The unified diff hunk header reports the wrong line when text before the match contains multi-byte UTF-8 | `content.byteslice(0, index)` applied a character index to a byte-domain API | Count newlines in `content[0, index]`, the character-domain prefix |
| High | `rake ci` aborts under `LC_ALL=C`, the default in most containers, cron jobs and CI runners | `docs/design-v0.1/validate_design.rb` read design documents with `File.read` and inherited `Encoding.default_external`; the documents contain UTF-8 punctuation | Read every design document as UTF-8 explicitly |
| High | `DocumentationTest#test_design_source_and_contract_counts_are_pinned` errors under `LC_ALL=C` | `Pathname#read` without an encoding on `INVARIANTS.md` and `DECISIONS.md` | Read as UTF-8 explicitly, matching the sibling test in the same file |
| Medium | `search_text` raises an untyped `Encoding::CompatibilityError` out of `Toolbox#execute` for a multi-byte query under a non-UTF-8 locale | `path.each_line` inherited `Encoding.default_external`; the tool's own rescue list covers only `ArgumentError` and two `EncodingError` subclasses | Read lines as UTF-8 explicitly, restoring the typed skip path the rescue was written for |

## Defect class A: character index used with a byte length

`String#[]`, `String#[]=`, `String#index`, `String#length`, and `String#count` are
character-domain. `String#bytesize`, `String#byteslice`, and `String#byteindex` are
byte-domain. Mixing them is silent for ASCII, where the two domains coincide, and lossy for
every other input.

Every site in the repository that combines an index with a length was inspected.

| Site | Verdict |
|---|---|
| `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:300` | **defect.** `after_content[index, before.bytesize] = after` consumed `before.bytesize - before.length` characters beyond the match. Corrected. |
| `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:310` | **defect.** `content.byteslice(0, index).count("\n")` under-counted newlines whenever multi-byte text preceded the match. Corrected. |
| `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:396-412` `read_bounded` | correct. `IO#readpartial` yields binary chunks; `bytesize`, `byteslice`, and the closing `force_encoding(UTF_8).scrub` are all byte-domain. Byte-identical output was observed under both locales for valid UTF-8 and for invalid bytes. |
| `gems/tamoz-evals/lib/tamoz/evals/duplicate_key_detector.rb:86-136` | correct. `@index` is a byte cursor used only with `getbyte`, `byteslice`, and `bytesize`. Structural JSON characters are ASCII, and no UTF-8 continuation byte can collide with them. |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_registry.rb:362-365` | correct. Width and offset are both derived from `bytesize` and consumed by `byteslice`. |
| `gems/tamoz-evals/lib/tamoz/evals/harness/subprocess_runner.rb:226-234, 413-425` | correct. The accumulator is explicitly binary, and `byteslice` truncation is followed by `scrub("")`, so a split multi-byte character cannot survive. |
| `gems/tamoz-graph/lib/tamoz/graph/checkpoint_codec.rb:266-306` | correct. Byte-domain bounds; `force_encoding` is followed by a `valid_encoding?` gate. |
| `gems/tamoz-core/lib/tamoz/state_codec.rb:110, 376-405`, `immutable.rb:93-99`, `safe_text.rb` | correct. All limits are byte limits over `bytesize`; strings are encoded to UTF-8 before measurement. |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/wire.rb:87-90`, `store.rb:247, 277` | correct. Constant-time compare and hex handling are byte-domain throughout. |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit.rb:90-97` | correct. `File.binread` plus `force_encoding` plus `valid_encoding?`. |
| `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:73, 123, 522-530` | correct. `IO#read(length)` returns binary; sizes and digests are byte-domain. |
| Remaining `bytesize` uses (identifier, task, path, query, argv, and observation bounds) | correct. Each is a byte budget compared against a byte count, never used as an index or length into a character API. |

### Why the byte length looked right

Every other bound in `Toolbox` is a byte bound: `MAX_FILE_BYTES`, `MAX_PATCH_BYTES`,
`MAX_CHECK_OUTPUT_BYTES`, the 4096-byte path limit, and the 256-byte query limit. The one
place that needed a character length is surrounded by places that correctly need bytes.

### Reproduced behavior at the reviewed base

Executed against the real `Toolbox`, `expected_sha256` valid, approval granted:

| `before` | Overhead | Applied result |
|---|---|---|
| `NAME = "hello"` | 0 bytes | correct |
| `NAME = "héllo"` | 1 byte | trailing newline eaten; two lines joined |
| `LABEL = "日本語テキスト"` | 14 bytes | the entire following line destroyed |
| `ICON = "👩‍💻"` | 14 bytes | the entire following line destroyed |
| `NAME = "hello"`, multi-byte elsewhere in the file | 0 bytes | correct |
| `NAME = "hello"`, multi-byte only in `after` | 0 bytes | correct |

The fault is exactly `before.bytesize`. In all three corrupting cases the tool returned
`Applied <path>` and an `after_sha256` equal to the SHA-256 of the corrupted bytes on disk.

## Five Whys: a successful receipt for a destroyed file

1. Why was content destroyed? The splice length was `before.bytesize` while `String#[]=`
   interprets its second argument as a character count.
2. Why was a byte length reached for? Every neighbouring limit in `Toolbox` is a byte
   limit, so "the size of `before`" was written the way size is written everywhere else in
   the class.
3. Why did tests, fixtures, and the scorecard not catch it? Every P0-P3 fixture, workspace,
   and evaluation case is ASCII, and for ASCII `bytesize == length`. The defect is
   unreachable from the entire committed corpus.
4. Why did the digest receipt not catch it? `after_sha256` is taken from the same in-memory
   buffer that is written. The receipt is self-consistent by construction. It proves that
   publication was atomic and that the bytes on disk are the bytes intended by the splice.
   It cannot prove that the splice implemented the approved edit.
5. Why is this release-blocking rather than an ordinary bug? Approval is rendered from
   `before_text` and `after_text` while execution writes a buffer produced by a different
   computation. The reviewer therefore authorized an edit that was never performed.
   `docs/PROJECT_HANDOVER_PLAN.md` §6 P4 names "approval preview can differ from execution"
   as a stop/redesign condition; it was already true at P1. Under P6-C the corrupted file
   would be reconciled and journalled as a successful filesystem effect, because its
   proven-after digest matches.

## Restored semantics

For `apply_patch` on a file whose content is `content`:

- `before` must occur exactly once in `content`, counted by `String#scan`, which is
  character-domain and already correct;
- the applied bytes are `content` with that single occurrence replaced by `after`, and
  nothing else changes;
- the preview describes exactly that replacement, and the hunk header line is the 1-based
  line on which the occurrence starts.

This is the single-occurrence literal replacement. It is deliberately implemented as an
index/length splice rather than `content.sub(before, after)`, because `String#sub` expands
`\0`, `\&`, and `\\` inside a String replacement: `"X = A".sub("A", 'B\0C')` yields
`"X = BAC"`, while the approved `after` text is `B\0C`. The splice is byte-for-byte equal to
`content.sub(before) { after }` for every input, and equal to `content.sub(before, after)`
for every `after` without a backslash escape.

## Defect class B: text read under the ambient locale

`File.read`, `IO.read`, `Pathname#read`, `File.readlines`, `IO.foreach`, `Pathname#each_line`,
backticks, and `Open3` output all tag their result with `Encoding.default_external`, which is
derived from `LANG`/`LC_ALL`. Under `LC_ALL=C` that is US-ASCII, and any regexp, `scan`,
`include?`, or comparison against non-ASCII content raises or silently returns the wrong
answer.

Forcing UTF-8 is not universally right. For genuinely binary data the correct form is
`binread`/`IO#read(length)` plus an explicit `valid_encoding?` gate, which is what the
persistence, codec, and verifier layers already do.

Every read site was inspected and classified.

| Site | Verdict |
|---|---|
| `docs/design-v0.1/validate_design.rb:40, 66, 83, 117, 123, 128, 156` | **defect.** Reads design Markdown that contains UTF-8 punctuation. Aborts `rake ci` under `LC_ALL=C`. Corrected to explicit UTF-8. |
| `test/documentation_test.rb:23-25` | **defect.** Reads `INVARIANTS.md` and `DECISIONS.md`, both non-ASCII. Errors under `LC_ALL=C`. Corrected to explicit UTF-8, matching `test_local_markdown_links_resolve` in the same file, which was already correct. |
| `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:259` `search_text` | **defect.** Reads arbitrary workspace files under the ambient locale and compares them to a model-supplied query. Under `LC_ALL=C` a multi-byte query raises `Encoding::CompatibilityError`, which is not in the loop's rescue list and escapes `Toolbox#execute` untyped, contrary to invariant 17. Corrected to explicit UTF-8, which routes an undecodable file into the existing `ArgumentError` rescue and skips it as intended. |
| `test/core_pool_test.rb:171`, `test/m1_evidence_test.rb:44`, `test/m2_evidence_test.rb:45`, `test/ci_configuration_test.rb:9, 31` | **latent.** These read tracked repository files that are ASCII today but are not constrained to stay ASCII; `INVARIANTS.md` proves the repository does not hold that constraint. Corrected to explicit UTF-8 so the gate is locale-independent by construction rather than by accident. |
| `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb:256, 313, 341, 472, 538, 726` | no change. Each oracle compares a file the harness itself wrote from an ASCII literal in the same process against that same literal. Two ASCII-only strings are encoding-comparable in every locale. Verified: the scorecard produces identical aggregates and the identical `content_digest sha256:57a2ac8f…` under `LC_ALL=en_US.UTF-8` and `LC_ALL=C`. |
| `test/agent_toolbox_test.rb:85, 111`, `test/sqlite_backup_test.rb:41, 50`, `test/agent_change_evaluation_test.rb:97, 150`, `test/agent_repair_evaluation_test.rb:373`, `test/sqlite_crash_recovery_test.rb:135` | no change for the existing assertions, same reason: ASCII fixtures written by the test itself. New multi-byte assertions added by this correction read explicitly as UTF-8. |
| `gems/tamoz-evals/lib/tamoz/evals/schema.rb:28`, `test/test_helper.rb:29`, `test/sqlite_raw_oracle_test.rb:375`, `test/documentation_test.rb:10`, `toolbox.rb:224, 287` | already correct. Explicit UTF-8. |
| `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:522-530`, `gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit.rb:90` | already correct, and correctly *not* UTF-8 at read time. Both read bytes (`IO#read(length)`, `File.binread`) and gate on `valid_encoding?` afterwards. Forcing UTF-8 at the read would destroy the ability to reject a non-UTF-8 artifact. |
| `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:363-412` `run_check` | already correct. Subprocess output is accumulated as bytes and finalized with `force_encoding(UTF_8).scrub`. Observed byte-identical under both locales. |
| `gems/tamoz-agent/lib/tamoz/agent/cli.rb:147` `@input.gets` | no change. The answer is compared against `%w[y yes]` after `strip.downcase`. A non-ASCII answer is not equal to either token under any locale, and a non-answer is a denial. Changing the CLI input encoding is a P7 concern, not a correctness fix. |
| `.github/workflows/ci.yml` | no change. Pinning a locale in the workflow would hide the defect instead of fixing it, and would leave every container, cron job, and release rehearsal outside that workflow still broken. |

## Five Whys: the phase gate depended on an environment variable

1. Why does `rake ci` abort under `LC_ALL=C`? `validate_design.rb` scans design text that
   `File.read` tagged US-ASCII.
2. Why is the tag wrong? `File.read` inherits `Encoding.default_external`, and the design
   documents contain UTF-8 punctuation, so `String#scan` raises
   `ArgumentError: invalid byte sequence in US-ASCII`.
3. Why was it never observed? Every gate run so far happened in an interactive macOS shell
   with a UTF-8 locale, and the GitHub runner image happens to export `C.UTF-8`. Neither is
   pinned or asserted.
4. Why does the same class appear in three separate layers? "Read a text file" was written
   as `read(encoding: Encoding::UTF_8)` in some places and as bare `File.read` in others.
   No rule was ever stated, so both forms coexisted and neither was wrong-looking.
5. Why is this worse than an inconvenience? `rake ci` is the declared phase gate for every
   phase in the handover plan, and P15-H requires release reproduction that does not depend
   on the development checkout. A gate whose outcome depends on an ambient environment
   variable certifies the environment, not the code.

## Failure taxonomy after the correction

| Input | Outcome |
|---|---|
| single-occurrence `before`, any UTF-8 content | exactly that occurrence replaced; preview equals execution |
| `before` absent | `ToolError` "patch text was not found"; file untouched |
| `before` occurring more than once | `ToolError` "patch text is ambiguous"; file untouched |
| empty `before` | `ToolError` at validation; file untouched |
| `expected_sha256` stale, uppercase, or malformed | `ToolError`; file untouched |
| `after` not valid in its own encoding | `ToolError` at validation; file untouched |
| result exceeding `MAX_FILE_BYTES` | `ToolError`; file untouched |
| absolute path, root escape, null byte, symlink target | `ToolError`; file untouched |
| non-UTF-8 file content | `ToolError` "file is not valid UTF-8 text"; file untouched |
| `search_text` over a file that is not valid UTF-8 | that file is skipped; the search continues |
| `search_text` with a multi-byte query, any locale | matches by character content |
| design document that is not valid UTF-8 | `validate_design.rb` raises rather than passing silently, under every locale |

## Regression proof

Four new deterministic tests fail against `0abb42a` and pass against the correction. One
further test records the rejection floor, which the correction must not move.

| Test | Property |
|---|---|
| `AgentToolboxTest#test_patch_replaces_exactly_one_multibyte_occurrence` | five cases (1-byte overhead, a wide script, a combined emoji, multi-byte outside the match, multi-byte only in the replacement); the bytes on disk equal the single-occurrence replacement, the file's byte length equals `original - before + after`, the preview equals the applied edit, and `after_sha256` equals the digest of the correct content |
| `AgentToolboxTest#test_patch_preview_locates_an_occurrence_following_multibyte_text` | the hunk header names line 3 when two multi-byte lines precede the match |
| `AgentToolboxTest#test_search_text_matches_a_multibyte_query_without_a_utf8_locale` | a subprocess under `LC_ALL=C` returns the matching line instead of raising |
| `DocumentationTest#test_design_validation_passes_without_a_utf8_locale` | the real gate script exits 0 under `LC_ALL=C` |
| `AgentToolboxTest#test_every_patch_rejection_leaves_the_target_byte_identical` | ten rejections over multi-byte content (stale digest, uppercase digest, zero match, ambiguous match, empty `before`, invalid-UTF-8 `after`, absolute path, root escape, null-byte path, symlink target) each raise `ToolError` from both `preview` and `execute` and leave the file byte-identical |

Observed against `0abb42a` with the corrected tests in place:

| Test | Pre-correction result |
|---|---|
| `test_patch_replaces_exactly_one_multibyte_occurrence` | fail: applied `NAME = "world"NEXT = 1\n`, expected `NAME = "world"\nNEXT = 1\n` |
| `test_patch_preview_locates_an_occurrence_following_multibyte_text` | fail: `@@ -2,1 +2,1 @@`, expected `@@ -3,1 +3,1 @@` |
| `test_search_text_matches_a_multibyte_query_without_a_utf8_locale` | fail: `Encoding::CompatibilityError: incompatible character encodings: US-ASCII and UTF-8` |
| `test_design_validation_passes_without_a_utf8_locale` | fail: `ArgumentError: invalid byte sequence in US-ASCII` |
| `test_every_patch_rejection_leaves_the_target_byte_identical` | pass, as required of a floor |

## Compatibility

No public API changed: no tool name, argument name, receipt line, error class, event, or
digest domain moved. The corrected splice and the previous splice agree on every ASCII
input, so every committed fixture, baseline, scorecard case, and corpus digest is unchanged.
`agent-smoke` retains `content_digest sha256:57a2ac8f…`.

## Residual risk

- **Not fixed, and reported for a separate decision.** `Toolbox#validate_patch_text!` states
  "`after` must be valid UTF-8" but tests `value.valid_encoding?`, which asks only whether a
  string is valid *in its own encoding*. A String tagged `ASCII-8BIT` containing `\xFF`
  passes that check, and `apply_patch` then writes those bytes into a file that `read_file`
  will subsequently reject as "not valid UTF-8". Reproduced at this base and unchanged by
  this correction. The minimal fix is to require `value.encoding == Encoding::UTF_8` in
  addition to `valid_encoding?`. It is a strict tightening of an action tool's input
  contract and is deliberately left outside a correction whose authorized scope is the two
  defects above. It is not reachable through the CLI, where arguments arrive from
  `JSON.parse` as UTF-8.
- The correction adds no protection against a *future* character/byte mix-up. The audit
  above is a point-in-time result, not an enforced rule; there is no lint for it.
- `search_text` still returns whole matching lines subject only to a result count bound, so
  a single very long line remains a large observation. Unchanged by this correction.
- The evaluation corpus is still entirely ASCII. The new regression tests cover multi-byte
  patching at the `Toolbox` boundary, not at the scorecard boundary. A behavioural case for
  multi-byte editing belongs with P4, where the compound-edit corpus is authored.
- Locale independence is now a property of the code, not an asserted invariant. Nothing
  fails if a future read is written as bare `File.read` again.

## Gate evidence

Executed under rbenv Ruby 3.3.11:

- reviewed base `0abb42a`: `rake ci` under `LC_ALL=en_US.UTF-8` passed with 351 tests and
  27,221 assertions; under `LC_ALL=C` `design:validate` aborted with
  `invalid byte sequence in US-ASCII`, and running the suite alone still errored in
  `DocumentationTest#test_design_source_and_contract_counts_are_pinned`;
- corrected tree: `rake ci` under `LC_ALL=en_US.UTF-8` — design validation over 22
  documents, 55 invariants, 40 ADRs; 356 tests, 27,286 assertions, 0 failures, 0 errors,
  0 skips;
- corrected tree: `rake ci` under `LC_ALL=C` — identical design validation output; 356
  tests, 27,286 assertions, 0 failures, 0 errors, 0 skips;
- `tamoz-eval scorecard agent-smoke` under both locales: `"decision":"pass"`, all four hard
  gates pass, `content_digest sha256:57a2ac8fea4cc03f51676f0b009add6ae09fac9d0ae7985942e044737ff1e699`
  in all three of the pre-correction run, the corrected UTF-8 run, and the corrected `C`
  run, with aggregates byte-identical to the pre-correction baseline: 6 task successes, 6
  verified completions, 0 unsafe or bypassed actions, 0 false-positive completions, 0
  incomplete case evidence, 1 unnecessary mutation, 1 repeated-action stop;
- `ruby -wc` clean on every changed file; `git diff --check` clean.

The 351 -> 356 test delta is the five tests added by this correction. No expected value was
adjusted to make anything green.

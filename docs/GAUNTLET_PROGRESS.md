# Tamoz Gauntlet Loop — live progress

Status: **active**
Started: 2026-08-01
Last verified: 2026-08-01 at commit `a019167` (P8-A/B/C landed; P8-E next)
Goal: finish P4–P15 of `docs/PROJECT_HANDOVER_PLAN.md` to production quality, with every
phase passing real behavioural proofs and hard-zero safety gates.

Method: each work package gets a **builder** and a separate **harsh critic** with fresh
context. The critic runs the real output, compares it against the bar with held-out probes
the builder never saw, runs a blind A/B against the previous implementation, and returns the
single biggest remaining gap. Rounds repeat until the package wins.

Owner constraints in force: **no push, no publish, no release, no real physical actuators.**

---

## 1. Judging substrate

The loop is only as honest as its judge, so the judge was built and validated first.

| Component | Location | What it proves |
|---|---|---|
| `gauntlet_gate` | scratchpad harness (uncommitted and ephemeral) | clean worktree; `rake ci` green under **both** UTF-8 and C/POSIX locales; scorecard `decision=pass`; every hard gate pass; hard-zero safety counters; task-success floor never regresses |
| `gauntlet_ab` | scratchpad harness (uncommitted) | materialises two git refs as separate detached worktrees and runs an **identical** probe set against both — neither ref can see the other, and the probes live outside the repository so no builder can tune to them |
| held-out probes | scratchpad harness (uncommitted) | byte-level behavioural facts (not implementation self-reports): file digests before/after, preview-vs-execution agreement, receipt truthfulness |

The harness is deliberately kept **out of the committed tree**: it is judging apparatus, not
product. Committing it would let a builder read or edit its own exam.

### Baseline gate result (commit `0abb42a`, unchanged code)

| Check | Result |
|---|---|
| worktree clean | pass |
| `rake ci` under UTF-8 | pass — 351 runs, 27,230 assertions, 0 failures |
| `rake ci` under C/POSIX | **FAIL** — see D-1 |
| scorecard decision | pass |
| hard gates (4) | pass |
| hard-zero safety counters | pass — unsafe/bypassed 0, false-positive completions 0, incomplete evidence 0 |
| task successes | 6/12 (floor) |

---

## 2. Defects found at the unchanged baseline

The handover plan requires diagnosing a red baseline before adding capability. Two real
defects were found in **already-committed, already-reviewed** code before any new work began.

### D-1 — the project's own quality gate is locale-dependent (severity: high)

`docs/design-v0.1/validate_design.rb` reads design documents without specifying an encoding,
so it inherits `Encoding.default_external`. Under `LANG=C`/`LC_ALL=C` — the default in most
containers, cron jobs and CI runners — `rake ci` aborts:

```
docs/design-v0.1/validate_design.rb:55:in `scan': invalid byte sequence in US-ASCII (ArgumentError)
```

Why it matters: `rake ci` is the phase gate for **every** phase in the handover plan. A gate
that only passes on one machine's locale cannot certify a release, and P15-H explicitly
requires release reproduction that does not depend on the development checkout.

Status: **closed in `fe1d26e`; independently reverified under `LC_ALL=C`.**

### D-2 — `apply_patch` silently corrupts files containing multi-byte UTF-8 (severity: critical)

`Toolbox#prepare_patch` (`gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:300`) computes a
**character** index and then splices using a **byte** length:

```ruby
index = content.index(before)              # character index
after_content[index, before.bytesize] = arguments.fetch("after")   # character length
```

For any `before` text containing multi-byte UTF-8 the splice consumes
`before.bytesize - before.length` extra characters **beyond the matched region**.

Measured on the real implementation (held-out probe `p01`):

| Case | `before` overhead | Exact replacement? | Following line survived? | Reported success? |
|---|---|---|---|---|
| pure ASCII | 0 bytes | yes | yes | yes |
| Latin-1 accent (`héllo`) | 1 byte | **no** | yes (newline eaten, lines joined) | yes |
| CJK (`日本語テキスト`) | 14 bytes | **no** | **no — following line destroyed** | yes |
| emoji ZWJ (`👩‍💻`) | 14 bytes | **no** | **no — following line destroyed** | yes |
| multi-byte elsewhere in file | 0 bytes | yes | yes | yes |
| multi-byte only in `after` | 0 bytes | yes | yes | yes |

The last two controls confirm the fault is specifically `before.bytesize`.

Why it matters, beyond data loss:

1. **The approval preview does not describe what execution performs.** The rendered diff is
   correct; the applied bytes are not. `PROJECT_HANDOVER_PLAN` §6 P4 names exactly this as a
   stop/redesign condition — and it is already true at P1.
2. **The receipt is truthful about a wrong result.** `after_sha256` matches the corrupted
   bytes on disk, so digest-checking downstream cannot detect it. Under P6 this would be
   journalled as a successfully reconciled effect.
3. It is invisible to the current gate: 351 tests and the 12-case scorecard all pass.

Status: **closed in `fe1d26e`; held-out multibyte and literal-backslash probes pass.**

### D-3 — `search_text` crashes with an unrescued encoding error under `LANG=C` (severity: high)

`Toolbox#search_text` reads candidate files with `Pathname#each_line`, which decodes using the
ambient `default_external`. Under `LANG=C` a multi-byte query against a UTF-8 file raises:

```
Encoding::CompatibilityError: incompatible character encodings: US-ASCII and UTF-8
```

The method's rescue list covers `ArgumentError`, `Encoding::InvalidByteSequenceError` and
`Encoding::UndefinedConversionError`. `Encoding::CompatibilityError` is a sibling under
`EncodingError` and is **not** caught, so it escapes a *read-only* tool as a raw
`EncodingError` rather than a typed `ToolError`.

Why it matters: invariant 17 requires that only recoverable tool failures become values, and
that everything else be a genuinely propagating class (cancellation, policy violation,
programmer bug, storage corruption). An ambient-locale encoding mismatch is neither. The
agent loop cannot treat it as a recoverable tool failure, so a read-only search aborts the
turn.

Measured: `LANG=C` + ASCII query → ok; `LANG=C` + multi-byte query → **raises**;
`LANG=en_US.UTF-8` + either → ok.

Status: **closed in `fe1d26e`; independently reverified under `LC_ALL=C`.**

### D-4 — `read_file` returns invalid UTF-8 instead of the documented error (severity: medium)

`Toolbox#read_file` opens with `encoding: Encoding::UTF_8` but never checks
`valid_encoding?`. `Pathname#read(encoding:)` tags bytes without validating them, so a file
containing `\xC3\x28` was returned to the model as content with `valid_encoding? == false`,
instead of raising the documented `file is not valid UTF-8 text`. The same gap existed in
`prepare_patch`, where an invalid-UTF-8 target raised an untyped `ArgumentError` from
`content.scan(before)` rather than a typed `ToolError`.

Status: **closed in `a88f403`; both `read_file` and `apply_patch`/`preview` now raise typed
`ToolError` and leave the target byte-identical. Verified under `LC_ALL=en_US.UTF-8` and
`LC_ALL=C`.**

### D-5 — patch text accepts non-UTF-8 binary strings (severity: high)

`validate_patch_text!` checked `valid_encoding?` in the string's current encoding rather than
requiring UTF-8. An `ASCII-8BIT` string containing bytes invalid in UTF-8 could pass
validation and be written by the public Ruby API.

Status: **closed in `a88f403`; `validate_patch_text!` now rejects null bytes, non-UTF-8
encoding tags, and invalid UTF-8 byte sequences with accurate per-cause messages. Verified
under both locales.**

### Regression floor established

Held-out probe `p02` confirms all ten byte-level safety invariants hold at baseline and must
keep holding: stale digest, zero match, ambiguous match, empty `before`, uppercase digest,
absolute path, root escape, null-byte path, invalid UTF-8 `after`, symlink target. Every one
rejects **and leaves the file byte-identical**. No fix may weaken any of these.

---

## 3. Round ledger

| Round | Scope | Builder | Critic | Verdict | Commit |
|---|---|---|---|---|---|
| 0 | judging substrate + baseline audit | main | — | substrate validated; 4 defects found | — |
| 1 | D-1 locale gate + D-2 multibyte corruption (+D-3 found by builder) | done | done | **pass against baseline; D-4/D-5 split out** | `2df0063`, `fe1d26e`, `b5f7fb9`, `39a8679` |
| 2 | D-4/D-5 UTF-8 contract correction | done | done | **pass against baseline; invariant-17 matrix added** | `b213b4a`, `a88f403` |
| 5 | P6 durable session and effect recovery | done | in flight | **coordinator gate PASS; independent critic still running** | `8c977dc`, `2d94908`, `b69701c`, `752363f` |
| 7 | P7 interactive/resumable CLI | done (builder + coordinator; quota killed subagents) | pending (quota) | **P7 closed — coordinator gate PASS; scorecard 9/13, safety zero** | `1f2c56a`, `9500acb`, `1e404d8`, `7469fa2` |

### Round 1 — builder result

Two commits, following the repo's own correction protocol (documentation checkpoint first,
then implementation).

The implementation is three surgical lines plus tests — no API change, no refactor:

```diff
-        after_content[index, before.bytesize] = arguments.fetch("after")
+        after_content[index, before.length] = arguments.fetch("after")
-          line: content.byteslice(0, index).count("\n") + 1
+          line: content[0, index].count("\n") + 1
-          path.each_line.with_index(1) do |line, number|
+          path.each_line(encoding: Encoding::UTF_8).with_index(1) do |line, number|
```

Independently verified by the coordinator on `fe1d26e` (held-out probes p01/p05):

| Probe case | baseline `0abb42a` | HEAD `fe1d26e` |
|---|---|---|
| p01 ascii_control | exact | exact |
| p01 latin1_accent | **corrupt** | exact |
| p01 cjk | **corrupt, next line destroyed** | exact |
| p01 emoji_zwj | **corrupt, next line destroyed** | exact |
| p01 multibyte_before_target | exact | exact |
| p01 multibyte_growing_replacement | exact | exact |
| p05 search_multibyte under `LANG=C` | **raises `Encoding::CompatibilityError`** | ok |
| p05 read_invalid_utf8 | returns invalid UTF-8, no error | **unchanged — D-4 still open** |

Credit where due — the builder produced two things the coordinator had not:

1. It found **D-3** independently, correctly diagnosing the invariant-17 violation (an
   untyped `EncodingError` escaping a read-only tool instead of becoming a `ToolError`).
2. It found a defect the coordinator missed: `validate_patch_text!` documents "`after` must
   be valid UTF-8" but tests `value.valid_encoding?`, which only asks whether a string is
   valid *in its own encoding*. A String tagged `ASCII-8BIT` containing `\xFF` passes. The
   builder scoped this out of an authorised two-defect correction and reported it for a
   separate decision rather than silently widening the change — the correct call.

It also declined to pin a locale in `.github/workflows/ci.yml`, on the grounds that doing so
"would hide the defect instead of fixing it, and would leave every container, cron job, and
release rehearsal outside that workflow still broken." That is the right judgement and the
tempting wrong move.

**The builder corrected the judge.** Probe p01 computed its expected value as
`content.sub(before, after)`. `String#sub` with a *String* replacement expands `\0`, `\&`,
`\\` and `\1..\9`. Verified: `"X = A".sub("A", 'B\0C')` → `"X = BAC"`, while the correct
literal splice gives `"X = B\0C"`.

The probe was wrong, not the code — and the distinction is a safety property, not a
technicality. An implementation built on `sub` would write bytes **different from the ones
the approval preview displayed** whenever `after` contains a backslash escape: an
approval-bypass vector. The splice is deliberate and correct.

p01 now uses the block form and carries four backslash cases (`\0`, `\&`, `\\`, `\1\2`).
All ten cases pass on HEAD. Recorded here because a Gauntlet whose bar is never wrong is a
Gauntlet that is not being checked: findings against the judge count, and this one was the
builder's.

**Disputed claim resolved — by the builder, against itself.** The correction document's
residual-risk section asserted `read_file` would reject invalid UTF-8. It does not. The
builder reached the same conclusion independently and committed `39a8679` recording it, and
went further than the coordinator's D-4: the `rescue Encoding::...` clause in both
`read_file` and `prepare_patch` is **dead code**, because `Pathname#read(encoding:)` tags
bytes without transcoding. Consequently `apply_patch` against a non-UTF-8 target raised an
untyped `ArgumentError` out of `content.scan(before)` rather than a `ToolError` — a second
invariant-17 gap. Fail-closed (file byte-identical) and unchanged by this round.

**Disputed claim sent to the critic (superseded).** The correction document's residual-risk
section asserted that `apply_patch` writing raw bytes yields "a file that `read_file` will
subsequently reject as 'not valid UTF-8'." Measured behaviour contradicted this at both
baseline and HEAD. A review document asserting unverified behaviour is precisely the failure
mode an evidence-based process exists to prevent, so it is being adjudicated against running
code rather than prose.

### Round 1 — final critic and coordinator verdict

Round 1 is complete. The critic accepted the authorized correction after the builder and
critic corrected two inaccurate review claims in `b5f7fb9` and `39a8679`. The resulting
behaviour wins against `0abb42a` on the changed properties without weakening the fixed agent
scorecard or any hard safety gate.

Independent coordinator verification at `39a8679`:

| Check | Result |
|---|---|
| `rake ci`, `LC_ALL=en_US.UTF-8` | pass — 356 runs, 27,289 assertions, 0 failures/errors/skips |
| `rake ci`, `LC_ALL=C` | pass — 356 runs, 27,292 assertions, 0 failures/errors/skips |
| design validation | pass — 22 documents, 55 invariants, 40 ADRs |
| gem packaging | pass — all five gems |
| `tamoz-eval scorecard agent-smoke` | pass — fixed digest, 6/12 successes, all four hard gates pass |
| hard-zero counters | pass — unsafe/bypassed 0, false-positive completion 0, incomplete evidence 0 |

The assertion-count variance is pre-existing and honestly retained as residual gate debt;
test count and outcomes are stable. P4 capability work did not begin.

### Round 3 — P4 compound existing-file edits

The builder produced `docs/P4_COMPOUND_EDIT_PLAN.md`; the critic accepted it with a
single required correction (must prove signature stability and replacement-order
independence). The design checkpoint was committed at `a941f25`.

The builder then implemented P4-A/B/C in `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb`,
adding structural validation, set-level matching, atomic replacement, and signature
stability for compound replacements. The critic accepted the implementation after verifying
safety invariants, blind A/B against the baseline, and a new integration test.

The builder then implemented P4-E by flipping the `agent.multi-location-edit` scorecard
case to emit one compound `apply_patch` with a `replacements` array covering both locations.
The critic verified the scorecard rose from 6/12 to 7/12 with all hard gates still zero.

Independent coordinator verification at `67f72d7`:

| Check | Result |
|---|---|
| `rake ci`, `LC_ALL=en_US.UTF-8` | pass — 393 runs, 27,456 assertions, 0 failures/errors/skips |
| `rake ci`, `LC_ALL=C` | pass — 393 runs, 27,438 assertions, 0 failures/errors/skips |
| design validation | pass — 22 documents, 55 invariants, 40 ADRs |
| gem packaging | pass — all five gems |
| `tamoz-eval scorecard agent-smoke` | pass — fixed digest, 7/12 successes, all four hard gates pass |
| hard-zero counters | pass — unsafe/bypassed 0, false-positive completion 0, incomplete evidence 0 |

Blind A/B against `def7908` (pre-scorecard-flip baseline) on identical sandboxed tasks:

| Probe | Baseline `def7908` | New `67f72d7` |
|---|---|---|
| `agent.multi-location-edit` | failed — two separate single-replacement attempts | **succeeded** with one compound `apply_patch` |
| `agent.exact-edit-and-check` | unchanged success | unchanged success |
| `agent.stale-digest` | unchanged rejection | unchanged rejection |
| safety counters | 0 | 0 |

P4 is closed. The active phase moves to P5.

### Round 4 — P5 reviewed file creation

The builder produced `docs/P5_REVIEWED_FILE_CREATION_PLAN.md`; the critic rejected the
initial draft because the directory-symlink TOCTOU race was overstated and `AgentRunAudit`
did not count `create_file` as a mutation. The builder amended the plan to scope the race
honestly, add pre-link parent revalidation, and extend the audit mutation counters. The
amended plan was accepted.

The builder then implemented P5-A/B/C/E: a new `create_file` tool with path/parent/root/
symlink validation, UTF-8 content policy, digest/mode binding, and atomic no-clobber
publication via `Tempfile` + `File.link`; `Runtime` structural checks treat `create_file` as
a mutation step; `AgentRunAudit` counts it as a mutation and requires approval. The critic
found two required corrections: race-time `EEXIST` had to surface as `file already exists`
(plan-documented), and the special-bits mode check was unreachable dead code. Both were
fixed and re-verified.

Independent coordinator verification at `6504398`:

| Check | Result |
|---|---|
| `rake ci`, `LC_ALL=en_US.UTF-8` | pass — 408 runs, 27,596 assertions, 0 failures/errors/skips |
| `rake ci`, `LC_ALL=C` | pass — 408 runs, 27,596 assertions, 0 failures/errors/skips |
| design validation | pass — 22 documents, 55 invariants, 40 ADRs |
| gem packaging | pass — all five gems |
| `tamoz-eval scorecard agent-smoke` | pass — fixed digest, 8/12 successes, all four hard gates pass |
| hard-zero counters | pass — unsafe/bypassed 0, false-positive completion 0, incomplete evidence 0 |

Blind A/B against `4dcb9c1` (pre-P5 baseline) on identical sandboxed tasks:

| Probe | Baseline `4dcb9c1` | New `6504398` |
|---|---|---|
| `agent.new-file-need` | `plan_rejected` — no creation capability | **succeeded** with one reviewed `create_file` + check |
| `agent.one-pass-repair` | unchanged success | unchanged success |
| `agent.multi-location-edit` | unchanged success | unchanged success |
| safety counters | 0 | 0 |

P5 is closed. The active phase moves to P6.

### Round 2 — D-4/D-5 UTF-8 contract correction

The builder produced `docs/D4_D5_UTF8_CONTRACT_PLAN.md`; the critic accepted it with
corrections (null-byte rejection, accurate error messages, dead-rescue removal, `search_text`
scope, invariant-17 matrix). The design checkpoint was committed at `b213b4a`.

The builder then implemented the plan in `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb` and
`test/agent_toolbox_test.rb`, and added `test/agent_toolbox_invariant17_test.rb` after the
critic noted the missing matrix artifact. The critic accepted the implementation with the
matrix addition.

Independent coordinator verification at `a88f403`:

| Check | Result |
|---|---|
| `rake ci`, `LC_ALL=en_US.UTF-8` | pass — 370 runs, 27,342 assertions, 0 failures/errors/skips |
| `rake ci`, `LC_ALL=C` | pass — 370 runs, 27,339 assertions, 0 failures/errors/skips |
| design validation | pass — 22 documents, 55 invariants, 40 ADRs |
| gem packaging | pass — all five gems |
| `tamoz-eval scorecard agent-smoke` | pass — fixed digest, 6/12 successes, all four hard gates pass |
| hard-zero counters | pass — unsafe/bypassed 0, false-positive completion 0, incomplete evidence 0 |

Blind A/B against `019ea40` (the pre-correction baseline):

| Probe | Baseline `019ea40` | New `a88f403` |
|---|---|---|
| `read_file` invalid-UTF-8 target | returns invalid content silently | `ToolError: file is not valid UTF-8 text` |
| `apply_patch` invalid-UTF-8 target | `ArgumentError: invalid byte sequence in UTF-8` | `ToolError: file is not valid UTF-8 text` |
| `search_text` invalid-UTF-8 target | silently skipped | `ToolError: <path>: file is not valid UTF-8 text` |
| `validate` ASCII-8BIT `before` | accepted | `ToolError: before must be UTF-8 encoded` |
| `validate` invalid-UTF-8 search query | accepted | `ToolError: query must be valid UTF-8` |

All changed behaviour is fail-closed; no valid-UTF-8 path regressed.

---

### Round 6 — P7/P7 interactive CLI and P8 trusted profiles planning

Two design plans were produced in parallel and reviewed by separate critics with fresh context.

- **P7** — `docs/P7_INTERACTIVE_CLI_PLAN.md` defines a subcommand-based CLI (`ask`, `resume`,
  `continue`, `list`, `show`, `follow-up`, `redirect`, `cancel`, `resolve`) over the existing
  `Tamoz::Agent::Session`, adds a stream/emitter contract, kill-resume scorecard case, and
  clarification/approval interrupts. The initial critic rejected the draft over the missing
  stream contract, unsound cancel semantics, bare-invocation ambiguity, and effect-journal
  vocabulary; all were amended and the plan is now **accepted**.
- **P8** — `docs/P8_TRUSTED_PROFILES_PLAN.md` defines operator-owned YAML profiles outside the
  repository, strict load/validate/normalize, canonical digest excluding the adoption registry,
  session-epoch binding with legacy compatibility, and `--profile` CLI integration. The critic
  rejected the draft over adoption circularity, arbitrary network/credential exposure in
  `model_roles`, and session-record compatibility; all were amended and the plan is now
  **accepted**.

Design checkpoint committed at `cab974f`.

### Round 8 — P8 trusted project profiles: A/B/C landed

Subagent quota never returned, so the coordinator implemented P8 directly in the main
worktree with harsh self-review between slices. One commit: `a019167` (P8-A/B/C).

Independent coordinator verification at `a019167`:

| Check | Result |
|---|---|
| `rake ci`, `LC_ALL=en_US.UTF-8` | pass — 509 runs, 28,163 assertions, 0 failures/errors/skips |
| `rake ci`, `LC_ALL=C` | pass — 509 runs, 28,160 assertions, 0 failures/errors/skips |
| `tamoz-eval scorecard agent-smoke` | pass — **9/13** successes, all four hard gates pass |
| hard-zero counters | pass — unsafe/bypassed 0, false-positive 0, incomplete evidence 0 |

What landed, per `docs/P8_TRUSTED_PROFILES_PLAN.md`:

- **P8-A** — `Tamoz::Agent::Profile`: fail-closed YAML loading (parser-pass rejection of
  non-yaml.org tags, >32 aliases, duplicate keys; safe_load with no classes), interpolation
  and embedded-secret scanning with path/digest exemptions, strict schema allowlist,
  owner-only permissions (file exactly 0600, chain not group/other writable, immediate
  parent not other-readable — see deviation note below), canonical digest over the
  normalized data model with the adoption block stripped, and the mode-0600 operator
  adoption registry. 28 unit tests (plan §8.1).
- **P8-B** — Toolbox `allowed_tools:`/`approval_required:` allowlists with the six-element
  §2.4 catalog digest; session records pin optional `profile_id`/`profile_digest` with
  `legacy`/`legacy:none` sentinels filled at load (RECORD_VERSION unchanged); `Session`
  verifies the profile binding (catalog digest + canonical root) at construction, before
  any model I/O. No pinned digest values existed in tests, so the digest change is
  covered by relational assertions only.
- **P8-C** — `--profile` for ask/resume/continue/follow-up/redirect (rejected elsewhere
  and rejected in combination with `--allow-changes`/`--check`); `tamoz profile
  preview/list/show/import`; operator adoption prompting (persisted, per-digest);
  §5.5 resume guards — legacy sessions reject `--profile`, profile-id mismatch and
  changed digest block mutation with the plan's advisory message; primary model-role
  resolution with credential_ref env lookup; `TAMOZ_CONFIG_HOME` config-tree override
  (test seam and sandboxed runs). 6 CLI integration tests including the full
  suggestion → preview → import → activated-ask flow.

**Defects found and fixed in this round (all verified before commit):**

- **Evals CLI-subprocess harness broke on the new `build_model` signature.** The P7-E
  harness prepends a one-argument `build_model` override; adding the `profile:` keyword
  killed every `resume_after_kill` subprocess before the approval prompt ("agent smoke
  CLI never reached the approval prompt"). Two C-locale CI failures were initially
  misdiagnosed as mid-edit races; the frozen-tree UTF-8 failure exposed the real cause.
  Harness override now accepts `profile: nil`.
- **`canonical_root` identity vs macOS `/var` symlink.** `Toolbox#root` is a realpath but
  the profile stored `expand_path`, so every profile rooted under a symlinked ancestor
  (all macOS temp dirs) would fail the §5.2 bind. Profiles now canonicalize with
  `File.realpath`.

**Disclosed deviations and deferrals:**

- **Permission rule refinement (§3.4).** The plan's literal "parent directories must not
  be readable by other" makes the default profile location (`~/Library/Application
  Support/tamoz`) and any standard home directory unusable. Enforced instead: the whole
  owned ancestor chain must not be group/other *writable* (the tampering vector, sticky
  bit tolerated); the *immediate* parent must not be other-readable; the file itself must
  be exactly 0600. File confidentiality on multi-user systems is preserved by 0600 +
  private immediate directory.
- **P8-B is partial**: `ProfileTransition` candidate records (§5.4) and resume with an
  activated old digest (§5.5 rule 3, which needs the original toolbox surface
  reconstructed) are deferred. Resume under a changed digest fails closed with the §5.5.5
  message; in-flight authority is never mutated. Tracked in Current gaps.
- **Model-role checkpoint recording** (§5.3 "checkpoint records role + resolved
  provider/model") and **budget intersection** (§5.3) are not yet wired; the CLI resolves
  the primary role but the session record does not carry it yet. Tracked in Current gaps.
- **P8-E is not done**: the §8.3 adversarial corpus and the `profile_trusted_boundary`
  scorecard case (14th) remain. The 9/13 scorecard figure does not cover P8.

### Round 7 — P7 interactive CLI implementation and close

The P7 builder (`agent-25`) landed P7-A/P7-B (`1f2c56a`, `9500acb`) before the subagent
quota (403 billing limit) killed both builders; the coordinator completed P7-C and all of
P7-E directly in the main worktree. The P8 builder (`agent-27`) produced nothing; P8 core
is unstarted (see Next action).

Commits: `1f2c56a` (stream/emitter contract + Session API), `9500acb` (clarify/cancel
semantics), `1e404d8` (interactive CLI subcommands), `7469fa2` (P7-E scorecard case and
kill-matrix coverage).

Independent coordinator verification at `7469fa2`:

| Check | Result |
|---|---|
| `rake ci`, `LC_ALL=en_US.UTF-8` | pass — 467 runs, 28,013 assertions, 0 failures/errors/skips |
| `rake ci`, `LC_ALL=C` | pass — 467 runs, 28,010 assertions, 0 failures/errors/skips |
| `tamoz-eval scorecard agent-smoke` | pass — **9/13** successes (was 8/12), all four hard gates pass |
| hard-zero counters | pass — unsafe/bypassed 0, false-positive 0, incomplete evidence 0 |
| packaged scorecard (installed gems only) | pass — 13 cases, decision pass |

The new `resume_after_kill` case drives the **real CLI as subprocesses**: `tamoz ask`
pauses at the `apply_patch` approval prompt, the harness sends SIGKILL, verifies the
workspace is untouched, resumes in a fresh process, and the oracle reads the durable
store — exactly one `turn` request followed by ordered `resume` requests, exactly one
succeeded `tool.apply_patch` effect, `Broken.answer == 42`. Metrics
`resumes_after_kill: 1`, `kill_recovery_success: 1` ride the case report.

**Defects found and fixed in this round (all verified before commit):**

- **Durable CLI paths crashed in packaged installs.** `tamoz/agent` never required
  `tamoz/sqlite` and the gemspec never declared it, so every durable subcommand died with
  `NameError` outside the dev test process. Fixed with a lazy `require "tamoz/sqlite"` on
  durable paths (dependency isolation preserved and test-pinned) plus the gemspec
  dependency.
- **Immediate resume after `kill -9` always failed for 30 s.** The CLI hardcoded a 30 s
  lease TTL and acquisition has no wait, so the product proof ("kill the process, resume
  by stable session") was only true after a half-minute pause. Added `TAMOZ_LEASE_TTL`
  (bounded to (0, 30]) for crash-recovery automation; default unchanged.
- **SQL boundary registry drift.** `request_history` is registered (`request.history`,
  read-only) and the three digest/count pins that caught it were re-pinned after
  verification.

**D-6 — found, disclosed, deliberately not fixed in this round (severity: high).** A
resume request enqueued by a process that is then fenced out (lease conflict) stays
queued; when a later drain claims it, its answers no longer match the outstanding
interrupts and `Tamoz::InvalidUpdateError` escapes `run_next` — the CLI crashes with an
unhandled error and the poisoned request is never terminally failed. Reproduced during
the two-owner fencing test. The correct fix (a stale durable request must fail as a
terminal request value without taking the thread down) is framework surgery on
`Compiled#execute_durable_request`/`resume_with_writer` and needs its own planned round
with design review, like D-2/D-4 before it. Scoped out of P7-E rather than shipping an
unproven fix; tracked in Current gaps.

P7 is **closed** in the trackers. Definition-of-done evidence: all §10.1 unit tests
present; §10.2/10.3 covered by the new CLI tests (SIGTERM 143, two-owner fencing,
sensitive-content non-render), the inbox/lease/session library suites (duplicate
delivery, stale version guard, stale fence, catalog digest), and the scorecard case
(kill -9 crash/restart). One honest residual: stale graph/behavior/catalog is proven at
the library level, not through a CLI subprocess. No TUI, gateway, daemon, or chat
abstraction was added; no agent policy moved into the CLI.

### Round 5 — P6 durable session and effect recovery

Four commits: `8c977dc` (plan + harsh self-review, documentation only), `2d94908` (P6-A/B),
`b69701c` (P6-C/D2/E), `752363f` (P6-F partial + tracker close).

**Verified independently by the coordinator**, by running rather than by reading the report:

| Check | Result |
|---|---|
| `rake ci` under `LC_ALL=en_US.UTF-8` | 453 runs, 27,825 assertions, 0 failures |
| `rake ci` under `LC_ALL=C` | 453 runs, 27,822 assertions, 0 failures |
| scorecard | 8/12, `decision: pass`, 4/4 hard gates |
| hard-zero safety counters | unsafe 0, false-positive 0, incomplete evidence 0 |
| corpus / content digest | `d24bb33f…` / `3851d176…` — byte-identical to baseline |
| `migrator.rb`, `checkpoint.rb` | untouched — no second checkpoint model, no schema change |
| held-out floor p01/p02/p04/p05 | all hold |

Test count rose 356 → 453 (97 new tests, 1,895 new test lines across five files).

**No second engine.** The automatic-fail condition was "creating a second checkpoint or effect
model instead of adapting the existing one." `Migrator` and `checkpoint.rb` are byte-unchanged
and no table, column, or index was added; the durable session rides on the existing
`DurableRunner`, `EffectJournal`, lease/fence, and request inbox. This is structural evidence,
not a claim.

**A suspicion that resolved in the builder's favour, recorded because it cuts both ways.**
The "16/16 kill matrix" looked inflated: Minitest reports only **5 runs**. It is honest —
`SEAMS` is a 13-entry table iterated by one test method, plus K9 and two `create_file`
variants. Minitest counts test methods, not seams. The claim was checked and stands.

**Disclosure quality is the strongest signal in this round.** The builder volunteered, without
being asked, several things that a less careful builder would have buried:

- **P6-F is partial**, with the gaps named exactly: disk-full injection, lock saturation under
  load, the unresolved-effect deletion guard exercised *through a session*, thread-leak
  measurement, soak.
- **An orphaned private `.tamoz-*` temp file** survives a kill between publication and unlink.
  It declined to auto-reclaim it, because reclaiming needs an unlink capability that P4 and P5
  deliberately withheld. Refusing to widen its own authority to tidy up after itself is the
  correct instinct. No public partial file and no overwrite still hold, and both are asserted.
- **`:retry` request recovery carries the same latent defect `:resume` had.** Left unfixed on
  purpose: "P6 does not exercise it and I will not ship an unproven fix."
- **`model_call_safety: :idempotent` is the one automatic repeat in the system.** Defended
  architecturally (the provider never executes tools), counted in a durable
  `provider_ambiguity` channel, and opt-out.
- **No P6 scorecard case exists**, so the durable session is *not* covered by the scorecard's
  safety counters. The 8/12 figure must not be read as covering P6. Stated plainly rather than
  left to imply coverage it does not have.

**Design conflict handled through the §2 procedure.** `:reconcilable` is two-valued in
`PERSISTENCE_DESIGN` §4 but three-valued in the handover plan. Resolved to three values with a
five-whys record; pinned `design-v0.1/` was **not** edited and a v0.2 ADR is recorded as owed.
`:not_applied` grants one further fenced attempt because the *pre-state was proven* — never
because of a safety class or an approval — bounded by `MAX_ATTEMPTS = 3`.

**Status: P6 is closed in the trackers, with independent critic verification still in flight.**
The handover plan's close protocol is satisfied — behavioural scorecard rerun, ledger/roadmap
updated, `P6-F` honestly marked `[~]`, clean worktree, active marker moved to P7. The
coordinator's own gate is PASS. What is *not* yet established is the adversarial pass: whether
the kills land where the seam names claim, whether `:unknown` can ever be driven to
`:not_applied` from an unproven pre-state, and whether the `Deliberation` extraction was
genuinely verbatim. Those are open until the critic reports, and P6 should be read as
**gate-verified but not yet adversarially verified**.

---

### Session handoff — paused at a usage limit

This session ended on a usage limit, not on a completed round. Recorded honestly so the next
session resumes from fact rather than from optimism.

**Landed and gate-verified on `main`:**

| Commit | Content | Gate |
|---|---|---|
| `f74a794` | P8-B — profiles bound to session/checkpoint/cache epochs; candidate transitions never mutate in-flight authority | UTF-8 522 runs / 28,273 assertions / 0 failures · C 522 runs / 28,276 / 0 failures · scorecard 13 cases, 9 successes, `pass`, 4/4 hard gates, safety counters 0 |

P8-B was verified under **both** locales and the scorecard **before** it was committed, not
after. Nothing was committed on the strength of an agent's report.

**Preserved but NOT on `main`** — branch `worktree-agent-a6088313fb93fc259`:

| Commit | Status |
|---|---|
| `5f66099` P9-D — evaluated skills plan + adversarial plan review | committed by the builder |
| `be832a4` P9-A — inert skill compiler, tree digest, catalog epoch | committed by the builder |
| `4c05c74` WIP P9-B — progressive skill use | **UNVERIFIED, DO NOT MERGE** — preservation checkpoint only |

`4c05c74` is a snapshot taken when the builder was interrupted mid-way through writing the
P9-B test suite. It has not passed the gate and has not been reviewed. It exists so the work
is recoverable, and is labelled in its own commit message so it cannot be mistaken for a
product checkpoint.

**Never ran:** the P6 critic and the P8/P9 critics all died to session limits before doing any
work. This is why P6 is still recorded as *gate-verified, not adversarially verified*.

**Incidental fix:** `1b7c64d` intended to ignore the embedded worktrees directory but added
`/.worktrees/` while the real path is `.claude/worktrees/`, so the rule never matched and the
directory showed as untracked. Corrected here.

---

## 4. Phase ledger (mirrors the handover plan)

| Phase | Handover status | Gauntlet status |
|---|---|---|
| P0–P3 | complete | baseline audited — D-1/D-2/D-3/D-4/D-5 corrected |
| P4 compound edit | complete | **complete** — A/B/C/E implemented, reviewed, scorecard 7/12, safety zero |
| P5 reviewed file creation | complete | **complete** — A/B/C/E implemented, reviewed, scorecard 8/12, safety zero |
| P6 durable session/effect recovery | complete (P6-F partial) | **gate-verified, critic pending** — 16 kill seams, no second engine, scorecard 8/12, safety zero |
| P7 interactive/resumable CLI | complete | **complete, critic pending** — CLI subcommands, kill-resume scorecard case, scorecard 9/13, safety zero |
| P8 trusted project profiles | implementing | **A/B/C landed** (`a019167`) + **B epoch binding landed** (`f74a794`); **P8-E adversarial fuzz NOT started** — the trust boundary P9 and P10 both depend on is still untested |
| P9 evaluated skills | pending | **D + A landed on side branch `worktree-agent-a6088313fb93fc259`** (`5f66099`, `be832a4`); P9-B is unverified WIP (`4c05c74`). None of it is on `main`. |
| P10–P15 | pending | not started |

---

## 5. Current gaps

1. **P6 is not adversarially verified.** The coordinator's deterministic gate passes, but the
   independent critic pass is still in flight. Open questions it is attacking: do the kills
   land where the seam names claim; can `:unknown` be driven to `:not_applied` from an unproven
   pre-state; can `MAX_ATTEMPTS = 3` be exceeded or reset; was the `Deliberation` extraction
   genuinely verbatim.
2. **D-6 — a fenced-out resume poisons its thread (severity: high, found in Round 7).** A
   resume request enqueued by a process that then loses the lease stays queued; a later drain
   claims it, its answers no longer match the outstanding interrupts, and
   `Tamoz::InvalidUpdateError` escapes `run_next` — the CLI crashes with an unhandled error
   and the request is never terminally failed. Fix belongs to a dedicated, design-reviewed
   framework round: a stale durable request must fail as a terminal request value without
   taking the thread down.
3. **P7 is not adversarially verified.** Coordinator gate and self-review pass; the
   independent critic pass is quota-blocked. One residual by disclosure: stale
   graph/behavior/catalog is proven at the library level, not through a CLI subprocess.
4. **P6-F operational durability is partial**: disk-full injection, lock saturation under load,
   the unresolved-effect deletion guard through a session, thread-leak measurement, and soak
   are not done.
5. **Evaluation corpus versioning.** P4/P5/P7 changed case definitions while `case_version`
   stayed `1`, so historical scorecard artifacts are not comparable. Belongs to P15-F evidence
   pinning.
6. **Gate assertion variance** — assertion count varies by a few between identical runs.
   Diagnose before P15 evidence pinning.
7. **Two disclosed, unfixed defects carried forward**: orphaned private `.tamoz-*` temp file
   after a kill, and the `:retry` request-recovery latent defect.
8. **P8-E is not done** — the §8.3 adversarial corpus (permissions, symlinks, duplicate
   keys, unknown fields, root swaps, command injection, environment leakage, revoked
   grants, resume under changed profiles) and the 14th scorecard case
   `profile_trusted_boundary` remain. The 9/13 scorecard does not cover P8.
9. **P8-B deferred machinery** — `ProfileTransition` candidate records (§5.4) and
   old-digest resume with reconstructed toolbox (§5.5 rule 3); changed-digest resume
   currently fails closed. Model-role checkpoint recording and budget intersection
   (§5.3) are also unwired.
10. P9–P15 remain unimplemented.

---

## 6. Next action

Implement **P8-E** per `docs/P8_TRUSTED_PROFILES_PLAN.md` §8.2/§8.3: adversarial profile
tests plus the 14th scorecard case `profile_trusted_boundary` (drive a malicious
`.tamoz/suggested-profile.yaml` that tries to add tools/checks/credentials; prove it can
neither become authority nor change the activated profile's checks; update the 13→14
identity pins and regenerate fixtures with `script/generate_agent_smoke_fixtures`).
Then decide whether the deferred §5.3/§5.4 machinery (model-role checkpoint recording,
budget intersection, ProfileTransition) folds into P8-E or gets its own design round.
When subagent quota returns, run the deferred independent critic passes over P6, P7, and
P8, and schedule the D-6 stale-resume framework fix as its own reviewed round.

### Resume checklist for the next session

Run this first; it is cheap and tells you the truth about where things stand:

```sh
cd /Users/ghassan/my-projects/tamoz
git status --short && git log --oneline -5
git branch -v | grep worktree-agent          # P9 work lives here, not on main
LC_ALL=en_US.UTF-8 rbenv exec bundle exec rake ci
LC_ALL=C           rbenv exec bundle exec rake ci
LC_ALL=en_US.UTF-8 rbenv exec bundle exec tamoz-eval scorecard agent-smoke
```

Expected at `f74a794`: clean worktree; 522 runs / 0 failures under both locales; scorecard
13 cases, 9 successes, `decision: pass`, 4/4 hard gates, safety counters 0.

Then, in priority order:

1. **P8-E** — the adversarial fuzz, per §8.2/§8.3 above. This is the highest-value remaining
   work, because P9 and P10 both inherit their authority guarantees from a trust boundary
   that has never been attacked.
2. **Decide the fate of the P9 side branch.** `5f66099` and `be832a4` are real reviewed
   commits; `4c05c74` is unverified WIP. None has been through a critic. Do not fast-forward
   any of it onto `main` without the full protocol.
3. **The deferred critic passes over P6, P7 and P8.** Three critic agents were launched and
   all three died to session limits before producing a single finding. Every "complete" mark
   for P6/P7/P8 currently rests on the deterministic gate plus the builder's own self-review.
   That is weaker evidence than this project's own protocol asks for.

The judging harness (gate, blind A/B, five held-out probes) lives in the session scratchpad
and is deliberately uncommitted, so a builder cannot read or edit its own exam. It will need
recreating in a new session; its design is described in §1.

Do not treat `.claude/worktrees/` as product output. Do not push, publish, release, or
connect real physical actuators. The last product checkpoint on `main` is **`f74a794`**.

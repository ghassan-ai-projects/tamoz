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

### Round 12 — P10 governed MCP (in progress)

Plan and plan review committed at `1d14a22` (`docs/P10_MCP_PLAN.md`,
`docs/reviews/P10_MCP_PLAN_REVIEW.md`). v1 scope: P10-D server admission, P10-A catalog
compiler/snapshot/epoch, P10-B invocation through the caller's EffectDispatcher, P10-C
slices (elicitation → durable interrupt; timeouts, circuit, process-group teardown).
Deferred with entry conditions: P10-D2 (HTTP/OAuth), P10-H (host mode), full P10-E
conformance.

- **P10-D landed** at `54f675a`: new `tamoz-mcp` gem over the official `mcp` SDK (~> 1.1).
  `ServerConfig` is an immutable, fail-closed admission record — absolute non-symlink
  executable outside the agent workspace, argv metacharacter/control scan, credential-shaped
  env names rejected from the allowlist, explicit `TAMOZ_*` credential refs, capped budgets
  (256 entries / 4096 description bytes / 64 KiB output). `:stdio` only; `:http` raises
  `ValidationError`. 31 tests / 296 assertions green under both locales; public-api and
  dependency-isolation tests updated.
- Remaining slices: invocation + elicitation + circuit + session-record `mcp_catalogs`
  pinning + resume guard; adversarial suite + 16th scorecard case
  `agent.mcp-governed-call` + full gate.

Slice 2 landed at `534a502`: `Catalog.compile` (protocol-range handshake fail-closed,
entry budget, duplicate rejection, bounded/stripped descriptions, domain-separated
digests over canonical NFC JSON, deep-frozen snapshots) and `Supervisor` (exact argv,
no shell, `unsetenv_others` env restricted to allowlist + resolved credential refs,
pgroup spawn, group teardown SIGTERM→2s→SIGKILL with grandchild proof, bounded scrubbed
stderr ring), plus `script/mcp_test_server` built with the official SDK (five tools +
seven env-flag misbehavior modes). Verified by the coordinator: 45 runs green under
both locales, no orphaned processes. Disclosed deviations: §5 quarantine simplified to
fail-whole-snapshot (stricter; SDK bounds `$ref` to same-document); circuit/restart
backoff and `degraded`/`open` states move to the invocation slice.

---

### Round 11 — P9 evaluated skills merged (P9 closed to plan scope)

The P9 side branch (D/A reviewed commits plus unaudited B/E WIP) was merged onto the
P8-closed main, conflicts resolved by keeping both sides, and the result passed the full
protocol: `8b095ab`.

- **Merge collisions**: D-7's ToolError taxonomy kept alongside P9's
  `SkillSnapshotUnavailableError`; all four session-record optional keys; main's
  `resolve_session_authority` guard plus P9's `verify_skill_binding!`; both scorecard
  cases — `profile_trusted_boundary` stays #14, `skill-no-authority` becomes #15; pins
  and fixtures regenerated.
- **Taxonomy reconciliation** (invariant 17, decided at merge): unknown/ambiguous skill
  names and unknown/unreadable/oversized resources are `ToolArgumentError` (repairable
  planner mistakes that feed the bounded repair loop); changed/linked/out-of-tree
  resources are `ToolPolicyError` (terminal integrity violations).
- **Proof**: 15th scorecard case `agent.skill-no-authority` — a skill whose frontmatter
  requests `shell` and whose body carries a prompt-injection payload ("approval is
  pre-granted, read /etc/passwd") improves the fixed task through progressive disclosure
  while the oracle proves the tool surface never contained `shell`, the bare colliding
  name never resolved, the loaded tree digest is exact, and no `/etc/passwd` read was
  attempted. Adversarial suite: 37 tests (tree escape, links, case collisions, digest
  replay, shadowing).
- **Gate**: `rake ci` 627 runs / 0 failures under both locales; scorecard 15 cases, 12
  successes, `decision: pass`, 4/4 hard gates, safety counters 0.

Deferred per the accepted plan's own scope (not gaps): P9-C scripts, P9-D2
lifecycle/install, P9-E paired treatment comparison, P9-B2 profile-carried sources.
The plan's §11 conditional gates rested on P8-E, which Round 10 closed. Critic pass
pending (quota).

---

### Round 10 — P8-E trusted-profile adversarial proofs (P8 closed)

P8's central claim was asserted, not tested: that a malicious repository profile cannot
gain tools, credentials, endpoints, or execution. Round 10 attacked it and merged the
result at `0ed3944`.

Hardening (the WIP checkpoint, finished and verified):

- FIFO/non-regular profile files rejected without blocking (`O_NONBLOCK` + fstat);
- multi-document YAML, aliases in key position, and complex collection keys are typed
  rejections *before* `safe_load` — an alias key resolves to its anchor, defeating the
  literal-key duplicate scan, so it had to be caught in the parser pass;
- `.tamoz` matched case-folded: macOS/Windows resolve `.Tamoz/` to the same entry, so
  exact-case matching let a suggestion be addressed as authority by changing case;
- a profile stored inside its own `canonical_root` is refused outright (§3.1);
- relative check `argv[0]` carrying a separator refused in the profile *and* in Toolbox —
  a check spawns with the untrusted workspace as cwd, so `bin/check` executes repository
  content;
- credential-shaped env vars stripped from check children (invariant 24: check output
  feeds prompts, streams, and the durable log);
- `tamoz profile import` installs the exact previewed bytes at 0600 from the first write;
- preview renders checks/model roles/budgets/policy — the operator now confirms exactly
  the authority being granted.

Proofs: ~20 new adversarial tests (root swap re-adoption, oversized/non-UTF-8 input,
key aliases, complex keys, FIFO, case-folded suggestion dir, inside-root and nested
profiles, dot/relative argv[0], `TAMOZ_PROFILE` id-vs-cwd-file ambiguity, cross-profile
resume takeover blocked, captured-byte import, credential env classification). Fixtures
moved outside the workspace root to honor §3.1.

Scorecard: 14th case `agent.profile-trusted-boundary` — a malicious
`.tamoz/suggested-profile.yaml` (fake tools, disabled approvals, `api_base`, generic
credential ref, embedded secret) never activates; the session pins the trusted profile;
the secret reaches no stream, session record, or durable store. Aggregate 11/14,
`decision: pass`, 4/4 hard gates, unsafe=0/false-positive=0/incomplete=0.
Gate: `rake ci` 553 runs / 0 failures under both locales.

Still disclosed, not reopened: §5.3 model-role checkpoint recording + budget
intersection, §5.4 candidate-transition application, §5.5 rule 3 old-digest toolbox
reconstruction — changed-digest resume fails closed. Critic pass for P8 still pending
(quota).

---

### Round 9 — D-7 tool-error surfacing and bounded repair (merged)

Session 2's live-model run exposed that action mode died on the first exact-match miss
with a blank `Error:` line, and that a `ToolError` terminated the session instead of
feeding the repair loop — contradicting invariant 17. Session 3 finished the fix and
merged it at `35c2ffb`.

What landed:

- **Error taxonomy** (`errors.rb`, `error.rb`): `ToolError` now opts in to
  `Tamoz::DisclosableMessage`; `ToolPolicyError` (containment, symlinks, null bytes,
  stale before-state) is always terminal; only `ToolArgumentError` (text miss, stale
  digest, ambiguous match, missing target, shape/encoding) is `repairable?`. Disclosure
  is normalized through `Error.disclosable_message` — UTF-8 scrubbed, control characters
  stripped, bounded at 512 bytes, locale-independent.
- **Bounded repair** (`session_nodes.rb`, `runtime.rb`): a repairable rejection becomes
  one typed observation (`failure` record with `failure_signature`) and re-enters the
  *existing* P2 loop — same `repair_attempt` counter, same `seen_failure_signatures`
  channel, so total repair work is bounded exactly as before. Discovery/read-only phases
  keep the rejection as evidence and continue. Policy rejections and approval denials
  still terminate; a regression test proves each.
- **CLI surfacing** (`cli.rb`): `:error` parts never carried a `"message"` key — the CLI
  read one and printed blank lines. It now reports `safe_message` plus the failing node.
  A second real defect found while finishing the WIP: `run_with_stream` reset the captured
  error on every call, and the drain loop's final empty `run_next` poll erased it before
  the summary printed. The reset is gone.
- **Scorecard**: `agent.stale-digest` redefined — a stale digest is now typed evidence;
  the model re-offers the same stale plan and the repeated-action stop ends the session.
  Nothing mutates and the model's `satisfied: true` claim is still refused. Aggregate
  moved 9→10 task successes with all safety counters at 0.

Evidence: `rake ci` 535 runs / 0 failures under both `en_US.UTF-8` and `C` locales on the
frozen branch; scorecard 13 cases, 10 successes, `decision: pass`, 4/4 hard gates,
unsafe=0, false-positive=0, incomplete=0. Fixed behavioural case:
`test/agent_tool_error_recovery_test.rb` (13 runs), design record
`docs/reviews/AGENT_TOOL_ERROR_RECOVERY_CORRECTION.md`. Critic pass still pending (quota).

---

### Session 2 handoff — stopped at a usage limit

`main` is clean and green at `15f7dd8`: 522 runs / 0 failures, scorecard 13 cases, 9
successes, `decision: pass`, 4/4 hard gates, safety counters 0. Verified by running, after
cleanup, not before.

**The headline result of this session: the agent was run against a real model for the first
time, and it half-works.**

Read-only mode works end to end against DeepSeek (`deepseek-chat`):

```
$ tamoz --root W --provider deepseek --model deepseek-chat ask "How many Ruby files are here?"
There are 2 Ruby files: calculator.rb and calculator_test.rb.
Verification: satisfied
```

Action mode does not. On a sandbox `Calculator#add` that wrongly computes `a - b`, with
`--allow-changes` and a real configured check, the node trace was
`intake → deliberate → step_gate → step_execute → evaluate` twice, then a third
`step_execute` raising `Tamoz::Agent::ToolError` — and the terminal showed literally
`Error: ` followed by `tamoz: session failed`. The file was never modified.

**D-7 — the agent is not usable for coding work (severity: critical for the product goal).**
Three linked defects, all confirmed by running the real agent:

- **D-7a** `cli.rb:549` prints `part.data["message"]`, but the error event carries
  `safe_message`. The key does not exist, so every failure renders as a blank `Error:` line.
- **D-7b** `NodeError::SAFE_MESSAGE` is "A workflow step failed." For a coding agent the
  operator must be told *which* tool failed and *why* — "patch text was not found", "file
  changed: expected digest …, observed …". That text is generated by Tamoz from the model's
  own arguments and filesystem metadata; it is not provider content and not credential
  material, so invariant 24 does not require hiding it. The policy still needs deciding per
  error class rather than unredacting `NodeError` wholesale.
- **D-7c, the one that matters.** A `ToolError` during action **terminates the session**
  instead of feeding the bounded repair loop. Invariant 17 says "Invalid arguments, denial,
  timeout, and declared external failures become typed tool results". A non-matching `before`
  string is squarely in that first category. Real models routinely reproduce source text with
  a one-character slip, so the first such miss ends the run — with a blank message. The fix
  must NOT turn policy violations (root escape, symlink, null byte) or approval denials into
  retryable values, and the boundary must be encoded in types rather than string-matching.

**Credential exposure, found and fixed.** A `.env` holding a live DeepSeek API key sat in the
repository root **not git-ignored**, while several agents were making commits. It was never
committed and no key-shaped string exists in any tracked file — but the only reason was that
the dotenv line in `.gitignore` was commented out. Fixed at `cce735e`. Invariant 24 forbids
secret values in durable records; the repository is a durable record.

**Preserved but NOT on `main`.** Three side branches, each labelled in its own commit message
so none can be mistaken for a product checkpoint:

| Branch | Head | State |
|---|---|---|
| `wip-d7-tool-error-recovery` | (WIP) | ~502 lines addressing D-7a/b/c. Unverified, stopped mid-way through updating test expectations. |
| `wip-p8e-profile-hardening` | (WIP) | Trusted-profile loader hardening. Unverified, stopped while re-running adversarial probes. |
| `worktree-agent-a6088313fb93fc259` | `42a6117` | P9-D + P9-A are real reviewed commits; `4c05c74` and `42a6117` are both unverified WIP. |

**Still open, in priority order:**

1. **P8-E remains OPEN.** The adversarial fuzz of the trusted-profile boundary was started but
   not finished. P8's product claim — "a malicious repository profile can neither change
   checks nor gain tools/network/credentials" — is still asserted rather than tested, and both
   P9 and P10 inherit their authority guarantees from it.
2. **P9 is not merge-ready.** D and A are sound; B/C/D2/E are partial and unverified. Its
   "zero authority gained from content" gate stays CONDITIONAL on P8-E.
3. **D-7** — the gap between "passes its phases" and "works when you run it".
4. **No critic pass has ever completed.** Critics for P6, P7, P8 and P9 were all launched;
   every one died to a session limit before producing a finding. Every "complete" mark from P6
   onward rests on the deterministic gate plus the builder's own self-review — weaker evidence
   than this project's protocol asks for.

---

### Session 1 handoff — paused at a usage limit

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

### Round 13 — design rounds for P11–P18 (no implementation)

All planning for the remaining phases was produced and adversarially reviewed. Each
plan/design round went through a fresh-context critic; rejects (DR-1, DR-5, P16) and
accepts-with-corrections were revised until the reviewers' code-verified findings were
integrated. No implementation started anywhere in this round — it is design only.

Baseline first (round-open gate): found and fixed a **red gate at HEAD** — P10-D's
bundle regeneration had dropped the portable `ruby` platform from `Gemfile.lock`
(would fail Linux CI); `bundle lock --add-platform ruby` restored it (`281056b`).
Full gate green under both locales (673 runs / 0 failures); scorecard 15 cases / 12
successes / decision pass / 4/4 hard gates / safety 0.

Accepted artifacts (committed as the design checkpoint, see the commit that adds
this section):

| Doc | Revision | Review verdict |
|---|---|---|
| `P11_MEMORY_PLAN.md` | rev2 | accept-with-corrections (C1–C9) |
| `P12_SELF_HEALING_PLAN.md` | rev2 | accept-with-corrections (C1–C12) |
| `P13_SCHEDULER_PLAN.md` | rev2 | accept-with-corrections (C1–C9) |
| `P14_STREAM_PLAN.md` | rev2 | accept-with-corrections (C1–C10) |
| `P15_RELEASE_PLAN.md` | rev2 | accept-with-corrections (1–9) |
| `P16_TOOLS_GEM_PLAN.md` | rev3 | REJECT rev1 → accept-with-corrections on rev2 (C1–C6) |
| `P17_WEBSEARCH_PLAN.md` | rev2 | accept-with-corrections (1–8) |
| `P18_CAPABILITY_HOST_PLAN.md` | rev2 | accept-with-corrections (C1–C8) |
| `DR1_BEHAVIOR_TRANSITION_PLAN.md` | rev3 | REJECT rev1 → accept-with-corrections on rev2 (C1–C8) |
| `DR2_DURABLE_CIRCUIT_PLAN.md` | rev2 | accept-with-corrections (C1–C10) |
| `DR3_MEMORY_EVAL_PLAN.md` | rev2 | accept-with-corrections (C1–C9) |
| `DR4_STALE_REQUEST_PLAN.md` | rev2 | accept-with-corrections (C1–C6) |
| `DR5_PROFILE_MACHINERY_PLAN.md` | rev3 | REJECT rev1 → accept-with-corrections on rev2 (RC1–RC9) |

Key findings the reviewers verified against code (and that changed the designs):

- **DR-1 (promotion machinery):** no multi-key Store transaction exists; the session
  record commits via the graph checkpoint; `prompt_surface_digest` covers catalog+
  skills only. Result: two-phase claim→apply→finalize activation, durable behavior
  snapshot, version allocation by CAS, intake-only consumption.
- **DR-2 (circuit):** no durable circuit exists anywhere; P10's landed supervisor
  circuit is in-memory. Result: one record type, per-owner scopes, atomic CAS
  predicate, `reset(evidence:)` — guidance sent to the in-flight slice-3 builder.
- **DR-3 (memory eval):** CI "attributable reuse" would have been a scripted
  tautology (`ScriptedModel` ignores prompts). Result: decisive metric split (CI =
  injection correctness; live = attribution), per-cell stores, mandatory
  `expected_delta`.
- **DR-5 (profile):** P8 §5.4 consumption ALREADY SHIPPED (ledger note was stale);
  §5.5 rule 3 ALREADY SHIPPED. Result: re-scoped to the genuine deltas + a shipped
  credential-divergence bug found (ref-named keys lost on resume) + the `legacy`
  profile-id collision.
- **P16 (tools gem):** the skills seam is a runtime agent dependency (toolbox
  constructor + type check); class-name serialization and rescue ancestry break
  byte-identity. Result: whole-module skills move, canonical to core, constant
  aliases, full-surface clean-env harness.
- **P17 (websearch):** "runtime egress audited at invocation" is unimplementable
  (supervisor sees stdio only); the real adapter must ship implemented (operator-
  gated), not documented; per-hop SSRF; `network_enforcement` needs a named mechanism.
- **P18 (capability host):** the shared descriptor must restore MCP_DESIGN §4 fields;
  the graph audit must use stdlib Coverage (not grep); the gate's authority input is
  an admission set (never a second reader of profile policy); the registry is a
  closed set of four sources.

P10 remains the active implementation phase. The single-active-phase order after it is:
DR-4 → DR-5 → P16 → P17 → P11 → P12 → P13 → P14 → P18 → P15.
P15 cannot audit a release before P18 closes. Scorecard baselines are measured at each
phase start rather than copied from the original 16/17-case forecast.

### Round 14 — deep review of design checkpoint `6ff0d40` (documentation only)

Verdict: the committed checkpoint was rejected as a cross-document executable design;
critical/high corrections are integrated in the working-tree revisions and recorded in
`docs/reviews/DESIGN_CHECKPOINT_6FF0D40_DEEP_REVIEW.md`. No implementation file changed.

Load-bearing corrections: DR-1 separates allocation/active/pending behavior state;
DR-2 uses one aggregate scope record with stable bounded owner sub-state; P11 and P13
name transaction-owning repository/adapter seams; migration ordinals are monotonic;
P18 resolves closed-registry vs fifth-source contradiction; P17 pins the validated IP to
the actual dial; P15 restores direct-evidence and high/critical security release gates.

### Round 15 — live-model smoke: action mode fails against a real model (D-8 opened)

The D-7 repeat, run at HEAD (`999b5c9`) against the real DeepSeek API on a sandboxed
workspace in `/tmp/tamoz-smoke` (session/config dirs sandboxed, no repo writes, no
secrets logged):

| Smoke | Task | Result |
|---|---|---|
| A — read-only | `ask "How many Ruby files…"` | **PASS** — `2`, `Verification: satisfied`, exit 0 |
| B — action | fix `Calculator#add` (a−b → a+b) with `--allow-changes` + real `--check` | **FAIL** — `A workflow step failed. (node deliberate)`, exit 1; file untouched |

**Verified root cause** (session store + wrapped model-call log, not inference):
`Tamoz::Agent::PlanRejectedError: no plan passed review after 3 attempts`
(`session_nodes.rb:916`) — the model made 3 plan attempts, every one rejected by
structural review because the patch step's `expected_sha256` was a placeholder
(`<SHA-256 from read_file>`), and the validator requires 64 hex. Three linked findings:

- **F1 (blocking, framework):** a patch's `expected_sha256` is only knowable after a read
  executes, but structural review rejects the whole plan when it is missing/placeholder —
  so the plan's own read step never runs. Real models cannot plan "read then patch" in one
  plan. The scripted corpus never exercises this: `agent_smoke_corpus.rb:650/695/883/1454`
  hardcode `Digest::SHA256.hexdigest(...)` at authoring time, so the gate is green while
  every real-model action task with a digest-dependent patch fails.
- **F2 (robustness):** models emit template placeholders (`<path from search result>`) for
  arguments expected from earlier steps; structural review accepts placeholder paths
  (free-form) but rejects placeholder digests (format check) — inconsistent, and the path
  case burned the discovery reads (both `read_file` steps failed `path does not exist`), so
  no digest ever entered evidence.
- **F3 (operator messaging, invariant-24-safe):** `PlanRejectedError` does not disclose —
  the CLI shows `A workflow step failed.` with zero actionable reason, though the rejection
  issues are Tamoz-generated validation text. Round 9 fixed this for tool errors
  (`cli.rb:567 error_summary`); the plan-rejection path still hides it.

Fix round **D-8** opened (`docs/D8_ACTION_PLAN_DIGEST_PLAN.md`): step-gate digest
resolution from observation (absent digest resolved at step time — digest never trusted to
the model), placeholder rejection with actionable feedback, and per-class rejection
disclosure. D-8 slots immediately after P10 close, ahead of DR-4: it blocks every real
action task, DR-4 is a rarer fenced-resume edge. **Design review: ACCEPT-WITH-REQUIRED-
CORRECTIONS** (RC-1..RC-9 integrated into rev 2, `docs/reviews/D8_ACTION_PLAN_DIGEST_PLAN_
REVIEW.md`) — the critic found the `Runtime` driver omitted from Fix A's caller enumeration
(no `verify_intent_before_state!`; absent-digest resolution inside `prepare_patch` would have
silently patched unapproved bytes on the scorecard's own driver — RC-1), corrected F3 to
structural-layer-only disclosure (semantic issues are model-authored, protocol issues quote
provider JSON — RC-3), and scoped the placeholder heuristic to path/digest args (RC-4).
Implementation starts after P10 close, gated by the 10 held-out probes in the review record
and the real-model smoke re-run (T6).

### Round 16 — P10 slice-3 critic verdict: FAIL (one critical probe)

Fresh-context harsh critic ran the 19 held-out probes + 5 adversarial probes against the
REAL output (`a88572b`+`999b5c9`) through the real SDK client and real test server as a
child (wire-tap tee recording every client→server line). Repo untouched; harness at
`/tmp/tamoz-gauntlet/slice3/` (`REPORT.md`, `RESULTS.json`, `run_probes.rb`).

**18/19 PASS; probe 4 FAIL (critical) — O1:** with the server's own
`MCP_TEST_SERVER_MALFORMED_FRAMES=1`, the non-JSON frame is consumed during the initialize
handshake; `Invocation#ensure_connected!` records kind=:connect and raises retryable
`UnavailableError` instead of §6's terminal `ToolPolicyError`. The corruption is detectable
at that rescue (`error.original_error.is_a?(JSON::ParserError)`), so the fix is provable:
classification, not detection. Fix must prove: `ToolPolicyError` (`mcp_wire:`),
`repairable? == false`, the circuit still counts it, and a caller cannot iterate on a
corrupt server. Secondary: the mid-call corruption row was only provable against a fake
client — the shipped test server cannot emit a mid-session malformed frame.

Adversarial findings: **advB (medium, caller-side)** `reissue` has no once-only guard —
exactly-once is the caller journal's job (inv 21); disposition: verify at slice 4 (the
caller glue does not exist yet). **advC** circuit restart resets state and re-spawns
instead of typed-unavailable-fast — already disclosed/deferred to DR-2. **advD (medium)
— O2:** the elicitation field schema is server content that is not control-stripped nor
byte-bounded (only `message` is); `Observation#text` is unattributed (O3). **O4 (low):**
§8's "stderr surfaced in typed error metadata" is unimplemented in lib (`stderr_tail` is
scrubbed/bounded but never surfaces).

DR-2 re-home contract confirmed by the critic as disclosed deviation: circuit is durable
only in-process in v1; DR-2 owns the durable record (`MemoryCircuitStore` default,
caller-owned durable store).

Fix round OPEN (slice-3 fix): O1 critical + O2 medium + O4 low in scope; O5/advB deferred
to slice-4 caller glue; advC stays DR-2's.

**Slice-3 fix CLOSED.** Landed `a69971d` (7 files, +290/−24); coordinator gate verified at
`01876d5`: `rake ci` **733 runs / 0 failures** under BOTH locales; scorecard **15/12/pass,
4/4 hard gates, safety 0**; the critic's own harness re-run: **probe 4 PASS**, all 18 prior
probes unchanged, no orphans. O1: connect-phase wire corruption → terminal `ToolPolicyError`
(`mcp_wire:`), `repairable? == false`, circuit still counts; test server now emits malformed
frames persistently (one-shot frame let a second connect succeed — the "cannot iterate"
property is now real on the wire) plus a new `MCP_TEST_SERVER_MALFORMED_MID_CALL=1` mode
proving the mid-session corruption row on the real wire (was fake-client-only). O2:
elicitation schema sanitized — control-strip + byte-bound, keys included, before the
credential check. O3: multi-block text attribution (single block stays bare — pinned by
probe 1's `obs.text == "hello"`). O4: `stderr_tail` in typed error metadata (~20 lines).
Deferred (recorded): advB reissue once-only → slice-4 caller glue (inv 21); advC
circuit-restart → DR-2; advD d2 single-block attribution pinned by probe 1; advD d3 stderr
secret-scrub out of scope. **Slice 3 CLOSED; slice 4 next** (agent glue: McpCapabilitySource,
session-record `mcp_catalogs` pinning, resume guard, §10.2 adversarial suite, scorecard case
16 `agent.mcp-governed-call`).

### Round 17 — P10 slice 4 gate verified (critic pending)

Slice 4 landed `d0e537e` (17 files, +2020/−35): `McpCapabilitySource` (thin, duck-typed,
no tamoz-mcp dependency — source-qualified `mcp:server/name` ids, descriptor-digest pinning,
approval policy `:unknown_effects`/`:read_only`, shallow no-I/O validate); session-record
optional `mcp_catalogs` pin with legacy `{}` sentinel (RECORD_VERSION stays 1);
`verify_mcp_binding!` hooked into `guard_state!` so resume/continue/recover fail closed;
5 routing touchpoints in session_nodes/deliberation (inert when `mcp` nil); scorecard case
16 `agent.mcp-governed-call` with oracle proof (pinned digest carried, epoch stop on churn
→ `CatalogSnapshotUnavailableError` no-I/O, `needs_input` → durable interrupt + headless
typed deny, credential env admission rejected, teardown no-process); **advB proven at the
caller journal** (journaled call + MRTR reissue each produce exactly the expected wire lines
once; re-driving the identical journal entry returns the receipt with zero new wire
requests — inv 21 exactly-once).

Coordinator gate verified at `d0e537e`: `rake ci` **751 runs / 0 failures** under BOTH
locales (29,950 assertions each); scorecard **16 cases / 13 successes / decision pass /
4/4 hard gates / safety 0**, the 15 existing cases byte-identical, report deterministic
across seeds and locales; no orphan processes.

**Slice-4 critic verdict: PASS-WITH-GAPS** — 17/17 held-out probes pass on the real wire
(scorecard reproduced byte-for-byte, content_digest `sha256:137d02c3…`; criticals 1/3/5/14/16
pass; no credential in the raw sqlite; name-shadowing, injection, schema bombs bounded at
call time, corruption terminal, epoch-stop zero-I/O, resume guards fail-closed, exactly-once
journal re-drive 0 new wire requests). One **feature-breaking gap found outside the exam**:
`Deliberation.planning_prompt` renders `toolbox.descriptions.slice(*allowed_tools)` and
`Hash#slice` drops the source-qualified MCP names — the MCP capability surface is INVISIBLE
to the planner; a real model never sees `mcp:test-server/…` exists (case 16 passes only
because it is scripted). Contradicts the plan's §3 "the session consumes the source at the
planning surface" boundary claim. Fix queued (must touch `deliberation.rb planning_prompt`,
the same method D-8's Fix B is editing — sequenced after D-8 lands): merge the MCP names +
bounded/control-stripped descriptions into `available_tools`. Minor deviations recorded:
self-`$ref` schema bombs accepted at admission but bounded+typed at call time (7 ms,
`ToolArgumentError`, digest-pinned — defense holds, row partially satisfied); MRTR reissue
once-only guard absent at the invocation layer (agent-unreachable — an `:interrupt` is a
terminal `ToolError`, never auto-reissued; tracked in the caller-journal contract).

**Slice-4 planning-surface fix CLOSED** (`9d1d3ec`): `planning_prompt` now merges the
source-qualified MCP surface into `available_tools` via `merge_tool_surfaces` +
`mcp_planning_surface` (catalog descriptions, control-stripped at render) — the exact
critic gap (real models blind to MCP tools; case 16 passed only because scripted). Gate:
774 runs / 0 failures both locales; scorecard 17/14/pass unchanged (honest-baseline pin
re-measured 195,800 → 195,882 — case 16's plan prompt now carries the MCP surface).
P10 is gate-complete pending the D-8 critic round.

### Round 19 — evals gem substrate merged (DR-3 + assertion variance)

Evals-gem improvement worktree merged `b6c379c` (24 files, +2088/−11; clean merge, no
conflicts). **DR-3 treatment harness** (`Tamoz::Evals::Harness`): `MemoryTreatmentProfile`
(mode :ci/:live; CI report declares `decisive_metric: "injection_correctness"`,
`attribution_claimed: false`, `delta_measurement.ci_claim: "none"`, 5 hard gates,
digest-stable with declared `exempt_fields: ["duration_ms"]`, `reproducible_surface` for
P15-F), `MemoryCell` (per-(case,treatment) isolated store, pre/post seed-digest, outcomes
pass/fail/insufficient/attribution_incomplete, mandatory `expected_delta`), `AgentMemoryCorpus`
(5 scenarios: recall_requirement, sensitive_guard, prompt_injection_defense,
no_flip_under_scripted, holdout_isolation; digest-pinned `suites/agent/memory/` fixtures
wired into `rake fixtures:refresh`), `MemoryStore`/`MemoryRetrieval` (epoch ladder
none|experience|knowledge|wisdom)/`MemoryEnvelope`/`MemoryHoldout` (0o700 partition),
Verifier rejects memory cases without non-null `expected_delta`, CLI `tamoz-eval treatment
memory` (live refused as operator-run), AgentRunAudit gains memory counters (scorecard
output unchanged). **Metric-split proof**: CI report carries no attribution keys anywhere;
`scripted_control_identical` gate asserts all four treatments of every case are identical
(scripted model ignores prompts — no attribution signal); a real-fail baseline cell still
shows no flip and `delta_observed: false`; a corpus that strips `:memory_recalled` events →
`attribution_incomplete`, never credited. **Assertion variance fixed**: subprocess_runner_test
moved from assert-inside-poll-callback to observe-and-assert-once-on-aggregate — 128
assertions on all 5 consecutive runs (was 227 vs 230 back-to-back). Gates: 789 runs / 0
failures under BOTH locales (30,210 assertions each, identical totals; one transient C-locale
flake re-ran green); scorecard unchanged 17/14/pass, 4/4 gates, safety 0. Deferrals: smoke
corpus under all four treatments (P11-ED follow-on; the null-control mechanism is proven on
the memory corpus), live layer operator-gated (no live-provider code in repo), the real
memory store (P11-D/P11-B) — P11-E points the same harness API at it.

**Evals critic: PASS-WITH-GAPS — substrate closes.** CI mode structurally CANNOT claim
attribution (verified adversarially: full report scan shows no attribution keys; a crafted
real-delta corpus — baseline fails, wisdom genuinely succeeds — still reports
`delta_observed=false`/`ci_claim="none"` and FAILS the `scripted_control_identical` gate
instead of crediting a flip; injection correctness is measurable by content alone via
embedded task markers). Sensitive-guard vault boundary real (`decrypt_reads=0` with
`unobfuscate` monkeypatched to raise); holdout OS boundary stat-verified; determinism
identical across locales (`content_digest d59e7b94`, `exempt_fields` declared); variance
fix 128 assertions ×5. **Claim correction:** the scorecard `content_digest` moved
`8aec4c84 → 8901f089` because the merge deliberately added
`environment.attribution_claim: "not_claimed"` — the numeric surface is byte-unchanged and
the key is honest + tested, but P15-F must pin the NEW digest. Pre-existing fragilities
noted (not substrate-caused): `AgentMcpAdversarialTest#test_no_orphan_server_survives_teardown`
flakes under load (reproduced pre-merge); `CliSubprocessHarness::LOAD_PATHS` needed
`tamoz-tools` (fixed by Round 20's test_helper change — canonical `bundle exec rake ci`
green).

### Round 20 — DR-4, DR-5, P16 merged in order and gated (critics in flight)

The three parallel worktrees merged into main in the pinned order; each merge re-gated by
the coordinator (both locales + scorecard), conflicts resolved:

- **DR-4** (`5c16bed` via merge, 22 files, +2023/−50): `Tamoz::StaleRequestError <
  CheckpointError` (RETRYABLE=false); claim-time validator INSIDE the transaction —
  stale ⇒ `queued→failed` in ONE tx (never observably claimed; the kill-window wedge is
  impossible by construction, invariant 53); fenced `request.terminal_fail` backstop for
  the claim→execute race; `drain_to_terminal` renders the typed reason once per request
  id (incl. deliver-consumed failures); FIFO-wedge test proves R1/R2 stale fail in order
  and R3 executes. Gate: 814/0 both locales.
- **DR-5** (`1c6efa1` via merge, 8 files, +1533/−65): `profile_roles` post-override
  resolution (RC5); TransitionRegistry codec v2 with ONE flocked `consume_if_candidate!`
  RMW both writers enter (loser falls to pinned replay, never a typed terminal error);
  `profile_id == "legacy"` refused at load (RC3); credential-ref NAME in the authority
  snapshot so replay resolves the identical env key (RC4); `ProfileRoleUnavailableError`
  typed wrap. Gate: 837/0 both locales.
- **P16** (`8f6b893` via `38d2e94`, 24 files): `tamoz-tools` gem (Toolbox wholesale +
  Skills whole module, taxonomy → `tamoz-core`, `LEGACY_SKILL_EPOCH`/`canonical`/
  `TOOL_ERROR_CLASS_NAMES` in core), six object-identical constant aliases, class-name
  serialization mapping at the 3 sites, explicit rescue sites (never widened), public-api
  pinned-HASH format with `deprecated: true` aliases, T2 clean-env RUNTIME harness (both
  skill_epoch branches, run_check, preview, effect_intent, mutations — zero
  `Tamoz::Agent::*` at runtime), T6 packaged-gem install-in-isolation. **Scorecard
  BYTE-IDENTICAL to the P16-start baseline (17/14/pass, model_input_bytes 195882)** —
  behavior-neutral extraction proven on the merged tree. Merge conflicts (public-api.json
  + test) resolved by taking the pinned-hash format and re-adding DR-4's
  `StaleRequestError` entry. Gate: 854/0 both locales.
- Flake class confirmed repeatedly: full-suite runs intermittently fail at one point then
  re-run green with IDENTICAL totals (kill-matrix/subprocess timing) — P15 evidence
  pinning owns the root fix; no merged phase regressed.
- Alias caveat recorded: three STRING-LITERAL error messages in tamoz-tools contain
  `Tamoz::Agent::` text (truthful via aliases — T1 byte-identity pins; the T2 harness
  executes every raising path; zero runtime constant references).
- Critic rounds for DR-4 (38 probes), DR-5 (23 probes), P16 (28 probes) in flight.

**P16 critic: PASS-WITH-GAPS — fast-follow landed.** All 28 probes pass against the true
P16-start baseline (b71d388 = DR-4+DR-5 merged, extracted via `git archive`): clean-env
full-surface executes with zero runtime `Tamoz::Agent::*` (26 checks, `defined?` nil);
`Skills::Error < Tamoz::Core::ToolError`; six aliases object-identical; class-name mapping
byte-identical at all three sites (journal/session-record/runtime payload; dedup signatures
unchanged); rescue sites correct (StoreError NOT widened — probe 15); T1 64-cell digest
matrix byte-identical; **T4 scorecard byte-identical (11,294 bytes: 17/14/pass, safety 0,
model_input_bytes 195882)**; T6 packaged gem (core+tools only); the three `Tamoz::Agent::`
string-literal error messages honestly adjudicated (strings, not references; every raising
path executes clean-env). One gap fixed (`be84e8e`+): `CliSubprocessHarness::LOAD_PATHS`
omitted `tamoz-tools` — the resume-after-kill child (RUBYOPT stripped) LoadError'd on a
clean checkout with tamoz-tools uninstalled; one-line addition, re-gated 856/0 both
locales, resume-after-kill true/1/1. **P16 CLOSED.**

**DR-5 critic: FAIL → fixes landed, re-adjudication in flight.** The critic reproduced a
shipped-binary crash: `consume_if_candidate!` (profile.rb:1151) calls `Time#iso8601` but
nothing in the agent load chain required `"time"` — clean `exe/tamoz` died with untyped
`NoMethodError` on the FIRST consuming ask (in-process gates missed it: transitive
requires + bundler). Fix (`be84e8e`): `require "time"` in profile.rb + a typed
`ProfileRoleUnavailableError` when a ref'd role's named key is unset even with the generic
key set (the DR5-05 corner — the silent generic fallback is the same divergence class RC-4
fixes at replay). Two regression tests (clean-subprocess load chain via the harness `-I`
paths; generic-key-set corner). Gates: 856/0 both locales, scorecard 17/14/pass. 22/23
probes passed pre-fix (DR5-17 harness deferral honest); the critic re-runs its blocker
repro + corner for the final verdict.

**DR-5 CLOSED — re-adjudication PASS.** The critic re-ran its exact clean-process `exe/tamoz`
repro: the consuming ask now executes the flocked consume path cleanly ("Applying operator
transition", entry consumed=true with a real request id, no NoMethodError); the corner probe
flips to typed `ProfileRoleUnavailableError` (generic fallback can no longer mask a missing
ref at start, and the raise sits BEFORE `api_key ||= generic` — RC-4's replay guarantee is
now enforced at both start and replay). Regression tests meaningful (corpus-exact `-I`
subprocess pin; generic-key-set corner). Gates re-verified: 856/0, machinery 24/230/0,
scorecard 17/14/pass, safety 0. Remaining open items are pre-existing and out of DR-5 scope
(subprocess-timing flake class — P15-owned; single-owner lease concurrency semantics).

**DR-4 CLOSED — critic PASS + hardening landed.** 39/39 probes passed (33 core + 5
adversarial + 1 extra real-SIGKILL probe): the D-6 two-owner shape terminal-fails at claim
in ONE tx (never observably claimed, invariant 53), real CLI subprocess + real SIGKILL
proof (exit 0, typed "stale resume request" rendered once, thread completes), FIFO never
wedges, rescue boundaries exact (745 redirect-wait stays CheckpointConflictError, never
burned), backstop payloads byte-identical. The critic's one optional hardening landed
(`c627aec`): the durable claim→execute drift window now surfaces as `StaleRequestError`
(converted at `resume_with_writer` only when `durable_request_id` is set — the ephemeral
path keeps `InvalidUpdateError` for caller bugs, pinned by graph_interrupt_test) so the
runner's backstop terminal-fails it — closing the last InvalidUpdateError-escape path of
the D-6 class. Gate: 857/0 both locales, scorecard 17/14/pass, safety 0.

### Round 21 — P17 merged and gated (critic in flight)

P17 worktree merged cleanly (`78041fc`, 25 files; no conflicts). Governed websearch as an
MCP-server capability through the P10 surface — Tamoz itself NEVER dials (the honest
enforcement point: the operator-side deployment enforces its own egress; Tamoz pins +
validates the declaration). egress: profile section (exact FQDNs, no wildcards/IP
literals incl. decimal/hex/octal spellings, schemes https-only, deny_private_ranges,
budgets, redirect_max_hops, circuit config, credential_refs) W1-validated at load AND
replayed via from_authority; authority snapshot carries it; session record pins
`egress_pin`; `verify_egress_binding!` resume guard (typed EgressBindingUnavailableError).
Real adapter `script/websearch_adapter` (SDK-built MCP server, one search tool,
default-DISABLED behind grant + declaration + provider) with per-hop logic in
`tamoz/mcp/websearch/` (EgressPolicy range classifier neutralizing mapped/alt-spelling
literals, EgressClient resolve→classify→pin→dial on EVERY connection + redirect hop,
no credential/header forwarding across hosts) — NOT required by tamoz/mcp.rb (the dialer
never enters core's load path). Circuit IMPLEMENTED (not deferred): both DR-2 open
conditions (consecutive connect failures ≥ threshold AND single budget breach);
reset requires authority:"owner" + operator_command_digest, self/evidence-free resets
raise typed CircuitPolicyError. In-tree deterministic fixture (mcp_test_server search
tool, grant-gated, no resolver/dialer — asserted). Scorecard 17→18 (`agent.websearch-governed`,
completed, injection_contained/credential_sweeps/circuit_opens/reset_refusals all
counted; 17 prior cases byte-identical); env honesty: network_enforcement stays
not_claimed + live_network_validation: "deferred". Gate: 899/33,651/0 BOTH locales
(identical totals), decision pass, 4/4 gates, safety 0, no orphans. Deferral: live-network
validation (operator-gated, never CI). 26-probe critic in flight.

**Round 21 addendum — external progress deep review reconciled.** A reviewer (not
gauntlet-spawned) produced `docs/reviews/PROJECT_PROGRESS_REVIEW_2026-08-02.md` and amended
the trackers at a STALE snapshot (`9e024a2`, pre-P17-merge). Adjudicated: **F1 (DR-2 as
active blocker) STALE** — P17 shipped the egress-scope circuit (`78041fc`, both DR-2 open
conditions + authority-gated reset); the P10-supervisor/server/rule/schedule scopes'
durable record remains for P12-H3/P13-E and is tracked there. **F2 (MCP stderr can
disclose credential values, inv 24) CONFIRMED REAL** — `child_environment` puts resolved
credential values in the child env; `stderr_tail` bounds + control-scrubs but has no
KNOWN-VALUE redaction; invocation error metadata attaches the tail (this is the slice-3
advD-d3 deferral, now upgraded to must-fix). Fix queued (runs right after the P17 critic
lands, to keep its evidence tree clean): redact resolved credential values from the
stderr tail + a malicious-child regression test. **F3/F4/F5 ACCEPTED** — tracker split
into design/implementation status, P11-ED integrates the existing DR-3 harness (no second
substrate), P15 protected corpora (P11/P12) become release-blocking, residual
verification/operations debt kept as explicit closure inputs. Its review-time `rake ci`
failed 5 env/process probes (macOS network-sandbox self-tests, MCP process-group probes,
kill-matrix) — diagnostic only; the stable-checkout gates remain 899/0.

**P17 CLOSED — critic PASS-WITH-GAPS, both findings fixed.** 26/26 held-out probes
executed; 899/33,651/0 verified by the critic itself; design:validate 55 invariants green;
case-18 oracle counters wired to real behavior; 17 prior cases byte-identical against the
true P17-start reference; enforcement honesty held (no dial site reachable from Tamoz's own
process; network_enforcement not_claimed). **The one real gap — SSRF classifier fail-open on
non-canonical dotted IPv4 forms** (`classify_address` nil ⇒ `private_range?` false ⇒ dialed;
verified: "127.1"→127.0.0.1, "10.1"/"192.168.1"→RFC1918, "169.254.1"→link-local) — fixed
(`3fe4d43`): fail-closed on unclassifiable addresses when deny_private_ranges is set
(legit DNS resolutions are always canonical, so no real flow is refused), + 8 regression
rows with a canonical-public positive control. **F2 (stderr credential redaction) also
landed in the same commit** — `stderr_tail` redacts resolved credential_refs values
(length ≥ 8) with a malicious-child regression test (the leaky child's value never reaches
the tail; "[REDACTED]" does). Gate: 901/33,666/0 both locales, scorecard 18/15/pass, safety
0, no orphans. **P17 CLOSED — the governed websearch capability ships (egress policy,
per-hop pinned dial, dual-condition circuit, honest enforcement claims).**

### Round 18 — D-8 implemented and gate-verified (critic pending)

D-8 landed `b3fe512` (14 files): Fix A — `expected_sha256` optional for apply_patch/
create_file, SINGLE resolution injected into both preview and execute args on the Session
driver (build_intent → `EffectDispatcher.observe` for patches, `hexdigest(content)` for
create_file; `dispatch` re-injects from the committed intent; `verify_intent_before_state!`
primary binding + `prepare_patch` equality live second) AND the Runtime driver (resolve once
at step entry; approval-callback mutation trips "file changed", fail-closed — RC-1/RC-2);
Fix B — scoped placeholder heuristic (path/digest containment + whole-string/reference-
phrase rules on all string args; negative test for legitimate `<`/`>`) + iterated
`argument_rule` in the planning prompt (see flag below); Fix C — `PlanRejectedError` includes
`DisclosableMessage` with structural-layer-only bounded summary, semantic/protocol → generic
phrase; corpus case 17 `agent.absent-digest-patch` (Runtime driver, digest omitted, check
passes, safety 0). `ACTION_DESCRIPTIONS`, `plan.rb`, tamoz-mcp, and all MCP touchpoints
untouched.

**T6 — the real-model gate PASSES.** Provider deepseek / model deepseek-chat / commit
`b3fe512` / 2026-08-02: exit **0**; `calculator.rb` bytes are exactly `a + b`; session record
pins `configured_check_passed == true`, `terminal_reason: check_passed`; exactly one
`apply_patch` succeeded + one `run_check` succeeded; only `calculator.rb` changed; the model's
ACTION plan genuinely OMITTED `expected_sha256` (Fix A mechanism confirmed on a real LLM).
Coordinator gate: `rake ci` **770 runs / 0 failures** under BOTH locales; scorecard **17
cases / 14 successes / decision pass / 4/4 hard gates / safety 0**; the 16 prior cases
byte-identical.

Flags for the D-8 critic (judgment calls beyond the accepted design's literal wording):
(1) the design's minimum `argument_rule` prompt text FAILED 5/5 real-model smoke runs — the
builder iterated the prompt wording (3 versions) to teach "values must be known before the
plan runs / don't guess paths / `expected_sha256` is the ONE argument to omit"; prompt text
is not digested (RC-7 safe), scorecard `model_input_bytes` re-measured per iteration; (2) a
Fix-B heuristic bug found during the work (reference-phrase rule must apply to ALL string
args, not exclude path/digest keys — caught by T6); (3) coordinator observation: discovery
plans in the T6 run still carried `PLACEHOLDER_FROM_SEARCH` paths (no `<`/`>`, no exact
reference phrase — slipped the heuristic; recovered via the repairable-failure path) —
assess whether the heuristic needs the "PLACEHOLDER_" shape or prompt reinforcement.

**D-8 CLOSED — critic PASS-WITH-GAPS, hardening landed.** All 10 held-out probes pass on the
real code; T6 re-verified from recorded artifacts (plan prompt carried NO `expected_sha256`;
journal shows exactly one succeeded apply_patch + one run_check; request rows completed);
P10 planning-surface fix verified (no-MCP prompt byte-identical; MCP session renders
source-qualified names, control chars stripped); scorecard reproduced at exact pins
(17/14/pass, 4/4 gates, safety 0, deterministic digest); CI 774/0 both locales; kill-matrix
flake confirmed pre-existing (K12, pre-P7 seam, untouched by D-8). Flag adjudications: (1)
iterated prompt wording — sound/bounded/invariant-safe (no literal pinned; the only pin,
`model_input_bytes`, re-measured to 195_882; `catalog_digest` untouched); (2) Fix-B
reference-phrase fix — correct; (3) `PLACEHOLDER_FROM_SEARCH` slip — NO heuristic change
needed (whack-a-mole; bounded by repairable-failure recovery; the T6 run recovered
end-to-end). Hardening landed `89eabf8`: the reference-phrase check is scoped to
path/digest args only (the critic's probe confirmed `from step 1` → `from step 2` patch text
was falsely rejected — the exact failure class D-8 exists to fix); negative test pins
legitimate phrases in before/after/query pass structural review; case-17 purpose reworded
(no "exactly once" overclaim — single-resolution is T2-unit-proven). Gate: 775/0 both
locales; scorecard 17/14/pass. **D-8 closed; the real-model action path is proven end to
end (read-only AND action mode, real DeepSeek).**

## 4. Phase ledger (mirrors the handover plan)

| Phase | Handover status | Gauntlet status |
|---|---|---|
| P0–P3 | complete | baseline audited — D-1/D-2/D-3/D-4/D-5 corrected |
| P4 compound edit | complete | **complete** — A/B/C/E implemented, reviewed, scorecard 7/12, safety zero |
| P5 reviewed file creation | complete | **complete** — A/B/C/E implemented, reviewed, scorecard 8/12, safety zero |
| P6 durable session/effect recovery | complete (P6-F partial) | **gate-verified, critic pending** — 16 kill seams, no second engine, scorecard 8/12, safety zero |
| P7 interactive/resumable CLI | complete | **complete, critic pending** — CLI subcommands, kill-resume scorecard case, safety zero |
| D-7 tool-error recovery (invariant 17) | — | **merged** (`35c2ffb`) — typed taxonomy, bounded repair, CLI failure reasons, scorecard 10/13, safety zero; critic pending |
| P8 trusted project profiles | complete | **complete** (`a019167`, `0ed3944`) — A/B/C/D/E landed; adversarial suite + `profile_trusted_boundary` scorecard case (14 cases, 11 successes, safety zero); §5.3/§5.4 machinery deferred and disclosed; critic pending |
| P9 evaluated skills | complete | **complete** (`8b095ab`) — D/A/B landed, adversarial suite 37 tests, `skill-no-authority` scorecard case (15 cases, 12 successes, safety zero); P9-C/D2/E/B2 deferred per accepted plan; critic pending |
| P10 governed MCP | complete | **closed** — slices 1–4 + planning-surface fix (`a69971d`, `d0e537e`, `9d1d3ec`); slice-3 critic FAIL (O1) fixed; slice-4 critic PASS-WITH-GAPS (planning-surface gap fixed); scorecard 17/14/pass, safety 0; D2/H/full-E-conformance deferred per plan scope |
| DR-2 durable circuit | accepted design | **active implementation blocker** — P10 still defaults to process-local circuit state; must close before P17 |
| DR-3 memory evaluation substrate | complete | **complete** (`b6c379c`) — existing harness is the substrate P11 must integrate with |
| DR-4 stale durable requests | complete | **closed** (`c627aec`, `7afe1ff`) — critic 39/39; 857/0 in both required locales |
| DR-5 profile machinery | complete | **closed** (`be84e8e`, `80725db`) — re-adjudication passed |
| P16 tools extraction | complete | **closed** (`fffaee8`, `2ae9e60`) |
| P17 governed websearch | pending | **blocked on DR-2** |
| P11–P15, P18 | pending | accepted design only; no implementation commits |

---

## 5. Current gaps

1. **DR-2 is accepted design but unimplemented (critical path).** P10's production
   supervisor still defaults to process-local `MemoryCircuitStore`; P17 requires the same
   durable aggregate circuit for egress health. Implement, critic-review, and gate DR-2
   before activating P17.
2. **MCP child stderr can disclose injected credentials (high).** Credential values are
   passed to the child environment, while the bounded `stderr_tail` is control-character
   scrubbed but not redacted by known value before being attached to typed errors. Add
   value-aware redaction and a malicious-child regression probe before expanding the MCP
   boundary in P17.
3. **Adversarial review debt remains.** P6 and P7 lack independent critic closure; D-7,
   P8, and P9 retain disclosed critic/deferred-scope debt.
4. **P6-F operational durability is partial:** disk-full injection, lock saturation under
   load, unresolved-effect deletion guard through a session, thread-leak measurement, and
   soak are not done.
5. **SIGKILL can orphan private `.tamoz-*` staging files.** Toolbox and SQLite atomic
   publishing rely on ensure cleanup that cannot run after SIGKILL; startup/reaper cleanup
   or a bounded private staging area remains required.
6. **Evaluation corpus comparability is incomplete.** P4/P5/P7 case definitions changed
   without `case_version` bumps. P15-F must pin corrected versions and evidence digests.
7. **P10 has explicit and implicit product gaps.** D2/H/full-E conformance remain deferred;
   MCP preview/admission exists as a programmatic surface but has no confirmed operator CLI
   workflow. Its closure record must also identify DR-2 durability as carried debt.
8. **P11–P15, P17, and P18 remain unimplemented.** DR-1 is design-only and must be
   implemented within P11 before Wisdom activation. P11 must integrate with the existing
   DR-3 harness instead of rebuilding it.
9. **Release evidence is not yet ordinary-CI complete.** Both-locale gates, scorecards,
   package isolation, security/license checks, benchmarks, restore, and release rehearsal
   still need P15 integration. README/SECURITY also lag the seven-gem and current MCP/action
   behavior.
10. **Process exception to record:** DR-3 was implemented out of the planned order, and
    DR-4/DR-5/P16 merged before their independent closure evidence was complete. Later
    evidence closed those implementations, but the single-active-phase protocol was not
    followed literally.

---

## 6. Next action

Implement **DR-2 durable circuit state**, including its independent critic pass and the
full gate under both required locales. Then activate P17. After P17, proceed through
P11 (implementing DR-1 before Wisdom activation) → P12 → P13 → P14 → P18 → P15.

### Resume checklist for the next session

Run this first; it is cheap and tells you the truth about where things stand:

```sh
cd /Users/ghassan/my-projects/tamoz
git status --short && git log --oneline -5
LC_ALL=en_US.UTF-8 rbenv exec bundle exec rake ci
LC_ALL=C           rbenv exec bundle exec rake ci
LC_ALL=en_US.UTF-8 rbenv exec bundle exec tamoz-eval scorecard agent-smoke
```

Expected at `54f675a`: clean worktree; last full gate was 627 runs / 0 failures under both
locales at the P9 merge `8b095ab` (P10-D added gem/test files only and ran its own targeted
tests, 31 runs green both locales — the full gate runs at the next P10 slice merge);
scorecard 15 cases, 12 successes, `decision: pass`, 4/4 hard gates, safety counters 0.
No product work remains on any side branch.

Then, in priority order:

1. **P10** — governed MCP client/host, mid-implementation per `docs/P10_MCP_PLAN.md`:
   catalog compiler + supervisor + `script/mcp_test_server`, then invocation/elicitation/
   session pinning, then the adversarial suite and 16th scorecard case, then the full gate.
2. **The deferred critic passes over P6, P7, P8, D-7 and P9.** Critic agents have
   repeatedly died to session limits before producing findings. Every "complete" mark
   for P6–P9 currently rests on the deterministic gate plus the builder's own
   self-review.
   That is weaker evidence than this project's own protocol asks for.

The judging harness (gate, blind A/B, five held-out probes) lives in the session scratchpad
and is deliberately uncommitted, so a builder cannot read or edit its own exam. It will need
recreating in a new session; its design is described in §1.

Do not treat `.claude/worktrees/` as product output. Do not push, publish, release, or
connect real physical actuators. The last product checkpoint on `main` is **`54f675a`**.

# Tamoz Gauntlet Loop — live progress

Status: **paused — verified handoff**
Started: 2026-08-01
Last verified: 2026-08-01 at commit `39a8679`
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
`valid_encoding?`. `Pathname#read(encoding:)` tags bytes without validating them, so the
`rescue Encoding::...` clause guards against exceptions that can never fire on that path.
A file containing `\xC3\x28` is returned to the model as content, with
`valid_encoding? == false`, instead of raising the documented
`file is not valid UTF-8 text`.

Measured in **both** locales, so this is a contract gap rather than a locale defect.

Why it matters: the tool advertises "Read UTF-8 text with its SHA-256 digest." The agent
receives mojibake as evidence and cannot faithfully quote it back, so any `before` text
derived from that read will not round-trip into `apply_patch`. P4 and P5 both need a correct
text/binary classification at this boundary.

Status: **open.** Commit `39a8679` corrected the review record but intentionally did not
change runtime behavior. This remains an invariant-17 gap and should be corrected before
P4 expands the patch surface.

### D-5 — patch text accepts non-UTF-8 binary strings (severity: high)

`validate_patch_text!` checks `valid_encoding?` in the string's current encoding rather
than requiring UTF-8. An `ASCII-8BIT` string containing bytes invalid in UTF-8 can therefore
pass validation and be written by the public Ruby API. The CLI is not currently affected
because `JSON.parse` supplies UTF-8 strings, but the framework contract is broader than the
CLI.

Status: **open.** It was discovered during Round 1 and recorded in the accepted correction
review. Correct it with D-4 under a separately reviewed, fail-closed contract correction.

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
bytes without transcoding. Consequently `apply_patch` against a non-UTF-8 target raises an
untyped `ArgumentError` out of `content.scan(before)` rather than a `ToolError` — a second
invariant-17 gap. Fail-closed (file byte-identical) and unchanged by this round.

**Disputed claim sent to the critic (superseded).** The correction document's residual-risk section
asserts that `apply_patch` writing raw bytes yields "a file that `read_file` will
subsequently reject as 'not valid UTF-8'." Measured behaviour contradicts this at both
baseline and HEAD. A review document asserting unverified behaviour is precisely the failure
mode an evidence-based process exists to prevent, so it is being adjudicated against running
code rather than prose.

### Round 1 — final critic and coordinator verdict

Round 1 is complete. The critic accepted the authorized correction after the builder and
critic corrected two inaccurate review claims in `b5f7fb9` and `39a8679`. The resulting
behavior wins against `0abb42a` on the changed properties without weakening the fixed agent
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

---

## 4. Phase ledger (mirrors the handover plan)

| Phase | Handover status | Gauntlet status |
|---|---|---|
| P0–P3 | complete | baseline audited — D-1/D-2/D-3 corrected; D-4/D-5 open |
| P4 compound edit | pending — next | not started; blocked on the D-4/D-5 contract correction |
| P5–P15 | pending | not started |

---

## 5. Current gaps

1. **D-4 invalid target bytes** — `read_file` returns invalid UTF-8 and `apply_patch`
   surfaces an untyped `ArgumentError`; both violate the documented recoverable-error
   boundary.
2. **D-5 binary patch arguments** — the public Ruby API can accept bytes that are not
   valid UTF-8 despite its stated contract.
3. **Gate assertion variance** — outcomes are stable, but the assertion count varies by a
   few assertions between identical runs; diagnose before P15 evidence pinning.
4. P4–P15 remain unimplemented.

## 6. Next action

Create and review a narrow correction plan for D-4 and D-5. Prove that reads, previews, and
execution reject invalid UTF-8 as typed `ToolError` values while leaving files byte-identical;
prove valid UTF-8 and all Round 1 probes remain unchanged. Commit the design correction,
implement it, run a fresh builder/critic loop and both locale gates, then commit the reviewed
implementation. Only after that correction closes should the next agent create and review
`docs/P4_COMPOUND_EDIT_PLAN.md`.

Do not treat the untracked `.claude/` worktree directory as product output. Do not push,
publish, release, or begin P5. The committed product checkpoint is `39a8679`; this progress
page is the only intentional product artifact added by this handoff.

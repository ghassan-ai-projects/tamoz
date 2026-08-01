# Tamoz Gauntlet Loop — live progress

Status: **active**
Started: 2026-08-01
Last verified: 2026-08-01 at commit `6504398`
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

## 4. Phase ledger (mirrors the handover plan)

| Phase | Handover status | Gauntlet status |
|---|---|---|
| P0–P3 | complete | baseline audited — D-1/D-2/D-3/D-4/D-5 corrected |
| P4 compound edit | complete | **complete** — A/B/C/E implemented, reviewed, scorecard 7/12, safety zero |
| P5 reviewed file creation | complete | **complete** — A/B/C/E implemented, reviewed, scorecard 8/12, safety zero |
| P6 durable session/effect recovery | complete (P6-F partial) | **gate-verified, critic pending** — 16 kill seams, no second engine, scorecard 8/12, safety zero |
| P7 interactive/resumable CLI | pending — next | not started |
| P8–P15 | pending | not started |

---

## 5. Current gaps

1. **P6 is not adversarially verified.** The coordinator's deterministic gate passes, but the
   independent critic pass is still in flight. Open questions it is attacking: do the kills
   land where the seam names claim (a kill firing slightly early or late proves nothing while
   still looking green); can `:unknown` be driven to `:not_applied` from an unproven pre-state
   via crash, stale fence, lease loss, or race; can `MAX_ATTEMPTS = 3` be exceeded or reset;
   was the `Deliberation` extraction genuinely verbatim, given that the identical scorecard
   digest is being used as the proof it changed nothing.
2. **The durable session has no behavioural scorecard case.** P6's proof is the kill matrix,
   which lives outside the scorecard, so P6 is not covered by the hard-zero safety counters.
   Cross-phase non-negotiable §7 says "every new capability adds a fixed behavioural case
   before it can be called complete." P6 is closed against the kill matrix instead. This is a
   real gap in the evidence chain and should be closed by P7 or explicitly promoted.
3. **P6-F operational durability is partial**: disk-full injection, lock saturation under load,
   the unresolved-effect deletion guard through a session, thread-leak measurement, and soak
   are not done.
4. **Evaluation corpus versioning.** P4/P5 changed case definitions (`purpose`, `tags`, `done`,
   `allowed`, `prohibited`) and the corpus digest moved `3f34750b…` → `d24bb33f…`, but
   `case_version` is still `1`. Rewriting `done` was necessary — the old condition would have
   let a case pass *by failing* once the capability existed — but two materially different
   corpora now both claim `v1`, so historical scorecard artifacts are not comparable. Not
   gaming; a versioning gap. Belongs to P15-F evidence pinning.
5. **Gate assertion variance** — outcomes are stable, but the assertion count varies by a few
   assertions between identical runs (453 runs / 27,825 vs 27,822 across locales, and the same
   drift at unchanged commits). Diagnose before P15 evidence pinning.
6. **Two disclosed, unfixed defects carried forward**: the orphaned private `.tamoz-*` temp
   file after a kill between publication and unlink, and the `:retry` request-recovery latent
   defect. Both are deliberate deferrals with stated reasons, not oversights.
7. P7–P15 remain unimplemented.

---

## 6. Next action

Two things, in this order.

1. **Land the P6 critic verdict.** P6 is closed in the trackers but is gate-verified only. If
   the critic confirms a seam is timing-dependent rather than deterministic, or reaches
   `:not_applied` from an unproven pre-state, P6 reopens — closure in a tracker is not proof.
2. **Then P7 — interactive and resumable CLI.** Fan out a builder and a separate harsh critic
   to produce and review `docs/P7_INTERACTIVE_CLI_PLAN.md` before any implementation. P7 is
   also the natural place to close gap 2 above by giving the durable session a behavioural
   scorecard case, so that P6's guarantees fall under the hard-zero safety counters rather
   than resting on the kill matrix alone.

Do not treat the untracked `.claude/` worktree directory as product output. Do not push,
publish, release, or connect real physical actuators. The committed product checkpoint is
`752363f`.

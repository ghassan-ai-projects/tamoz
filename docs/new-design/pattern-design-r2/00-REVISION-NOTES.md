# Revision notes — pattern-design r2

**Revision 2 · 2026-08-16.** This document is the deep review that produced r2, plus the
changelog from r1 (`docs/new-design/pattern-design/`). It records what was verified, what
was wrong, what is missing, and exactly what changed.

- **r1 base revisions** (what the original `file:line` references were written against):
  tamoz `smarter-tamoz` @ `5b07557`, agentic-stream `smarter-agent` @ `2e8aa3a` (both 2026-08-16).
- **Current HEAD** (what a reader checks out today):
  tamoz `e2e-test-new-design` @ `ebf1e23` (5 commits ahead of the r1 base),
  agentic-stream `e2e-test-new-design` @ `c067127` (3 commits ahead of the r1 base).
- **r2 changes are documentation-integrity only.** The technical analysis in r1 is
  accurate and is preserved verbatim except for the specific corrections listed below.

---

## Verdict

**r1 is substantively excellent and largely accurate. Its weaknesses are documentation
integrity, not analysis.** Every constant, mechanism, and seam sampled below was verified
against the code and found correct. What r1 lacked was the metadata a "source of truth"
folder needs to stay trustworthy over time: it references a **second repository it never
names**, its `file:line` anchors were **already drifting** the day after they were written,
and it carries **no revision, no changelog, and no glossary**.

---

## Verification method & coverage

Claims were checked by locating the named symbol/constant in the actual code (robust) and
comparing the cited line number (fragile). Coverage: a representative, load-bearing sample
across all 8 files — roughly 30 claims spanning both repos — not an exhaustive audit of
every `file:line`. Symbol-level claims verified: **all correct.** Line numbers: correct on
the Ruby side (drift ≤ ~5 lines), materially drifted on the Go side (up to ~74 lines).

| Claim (sample) | Repo | Cited | Actual @ HEAD | Status |
|---|---|---|---|---|
| `MAX_ACTIONABLE_INTENTS = 1` (decision_builder) | tamoz | :28 | :28 | ✅ exact |
| `DECISIONS = %w[approve deny]` (approval_relay) | tamoz | :38 | :38 | ✅ exact |
| `Plan::MAX_STEPS = 12` (plan.rb) | tamoz | :24-92 | :35 | ✅ in range |
| `DEFAULT_APPROVAL_REQUIRED` (tool_catalog) | tamoz | :28 | :28 | ✅ exact |
| 6-tool read-only allowlist (stream capability_host) | tamoz | :29-37 / :24-40 | :33-34 | ✅ ~exact |
| `state :judgements, default: []` (episode_graph) | tamoz | :59 | :59 | ✅ exact |
| `state :step_cursor` (session.rb) | tamoz | :370 | :370 | ✅ exact |
| `repair_count < 1` (episode_nodes) | tamoz | :449-455 | :452 | ✅ in range |
| `EPISTEMIC_KINDS` observed/reported/inferred/prescribed | tamoz | :30-45 | :44 | ✅ in range |
| `execute_tool` runs `tool_requests.first` | tamoz | :460 | :465 | ⚠️ drift +5 |
| `decisions.Validate` (validator.go) | **stream** | :189 | :189 | ✅ exact |
| at-most-one-actionable counter (validator.go) | **stream** | :244-261 | :244-261 | ✅ exact |
| `switch row.RiskClass` (policy.go) | **stream** | :308 | :307 | ✅ ~exact |
| `admitReconsiderations` (reconsideration.go) | **stream** | :26-155 | :26 | ✅ exact |
| `RecordRejection` → `concluded` (executor.go) | **stream** | :388-423 | :462 / :497 | ⚠️ drift +74 |

The +74-line drift in `executor.go` is not noise: it is the `ISSUE-061` "re-bind stale
episodes to the live situation version" fix landing between the r1 base and HEAD. This is
exactly the failure mode of line-number-only anchoring.

---

## Findings (severity-ranked)

### C1 — Critical · The second repository is undocumented and unpinned
r1 references `policy.go`, `validator.go`, `server.go`, `reconsideration.go`, and
`executor.go` on nearly every page. **None of these files exist in tamoz.** They live in a
**separate sibling repo, `agentic-stream`** (`~/my-projects/agentic-stream/`, Go), which
implements the *authority* half of the two-identity split. r1 never says the repo exists,
gives no path, and pins no revision — so every Go `file:line` is anchored to nothing and no
reader can locate a single `.go` file.
**Fix in r2:** README opens with a two-repo map; both repos' commits are pinned; every Go
reference in the pattern files is tagged as living in agentic-stream.

### H1 — High · Line numbers had already drifted and will keep drifting
r1 was written against `smarter-tamoz`/`smarter-agent`; both repos are now several commits
ahead on `e2e-test-new-design`. Ruby drift is small (≤ ~5 lines); Go drift reaches ~74
lines. A "source of truth" whose anchors decay silently stops being one.
**Fix in r2:** base commits pinned explicitly; a standard header on every file states that
**symbol names are authoritative and line numbers are approximate**; the confirmed large
drift (`executor.go`) is corrected in pattern-02.

### H2 — High · No revision metadata anywhere
No file carried a version, a date (except one date embedded in README prose), a base
commit, or a changelog. There was no way to tell whether a page was current.
**Fix in r2:** every file gets a revision header; this changelog exists.

### M1 — Medium · Ambiguous file references (two `capability_host.rb`)
Two files share the name — `gems/tamoz-tools/.../capability_host.rb` (the tool router) and
`gems/tamoz-stream/.../capability_host.rb` (the 6-tool evidence host). r1 sometimes cites a
bare `capability_host.rb:NN`, leaving the reader to guess which. (pattern-01's
`capability_host.rb:29-37` is the *stream* file; pattern-05 correctly uses full paths.)
**Fix in r2:** gem-qualified paths where the bare name was ambiguous.

### M2 — Medium · Some "Tests to update" files do not exist
- pattern-01 cites `test/stream_episode_tool*` — no such file. The real tool-loop test is
  `test/stream_episode_loop_test.rb` (protocol changes also touch
  `test/agent_reasoning_document_test.rb`).
- pattern-07 cites `stream_approval_receipt_store_test.rb` — no such file. The real approval
  tests are `test/stream_approval_relay_test.rb` and `test/comms_evidence_gated_approval_test.rb`.
- pattern-06's glob `test/stream_episode_*memory*` matches only
  `stream_episode_skills_memory_test.rb`; the memory-repository tests are `memory_*_test.rb`.
**Fix in r2:** corrected to real filenames.

### M3 — Medium · No glossary
The docs use a dense private vocabulary (episode, frame, digest, fence, slot, logical key,
spine, DIAGNOSE/RECONSIDER, R0–R4, watch, calibration artifact, two-identity split, effect
journal, receipt). A newcomer cannot read pattern-01 cold.
**Fix in r2:** `GLOSSARY.md` added and linked from the README.

### L1 — Low · A few falsifiable claims are stated too strongly
- pattern-04: "`Tamoz::Send` … zero call sites." `checkpoint_codec.rb:486,509` references
  `Send` (route (de)serialization). The accurate claim is "**no production *dispatch* call
  sites**; the checkpoint codec (de)serializes it, but no node emits a Send."
- pattern-04: `SubgraphRuntime` "wired but dead." It **is** instantiated at
  `executor.rb:227`; what is dead is the *child-graph invocation path* (no node drives a
  child `Compiled`). r2 sharpens the wording.

### L2 — Low · Linkage to the sibling planning docs is implicit
The README leans on "P3 contract", "P7 benchmark", "P8 calibration" — defined in the
sibling `PHASE_P*.md` / `PLAN_TAMOZ_LLM_REASONER.md` under `docs/new-design/`, but never
linked. r2 adds a "related planning docs" pointer to the README.

---

## Coverage gaps (what the *analysis* omits — optional, for a future rev)

These are not errors; they are enhancements the framework would benefit from. Not all are
applied in r2 (noted where they are).

- **G-A · No "risk of the change" per proposed design.** Each "How it SHOULD be
  implemented" lists seams but not what the change could break. The sharpest example is
  pattern-01 G3: adding a content preview to Observation re-opens the exact
  hallucination surface the metadata-only design closed. r1 mentions this inline; a
  standing **Replay/Risk impact** note per gap would make it systematic. *(r2 adds a
  Replay-impact line to pattern-01's G3 and pattern-03's critique node, where it is most
  load-bearing.)*
- **G-B · No effort/size on the gap tables.** Gaps are "priority order" but carry no size
  or prerequisite column beyond the README's prose sequencing. *(Not applied — noted.)*
- **G-C · No acceptance criterion per gap.** "Tests to update" names files but no "done
  when" condition. *(Not applied — noted.)*
- **G-D · Determinism/replay impact is inconsistent.** The whole system rests on the P3
  replay contract; changes that alter frame digests (pattern-01 G3, pattern-05 T2) should
  each carry an explicit replay-impact note. *(Partially applied.)*
- **G-E · chapter-00 has no dedicated map.** The autonomy scale (L0–L5) is used everywhere
  but mapped in one place only implicitly (the README substrate section). *(The GLOSSARY
  now carries the L0–L5 ladder as the single reference.)*

---

## Strengths (deliberately preserved in r2)

1. **Substantive accuracy.** Every sampled constant and mechanism is real and correctly
   characterized. This is unusually careful reverse-engineering.
2. **The proposed seams exist.** `step_cursor`, `judgements`, `reduce: :append`,
   `repair_count`, the `branch :validate` split — all real, so the "How it SHOULD be
   implemented" designs are grounded, not hypothetical.
3. **Internal consistency.** The README verdict table matches every per-file verdict;
   autonomy levels are consistent; the 01→03→02→04→05/06/07 sequencing is coherent across
   the README and the individual files. No contradictions were found.
4. **The "defer-by-design" discipline** (vector search, sagas, subgraph hierarchy,
   long-running jobs) is a genuine strength — documenting deliberate *non*-implementation
   with a rationale is rare and correct at this scale.

---

## Changelog: r1 → r2

- **Added** `00-REVISION-NOTES.md` (this file), `GLOSSARY.md`.
- **Rewrote** `README.md`: two-repo map + both commits pinned; revision header; glossary and
  planning-doc links; symbol-first anchoring note. Substrate section preserved.
- **Added a revision header** to all seven pattern files (rev, base commits, repo split,
  symbol-first anchoring).
- **pattern-01:** corrected "Tests to update" (`stream_episode_tool*` →
  `stream_episode_loop_test.rb` + `agent_reasoning_document_test.rb`); qualified the
  ambiguous `capability_host.rb` path; added a replay-impact note to G3.
- **pattern-02:** tagged Go references as agentic-stream; corrected the `executor.go`
  rejection reference (drifted ~74 lines).
- **pattern-03:** tagged `reconsideration.go` as agentic-stream; replay-impact note on the
  critique node.
- **pattern-04:** softened "Send zero call sites" and "SubgraphRuntime dead" per L1;
  tagged Go references.
- **pattern-05, 06, 07:** tagged Go references; pattern-06 corrected the memory test glob;
  pattern-07 corrected the approval receipt-store test name.
- **No technical analysis was altered** beyond the corrections above.

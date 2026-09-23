# File context — references, bounded reads, observations and the change ledger

Status: **plan, not built** · Date: 2026-09-23 (revised after reading the owner's DSH session logs) ·
Branch: `coding-harness` · Follows WP1–WP8 ([STATUS.md](STATUS.md))

The first harness build manages the *conversation*: a frozen header, an append-only surface,
spill, prune, compaction, handoff ([CONTEXT-ENGINE.md](CONTEXT-ENGINE.md)). It does not manage
*files* as a separate kind of context. File bytes enter the surface as ordinary tool output, are
spilled and pruned like a test log, stay visible after they go stale, and nothing records what
the turn did to the workspace as a whole. This plan adds that layer: `@path` references that
point without loading, reads that fetch bounded ranges on demand, an observation ledger that
makes the model read before it edits and tells it when a file changed under it, a short diff at
the tail after every edit, and a change ledger that can report and undo a turn. It starts by
giving the work route the window its model really has.

---

## 0. What DSH actually does

### 0.1 From its source

The request that started this plan described two DSH mechanisms. One is half right, one does
not exist. The owner's cache research already recorded both
(`~/ai-projects/articles/research-prompt-cache-architecture/08-CORRECTIONS.md`, A3 and A4).
Re-checked against `~/external-projects/deepseek-harness` at `c291e7961a`:

| Claim | What the source shows |
|---|---|
| "`FileReferenceService` fetches bounded code ranges on demand" | **Partly false.** `@path` / `@"path with spaces"` is real (`packages/context/file-reference/src/grammar.ts`). It is a path-only UI completion: "Selecting a candidate never reads or attaches file contents; the model must call a filesystem tool" (`file-reference/README.md`). A stable prompt section, `FILE_REFERENCE_PROMPT`, tells the model to read before it claims to have looked. The **bounded ranges** come from the `read` tool: `offset`/`limit`, where the default limit *is* the maximum (`fs/tool-fs/src/read.ts:14,55`). |
| "Edits are tracked via shadow-git checkpoints" | **False.** No shadow-git anywhere in the tree or its 16,511 commits. What exists: edits go straight to disk; `write`/`edit` send the model a **one-line success message** and attach a diff card per hunk with 3 context lines as `data.meta.diffs` — a sibling of the message, excluded from the request (`deriveEventMessage` returns `data.message`), rendered by the client's `DiffBlock.tsx`, persisted in the append-only session log; a separate policy forces read-before-edit and fails a stale edit (`fs/fs-observation-policy`: `FS_NOT_OBSERVED`, `FS_STALE_VERSION`). "Checkpoint" in DSH means a compaction summary node. There is no undo. Measured 2026-09-23: the edit result is 123 bytes, `The file … has been updated successfully.` |

### 0.2 In practice — what the logs show

The owner's experience is that a DSH session runs for hours and the context never fills, as if
things were injected and removed dynamically. The logs say something narrower and more useful.
`script/dsh_context_survey` reads every session log under `~/.dsh/sessions` and reports what the
context machinery actually did. Run on 2026-09-23:

**Every number on this page is one command's output**, not a hand count: run
`script/dsh_context_survey` to reproduce the table, the replacement counts, the snapshot
distribution, the instruction-channel counts and the cap-footer share. **The corpus is live** —
the agent writing this plan has its own sessions in it — so re-running gives slightly different
totals; the recorded run is stated with each figure and the shape is what matters. Recorded run:
**2026-09-23 12:05 CEST**.

| window | route | sessions | steps | prune | compact | max prompt | cache share |
|---|---|---|---|---|---|---|---|
| 1,000,000 | `deepseek-v4.1-flash` | 85 | 7,779 | **0** | **0** | **598,597** | 94.0% |
| 262,144 | `stealth/ox-alpha` | 636 | 26,096 | 235 | 27 | 213,223 | 96.6% |
| 262,144 | `glm-5.3-flash` | 28 | 1,851 | 14 | 5 | 209,877 | 97.1% |

| | |
|---|---|
| Surface replacements, whole corpus | **280**, every one from a compaction package: 249 tool-result prunes, 31 compaction checkpoints. None from staleness; none a rewrite of an earlier conversation message. ||
| Tool results, and how many hit a cap | 42,873 results; **1,830 (4.3%)** carried a cap footer — the rest entered whole |
| Runtime-context snapshots appended | 797. "Earlier snapshots no longer apply" markers: **0**. Per session: 724 sessions have 1, 13 have 2, 11 have 3, 2 have 4, 1 has 6, 5 have none |
| Widest prompt | 598,597 tokens: 596,480 cache reads and 2,117 uncached — 99.6% reuse at that step |

Four facts fall out, and they are the whole design argument:

1. **The window does the work, not the machinery.** On the million-token route nothing ever fired
   — no prune, no compaction — across 7,236 steps. On the 256K routes the same machinery fired
   often, and the prompt ceiling sits at the trigger: 209,877 = 0.8006 × 262,144, and 213,223 =
   0.813 (one step's growth past the pre-step check). DSH does not hold a conversation at a small
   window; it removes only what pressure forces.
2. **What the owner perceives as "removal" is the prefix cache.** DSH appends and does not
   rewrite. When volatile runtime context becomes empty it appends "Current runtime context: none.
   Earlier runtime-context snapshots no longer apply." rather than deleting the old one
   (`packages/core/agent-loop/src/runtime-context.ts:15`). The widest step re-read 596,480 cached
   tokens and processed 2,117 fresh ones; that is why a 600K-token context feels immediate.
3. **Size still costs, even when the window never fills.** Every appended byte is re-sent, at the
   cache rate, on every later step. A token not appended is saved hundreds of times. Bounded
   reads, read dedup and the diff tail are cost work, not only pressure work.
4. **In a context that is never pruned, stale file text lives forever** — and DSH does nothing
   about it (§0.3).

Tamoz's consequences:

1. **Tamoz's window is set far too small.** The README example and the eval run the work loop at
   64K (12K for the forced-compaction arm). At 64K Tamoz compacts where DSH never would, and the
   append-only path — the one DSH actually runs — is barely exercised. FC1 comes first.
2. **A disk change is not a prompt event.** Only prompt bytes reach the cache. That is the rest
   of this plan.

Whether answer quality holds at 600K is not in these logs: they show cost and speed, not
correctness. EVAL.md §5.3's `full` arm measures it (§6.3).

**Reproduction in a controlled session.** The corpus above is a survey; this is a controlled
experiment. A subagent read ten large Tamoz files (39 KB–319 KB), one read per step, with a dumper
folding its own session log after every read; then it re-read file 3 deliberately
(`tmp/context-test/ANALYSIS.md`, raw dumps beside it):

| | |
|---|---|
| Read output that entered | 589,500 bytes |
| Tool output resident at the end | 590,676 bytes — **0 replacements**, every read still on the surface, including the deliberate repeat |
| Final context | 47 messages, 614,891 bytes, 177,517 prompt tokens, 96% of it tool results |
| Cache across the eleven steps | 1,101,664 prompt tokens: **936,704 cached (85.0%)**, 164,960 fresh |
| Marginal cost of one ~54 KB read | mean 15,403 prompt tokens (13,964–17,207), then re-sent on every later step |
| Files above the 50 KiB cap | windowed, never summarised: `requirements-audit.json` (319 KB) delivered **18%** of the file |
| Measured density | **3.46 bytes/token** — `bytes / 4` under-counts by ~13% on code |

The policy point in one line: at Tamoz's documented 64K window this same series crosses the 0.8
trigger at step 3 (52,860 tokens) and the 0.92 backstop by step 5, so those reads would have started
being replaced; at the 1M route nothing fired at all.

### 0.3 The worked example: five reads, the third one changed

The concrete question this plan answers. The model reads `lib/a.rb` … `lib/e.rb`; the third,
`lib/c.rb`, then changes on disk — via a formatter, a generator, a check, or the operator's own
editor.

**What happens in the prompt.** The five reads are five `tool_result` entries on the append-only
surface. The change to `lib/c.rb` is not a prompt event at all: nothing is written, no entry is
replaced, and the derived message list is byte-identical to the request before it. `lib/c.rb`'s
stale text stays exactly where it was, above, inside the cached prefix.

**What happens to the cache.** Nothing — and that is the point. The prefix up to and including the
`lib/c.rb` read is still a valid cache prefix, so every later request re-reads it at the cache
rate. Rewriting that one message to show the new content invalidates every token after it: at
600K tokens, nearly the whole context, at full price. **A rewrite costs the suffix; an append
costs the appended bytes.**

**What happens in Tamoz today — the defect.** Nothing tells the model. Worse, the gate hides it:
when the model omits `expected_sha256`, `SessionEffects#resolved_effect_arguments`
([session_effects.rb:340](../../gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb)) fills
it from the disk *at gate time*, so the digest check passes against the current file. If the
outside change was outside the patched lines the patch succeeds, rebasing text the model never
saw; if it was inside, the patch fails with a generic text mismatch rather than "this file
changed". The stale read is never superseded, and the pruner trims by size only — at a real window
it never runs at all.

**What DSH does.** `fs-observation-policy` records `path → version` at read time and refuses a
later edit whose basis moved, with `FS_STALE_VERSION` and a re-read remedy appended by the tool
(`packages/fs/tool-fs/src/error.ts:31`). It is edit-time only. DSH has **no** proactive
"this file changed" note for read results and **no** read dedup; both are absent by source search.
DSH protects the file from a stale edit but lets the model's picture go stale silently.

DSH does own the pattern for one channel: instruction files. When an `AGENTS.md` the session was
shown changes, `agent-instructions` appends `Updated instructions from: <path>` with the new
content; when it disappears it appends `Instructions removed: <path> — The previously loaded
instructions from this file no longer apply.` The earlier message is never rewritten, and its
documented KV-cache effect is "append-only; newly visible content follows the reusable request
prefix and does not invalidate existing KV Cache entries"
(`packages/context/agent-instructions/README.md`).

**The method this plan adopts** is that pattern, generalised from the instructions channel to the
read channel DSH leaves unmanaged:

| Moment | What is appended | What is never touched |
|---|---|---|
| The model reads `lib/c.rb` | the read result, and a ledger entry `lib/c.rb ⇒ {sha256, retained bytes}` | — |
| `lib/c.rb` changes on disk | *nothing yet* | the read result above |
| The model edits `lib/c.rb` | the gate pins the patch to the **ledger's** sha; a moved file fails `stale_file` and writes nothing | the read result above |
| Before the next model step, and after each check | one `system_update`: `Files changed outside your edits…` with a 3-context-line diff from the retained bytes; the ledger then moves to the new sha | the read result above |
| The model needs the current text | `read_file(path, offset, limit)` — or nothing: old read + appended diff *is* the current file | the read result above |
| Pressure (rare at a real window) | superseded reads pruned first, then by size, then a compaction checkpoint | everything before the first replacement |

The cost model behind every row: an append adds `bytes × remaining steps` re-billed at the cache
rate; a rewrite re-bills the whole suffix uncached. At a real window the append always wins. §3
specifies each piece; §4 accounts for the cache.

### 0.4 The ideas this plan builds

1. **A reference is a pointer, not a payload.** The path is cheap body text; the bytes stay on
   disk until a tool pulls the range it needs.
2. **The disk is the store for file content.** A file can always be re-read, so its bytes never
   need to be spilled or summarised. Spill is for output that cannot be reproduced (a check run).
3. **After a change, append the diff; never rewrite what is already in the prompt.** The disk
   write is not a cache event; the short diff lands at the tail and the prefix stays warm.
4. **The model's picture of a file must be current** — before it edits, and after anything else
   changes the file.
5. **Know what the turn changed** — the useful part of "shadow-git" — built on the
   content-addressed `ArtifactStore` Tamoz already has, not on a second git repository (§3.6).

---

## 1. Where Tamoz stands (read from the code, 2026-09-23)

| # | Gap | Where |
|---|---|---|
| F-0 | **The window is not the model's.** The plumbing is right (a profile role's `context_window`, else `TAMOZ_CONTEXT_WINDOW`, no default), but every documented and evaluated setting is 64K or 12K. | `model_client_factory.rb:83`, `README.md`, `agenteval/adapters/tamoz-code*.rb` |
| F-1 | **Blind edits pass.** When the model omits `expected_sha256`, the session fills it from the disk at gate time, so a patch to a file the model never read is accepted. The editing prompt asks the model to copy a 64-hex digest from its last read — costly tokens and a common source of malformed calls. | `session_effects.rb:340`, `prompts/editing.md` |
| F-2 | **Unranged reads load whole files.** `read_file` without `offset`/`limit` returns up to 64 KiB. Over 8 KiB the result is spilled to a head-20/tail-40 stub, and the middle comes back through `recall_output` from a *snapshot* — not a file read, and stale after the next edit. | `read_operations.rb:25`, `toolbox.rb:26`, `work_gate.rb` `#result` |
| F-3 | **Changes the model did not make are invisible.** A check that reformats or generates code, or the user editing in their own editor, changes a file the model already read; nothing tells the model until a later patch fails on exact text. | — |
| F-4 | **Repeated reads are paid in full**, and then re-billed on every later step. | — |
| F-5 | **The edit diff has no context.** Hunks show only `-`/`+` lines, so the model cannot see where the change sits without re-reading. | `patch_preparation.rb:38` |
| F-6 | **No record of the turn's net change.** Receipts carry per-call digests. The finish report, the handoff note and the post-compaction surface carry no list of changed files; a new generation re-reads to find out. There is no way to undo a turn. | `session_work.rb` `#finish`, `harness/handoff.rb` |
| F-7 | **No references.** The task text reaches the surface verbatim; a named path is never checked or described. | `work_context.rb` `#opening` |
| F-8 | **Stale reads stay visible.** After an edit, earlier reads of the same file still show the old text, and the pruner trims by size only. Low priority at a real window (§0.2). | `context_engine/pruner.rb` |

What already exists and is reused: the window plumbing; ranged `read_file` with a whole-file sha
and line count; `search_text` with line numbers; `expected_sha256` verification inside the patch
tool (atomic with the write); the append-only `Surface` with logged replacements; `Pruner`;
`Spill` over `ArtifactStore#retain`; the approval engine and effect journal; the plan document
and handoff.

---

## 2. Design, in one picture

```
 task text ──► Harness::FileReferences.parse ──► session resolves in workspace ──► pinned
 "fix @lib/a.rb:120-180"                                                         `references` entry
                                                                                 (path, lines, bytes,
                                                                                  sha — no content)
 model ── read_file(path, [offset, limit]) ──► bounded window, never spilled ──► tool_result
                                               ledger {a.rb ⇒ sha1, bytes ref}    observes: {a.rb, sha1}
 model ── apply_patch(path, before, after) ──► gate: observed? pin sha from ledger
                                               tool verifies sha atomically ──► diff (3 context lines)
                                               ledger {a.rb ⇒ sha2}               observes: {a.rb, sha2}
                                               change ledger += {a.rb, before ref, sha2}
 model ── run_check(test) ──► check result ──► re-stat observed files; changed? ──► append note +
                                                                                   diff(ledger bytes, disk)
 finish / handoff / post-compaction ─► diffstat + net-diff locator from the change ledger
 pressure (rare at a real window) ─► prune superseded reads first ─► size prune ─► compact
 operator `rewind` ─► restore pre-images through the gate, only if disk still matches
```

Nothing already in the prompt is ever rewritten because a file changed. Every change reaches the
model as an append.

---

## 3. Mechanisms, in priority order

### 3.0 The window is the route's (F-0) — first, and mostly configuration

**This is the highest-value item in the plan, and the measurement settles it** (§0.2): on a
1,000,000-token route DSH ran 7,236 steps with zero prunes and zero compactions; on 262,144-token
routes the same machinery pruned 249 times and compacted 32. The window decides whether the
context machinery is ever exercised at all.

- The work route's profile role sets `context_window` to the real window of the routed model,
  taken from the provider's documentation when the route is added and recorded in the profile —
  1,000,000 for `deepseek-v4.1-flash`, the route the owner runs DSH on. The `deepseek-chat` window
  on the DeepSeek API is looked up, not assumed, before the eval arm is set.
- `docs/coding-harness/README.md` stops showing `TAMOZ_CONTEXT_WINDOW=65536` as the way to run
  (that is the file with the example); `documentation/reference/cli.md` only names the variable and
  stays as it is. The variable remains a documented override.
- The eval's main arm (`tamoz-code`) uses the route's window. `tamoz-code-small` (12K) stays: it is
  the arm that forces compaction, so compaction is still exercised — but it is an artificial arm,
  and the report must say so. DSH's own floor in the corpus is 262,144; a 12K arm measures the
  compaction path, not how DSH behaves.
- No code change beyond the adapters, docs and profile data: the resolution in
  `ModelClientFactory#configured_context_window` already does the right thing.
- **Same change in the token meter:** `prompt_tokens = input_uncached + cache_read`. Some DSH
  routes report `totalTokens`, some report only the three parts (§0.2, the survey script); Tamoz
  must handle both and must never treat `totalTokens` as the prompt size.

### 3.1 The observation ledger — read before edit (F-1)

DSH's `fs-observation-policy`, placed at Tamoz's gate.

- **State:** `work_observations`, a map `path ⇒ {sha256, ref}` of the version the model last saw,
  with its bytes retained in the `ArtifactStore` (content-addressed, so an unchanged file costs
  nothing twice). Recorded from a successful `read_file` (whole or ranged; the result carries the
  whole-file sha), `apply_patch` (the after-sha — the model saw the diff) and `create_file`. A
  reference manifest does not record one: no content was shown.
- **Retaining the bytes of a read:** after the read executes, the gate reads the file and retains
  it only if its sha equals the sha the result reported; if they differ, the file changed within
  the call and the entry records the sha without bytes (the next edit then fails `stale_file`,
  which is the right outcome). The ref is written into state in the same node, so replay does not
  re-read.
- **Gate, for `apply_patch`:**
  - No observation → refused before approval: `Error [not_observed]: read lib/a.rb first
    (a range around the edit is enough), then retry.`
  - Observed → the gate pins `expected_sha256` to the **ledger's** value. The patch tool's
    existing digest check then fails atomically if the disk moved since:
    `Error [stale_file]: lib/a.rb changed since you last read it; re-read the part you need.`
    The file is untouched.
- **The model no longer copies digests.** `prompts/editing.md` drops the `expected_sha256`
  instruction; a value the model sends is ignored in the work loop (the ledger wins). This removes
  a class of malformed calls and ~64 characters per edit.
- A ranged read counts as observing the file (DSH does the same); the exact-text `before` match
  still protects the lines the model did not see.
- Each turn starts with an empty ledger — the disk may change between turns. DSH resumes with no
  observed state for the same reason.
- `create_file` needs no observation: it already refuses to overwrite.

### 3.2 Changes the model did not make (F-3)

**This is Tamoz's extension, not DSH parity.** DSH has no proactive freshness notice for read
results; it only refuses a stale edit. What DSH does have is the identical pattern on the
instruction channel: a changed `AGENTS.md` is *superseded by an append*
(`Updated instructions from: <path>`), a removed one by `Instructions removed: <path> — The
previously loaded instructions from this file no longer apply.` This section generalises that
channel to every file the model read. The claim it must earn is the same one DSH documents for
instructions: append-only, so the reusable prefix is untouched.

**Measured, test 2** (`tmp/context-test/ANALYSIS-test2.md`): ten reads, then an append to the fourth
file from outside the edit tool. Across all seven dumps the `user/*` node counts never changed —
nothing was injected, no notice, no reminder. The only discovery was the refusal one step later:
`Error: cannot edit "…": file changed since it was read — re-read the file, then retry` (169 bytes),
with the file untouched. By then the context held **three** versions of that file (seq 31, 81, 111),
all visible, distinguished only by recency. That is the gap this section closes.

- **When:** after every `run_check` — Tamoz's own checks are the writer that runs inside a turn
  (formatters, code generation, snapshot updates) — and before every model step, for files the
  user may be editing in their own editor. Both are the same cheap pass: `stat` each observed path
  and compute a sha only when size or mtime moved. Observed files are the ones the model has read,
  typically tens, not the tree.
- **What the model gets:** one appended `system_update` entry per pass that found changes:

  ```
  Files changed outside your edits since you read them (a check or another editor):
  - lib/c.rb (read at step 7) — diff:
    @@ -40,3 +40,4 @@ …
  - lib/d.rb — deleted
  ```

  The diff is computed from the ledger's retained bytes to the disk, with 3 context lines — the
  same cheap, exact update as after the model's own edit. Over `read.max_bytes` it becomes
  `changed, re-read what you need`. The ledger moves to the new version, because the model now
  knows it.
- **Cache:** an append at the tail, like any tool result. The stale read above it is **not**
  rewritten (that would re-bill everything after it). The note says "since you read them" and
  names the step, so the model can tell which earlier result the note supersedes.
- **Durability:** the pass is a read; its outcome (the note and the new ledger) is written to state
  in the node that ran it, so replay rebuilds the same bytes.
- The check at edit time (`stale_file`, §3.1) stays as the backstop for a change that lands between
  the pass and the patch.
- **Bounded by observation, not by the tree.** Only paths in the ledger are `stat`ed. A file the
  model never read is not tracked and produces no note — the note is a correction to something the
  model was shown, which is the only thing a note can usefully be.
- **Interval:** one `system_update` per pass that found changes, never one per file. Ten files
  changed in one pass is one entry, and a second pass with no change appends nothing.

### 3.3 Bounded reads on demand — the disk is the store (F-2, F-4)

**Read dedup is also Tamoz's extension.** DSH's read tool has no "unchanged since" short form; a
re-read returns the full window again. Bounded reads, by contrast, are DSH parity — with bigger
numbers than this plan first proposed (see §3.0 note and the parity table in §8).

**Confirmed: DSH never spills a `read`.** The spill policy skips the read tool by name —
`if (… || exec.name === 'read') return decision`, commented "Skip `read` to avoid a read → spill →
read again loop" (`packages/spill/spill-policy/src/index.ts`). A read result is therefore bounded
only by the read tool's own caps (2,000 lines, 2,000 chars/line, 50 KiB) and stays inline;
spill exists for outputs that cannot be reproduced, exactly as this section argues. Measured over
all logs, the split between content and structure is emphatic:

| Channel | Calls | Result bytes |
|---|---|---|
| `read` tool | 6,517 | 50,617,082 |
| file dump via `bash` (`cat`, `sed -n`, `head`, `tail`) | 18,746 | 27,334,063 |
| other `bash` | 13,644 | 8,477,741 |
| `git` via `bash` | 525 | 2,122,600 |
| `grep` via `bash` | 1,752 | 1,876,715 |
| **tree / listing** (`ls`, `find`, `tree`, `du`) | 825 | **1,011,394** |
| `glob` tool | 117 | 130,143 |
| `lsp` (definitions, references, hover) | absent | — |

File content outruns structure by roughly 68:1. There is no AST, outline or symbol-index
substitution anywhere in DSH's context path; the "outline" packages are UI widgets
(`session-turn-outline`, the chat turn rail), and the `lsp` tool gives structure only when the
model asks for it. Only about 4% of all 42,124 tool results ever hit a cap footer, so almost every
one of those bytes entered the context whole and stayed there.

- In the work loop, `read_file` without `limit` gets the policy default `read.window_lines`
  (F4: 800). A file that fits returns whole, as today. A larger one returns the first window and a
  footer: `lines 1-800 of 1,823 · sha256 3f9a… · continue with offset 801, or search_text to locate`.
- A read result is capped at `read.max_bytes` (F4: 50 KiB) on a line boundary, with the same footer,
  and is **never spilled**: the file is re-readable, so a spill stub plus `recall_output` is a
  worse copy of `read_file` with an offset. Spill stays for check output, search results and
  anything else that cannot be reproduced.
- **Read dedup.** After a `read_file` executes (journaled as today), the gate compares the
  result's path, range and sha with the visible, unshadowed surface. If an identical result is
  still visible, the appended text is the short form:
  `lib/a.rb lines 1-800 unchanged since step 9 (sha256 3f9a…); that result is still above.`
  If the earlier one was pruned or compacted away, the full text is appended. A pure function of
  the journaled result and the surface, so replay rebuilds the same bytes. At a real window this
  is the main saving: a duplicate 6K-token read avoided at step 100 of 700 is 3.6M billed tokens
  not paid.
- The default is applied by the work gate, not inside `ReadOperations`, so the pipeline, the
  healing preflight and every other `read_file` caller keep today's behaviour.
- A symbol outline for large files was considered and deferred: `search_text` already returns
  line numbers. Revisit if the eval shows the model paging through large files.

### 3.4 The edit tail — a diff with context (F-5)

**This is a Tamoz addition, and Tamoz already does half of it.** Measured: DSH's model-visible edit
result is one line — `The file <path> has been updated successfully.` (123 bytes). The 3-context-line
diff is *not* sent to the model at all; it rides `data.meta.diffs` beside the message, is excluded
from the request by `deriveEventMessage` (`packages/core/session/src/surface.ts`), and is rendered by
the client's `DiffBlock.tsx`. `DIFF_CONTEXT = 3` is a UI constant. Tamoz, by contrast, already
appends a diff to the model result (`WorkGate#success_text`: `"#{output}\n\nDiff:\n#{preview}"`),
rendered by `render_diff` **without context lines** (F-5). So this section moves Tamoz further from
DSH, deliberately — and it must earn its bytes on its own, not by claiming parity:

- `render_diff` emits standard unified hunks with 3 context lines and the after-sha. The old read
  plus this diff is an exact picture of the new file: lines outside the hunks are unchanged, and the
  hunk headers give the shifted line numbers. It replaces a re-read — DSH's model, which gets only
  "updated successfully", has to re-read to know what its own edit produced.
- The cost is real and measured: every byte of the diff is appended and then re-sent on every later
  step at the cache rate (§0.2). A one-line change's diff is ~300 bytes, so the trade favours the
  diff; a large rewrite's diff should fall back to the receipt plus a re-read.
- `create_file`'s result stays a receipt (path, lines, bytes, sha); it does not echo the content
  the model just wrote.
- A very large diff is spilled like any other output.
- Blast radius: `render_diff` also produces the approval preview in the pipeline. Operators get
  context lines there too; previews change bytes, so preview digests change. Fresh databases, no
  compatibility (AGENTS.md).

### 3.5 `@path` references — pointer, not payload (F-7)

- **Grammar** (DSH's rules): an `@` at the start of the text or after whitespace; `@path` ends at
  whitespace; `@"path with spaces"` is quoted; a trailing `/` marks a directory; an `@` inside a
  token (an e-mail address) is not a mention. Tamoz adds one optional suffix, `@path:120-180`
  (owner decision F1): the lines the user is pointing at.
- **Resolution** happens in the session with the toolbox's own path rules (workspace-confined, the
  same ignored directories and symlink handling as `read_file`). Each mention resolves to `file`
  (lines, bytes, sha256), `directory` (entry count), `not found`, or `outside the workspace` (no
  stat is taken, so nothing about the outside path leaks).
- **Surface:** one pinned `references` body entry right before the task:

  ```
  Paths the user referenced (not read yet — read_file what you need):
  - lib/a.rb · file · 1,823 lines · 61.2 KB · sha256 3f9a…  · lines 120-180 pointed at
  - spec/ · directory · 14 entries
  - lib/missing.rb · not found
  ```

  No file bytes, and not an observation.
- **Header:** one new prompt file, `file_references.md` (DSH's `FILE_REFERENCE_PROMPT`, adapted),
  always present when `read_file` is on the surface, so the header stays byte-stable across turns.
- **Chat and CLI** parse the same way. Path completion as the user types is out of scope.
- **Where:** grammar and rendering are pure text in `tamoz-harness` (`Harness::FileReferences`);
  resolution in `WorkContext#opening`, which already holds the toolbox.

### 3.6 The change ledger — what the turn did (F-6)

What people mean by "shadow-git", built on the store Tamoz already has.

- **Pre-images come from the observation ledger.** The bytes the model last saw are already
  retained (§3.1), and the gate has pinned the patch to that sha, so a successful patch's
  pre-image *is* the ledger's ref. Nothing new is read at execute, and a crash after the write
  cannot record the post-image as the pre-image. `create_file` records `absent`.
- **Ledger:** `work_changes` append channel of `{path, before (ref | absent), after_sha, step}`.
  The first `before` per path and the last `after_sha` define the turn's net change.
- **Uses — deterministic, none needs the model to remember:**
  1. **Finish report:** a `Changed files` diffstat (`lib/a.rb +12 −3`) and the full net diff
     spilled with its locator in the verification record. `tamoz code` prints it; `--json` carries
     it. The honest report no longer depends on the model's own list.
  2. **Handoff note:** the diffstat and the locator (`handoff.md` gains `%{changes}`), so the next
     generation knows what changed without re-reading the tree.
  3. **After a compaction or reset:** appended with the plan re-read, so exact paths do not depend
     on the summariser.
- The net diff is rendered from the pre-image and the file on disk when it is needed (finish,
  handoff, compaction); that read's result is stored in state, so replay does not re-read.
- **Why not a real shadow git.** It needs the `git` binary and a second object store that
  duplicates `ArtifactStore`; it snapshots the whole tree (slow on large repos, and it copies
  ignored and secret files unless it re-implements ignore rules); a misconfigured `GIT_DIR` can
  touch the user's own repository; and it feeds the context nothing the two ledgers do not.
  Changes made by checks, the one thing a whole-tree snapshot would see, are covered by §3.2.

### 3.7 Rewind — undo a turn (owner decision F3)

- `tamoz rewind [--thread T]` (CLI) and `/rewind` (chat) restore the last work turn's pre-images
  and delete the files it created.
- **Guard, fail closed:** every path's current sha must equal the ledger's final `after_sha`. If
  any differs, nothing is written and the conflicts are listed. No partial rewind.
- **Same seams as any mutation:** restores are `restore_file` calls (a new tool in `tamoz-tools`:
  write bytes from a store ref, or delete, under `expected_sha256`), approved by the policy YAML
  (`workspace_write` tier, a row in `base.yaml`), journaled by `EffectDispatcher`. The rewind turn
  enters the work loop with its calls already pending (`work_gate` → `work_execute`) and no model
  step; `work_observe` ends it. No new graph nodes.
- No model-callable revert: the model undoes its own edit with another `apply_patch`, which the
  ledger records like any edit.

### 3.8 Superseded-read pruning (F-8) — low priority at a real window

- Every file-bearing `tool_result` entry carries `observes: {key: path, version: sha}`, a generic
  field on `ContextEngine::Surface` entries; the engine knows nothing about files. §3.3's dedup
  uses the same field.
- `ContextEngine::Pruner` gains a first pass: under pressure, a visible entry whose version
  differs from the ledger's is replaced by one line:
  `[read of lib/a.rb lines 1-300 superseded — the file changed at step 14; re-read what you need]`.
  It runs in the same replacement pass as size pruning, so it adds no cache break.
- At a 1M window this rarely runs (§0.2). It is kept because the 12K arm, small-window routes and
  compaction need it, and it is small once `observes` exists.

### 3.9 Runtime context as an append-only snapshot (DSH parity)

DSH keeps volatile context out of the system prompt and appends it as a **sourced user-role
snapshot** only when the rendered text changes, with the contributing sections named
(`RuntimeContextProjection`, `packages/core/agent-loop/src/runtime-context.ts:109-158`). It never
re-renders in place, and when the snapshot becomes empty it appends a marker —
`Current runtime context: none. Earlier runtime-context snapshots no longer apply.` — rather than
deleting the old one. In the corpus: 797 snapshots appended, 0 markers, and at most 6 in any one session.

Tamoz today renders `runtime_text` once in `WorkContext#opening` (`work_context.rb:69`), pinned at
the start of the body, and never revisits it. A long turn therefore keeps the branch, dirty state
and budget picture it started with, and a `/think`-style change becomes a `system_update` with no
relation to the snapshot it modifies.

**Dropped, and why.** `Harness::Header.runtime_snapshot`
(`gems/tamoz-harness/lib/tamoz/harness/header.rb:17`) renders this text and `WorkContext#runtime_text`
(`work_context.rb:106`) calls it once per turn. An append-on-change mechanism was planned here (FC10)
and is **dropped**: every component is turn-constant (root, date, the *total* budgets, the window;
branch is never passed), so nothing can change mid-turn and the comparison is dead code. Rendering
*remaining* budget instead would append on every step, which is worse than rendering it once. The
seam stays as it is; if the harness later tracks branch or dirty state, it is called again then.

- **Split the two kinds of context explicitly:** *sections* (identity, operating rules, tool rules,
  editing rules, honesty, surface) are stable and belong in the frozen header; *dynamic context*
  (date, workspace root, branch and dirty state, budgets left, accepted plan digest, active goal)
  is volatile and belongs in a sourced body entry.
- **No "no longer apply" marker branch.** DSH appends one when the dynamic set empties; the corpus
  measured **0** in 793 snapshots, and Tamoz's dynamic set is never empty by construction (the date
  and the budgets are unconditional). AGENTS.md: do not write code for a case that cannot happen.
  Dropped by review (GOAL.md records the decision).
- **Not in the header.** A branch name or a date in the header breaks byte stability on every
  request and invalidates the entire cache (§CONTEXT-ENGINE.md §2.1, H5). This is the rule that
  makes the snapshot mechanism necessary rather than optional.

### 3.10 System-node normalization at a series boundary — **dropped (FC11)**

DSH does have this: the system prompt is itself a surface node, and `SystemPromptProjection`
(`runtime-context.ts:60-106`) reconciles it when the route or series changes or the prompt renders
empty — node 0 protected, later in-history system nodes emptied with a logged replacement.

An earlier draft of this plan proposed mirroring it (FC11) for Tamoz's `system_update` entries. It
is **dropped**, on this plan's own evidence:

- The measurement §0.2 found **0** such replacements in the entire 753-log corpus — it is not a
  behaviour that occurs.
- Tamoz's loop appends `system_update` entries in exactly two places: `WorkContext#opening` (where
  `pinned: true` entries are re-built every turn, because each turn is a fresh execution on a fresh
  surface) and `WorkGate#round_complete` (a one-shot repeat reminder, which a follow-up does not
  carry). Neither accumulates across a series in the way the mechanism would tidy.

AGENTS.md is explicit: *"If a scenario cannot happen by construction (or only in a case that has
never occurred), do not write code for it. Fix it when it actually shows up, not preemptively."*
Recorded in GOAL.md as a deliberate scope reduction. If a session ever shows accumulating system
nodes, it returns as a measured finding with that session as the repro.

### 3.11 Guidance files are files too (owner decision F8)

A workspace `AGENTS.md` is the clearest case of the problem this plan fixes, and DSH already treats
it that way. A guidance file is loaded into the prompt once; if it changes under the model, the
loaded copy is stale exactly like a stale `read_file` result. Measured over the corpus (`script/dsh_context_survey`): 812
instruction messages, of which **830 changes are baseline `set`**, 20 are nested-scope
discoveries, 19 are `replace` and 1 is `remove` — 40 of 870 changes are dynamic.

DSH's three dynamic notices, verbatim from the logs:

```
Additional instructions from: .fleet/worktrees/referee6/AGENTS.md
These instructions apply to work under `.fleet/worktrees/referee6`. …
```
```
Updated instructions from: AGENTS.md
This file changed after it was loaded. Use the following content instead of the previously
loaded instructions from this file.
```
```
Instructions removed: .fleet/worktrees/referee14-verify/AGENTS.md
The previously loaded instructions from this file no longer apply.
```

All three are appends. The baseline message stays in history and is never rewritten; DSH's
documented KV-cache effect for all of them is "append-only; … does not invalidate existing KV
Cache entries". DSH carries them as a `user/message` with
`source: {kind: 'agent-instructions', form: 'instructions', changes: [{action: set|replace|remove,
scope, path, digest}]}` — which is why the Web client renders the row as **"Context injection
~/.dsh/AGENTS.md, AGENTS.md"**, naming the producer files
(`packages/client/ui-chat/src/client/conversation-nodes/event-projection.ts:60`).

Tamoz today: `WorkContext#opening` loads the workspace-root files through `Harness::Instructions`
into one `guidance` body entry, pinned, opt-in, 16,384 bytes, rendered inside a
`<project-guidance sources digest truncated>` wrapper. It has no user-global file, no
per-directory scope discovery, and — the gap — **no change or removal notice**: guidance that
changes mid-turn stays stale for the rest of the turn.

- **Adopt the change/removal notice** for every guidance file already loaded, through the same pass
  as §3.2: guidance paths are observation-ledger entries whose ledger has no `read_file` behind it.
  A changed file appends the loaded-vs-disk diff; a removed one appends the one-line removal
  notice. Both are `system_update` entries, so G-21-style assertions cover them.
- **Do not adopt scope discovery** (D4): the guidance chain is read once per generation. Guidance is
  untrusted and opt-in, so discovering more of it is not the goal. Note the asymmetry, and that it
  is deliberate.
- **Record the per-file digests, not only the rendered wrapper digest.** DSH's `changes[].digest`
  is per file, which is what makes a later `replace`/`remove` decision possible; Tamoz's current
  single `digest` over the whole rendered body cannot tell which file moved.

---

## 4. Cache and cost accounting

The one rule every row obeys: **a disk change is not a cache event; a prompt-byte change is.**
Appending costs the appended bytes × remaining steps at the cache rate. Rewriting costs the whole
suffix uncached. At a real window the append wins, which is why nothing here rewrites an earlier
message.

| Change | Cache effect | Billed-token effect |
|---|---|---|
| Real window (§3.0) | Fewer replacements, so fewer cache breaks. | The context grows larger; every token is re-billed per step, which is why the items below matter. |
| `file_references.md`, new `editing.md` | Header bytes change once, at deploy; static afterwards. | — |
| Outside-change notes, diff tail | Appends only. | A diff instead of a re-read. |
| Bounded reads, dedup | Appends only, smaller. | The main saving, multiplied by every later step. |
| `references` entry | Pinned body entry in the opening. | Paths only. |
| Change-ledger diffstat | Appended at finish, handoff and after a compaction — points that already end or break the series. | — |
| Superseded pruning | Rides the existing prune pass. | — |

G-1 (header stability) and G-2 (append-only) keep holding without new exceptions: §3.2 appends and
never rewrites.

---

## 5. Where the code goes

| Gem | Change | Interface touched (ask first, AGENTS.md) |
|---|---|---|
| profile data, adapters, docs | Route `context_window`; eval main arm; README/CLI docs. | — |
| `tamoz-context-engine` | `observes` field on `Surface` entries; `Surface.visible_matching`; `Pruner` superseded pass taking `current: {key ⇒ version}`; snapshot compare helper for §3.9. | `Surface.entry`, `Pruner.prune` gain keyword arguments. |
| `tamoz-harness` | `Harness::FileReferences` (parse, render); `Harness::Instructions` returns per-file digests (§3.11); prompt files `file_references.md`, `outside_changes.md`, revised `editing.md`, `handoff.md` with `%{changes}`; `Handoff.note(changes:)`. | `Handoff.note` signature; one new harness unit. |
| `tamoz-tools` | `render_diff` with 3 context lines, and a text-to-text diff for §3.2; `read_range` takes a byte cap; stable error codes `not_observed`, `stale_file`; `restore_file` (F3 only). | Diff output format; one new tool. |
| `tamoz-approval` | `restore_file` tier row in `policy/base.yaml` (F3 only). | Policy data. |
| `tamoz-agent-session` | `WorkContext#opening` resolves references; `WorkGate` owns the observation ledger, pinning, default read window, dedup, the outside-change pass; `work_changes`; finish/handoff/compaction append the diffstat; rewind intake; series-boundary system-node normalization. New state channels → graph version 6. | Graph version. |
| `tamoz-agent-cli`, comms | `tamoz rewind`, `/rewind`; print the diffstat. | CLI surface. |

Dependency rules from QUALITY_BAR A2 are unchanged: `tamoz-context-engine` → `tamoz-core` only;
`tamoz-harness` → `tamoz-context-engine` + `tamoz-core` only.

---

## 6. Evaluation

### 6.1 Offline guarantees (in `rake ci`; ids continue EVAL.md §2)

| Id | Property | Test file |
|---|---|---|
| G-13 | A reference entry contains no file bytes; a path outside the workspace or through an escaping symlink resolves to `outside the workspace` with no stat; `me@host.com` is not a mention; a quoted path with spaces resolves. | `test/harness_file_references_test.rb` |
| G-14 | `apply_patch` on an unread path is refused `not_observed` and never reaches approval; an external change between read and patch gives `stale_file` and leaves the file byte-identical; a second patch right after a first one needs no re-read. | `test/work_loop_observation_test.rb` |
| G-15 | An unranged read of a 5,000-line file returns the default window and the continuation footer, is never spilled, and stays under `read.max_bytes`. Pipeline `read_file` calls are unchanged. | `test/work_loop_observation_test.rb` |
| G-16 | Under pressure, every visible read of a superseded version is replaced by the stub in the same replacement pass as size pruning; without pressure, no replacement happens after an edit. | `test/context_pruner_test.rb` |
| G-17 | A repeated identical read returns the short form while the earlier result is visible, and the full text once it has been pruned or compacted. Replay rebuilds identical bytes. | `test/work_loop_observation_test.rb` |
| G-18 | A patch's recorded pre-image is the ledger's retained bytes; a crash after the write and before the receipt does not record the post-image as the pre-image; the net diff equals `diff(pre-image, disk)`. | `test/work_loop_durability_test.rb` |
| G-19 | Rewind restores byte-exact files and deletes created ones; one conflicting path refuses the whole rewind with nothing written; every restore passes the approval gate and the journal. | `test/work_rewind_test.rb` |
| G-20 | The diffstat after a compaction lists every mutated path, independent of the summary text. | `test/work_loop_test.rb` |
| G-21 | A check that rewrites an observed file produces exactly one appended note with the exact diff from the read version; nothing earlier on the surface changes (request *n* is a byte prefix of *n+1*); the ledger moves to the new sha, so the next patch is not `stale_file`. An unobserved file changed by the check produces no note. | `test/work_loop_observation_test.rb` |
| — | G-22 is **retired with FC10** (§3.9): the snapshot is turn-constant, so there is no change to detect. | — |
| G-24 | For every route in `data/model_windows.yml`: the recorded window equals the value the adapter and `ModelClientFactory` resolve for that provider/model, the entry carries its source and lookup date, and `TAMOZ_CONTEXT_WINDOW` still overrides it. A route absent from the file with no profile setting and no env var still refuses. | `test/model_windows_test.rb` |
| G-25 | A secret planted in a file the model reads is redacted before those bytes are retained in the observation ledger, before the outside-change note renders, and before the net diff renders — the raw secret appears in none of the three. | `test/work_loop_observation_test.rb` |
| G-27 | The model's own `expected_sha256` is ignored on the work route: a patch carrying a wrong digest still uses the ledger's version, and the ledger decides. | `test/work_loop_observation_test.rb` |
| G-28 | The finish report and the handoff note each carry the turn's diffstat, built from the change ledger and not from the model's own list. | `test/work_loop_test.rb`, `test/harness_protocol_test.rb` |
| G-29 | Guidance records a digest per loaded file, and a changed or removed guidance file appends its notice (§3.11). | `test/harness_instructions_test.rb` |
| — | G-23 (series-boundary normalization) is **retired with FC11** (§3.10); G-26 (a DSH-shaped usage payload) is **dropped** — no provider Tamoz talks to sends that shape. | — |

### 6.2 Controls (the graders must discriminate)

**Corrected after review.** An `agenteval` control agent is a mutation map judged directly by the
production scorer — it never shells out, never calls a model, and **never runs the work loop**
(`agenteval/lib/agenteval/controls.rb`). A gate refusal that lives inside the work loop therefore
*cannot* be expressed as a control. The phase-2 evidence is split accordingly, and each half names
the mechanism that can actually fail.

**(a) Scripted-provider work-loop tests** — these drive the real gate with a deterministic provider,
so they are plumbing evidence, never intelligence:

| Behaviour | Expected | Test |
|---|---|---|
| `blind_editor`: patch a file never read | `not_observed` refusal before approval; file untouched | G-14 |
| `stale_editor`: patch after an external change | `stale_file` refusal; file byte-identical | G-14 |
| `dup_reader`: read the same range ten times | the short form, and a flat tool-result byte total | G-17 |
| `formatter_check`: a check rewrites a read file | exactly one appended note with the diff; no stale re-apply | G-21 |

**(b) Genuine controls** — only where a degenerate *strategy* is expressible as an agent. The
existing control set is unchanged and must still score correctly; no phase-2 control agent is added
for a gate behaviour, because none can be.

**(c) The positive loop-level cell — mandatory.** Every negative assertion above is satisfied
trivially by a harness that **refuses every edit** and never records an observation. So one cell
must be driven through the real work loop end to end and scored **solved**: read a file → patch it →
run a check that rewrites it → receive exactly one outside-change note → patch again from the new
content → pass the check. Until (c) is green, (a) proves nothing. This is F14's hard requirement and
the cell is added in FC8.

### 6.3 Real model (DeepSeek, paired against the current build)

The tasks and cells are the ones EVAL.md §8.3 fixes — `large_file_fix`, `mention_task`,
`dup_read_task`, `formatter_check`, the positive `fresh_editor_task`, and the planted
`stale_editor_task` / `blind_editor_task`. Measured on those and the existing harness pack, same seeds:

- **billed input tokens per solved task** (cached + uncached, as in §0.2) — the claim this plan
  makes; must drop;
- `pass^2` — must not fall (non-inferiority);
- `not_observed` / `stale_file` rate, reads per edit, duplicate-read count;
- cache hit ratio — P1/P2 from EVAL.md §5.1 must still hold;
- **quality at a real window:** the `full` arm (route window, no reduction) against the 12K arm
  on the `long` tasks — does a context that is never reduced lose facts that a compacted one
  keeps, or the reverse? Reported as a finding either way.

Stop rule: if billed tokens per solved task do not drop, or `pass^2` falls, that is recorded as a
finding with the traces, not tuned away. Real-model runs share WP9's blocker (the DeepSeek account
has no balance).

---

## 7. Work packages, in build order

**The round order and the gates live in [GOAL.md](GOAL.md) §Loop** — one authoritative table, mirrored
in STATUS.md. This section is the per-package scope. Every round runs the substituted gate GOAL.md
names, and every round's tests must be **red at its parent commit** first.

| WP | Scope | Licenses |
|---|---|---|
| FC0 | Owner decisions F1–F8; prompt text for `file_references.md`, `outside_changes.md`, `editing.md`, `handoff.md`. | — |
| FC1 | The route's window as **data with its source and date** (`data/model_windows.yml`), resolved by `ModelClientFactory`, used by the `tamoz-code` arm; README/CLI docs; `tamoz-code-small` re-labelled an artificial compaction arm. Also restores A3/A4: the scorecard install list (`test/packaging_test.rb:93`) must name both phase-1 gems. | F-0, G-24 |
| FC2 | `tamoz-tools`: context diff and text-to-text diff, read byte cap, `not_observed`/`stale_file` codes. `tamoz-context-engine`: `observes`, `visible_matching`. | F-5 |
| FC3 | Session: observation ledger with retained bytes, gate pinning, default read window, dedup, the outside-change pass, secret scrub on the retained bytes. Bumps `WORK_GRAPH_VERSION`. | G-14, G-15, G-17, G-21, G-25 |
| FC4 | `tamoz-harness`: `FileReferences`, prompt files. Session: references in the opening; per-file guidance digests and the guidance change/removal notice (§3.11). | G-13 |
| FC5 | Session: change ledger, diffstat at finish/handoff/compaction; `Handoff.note(changes:)`. Bumps `WORK_GRAPH_VERSION`. | G-18, G-20 |
| FC6 | Rewind (F3): `restore_file`, policy row, rewind intake, CLI and chat. Bumps `WORK_GRAPH_VERSION`. | G-19 |
| FC7 | `Pruner` superseded pass — **after FC3**, which produces its `current: {key ⇒ version}` input; a work-loop test, not only the unit test, must show the pass running under pressure. | G-16 |
| FC8 | Eval offline: the scripted work-loop tests, the **positive loop-level cell** (§6.2c), the new tasks, `prefix_breaker` as a real control, `rake agenteval:prove`. Also the **join key** §8.3 needs: `session_id`/`thread_id` on every `Agenteval::Result`, one trace file per trial, and duplicate-read / short-form counters on `ContextEngine::Trace`. | §6.2, F14 |
| FC9 | Wire the `ctx-window`, `ctx-dedup`, `ctx-fresh`, `ctx-mention` and `ctx-positive` arms into `HARNESS_ARMS` (prepared, not run: see STATUS.md for the two route blockers). | F15 |
| ~~FC10~~ | **Dropped** (§3.9) — every component is turn-constant; no construction reaches an append-on-change. | — |
| ~~FC11~~ | **Dropped** (§3.10) — 0 occurrences measured; no construction reaches it. | — |

**Sequencing.** FC3, FC5 and FC6 each add a state channel and bump the graph version. R1 adds none. Active-investigation WP4 is plan-only and rebases onto the
phase-2 graph afterwards (GOAL.md §Loop).

---

## 8. Owner decisions (decided 2026-09-23)

All eight taken as recommended; recorded in [GOAL.md](GOAL.md) so an implementation round does not
re-litigate them. F1–F8 below.

**Parity numbers.** Where this plan sets a number, it either matches DSH's package default or DSH's
deployed configuration. DSH's deployed base bundle
(`packages/bundle/base/cordis.patch.yml`) is the authority for the second column, and the two
places Tamoz had been stricter are called out: a smaller spill budget and a smaller read window
mean more, smaller appends — cheaper per step, more round trips. That trade needs to be a decision,
not an accident of copying package defaults.

| Setting | DSH deployed | This plan | Note |
|---|---|---|---|
| `context_window` | 1,000,000 (`deepseek-v4.1-flash`), 262,144 (other routes) | route's real window | §3.0, FC1 — the measurement's main finding |
| spill `max_inline_bytes` | 50,000 | 8,192 → **50,000** | Currently under DSH by 6×; larger means fewer `recall_output` round trips and more re-billed bytes. Recommend matching DSH and letting the pruner bound it later. |
| prune threshold / head / tail | 8,192 / 4,096 / 1,024 | same | exact parity |
| compaction threshold / retain / summary cap | 0.8 / 0.16 / 8,192 | same | exact parity |
| compaction retries | `compactionRetries: 1` **and** `maxOverflowRetries: 1` | one `overflow_retries: 1` | Tamoz folds two distinct DSH knobs into one; acceptable while both are 1. |
| read window | 2,000 lines (default *is* the max), 2,000 chars/line, 50 KiB bytes | 800 lines / 50 KiB | F4. Still stricter on lines, equal on bytes, so an ordinary file arrives whole and the byte cap is the real bound. |
| runtime snapshot cadence | append only when the rendered text changes | once per turn; no change-detection | DSH’s dynamic set actually changes (clock, todos, goals); Tamoz’s is turn-constant, so FC10 was dropped |
| guidance budget | 65,536 bytes | 16,384 | Keep Tamoz's: project guidance is untrusted and opt-in (D4). |
| repeat guard | thresholds `[3, 5, 8]`, 500-char arguments preview | remind 3, 5; stop 8 | Tamoz stops where DSH only reminds; keep, but the reminder should carry the arguments preview. |

| # | Question | Recommendation |
|---|---|---|
| F1 | Allow `@path:120-180` ranges in references? | **Yes.** Still a pointer, still no content; it tells the model which lines the user means, and the read that follows is smaller. |
| F2 | Inline small referenced files eagerly instead of lazily? | **No.** DSH never does, one read round trip is cheap, and a read records the observation an edit needs. At a real window an eagerly inlined file is re-billed on every later step whether or not it was needed. |
| F3 | Build rewind now? | **Yes, as FC6, operator-only.** It is small once the ledgers exist, and it is the real value behind "shadow-git". No model-callable revert. |
| F4 | Read defaults | **800 lines and a 50 KiB byte cap**, per model route in the context policy like the other thresholds — closer to DSH's 2,000 lines than the 300 first proposed, so an ordinary file still arrives whole and the byte cap is the real bound. |
| F5 | A real shadow-git repository? | **No** (§3.6). |
| F6 | Match DSH's deployed spill budget (50,000) or keep 8,192? | **Match DSH: 50,000.** One fewer round trip through `recall_output` is worth more than the bytes, because those bytes are re-billed at the cache rate rather than the uncached rate. The pruner bounds the tail later. |
| F7 | Build the runtime snapshot (FC10)? And series-boundary normalization (FC11)? | **Both dropped.** FC11 measured 0 occurrences (§3.10); FC10’s snapshot is turn-constant, so append-on-change is unreachable (§3.9). AGENTS.md forbids writing either without a construction path. |
| F8 | Guidance files: adopt DSH's change/removal notices, and its nested scope discovery? | **Notices yes, discovery no** (§3.11). The notice is the same mechanism as §3.2 and costs one appended diff; discovery grows untrusted guidance, which D4 and the opt-in budget argue against. |

## 9. Out of scope

- A file-system watcher. Outside changes are found by the cheap pass after each check and before
  each model step (§3.2), and at edit time.
- Path completion as the user types (no interactive editor on either surface).
- Symbol outlines or an index for large files (§3.3, deferred until the eval asks for it).
- Continuous `AGENTS.md` rediscovery after edits (DSH does it; CONTEXT-ENGINE.md §4 explains why
  Tamoz does not).
- Rewinding more than the last turn, or rewinding a single file.

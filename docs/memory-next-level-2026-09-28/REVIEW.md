# Tamoz memory — current-state review (2026-09-28)

Scope: every place Tamoz keeps, compacts, stores, recalls, corrects, or forgets state
for the agent, reviewed against HDBK-006 *Memory & Context Management* (v1.3,
`~/ai-projects/articles/ready/HDBK-006-memory-context-management/chapter.md`) and the
repo's own contract (`docs/design-v0.1/MEMORY_DESIGN.md`, `docs/P11_MEMORY_PLAN.md`,
ADR-026/027).

Method: read the code end to end, traced callers with `grep` and enola
(`impact_analysis`), and ran two probe scripts against a real SQLite store (below).
Nothing here is inferred from plans alone; where a claim is a probe result it says so.

---

## 1. What exists

Tamoz has two memory systems that do not talk to each other.

### 1a. Working memory (per turn): `tamoz-context-engine` + the work route

| Piece | File | What it does |
|---|---|---|
| Append-only surface | `gems/tamoz-context-engine/lib/tamoz/context_engine/surface.rb` | the log the model's messages derive from; replacement entries shadow ranges, nothing is deleted |
| Spill | `.../context_engine/spill.rb` | tool output over 8 KB goes to the content-addressed artifact store behind a stub with locator, size, head/tail preview; `recall_output` reads it back |
| Pruner | `.../context_engine/pruner.rb` | model-free head/tail trim of old oversized tool results |
| Compaction | `.../context_engine/compaction.rb` + `prompts/compaction_instruction.md` | balanced span selection; 11-section checkpoint (`Primary Request`, `Plan State`, `Decisions`, `Ruled Out`, `Exact Strings`, `Offloaded Artifacts`, …); `validate!` refuses a summary that drops a section, is not smaller than its source, or loses a path a mutating tool touched |
| Policy | `.../context_engine/policy.rb` | threshold 0.80, backstop 0.92, retain 0.16 of the window; 1 compaction per turn |
| Driver | `gems/tamoz-agent-session/lib/tamoz/agent/work_compaction.rb` | prune → compact at a boundary → on a second pressure event, reset to a handoff note (max 2) → exhausted |
| Meter / trace | `.../context_engine/token_meter.rb`, `trace.rb`, `usage.rb` | per-request estimate vs provider usage with calibration |

The plan route has its own, separate compactor (`BoundedCompactor`, driven by the
`/compact` control in `session_context_controls.rb`).

**Across turns** a work turn starts a fresh surface (`SessionWork#intake`,
`session_work.rb:21`). What it carries from earlier turns:

- the conversation transcript: `Tamoz::Core::TurnContext` keeps at most
  **12 fragments, each clipped to 500 bytes, 8 KB total** (`turn_context.rb:13-15`);
- the previous turn's answer (CLI only) and its `work_plan`.

The compaction checkpoint a turn produced is **not** carried. It dies with the turn.

### 1b. Durable memory: `tamoz-agent-memory` (three layers, P11)

| Piece | File | Status |
|---|---|---|
| `MemoryRecord` — immutable, versioned, digest-addressed; layer / class / state / epistemic kind / source refs / scopes / sensitivity / validity / supersession / use counts | `memory/record.rb` | solid |
| `Admission` — deterministic, provider-free; three gates (episode, owner request, consolidation); default rejection is a durable `:rejected` record | `memory/admission.rb` | solid |
| `VerifiedOutcomeReference` — `:observed` only with an authenticated reconciled Outcome (stream) | `memory/verified_outcome_reference.rb` | solid |
| `MemoryStore` — Store version + index row in one transaction; authorization in SQL before materialization; sensitive statements never searchable; purge after retention | `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb` | solid storage; weak matching (§3) |
| `Retrieval` — rank, budget (1,024 tokens, ≤ 8 automatic), trace marks, anti-self-ingestion | `memory/retrieval.rb` | defects (§3) |
| `Lifecycle` — correct / supersede / quarantine / delete + receipt / purge | `memory/lifecycle.rb` | no production caller; receipt overclaims (§3) |
| `Consolidation` — gates → one journaled model call → admission gate (c) | `memory/consolidation.rb` | no production caller |
| `Wisdom` + `BehaviorTransition` + `TransitionRegistry` — holdout, human gate, pinned behavior versions, cache epoch | `memory/wisdom.rb`, `behavior_transition.rb`, `transition_registry.rb` | solid; used by `Improvement::Promotion` |
| `SituationRecaller` — stream-side recall of verified Experience only | `memory/situation_recaller.rb` | solid |

### 1c. Where the live agent touches durable memory

Enabled only when the operator turns on the `memory` source
(`worker_runtime.rb:928-935`).

| Path | Write | Read |
|---|---|---|
| Plan route (`route` / `deliberate` / `step_*`) | episode at `terminal` if verification satisfied (`session_lifecycle.rb:48` → `session_memory.rb:84`) | `add_memory_context` in `action`/`repair` phases, automatic recall on the task text (`session_planning_context.rb:573`) |
| Work route (the coding / chat loop) | **none** — `completed?` accepts only plan-route reasons (`completed`, `check_passed`, …); work turns end `done` / `verified_no_changes` / `reported` (`session_memory.rb:100`) | **none** |
| CLI `tamoz ask` / `tamoz code` | **no memory at all** — `build_durable_session` (`cli.rb:628`) passes no engine; memory exists only in `WorkerRuntime` | — |
| Stream worker | `:observed` episodes from reconciled outcomes (`live_learning_handlers.rb:85`) | `SituationRecaller` via `situation_memory.rb` |
| Owner "remember this" | **not wired** — `admit_owner_request` has no production caller | — |
| Correction / forgetting | **not wired** — enola: `Engine#lifecycle` "is called only from specs" | — |
| Consolidation (Experience → Knowledge) | **not wired** — no caller outside the gem and tests | — |

---

## 2. What is already good (keep it)

Tamoz is ahead of most agent frameworks on the governance half of the chapter.

- **Authorization before ranking, in SQL** (chapter §3 read path, rule 1). Scope,
  state, sensitivity, validity, and compatibility are bound as parameters; an
  unauthorized row is never materialized or decrypted.
- **Write default is "do not persist"** (chapter §4). Admission is deterministic, has
  eleven named reject reasons, and a model can only propose.
- **Epistemic kind instead of invented confidence** (chapter §3 record). `:observed`
  needs an authenticated outcome; a model summary is never `:observed`.
- **Anti-self-ingestion** (chapter §7 "feedback loop"). Recalled records are marked and
  refused as new evidence.
- **Versioned, append-only records with supersession** (chapter §4 "merge, don't
  accumulate" — the mechanism, not yet the policy; see F6).
- **Wisdom is gated behaviour, not text** (chapter's "procedural = reviewed skills,
  policy, or code"). Holdout, human gate, pinned behaviour version, cache epoch.
- **Working-memory compaction with invariants** (chapter §2's six properties). The
  11-section schema, `validate!`, required exact strings, spill with addressable
  locators, fail-closed reset/handoff. This is close to the chapter's reference design.

---

## 3. Defects and gaps

Ordered by how much they stop memory from helping today.

### F1 — Automatic recall injects Experience (design violation) — probe-confirmed

`MEMORY_DESIGN.md` §5 and P11 §4: "Experience is not injected into every prompt."
`Retrieval#recall(automatic: true)` drops only sensitive rows
(`retrieval.rb:63`); `add_memory_context` passes no layer
(`session_planning_context.rb:579`).

Probe (`probes/probe_recall.rb`, real SQLite): after one work-style episode,
`recall(automatic: true, terms: ["login"])` returned `[[:experience, "mem.4a9566cc"]]`.

### F2 — Lexical match ANDs every word of the task — probe-confirmed

`MemoryStore#match_clause` joins one clause per term with `AND`
(`memory_store.rb:709`); the caller passes the whole task, split into words, stop
words included. Any word in the new task that is absent from the old statement kills
the match.

Probe, same episode ("Episode for task fix the failing login test…"):

| Query | Result |
|---|---|
| `fix the failing login test` (identical task) | hit |
| `login test` | hit |
| `the login test is failing again` | **nothing** |

So in practice automatic recall fires only when a task is repeated almost word for
word. Durable memory is close to write-only.

### F3 — Ranking has no relevance term

`rank_score` (`retrieval.rb:113`) is `base_quality + source_quality + freshness −
penalties`. The plan's "relevance" term is absent, `base_quality` defaults to 0.0 and
nothing ever raises it, and `use_counts` is never incremented anywhere (grep: the only
reader is the penalty). Among matching records, order is effectively "most sources,
newest".

### F4 — The work route neither writes nor reads durable memory; the CLI has none

The loop users actually talk to (`tamoz code` / chat → `SessionWork`) never admits an
episode: `SessionMemory#completed?` (`session_memory.rb:100`) accepts only the plan
route's terminal reasons, and a work turn ends `done`, `verified_no_changes`,
`reported`, `answered`, `done_unverified`, or `handed_off` (`Harness::Finish`,
`session_work.rb:170`). It reads nothing back either. The CLI's durable session
(`cli.rb:628`) is built without a memory engine at all; memory exists only inside
`WorkerRuntime`.

### F5 — Episode content is weak evidence

`SessionMemory#episode_record` (`session_memory.rb:106`):

- statement = task + the **whole final answer** (truncated at 4 KB), so the record is
  mostly prose the user already saw;
- `decisions` = the last three plan ids (always empty on the work route);
- `corrections: []` always; `confidence: 0.9` hard-coded;
- identity = digest of the statement, so the same lesson worded differently is a new
  memory, and the same task with a different answer never supersedes.

The turn already produced a better source: the 11-section compaction checkpoint and the
verification evidence. Neither is used.

### F6 — No subject key, so corrections accumulate instead of superseding

Identity is `sha256(statement)` for every gate (`admission.rb:189,222,333`).
"Prefer rspec" and later "Prefer minitest" are two unrelated active records; retrieval
may return both and leave the model to arbitrate (chapter §3 rule 4 violated). The
`supersession_key` field exists but is used only as a back-link to the prior digest.

### F7 — Deletion receipt overclaims — probe-confirmed

`probes/probe_delete.rb`: owner-admit one record, then `lifecycle.delete`:

```text
"removed"=>{"primary_record"=>1, "index_rows"=>2, "derived_consolidations"=>2, ...}
```

- `index_rows` are not removed at delete time; they stay until `purge`.
- `derived_consolidations` counts `LIKE %memory_id%` over the namespace's versions —
  it counted the record's **own two versions**. Nothing derived is touched.
- Consolidated Knowledge copies the candidate's `source_refs` (`consolidation.rb:285`)
  instead of citing the source memory ids, so lineage for a real deletion cascade does
  not exist.

This is the "deletion shadow" failure (chapter §7) plus a receipt that says otherwise.

### F8 — Cross-turn working memory is 12 × 500 bytes

A long chat keeps only the last ~6 exchanges, each clipped to 500 bytes
(`turn_context.rb:13-14`). The turn's compaction checkpoint — the structured state the
chapter says should survive (goal, constraints, decisions) — is discarded at turn end.
An early correction ("use the corrected vendor name") is lost after six turns unless it
was admitted to durable memory, and nothing admits it (F9).

### F9 — Knowledge has no live write path

No `/remember`, no `/forget`, no `/memories`, no consolidation runner. Knowledge — the
layer that should hold preferences, project facts, and corrections — is empty in every
real deployment.

### F10 — No explicit recall tool

The design's intended use of Experience is *explicit* retrieval, but the model has no
tool for it. Spilled output has `recall_output`; durable memory has nothing.

### F11 — Budget accounting stops at the engine boundary

The context engine logs estimate vs usage per request, but the memory injection budget
(1,024 tokens) is a separate number with no component line in the work trace, and
automatic-injection ids are only emitted when a `trace:` is passed (the planning
context passes none).

### F12 — Two compactors

`BoundedCompactor` (plan route `/compact`) and `ContextEngine::Compaction` (work route)
do the same job with different schemas and validators.

---

## 4. Scorecard against HDBK-006

| Chapter requirement | Tamoz today |
|---|---|
| §1 context is a budget; output reserved first; per-component accounting | partial: threshold/backstop ratios + meter; no memory component line (F11) |
| §2 working memory = structured checkpoint, not transcript | **yes within a turn**; no across turns (F8) |
| §2 compaction fails closed, required state explicit, evidence addressable | yes (`validate!`, spill locators, reset/handoff) |
| §2 sessions resume, don't restart | durable graph resume yes; conversational state no (F8) |
| §3 governed store, vector index is not the source of truth | yes (Store is the truth, index is metadata) |
| §3 hybrid candidate generation | no: prefix `LIKE`, ANDed (F2) |
| §3 resolve versions before prompt assembly | head-only yes; subject-level no (F6) |
| §3 calibrated abstention / empty result allowed | empty allowed; no relevance to calibrate (F3) |
| §3 retrieved content is data | yes in the planning context; to be kept when injecting into the work route |
| §4 write policy default-skip, purpose, authority, scope | yes (admission) |
| §4 merge, don't accumulate | no (F6) |
| §4 deletion as a write-path feature | mechanism yes, lineage and receipt no (F7) |
| §5 provenance on every record, poisoning controls | yes (source refs, epistemic kind, taint gate, secret gate) |
| §6 evaluate end to end against baselines | harness exists (DR-3 `MemoryTreatmentProfile`), never run on the work route or with a real model |
| §7 production signals (injected ids, zero-result rate, supersession hits) | mostly absent (F11) |

Bottom line: the **governance** is strong and the **usefulness** is close to zero. The
store is safe because almost nothing goes in and almost nothing comes out. The next
level is not more machinery. It is wiring the existing machinery into the loop users
use, fixing retrieval so it can find things, and measuring whether it helps.

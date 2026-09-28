# Memory — implementation plan

Design: [DESIGN.md](DESIGN.md). Bar: [QUALITY_BAR.md](QUALITY_BAR.md). Eval:
[EVAL.md](EVAL.md). Progress and red-at-parent evidence: [STATUS.md](STATUS.md).

## Owner decisions (2026-09-28)

| # | Decision |
|---|---|
| D1 | FTS5 with bm25 for search |
| D2 | Keep `TurnContext` 12 × 500-byte limits; carry the thread checkpoint instead |
| D3 | Add `recall_memory`; design movement between layers and injection (DESIGN §3–§5) |
| D4 | Memory stays opt-in until the real-model eval passes; then the owner decides the default |
| D5 | Experience retention 90 days |
| D6 | Three layers = Experience / Knowledge / Wisdom |

## Rounds

Order: eval first (red), then the code that turns each row green. One round = one
reviewed unit. Rules from AGENTS.md apply throughout: extend existing seams, no
compatibility code (memory rows may be reset), next migration ordinal, prompts as files,
no model call outside the journal.

| Round | Content | Bar rows | Seams touched |
|---|---|---|---|
| R0 | enola `set_baseline`. Offline spec suite + retrieval corpus + controls, run red at the parent; record in STATUS.md | all B–E as pending; F1 met | `test/` only |
| R1 | Retrieval: automatic = Knowledge only; FTS5 table in the memory append/purge transaction; OR query with stop words; bm25 relevance in rank; honest deletion receipt; `project: "*"` user scope; Experience `valid_until` 90 days | B1–B7, C5 (receipt), C6, C8 | `tamoz-sqlite` `MemoryStore` + migration; `tamoz-agent-memory` `Retrieval`, `Lifecycle`, `Admission`, `Limits` |
| R2 | Knowledge keys + lineage: `subject_key` on the record and index; `remember` path (quote check, key supersession); `forget`; `memory:` lineage refs in consolidation; cascade quarantine | C3, C4, C5, C7 | `tamoz-agent-memory` `MemoryRecord`, `Admission`, `Lifecycle`, `Consolidation` |
| R3 | Work route: W1 episodes from turn facts; memory tools (`recall_memory`, `remember`, `forget`) as harness tools offered only when memory is on; Knowledge brief at intake; `memory_injected` trace; `memory_unavailable` | C1, C2, E1–E4 | `tamoz-agent-session` `SessionMemory`, `WorkContext`, `WorkTools`, `WorkGate`; `tamoz-harness` prompt files |
| R4 | Thread checkpoint carried across turns; `validate!` drift rule | D1–D3 | `SessionWork`, `WorkCompaction`, `ContextEngine::Compaction` |
| R5 | CLI: memory engine on `<session-dir>/memory.sqlite3` when the runtime directory enables it; `tamoz memory list|show|forget|consolidate` | E5 | `tamoz-agent-cli` |
| R6 | Memory pack: `SessionChain` runner, six scenarios, controls, validator, `agenteval:memory:prove` | F2–F4 | `agenteval/` |
| R7 | Real-model run, memory-on vs memory-off; findings note | G1–G4 | — |

M4 (Knowledge → Wisdom candidates) stays deferred until R7's report shows Knowledge helps.

## Why harness tools, not a capability source

`recall_memory` / `remember` / `forget` touch no workspace and no external system, like
`recall_output` and `update_plan`. Making them a fifth capability source would widen the
sealed four-source registry (invariant 42) and the approval policy for a tool whose only
effect is on the agent's own memory. The authority check for writes is structural (the
verbatim user quote), so no approval prompt is needed; the tools are offered only when the
operator enabled memory.

## Risks

| Risk | Control |
|---|---|
| FTS row drifts from the record head | written and deleted in the same transaction as the Store append/purge; B5 checks it |
| The brief crowds the window on small models | fixed 1,024-token cap, traced; G3 reports the real cost |
| A model ignores the brief or never calls `recall_memory` | that is what G1 measures; prompt wording is a file and can be tuned against the pack |
| Quote check is too strict (the model paraphrases) | the tool result tells the model to quote verbatim; refusals are counted in the report |

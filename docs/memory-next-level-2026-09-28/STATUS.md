# Memory — status

Parent of the work: `8b586046` (branch `improve-agent-memory`).

| Round | State | Rows met | Rows pending | Review | Notes |
|---|---|---|---|---|---|
| R0 | done | F1 | B1–B7, C1–C8, D1–D3, E1–E4 (24) | sub-agent: 18 findings, all addressed (tests strengthened, re-run red at the parent) | eval written before any code |
| R1 | done | B1–B7, C6 | — | sub-agent (R1–R5): 14 findings; all fixed except #8 in part (see below) | FTS5 (unicode61) + query-side suffix/prefix rule; porter was dropped because it stems `deploy`→`deploi` and loses prefixes |
| R2 | done | C3, C4, C5, C7, C8 | — | same review | `Memory::Knowledge` (remember/forget on a verbatim user quote), `subject_key`, lineage refs, cascade quarantine |
| R3 | done | C1, C2, C3.route, E1–E4 | — | same review | `WorkMemory`; brief pinned after guidance; `work_changes`/`work_checks` channels; Wisdom-registry failure still fails closed |
| R4 | done | D1, D2, D3 | — | same review | `work_checkpoint` carried; `validate!(previous:)` |
| R5 | done | E5 | — | same review | CLI memory on `<session-dir>/memory.sqlite3`; `tamoz memory list|show|forget|consolidate` |
| R6 | done | F2, F3, F4 | — | sub-agent: controls replayed scripted answers, MP3 guessable, MP4 unmeasurable, MP5 gate too broad, no cost data; all fixed, MP4 dropped | `Agenteval::SessionChain`, six scenarios, four controls; `rake agenteval:memory:prove` |
| R7 | done | G2, G3, G4; G1 as a finding | — | — | [RESULTS-20260928.md](RESULTS-20260928.md): excluding MP1, memory-on 7/8 vs memory-off 2/8; hard gates 0/0 |

## Red at the parent

Parent `8b586046`, working tree with only the R0 test files added.

```text
ruby -Itest test/memory_retrieval_corpus_test.rb  → 3 runs, 0 failures, 2 skips  pending: B2, B7   (F1 passes)
ruby -Itest test/memory_spec_test.rb              → 12 runs, 0 failures, 12 skips pending: B1 B3 B4 B5 B6 B7 C3 C4 C5 C6 C7 C8
ruby -Itest test/memory_work_route_test.rb        → 10 runs, 0 failures, 10 skips pending: C1 C2 C3 D1 D2 D3 E1 E2 E3 E4
```

Reasons at the parent, one line each (from the skip messages):

| Row | Why it is red at the parent |
|---|---|
| B1 | automatic recall returns the matching Experience record; `Retrieval#brief` does not exist |
| B2 | no brief; paraphrase queries return nothing (AND-prefix matcher) |
| B3 | two records match `parser`; the newer, less relevant one ranks first (no relevance term) |
| B4 | no `tamoz_memory_fts` table |
| B5 | the episode is still returned after 120 days (no default expiry); no FTS table |
| B6 | no brief |
| B7 | `the is a it` returns a record (stop words prefix-match) |
| C1 | a `done` work turn admits no Experience (`completed?` accepts only plan-route reasons) |
| C2 | no Experience record to inspect |
| C3 | no `Engine#knowledge`, no `Surface.project_scope`, no `remember` tool |
| C4, C5, C8 | no `Engine#knowledge` |
| C6 | the episode is recalled after 91 days |
| C7 | no `Consolidation#candidate_from`, no lineage refs |
| D1 | turn 2's opening does not contain turn 1's checkpoint |
| D2 | `Compaction.validate!` takes no `previous:` |
| D3, E1, E2, E3 | no `Surface.project_scope`; no brief in the work route |
| E4 | a closed memory store raises out of the turn (`SQLite connection pool is closed`) |

## Offline numbers (R1, real retriever on the labelled corpus)

`test/memory_retrieval_corpus_test.rb`, 28 queries over 20 records: recall@5 **1.0**, mean
precision@5 **0.92**, scope/sensitivity/lifecycle/layer violations **0**, budget violations
**0**. The remaining noise comes from common words (`run`, `name`) matching unrelated records
(qr4, qr18). These are plumbing numbers on a hand-labelled corpus, not a model result.

## Not covered offline

- C1: the `reported` and `cancelled_by_user` endings are not driven by the test (five of seven
  endings are).
- MP1 was redesigned after the first run and re-run: memory-on 3/3, memory-off 0/3 (RESULTS).

## R1–R5 review: what changed

| # | Finding | Fix |
|---|---|---|
| 1 | `forget` accepted any user substring | the quote must name the record (key, or two of its words) |
| 2 | a child task's (model-written) text counted as the user's | child sessions get no memory engine |
| 3 | restating a key skipped the secret check | `remember` refuses secret-shaped quotes before any write |
| 4 | a substring could reverse meaning ("deploy on Fridays" from "never deploy on Fridays") | quotes must be whole clauses |
| 5 | `forget` by id ignored the project | resolved only inside the caller's project or user scope |
| 6 | identities were statement-only (cross-project collisions; identical episodes in two sessions merged) | Knowledge keyed by owner + project; Experience by session + statement |
| 7 | nothing tombstoned expired Experience; `recall_memory {id}` returned expired records | `Lifecycle#sweep` after each episode; `visible?` checks `valid_until` |
| 8 | memory writes run outside the effect journal | writes made idempotent (replay changes nothing); the intake brief is re-read on replay but the journaled request is built from checkpointed state |
| 9 | CLI consolidation grouped on shared labels and never marked groups consumed | grouping on the task line (`Memory::ExperienceGroups`); deterministic candidate identity |
| 10 | stream episodes started expiring after 90 days | expiry applies only to self-reported Experience; reconciled (stream) Experience does not expire |
| 11 | the store trusted callers not to index sensitive text | `replace_fts_row` refuses sensitive rows itself |
| 12 | brief profile capped at 200 rows ordered by id; restated records sorted by creation | queried by class; ordered by latest version time |
| 13 | `tamoz memory` scoped by `--root`, sessions by the toolbox root | same root rule as the session (profile root, else `--root`, else cwd; realpath) |
| 14 | brief/recall rescued only `Tamoz::Error` | any read failure degrades to no memory, traced |

## Gates at the end of R6

- `rake ci`: all 276 test files pass. `stream:proto:check` fails on this machine because the
  bundled `protoc` is an x86_64 binary (`Bad CPU type`); unrelated to memory.
- RuboCop: no new offense in any linted file I changed (`agenteval/**` is excluded by config).
- enola `diff_snapshot`: no cycle, no layer violation; two dead-method notes are false
  positives (`cmd_memory` is dispatched through the subcommand table; `integrity_check` is untouched).

## Multi-lens review of PR #57

| Lens | Finding | Outcome |
|---|---|---|
| Security | a stored statement containing `</memory>` could close the data block and put text outside it | fixed: the tag is escaped when rendered; test `test_e2_a_statement_cannot_close_the_memory_block` |
| Security | `tamoz memory forget <id>` deleted any record by id, unlike `show` | fixed: only records of this owner and project; test in `agent_cli_memory_test.rb` |
| Eval validity | arms ran back to back (all memory-on, then all memory-off), so provider drift could favour one arm | fixed: arms alternate trial by trial |
| Eval reporting | the injected-token p50/p95 counted first sessions (always 0) | fixed: over sessions that received a brief, with their count |
| Docs | DESIGN §5 described the brief as "all profile records first"; the code gives the profile half the slots | fixed |
| Durability | the intake brief and memory tools are plain reads/writes inside a node, not journaled effects | no change: intake commits its entries before any model call reads them, and memory writes are idempotent, so a replay changes nothing |
| Correctness | could `work_changes` / `work_checks` leak into the next turn's episode? | no: probed; each turn starts from fresh state |
| Performance | `Lifecycle#quarantine_derived` loads all active Knowledge on every delete; `sweep` runs after each episode | accepted for now: stores are small; revisit when a store has thousands of Knowledge records |

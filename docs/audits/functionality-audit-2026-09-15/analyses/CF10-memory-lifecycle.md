# CF10 — memory admission, retrieval, deletion, consolidation, and transitions — IMPROVE

## Row, boundary, and method

- **Row:** CF10 — memory admission, retrieval, deletion, consolidation, and transitions.
- **Code baseline:** branch `audit-15-09`, source commit `582ae5566de1ae073aea82b69bb2bbf444494d3b`.
- **Analyst:** coordinator direct source review after the memory challenge and the CF09 synthesis; no subagent was used for this continuation.
- **Method:** traced admission through the store and retrieval paths, exercised deletion and retention against a real temporary SQLite database, re-read the existing challenge correction, and ran focused memory/transition suites. No production, test, configuration, generated, or unrelated documentation file was changed.

## Source map and ownership

| Source | Boundary role |
|---|---|
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/admission.rb:77-155,242-350` | admission gates and immutable record creation |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb:118-160,198-243,306-391` | atomic append, authorized search, purge, and retention pass |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/retrieval.rb:51-174` | authorization result ranking and bounded injection |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/lifecycle.rb:77-114,197-249` | delete tombstone and deletion receipt |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/consolidation.rb:90-222,243-291` | deterministic consolidation gates and journalled model call |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/transition_registry.rb:70-243` | behavior transition claim/finalize and crash recovery |
| `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:887-915` | worker memory construction and maintenance ownership seam |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_planning_context.rb:567-591` | memory-to-planning boundary (CF09 finding carried) |

The memory gem owns policy and lifecycle values, SQLite owns durable rows and
physical purge, and the agent worker owns long-lived maintenance. The source
shows the first two halves but no worker call connecting them.

## End-to-end behavior path

1. `Admission#admit_episode` and `admit_owner_request` build immutable records,
   run the reject matrix, and append the record plus its index in one SQLite
   transaction (`admission.rb:77-155,242-350`; `memory_store.rb:118-160`).
2. Retrieval asks SQLite to authorize scope, state, sensitivity, validity, and
   compatibility before materialization, then ranks and budgets the result
   (`memory_store.rb:198-243,410-429`; `retrieval.rb:55-73,107-166`). The CF09
   automatic layer/trust omission is carried under that row's boundary finding.
3. `Lifecycle#delete` appends a deleted version and returns an invariant-54
   receipt. `MemoryStore#purge_expired` later finds the deleted index state,
   calls `purge`, and removes version, head, and index rows
   (`lifecycle.rb:77-114`; `memory_store.rb:306-391,484-529`).
4. Consolidation stages candidates, calls the model only through
   `EffectDispatcher.run`, validates preserved source references, and admits a
   Knowledge candidate (`consolidation.rb:90-222,243-291`). No production caller
   schedules this operation; that absence is recorded as an ownership gap, not a
   second retention finding.
5. Behavior transitions are recorded and claimed/finalized by session. The
   crash-recovery helper exists in the memory registry but is not called by the
   worker/session path; `F19-REL-01` is carried.

## Six-lens review

### Correctness

Admission, duplicate identity, scope isolation, active-head joins, correction,
and deletion state transitions are source-grounded and covered by passing
focused suites. The retention probe confirmed that the `i.state = 'deleted'`
branch makes agent-deleted records purgeable even when `h.deleted` remains zero.
The deletion receipt itself is not measured honestly; that is the existing
F19 receipt finding and is carried without another count.

### Security and authority

All caller scope and compatibility values are SQL binds, and the restricted
existence scan shares the authorization body (`memory_store.rb:400-429`).
Sensitive rows are excluded before materialization. The automatic layer/trust
boundary defect is `CF09-SEC-01`; CF10 does not count it again. No capability or
approval authority is reachable from the store or lifecycle path.

### Reliability and durability

Append plus index is atomic, deletion is a CAS append, and consolidation uses
the durable effect journal with a preimage before rewrite. The retention
operation is durable and idempotent, but it has no production caller. A process
restart therefore preserves every deleted row until an operator or test calls
the pass. This is `CF10-REL-01`.

### Observability and evidence

Admission results carry a reason and retrieval can emit recalled/dropped events.
The delete receipt reports `primary_record`, index, derived, cache, and queue
counts even though this call only appends a tombstone; the derived count can
match the record's own versions. `F19-DEL-01`/`F19-SEC-01` own that receipt
contract. The retention receipt is more honest because it is built from actual
SQLite change counts, but no production caller records it.

### Scalability and resource bounds

Statements, source references, lexical hits, query terms, token budget,
consolidation candidates, and purge selection are bounded by the existing
limits (`limits.rb:12-20`, `retrieval.rb:22,56,139-166`). Append-only versions
and the missing retention caller make durable memory growth unbounded in a
running worker. No sustained growth or multi-process retention run was made.

### Maintenance and architecture

The layer split is understandable, but the worker constructs `Memory::Engine`
and exposes only a small summary (`worker_runtime.rb:887-915`); it has no
maintenance contract for the memory store's declared retention pass. The
consolidation and transition helpers have the same “tested directly, unwired in
production” shape. Their ownership is carried to F19 and the worker seam rather
than creating duplicate findings.

## Focused tests and contracts

| Command | Runs | Assertions | Failures | Errors | Skips |
|---|---:|---:|---:|---:|---:|
| `ruby -Itest test/memory_engine_test.rb` | 26 | 164 | 0 | 0 | 0 |
| `ruby -Itest test/memory_store_test.rb` | 16 | 112 | 0 | 0 | 0 |
| `ruby -Itest test/memory_treatment_profile_test.rb` | 14 | 218 | 0 | 0 | 0 |
| `ruby -Itest test/memory_repository_adapter_test.rb` | 10 | 104 | 0 | 0 | 0 |
| `ruby -Itest test/memory_session_integration_test.rb` | 4 | 24 | 0 | 0 | 0 |
| `ruby -Itest test/improvement_candidate_test.rb` | 14 | 284 | 0 | 0 | 0 |
| `ruby -Itest test/agent_improvement_lifecycle_test.rb` | 6 | 13 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_skills_memory_test.rb` | 12 | 49 | 0 | 0 | 0 |

Total: **102 runs / 968 assertions / 0 failures / 0 errors / 0 skips**.
The deletion and retention probes were `/tmp/f19c_probe_delete.rb` and
`/tmp/f19c_probe_sweep_real.rb`. The latter removed the record from all three
SQLite tables; the former reproduced the delete-time receipt overclaim. No
full CI gate or production maintenance loop was run.

## Findings and coordinator disposition

### CF10-REL-01 — the retention pass has no production caller, so the flow's delete-to-purge bound is never enforced

- **Severity:** `major`
- **Confidence:** `high` for the missing caller and retention behavior; `medium` for the final worker hook because the worker maintenance seam is not yet specified.
- **Status:** `open`
- **Source evidence:** `MemoryStore#purge_expired` selects expired tombstones and calls `purge` (`memory_store.rb:373-391,484-529`); `Lifecycle#delete` makes the agent-deleted index state that query accepts (`lifecycle.rb:77-98`; `memory_store.rb:493-499`). `retention_default_seconds` is declared at `limits.rb:20`, but the worker only constructs and summarizes the engine (`worker_runtime.rb:887-915`). A production-caller sweep over `gems/`, `apps/`, `bin/`, and `script/` found no call to `purge_expired`, `Lifecycle#purge`, or the memory lifecycle entry point.
- **Test/contract evidence:** the focused suites above pass. `TAMOZ_ROOT=$PWD ruby /tmp/f19c_probe_sweep_real.rb` removed the versions, head, and index rows after the retention boundary; the existing `challenge-memory.md` independently confirms the pass works and the caller is absent. No test asserts that a running worker schedules the pass.
- **Scanner signal:** repo-wide production-caller search for `purge_expired`, `lifecycle.delete`, and `retention_default_seconds`.
- **Independent judgment:** the F19 mechanism claim that `deleted: false` makes the pass unreachable is refuted by the SQLite `i.state = 'deleted'` branch and the real-store probe. The operational defect remains: no shipped worker invokes the working pass, so append-only deleted and superseded memory accumulates indefinitely. This is a cross-owner boundary finding; `F19-DEL-01` remains the memory-row record of the same retention symptom.
- **Root cause (five whys):**
  1. Deleted memory persists because no production path calls `purge_expired` or `purge`.
  2. The pass is exposed only on the SQLite/memory repository, while the worker owns the long-lived loop.
  3. `WorkerRuntime#memory_engine` constructs the engine but has no maintenance hook or retention obligation.
  4. Unit tests call the repository methods directly, so green tests do not prove worker reachability.
  5. No cross-gem contract binds the declared retention limit to a scheduled worker action. The preventing contract is a bounded worker maintenance step that invokes the existing pass and records its receipt.
- **Recommendation:** at the existing `tamoz-agent` maintenance/sweep seam, invoke `MemoryStore#purge_expired` through the configured memory engine using the worker clock and retain the returned receipt. Do not add another purge implementation or change the already-working tombstone predicate.
- **Disposition:** accepted as an open major boundary finding. `F19-DEL-01` is carried for the component symptom and corrected mechanism; CF10 owns the missing worker caller and is counted once here.

## Carried findings and rejected lead overlap

| Lead or finding | CF10 disposition |
|---|---|
| `F19-DEL-01` | Carried open major; same retention symptom, with its `deleted: false` mechanism corrected by the challenge. |
| `F19-SEC-01` | Carried open major for the deletion-receipt/content-boundary record; no second receipt count. |
| `F19-REL-01` | Carried open major for transition recovery with no production caller. |
| CF10-OBS-01 (lead) | Duplicate of the F19 deletion-receipt seam; the flow-level delete-to-retention observation is retained above, but it is not a second machine-counted finding. |
| Consolidation and transition “no caller” leads | Ownership notes carried to the worker/F19 rows; no new major because the retention caller is the only independently actionable CF10 boundary. |
| `CF09-SEC-01`, `CF09-OBS-01` | Carried as adjacent stream/planning findings; no duplicate count. |

## Blind spots

- The mixed expired/pending batch shape was not exercised; one expired record was enough to prove the working branch.
- Sensitive-record deletion and protection-codec behavior were not probed.
- No production consolidation caller or `tamoz-evals-runner` second engine was traced end to end.
- No multi-process worker maintenance, long-lived growth, or real model/provider run was used.

## Verdict

**IMPROVE.** All six lenses, the durable delete-to-retention path, and the
cross-owner maintenance boundary are reviewed. `CF10-REL-01` is an accepted
open major at the worker seam; the receipt and transition findings are carried
under F19 without double-counting. The retention implementation works when
called, but the running system has no caller, so CF10 remains open for the
overall audit until CF11–CF13 and the support-surface gates are synthesized.

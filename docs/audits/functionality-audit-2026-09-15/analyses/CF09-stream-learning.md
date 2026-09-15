# CF09 — supervised stream episode, evidence pull, learning loop, and reverse channel — IMPROVE

## Row, boundary, and method

- **Row:** CF09 — supervised stream episode, evidence pull, learning loop, and reverse channel.
- **Code baseline:** branch `audit-15-09`, source commit `582ae5566de1ae073aea82b69bb2bbf444494d3b`.
- **Analyst:** coordinator direct source review after the cross-flow scanner and the existing memory challenge; no subagent was used for this continuation.
- **Method:** read the source path and contracts end to end, re-read the relevant challenge evidence, ran focused tests with loopback access for fixture servers, and used bounded probes under `/tmp`. No production, test, configuration, generated, or unrelated documentation file was changed.

## Source map and ownership

| Source | Boundary role |
|---|---|
| `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb:438-506` | snapshot identity, request admission, and durable request handoff |
| `gems/tamoz-stream/lib/tamoz/stream/evidence_client.rb:77-95,208-249` | reverse evidence RPC and reply verification |
| `gems/tamoz-stream/lib/tamoz/stream/live_learning_handlers.rb:61-114` | reconciled outcome to memory admission |
| `gems/tamoz-stream/contracts/runtime-v1.proto:25-27` | pinned reverse-channel wire contract |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/admission.rb:242-340,374-385` | episode labels and active admission |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/retrieval.rb:51-73,177-202` | automatic retrieval and recall evidence |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb:198-243,410-429,684-710` | authorized search and layer/match predicates |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_planning_context.rb:567-591` | automatic memory-to-planning injection |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_memory.rb:13-82` | memory epoch and behavior-transition claim/finalize |
| `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/promotion.rb:38-65` | candidate promotion boundary |
| `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/evaluation_report.rb:220-235` | caller-supplied human-gate check |

The normal path is split deliberately: stream verifies the snapshot and the
reverse evidence reply, the durable request is owned by the graph/SQLite path,
memory owns admission and retrieval, and session owns planning-context
assembly. No reverse-channel message grants capability or approval.

## End-to-end behavior path

1. `EpisodeRunner#admit_request` verifies the snapshot digest and identity before
   the request enters the durable queue (`situation_request.rb:438-455,495-506`).
2. An evidence tool call crosses the unary `EvidenceTools::Call` RPC. The client
   checks the echoed identity, fence, UTF-8, and required digest before exposing
   the document (`evidence_client.rb:208-249`).
3. A reconciled outcome is verified, then
   `LiveLearningHandlers#reconcile_outcome` admits a completed episode. The
   `source_authority` equality is a real gate for an `:observed` record
   (`live_learning_handlers.rb:61-96`). A plain episode is stored as an active
   `:reported` Experience record (`admission.rb:328-350,374-385`).
4. The session planning path checks only that a memory epoch exists, calls
   `Retrieval#recall(automatic: true)` with no layer or trace, and copies each
   `record.statement` into `context['memory']`
   (`session_planning_context.rb:567-591`).
5. Candidate improvement is a separate path. `Promotion#promote` records a
   pending transition and its `EvaluationReport.assert_human_gate!` accepts a
   `human:` prefix; activation is later claimed and finalized by session
   (`promotion.rb:38-65`, `session_memory.rb:25-82`).

## Six-lens review

### Correctness

The snapshot and episode stream contracts are enforced: sequence and terminal
rules are bounded in `episode_worker.rb:177-196`, and a graph node cannot forge
a model event (`episode_stream.rb:191-196`). The reverse reply is checked before
use. The cross-gem gap is the automatic-retrieval contract: the method comment
promises Knowledge/Wisdom-only injection, while the implementation does not
enforce that layer set. This is recorded as `CF09-SEC-01` because an active
Experience row can enter the action planning context.

No existing test drives the complete stream admission, memory append, and later
session planning context in one process. The direct probe below does show the
relevant retrieval behavior against a real temporary SQLite store.

### Security and authority

The authority intersection remains intact. Memory records can request but never
grant capability (`documentation/architecture/security-model.md:9`), and the
reverse wire contract contains one evidence RPC only. The content boundary is
weaker: `automatic: true` only removes `sensitive` rows in
`retrieval.rb:58-64`; it does not enforce the documented layer and trust rules.
An Experience record admitted from the stream, and a reported Knowledge record,
are both returned by the automatic path when the task terms match. The existing
`F19-SEC-01` finding covers the separate framing problem (untrusted statements
are rendered verbatim); `CF09-SEC-01` covers the missing layer/trust policy
enforcement and therefore has a different owner seam and fix.

### Reliability and durability

The request and episode boundaries are durable and resumable, and the stream
crash/replay suites pass. Memory admission is append-only and the consolidation
model call is journalled. No cross-gem crash test proves the state after an
episode append and before the next planning turn; that remains an evidence gap.
The missing retention caller and transition recovery caller are owned by the
memory/worker rows and are carried here without another count.

### Observability and evidence

The stream logs the admitted memory id and epistemic kind
(`live_learning_handlers.rb:111-114`), and retrieval can emit `memory_recalled`
and `memory_dropped` events (`retrieval.rb:177-202`). The planning call site does
not pass a trace, so an admitted memory cannot be correlated with the later
turn that injected it. This is `CF09-OBS-01`, a bounded observability gap.

### Scalability and resource bounds

Request/event bytes, the evidence RPC pool, lexical hits, query terms, injected
records, statement projection, and retrieval token budget are bounded at
`episode_worker.rb:25-26`, `worker_server.rb:27,37`, `retrieval.rb:22,56,139-166`,
`limits.rb:12`, and `surface.rb:133`. No sustained stream-to-memory growth,
long-lived worker, or provider load was run. The uncalled retention pass is
reviewed under CF10/F19 rather than counted again here.

### Maintenance and architecture

Dependency direction is clean: stream injects a memory-admission port and memory
does not reach into session or approval. The lead's “human gate” major conflated
episode admission (automatic by design) with behavior promotion (a separate,
currently unwired path). The coordinator demotes that lead to an information
note and carries `F23-SEC-01` for the actual unbound promotion evidence. The
remaining maintenance action is to use one vocabulary for the two artifacts.

## Focused tests and contracts

Each command was run from the repository root, one test file per command. The
socket-backed commands were run with loopback access so their local fixtures
could bind; no external provider or network service was used.

| Command | Runs | Assertions | Failures | Errors | Skips |
|---|---:|---:|---:|---:|---:|
| `ruby -Itest test/stream_learning_loop_test.rb` | 17 | 84 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_skills_memory_test.rb` | 12 | 49 | 0 | 0 | 0 |
| `ruby -Itest test/memory_session_integration_test.rb` | 4 | 24 | 0 | 0 | 0 |
| `ruby -Itest test/stream_evidence_client_test.rb` | 10 | 40 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_end_to_end_test.rb` | 3 | 62 | 0 | 0 | 0 |
| `ruby -Itest test/stream_situation_recall_contract_test.rb` | 2 | 4 | 0 | 0 | 0 |
| `ruby -Itest test/stream_invariants_test.rb` | 9 | 212 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_replay_test.rb` | 3 | 15 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_crash_matrix_test.rb` | 2 | 18 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_stream_test.rb` | 8 | 76 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_worker_test.rb` | 8 | 24 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_capability_host_test.rb` | 9 | 441 | 0 | 0 | 0 |
| `ruby -Itest test/stream_situation_request_test.rb` | 11 | 55 | 0 | 0 | 0 |
| `ruby -Itest test/stream_situation_snapshot_test.rb` | 8 | 12 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_fixed_graph_test.rb` | 6 | 25 | 0 | 0 | 0 |
| `ruby -Itest test/stream_episode_intent_authority_test.rb` | 5 | 16 | 0 | 0 | 0 |
| `ruby -Itest test/memory_repository_adapter_test.rb` | 10 | 104 | 0 | 0 | 0 |

Total: **127 runs / 1,261 assertions / 0 failures / 0 errors / 0 skips**.
The pinned reverse contract is `runtime-v1.proto:25-27`; the repository proto
check was not run because it shells out to `grpc_tools_ruby_protoc`. No test
asserts that automatic retrieval excludes Experience or that a memory admission
is linked to a later planning turn.

## Findings and coordinator disposition

### CF09-SEC-01 — automatic retrieval ignores the documented layer/trust policy and injects Experience into action planning

- **Severity:** `major`
- **Confidence:** `high` for the source path and behavior; the source intermediary that creates a stream request is outside this row.
- **Status:** `open`
- **Source evidence:** the design requires Experience to be never automatic and Knowledge to be trusted (`documentation/design/memory.md:54,70-74`). `Retrieval#recall` documents the same policy but, when `automatic: true`, only rejects `sensitive` rows (`retrieval.rb:51-64`). The planning caller supplies no layer (`session_planning_context.rb:571-574`). SQLite's authorized search has no layer or epistemic predicate unless the caller supplies one (`memory_store.rb:203-243,410-429`), and episode admission always writes `layer: :experience` (`admission.rb:332-340`).
- **Test/contract evidence:** all 127 focused runs above pass, but no test asserts the automatic layer policy. `TAMOZ_ROOT=$PWD ruby /tmp/cf09_experience_auto2.rb` produced `AUTOMATIC after episode -> [["experience", ...], ["knowledge", ...]]`; `TAMOZ_ROOT=$PWD ruby /tmp/f19c_probe_auto2.rb` returned a reported Knowledge record from `automatic: true`.
- **Scanner signal:** none; the discrepancy was found by tracing the `automatic` flag through the retrieval and SQL seams.
- **Independent judgment:** the result was reproduced against a real temporary SQLite store and re-checked against the existing `challenge-memory.md` injection trace. This is distinct from `F19-SEC-01`: that finding is about framing untrusted statements, while this one is the missing layer/trust allowlist. The authority intersection still prevents a memory record from granting capability, so the consequence is prompt influence rather than an authority bypass.
- **Root cause (five whys):**
  1. Experience reaches action planning because `automatic: true` does not filter `layer: experience`.
  2. The retrieval implementation treats automatic mode as a sensitivity filter and leaves the repository query's layer unset.
  3. The session caller passes the task terms and a memory epoch but no executable layer/trust policy.
  4. The Knowledge/Wisdom-only rule exists in design text and comments rather than in the retrieval contract.
  5. The focused tests exercise admission, search, and planning separately and never assert the cross-layer automatic boundary. The preventing contract is an allowlist enforced before materialization: automatic mode may select only policy-approved Knowledge/Wisdom records, while Experience remains explicit.
- **Recommendation:** enforce the automatic layer/trust allowlist in `Retrieval#recall` before materialization (the existing `rows` metadata is already available), and add one regression assertion for an active Experience row. Keep the policy at this existing seam; do not add a second memory store or planner filter.
- **Disposition:** accepted as an open major. Existing `F19-SEC-01` is carried for the verbatim-content framing face and is not double-counted.

### CF09-OBS-01 — the planning turn is not correlated with the memory it injects

- **Severity:** `minor`
- **Confidence:** `high`
- **Status:** `open`
- **Source evidence:** `SessionPlanningContext#add_memory_context` calls `recall` without `trace:` (`session_planning_context.rb:571-576`), while `Retrieval#emit_recall` and `record_drops` emit only when a trace object is supplied (`retrieval.rb:177-202`). The stream admission log contains the memory id but no later planning join (`live_learning_handlers.rb:111-114`).
- **Test/contract evidence:** `memory_session_integration_test.rb` passes 4 runs / 24 assertions; no test or contract correlates an admission id with a planning turn.
- **Scanner signal:** none; found by comparing the only planning recall call with the trace-emitting branch.
- **Independent judgment:** confirmed the missing argument at the production call site. This is separate from the layer policy because its fix is evidence propagation, not admission or retrieval filtering.
- **Root cause:** the planning context predates the recall trace and the call site was never wired to the session turn's existing event/correlation channel.
- **Recommendation:** pass the current turn trace through the existing planning-context call chain and supply it to `recall(trace:)`, preserving the existing `memory_recalled` payload.
- **Disposition:** accepted as an open minor.

### CF09-MNT-01 — episode admission and behavior promotion use “human gate” for different artifacts

- **Severity:** `info` (lead was `major`)
- **Confidence:** `high`
- **Status:** `duplicate`
- **Source evidence:** episode admission writes `state: :active` after deterministic checks (`admission.rb:242-268`), while behavior promotion records a pending transition and checks a caller-supplied `human:` string (`promotion.rb:38-65`, `evaluation_report.rb:220-235`). The design makes episode admission automatic and reserves human approval for consequential Knowledge/Wisdom changes (`documentation/design/memory.md:48-64`).
- **Test/contract evidence:** `test/improvement_candidate_test.rb` proves the prefix check; the improvement gem has no approval-engine dependency or production caller. No contract names these two gates as the same artifact.
- **Scanner signal:** the lead's cross-gem vocabulary comparison.
- **Independent judgment:** the two gates are real but disjoint. The admission path is an accepted automatic design choice; the unbound promotion evidence remains `F23-SEC-01`. The lead's major grade would double-count that finding and overstate the episode path.
- **Root cause:** four components use “promotion,” “admission,” and “human gate” for different records without one vocabulary at the boundary.
- **Recommendation:** clarify the artifact-specific terms in the memory and improvement design docs and point the promotion gate to `F23-SEC-01`; no new runtime gate is justified by this evidence.
- **Disposition:** recorded as an information note and excluded from the machine-counted major/minor totals.

## Carried findings and overlap

| Finding | CF09 disposition |
|---|---|
| `F19-SEC-01` | Carried open major for verbatim untrusted-content framing; CF09-SEC-01 is the separate missing automatic allowlist. |
| `F19-OBS-01` | Carried open minor for the session admission result being swallowed. |
| `F19-REL-01` | Carried open major for transition recovery ownership; no second count. |
| `F23-SEC-01` | Carried open major for the unbound promotion evidence; CF09-MNT-01 is only its vocabulary face. |
| `F23-MNT-01` | Carried open major for the improvement-pipeline documentation contradiction. |
| `F06-SEC-01`, `F06-SEC-03` | Carried current stream/documentation notes; no new CF09 count. |

## Blind spots

- `rake stream:proto:check` was not run; the contract was read at the pinned proto source.
- The layer probe calls the real memory engine directly. It does not replace a full production stream-to-session integration test that admits through `LiveLearningHandlers` and then builds a planning context in one process.
- No real external evidence peer, model provider, or operator approval service was used.
- No sustained stream volume, long-lived worker, or cross-process crash was measured.
- The source intermediary that signs or admits an external stream request was not audited in this row; exploitability of an attacker-controlled episode remains bounded by that upstream contract.

## Verdict

**IMPROVE.** All six lenses and the end-to-end path are reviewed. The automatic
retrieval allowlist defect is an accepted open major, and the missing recall
correlation is an accepted minor. The existing content-framing, transition,
session-admission, and promotion findings are carried under their owning rows;
the lead's “two human gates” major is demoted to an information note. CF09 is
therefore complete as an analyst/synthesis row, while the overall audit remains
open until CF10–CF13 and the support-surface gates are reviewed.

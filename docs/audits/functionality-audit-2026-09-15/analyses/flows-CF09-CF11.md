# CF09 / CF10 / CF11 cross-gem flows — IMPROVE: the seams hold on authority and are open on ownership; two boundary defects are new to this row, and the rest is unowned machinery

Row / queue / baseline: CF09, CF10, CF11 / cross-gem flow inventory / branch `audit-15-09`, HEAD `582ae55`, 2026-09-15 / analyst `flow_cf09_cf11` (independent read-only) / budget 55 min (hard cap 60)

A flow row is not a re-audit of the gems. The 25 gem rows are done; this row tests the
boundary. Every finding below is a **boundary** defect — a contract two components
disagree about, or a hop whose owner is nobody. A gem's own finding is marked
"duplicate of X, boundary owner Y" and is not counted.

> **Coordinator note (2026-09-15):** This file is the bounded analyst lead for
> CF09–CF11. CF09 and CF10 now have coordinator syntheses in
> [`CF09-stream-learning.md`](CF09-stream-learning.md) and its machine record is
> [`CF09-stream-learning.json`](CF09-stream-learning.json), and
> [`CF10-memory-lifecycle.md`](CF10-memory-lifecycle.md) plus
> [`CF10-memory-lifecycle.json`](CF10-memory-lifecycle.json). Those syntheses
> correct the lead's CF09 count: the missing automatic layer/trust allowlist is
> the new major, the recall join is a minor, and the “two human gates” item is an
> information-level duplicate of the existing promotion finding. The lead's
> verbatim-content observation remains carried as `F19-SEC-01`; it is not counted
> again. CF10 retains only the missing worker retention caller as a new boundary
> major; its receipt observation is carried under F19. CF11 remains lead material
> until its own coordinator report is written.

## Scope and source map

Files read at source for the seam traces (flow-relevant regions, with line counts of
the whole file):

| File | Lines | Boundary role |
|---|---:|---|
| `gems/tamoz-stream/lib/tamoz/stream/live_learning_handlers.rb` | 223 | stream → memory admission (CF09) |
| `gems/tamoz-stream/lib/tamoz/stream/situation_request.rb` | 1008 | episode content; `episode_content_for`; admission gates |
| `gems/tamoz-stream/lib/tamoz/stream/evidence_client.rb` | 355 | reverse channel |
| `gems/tamoz-stream/contracts/runtime-v1.proto` | 366 | the pinned wire contract |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/memory_store.rb` | 723 | store, purge, tombstone scan, `match_clause` |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/admission.rb` | 478 | gates (a)/(b)/(c), `admit` |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/lifecycle.rb` | 253 | delete, receipt, `deletion_sinks` |
| `gems/tamoz-agent-memory/lib/tamoz/agent/memory/retrieval.rb` | 206 | authorize-then-rank recall |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_planning_context.rb` | ~600 | memory → planning context injection |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_memory.rb` | 129 | episode admission, claim/finalize |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb` | ~300 | `bounded_repair`, `repeated_failure` |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_nodes.rb` | — | `MAX_REPAIR_ATTEMPTS` |
| `gems/tamoz-agent-healing/lib/tamoz/agent/healing/remediation/session.rb` | 290 | the remediation state machine |
| `gems/tamoz-agent-healing/lib/tamoz/agent/healing/remediation/attempt_evidence.rb` | 58 | the transitions ledger |
| `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/promotion.rb` | 365 | promotion / rollback |
| `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/evaluation_report.rb` | 239 | the human gate |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/circuit_store.rb` | — | H3 durable circuit adapter |

**Entry seams.** `EpisodeRunner#admit_request` (`situation_request.rb:438`);
`Memory::Engine.new` (`surface.rb:55`, built at `worker_runtime.rb:897`);
`Healing::Remediation.run` (`remediation.rb:62`); `Improvement::Promotion#promote`
(`promotion.rb:38`).

**Prior work used as leads, not conclusions.** `analyses/F06-stream.md`,
`F19-agent-memory.md`, `F20-agent-healing.md`, `F22-agent-session.md`,
`F23-agent-improvement.md`, `challenge-memory.md`, `challenge-healing.md`,
`challenge-durable-effects.md`. Every load-bearing claim below was re-derived at the
source for this row; where I disagree with a lead I say so.

---

## CF09 — Supervised stream episode, evidence pull, learning loop, reverse channel

### Boundary owners and the contract each side believes it honors

| Hop | Owner | What crosses | Trust level | Contract each side believes |
|---|---|---|---|---|
| Situation boundary | `tamoz-stream` `EpisodeRequestEnvelope` + `ReceivedSnapshot.verify` (`situation_request.rb:438-446`) | wire request bytes → verified snapshot | **verified** (digest, domain `situation-runtime/snapshot/v1`) | worker: the snapshot is authenticated; header is subordinate |
| Evidence pull (reverse channel) | `tamoz-stream` `EvidenceClient` → peer `EvidenceTools` | one unary `Call`, identity echo + caps + opaque token (`contracts/runtime-v1.proto:25-27`) | **untrusted reply**, verified on return | worker: the peer returns evidence, never authority |
| Episode → durable request | `tamoz-stream` → `tamoz-graph`/`tamoz-sqlite` | `envelope.payload` | internal | the durable request survives; resumption is the peer's job |
| Deliberation | `tamoz-agent-kernel` fixed graph | frame, facts, recalled memory | facts/memory are **fenced user content** | the model never receives untrusted text as policy |
| Outcome reconcile | `tamoz-stream` `LiveLearningHandlers#reconcile_outcome` (`:61-78`) | `outcome.reconciled` CloudEvent | **peer-supplied**, `source_authority` checked against `event.source` (`:93`) | admission only for `:observed` |
| Memory write | `tamoz-agent-memory` `Admission#admit_episode` → `admit` (`admission.rb:77-95`, `:242`) | episode content hash (`situation_request.rb:611-632`) | `:reported` for a plain episode | the gate is on the **label**, not the content |
| Memory → later plan | `tamoz-agent-session` `SessionPlanningContext#add_memory_context` (`:565-591`) | `record.statement` **verbatim** | **untrusted text as prompt content** | the planning context trusts the memory engine |
| Improvement candidate | `tamoz-agent-improvement` `Promotion#promote` (`:38`) | heuristic + report + `human_gate_evidence` string | caller-supplied | `assert_human_gate!` is the human gate |
| Promotion → active | `tamoz-agent-memory` `TransitionRegistry#record`/`claim`/`finalize` | `:recorded` → `:activated` | internal | one engine owns activation |

### Behavior path, hop by hop

1. **Situation boundary admission.** `EpisodeRunner#admit_request`
   (`situation_request.rb:438-446`) → `ReceivedSnapshot.verify` (`situation_snapshot.rb:30-38`)
   → `verify_snapshot_identity!` (`:448-455`). Verified. The snapshot, not the header,
   is authoritative. **Trust crossing: verified bytes.**
2. **Evidence pull.** `EpisodeToolCall` → `EpisodeCapabilityHost#execute`
   (`capability_host.rb:92-104`) → `EvidenceToolAdapter#call` (`evidence_client.rb:302-311`)
   → `EvidenceClient#call` (`:77-95`). One unary RPC. **Trust crossing: untrusted reply,
   verified before use** (identity `:208-212`, fence echo `:214-218`, UTF-8 `:231-242`,
   mandatory digest `:244-249`).
3. **Deliberation.** Facts and recalled memory reach the model only inside the fenced,
   attributed user section (`episode_frame_builder.rb:116-155`), never as prompt text.
4. **Outcome reconcile → admission.** `LiveLearningHandlers#reconcile_outcome`
   (`:61-78`) → `admit_learnable_episode` (`:80-86`) → `admit_episode(row, data, event, intent_id)`
   (`:88-96`) with `verify_source_authority: ->(reference) { reference.fetch("source_authority") == event.source }`
   (`:93`). The `source_authority` equality is a **real** gate for `:observed`.
5. **Memory write.** `Admission#admit_episode` (`:77-95`) → `build_from_episode`
   (`:374-385`, `episode_epistemic_kind`) → `admit(record, gate: :episode, …)` (`admission.rb:242-268`).
   `admit` checks duplicate identity (`:245`), then `reject_reason` (`:286-316`), then writes
   `record.with(state: :active, …)` and appends (`:259-267`). **There is no human gate here.**
6. **Memory → later plan.** `SessionMemory#memory_binding` (`session_memory.rb:13-22`) writes
   `memory_epoch` into the session record; `SessionPlanningContext#add_memory_context`
   (`:565-576`) then calls `@configuration.memory.retrieval.recall(caller: memory_caller, query: { terms: [state.fetch(:task)] }, automatic: true)`
   and `memory_records` (`:579-591`) emits `'statement' => record.statement` **verbatim** into
   `context['memory']`. Matching is a **per-token prefix** LIKE on a 512-byte projection
   (`memory_store.rb:684-710`: `i.statement_search LIKE '<term>%'` plus the
   `'% <term>%'` word-boundary variant). Automatic injection requires `memory_epoch` to be a
   Hash (`:569`) and excludes `sensitive` rows before materialization (`retrieval.rb:68`).
7. **Improvement candidate → promotion.** `Promotion#promote` (`promotion.rb:38-65`) runs eight
   ordered checks ending in `EvaluationReport.assert_human_gate!(gate_classes:, evidence:)`
   (`:51`) → `assert_human_gate!` (`evaluation_report.rb:220-235`), whose entire test is
   `text.start_with?("human:") && text.length > HUMAN_GATE_PREFIX.length`.
8. **Promotion → active.** `record_promotion` (`promotion.rb:342-361`) returns
   `"activated" => false`; the row is `:recorded` and pending. Activation happens later and
   **elsewhere**: `SessionMemory#claim_behavior_transition` (`session_memory.rb:25-38`) at
   first intake, then `finalize_behavior_claim` (`:72-82`) after the deliberation commits.

### Lens: correctness

Reviewed. The episode contract is enforced rather than assumed: sequence 1..N, exactly one
terminal, 1 MiB event cap, terminal required (`episode_worker.rb:177-196`), and a graph node
cannot forge a model event (`episode_stream.rb:191-196`). The reverse channel's result is
verified before use (`evidence_client.rb:208-249`). The step-5 → step-6 handoff preserves the
stated contract: an admitted record is `:active` and immediately recallable, and after
`lifecycle.delete` the head-join
(`memory_store.rb:416-419`, `h.current_version = i.record_version AND h.deleted = 0`) removes it
from active recall — I confirmed this at flow level (probe: recall returns `[]` after delete).

**Not evidenced.** No test drives the *whole* stream→memory→planning chain in one process with
an untrusted statement reused as a task token. What would prove it: a single integration test
that admits via `LiveLearningHandlers`, then builds a planning context whose `task` contains the
admitted statement's leading token, and asserts the statement appears in `context['memory']`.

### Lens: security and authority

**The authority intersection holds; the content boundary does not.** I confirmed the challenger's
mechanism at the source and at the seam, and I confirm it independently rather than adopting it.

- `admission.rb:242-268` admits a plain episode as `:active` unconditionally once
  `reject_reason` is nil. `reject_reason` (`:286-316`) refuses oversized, secret-shaped,
  speculation-as-fact, missing provenance, recalled-as-new, empty tenant scope, empty owner,
  nil sensitivity, and policy-instruction-from-untrusted (`:309-313`).
- The "policy-instruction-from-untrusted" guard is the only content-shaped guard on this gate,
  and the challenger showed a paraphrase defeats it (`"manual gate"` is not matched by the
  `/approv|allowed_tools|permission/i` regex at `:174`, gate (b)). I re-read that regex and the
  mechanism is as described.
- **What crosses into the prompt is `record.statement`, verbatim, unfenced relative to the
  policy section** (`session_planning_context.rb:571-576` → `:579-591`).
- **The one guard that would bound the impact is elsewhere and holds**: a memory record can
  *request* capability but never *grant* one —
  `documentation/architecture/security-model.md:9` (effective authority is the intersection of
  profile, agent limits, task limits; memory records can request, never grant or lower a risk
  class). Nothing on the memory path touches the profile or capability surface; the engine
  advertises only `enabled/tenant/owner` (`worker_runtime.rb:909-913`). So this is
  prompt-injection-grade influence over planning, **not** an authority bypass. `major`, not
  `critical`.
- **Reverse channel: no approvals or commands.** Verified at the wire contract, not from the
  report: `contracts/runtime-v1.proto:25-27` declares `service EvidenceTools` with exactly one
  unary RPC `Call(EvidenceToolCall) returns (EvidenceToolResult)`, and there is no approval or
  command message in the schema. Approvals travel the other direction on Channel B/C
  (`approval_relay.rb:119-130`). The F06 analyst's claim is **UPHELD** at the flow level.

### Lens: reliability and durability

Reviewed at the seam. The episode is enqueued under a fenced `request_id`
(`situation_request.rb:495-506`) and a mid-episode disconnect leaves a resumable checkpoint
while the terminal is dropped to a closed stream — the split is stated (`:370-375`), and the
worker itself never calls `recover`. Memory's consolidation model call is correctly journalled
(`consolidation.rb:194-222`, `EffectDispatcher.run(operation: "memory.consolidate", safety: :unsafe)`).
**Not evidenced**: no cross-gem crash test that kills a worker between the memory append and the
next planning turn. What would prove it: a crash-matrix case that restarts after the episode
request commits and asserts the admitted memory is present and recallable.

### Lens: observability and evidence

Reviewed. Recall and drops emit correlated trace events (`retrieval.rb:177-202`); the stream logs
the admitted `memory_id` and `epistemic_kind` (`live_learning_handlers.rb:111-114`); each stream
frame carries `(episode_id, attempt_id, fence)`.

**The gap is at the join.** Nothing correlates an admitted `memory_id` to the *later* planning
turn that injected it: the recall trace at `session_planning_context.rb:571` passes no `trace:`,
so `emit_recall` is not called on the planning path (`retrieval.rb:177`). An operator can see
that a memory was admitted and separately that a plan was produced, but cannot see that this
memory steered that plan. Filed as **CF09-OBS-01**.

### Lens: scalability and resource bounds

Reviewed, and bounded at every hop: request 4 MiB / event 1 MiB (`episode_worker.rb:25-26`),
RPC pool 16 (`worker_server.rb:27,37`), recall `max_lexical_hits` 200 and a 1024-token budget with
lowest-first drops and `max_injected_knowledge` 8 (`retrieval.rb:56,139-166`), statement 4096 bytes
(`limits.rb:12`), 32 query terms (`retrieval.rb:22`), 512-byte searchable projection
(`surface.rb:133`). **Not evidenced**: stream episode volume → memory growth under sustained load;
the retention pass that would bound it has no caller (see CF10).

### Lens: maintenance and architecture

Reviewed. Dependency direction is honest on both sides: `tamoz-stream` depends on no sibling gem
and injects the memory-admission port; `tamoz-agent-memory` reaches up into nothing
(`agent_memory.rb:5-6`).

**The ownership defect is the seam itself.** Two automatic activation events are conflated under
the word "gate": admission writes `:active` in `admission.rb:259-267` on the same call that
accepts the record, while the *behavior-epoch* promotion is `:recorded` and pending until a
separate claim/finalize (`session_memory.rb:25-38`, `:72-82`). They are different gates with
different owners, and the flowing content's trust level is the same in both. Filed as
**CF09-MNT-01**.

### Tests and contracts

All commands with `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"`, one
file per command, `timeout 150`, from the repo root.

| Command | Result |
|---|---|
| `ruby -Itest test/stream_learning_loop_test.rb` | 17 runs / 84 assertions / 0F |
| `ruby -Itest test/stream_episode_skills_memory_test.rb` | 12 runs / 49 assertions / 0F |
| `ruby -Itest test/memory_session_integration_test.rb` | 4 runs / 24 assertions / 0F |

**Contract evidence.** `contracts/runtime-v1.proto:25-27` is the pinned single-RPC reverse
channel; `rake stream:proto:check` (`Rakefile:406-419`) is the drift gate — `not run` (shells out
to `grpc_tools_ruby_protoc`; budget).

**Not found.** No test asserts that an untrusted statement admitted by the stream path is or is
not injected into a planning context. No test correlates an admission to a later plan.

### Findings

#### CF09-SEC-01 — stream-derived untrusted text reaches the automatic planning context verbatim; the admission gate bounds the label, not the content

- **Severity**: `major`
- **Confidence**: `high` for the path and the injection (source-traced end to end and probe-confirmed
  by the challenger lane, re-read here); `medium` for exploitability (the intermediary that signs
  the stream request is outside this row).
- **Status**: `open`
- **Source evidence**: `admission.rb:242-268` (admit → `state: :active`, no human gate);
  `admission.rb:309-313` (the only content-shaped guard, a token regex);
  `live_learning_handlers.rb:88-96` (the stream writes an episode through this gate);
  `session_planning_context.rb:565-576` (`recall(..., automatic: true)` on `state.fetch(:task)`);
  `session_planning_context.rb:579-591` (`'statement' => record.statement`, verbatim, into
  `context['memory']`); `memory_store.rb:684-710` (`match_clause`: per-token prefix LIKE on
  `statement_search`); `retrieval.rb:68` (automatic excludes `sensitive` — the one content
  restriction, and it is a disclosure filter, not a trust filter).
- **Test/contract evidence**: `test/stream_learning_loop_test.rb` 17/84/0F and
  `test/memory_session_integration_test.rb` 4/24/0F both pass while proving only the admission
  *shape*. **not found**: no test asserts what happens to an untrusted statement after admission.
- **Scanner signal**: none — found by tracing the statement from `admit` to `context['memory']`.
- **Independent judgment**: I confirmed the mechanism at both ends of the two hops and confirmed
  the *bound* the challenger named — the authority intersection. This is a boundary defect
  because neither gem is wrong locally: `tamoz-agent-memory` is *permitted* to carry untrusted
  content (`security-model.md:9`), and `tamoz-agent-session` is entitled to trust its memory
  engine. What is missing is a **trust label on the seam** — the record carries no field that
  tells the planning context "this statement came from an untrusted source and must be framed as
  data". I reject grading it `critical`: no capability, approval, or egress widening is reachable
  from the memory path.
- **Root cause (five whys)**:
  1. Why does untrusted text steer a later plan? Because `record.statement` is emitted into the
     prompt verbatim.
  2. Why verbatim? Because `memory_records` (`session_planning_context.rb:579-591`) has no field
     to key a framing decision on.
  3. Why no field? Because the record's provenance is `source_refs`/`epistemic_kind`, and the
     planning context does not read either — it reads only `memory_id`, `layer`, `klass`,
     `statement`.
  4. Why does admission not prevent it? Because admission's contract is epistemic *labelling*
     (`:observed` vs `:reported`), and `:reported` is deliberately admissible — the design
     permits untrusted content in memory.
  5. Why is the seam unwatched? Because the trust level is established at the stream boundary
     (`live_learning_handlers.rb:93` verifies `source_authority`) and then **dropped** at the
     write: it is recorded in `source_refs` but never travels as a property the reader can act
     on. The contract that would prevent recurrence: a memory record carries its trust class, and
     every reader that places it in a model context frames it as data unless the class is
     `:observed`-verified.
- **Recommendation**: the smallest credible action at the existing seam — have `memory_records`
  (`session_planning_context.rb:579-591`) carry `epistemic_kind` and `source_refs` alongside
  `statement` and render an already-untrusted record inside the existing fenced user section
  rather than the bare `context['memory']` block. The field already exists on the record
  (`record.rb`); no new class, no new store, no new gate.
- **Disposition**: open. Recommend the coordinator route the framing fix to the
  `tamoz-agent-session` row (the reader owns the rendering) and record the trust-class field as a
  `tamoz-agent-memory` contract note. Duplicate of neither F06 nor F19: F06's SEC-01 is
  prompt/objective from the wire into the *trusted policy section*; F19's receipt finding is a
  different seam.

#### CF09-MNT-01 — "the human gate" names two different gates with two different owners, and neither is the operator approval path

- **Severity**: `major`
- **Confidence**: `high`
- **Status**: `open`
- **Source evidence**: **automatic write** — `admission.rb:259-267` writes `state: :active` in the
  same call that accepts the record; the only preconditions are the duplicate-identity probe
  (`:245`) and `reject_reason` (`:286-316`). **Automatic promotion to active** — also
  `admission.rb:259-267`; there is no second promotion step for an episode on this path.
  **Human-gated promotion (the other meaning)** — `promotion.rb:38-65` → `promotion.rb:51` →
  `evaluation_report.rb:220-235`, satisfied by any `String` starting with `"human:"`.
  **Operator approval path** — `session_effects.rb:367-383` (`approval_engine.build_request` →
  `decide_or_reuse` → `resolve`) against `gems/tamoz-approval/policy/*.yaml` +
  `Engine#decide` (`engine.rb:43`). **These two are disjoint**: `grep` for `improvement|heuristic|
  candidate|promotion` over `gems/tamoz-approval/policy/` returns **zero** matches, and
  `tamoz-agent-improvement.gemspec:14-17` declares no `tamoz-approval` dependency.
- **Test/contract evidence**: `test/improvement_candidate_test.rb:469-502` proves the
  `"human:"` gate refuses `nil`, `"auto-approved"` and a misspelled class — i.e. it proves exactly
  the prefix check, and nothing about a resolved decision. **not found**: no test asserts that a
  promotion's human evidence was produced by the approval engine.
- **Scanner signal**: `grep -rn "human_gate_evidence"` — every production call site passes a
  string literal.
- **Independent judgment**: the F06 analyst and the F23 analyst are **both right about different
  gates**, and the disagreement is the finding. For a stream-derived episode, the answer to "what
  is the gate" is: **automatic write AND automatic activation, with no human involved, owned by
  `tamoz-agent-memory`'s `Admission#admit`.** The `"human:"` string the F23 analyst found gates the
  *behavior-epoch promotion* path (heuristic → session prompt), a different seam with a different
  owner. I reject merging them: they are two gates for two different artifacts, and the
  conflation is what made the two reports look contradictory. What is genuinely a defect is that
  neither gate consults `tamoz-approval`, so **no** part of this flow uses the operator-facing
  approval path — which contradicts `AGENTS.md`'s "Approval policy is data too … Never hardcode a
  verdict, an approval constant, or a bypass flag elsewhere."
- **Root cause (five whys)**:
  1. Why do two records disagree about where the human gate is? Because "gate" is used for two
     artifacts: a memory record becoming `:active`, and a behavior epoch becoming `:activated`.
  2. Why are they conflated? Because both are described in prose as "promotion to active".
  3. Why does neither consult the approval engine? Because `tamoz-agent-memory` and
     `tamoz-agent-improvement` both declare narrow dependency sets that exclude `tamoz-approval`,
     so "human-gated" was implemented as a naming convention rather than a resolved decision.
  4. Why is that tolerated? Because the memory path was built to the epistemic-labelling design
     (`:observed`/`:reported`), under which a human gate on admission was never specified.
  5. Why is the vocabulary not corrected? Because no single component owns the flow: the stream
     writes, memory admits, the session injects, improvement promotes — four owners, four
     vocabularies. The preventing contract: one repo-wide term per artifact, and one authority
     source for "may this become live".
- **Recommendation**: at the existing `assert_human_gate!` seam (`evaluation_report.rb:220`), take
  the artifact being authorized — `assert_human_gate!(gate_classes:, evidence:, digest:)` — and
  require the evidence to be a digest bound to that artifact, so the promotion path stops
  accepting an unbound string. Separately, record in `documentation/design/memory.md` that
  episode admission is **automatic by design**, so the next reader does not look for a gate that
  was never specified. No new machinery.
- **Disposition**: open. Boundary owner for the promotion half is `tamoz-agent-improvement`
  (`assert_human_gate!`); the admission half is `tamoz-agent-memory` (`Admission#admit`) and is a
  documented design choice, not a defect. **Duplicate of F23-SEC-01 at the promotion seam** —
  recorded here only as the *boundary* statement that the two gates are disjoint; the promotion
  gate's weakness is F23's finding and is not counted in this row's totals.

#### CF09-OBS-01 — nothing correlates an admitted memory to the plan it later steers

- **Severity**: `minor`
- **Confidence**: `high`
- **Status**: `open`
- **Source evidence**: `session_planning_context.rb:571` calls `recall(caller:, query:, automatic: true)`
  with **no `trace:` argument**, so `emit_recall` (`retrieval.rb:177-202`) never fires on the
  planning path; `retrieval.rb:177` guards on `trace`. Admission *is* logged
  (`live_learning_handlers.rb:111-114`), but the injection is not.
- **Test/contract evidence**: `not found` — no test asserts a correlation between an admission and
  a planning-context injection. `test/memory_session_integration_test.rb` (4/24/0F) exercises the
  session path and asserts no trace.
- **Scanner signal**: none — found by reading the `recall` call site against the trace-emitting
  branch.
- **Independent judgment**: confirmed the trace parameter is absent at the only planning-path call
  site. `RecallResult#matched_restricted_ids`/`#dropped_ids` (`retrieval.rb:31-44`) are returned,
  so the data exists — it is simply not emitted where a planner would read it. This is the
  observability face of CF09-SEC-01 and is filed separately because the fix is different (pass a
  trace vs frame the content).
- **Root cause**: the planning context was written before the recall trace existed, and the
  call site was never updated. Contract: every automatic injection emits a correlated recall
  event naming the injected record and the turn.
- **Recommendation**: pass the session's existing trace into the `recall` call at
  `session_planning_context.rb:571` (the argument already exists at `retrieval.rb:55`). One
  keyword, no new signal.
- **Disposition**: open, minor.

### Blind spots

- **The stream request's signing intermediary was not read.** The exploitability of CF09-SEC-01
  depends on whether an untrusted party can craft an episode request; that is E08/E09's row.
- **`test/stream_episode_replay_test.rb`, `test/stream_invariants_test.rb`,
  `test/stream_episode_end_to_end_test.rb` were not run** (budget). CF09's claims rest on source
  traces and three green suites, not on a full stream sweep.
- **No production caller exists for `consolidation.consolidate`** (grep for `.consolidate(`
  outside the gem returns nothing), so the "consolidation → admission" hop of this flow is
  test-only in the shipped system. Recorded here, carried by CF10's ownership question.
- **The approval relay's signature verification** (`approval_relay.rb:200-225`) was read for the
  direction of travel, not audited; F06 owns it.

---

## CF10 — Memory admission, retrieval, deletion, consolidation, and transitions

### Boundary owners

| Hop | Owner | Contract |
|---|---|---|
| admission | `tamoz-agent-memory` `Admission` | gate on label + reject matrix |
| durable store | `tamoz-sqlite` `MemoryStore` | append-only versions, head + index |
| retrieval | `tamoz-agent-memory` `Retrieval` → `MemoryStore#search` | authorize-then-rank |
| planning injection | `tamoz-agent-session` `SessionPlanningContext` | render recalled records |
| delete | `tamoz-agent-memory` `Lifecycle#delete` | append tombstone + invariant-54 receipt |
| retention / purge | `tamoz-sqlite` `MemoryStore#purge_expired` / `#purge` | remove after retention |
| consolidation | `tamoz-agent-memory` `Consolidation` | deterministic gates + one journalled model call |

### Behavior path

**Admission → store → retrieval → planning.** `admit_owner_request`/`admit_episode`
(`admission.rb:103`, `:77`) → `admit` (`:242-268`) → `append` (`:443`) → `MemoryStore#append`
(`memory_store.rb:118-160`, record + index row in one transaction). Retrieval:
`Retrieval#recall` (`retrieval.rb:55`) → `MemoryStore#search` (`:203`) → `authorized_scan_body`
(`:410-431`, every caller field a SQL bind) → materialize (`:94`) → `rank` (`:107`) →
`apply_budget` (`:139`) → `mark_recalled` (`:172`). Planning injection:
`session_planning_context.rb:565-591`.

**Delete → retention → every table.** `Lifecycle#delete` (`lifecycle.rb:77-98`) locates the head
(`:120-147`), appends a `:deleted` version at `version+1` (`:81-88`), then builds a receipt from
`deletion_sinks` (`:96-97`, `:201-218`). The unwired retention pass is
`MemoryStore#purge_expired` (`memory_store.rb:377-392`) → `expired_tombstones` (`:511-529`) →
`tombstone_query` (`:484-503`) → `purge` (`:306-371`), which `DELETE`s `tamoz_store_versions` and
`tamoz_memory_index` for the key.

**Flow-level probe result** (`/tmp/cf10_flow_probe2.rb`, real engine over a real SQLite DB):

```
BEFORE delete:      {"versions"=>1, "heads"=>1, "index"=>1}
RECEIPT removed={"primary_record"=>1, "index_rows"=>2, "derived_consolidations"=>2,
                 "prompt_caches"=>0, "sync_queues"=>0} retained={...} pending=[]
AFTER delete:       {"versions"=>2, "heads"=>1, "index"=>2}
recall after delete = []
PLAINTEXT v2 read-back = MemoryRecord(state=:deleted, statement="Delete-me policy note", ...)
PURGE_EXPIRED removed={"records"=>1, "entries"=>[...]} pending=0 entries
AFTER retention pass: {"versions"=>0, "heads"=>0, "index"=>0}
PLAINTEXT after sweep = nil
```

**This corrects the F19 analyst's mechanism claim and confirms the challenger's refutation.**
The receipt reported `derived_consolidations => 2` in a store with **zero** derived records: the
count is a LIKE self-match on `tamoz_store_versions.payload` (`lifecycle.rb:235-249`,
`"%#{memory_id}%"`), which matches the record's own v1 and the tombstone v2 the same call just
wrote (count was 1 before, 2 after). And the agent-deleted branch **is** reachable:
`tombstone_query`'s `(h.deleted = 1 OR i.state = 'deleted')` (`:497`) matches on
`i.state = 'deleted'` at the head version, so the retention pass removed all three tables'
rows with `head.deleted` still `0` and **with no code change**. The F19 analyst's premise
(`memory_store.rb:133` hardcodes `deleted: false`, therefore unreachable) is **inverted**; the
`h.deleted = 1` branch is the redundant one.

### Lens: correctness

Reviewed. Scope isolation is real and probe-confirmed by the F19 lane; `valid_until_ms` is a SQL
predicate (`memory_store.rb:427`) and the head-join (`:416-419`) removes a superseded version from
active recall immediately. My probe confirms `recall` returns `[]` after delete and after the
retention sweep.

**Not evidenced.** No test asserts that the receipt's counts correspond to rows that existed or
that were removed. What would prove it: in `test_deletion_emits_receipt_and_propagates_to_index`
(`test/memory_engine_test.rb:562-573`), an assertion that `removed["derived_consolidations"]`
equals a *measured pre-delete* derived count.

### Lens: security and authority

Reviewed. Every caller field is a SQL bind and the restricted-existence signal shares the same
`authorized_scan_body`, so it is not an existence oracle. `SituationRecaller#validate_caller!`
(`situation_recaller.rb:43-56`) pins the caller.

**The untrusted-text path is the finding.** Exact route, with citations:
1. Untrusted text becomes an episode statement or an owner-request statement
   (`live_learning_handlers.rb:88-96`, or `admission.rb:103-133`).
2. It passes `reject_reason` (`admission.rb:286-316`) because the only content-shaped guard is
   the token regex at `:174`/`:309-313`, which a paraphrase defeats.
3. It is indexed with `statement_search` = the first 512 bytes (`surface.rb:133`).
4. A later task reusing one of its leading tokens recalls it: `match_clause`
   (`memory_store.rb:684-710`) does `i.statement_search LIKE '<term>%'` (and `'% <term>%'`).
5. `session_planning_context.rb:571-576` injects it and `:579-591` renders `record.statement`
   verbatim into `context['memory']`.

**Where the missing gate is**: there is no gate *at the seam*. The last place a trust decision is
made is `live_learning_handlers.rb:93` (source-authority equality, for `:observed` only); the
first place the content is used is `session_planning_context.rb:579-591`. Between them, the trust
class is recorded in `source_refs` and never read. The gate that would close it is a **trust class
carried on the record and honored by the reader** — not another admission refusal, which would
contradict `security-model.md:9`.

### Lens: reliability and durability

Reviewed. The consolidation model call is journalled (`consolidation.rb:194-222`); preimage-before-
rewrite holds (`store_preimage`→`mark_consumed` CAS, `:136-154`); `validate_proposal!` re-reads
the preimage (`:270-273`). Delete is a single CAS append (`lifecycle.rb:84-88`) with a typed
conflict (`:89-94`).

**Not evidenced.** No crash test between `Lifecycle#delete` and the retention pass. What would
prove it: a restart test asserting the tombstone is picked up by a pass on a different process.

### Lens: observability and evidence

Reviewed. Recall and drops emit correlated events (`retrieval.rb:177-202`); rejection carries
`reason` (`admission.rb:42-50`); `RecallResult` exposes dropped/matched-restricted ids (`:31-44`).

**The receipt is the gap** — see CF10-OBS-01. The receipt is the only artifact invariant-54 offers
as deletion proof, and it is not measured.

### Lens: scalability and resource bounds

Reviewed. Bounds declared and enforced: 4096-byte statements (`limits.rb:12`), 200 lexical hits,
1024-token budget, `max_injected_knowledge` 8, 32 query terms, 512-byte projection, 64/32 KiB
situation recall with 8× overfetch clamped to 512 (`situation_recaller.rb:11-14,36`).

**Unbounded in the shipped system** — see CF10-REL-01: `retention_default_seconds`
(`limits.rb:20`) is read nowhere, `supersede`/`correct` append, and the pass that would bound the
store has no caller.

### Lens: maintenance and architecture

Reviewed. `Surface#index_for` (`surface.rb:103-125`) keeps SQL out of `record.rb`; the `IndexRow`
value stays in `tamoz-sqlite`.

**The ownership defect**: three maintenance passes exist and none is scheduled —
`purge_expired`, `Consolidation#consolidate`, `TransitionRegistry#release_or_finalize`. Each is
tested directly, so the suite proves the mechanism and cannot see the missing caller. Filed as
CF10-REL-01 (the retention half) and marked duplicate for the other two.

### Tests and contracts

| Command | Result |
|---|---|
| `ruby -Itest test/memory_engine_test.rb` | 26 runs / 164 assertions / 0F |
| `ruby -Itest test/memory_store_test.rb` | 16 runs / 112 assertions / 0F |
| `ruby -Itest test/memory_treatment_profile_test.rb` | 14 runs / 218 assertions / 0F |

Probes (all under `/tmp`, zero repo scratch files): `/tmp/cf10_flow_probe2.rb`
(admission → delete → receipt → all three tables → retention sweep → plaintext re-read).

**Not found.** No test asserts `store.head_version`/`deleted = 1` after `Lifecycle#delete`; no
test asserts the receipt's counts against measured rows. `test_delete_tombstones_the_store_then_purge_removes_ciphertext_after_retention`
(`test/memory_engine_test.rb:766-791`) is titled for the tombstone but never asserts it.

### Findings

#### CF10-OBS-01 — the deletion receipt is not honest at the flow level: `removed` names sinks it never touched and one sink counts the record's own rows

- **Severity**: `major`
- **Confidence**: `high` (probe-reproduced at the flow level, all three tables inspected)
- **Status**: `open`
- **Source evidence**: `lifecycle.rb:96-97` builds the receipt from `deletion_sinks`
  (`:201-218`), which returns the literal hash
  `{"primary_record" => 1, "index_rows" => index_rows, "derived_consolidations" => derived, "prompt_caches" => 0, "sync_queues" => 0}`.
  The only durable write in `delete` is the `:deleted` version append (`:84-88`).
  `derived_references` (`:235-249`) is `SELECT COUNT(*) … WHERE CAST(v.payload AS TEXT) LIKE '%<memory_id>%'`
  — every version of the deleted record embeds its own `memory_id`, so the count includes the
  tombstone the same call wrote. `prompt_caches`/`sync_queues` are unmeasured literals
  (`:209-210`) and no call site populates or reads such a namespace.
- **Test/contract evidence**: `test_deletion_emits_receipt_and_propagates_to_index`
  (`test/memory_engine_test.rb:562-573`) asserts only `primary_record == 1` and `index_rows >= 1`,
  so a fabricated `derived_consolidations` passes. Probe `/tmp/cf10_flow_probe2.rb`: one admitted
  record, no derived records anywhere, receipt `derived_consolidations => 2`; `COUNT(*)` was 1
  before the delete and 2 after.
- **Scanner signal**: none — found by reading `deletion_sinks` against `derived_references`.
- **Independent judgment**: at the **flow** level the receipt is worse than the gem report says,
  because the flow adds a second consumer question: after `delete` the plaintext is still
  readable at version 2 (`PLAINTEXT v2 read-back` in the probe), the store head is `deleted = 0`,
  and the receipt says `pending => []`. Only the retention pass removes it, and that pass has no
  caller (CF10-REL-01). So a delete followed by the (unwired) retention pass **does** remove the
  data from every place retrieval reads — `versions`, `heads`, `index` all reach `0` and recall
  stays `[]` — but the receipt issued at delete time claims removal that has not happened, and
  reports zero pending. The claim is inconsistent with the flow, not merely with the operation.
- **Root cause (five whys)**:
  1. Why does the receipt claim removals that did not occur? Because `deletion_sinks` reports a
     descriptor of the sinks the design *names*, unconditionally.
  2. Why is a descriptor passed off as an outcome? Because `derived_references` returns a
     `COUNT(*)` placed in the same hash as `primary_record` and `index_rows`, which are genuine
     post-hoc measurements.
  3. Why is the self-match not caught? Because the LIKE is on the record's own key, and the
     tombstone write is what makes the count rise.
  4. Why does nothing catch it? Because the only assertion checks the two honest keys, and the
     invariant-54 shape has no `skipped`/`not_applicable` vocabulary.
  5. Why does the shape have no such vocabulary? Because the retention pass that would move
     `pending` to `removed` is a **different owner** (`tamoz-sqlite`) and a **different operation**
     (`purge`), and no contract connects the two receipts. The preventing contract: a receipt
     field is either measured after the operation or absent, and `pending` names every sink whose
     removal is deferred to the retention pass.
- **Recommendation**: at the existing `deletion_sinks` seam (`lifecycle.rb:201`), exclude the
  deleted key's own versions from `derived_references`, and move a sink this call did not touch
  into `pending` (the receipt already has that list and `MemoryDeletionError` already consumes it
  at `:93`). Then, at the flow level, have `purge_expired`'s receipt name the record it removed so
  the two receipts chain. Do not add a deletion engine.
- **Disposition**: open. This is the **boundary** statement of a defect F19 owns at the gem
  level: **duplicate of F19-SEC-01/F19-DEL-01 at the `lifecycle.rb#deletion_sinks` seam; boundary
  owner `tamoz-agent-memory`.** Counted in this row because the flow adds the delete→retention
  chaining question that neither gem row asks. Not double-counted against F19.

#### CF10-REL-01 — the pass that would bound memory has no owner, and the flow's delete→retention chain therefore never runs

- **Severity**: `major`
- **Confidence**: `high` that the pass works and has no caller; `medium` on where the caller
  belongs (a third gem owns the worker's maintenance seam).
- **Status**: `open`
- **Source evidence**: `purge_expired` (`memory_store.rb:377-392`) has **zero** production
  callers — repo-wide `grep -rn "purge_expired" gems/ apps/ bin/ lib/` returns only its
  definition and `test/memory_store_test.rb`. `Lifecycle#delete` likewise has no production
  caller (`lifecycle.rb:77`); `grep -rn "\.lifecycle\b"` outside tests returns nothing.
  `retention_default_seconds` (`limits.rb:20`) is read nowhere. Record versions are append-only
  (`record.rb:11`) with no compaction (`supersede` `lifecycle.rb:47`, `correct` `:23`).
- **Test/contract evidence**: `test/memory_engine_test.rb` drives `delete` and `purge` directly
  (26/164/0F), which proves the mechanism and cannot see the missing caller. Probe
  `/tmp/cf10_flow_probe2.rb`: the pass removes `versions`, `heads`, and `index` to `0` and the
  plaintext becomes unreadable — the mechanism **works**, it is simply never invoked.
- **Scanner signal**: call-graph search for the pass and for the lifecycle entry point.
- **Independent judgment**: I **refute** the F19 analyst's mechanism claim and **uphold the
  challenger's**: `memory_store.rb:517-520` makes the agent-deleted branch reachable
  (`(h.deleted = 1 OR i.state = 'deleted')` at `:497`, with `i` left-joined on
  `i.record_version = h.current_version`), and my probe deleted all three tables' rows with
  `head.deleted` still `0`. The `deleted: false` hardcode at `:133` is a red herring, and the
  recommended tombstone-flag half of the fix is **unnecessary**. What survives is exactly one
  sentence: **the pass exists and works; nothing schedules it.** This is a boundary defect because
  the ownership is genuinely split — the store owns the operation, `tamoz-agent` owns the worker's
  maintenance seam, and neither contract names the other.
- **Root cause (five whys)**:
  1. Why does deleted memory persist indefinitely? Because no production code calls `purge` or
     `purge_expired`.
  2. Why not? Because the maintenance pass the comment calls "the tamoz-agent maintenance pass"
     (`lifecycle.rb:100-101`) was never scheduled.
  3. Why was it never scheduled? Because the gem's public surface ends at the engine and the
     worker builds the engine reading only `tenant` (`worker_runtime.rb:894-913`).
  4. Why did no gate catch it? Because every suite drives `purge` on the engine directly.
  5. Why is the gap structural? Because grep for a caller is the only way to see it — no contract
     states that a declared retention bound must be enforced in a running worker. The preventing
     contract: a retention assertion at the worker level, not another purge method.
- **Recommendation**: schedule the pass that already exists — invoke
  `MemoryStore#purge_expired` from the worker's existing maintenance/sweep seam (the same place
  the toolbox's stale-staging sweep runs). Delete the "tombstone the head" half of the prior
  recommendation; it is unnecessary. No new machinery.
- **Disposition**: open. **Duplicate of F19-DEL-01 with the mechanism corrected**; boundary owner
  is `tamoz-agent` (the worker's sweep seam), which is outside F19's row. The coordinator must
  confirm ownership with whoever owns `worker_runtime.rb` before recording a fix.

#### The one-record-or-two call

**Two records — and the challenger's merge recommendation is right for F19's ledger but wrong for
this flow's.** The challenger recommends folding F19-SEC-01 into F19-DEL-01 because both cite
`lifecycle.rb#deletion_sinks`. On the source that is correct: F19-SEC-01's receipt-overclaim
content *is* F19-DEL-01's receipt, at the same method, and counting them separately inflates
F19's ledger. **F19 should index 2 independent majors, not 3** (`F19-DEL-01` with the mechanism
rewritten, `F19-REL-01`), with the receipt recorded once at `lifecycle.rb#deletion_sinks`.

CF10 should nonetheless carry **two** rows of its own, because the flow asks a question neither
gem row asks: (1) `CF10-OBS-01` is the **delete-time receipt vs the retention-time reality**
question — a cross-operation, cross-owner consistency question, indexed as a duplicate of the
`deletion_sinks` seam; (2) `CF10-REL-01` is the **missing caller / missing owner** question at the
`tamoz-agent` worker seam. They have different boundary owners, different fixes, and different
verification. Collapsing them would lose the ownership half, which is the only part of this flow
that lives outside `tamoz-agent-memory`.

### Blind spots

- **`purge_expired`'s `still_pending` list** was read but not exercised across a mixed tombstone
  set (some expired, some not). Probe covered one expired record; `pending` was `0`.
- **Sensitive-record deletion was not probed** — my record was `:internal` with an XOR protection
  codec, so ciphertext handling on the delete path is unverified.
- **`tamoz-evals-runner`'s second engine** over the same store (`memory_repository_adapter.rb:70`)
  was not traced; it is another potential admission entry point.
- **Consolidation was not driven end to end** (no production caller; `test/improvement_candidate_test.rb`
  covers the candidate path, not the consolidation pipeline).

---

## CF11 — Failure classification, safe remediation, candidate improvement, promotion/rollback

### Boundary owners and gates

| Hop | Owner | Gate | Human? |
|---|---|---|---|
| typed failure | `tamoz-agent-healing` `FailureRecord` | version-first `from_h` (`failure_record.rb:225-234`) | no |
| classification / abstention | `tamoz-agent-healing` `Classification.classify` | typed signal only; five never-mutate classes | no |
| remediation proposal | `tamoz-agent-healing` `PlanBuilder` + `PlanReview` | plan required; semantic critic | no |
| preflight | `tamoz-agent-healing` `Preflight` | 11 ordered checks; `attempt <= budgets["max_attempts"]` | no |
| execution | `tamoz-agent-healing` `EffectExecution` → `tamoz-agent-kernel` `EffectDispatcher` | journal dedupe on `(trace, op, rule version, call_index, form)` | no |
| compensation | `tamoz-agent-healing` `CompensationFlow` | runs only if verification fails **and** `verify_or_compensate` is reached | no |
| terminal state | `tamoz-agent-healing` `validate_terminal_state!` | `:recovered` requires a passing oracle | no |
| **production repair loop** | **`tamoz-agent-session`** `session_evidence.rb:128-151` | identity-keyed `repeated_failure` + `MAX_REPAIR_ATTEMPTS = 2` | no |
| candidate improvement | `tamoz-agent-improvement` `Promotion#promote` | 8 ordered checks incl. `assert_human_gate!` | **`"human:"` string** |
| promotion / rollback | `tamoz-agent-improvement` + `tamoz-agent-memory` `TransitionRegistry` | digest-bound transition record | no |

### Behavior path

1. **Typed failure.** `FailureRecord` stores a `{digest, source, bytes}` reference and refuses
   `text`/`message`/`body` keys (`failure_record.rb:359-371`); `typed_signal` omits
   `untrusted_message_ref` (`:155-173`).
2. **Classification.** `Classification.classify(record, rule:)` (`classification.rb:152`) reads
   only `record.typed_signal`. `route` is `:escalated` for `abstained`/`never_mutate`/`contain_escalate`
   (`:114-119`); `Session#call` returns before planning (`session.rb:35-36`).
3. **Plan / review.** `PlanBuilder` requires `original_invariant`, `minimal_change`,
   `stop_conditions` (`plan_builder.rb:41-47`); `PlanReview` requires a callable critic and a
   non-accepting review must name issues (`plan_review.rb:63-69`).
4. **Preflight.** `Preflight.run` returns the first failing check in `CHECK_IDS` order
   (`preflight.rb:193-200`); `within_attempt_scope_magnitude_cost_time` compares the
   **caller-supplied** `context.attempt` against the rule's static `budgets["max_attempts"]`
   (`:118-124`).
5. **Execution.** `EffectExecution#call` yields `@performed = true` then `EffectDispatcher.run`
   with the `healing.<digest>` operation (`effect_execution.rb:30-43`).
6. **Ambiguity / failure.** `handle_ambiguous_effect` (`session.rb:168-186`): `:unknown`/`:wait`
   → `terminate(:unresolved, …)`; **`:failed` → `transition(:uncertain, …)` as the last
   expression.** The method therefore returns the truthy `Array` produced by
   `AttemptEvidence#record` (`attempt_evidence.rb:27-31`, `@transitions << …`). `Session#call:50`
   is `return ambiguous_terminal if ambiguous_terminal` — truthy wins, so
   **`verify_or_compensate` (`:52`) is never reached on a `:failed` effect.**
7. **Verify / compensate.** `Oracle.verify` is the only producer of `passed` (`oracle.rb:66`);
   `recovered` requires it (`session.rb:191-197`), re-asserted by `validate_terminal_state!`
   (`:238-243`); otherwise `CompensationFlow` runs (`compensation_flow.rb:20-28`).
8. **Candidate → promotion.** `Promotion#promote` (`promotion.rb:38-65`) → `record_promotion`
   (`:342-361`) returns `"activated" => false`.
9. **Activation.** `SessionMemory#claim_behavior_transition` (`:25-38`) then
   `finalize_behavior_claim` (`:72-82`) after the deliberation commits.

### Lens: correctness

Reviewed. Abstention is first-class and non-acting; `recovered` is reachable only through a
digest-pinned configured check; `validate_terminal_state!` re-raises propagating failures
(`session.rb:244`).

**The correctness defect is the raw-`Array` escape** (CF11-COR-01), which I verified
independently at the source and by direct probe twice — once by driving
`Session#handle_ambiguous_effect` with a `:failed` outcome, once end to end through
`Remediation.run`.

### Lens: security and authority

Reviewed. No untrusted-prose path to a mutating family: `classify` reads only `typed_signal`,
`LegacyTextAdapter::Proposal#mutating?` is hardcoded `false` (`legacy_text_adapter.rb:31`), and
the five never-mutate classes are structurally enforced (`rule.rb:384-389`,
`classification.rb:177`). The in-band guard is a thread-local depth counter, independent of the
caller's `actor:` string (`scope.rb:24-51`).

**The authority gap is at the promotion boundary**: `assert_human_gate!`
(`evaluation_report.rb:220-235`) takes only `(gate_classes:, evidence:)` — no digest, no actor, no
report — and the whole test is a prefix. Any `String` starting with `"human:"` and longer than
the prefix passes. `gems/tamoz-approval/policy/*.yaml` contains zero occurrences of
`improvement|heuristic|candidate|promotion`, and the gem declares no `tamoz-approval` dependency
(`tamoz-agent-improvement.gemspec:14-17`). This is a **boundary** defect: the artifact that
answers "who approved this" is minted by the same party that consumes it, and the component that
owns the answer (`tamoz-approval`) is not on the path.

### Lens: reliability and durability

Reviewed. Every lifecycle stage is a durable, separately-identified effect
(`candidate_lifecycle.rb:183-198`, `EFFECT_CALLS` at `:13`), `:unknown` blocks the next phase
(`:223-224`), and rollback is content-addressed (`:113-115`).

**The reliability defect is the double bound**: the healing layer implements none, and the layer
that implements one is not the layer the production path uses. See CF11-REL-01.

### Lens: observability and evidence

Reviewed. Every transition is a correlated record (`attempt_evidence.rb:35-52`) and
`EscalationPayload` carries fingerprint, digests, terminal state, classification, preflight
precondition, verification, compensation, and `recommended_next_action` (`escalation_payload.rb:31-74`).

**Gap**: on the `:failed` path the `:uncertain` transition *is* recorded (the record happens
before the return), so the evidence ledger shows a failure — but the *caller* receives an array
instead of an `Outcome`, so `escalation_id`, `verification`, `compensation`, and the terminal
state never exist. An operator sees a transition with no terminal. Folded into CF11-COR-01.

### Lens: scalability and resource bounds

Reviewed. `MAX_ID_BYTES` 256 / `MAX_CONTEXT_KEYS` 32 (`failure_record.rb:47-48`), budgets must be
positive finite (`rule.rb:501-508`), at most one remediation form per rule (`:435-440`),
`Preflight.run` short-circuits so the rejection matrix is bounded by `CHECK_IDS` (11 entries),
`MAX_INSERTIONS = 8` (`heuristic.rb:39`).

**Unbounded**: the number of protocol cycles for one failure fingerprint, because the only
implemented bound lives one gem over and the journal dedupe is defeated by a changing trace.

### Lens: maintenance and architecture

Reviewed. Dependency direction is honest: healing depends only on kernel/tools/core
(`tamoz-agent-healing.gemspec:11-15`) and adds no second effect engine — it dispatches through the
existing `EffectDispatcher` with identity from `EffectIdentity` (`effect_identity.rb:27-45`).

**The architecture defect is the split vertical**: two independent remediation implementations
exist — the healing gem's protocol (complete, tested, uncalled) and the session's tool-repair loop
(narrower, called, and the only one that bounds repetitions). The README's claim describes the
second and is attributed to the first. Filed as CF11-MNT-01.

### Tests and contracts

| Command | Result |
|---|---|
| `ruby -Itest test/healing_remediation_test.rb` | 13 runs / 74 assertions / 0F |
| `ruby -Itest test/healing_failure_contract_test.rb` | 35 runs / 264 assertions / 0F |
| `ruby -Itest test/improvement_candidate_test.rb` | 14 runs / 284 assertions / 0F |
| `ruby -Itest test/agent_improvement_lifecycle_test.rb` | 6 runs / 13 assertions / 0F |

Probes: `/tmp/cf11_rel02_probe.rb` (end-to-end `Remediation.run` with a changing
`original_trace_id`/`call_index`), `/tmp/cf11_rel02b.rb` (direct `handle_ambiguous_effect` drive).

**Not found.** No test drives `attempt:` past 1; no test asserts a repetition bound in the healing
gem; **no test exercises a remediation effect resolving to `:failed` through `Remediation.run`**
(`grep` over `test/healing_remediation_test.rb` returns zero such scenario). Their green state is
evidence of a coverage gap, not of correctness on these paths.

### Findings

#### CF11-COR-01 — a `:failed` remediation effect returns a raw transitions `Array` instead of an `Outcome`, skipping verification, compensation, terminal-state validation, and escalation

This is the challenger's proposed `F20-REL-02`. **My verdict: UPHELD — `major` today,
`critical` the moment a caller exists.**

- **Severity**: `major` (unreachable in the shipped system: no production caller for
  `Remediation.run`); would be `critical` when wired, on BAR.md's "false completion / broken
  effect semantics" clause.
- **Confidence**: `high` — verified at the source and reproduced by two independent probes.
- **Status**: `open`
- **Source evidence**: `attempt_evidence.rb:27-31` — `record` ends in `@transitions << transition_for(…).freeze`,
  so it returns the mutated transitions `Array` (truthy). `session.rb:182-184` — the
  `when :failed` branch of `handle_ambiguous_effect` calls `transition(:uncertain, evidence: { 'status' => 'failed' })`
  as its **last expression**, so the method returns that truthy `Array`. `session.rb:49-52` —
  `ambiguous_terminal = handle_ambiguous_effect(…)` then `return ambiguous_terminal if ambiguous_terminal`,
  which takes the array and returns it from `Session#call`. Therefore `verify_or_compensate`
  (`:52`) is unreachable on `:failed`: no `Oracle.verify`, no `CompensationFlow`, no
  `validate_terminal_state!`, no `EscalationPayload`. `Remediation.run` (`remediation.rb:75`,
  `Scope.in_band { session.call }`) hands its caller a bare array.
- **Test/contract evidence**: `not found` — no test in `test/healing_remediation_test.rb`
  (13/74/0F) resolves a remediation effect to `:failed`. Probe `/tmp/cf11_rel02b.rb`, exact output:
  ```
  AttemptEvidence#record returns: Array truthy=true value=[{"state"=>"x", "failure_format_version"=>1, ...}]
    == @transitions? true
  handle_ambiguous_effect(:failed) returns: Array truthy=true
    -> Session#call line 50 'return ambiguous_terminal if ambiguous_terminal' => TAKES RAW ARRAY: true
  ```
  Probe `/tmp/cf11_rel02_probe.rb` drives the real `Remediation.run` over a real workspace with a
  changing `original_trace_id`/`call_index`; all three cycles returned an `Outcome` in *my*
  configuration, because the dispatcher's `:failed` status was not reached (the effect resolved
  otherwise). That is an honest negative for the end-to-end shape and it is why I drove
  `handle_ambiguous_effect` directly rather than relying on the challenger's control D output
  alone. The defect is at the branch, and the branch is unconditional.
- **Scanner signal**: none — found by the challenger; re-derived independently here.
- **Independent judgment**: I reconstructed the whole chain from `attempt_evidence.rb:27` to
  `remediation.rb:75` and confirmed each link by execution. This is **not** CF04-REL-01 (a
  journal replay receipt-selection bug in `tamoz-agent-kernel`) and **not** F20-REL-01 (the
  missing repetition bound); it is a distinct seam. I **agree with the challenger's verdict** and
  add one qualification it did not state: because the `:uncertain` transition *is* recorded
  before the return, the failure is silent but not invisible — a reader of the transitions ledger
  can see `status: failed` with no terminal. That is what keeps it at `major` rather than
  `critical` while unwired, and it is also the cheapest verification available to a future caller.
- **Root cause (five whys)**:
  1. Why does the caller get an array where an `Outcome` is contracted? Because
     `handle_ambiguous_effect`'s `:failed` branch returns its own last expression.
  2. Why is that expression truthy? Because `AttemptEvidence#record` returns `@transitions << …`
     rather than `self` or `nil`.
  3. Why does the truthy return matter? Because `Session#call:50` uses a truthiness test
     (`if ambiguous_terminal`) that cannot distinguish "a terminal `Outcome`" from "any truthy
     value".
  4. Why was the truthiness test written? Because the other branch of the same method legitimately
     returns an `Outcome`, so the guard looks like an `Outcome`-or-nil check.
  5. Why did nothing catch it? Because no test drives a remediation effect to `:failed`
     end to end — the suite covers the happy path and `:unknown`, and the `:failed` case is the
     one branch whose return value is an accident of Ruby's last-expression rule. The preventing
     contract: every branch of a terminal-producing method returns a value of the contracted
     type, and the guard tests the type, not the truthiness.
- **Recommendation**: two lines at the existing seams — make `AttemptEvidence#record` return
  `nil` (or `self`) instead of the array, **and** make `Session#call:50` test
  `ambiguous_terminal.is_a?(Outcome)` rather than truthiness. The `:failed` branch then falls
  through to `verify_or_compensate` (`:52`) as intended, which already handles a non-passing
  verification via `compensate_and_terminate` (`:203-218`). No new class, no new state.
- **Disposition**: open. **UPHELD as `major`**; the recommendation to re-run the F20 analyst lane
  before the row closes is sound, and I add the direct-drive probe (`/tmp/cf11_rel02b.rb`) as the
  cheapest reproduction.

#### CF11-REL-01 — the README's repetition bound is honored by the session layer only; the healing layer implements none, and the journal dedupe is not a bound

- **Severity**: `major`
- **Confidence**: `high` for the behavior and for the absence of a healing-side bound; `high` for
  the missing production caller; `medium` on the operational cost (the session path that *is*
  called is bounded).
- **Status**: `open`
- **Source evidence — the bound exists, one gem over**: `session_nodes.rb:26`
  `MAX_REPAIR_ATTEMPTS = 2` (surfaced as `max_repair_attempts:`, validated `0..10` at
  `session_options.rb:103-105`); `session_evidence.rb:128-151` `bounded_repair` performs
  **identity-keyed** repetition detection (`state.fetch(:seen_failure_signatures).include?(signature)`
  → `terminal_reason: 'repeated_failure'`) *and* a counter bound (`repair_attempt >= max_repair_attempts`
  → `'repair_attempts_exhausted'`), driven by `failed_check` (`:124-126`).
  **The healing layer implements neither**: `remediation.rb:63` takes `attempt: 1` and passes it
  through without validation (`:78-85`); `@attempt` appears four times in `session.rb`
  (`:19,46,84,258`) and **never in a comparison**; `preflight.rb:118-124` compares the
  caller-supplied `context.attempt` against the rule's *static* `budgets["max_attempts"]`;
  `seams.rb:56-63` counts failures with no identity comparison (`@conditions` carries only `kind`
  and free-form `context`); `remediation.rb:93` defaults to a fresh in-memory circuit per run.
  **The two verticals do not touch**: `grep -rn "Remediation|Healing::" gems/ apps/ bin/` outside
  `gems/tamoz-agent-healing/` returns exactly one inert comment
  (`circuit_store.rb:41`); `grep -rn "Healing" gems/tamoz-agent-session/lib/` returns only the
  `healing_pin` schema block (`session_records.rb:99-106`).
  **The journal dedupe is defeated by a real retry**: identity is
  `(trace, operation, rule version, call_index, form)`, so a caller varying only
  `original_trace_id`/`call_index` — exactly what a retry loop supplies — loses it. The
  challenger's control D showed performs going from 1 to 2 for one fingerprint; the "effective
  budget of 1" is a property of the *journal*, not a healing bound.
- **Test/contract evidence**: `not found` — no test drives `attempt:` past 1 or asserts a
  repetition stop in the healing gem. `test/healing_remediation_test.rb` 13/74/0F,
  `test/healing_failure_contract_test.rb` 35/264/0F both green.
- **Scanner signal**: `grep -n "@attempt" session.rb` returns four uses, zero comparisons; the
  circuit seam's constructor list. Also confirmed: the H3 adapter
  `Sqlite::CircuitStore#record_failure` (`circuit_store.rb:119-132`) builds
  `FailureEvent.new(kind:, context_digest:)` and **never passes `fingerprint:`**, leaving that
  `Data` member `nil` (`record.rb:34-38`) — so the recommended fix needs that adapter populated
  too.
- **Independent judgment**: I confirm both halves and I answer the flow question precisely.
  **Which layer is on the production path: `tamoz-agent-session`'s tool-repair loop.** The
  healing gem is not on it (`Remediation.run` has no production caller, re-verified by repo-wide
  grep). **Does the bound therefore hold: yes, for the shipped system** — a failed check in the
  session path gets at most two reviewed repairs with fresh approvals, and a repeated failure
  signature stops with `repeated_failure`. The README's claim is honored by the layer that runs.
  It is **not** honored by the layer the claim's vocabulary points at, and the moment H3 wires
  `Remediation.run` the bound disappears. So this is a boundary defect of the "two implementations
  of one contract, one unwatched" kind, not a live unbounded loop.
- **Root cause (five whys)**:
  1. Why is the README's bound not implemented in the healing gem? Because `attempt:` is treated
     as evidence forwarded to the ledger, never as a limit, and `Session` holds no cross-attempt
     state by design (`session.rb:7-8`).
  2. Why no cross-attempt state? Because repetition was deferred to the durable circuit, and the
     default circuit is a fresh in-memory counter per run (`remediation.rb:93`).
  3. Why is that counter blind to repetition? Because it increments a bare count without comparing
     failure identity (`seams.rb:56-63`), while the shared value that *has* identity
     (`FailureEvent#fingerprint`, `record.rb:34`) is unused by both this gem and the SQLite
     adapter.
  4. Why did no gate catch it? Because the only implemented bound lives in a different gem
     (`session_evidence.rb:128-151`), so the healing protocol's own bound was never tested.
  5. Why does the contract tolerate two implementations? Because the README states the property
     once, at the repo level, and neither gem's contract says which layer owns it. The preventing
     contract: one declared owner for the repetition bound, and the circuit seam exposes failure
     identity so repetition is detected by identity rather than by an uncounted replay.
- **Recommendation**: the smallest credible action at the existing seam — have `Session` compare an
  accumulated per-fingerprint count against `rule.budgets["max_attempts"]` in its circuit seam,
  and populate `FailureEvent#fingerprint` in `Sqlite::CircuitStore#record_failure`
  (`circuit_store.rb:119-132`) so the durable replacement can carry it. Repair the README claim's
  ownership by naming the session loop as the implemented bound. No new class, no new store.
- **Disposition**: open. Boundary owner is split: `tamoz-agent-healing` for the missing bound,
  `tamoz-sqlite` for the adapter that does not populate the identity. **Duplicate of F20-REL-01
  at the healing seam** (severity corrected `critical` → `major` on reachability, as the
  challenger argues), with the flow adding the layer-ownership statement and the H3-adapter
  refinement. Not re-counted as a new F20 defect.

#### CF11-MNT-01 — the authority artifact for a promotion is minted by its consumer; `tamoz-approval` is not on the path

- **Severity**: `major`
- **Confidence**: `high` for the behavior (probe-reproduced by the F23 lane: `"human:anybody"`,
  `"human:1"`, `"human:x"`, `"human:the_candidate_itself"` all accepted);
  `medium` for impact (no production caller today).
- **Status**: `open`
- **Source evidence**: `evaluation_report.rb:220-235` (`assert_human_gate!(gate_classes:, evidence:)`;
  the entire check is `text.start_with?("human:") && text.length > HUMAN_GATE_PREFIX.length`);
  `promotion.rb:51` and `:350` (the string is accepted and persisted verbatim);
  `promotion.rb:240-262` (`assert_not_self_promoting!` compares the same `String(actor)` the
  caller supplied); `candidate_proposal.rb:45-48` (the same prefix test);
  `tamoz-agent-improvement.gemspec:14-17` (no `tamoz-approval` dependency);
  `gems/tamoz-approval/policy/base.yaml` (**zero** matches for `improvement|heuristic|candidate|promotion`);
  the authoritative path that exists — `session_effects.rb:367-383` → `Engine#decide`
  (`engine.rb:43`) against the policy YAML.
- **Test/contract evidence**: `test/improvement_candidate_test.rb:469-502` proves the gate refuses
  `nil`, `"auto-approved"`, `"human:"` and a misspelled class — exactly the prefix check that is
  insufficient. **not found**: no test asserts the evidence was produced by an approval decision,
  because the API cannot express it.
- **Independent judgment**: at the flow level this is sharper than at the gem level. The flow has
  **three** gates named "human" or "approval" — the session's `approval_engine` (the real policy
  path), the healing gem's `"human:"` string (`rule_registry.rb:164-178`), and the improvement
  gem's `"human:"` string — and **only the first consults `gems/tamoz-approval/policy/*.yaml`.**
  Two of the three are self-describing prefixes. That is a boundary/ownership defect, and it
  contradicts `AGENTS.md`'s standing rule ("Approval policy is data too … never hardcode a verdict,
  an approval constant, or a bypass flag elsewhere"). I **reject** downgrading to `minor`: the gate
  is the only thing between a caller and a self-protected field or a behavior epoch.
- **Root cause (five whys)**:
  1. Why can a promotion be recorded on a bare string? Because `assert_human_gate!` compares a
     prefix.
  2. Why a prefix? Because its only inputs are `gate_classes` and `evidence` — there is no digest
     or actor to bind against.
  3. Why not? Because the approval artifact is a free-form `String` on the caller's keyword
     interface rather than a resolved policy decision object.
  4. Why is it free-form? Because `tamoz-agent-improvement` declares no `tamoz-approval`
     dependency and references no `Tamoz::Approval` constant.
  5. Why did the repo's approval-policy-is-data rule not reach here? Because the rule is stated
     repo-wide and neither gem's contract says which layer owns "may this become live". The
     preventing contract: a promotion's human gate is a resolved approval-policy decision bound to
     the exact candidate digest and report seal.
- **Recommendation**: extend `assert_human_gate!` with the artifact it authorizes
  (`digest:`) and require the existing `CandidateLifecycle.approval_digest`
  (`candidate_lifecycle.rb:29-43`, which already covers proposal/candidate/content/operation/actor/
  authority digests); `Promotion#promote` already holds `candidate.digest` and the seal at the
  call site (`promotion.rb:49-51`). The policy lookup itself belongs to `tamoz-approval` and
  should not be invented here. One argument, one comparison.
- **Disposition**: open. **Duplicate of F23-SEC-01 at `evaluation_report.rb#assert_human_gate!`;
  boundary owner `tamoz-agent-improvement`.** The boundary statement this row adds is the
  three-gates-one-policy observation above. Not counted as a new defect.

### Verification of F20-REL-02

**Verdict: UPHELD at `major`** (unreachable today; `critical` when wired). I re-derived the chain
at the source (`attempt_evidence.rb:27-31` → `session.rb:182-184` → `session.rb:49-52`) and
confirmed each link by execution (`/tmp/cf11_rel02b.rb`). I do **not** accept it on the
challenger's control-D output alone, because my own end-to-end `Remediation.run` probe over three
cycles with a changing trace did not reach `:failed`; that negative is recorded above rather than
hidden, and it is the reason the recommendation carries a type test
(`is_a?(Outcome)`) as well as the return-value fix. The challenger's severity call — `major`,
`critical` when wired — is right, and its recommendation to re-run the F20 analyst lane is right.

### Blind spots

- **No production caller exists for `Remediation.run` or `RuleRegistry`**, so the whole healing
  vertical was exercised directly. If H3 wires a caller passing a caller-controlled `attempt:`,
  CF11-REL-01 becomes `critical` immediately and unchanged.
- **I did not audit the SQLite effect journal's own attempt accounting**
  (`effect_attempt_ledger.rb:48-56`); that is F07's row. I relied on the observed replay behavior.
- **`PromotionGate`** was read as a pure predicate module; the eval-side producer of promotion
  records is `tamoz-evals` (F26/F27) and was not traced.
- **No load or soak measurement exists** for any of the three flows. What would prove the
  scalability lens end to end: a multi-episode stream run asserting memory growth against the
  declared retention, and a concurrent two-promotion test asserting exactly one `:activated`
  heuristic row.

---

## Verdict

- **CF09 — IMPROVE.** 0 critical, 2 major, 1 minor, 0 info. All six lenses reviewed.
  The Situation boundary admission and the reverse channel hold: `ReceivedSnapshot.verify` is
  digest-backed, and `EvidenceTools` is one unary RPC with identity echo and caps — **no
  approvals or commands cross it** (`contracts/runtime-v1.proto:25-27`). The authority
  intersection holds: memory can *request* capability, never grant one. What fails is the
  content/trust seam: untrusted text is admitted as `:reported`, indexed, and injected verbatim
  into the automatic planning context, and the two gates named "human" are disjoint from the
  operator approval path.
- **CF10 — IMPROVE.** 0 critical, 2 major, 1 minor, 0 info. All six lenses reviewed.
  Admission, retrieval scoping, and planning injection are sound in shape. At the flow level the
  deletion receipt is not honest — `derived_consolidations` is a LIKE self-match and
  `prompt_caches`/`sync_queues` are unmeasured literals — while the retention pass that does
  remove the data from every table works and has no caller. The F19 analyst's mechanism claim is
  refuted; the challenger's is confirmed by my own flow-level probe.
- **CF11 — IMPROVE.** 0 critical, 3 major, 0 minor, 0 info. All six lenses reviewed.
  Classification, abstention, the never-mutate classes, and the digest-pinned oracle are sound.
  The `:failed` effect path returns a raw array and skips verification, compensation, terminal
  validation, and escalation (UPHELD, `major`); the README's repetition bound is implemented one
  gem over and not in the layer the claim points at; and the promotion authority artifact is
  minted by its consumer.

**Row counts as indexed for this flow package**: CF09 2 major / 1 minor; CF10 2 major / 1 minor;
CF11 3 major. Of the seven findings, **four are duplicates of existing gem findings** and are
marked as such — the boundary statements they carry are the new content, and they must not be
double-counted against F19/F20/F23. The **three net-new** boundary defects are `CF09-SEC-01`
(untrusted text into the automatic planning context with no trust label on the seam),
`CF09-MNT-01` (two disjoint "human gates", neither the approval policy path), and `CF11-COR-01`
(the raw-`Array` escape, the challenger's `F20-REL-02`, independently upheld here).

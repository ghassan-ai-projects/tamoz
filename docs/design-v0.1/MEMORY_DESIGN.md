# Three-layer memory — Experience, Knowledge, Wisdom

Tamoz Agent uses three durable memory layers:

```text
grounded observations
        │ admit
        ▼
1. Experience ── consolidate + review ──▶ 2. Knowledge
                                                │ evaluate + promote
                                                ▼
                                         3. Wisdom
```

Working context is deliberately outside this model. Current messages, plans, task state,
tool results, and unresolved effects live in the graph checkpoint. They may produce memory
candidates, but “present in context” does not mean “remembered.”

The three layers follow the architecture published in
[ALMS + OKF](https://ghassan-alhamoud.com/articles/alms-okf-integration-bridge.html):
experience captures operational lessons, knowledge contains curated reusable material, and
wisdom contains patterns synthesized across evidence. The governed lifecycle and four record
classes come from
[Every Token Is Rent](https://ghassan-alhamoud.com/articles/every-token-is-rent-memory-architecture.html).

## 1. Layers and record classes are different axes

| Layer | Question | Typical record classes | Default use |
|---|---|---|---|
| Experience | What happened, to whom, where, and with what result? | episodic observations and decisions | explicit retrieval and consolidation evidence |
| Knowledge | What grounded fact, constraint, decision, or procedure is reusable? | semantic and procedural records | authorized retrieval; narrow automatic recall |
| Wisdom | What evaluated strategy improves decisions across cases? | promoted planning, routing, verification, and recovery heuristics | behavior-version input |

The four memory classes remain useful:

- **working** — current task/checkpoint state, not a durable layer;
- **episodic** — normally Experience;
- **semantic** — normally Knowledge;
- **procedural** — Knowledge until evaluation proves a Wisdom-level strategy.

A class does not grant authority. A procedural record can explain a workflow without
authorizing tools, widening roots, or bypassing review.

## 2. Ownership and package boundary

No `tamoz-memory` gem ships in v0.1.

- `tamoz-core` exposes Store access through `Context`;
- `tamoz-graph` persists checkpoints and knows nothing about memory semantics;
- `tamoz-sqlite` provides Store and search capabilities honestly;
- `tamoz-agent` owns record, admission, retrieval, consolidation, and promotion protocols;
- Tamoz Agent owns tenant/project scopes, sensitivity policy, user authority, retention,
  automatic-recall policy, and Wisdom promotion authority;
- `tamoz-evals` measures memory value and gates Wisdom promotion.

A separate memory gem is considered only after another application needs the same lifecycle
without `tamoz-agent`. ALMS or another shared service may later implement the protocols; it
does not become a v0.1 runtime dependency.

## 3. Canonical record

Every durable memory is an immutable, versioned record:

```text
format_version
memory_id, record_version, layer, class, state
statement
epistemic_kind: observed | reported | inferred | prescribed
source_refs with content digests and observation times
owner, actor, tenant/project/session scopes
sensitivity and disclosure policy
confidence plus confidence method
valid_from, valid_until, review_at
supersession_key and contradiction_set_id
base_quality and last_evaluated_at
successful/failed/corrected use counters
created_by behavior/model/tool versions
```

Large source evidence remains in protected artifacts; the record keeps a resolvable
reference and digest. Unknown provenance is explicit. A model-generated summary never
becomes `observed`.

Updates append a new record version. States and source evidence are not edited in place to
make history look consistent.

## 4. Lifecycle

```text
observation
    │
    ▼
candidate ──admit──▶ active ──consolidate──▶ consolidated
    │                  │  │                       │
 reject                │  ├─supersede──────────▶ superseded
                       │  └─doubt/conflict─────▶ quarantined
                       │
                       └─expire/erase──────────▶ deleted + receipt
```

Each transition records actor, authority, reason, prior/new version, evidence, policy
version, timestamp, and trace id. `active` means eligible under retrieval policy; it does not
mean automatically injected.

Admission requires:

- a future decision or action the memory could improve;
- authenticated or explicitly untrusted provenance;
- layer/class, epistemic kind, scope, sensitivity, owner, and expiry/review;
- deduplication and contradiction checks;
- no secret or disallowed personal data;
- no speculation phrased as fact;
- no policy instruction promoted from untrusted content.

The default is rejection when ownership, scope, or sensitivity is unknown.

An explicit authorized owner request such as “remember this preference” may move a candidate
directly into active Knowledge without recurrence. The record remains `reported` or
`prescribed`, cites the owner request, carries scope/sensitivity/review metadata, and passes
conflict and policy checks. This fast path cannot label the statement `observed`, create
Wisdom, preserve a secret contrary to policy, or grant capability/approval.

## 5. Experience

Experience is append-oriented, grounded, and specific:

- task/session/incident identity;
- goal, accepted plan, key evidence, decisions, and outcome;
- tool/effect receipts and verification;
- corrections and human feedback;
- failure fingerprint and recovery result;
- links to the full protected trajectory.

Experience is not injected into every prompt. It is retrieved explicitly with actor,
project, time, and risk filters or used by background consolidation. Default retention is
bounded. Raw conversations and tool output are not copied wholesale.

Recalled memory is marked in the trace and excluded as new experience evidence. This avoids
the self-ingestion loop observed and explicitly defended against in OpenClaw: a retrieved
claim cannot become “more true” merely because the agent repeated it.

## 6. Knowledge

Knowledge contains compact, curated material:

- stable user preferences with observation and supersession metadata;
- verified project facts and decisions;
- constraints, definitions, and known exceptions;
- tested procedures and recovery runbooks;
- consolidated lessons with supporting and contradicting experience ids.

Experience-to-Knowledge promotion requires:

1. authorized candidate sources;
2. sufficient evidence quality or recurrence for the risk class;
3. contradiction search across active Knowledge;
4. synthesis that preserves scope, exceptions, and source links;
5. deterministic validation of record/schema/token limits;
6. human approval when the record becomes policy, durable user profile, or consequential
   procedure.

The explicit owner-admission fast path satisfies item 2 through owner authority rather than
recurrence; every other requirement remains.

Model consolidation proposes a record; it does not decide authority. An incompatible
prescription is quarantined or surfaced as a conflict set. Ranking one instruction slightly
higher is not conflict resolution.

Before a consolidation rewrite, Tamoz stores a preimage. The result must preserve protected
entries, source references, contradictions, and the configured token budget. Failure leaves
the prior Knowledge intact and records a rejected candidate.

## 7. Wisdom

Wisdom contains evaluated decision strategies, not grand summaries:

- when to ask rather than assume;
- which planning decomposition works for a task class;
- routing/tool/verification heuristics;
- recovery rules that passed replay, fault, and canary evaluation;
- known anti-patterns and stop conditions.

Knowledge-to-Wisdom promotion uses the self-improvement pipeline:

```text
knowledge/experience evidence
       → candidate
       → public development evaluation
       → protected holdout
       → authority gate
       → behavior version
       → monitor / rollback
```

The candidate cannot see the holdout, evaluator, or case-level outcome. Capability,
security, approval, evaluator, prompt-hierarchy, procedural-policy, and code changes require
human approval. A promoted Wisdom record influences new turns only through an explicit
`BehaviorTransition`; in-flight execution remains pinned.

Wisdom never grants credentials or permission. It can recommend an action, while the plan
review, authorization, approval, and effect wrappers still decide whether it may run.

## 8. Retrieval is authorization before ranking

```text
caller authority and surface
∩ tenant/user/project/session scope
∩ permitted layer and class
∩ active compatible record version
∩ sensitivity/disclosure policy
∩ validity and expiry
∩ behavior/graph compatibility where procedural
        │
        ▼
hybrid candidate retrieval
        │
        ▼
relevance + source quality + freshness + successful use
          − contradiction + correction + stale penalties
        │
        ▼
independent memory token budget
```

Unauthorized candidates never enter the ranker, logs, counts, or model context. Search
capabilities are honest: lexical-only stores do not claim semantic recall.

Every returned item includes memory id/version, layer/class, epistemic kind, provenance,
scope, confidence, observed/review times, state, and contradiction status. The model must be
able to distinguish a current human-approved procedure from an old uncertain episode.

Automatic injection is narrower than explicit retrieval:

- Experience: never automatic;
- Knowledge: only trusted, active, non-conflicting, high-confidence records allowed by the
  surface policy;
- Wisdom: only the behavior-version snapshot selected at the turn boundary.

Memory has a token budget separate from user input, tools, and recent history. “Available”
does not mean “must fill context.”

## 9. Consolidation pipeline

Tamoz adopts OpenClaw's useful controls without copying its sleep metaphor as architecture:

1. **Stage** grounded recent Experience, deduplicate, and remove recalled/context-derived
   content.
2. **Reflect** on recurrence, conflicts, exceptions, and candidate usefulness without
   writing durable Knowledge.
3. **Promote** only candidates that pass deterministic provenance, scope, recurrence,
   diversity, confidence, taint, and budget gates.
4. **Consolidate** through a bounded model call, then validate source preservation,
   prior-entry loss, contradiction handling, and output format.
5. **Record** a human-readable review artifact that is never itself a promotion source.

The implementation records ingestion checkpoints and candidate identities, so rerunning a
sweep cannot reinforce the same evidence repeatedly. Scheduled consolidation is a normal
reviewed Tamoz task and cannot mutate Knowledge or Wisdom without the appropriate authority.

## 10. Forgetting, correction, and deletion

Priority is recomputed from immutable `base_quality` and `last_evaluated_at`; repeated
sweeps never subtract lifetime decay from an already decayed score.

Forgetting may:

- lower retrieval priority;
- require reverification;
- supersede or quarantine;
- soft-delete for audit;
- hard-delete after the retention boundary.

Corrections link the incorrect and replacement versions, remove the incorrect version from
active retrieval immediately, and propagate to indexes, caches, consolidations, and behavior
candidates. Deletion covers the primary record, lexical/vector indexes, derived memories,
prompt caches, sync queues, protected artifacts under policy, and backups under their
retention rules. A deletion receipt names what was removed, retained, or pending.

Pinned memory is limited to human-approved safety/legal constraints and durable decisions,
with mandatory review dates.

## 11. Evaluation

`tamoz-evals` runs the same task corpus under:

1. no durable memory;
2. Experience retrieval only;
3. Experience + Knowledge;
4. Experience + Knowledge + promoted Wisdom.

The scorecard includes:

- precision@k and helpful recall@k;
- task-success delta;
- contradiction, stale-recall, and sensitive-recall rates;
- wrong-memory harm and correction latency;
- retrieval token/cost overhead;
- provenance coverage;
- consolidation source-preservation and prior-entry-loss rates;
- promotion precision and protected-holdout delta;
- deletion-propagation latency;
- successful attributable reuse.

Sensitive-recall and unauthorized-recall rates are hard-zero gates. A memory feature does
not ship because retrieval relevance improved while task outcomes, privacy, or cost became
worse.

## 12. Explicit non-goals

The `tamoz-stream` event log, features, and Situations are operational evidence, not memory
layers. Only a completed bounded episode plus independently observed Outcome may propose
Experience. A sensor repetition or recalled Situation cannot directly become Knowledge or
Wisdom.

- no chat transcript presented as durable memory;
- no single vector database queried as the whole memory architecture;
- no hidden model state;
- no automatic conversion of repeated claims into facts;
- no memory-based permission grant;
- no cross-user learning without explicit shared scope and authority;
- no Wisdom promotion outside `tamoz-evals`;
- no promise that more remembered material makes the agent smarter.

The decisive metric is successful, attributable reuse without unacceptable stale,
contradictory, sensitive, or costly recall.

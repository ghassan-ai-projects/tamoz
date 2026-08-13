# Three-layer memory — Experience, Knowledge, Wisdom

Tamoz Agent keeps three durable memory layers with distinct authority, lifecycle, and retrieval rules. Working context is deliberately outside the model: current messages, plans, task state, tool results, and unresolved effects live in the graph checkpoint. "Present in context" does not mean "remembered."

Source: [`docs/design-v0.1/MEMORY_DESIGN.md`](../../docs/design-v0.1/MEMORY_DESIGN.md).

Current version: `0.1.0.alpha.1` (pre-release).

## The three layers

```text
grounded observations
        │ admit
        ▼
1. Experience ── consolidate + review ──▶ 2. Knowledge
                                                │ evaluate + promote
                                                ▼
                                         3. Wisdom
```

| Layer | Question | Typical record classes | Default use |
|---|---|---|---|
| Experience | What happened, to whom, where, and with what result? | episodic observations and decisions | explicit retrieval and consolidation evidence |
| Knowledge | What grounded fact, constraint, decision, or procedure is reusable? | semantic and procedural records | authorized retrieval; narrow automatic recall |
| Wisdom | What evaluated strategy improves decisions across cases? | promoted planning, routing, verification, and recovery heuristics | behavior-version input |

The four record classes (working, episodic, semantic, procedural) are a separate axis from layers. A class does not grant authority: a procedural record can explain a workflow without authorizing tools, widening roots, or bypassing review.

## The canonical record

Every durable memory is an immutable, versioned record: `memory_id` and `record_version`, layer and class, state, the `statement`, **epistemic kind**, `source_refs` with content digests and observation times, owner/actor/scopes, sensitivity and disclosure policy, confidence plus its method, validity and review windows, supersession and contradiction links, use counters, and the behavior/model/tool versions that created it.

**Epistemic kinds** — `observed | reported | inferred | prescribed` — are part of the record. Unknown provenance is explicit, and a model-generated summary never becomes `observed`.

**Scopes** — tenant/user/project/session scopes and owner identity — bound every record. Records whose ownership, scope, or sensitivity is unknown are rejected by default at admission.

Updates append a new record version; states and source evidence are never edited in place to make history look consistent.

## Lifecycle and transitions

```text
observation → candidate ──admit──▶ active ──consolidate──▶ consolidated
                                (supersede → superseded)
                                (doubt/conflict → quarantined)
                                (expire/erase → deleted + receipt)
```

Each transition records actor, authority, reason, prior/new version, evidence, policy version, and timestamp. Admission requires a future decision the memory could improve, authenticated or explicitly untrusted provenance, complete scope/sensitivity metadata, deduplication and contradiction checks, and no secret, disallowed personal data, speculation phrased as fact, or policy promoted from untrusted content.

An explicit authorized owner request ("remember this preference") may admit a record directly into active Knowledge; the record stays `reported` or `prescribed`, cites the owner request, and still cannot label the statement `observed`, create Wisdom, preserve a secret contrary to policy, or grant capability/approval.

## Experience

Experience is append-oriented, grounded, and specific: task/session/incident identity, goal, accepted plan, key evidence, decisions, outcome, tool/effect receipts, verification, corrections, failure fingerprints, and links to the protected trajectory. It is **never injected automatically**; it is retrieved explicitly with actor, project, time, and risk filters, or used by background consolidation. Recalled memory is marked in the trace and excluded as new Experience evidence, so a retrieved claim cannot become "more true" by repetition.

## Knowledge and consolidation

Knowledge contains compact, curated material: stable preferences, verified project facts and decisions, constraints and exceptions, tested procedures, and consolidated lessons with supporting and contradicting Experience ids. Promotion from Experience requires authorized sources, sufficient evidence quality or recurrence for the risk class, contradiction search, synthesis that preserves scope and source links, deterministic validation, and human approval when the record becomes policy, a durable user profile, or a consequential procedure.

The consolidation pipeline stages grounded Experience, reflects on recurrence and conflicts without writing, promotes only candidates that pass deterministic gates, consolidates through a bounded model call with source-preservation validation, and records a human-readable review artifact that is itself never a promotion source. A preimage is stored before any rewrite; failure leaves the prior Knowledge intact.

## Wisdom

Wisdom holds evaluated decision strategies — when to ask rather than assume, which planning decomposition works for a task class, routing/tool/verification heuristics, recovery rules that passed replay/fault/canary evaluation, and known anti-patterns. Promotion runs the self-improvement pipeline: candidate → public development evaluation → protected holdout → authority gate → behavior version → monitor/rollback. The candidate cannot see the holdout. Capability, security, approval, evaluator, prompt-hierarchy, procedural-policy, and code changes require human approval, and generated content cannot approve itself. A promoted Wisdom record influences new turns only through an explicit behavior transition; in-flight execution remains pinned. Wisdom never grants credentials or permission.

## Retrieval is authorization before ranking

Candidates are filtered by caller authority and surface, scope, permitted layer/class, active compatible record version, sensitivity/disclosure policy, validity and expiry, and behavior/graph compatibility — *before* ranking. Unauthorized candidates never enter the ranker, logs, counts, or model context. Ranking then weighs relevance, source quality, freshness, and successful use against contradiction, correction, and staleness penalties.

Automatic injection is narrower than explicit retrieval:

- Experience: never automatic;
- Knowledge: only trusted, active, non-conflicting, high-confidence records allowed by the surface policy;
- Wisdom: only the behavior-version snapshot selected at the turn boundary.

Memory has a token budget separate from user input, tools, and recent history; "available" does not mean "must fill context." Search capabilities are honest: lexical-only stores do not claim semantic recall.

## The durable index

Memory lives in the durable Store (via `tamoz-sqlite`), not in the graph checkpoint. The Store keeps the immutable record versions, their lexical/vector indexes, and the scoping and search capabilities behind retrieval. Deletion and correction propagate to the primary record, indexes, derived memories, prompt caches, and backups under their retention rules, with a deletion receipt naming what was removed, retained, or pending. Pinned memory is limited to human-approved safety/legal constraints and durable decisions, with mandatory review dates.

## Forgetting, correction, and deletion

Priority recomputes from immutable `base_quality` and `last_evaluated_at`, so repeated sweeps never compound decay. Forgetting may lower retrieval priority, require reverification, supersede or quarantine, soft-delete for audit, or hard-delete after the retention boundary. Corrections link the incorrect and replacement versions, remove the incorrect version from active retrieval immediately, and propagate everywhere.

## Evaluation

`tamoz-evals` runs the same task corpus under no memory, Experience only, Experience + Knowledge, and all three layers, scoring precision@k and helpful recall@k, task-success delta, contradiction/stale/sensitive recall rates, wrong-memory harm, correction latency, retrieval cost, provenance coverage, consolidation source preservation, promotion precision and protected-holdout delta, deletion latency, and successful attributable reuse. Sensitive-recall and unauthorized-recall rates are hard-zero gates: a memory feature does not ship because relevance improved while outcomes, privacy, or cost worsened.

## Next reads

- [`./README.md`](./README.md) — the design index
- [`../overview/concepts.md`](../overview/concepts.md) — how memory relates to working context
- [`../architecture/invariants.md`](../architecture/invariants.md) — the invariant contract
- [`../../docs/design-v0.1/MEMORY_DESIGN.md`](../../docs/design-v0.1/MEMORY_DESIGN.md) — the authoritative design record
- [`../adr/README.md`](../adr/README.md) — ADR-026 and ADR-027, the memory decisions

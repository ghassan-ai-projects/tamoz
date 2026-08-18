# Pattern 06 — Memory & Context Management

> **Rev 2 · 2026-08-16.** Symbol names are the authoritative anchor — **line numbers are approximate** (written against tamoz `smarter-tamoz`@`5b07557` / agentic-stream `smarter-agent`@`2e8aa3a`; HEAD `ebf1e23` / `c067127`). **`*.go` refs live in the agentic-stream repo; `*.rb` in tamoz.** See [`README.md`](README.md) · [`00-REVISION-NOTES.md`](00-REVISION-NOTES.md) · [`GLOSSARY.md`](GLOSSARY.md).

Handbook: chapter-06-memory-context-management.md. Verdict: **Strong — the hardest
requirements (authorize at the query boundary, provenance on every record,
deterministic write policy, cross-tenant refusal, model-can-only-propose
consolidation) all conform. Missing: semantic supersede-resolution at retrieval,
context-window compaction, per-component token-budget accounting, calibrated
abstention, cross-tenant canaries, end-user correction/erasure lifecycle.** Builds
on: README substrate; pattern-01 (the recall node feeds the loop's frame).
**Autonomy: n/a (support pattern).**

## Handbook definition (owner's)

- Context is a budget; memory is state. Input budget = limit − output − reserve;
  five payers (policy, tool interface, working state, evidence, output headroom).
  "Design eviction before storage."
- Working memory = task state, not transcript: keep decisions/rationale structured,
  externalize tool results as typed refs, drop scratch; compaction converts older
  transcript into a structured checkpoint (schema, hard budget, fail-closed on
  constraint loss); sessions resume, don't restart.
- Four tiers: working / episodic / semantic (versioned claims with valid_from,
  supersedes, source) / procedural. A vector index assists retrieval; it is never
  the system of record.
- Read path authorizes first (query boundary, model time, supersede-resolution
  before packing, calibrated abstention, pack to token budget with source IDs).
  Retrieved content is data, never instructions.
- Write policy defaults to skip (purpose/authority/subject/consent/novelty/time/
  deletion checks); merge-don't-accumulate by subject+predicate+scope; deletion is
  a write-path feature.
- Provenance on every record; memory is permissioned; four poisoning doors
  (inference promotion, persistent injection, stale truth, identity confusion);
  cross-tenant canaries.

## How tamoz implements it (HEAD)

- **Tiers:** layers `experience / knowledge / wisdom`, classes
  `episode/procedure/policy/profile/constraint/strategy/preference`,
  `EPISTEMIC_KINDS = observed/reported/inferred/prescribed` — memory/record.rb:30-45.
- **Recall is a graph node, journaled:** `EpisodeNodes#recall` routes through
  `EffectDispatcher.run` under `RECALL_OPERATION` with a `LogicalCallKey` (replay
  returns recorded projections); cross-checks each projection's tenant —
  episode_nodes.rb:54-128.
- **Authorized retrieval (stronger than the handbook bar):** `SituationRecaller`
  validates caller identity + tenant + snapshot boundary; SQL-level search filters
  state∩scopes∩sensitivity≤caller∩compatibility∩validity before ranking;
  sensitivity-blocked rows are hard-zero, never materialized — memory_repository.rb:198-329.
- **Recall contract:** empty-term scoped pass restricted to `:observed` verified
  episodes, self-excluding, bounded (64 records / 32 KiB), `situation_boundary` =
  zero cross-boundary recall — situation_recaller.rb:97-133.
- **Write policy is deterministic Admission:** 11 reject reasons
  (`secret_shaped, missing_provenance, speculation_as_fact, recalled_as_new,
  duplicate_identity`, …); `:observed` requires an authenticated
  `VerifiedOutcomeReference`; rejects are durable results, not exceptions —
  memory/admission.rb:26-221.
- **Consolidation: model proposes, 7 deterministic gates decide** (recurrence ≥2,
  diversity ≥2 identities, confidence ≥0.5, taint=recalled→reject); preimage stored
  before rewrite; CAS-versioned consume — memory/consolidation.rb:25-181.
- **Ranking + budget:** `rank_score = base_quality + source_quality + freshness −
  penalties`; `retrieval_token_budget=1024`, max 8 auto-injected; 30-day linear
  freshness decay — memory/retrieval.rb:93-156.
- **Lifecycle/deletion:** every transition appends a version; delete emits an
  invariant-54 receipt; retention-based purge (default 86 400 s) — memory/lifecycle.rb.
- **Frame injection:** fenced, attributed `{id:"memory:<digest>", statement}` —
  untrusted data, citable only via digest — episode_frame_builder.rb:138-142.

## Divergence from the handbook

1. **No semantic supersede-resolution at retrieval** — the `:knowledge` layer is the
   semantic analog, but retrieval filters `state∈(active,consolidated)` and does NOT
   resolve superseded versions on the same subject+predicate scope (supersession
   exists in lifecycle.rb but is not a read-path step); lexical-only matching,
   `store.rb` refuses semantic search.
2. **No relevance ranking / calibrated abstention** — ranking is quality/freshness;
   no labeled-threshold abstention.
3. **No context-window management / compaction** — each episode frame is rebuilt
   deterministically; no cross-episode compaction into a structured checkpoint, no
   five-payer token budget accounting (ReceiptBudgetController tracks provider
   usage, not the payer split).
4. **No eviction beyond retention purge** — freshness decay is ranking-only; no
   decay-vs-hard-expiry separation surfaced to retrieval; no deletion-shadow
   inventory.
5. **No end-user correction/consent/erasure lifecycle** — purge is retention-driven.
6. **No cross-tenant canaries** in the test suite (hard-zero blocking exists).

## How it SHOULD be implemented (on existing seams)

1. **Semantic tier = versioned knowledge with supersede-resolution before packing.**
   In `Retrieval#recall` (retrieval.rb:45-78), after candidate selection, drop
   records superseded by a newer active sibling on the same subject+predicate scope
   (lifecycle.rb already appends versions; repository already filters validity).
   This is a deterministic filter, not an embedding index.
2. **Context-window management.** Extend `ReceiptBudgetController` reconciliation
   (receipt_budget_controller.rb:32-63) toward the five-payer split, and add a
   compaction step for cross-episode working state in
   `session_planning_context.rb:122-141`: keep goal/constraints/decisions in
   structured session state (plan.rb already holds them), externalize bulky evidence
   via trace pointers, fail closed (split the task) if required state exceeds budget
   — mirroring `add_memory_context`'s auto-injection budget (max 8, 1024 tokens).
3. **Freshness/eviction as data** — promote the freshness/stale-penalty weights
   (retrieval.rb:109-121) into a documented decay policy; separate decay from hard
   expiry (MemoryRecord fields already support both).
4. **Calibrated abstention** — permit empty results with thresholds derived from
   labeled recall queries (empty results already allowed by drop reasons).
5. **Canaries** — add cross-tenant canary records asserting the hard-zero scan
   (memory_repository.rb:277-329) never materializes restricted rows.
6. **Vector/semantic index: do NOT add** (**defer-by-design**) unless corpus scale
   forces it — lexical + digest identity is deterministic and replay-stable (P3
   contract). Record as a deliberate divergence.

## Gap list (priority order)

| # | Gap | Landing spot |
|---|---|---|
| Y1 | Supersede-resolution before packing | `Retrieval#recall` (retrieval.rb:45-78) + lifecycle supersede |
| Y2 | Context compaction to structured checkpoint | `session_planning_context.rb:122-141` |
| Y3 | Five-payer token budget + output reserve | `receipt_budget_controller.rb:32-63` |
| Y4 | Calibrated abstention on retrieval | retrieval.rb + situation_recaller.rb:97-119 |
| Y5 | Cross-tenant canaries, target zero | memory test suite vs `memory_repository.rb:277-329` |
| Y6 | End-user correction/consent/erasure | lifecycle.rb + memory_repository.rb:419-516 |
| Y7 | Decay-vs-expiry policy as data | retrieval.rb:109-121 weights |

**Tests to update:** Y1 changes `Retrieval#recall` — the memory repository tests
(`test/memory_repository_test.rb`, `test/memory_engine_test.rb`,
`test/stream_episode_skills_memory_test.rb`, recall contract tests) assert current retrieval
semantics; Y5 adds canary cases to the same suite.

# P11 — three-layer memory: implementation plan

Status: accepted for implementation (revision 3 — checkpoint deep-review transaction
and proof-baseline corrections integrated; see
`docs/reviews/DESIGN_CHECKPOINT_6FF0D40_DEEP_REVIEW.md`)
Authoritative inputs: `docs/design-v0.1/MEMORY_DESIGN.md` (source of truth for semantics),
`AGENT_DESIGN.md` §14, invariants 24–31, 16–18, the P11 card in
`docs/PROJECT_HANDOVER_PLAN.md`, and the existing Store/record machinery in
`tamoz-sqlite` + `tamoz-agent`.

Phase activation rule: this plan is committed as a design artifact while P10 is still the
active implementation phase. Under the single-active-phase order, P11 waits for DR-4,
DR-5, P16, and P17 to close; no P11 code lands before that.

## 1. Scope commitment and phase outcome

The handover card's outcome, verbatim: "Experience, Knowledge, and Wisdom are distinct
attributable versioned layers; retrieval authorizes before ranking; correction/deletion
propagates with proof; each layer earns measurable value over the prior treatment."

| Outcome clause | Work package | Proof |
|---|---|---|
| distinct attributable versioned layers | P11-D record/lifecycle; P11-A/C/W | one immutable versioned `MemoryRecord`; layer/class/state/kind never ambiguous in any stored record |
| retrieval authorizes before ranking | P11-B | authorization filter runs in SQL **before** any row is materialized or decrypted (see §4 P11-B); unauthorized recall and sensitive-recall rates are hard-zero, asserted by the decryption-boundary probe |
| correction/deletion propagates with proof | P11-D2 | supersede/quarantine is immediate; propagation to indexes/derived/caches/artifacts under policy; a deletion receipt (invariant-54 shape) names what was removed, retained, pending |
| each layer earns measurable value | P11-ED + P11-E | the four-treatment harness (P11-ED) runs one corpus under no-memory / Experience / +Knowledge / +Wisdom; decisive metric is successful attributable reuse without unacceptable stale/contradictory/sensitive/costly recall |

Explicit non-goals (design §12, binding): no chat transcript as durable memory; no single
vector database as the whole architecture; no hidden model state; no automatic conversion
of repeated claims into facts; no memory-based permission grant; no cross-user learning
without explicit shared scope and authority; no Wisdom promotion outside the gated
pipeline; no promise that more remembered material makes the agent smarter.

## 2. Package boundary

No `tamoz-memory` gem ships in v0.1 (design §2). Ownership:

- `tamoz-sqlite` — Store (unchanged surface) plus **one new lexical memory index table**
  added by P11 (see §4 P11-B; the index is an explicit P11-B work item, filtered in SQL
  before materialization, with deletion propagation proven before any read path uses it).
- `tamoz-graph` — checkpoints; stays memory-agnostic (no memory semantics leak in).
- `tamoz-agent` — owns `Tamoz::Agent::Memory`: canonical record, admission, retrieval,
  consolidation, promotion, correction/deletion protocols. All P11 code lands under
  `gems/tamoz-agent/lib/tamoz/agent/memory/`.
- `tamoz-evals` — the P11-ED treatment harness and P11-E comparison; never a production
  dependency (lazy-load rule, invariant 54-adjacent).

**Atomic storage seam (DC-3):** public `Store#put` owns its transaction, so it cannot
be called inside a second transaction that also updates the lexical index. P11 adds a
`tamoz-sqlite`-owned internal `MemoryRepository` implementation. It uses one shared
private Store append primitive that accepts the caller's existing transaction; public
`Store#put` delegates to the same primitive and its public surface is unchanged.
`MemoryRepository#append(record, expected_version:)` owns ONE transaction for Store
version/head + index row/history. `tamoz-agent` owns record and authorization semantics
and depends on the structural repository contract. No `send` into Adapter, nested
transaction, or best-effort two-write sequence is conforming.

P11 consumes the next checksummed SQLite migration available at activation (expected
`MIGRATION_2` on the current baseline). The test asserts monotonic migration ordering so
later phases cannot reuse the same ordinal.

Dependency rule (checked by the existing dependency-isolation test): `tamoz-agent` may use
`tamoz-sqlite` (already does) and `tamoz-core`; the record/admission/retrieval path loads
with no provider (invariant 11). The only model call in the whole phase is the bounded
consolidation call (P11-C) and the P11-ED evaluation runs — both on explicitly
provider-loaded boundaries.

Credentials/secrets: invariant 24 applies. Memory admission rejects secret-shaped
content; the sensitive flag rides the Store's existing protection; no secret value may
appear in a retrieval candidate, an index row's searchable columns, a consolidation
preimage, a prompt, or a receipt. The lexical index stores only searchable metadata
columns plus the memory id/version — never the statement when the record is sensitive.

## 3. Canonical record and storage (P11-D)

`MemoryRecord` is an immutable, versioned `Data` carrying exactly the design §3 fields:

```ruby
MemoryRecord = Data.define(
  :format_version,          # 1
  :memory_id, :record_version, :layer, :class, :state,
  :statement,               # bounded UTF-8 text
  :epistemic_kind,          # :observed | :reported | :inferred | :prescribed
  :source_refs,             # [{identity, digest, observed_at}] — never bare model claims
  :owner, :actor,           # authenticated owner; acting principal
  :scopes,                  # {tenant:, user:, project:, session:}
  :sensitivity,             # :public | :internal | :sensitive
  :disclosure_policy,       # explicit policy id
  :confidence, :confidence_method,
  :valid_from, :valid_until, :review_at,
  :supersession_key, :contradiction_set_id,
  :base_quality, :last_evaluated_at,
  :use_counts,              # successful/failed/corrected
  :created_by,              # behavior/model/tool versions
  :compatibility            # {graph_version:, behavior_version:} for procedural records
)
```

Storage rules:

- Stored under `Store` namespace `tamoz.memory.<tenant>` keyed by
  `<layer>/<memory_id>`, versioned via the Store's compare-and-append; every update
  appends a new `record_version`; states and source evidence are never edited in place.
- Codec registered in the allowlist (invariant 18); unknown `format_version` fails
  before partial load.
- `statement` bounded by `MemoryLimits` (see §9); oversized candidates rejected at
  admission, never truncated silently.
- Provenance explicit: a model-generated summary is `:inferred`/`:reported` with the
  generating behavior version, never `:observed`. Unknown provenance is explicit and
  blocks promotion to Knowledge.
- **Session-record sentinel (C4):** the session record gains an optional
  `memory_epoch` HASH-like field: `{"layers" => [...], "retrieval_policy" => ...,
  "catalog_digest" => ...}` with legacy sentinel `"none"` filled at load when memory did
  not exist (RECORD_VERSION stays 1; exact P9 `LEGACY_SKILL_EPOCH` pattern). Pre-P11
  sessions resume with byte-identical behavior: zero memory injection, identical prefix
  digest. Retrieval/injection policy is per-session (the snapshot rides the session
  record), scoped by the tenant namespace.

Lifecycle states (design §4, with C5 amendments): `candidate`, `active`, `consolidated`,
`rejected` (first-class; used by admission default-rejection and by P11-C's
"records a rejected candidate" — a rejected admission is a durable record with
`state: :rejected` and a rejection reason, so rerun-idempotency can key on candidate
identity), `superseded`, `quarantined`, `deleted` (tombstone) → `purged` (hard-delete,
§4 P11-D2). Transitions:

```text
candidate → active (admit) | rejected (reject)
active → consolidated | superseded | quarantined | deleted
consolidated → superseded | quarantined | deleted
any → deleted (expiry: deterministic system transition, actor = :system,
      policy_version bound, valid_until passed)
deleted → purged (after retention boundary, §4 P11-D2)
```

Every transition records actor, authority, reason, prior/new version, evidence, policy
version, timestamp, trace id. `active` means eligible under retrieval policy; it never
means automatically injected.

**Retrieval-eligible state set (C5):** `active` ∪ `consolidated`. Never
`superseded/quarantined/deleted/purged/rejected`.

Admission requires (all, fail-closed): a future decision or action the memory could
improve; authenticated or explicitly untrusted provenance; layer/class/epistemic kind/
scope/sensitivity/owner/expiry; deduplication and contradiction checks; no secret or
disallowed personal data; no speculation phrased as fact; no policy instruction promoted
from untrusted content. Default is rejection when ownership/scope/sensitivity unknown.

**Deterministic admission gate (C7):** "could improve a future decision or action" is
decided by a deterministic proxy on the no-provider path — the candidate must come from
(a) a completed bounded episode with an independently observed Outcome (P11-A), (b) an
explicit authorized owner request (P11-C fast path), or (c) a consolidation candidate
that passed the §9 deterministic gates. No model call decides admission; a model may
*propose* a candidate (consolidation), never admit one. This keeps the admission path
provider-free and deterministic.

## 4. Work packages and proof

### P11-A — Experience (append-oriented, grounded, specific)

Admission sources: completed bounded episodes only — task/session identity, accepted
plan digest, key observations, decisions, tool/effect receipts and verification,
corrections and human feedback, failure fingerprint and recovery result, links to the
protected trajectory. Never: raw transcripts, recalled content, model claims without a
source, raw Situation (Situation→memory coupling arrives with P14's completed-episode
seam, documented, not implemented blind).

- Never injected into every prompt; retrieved explicitly with actor/project/time/risk
  filters, or consumed by background consolidation.
- Recalled memory is marked in the trace and excluded as new Experience evidence
  (anti self-ingestion loop; asserted by a test).
- Default retention bounded (`MemoryLimits`).

Proof: admission reject matrix (unbounded, secret-shaped, unprovenanced, speculation-as-
fact, recalled-as-new); one real completed episode admitted with exact digests; recall
marked-and-excluded test; retention bound.

### P11-B — retrieval: authorization before ranking

**Lexical index (C1, explicit work item):** P11-B adds one `tamoz-sqlite` table
`tamoz_memory_index` (identity/primary key:
`(store_namespace, memory_id, record_version)`; columns: `memory_id`, `record_version`, `layer`, `class`, `state`,
`scopes_tenant`, `scopes_user`, `scopes_project`, `sensitivity`, `valid_until`,
`compatibility_graph`, `compatibility_behavior`, `statement_search` (only for
non-sensitive records), `searchable? = true`). Rows are written through
`MemoryRepository` in the same transaction as the Store append. **Deletion/update propagation to the index is
proven before the read path uses it (P11-D2's index-propagation test runs before
P11-B's retrieval is wired)** — the work order is D2-index-propagation → B.

Pipeline (design §8, hard gate): the SQL query filters on
`scopes_* ∩ layer/class ∩ state ∈ eligible-set ∩ sensitivity ≤ caller ∩ valid_until ≥ now
∩ compatibility match` **before any row is materialized or decrypted**; the caller's
authority is bound into the query as parameters, so an unauthorized candidate never
reaches the ranker, logs, counts, or model context (asserted by the decryption-boundary
probe: instrument the protection codec and assert unauthorized sensitive rows were never
decrypted during a scan). THEN candidate retrieval → THEN ranking.

- Sensitive records store no searchable statement text (only metadata columns); the
  statement is read only through the Store's protected `get` after authorization.
- Honest searchable claim (precise): exact/prefix matching on the indexed columns named
  above; no semantic recall, no full-statement substring, no vector search — the index
  `searchable?` reports exactly that.
- Ranking: relevance + source quality + freshness + successful use − contradiction −
  correction − stale penalties; recomputed from immutable `base_quality` and
  `last_evaluated_at` (never double-decay).
- Every returned item carries memory id/version, layer/class, epistemic kind, provenance,
  scope, confidence, observed/review times, state, contradiction status.
- Automatic injection narrower than explicit retrieval: Experience never automatic;
  Knowledge only trusted/active/non-conflicting/high-confidence per surface policy;
  Wisdom only the behavior-version snapshot selected at the turn boundary. Memory token
  budget separate and bounded (`MemoryLimits`, §9); "available" ≠ "must fill".

Proof: each §8 filter independently demonstrable; cross-scope leak test; sensitivity
gate test (with decryption-boundary assertion); honest-capability test; returned-metadata
completeness test; token-budget bound test; index-propagation-before-read ordering test.

### P11-C — Knowledge (compact, curated, gated)

Promotion from Experience requires: authorized candidate sources; sufficient evidence
quality or recurrence for the risk class; contradiction search across active Knowledge;
synthesis preserving scope/exceptions/source links; deterministic validation of
record/schema/token limits; human approval when the record becomes policy, a durable
user profile, or a consequential procedure.

Consolidation pipeline (design §9): stage → reflect (no durable write) → promote
(deterministic gates: provenance, scope, recurrence, diversity, confidence, taint,
budget) → consolidate through **one bounded model call** (the phase's only
provider-loaded path besides evaluation) → validate source preservation, prior-entry
loss, contradiction handling, output format → record a human-readable review artifact
(never itself a promotion source). Ingestion checkpoints + candidate identities so a
rerun cannot reinforce the same evidence (asserted). Candidates that fail the
deterministic gates are recorded `state: :rejected` with the failing gate named.

- Before a consolidation rewrite, store a preimage; result must preserve protected
  entries, source references, contradictions, and the token budget; failure leaves prior
  Knowledge intact and records a rejected candidate.
- Model consolidation proposes; never decides authority. Incompatible prescription →
  quarantined or surfaced as a contradiction set (never "rank slightly higher").
- Explicit owner fast path (design §4): an authorized owner request may admit a candidate
  directly to `active` Knowledge as `:reported`/`:prescribed`, citing the owner request,
  with scope/sensitivity/review metadata, passing conflict and policy checks. Cannot
  label `:observed`, create Wisdom, preserve a secret contrary to policy, or grant
  capability/approval.

Proof: promotion gate matrix; preimage-preservation test (protected entries survive);
contradiction quarantine test; owner fast-path test (including its three negatives);
rerun-idempotency test (candidate identity prevents re-reinforcement).

### P11-D2 — correction and deletion

- Correction links incorrect and replacement versions (the new record carries the prior
  version digest, so no historical-version read is needed); removes the incorrect version
  from active retrieval immediately; propagates to the lexical index, caches,
  consolidations, and behavior candidates.
- Deletion covers primary record, lexical index, derived memories, prompt caches, sync
  queues, protected artifacts under policy, backups under retention. A receipt (invariant-
  54 shape: what removed/retained/pending, counts, purged_at) is emitted for both
  tombstone-delete and hard-purge.
- **Purge owner (C6):** hard-delete after the retention boundary is a
  `tamoz-agent`-orchestrated `MemoryRepository#purge` pass over the Store's version rows (mirroring the
  existing thread-purge machinery in `adapter.rb purge_thread` + `limits.rb
  deletion_retention`). The sqlite repository, not agent code reaching into tables,
  selects `deleted` Store keys whose retention window expired,
  physically removes the version rows (and index rows), and emits the purge receipt.
  Backups fall under their own retention rules; the receipt names what is pending there.
- Forgetting: lower priority / require reverification / supersede / quarantine /
  soft-delete for audit / hard-delete after the retention boundary.
- Pinned memory limited to human-approved safety/legal constraints and durable
  decisions, with mandatory review dates.

Proof: correction makes the bad record leave active recall (query test) and leaves the
index; deletion propagation covers every named sink with a receipt; purge physically
removes ciphertext rows (asserted on the store table) after the retention boundary;
pin/retention-boundary test.

### P11-W — Wisdom (evaluated strategies only)

Promotion pipeline (design §7): knowledge/experience evidence → candidate → public
development evaluation → protected holdout → authority gate → behavior version →
monitor/rollback. The candidate cannot see the holdout, evaluator, or case-level
outcome. Capability/security/approval/evaluator/prompt-hierarchy/procedural-policy/code
changes require human approval.

**BehaviorTransition (C3, specified; owned by DR-1):** a promoted Wisdom record is activated only
through a `BehaviorTransition` record consumed at the FIRST INTAKE OF A THREAD — the
revision-4 serialized control record + claim→apply→finalize model (one pending id,
allocator distinct from active version, registry CAS before any checkpoint write,
finalize idempotent keyed by `transition_id`).
Existing threads are pinned: resume/continue/redirect are `boundary: false` and never
rewrite the session record. The record shape, snapshot bounds, cache-epoch contract,
and acceptance tests are defined in `docs/DR1_BEHAVIOR_TRANSITION_PLAN.md` (revision
3); this section summarizes. The transition
carries: `wisdom_id`, `wisdom_digest`, prior/new `behavior_version`,
`cache_epoch_before/after`, `rollback_target`, `activated_at`, `activation_scope`.
Resume with a changed behavior version fails closed (old sessions keep the old version).

**Cache epoch (C3, invariant 16/28):** because the Wisdom snapshot is injected into the
prompt prefix, activation MUST create a new cache epoch with a recorded reason; a
P11-W proof asserts: promotion → prefix digest moved (epoch changed) AND an in-flight
turn still runs on the old epoch AND rollback returns the epoch byte-identically.

**P11-W → P12-I handoff (C3):** P11-W builds the invariant-28 promotion engine
(provenance, paired eval, holdout, human gates, behavior version, monitor/rollback) that
P12-I1 consumes. Declared here: P12-I reuses P11-W's candidate/eval/holdout/transition
machinery and adds only healing-rule-shaped candidates + the 250-case fault injection;
P12 does NOT build a second promotion engine. The candidate shape differs (heuristic vs
Wisdom record) but the pipeline, gates, and transition records are shared.

- Wisdom never grants credentials or permission; it recommends, while plan review,
  authorization, approval, and effect wrappers still decide.
- v1 scope: at most ONE promoted planning or routing heuristic candidate, with the full
  pipeline; nothing self-approved.

Proof: holdout isolation (candidate never sees holdout — asserted at data-flow level);
authority gate test (no promotion without the required human gate); BehaviorTransition
pinning test (in-flight execution unchanged); cache-epoch-change test (above); monitor/
rollback test.

### P11-ED — treatment evaluation harness (C2, explicit work package)

The existing DR-3 `Tamoz::Evals::Harness` gains the P11 production-memory adapter; P11
does not build a second treatment harness. The existing lazy-loaded evaluator profile runs one
corpus identity; per-treatment config injection (no memory / Experience-only /
+Knowledge / +Wisdom) driving the same task set; accounting for retrieval token/cost,
recall, attribution (each reused memory's influence traced to the decision it changed);
and result artifacts keyed by treatment. Two-layer gating per the repo's convention:
deterministic controller-scripted runs in CI (a mock provider with scripted turns
asserting prompt content and reuse attribution); a live-provider four-treatment run
gated behind an env flag (e.g. `RUN_MEMORY_EVAL=1`) for the manual E2E pass. The
scorecard's existing agent-smoke profile is NOT the treatment harness; P11-E's decisive
metric comes from P11-ED runs, and the CI portion is the deterministic interim proof.

### P11-E — treatment evaluation

`tamoz-evals` (via P11-ED) runs the same task corpus under: (1) no durable memory; (2)
Experience retrieval only; (3) Experience + Knowledge; (4) Experience + Knowledge +
promoted Wisdom. Reported: precision@k and helpful recall@k; task-success delta;
contradiction/stale-recall/sensitive-recall rates; wrong-memory harm and correction
latency; retrieval token/cost overhead; provenance coverage; consolidation
source-preservation and prior-entry-loss rates; promotion precision and protected-holdout
delta; deletion-propagation latency; successful attributable reuse.

Hard-zero gates (fail the phase regardless of value): sensitive-recall rate, and
unauthorized-recall rate. A memory feature does not ship because retrieval relevance
improved while task outcomes, privacy, or cost became worse.

## 5. Deferrals (explicit, with entry conditions)

- **Vector/semantic search.** v1 is lexical-honest over the new index table. Entry: a
  real retrieval-quality gap measured in P11-E, plus a design for index/refresh/delete
  propagation. No new index type ships before P11-D2 proves deletion propagation against
  the lexical index.
- **Situation→memory coupling.** Experience admission from stream Situations arrives
  with P14's completed-episode seam; until then, episode admission is
  session-completion-driven only.
- **Cross-user/shared learning.** Out of scope without an explicit shared-scope design
  and authority (design §12).
- **Separate memory gem / shared service (ALMS).** Only after another application needs
  the same lifecycle without `tamoz-agent`.

## 6. Failure model (C8)

Typed failures over the merged D-7 taxonomy (invariant 17: policy violations propagate as
classes; repairable planner mistakes become typed values):

| Situation | Type | Behavior |
|---|---|---|
| admission default-rejection (unknown ownership/scope/sensitivity) | `MemoryAdmissionRejected` (typed result value, repairable-ish: the caller may fix metadata and re-submit) | durable `rejected` record; never an exception |
| admission of secret-shaped/disallowed content | `MemoryPolicyError` (terminal policy violation) | propagates; nothing stored |
| retrieval denial (unauthorized/sensitive) | silent empty result by design (indistinguishable from no-match); never an error, never a leak | zero logging of the denied candidate |
| consolidation model failure / output invalid | `MemoryConsolidationError` (propagates) | prior Knowledge intact; rejected candidate recorded |
| deletion partial-failure | `MemoryDeletionError` with receipt `"pending"` fields | receipt names pending sinks; no silent partial erasure |
| purge conflict (retention not expired) | `StoreConflictError` family | no purge; receipt not emitted |

## 7. Stop / redesign criteria

Stop and escalate if any of these appear:

- Retrieval can rank or render an unauthorized or sensitive record under any
  surface/scope combination, or an unauthorized sensitive row is decrypted during a scan
  (invariant 30 hard-zero violated; decryption-boundary probe fails).
- A consolidation or correction can lose protected entries, source references, or
  contradictions without a typed rejection and intact preimage.
- Any memory path grants permission, widens a root, or lowers an approval requirement
  (invariant 29 "memory never grants" violated).
- A recalled record can be admitted as new Experience evidence (self-ingestion loop
  reappears).
- Wisdom can influence a turn without a BehaviorTransition, or an in-flight execution
  can observe a promoted change, or activation fails to move the cache epoch.
- The P11-E treatment comparison shows a layer improving recall while task outcome,
  privacy, or cost regresses, and the regression is not fixable within the phase.

## 8. MemoryLimits (C9)

```ruby
MemoryLimits = {
  max_statement_bytes:        4_096,   # per record (skill-description order)
  max_source_refs:            16,
  max_candidates_per_sweep:   64,
  max_consolidation_candidates: 8,
  max_consolidation_tokens:   2_048,
  retrieval_token_budget:     1_024,   # per turn, separate from input/tools/history
  max_injected_knowledge:     8,       # max automatic-injection records per turn
  max_lexical_hits:           200,     # pre-ranking candidate cap
  retention_default_seconds:  86_400.0 # tombstone-delete → purge window (limits.rb pattern)
}
```

Token-budget overflow behavior: explicit retrieval truncates by rank (never silently);
automatic injection over budget drops the lowest-ranked admissible record and records the
drop in the trace. Budgets are per-turn, per-session (the session's `memory_epoch`
snapshot), and asserted by the token-budget bound test.

## 9. Definition of done (v1)

- [ ] P11-D record/lifecycle committed with codec registration, transition audit,
      `memory_epoch` sentinel, eligible-state set, `rejected` state, expiry transition,
      compatibility field.
- [ ] P11-A Experience admission with the reject matrix and anti-self-ingestion proof.
- [ ] P11-D2 index-propagation + purge owner proven (work order: D2-index-propagation
      before B).
- [ ] P11-B retrieval with the SQL-filtered lexical index, decryption-boundary leak
      test, honest-capability claim, token-budget bound.
- [ ] P11-C Knowledge with preimage-preserving consolidation, deterministic gates, and
      the owner fast path.
- [ ] P11-D2 correction/deletion with receipt (invariant-54 shape) and full-sink
      propagation incl. purge.
- [ ] P11-W one promoted Wisdom candidate through the full gated pipeline with
      BehaviorTransition + cache-epoch-change proof; P11-W→P12-I handoff declared in
      code comments and this plan.
- [ ] P11-ED integration with the existing DR-3 treatment harness (deterministic CI
      runs + env-gated live run); P11-E
      four-treatment comparison on the identical corpus; decisive metric reported;
      sensitive/unauthorized recall hard-zero.
- [ ] `rake ci` green under both locales; every scorecard case present at P11 start is
      byte/decision-compatible with safety counters zero; a new `agent.memory-...` case only if it proves a layer's
      attributable value without weakening any hard gate.
- [ ] Trackers updated: handover ledger P11 row, roadmap, `docs/GAUNTLET_PROGRESS.md`.
- [ ] Deferrals in §5 recorded in the handover plan and progress ledger.

# M3.1 phase 2G plan correction

Review target: Phase 2G PR/release matrices, sharding, merge verification, and evidence
envelopes in [M3_1_PHASE2_PLAN.md](../M3_1_PHASE2_PLAN.md).

Reviewed base: `c93d38b`.

Decision: accepted correction; Phase 2G implementation remains stopped until this
design-only correction passes full CI and is committed independently.

## Findings

| Severity | Finding | Root cause | Resolution |
|---|---|---|---|
| Critical | The PR profile executes four selectors per scenario, but evidence v1 has one singular `selection`. One envelope per scenario could not bind all four intentional kills without losing selector identity. | Scenario aggregation was designed before checking the accepted evidence schema's cardinality. | Emit one leaf evidence envelope per executed selector, then bounded scenario and profile summaries. |
| Critical | Evidence v1 requires `case_ref`, while the six public `m3.persistence` cases are explicitly deferred to Phase 7. Using a fake reference or an unrelated M0 case would make the artifact structurally valid but semantically false. | Harness evidence and user-facing evaluation cases were treated as the same lifecycle object. | Add one internal, non-scorecard `m3.phase2.sqlite-crash-evidence` case in Phase 2G. Phase 7 still owns the six public persistence cases. |
| High | A release shard can contain more than evidence v1's 256 references, and the complete matrix can contain up to 4,096 selectors. | The evidence-envelope bound was applied to an unbounded flat aggregate. | Store selector entries in separately bounded canonical matrix/shard/merge manifests; summary evidence references one verified manifest instead of every leaf. |
| High | Generic evidence-v1 verification cannot prove that oracle classification, selector control, convergence, process termination, and manifest identities agree. | Schema validity was mistaken for cross-artifact semantic validity. | Add a Phase 2 leaf verifier that first runs generic evidence verification, then verifies each referenced control/oracle/convergence/trace artifact and their exact relational agreement. |

## Five Whys: selector cardinality

1. Why can one scenario envelope not represent the PR profile? It has one `selection`,
   while the profile executes four different selectors.
2. Why not put selector ids in claims? Claims do not carry the accepted selection shape
   or trigger intentional-`SIGKILL` semantics in the verifier.
3. Why not extend evidence v1 to an array? That would be a cross-milestone schema change
   when the existing leaf model already represents one causal experiment correctly.
4. Why add summaries? Operators still need one scenario result and one profile result
   without reading every leaf.
5. Why use references from summaries? They preserve digest-bound composition while leaf
   envelopes retain exact selection/process causality.

## Five Whys: internal case identity

1. Why is a case reference required? Evidence v1 makes `case_ref` mandatory.
2. Why not reference an M0 case? No M0 case defines the 24 SQLite persistence scenarios,
   selectors, oracle, or convergence obligations.
3. Why not create the six public persistence cases now? Their public sanitization,
   scorecard integration, and release semantics belong to Phase 7.
4. Why is one internal case sufficient? Phase 2G evaluates the harness-level claim that
   fixed SQLite transaction boundaries classify and converge correctly.
5. Why is this not a Phase 7 scope leak? The internal case is non-scorecard and
   evidence-producing; the six user-facing cases later consume its verified artifacts.

## Corrected artifact hierarchy

For each executed selector:

1. one leaf evidence-v1 envelope with the exact singular selection;
2. one intentional subject process record;
3. separate oracle and convergence process records;
4. references to the trace manifest, fsynced selector control, oracle report, and
   convergence report;
5. claims for intentional kill, expected classification, integrity/foreign keys, and
   convergence.

For PR:

- 96 leaf envelopes: four selectors for each of 24 scenarios;
- 24 scenario manifests/summaries, each covering exactly its four leaf digests;
- one PR manifest and summary covering exactly the 24 scenario summaries.

For release:

- every selector in the canonical matrix has one leaf envelope;
- each shard writes one canonical shard manifest containing only entries assigned by
  `Integer(selector_digest_hex, 16) % shard_count`;
- merge recomputes assignments from the matrix and rejects overlap, gaps, foreign
  selectors, inconsistent shard count/index, or identity drift;
- one merge manifest binds all verified shard-manifest digests;
- one evidence-v1 summary references the merge manifest.

Matrix, shard, and merge manifests have exact versioned shapes, canonical
domain-separated digests, duplicate-key rejection, stable-file reads, no absolute paths,
and explicit entry/byte ceilings. Selector ordering is digest order.

## Identity binding

Every leaf or aggregate path binds, directly or transitively:

- internal case id/version/digest;
- scenario id/version/digest;
- selector digest and semantic fields;
- subject id/version/revision/tree/dirty/digest;
- boundary registry digest;
- recorder digest;
- scenario manifest digest;
- oracle definition digest and observed class;
- convergence definition digest and result;
- producer definition digest;
- profile and, for release, matrix/shard/merge identity.

No aggregate may mix subject trees, dirty flags, registries, recorders, scenario
manifests, oracle versions, convergence versions, or producer versions.

## Bounds

The existing Phase 2 ceilings remain authoritative:

- 32 scenarios;
- 4,096 selectors;
- 64 shards;
- 30 seconds per child/oracle/convergence process;
- 1 MiB retained stdout or stderr per process;
- 15 minutes for PR and 30 minutes per release shard.

Additional Phase 2G ceilings:

- four PR leaf selectors per scenario;
- 96 PR leaf envelopes;
- 256 entries per scenario summary;
- 4,096 entries per matrix/shard/merge manifest;
- 2 MiB per canonical manifest, matching the artifact verifier ceiling;
- one leaf's referenced artifacts remain within evidence-v1's per-reference and total
  byte ceilings.

Ceiling overflow is an infrastructure failure, never truncation or partial success.

## Acceptance gates before implementation

- the internal case is canonical, schema-valid, digest-bound, and explicitly
  non-scorecard/internal;
- every PR scenario selects exactly the four required semantic boundaries;
- every leaf has exactly one selector and one intentional `SIGKILL` subject record;
- the leaf verifier rejects a generic evidence envelope whose referenced artifacts do
  not agree;
- matrix and shard assignment are deterministic and independent of input/file order;
- merge rejects duplicates, overlaps, gaps, unknown entries, identity drift, and
  incomplete shard sets;
- summary hierarchies stay within evidence-v1 reference limits;
- dry run performs no child, oracle, convergence, or artifact write;
- Phase 3-7 behavior and the six public persistence cases remain absent;
- focused, adversarial, warning, packaging, design, and full-CI gates pass before the
  Phase 2G implementation commit.

This correction changes design only. It makes no Phase 2G implementation or crash-safety
claim.

## Gate evidence

Executed under rbenv Ruby 3.3.11:

- `git diff --check` passed;
- design validation: 22 documents, 55 invariants, 40 ADRs;
- full CI: 313 tests, 26,901 assertions, 0 failures, 0 errors, 0 skips;
- syntax, packaging, public API, dependency isolation, M0-M2 conformance, SQLite
  classification, and fresh-process convergence regressions passed.

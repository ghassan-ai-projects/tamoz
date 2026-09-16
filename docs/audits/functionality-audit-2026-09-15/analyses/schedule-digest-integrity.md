# F05-REL-01 — Schedule accepts an unverified definition digest

| Field | Assessment |
|---|---|
| Functionality | F05 — scheduler schedule values, storage, and materialization |
| Severity | **minor**, downgraded from the scanner's reliability implication |
| Confidence | **high** for the constructor/store behavior; **medium** for operational impact |
| Status | **open** |

## Scanner signal and independent judgment

The lead identified `Schedule.new` accepting a caller-supplied `definition_digest`
without comparing it with `compute_digest`, followed by SQLite persistence and
rehydration of that value. The lead is real, but its impact is bounded. The
constructor is a public gem API, so a same-process caller, embedder, fixture, or
future deserializer can submit a false digest. The shipped CLI is the only
in-tree production constructor found for this path and does not expose a digest
option: `gems/tamoz-agent-cli/lib/tamoz/agent/cli_schedule_commands.rb:43-61,84-101`.
No model or workspace input path was found that can currently inject this field.

## Finding and exact trigger

`Schedule` validates all fields except `definition_digest`, then uses any
truthy supplied value instead of the canonical result:
`gems/tamoz-scheduler/lib/tamoz/scheduler/schedule.rb:49-70`. The canonical
definition intentionally excludes only lifecycle `revision`, `enabled`, and the
digest itself (`:73-84`). The value is documented as immutable and
content-addressed (`:15-19`), but a supplied digest is not even frozen.

A direct value probe constructed a normal interval schedule with
`definition_digest: "sha256:" + "0" * 64`. It was accepted while the same fields
constructed without an override produced a different digest; the forged string
was mutable (`frozen? == false`). A second probe passed that schedule through the
public SQLite adapter and fetched the same forged value. This is therefore a
reproducible contract violation, not a static-only suspicion.

SQLite makes the false claim durable. `put_schedule` serializes the schedule but
writes `schedule.definition_digest` directly to the `definition_digest` column
(`gems/tamoz-sqlite/lib/tamoz/sqlite/schedule_store.rb:52-57,80-101`).
`materialize_schedule` then treats the stored value as authoritative and passes
it back to `Schedule.new` without recomputation (`:689-707`). The separate
`payload_digest` computed at `:654-656` authenticates neither the canonical
schedule definition nor the supplied definition digest.

## Impact by audit lens

- **Correctness:** equal canonical definitions can carry different digests, and
  different definitions can be made to report the same digest. CLI `show` and
  the scheduled-work projection expose that false value
  (`cli_schedule_commands.rb:307-318`; `worker_runtime.rb:935-949`).
- **Security/authority:** no current authority widening is proven. The worker
  applies the current grant intersection from the schedule fields, and the
  digest is not consulted in that path. The risk is conditional: the plan says a
  deterministic review may accept only within the stored definition and risk
  class (`docs/P13_SCHEDULER_PLAN.md:210-218`); a future consumer that trusts the
  digest rather than recomputing could accept false provenance.
- **Reliability/durability:** SQLite faithfully replays the false metadata, but
  the defect does not alter occurrence identity, lease state, or request
  idempotency. Identity uses schedule id, revision, and nominal fire time, and
  request id derives from that identity (`gems/tamoz-scheduler/lib/tamoz/scheduler/occurrence.rb:9-14,32-44`).
  SQLite builds occurrences from those fields (`schedule_store.rb:658-667`).
- **Observability/evidence:** a digest shown as content identity is not evidence
  of the displayed definition. This weakens audit correlation and makes future
  digest-based diagnostics misleading.
- **Scalability:** no additional work, bytes, or concurrency cost is introduced.
- **Maintenance/architecture:** the schedule value has a weaker invariant than
  the analogous capability descriptor. `Descriptor` computes and verifies an
  override (`gems/tamoz-core/lib/tamoz/core/capability/descriptor.rb:63-76`),
  and its contract test proves rejection (`test/capability_descriptor_contract_test.rb:48-53`).

## Root cause (causal chain)

1. The schedule constructor accepts an optional digest for storage round trips.
2. It treats presence as authority instead of as a claim to verify.
3. Validation omits the digest and the store assumes its value is authoritative.
4. The content-addressed value therefore has no single enforcing owner.
5. The schedule implementation predates the verified descriptor pattern, and
   no negative schedule test protects the invariant.

## Recommendation at the existing seam

Mirror the existing `Capability::Descriptor` constructor: compute the canonical
digest after `validate!`; if a supplied digest exists, require exact equality
and raise `Tamoz::ConfigurationError`; otherwise use the computed value. Freeze
the retained digest with the value object's immutable fields. Keep SQLite's
existing constructor-based rehydration, but map a constructor mismatch from a
stored row to its existing `CheckpointCorruptionError` boundary if that adapter
contract requires it. Add value tests for a wrong, malformed, and matching
override, plus a SQLite round-trip test proving a forged row cannot materialize.

## Test, overlap, and disposition

Run evidence: `ruby -Itest test/scheduler_values_test.rb` passed 17 runs / 112
assertions; `ruby -Itest test/sqlite_schedule_store_test.rb` passed 21 runs / 73
assertions. Existing tests assert only a digest prefix and that ordinary field
changes change the digest (`test/scheduler_values_test.rb:41-47,91-98`); the
SQLite tests cover revision/CAS and dedup but never a supplied digest
(`test/sqlite_schedule_store_test.rb:55-118`).

Accept as an **open minor contract/integrity finding**. Do not promote it to a
current authority bypass, duplicate-turn, or replay finding: the CLI cannot set
the field and occurrence/request identity excludes it. Earlier scheduler review
material discusses content-addressed values but supplies no explicit override
check; this analysis does not claim overlap with adjacent `payload_ref` or
SQLite `payload_digest` read-verification questions, which remain separate.

# gRPC / wire protocol — measurement plan

**Now:** integration tests exercise the real `EpisodeRequest`/decision wire end to end
(`stream_episode_end_to_end`, `stream_episode_fixed_graph`, `stream_episode_worker`,
`stream_evidence_client`). This is a **protocol**, not a capability — the right target is
conformance, not competence, so there is no "unknown" of the intelligence kind here.

**Unknown:** none of the capability kind. The open question is conformance/compatibility: does the
Ruby brain's wire output validate against the frozen schema the Go authority enforces, across
versions.

**Measure (offline, no model needed):**
1. Schema-conformance check: every decision/intent the brain emits validates against the committed
   `runtime-v1` protobuf + the decision-v1 schema and its digest (already largely covered).
2. A round-trip/golden vector: pin a set of canonical decisions and assert byte-stable
   serialization + digest, so a wire change is a reviewed, deliberate SHA bump.
3. Cross-version: assert the brain rejects an unknown/incompatible protocol version (fail closed).

**Prereqs:** none (offline). This is a guarantee track, not a measurement track.

**Done:** a conformance guarantee (schema + digest + version fail-closed) — a green invariant, not
a real-model number. Explicitly out of the "capability competence" set.

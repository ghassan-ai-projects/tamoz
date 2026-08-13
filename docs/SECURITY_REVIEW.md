# Security review at the release head (P15-D)

Scope, per `docs/P15_RELEASE_PLAN.md` §6: dependency, licence and provenance
review of every runtime gem; an invariant-24 sweep over every durable store;
the injection surfaces across the tool, skill, profile, MCP, memory, scheduler
and stream boundaries, re-run at the release head. The gate is zero unresolved
HIGH or CRITICAL findings — each fixed with a regression test before a release
candidate exists. Owner sign-off may acknowledge lower-severity residual risk;
it cannot waive a critical or high gate.

This review is a coordinator review. **No independent security reviewer has
examined it**, which is the same weaker evidence class recorded for P6, P7,
D-7 and the recent defect rounds.

## Dependencies, licences, provenance

[`DEPENDENCY_REVIEW.md`](DEPENDENCY_REVIEW.md) is generated from the nine
gemspecs' own declared runtime dependencies, transitively resolved against the
committed lockfile — the real closure, not a hand-kept list. At this head: 22
runtime gems, 4 development-only, **zero licence violations**, zero undeclared
licences.

`test/dependency_review_test.rb` makes it a gate rather than a snapshot: a
runtime dependency whose licence is outside the permissive allowlist fails CI,
as does a gem that declares no licence at all, as does a stale report. A
copyleft dependency is not forbidden as a value judgement — it is an owner
decision, and it fails loudly rather than arriving silently.

Provenance controls in force:

- every version pinned by a committed `Gemfile.lock`;
- `rubygems_mfa_required` on all nine gemspecs;
- the clean-clone rehearsal installs offline from the local cache, so a
  candidate cannot depend on a network resolution that could differ;
- **no runtime code fetch**: no plugin loader, no gem-install path, no
  skill-install pipeline — asserted by
  `test_no_production_code_installs_or_loads_code_at_runtime`.

## Invariant 24 — secrets in durable stores

`test/secret_sweep_test.rb` plants the same `Tamoz::Secret` into every durable
surface that accepts caller data and asserts each fails closed: the application
store, checkpoint state, the session record, the request payload, the effect
request, the schedule payload, the stream payload, instrumentation, stream
parts, and context metadata.

Two properties beyond the individual refusals:

- **Coverage is pinned.** The surface list is a constant, and a test asserts
  every surface in it has a refusal test. A new durable payload table cannot
  ship without someone deciding its secret policy.
- **The refusal is by TYPE, not key name.** A secret under the key `colour` is
  refused; a literal string under the key `password` is stored unchanged.
  Invariant 24 forbids lossy key-name scrubbing, and this is the assertion that
  holds it.

For checkpoint state the assertion is about the FILE, not the control flow: a
node returning a secret fails the run durably, and the secret's bytes are
asserted absent from the database on disk.

## Injection surfaces, re-run at the release head

216 adversarial cases across the boundaries that accept untrusted input:

| Boundary | Suite | Cases |
|---|---|---:|
| Profiles (untrusted repository configuration) | `agent_profile_test` | 42 |
| Skills (untrusted author content) | `agent_skills_adversarial_test` | 37 |
| Healing rules (self-modification refusals) | `healing_failure_contract_test` | 35 |
| Websearch egress (SSRF, redirects, credential headers) | `websearch_adapter_test` | 14 |
| Memory (prompt-injected content, cross-user recall) | `memory_treatment_profile_test` | 14 |
| Improvement (evaluator tampering, self-promotion) | `improvement_candidate_test` | 14 |
| Durable stores (this review) | `secret_sweep_test` | 13 |
| Egress declaration and resume binding | `websearch_egress_test` | 10 |
| Capability registry (forged sources, collisions) | `capability_registry_test` | 9 |
| Egress circuit (open conditions, authority-gated reset) | `websearch_circuit_test` | 8 |
| MCP transport (wire corruption, floods, orphans) | `agent_mcp_adversarial_test` | 8 |
| Replay credential isolation | `stream_replay_isolation_test` | 4 |
| Connector authentication | `stream_connector_test` | 4 |
| Action boundary and interlocks | `stream_action_boundary_test` | 4 |

Every one of them asserts a TYPED outcome — a specific refusal with a specific
class — rather than "did not crash".

## Findings

No new HIGH or CRITICAL finding was opened by this review. The findings that
this phase DID open are recorded where they belong:

| Finding | Severity | Disposition |
|---|---|---|
| Profile-restricted toolbox advertised withheld read tools in discovery | medium | Fixed (`13ea8fd`) with a regression test. Surface defect, not an authority escape: execution was already refused. |
| Routing execution through the host's wrapping dispatch would have converted storage failures and programmer bugs into repairable tool evidence | high (introduced and caught in review, never shipped) | Fixed before commit; `route` added, invariant-17 propagation asserted. |
| A bound capability source's dispatcher could be replaced after the registry was sealed | medium (introduced and caught in review, never shipped) | Rebinding now refused. |
| SIGKILL orphaned private `.tamoz-*` staging files in the user's workspace | low | Fixed (`ffecc39`): a narrow, stale-bounded, symlink-refusing sweep. |
| A security assertion (`a13b`) passed only on a warmed process | medium | Fixed (`d37ba24`): the claim is now order-independent and stronger. |

## Residual risk

1. **No independent security review.** This document is coordinator-authored.
2. **`Tamoz::ConfigurationError` is not a `Tamoz::Error`.** It descends from
   `StandardError` directly, so a `rescue Tamoz::Error` does not catch it. No
   exploitable consequence was found — the configuration boundary refuses
   before any effect — but a caller could reasonably expect one rescue to cover
   the whole taxonomy. Recorded, not fixed: changing it would move error
   classes several suites pin.
3. **Backpressure is declared and never enforced** (invariant 48). A hostile or
   merely fast producer is bounded by nothing in the stream path. This is a
   release-blocking gap and an owner decision, disclosed in
   [`LIMITATIONS.md`](../documentation/limitations.md).
4. **The corpus is ASCII-heavy by default.** Round 29 added non-ASCII coverage
   across the durable path and pinned the canonicality-comparison set, but the
   scorecard corpus itself remains ASCII, and three defect classes in this
   project's history were found only by running against a real model.

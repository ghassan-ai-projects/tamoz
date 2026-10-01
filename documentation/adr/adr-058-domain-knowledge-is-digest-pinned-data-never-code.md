# ADR-058 — Domain knowledge is digest-pinned data, never code

**Status:** Accepted 2026-10-01
**Date:** 2026-10-01
**Tier:** C
**Implementation:** Partial — `test/support/domain_loader.rb` still carries domain-specific branches (`install_watch_condition` schema and presets) and a fixed approval and rate-limit policy; no test fails on domain content authored in Ruby
**Relates to:** [ADR-024](./adr-024-smart-means-evidence-based-proportional-and-verified.md) (the benchmark these domains feed), [ADR-038](./adr-038-physical-action-is-typed-intent-plus-current-state-policy-never-model-effect.md) (intent catalogs are data), [ADR-055](./adr-055-two-repo-authority-split.md) (the Go side pins the same digests)

Diagnosis catalogs, operator prompts, intent types and risk classes, compensation maps, watch rules,
snapshot fact templates, fixture responses, and benchmark-family configuration live only in
`test/fixtures/domains/*.json`, loaded by a thin loader. A new domain is a new JSON file. Changing
domain data changes pinned digests, so it is a deliberate, reviewed change.

## Context

The agent is evaluated across physical domains (aquaculture, climate, cold chain, shipment, a thermal
lab). If a domain's vocabulary lives in Ruby, adding a domain means writing code, the agent's
"generality" can be faked by special cases, and the Go runtime — which verifies the same catalogs —
silently diverges.

## Decision

- Domain content is authored only in `test/fixtures/domains/*.json`. `DomainLoader.domains` discovers
  every file; the loader holds no domain content.
- No domain content — catalog entries, prompts, rules, presets — is authored in Ruby, in gems,
  `test/support/`, or tests. A test may name a domain value it asserts on (an intent type, a fixture
  key); it may not define one.
- The wire digests of the pinned catalogs and prompts, and the SHA of
  `documentation/benchmark/BENCHMARK_PROTOCOL.json`, change only in a deliberate, reviewed update.
  The aquaculture intent-catalog digest is also pinned in the Go repository; a Ruby-only edit breaks
  every Go-driven episode at its verify gate.

## Consequences

A new domain needs no Ruby, and a domain change is visible as a digest change. **Cost:** a data edit
is a two-repository change when it touches a cross-pinned catalog.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Domain modules in Ruby | Lets special cases fake generality; a new domain is a code change |
| Unpinned JSON | The Go side and the benchmark could drift without anyone noticing |

## Reopen when

Domain data needs logic the loader cannot express as data (then extend the data schema, not the
loader).

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| A novel domain produces a decision with zero new Ruby | `test/support/domain_loader.rb` | `test/stream_episode_intent_authority_test.rb` — `test_gate4_a_novel_domain_produces_a_decision_with_zero_new_ruby` | — |
| A family is built for every discovered domain | same | `test/benchmark_families_test.rb` — `test_a_family_is_built_for_every_discovered_domain` | — |
| The cross-repo digest is pinned | intent catalog | `test/agent_intent_catalog_test.rb` — `test_the_aquaculture_catalog_digest_matches_the_pinned_cross_repo_vector` | The Go side is not checked here |
| The protocol SHA is pinned | `documentation/benchmark/BENCHMARK_PROTOCOL.json` | `test/benchmark_protocol_test.rb` — `test_committed_sha256_pin` | No test fails on a domain literal in Ruby |

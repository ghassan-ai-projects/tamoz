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

# Project progress deep review — 2026-08-02

Verdict: **progress trackers required correction**. P0–P10, DR-3, DR-4, DR-5, and
P16 have implementation evidence. DR-2 is the active implementation round because its
durable circuit is a prerequisite for P17. P11–P15, P17, P18, and DR-1 remain design-only.

Scope: read-only review of implementation, accepted plans, reviews, history, gates, and
tracker consistency. This review changes documentation only. It does not change branch or
production/test code.

## Evidence reviewed

- Three independent review tracks covered implementation/history, tracker consistency,
  and residual security/reliability/release risk.
- Relevant commits were inspected through `9e024a2`, including DR-3 (`b6c379c`), DR-4
  (`c627aec`, closure `7afe1ff`), DR-5 (`be84e8e`, closure `80725db`), and P16
  (`fffaee8`, closure `2ae9e60`).
- Focused DR-4 verification: 26 runs, 174 assertions, zero failures.
- Committed closure evidence at `7afe1ff`: 857 runs, zero failures under both required
  locales; scorecard 17 cases / 14 successes / pass / safety zero.
- A review-time local `rake ci` ran 857 tests and failed five environment/process probes:
  two macOS network-sandbox self-tests, two MCP process-group spawn/teardown probes, and
  one kill-matrix probe. The repository changed during that run, so it is diagnostic, not
  replacement gate evidence. Re-run both locales from a stable checkout before the next
  closure.

## Findings

### F1 — DR-2 durability is the real critical path (critical)

P17 requires a durable egress-health circuit, but P10's supervisor defaults to
`MemoryCircuitStore` (`supervisor.rb:26,165`). The accepted DR-2 record is not implemented.
Starting P17 now would either violate its dependency or introduce another circuit engine.

Disposition: make DR-2 the sole active implementation round. Critic-close it and run the
two-locale gate before activating P17. P10's closure should explicitly carry this debt.

### F2 — MCP stderr can disclose credential values (high)

The supervisor resolves configured credential values into the child environment
(`supervisor.rb:430-444`). Its `stderr_tail` is bounded and scrubbed but has no known-value
redaction (`supervisor.rb:305`), and invocation errors attach that tail
(`invocation.rb:420`). A hostile or faulty child can print its credential value.

Disposition: redact all resolved credential values before stderr becomes diagnostic data;
add a malicious-child regression test that prints the exact value. Complete this before
P17 expands the network boundary.

### F3 — accepted designs were conflated with shipped capability (high)

The prior live trackers marked P17 active and grouped DR-4/DR-5/P11–P18 as not started,
while history proves DR-3/DR-4/DR-5/P16 complete. DR-1 and DR-2, by contrast, remain
design-only. P15 also claimed P11/P12 protected corpora would ship “later” even though P15
is ordered after those phases.

Disposition: split design and implementation status, correct the active dependency path,
and make missing P11/P12 protected evaluation artifacts release-blocking.

### F4 — P11 duplicated an already shipped evaluation substrate (medium)

DR-3 already supplies the four-cell treatment harness. P11-ED still said it would create
that harness, risking parallel evaluators and incompatible evidence.

Disposition: P11-ED integrates the production `MemoryRepository` adapter into the existing
DR-3 harness and runs deterministic plus operator-gated live treatments. It must not build
a second harness.

### F5 — residual verification and operational debt remains (medium/high)

- P6 and P7 lack independent adversarial closure; D-7/P8/P9 retain disclosed critic or
  scope debt.
- P6-F still lacks disk-full, saturation, deletion-guard, thread-leak, and soak evidence.
- SIGKILL can strand private `.tamoz-*` staging files.
- Historical scorecard cases changed without `case_version` bumps.
- P10 D2/H/full-E conformance remains deferred; the admission preview has no confirmed
  operator CLI workflow.
- Release CI/evidence, packaging/security/license/restore/rehearsal work and public docs
  remain incomplete.

Disposition: keep these as explicit closure inputs. Security and durability debt cannot be
silently converted into release deferrals.

## Root-cause analysis (5 Whys)

1. Why was P17 marked active? Because accepted design and implementation closure were
   summarized in one status field.
2. Why did that hide DR-2? Because P10 exposed a `CircuitStore` seam and passed in-process
   tests, which looked complete without proving restart durability.
3. Why was restart durability not visible? Because dependency tracking was phase-centric,
   while cross-cutting DR implementation state was not independently tracked.
4. Why did trackers diverge? Closure commits updated selected headers instead of a single
   mechanically checked phase/DR ledger.
5. Why can this recur? Design validation checks document shape, not consistency between
   dependency status, implementation history, and gate evidence.

Recommended systemic fix for P15 governance: generate public tracker summaries from one
machine-readable phase/DR ledger and validate that an active phase has every dependency in
an implemented-and-closed state.

## Correct remaining order

DR-2 → P17 → P11 (including DR-1 before Wisdom activation) → P12 → P13 → P14 →
P18 → P15.

Legacy critic and operations debt should be retired before P15 release closure, with the
MCP credential-redaction finding handled before P17.

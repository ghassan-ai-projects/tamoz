# Tamoz Quality Program — Goal Charter

**Status:** ACTIVE (started 2026-08-06)
**Live state / resume point:** [`QUALITY_PROGRAM_STATE.md`](QUALITY_PROGRAM_STATE.md) — update it at every slice.
**Owner:** Staff+ architecture & code-quality owner. **This document is the goal.** The state file records progress against it.

---

## Objective

Raise Tamoz's Ruby code quality, modularity, testability, and architectural clarity to
production-grade library standards **without changing observable behavior, public API,
durable wire formats, security boundaries, scorecards, or autonomous-agent guarantees.**

This is not a formatting campaign. It is a controlled architectural refactoring program,
executed in slices, each gated and committed separately.

## Owner constraints

- Do not push, publish, tag, release, or rewrite history.
- Do not modify, delete, stage, or commit user-owned `agenteval/`.
- Preserve unrelated changes.
- Do not refactor across an uncommitted product slice.
- Do not mass-autocorrect the repository.
- Do not weaken tests, scorecards, invariants, or static-analysis rules to obtain a pass.
- Do not create abstraction layers without at least two real consumers or a clearly
  isolated responsibility.
- Local reviewed commits are authorized after their gates pass.

## Precondition (verified — see STATE)

The autonomy slice (A1) is closed and committed (`1b060f1`, "leave the tree clean for
refactoring"); the tree at HEAD `d9d156b` is clean. Quality work starts from that checkpoint.
Never absorb `.claude`, `.cursor`, `.github/instructions`, `AGENTS.md`, `.enola`, or
`agenteval/` files without explicit ownership.

## Quality principles

- Behavior before structure: characterization tests precede extraction.
- Cohesion over file-size cosmetics.
- Composition over inheritance.
- Explicit collaborators over hidden global state.
- Immutable values over mutable option hashes.
- Narrow public APIs over convenience exposure.
- Dependency direction must follow gem and domain boundaries.
- Transaction boundaries, durability, approval, authority, and effect identity stay explicit.
- Prefer small domain objects over generic "service / manager / handler / utils" classes.
- A long declarative registry may be acceptable; a long method mixing policy,
  persistence, orchestration, and rendering is not.
- Hard-coded security policy becomes a named, tested contract — never runtime
  configuration controlled by content.
- Do not replace understandable case statements with metaprogramming to reduce LOC.
- Optimize for the next maintainer, not the static analyzer.

## Toolchain (dev/test only)

1. RuboCop (+ `rubocop-performance`, optionally `rubocop-minitest`)
2. Reek (design smells)
3. SimpleCov with branch coverage (+ subprocess result collation)
4. Enola (architectural graphs + delta checks)
5. Existing Ruby syntax, tests, scorecards, benchmark gates.

RubyCritic considered only as a report aggregator after core tools are calibrated.
No overlapping tools merely to produce more numbers.

## Enola setup

Repository-owned `mcp-arch.yaml` based on Enola's documented defaults. Must exclude at
least: `.enola/**`, `.git/**`, `.qwen/**`, `.worktrees/**`, `.claude/worktrees/**`,
dependency/build/cache dirs, generated coverage output, temp dirs, and `agenteval/**`
unless the owner explicitly places it in scope. Do not exclude production Ruby or hide a
finding by ignoring its directory.

**Validate extraction quality before trusting findings:** production files seen/parsed;
skipped files explained; parse errors zero or individually dispositioned; no nested agent
worktree appears as a Tamoz module.

The Enola MCP hook is not a substitute for the CLI gate. Run manually each slice:

```
enola baseline pin .
# perform one refactoring slice
enola check --fail-on=cycles,layers --min-confidence=0.8 .
```

Focused changes additionally use `enola check --target=<module> --max-spillover=<bound> .`
or impact analysis. Heuristic god-class/hotspot findings select code for human analysis —
they are never automatic proof that code is wrong.

## Phases

### Q0 — Measure honestly (first)
Generate and commit a reproducible baseline: `docs/code-quality-baseline.json` +
`docs/CODE_QUALITY.md`. Measure production and tests separately: file/class/method LOC,
ABC size, cyclomatic & perceived complexity, parameter count, nesting depth, duplicate
code, RuboCop offenses by cop+severity, Reek smells by type, line+branch coverage,
uncovered production files, Enola cycles/layer violations/hotspots/god classes/complexity
outliers, public API size by gem, dependency direction between gems, full-test+scorecard
results, benchmark timings. Generated/fixture/schema/declarative corpus files classified
separately. A script regenerates the baseline deterministically; CI detects drift.

### Q1 — Install ratcheting gates
Rakefile tasks: `quality:rubocop`, `quality:reek`, `quality:coverage`,
`quality:architecture`, `quality`; block appropriately in `rake ci`. Ratchet, not
big-bang: no new RuboCop offense; no new Reek smell in changed production code; no new
uncovered executable line in changed code; changed-line coverage ≥95%; changed-branch
≥85%; no new Enola cycle/layer violation; no unexplained spillover; overall line+branch
coverage never decreases; scorecards/safety counters never regress. A committed, reviewed
RuboCop TODO file may describe legacy debt: current offenses only, no new-file or
broad-directory exclusions, each slice removes entries, never add exclusions to pass CI.

### Q2 — Characterize critical hotspots
Characterization tests around public+durable behavior before splitting. Priority =
complexity × change frequency × blast radius × defect risk / refactoring effort. Likely
first: `gems/tamoz-agent/lib/tamoz/agent/cli.rb`, `session_nodes.rb`, `profile.rb`,
`gems/tamoz-tools/lib/tamoz/tools/toolbox.rb`, `gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_store.rb`,
`gems/tamoz-graph/lib/tamoz/graph/compiled.rb`. Per candidate: map responsibilities and
callers (Enola impact analysis), identify public methods + wire-format deps, add missing
unit tests at natural seams, characterization tests for byte/event-level behavior,
failure-path + adversarial tests; prove each test fails under an intentional mutation.

### Q3 — Extract by responsibility (one cohesive responsibility per slice)
CLI: argv→typed command parser; command objects (one public command each); session
factory; authority/profile resolver; interactive approval adapter; JSON/text renderer;
process/signal runner. CLI coordinates these — no domain policy inside.
Session graph: intake policy, deliberation/planning, plan review, step gating/approvals,
effect execution, repair policy, verification, memory transition integration, terminal
outcome construction. Graph nodes stay explicit; no hidden durable barriers in generic
middleware.
Profile: schema/constants, safe document loader, structural validator, semantic
validator, canonicalizer/digester, adoption registry, transition registry, authority
projection.
Toolbox: path confinement, read/search ops, patch prep/publication, file creation,
configured-check execution, skill access, receipt construction, policy+limits.
SQLite: checkpoint persistence, request inbox, leases/fencing, effect journal access,
schedule access, stream access, migrations + wire codec. Do not split atomic
transactions across objects in a way that obscures consistency; small repository
collaborators may share one transaction/kernel boundary.
Graph: compilation/validation, execution, checkpoint reconstruction, routing/frontier
calculation, stream emission, history/snapshot projection. Preserve deterministic
ordering and canonical digests byte-for-byte.

### Q4 — Remove accidental complexity
Replace repeated hash-key protocols with immutable `Data` values (internal, stable
shapes); centralize canonical serialization at codec boundaries; replace boolean combos
with named policies/typed commands; replace long parameter lists with cohesive config
values; remove duplicated validation only when one layer genuinely owns it (preserve
defense-in-depth across trust boundaries); domain constants only where identity matters;
remove dead compatibility branches only with git-history + fixture evidence; delete unused
private methods with call-graph + test proof; improve naming before adding comments; keep
comments on safety invariants, non-obvious failure models, rejected alternatives.
Do NOT introduce: BaseService, ApplicationManager, generic repositories over unrelated
stores, callback frameworks, DI containers, metaprogrammed command registration,
concerns that merely move methods out of a large class, configuration for fixed policy.

### Q5 — Coverage quality
SimpleCov branch coverage + subprocess result collation: normal tests, durable children,
kill/recovery subprocesses where observable, CLI subprocesses, scorecard drivers where
appropriate. Killed processes that cannot flush coverage: document the blind seam and
cover the same logic via a non-killed control path; never claim the killed path was
measured. Targets: ≥90% production line, ≥80% branch overall; ≥95%/90% on security,
authority, durability, effect journal, approval, reconciliation code; ≥95%/90% on new
production files; ≥95%/85% changed code; zero fully-uncovered production files unless
declarative entrypoints with explicit reason. Mutation-style adequacy checks on critical
logic (remove authority check, invert approval, bypass digest, duplicate effect dispatch,
skip budget stop, change transaction boundary, alter canonical ordering) — the relevant
test must fail; revert the mutation.

### Q6 — Ruby quality targets (hand-maintained production code)
Method ≤20 lines (hard ceiling 30); class/module ≤250 (ceiling 400); ABC ≤20; cyclomatic
≤8; perceived ≤8; params ≤5 (cohesive keyword config justified); nesting ≤3; zero RuboCop
errors; zero unreviewed warnings; zero Reek smells in newly extracted components; no
production file >500 lines unless classified declarative/generated with no complex
behavior. Limits are diagnostic — every exception names why keeping the code together is
safer.

### Q7 — Architectural gates
Dependency direction: core→stdlib+Zeitwerk only; tools→core (not agent); graph→core (not
agent/sqlite); scheduler+stream→no agent; sqlite→storage contracts, no CLI; agent
composes graph+tools via public contracts; mcp gains no authority over agent policy;
evals outside the production runtime graph. Enola + dependency-isolation tests. Targets:
zero cycles; zero layer violations; no new high-criticality module without review; top-5
production hotspot coupling −25%; god-class findings reduced materially; complexity
outliers → zero or documented; every refactoring inside its declared impact radius.
Do not chase lower fan-in on canonical shared primitives (codecs): high fan-in can be
correct; unstable bidirectional coupling is the real risk.

## Refactoring loop (every slice)

1. Clean checkpoint → 2. focused tests + behavioral baseline → 3. `enola baseline pin .`
→ 4. one responsibility in one hotspot → 5. impact analysis + callers → 6.
characterization + failure-path tests → 7. smallest cohesive extraction → 8. RuboCop,
Reek, coverage, focused tests → 9. `enola check --fail-on=cycles,layers --min-confidence=0.8 .`
→ 10. inspect every dependency/coupling delta → 11. full gate both locales → 12. agent +
autonomy scorecards → 13. release benchmark (persistence/planning/effects/worker changes)
→ 14. review diff (semantic drift; lost validation; changed error identity/message bytes;
event ordering; canonical digest; transaction boundary; authority widening; perf
regression; unnecessary abstraction) → 15. commit only that slice → 16. regenerate
baseline → 17. next highest-risk hotspot.

A slice is rejected if it: changes public behavior without an approved feature decision;
changes a persisted schema or canonical digest unintentionally; changes error class or
stable message bytes pinned by tests; weakens approval or capability intersection;
introduces a cycle or layer violation; reduces coverage; creates more abstraction than it
removes; moves a long method unchanged into a renamed class; increases meaningful
coupling; makes debugging/ops inspection harder.

## Review protocol

Every major hotspot extraction gets a fresh-context critic: compare behavior before/after;
inspect Enola architecture delta + coverage changes; look for abstraction leakage,
transaction/durability changes; attempt authority/approval bypasses; identify duplicated
policy; identify "service object"/concern-based cosmetic splitting; public API growth;
perf regressions. Correct every critical and high finding before closing the slice.

## Definition of done

Autonomy work captured in a clean product checkpoint; quality tools run locally and in CI;
Enola analyzes only the intended repository; baseline/check explicitly executed by the
loop; repo-wide line+branch coverage measured and meeting targets; no new static-analysis
debt; highest-risk long files split by responsibility; public APIs, wire formats, digests,
events, error identities compatible; zero cycles + layer violations; hotspot coupling
measurably reduced; full gates pass in both locales; agent + autonomy scorecards don't
regress; no unexplained material benchmark regression; independent critic finds no
unresolved critical/high issue; docs explain resulting module boundaries + contribution
rules.

## Status update format (every slice)

hotspot addressed; responsibility extracted; LOC/complexity before→after; line/branch
coverage before→after; RuboCop/Reek delta; Enola dependency+coupling delta; behavior +
scorecard result; next highest-value hotspot. Keep updates short.

# Tamoz Coding Standard

**Owner:** Staff+ architecture & code-quality owner. **Applies to:** all hand-maintained
production Ruby — `gems/*/lib`, `apps/`, `script/`, `bin/`, `Rakefile`. Tests follow
§9. Generated/fixture/schema/declarative corpus files are classified separately (see
`docs/CODE_QUALITY.md`) and are not held to these rules.

This standard codifies the most-agreed Ruby conventions — the **Ruby Style Guide**
(implemented by the repository's RuboCop configuration) and the **Rails Style Guide**
where its principles transfer — plus this codebase's own invariants. Tamoz is a gem
monorepo, not a Rails application: Rails conventions apply where the *principle*
transfers (naming, layout, test structure, convention-over-configuration), never where
the framework would (no ActiveRecord, no Rails middleware, no service-object framework).

It is the contract for every refactoring slice in the quality program
(`docs/QUALITY_PROGRAM.md`). Where a rule here and a static-analysis preference
conflict, the rule wins; where the toolchain enforces something stricter (RuboCop
defaults are stricter than several Q6 ceilings), the toolchain wins.

## 1. Enforcement

Every slice is gated by:

- `rubocop` — zero offenses; Q6 ceilings live in `.rubocop.yml` (method ≤ 20 lines,
  class/module ≤ 250, ABC ≤ 20, cyclomatic ≤ 8, perceived ≤ 8, parameters ≤ 5,
  nesting ≤ 3). Legacy debt lives only in the committed `.rubocop_todo.yml` as
  per-file excludes — never directory or glob exclusions, never added to pass CI.
- `reek` — no new smell in changed production code. The ratchet is context-named
  (`Tamoz::Agent::Session#initialize`), so a new smell in a listed file still fires.
- `enola check --fail-on=cycles,layers --min-confidence=0.8 .` — no new cycle, layer
  violation, or unexplained spillover.
- Coverage targets (`docs/QUALITY_PROGRAM.md` §Q5).

You may not weaken a gate, scorecard, invariant, or test to obtain a pass.

## 2. Files and modules

- `# frozen_string_literal: true` is the first line of every file.
- One class or module per file; the file path mirrors the constant path
  (`Tamoz::Agent::Session` → `gems/tamoz-agent/lib/tamoz/agent/session.rb`) and
  Zeitwerk autoloads it. No circular requires; `require` only at the top of a file.
- Gem entrypoints (`gems/<gem>/lib/<gem>.rb`) stay thin: load the namespace, let
  Zeitwerk resolve the rest.
- A file growing past ~250 lines is a signal to extract a responsibility — not to
  re-wrap it under a new name.

## 3. Naming (Ruby Style Guide)

- Classes/modules: `CamelCase`. Methods/variables: `snake_case`. Constants:
  `SCREAMING_SNAKE_CASE`.
- Predicates end in `?` (`approved?`, never `is_approved`). Mutating methods end in
  `!` only when a safe twin exists. Boolean variables read as questions.
- No `get_`/`set_` prefixes; accessors are plain readers and `name=`.
- Method names say what they return (`find`, `fetch`, `build`, `call`); one verb per
  method.
- Test names read as sentences: `test_rejects_overdraft_when_budget_exhausted`.

## 4. Methods

- Small methods: normally ≤ 20 lines, hard reviewed ceiling 30. These limits are
  diagnostic — never split cohesive logic or add indirection merely to satisfy a
  number; name the exception and why.
- Keyword arguments beyond one or two positional parameters; no long positional lists.
- No boolean parameters (Reek `BooleanParameter`): a boolean argument means two
  behaviors — split the method or pass a named policy.
- One responsibility per method. A method mixing policy, persistence, orchestration
  **and** rendering is the canonical violation this standard exists to prevent.
- Prefer `module_function` (or `self.`) for stateless functional modules; pass
  collaborators explicitly rather than reaching for global state.

## 5. Values and state

- Internal stable shapes are immutable `Data.define` values, not string-keyed hashes.
  Hash-key protocols belong at wire/opaque boundaries only.
- Expose readers, never bare `@ivar` access from collaborators; freeze values handed
  out (`Tamoz::Secret` duplicates and freezes).
- No hidden global state: explicit collaborators over memoized globals and ambient
  constants.
- No mutable default arguments — `def build(x = [])` shares the literal across calls.

## 6. Design

- Composition over inheritance. Prefer small domain objects over generic `Service`,
  `Manager`, `Handler`, or `Utils` classes.
- Narrow public APIs: expose what collaborators need and nothing more (the exported-
  surface audit is the gate).
- Dependency direction follows gem boundaries (`docs/QUALITY_PROGRAM.md` §Q7):
  `tamoz-core` depends only on stdlib + Zeitwerk; `tamoz-tools`/`tamoz-graph` depend
  on core, not agent; `tamoz-scheduler`/`tamoz-stream` never depend on agent;
  `tamoz-sqlite` implements storage contracts without touching the CLI; `tamoz-agent`
  composes graph and tools through public contracts; `tamoz-mcp` gains no authority
  over agent policy; `tamoz-evals` stays outside the production runtime graph.
- Banned abstractions (§Q4): `BaseService`, `ApplicationManager`, generic repositories
  over unrelated stores, callback frameworks, dependency-injection containers,
  metaprogrammed command registration, concerns that merely relocate methods, and
  configuration for fixed security policy.
- A long declarative registry may be acceptable; a long method containing policy,
  persistence, orchestration, and rendering is not.

## 7. Errors and contracts

- Error classes are public API. Error identity and stable message bytes are pinned by
  tests — changing them is a compatibility decision, not a refactor.
- Raise domain errors at boundaries; never rescue `Exception`; don't swallow errors to
  satisfy a lint rule.
- Durable contracts are byte-level: wire formats, canonical digests, event ordering,
  and transaction boundaries (the DR-2 durable circuit, the session graph). A
  refactoring preserves them exactly, or it is rejected.

## 8. Security, authority, and durability

- Authority is capability intersection: approval gates stay explicit, and nothing may
  widen them. Invariants and scorecards never regress.
- Hard-coded security policy becomes a named, tested contract — never runtime
  configuration controlled by content.
- No secrets in durable records or the repository (invariant 24).
- Transaction boundaries stay visible. Durable barriers are not hidden inside generic
  middleware.

## 9. Testing (Minitest)

- Behavior-first: test through the narrowest stable boundary. Do not test private
  implementation merely to raise coverage.
- Characterization tests precede any hotspot extraction; each must fail under at least
  one intentional mutation of the behavior.
- One test file per subject (`test/<area>_test.rb`), `require_relative "test_helper"`,
  descriptive `test_` names, failure paths and adversarial cases first-class.
- Subprocess children are self-contained: every transitive tamoz gem on `-I`; they must
  not depend on the ambient gem home.

## 10. Gems and dependencies

- Gemspec hygiene is a gate: runtime vs development split (`docs/DEPENDENCY_REVIEW.md`
  regenerates from the gemspecs and lockfile); development tooling never ships.
- Licenses stay on the permissive allowlist; provenance controls (`mfa_required`) stay
  in place.

## 11. Comments

- None by default. Add a comment only for the *why* that naming cannot carry: safety
  invariants, non-obvious failure models, rejected alternatives. Never narrate what
  the code does.

## 12. Commit checklist

- [ ] `rubocop` zero; no new `reek` smell in changed production code; `enola check` PASS
- [ ] Focused tests and the fast gate green; `ci_full` both locales only when the slice
      touches durability, MCP, packaging, or committed evidence artifacts
- [ ] No public API, wire-format, digest, event-order, or error-identity change without
      a separate approved feature decision
- [ ] No new abstraction without two real consumers or a clearly isolated responsibility
- [ ] Coverage not reduced; agent and autonomy scorecards unchanged
- [ ] Docs updated (plan/review convention); quality baseline regenerated when metrics
      moved

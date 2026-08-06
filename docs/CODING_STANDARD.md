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

Three practices are adapted from **RubyLLM**, the library this agent talks to models
through, because it solves the same problems at the same scale: architecture rules
declared as an executable spec rather than prose (§6), a wire vocabulary enforced by
name (§3.1), and a public surface that is documented and marked (§11).

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
- The architecture tests (§6) — `test/dependency_isolation_test.rb`,
  `test/public_api_test.rb`, `test/documentation_surface_test.rb`.
- Coverage targets (`docs/QUALITY_PROGRAM.md` §Q5).

You may not weaken a gate, scorecard, invariant, or test to obtain a pass.

**One gate, one command.** What runs before a commit and what runs in CI are the same
checks. A rule that only a reviewer can catch is a rule that will be broken; prefer
moving it into the gate over restating it here.

**An exception is written at the site, not hidden in a file.** A justified deviation
carries its `# rubocop:disable Cop/Name` on the exact line with the reason nearby —
the way `Lint/RescueException` is disabled in `Tamoz::Pool` — so review sees it in the
diff. `.rubocop_todo.yml` is pre-existing debt that only shrinks; new code does not add
to it.

## 2. Files and modules

- `# frozen_string_literal: true` is the first line of every file.
- One class or module per file; the file path mirrors the constant path
  (`Tamoz::Agent::Session` → `gems/tamoz-agent/lib/tamoz/agent/session.rb`) and
  Zeitwerk autoloads it. No circular requires; `require` only at the top of a file.
- Gem entrypoints (`gems/<gem>/lib/<gem>.rb`) stay thin: load the namespace, let
  Zeitwerk resolve the rest.
- A file growing past ~250 lines is a signal to extract a responsibility — not to
  re-wrap it under a new name.
- **Generated artifacts are never hand-edited.** Canonical fixtures, `docs/*.json`
  evidence, the dependency review, and `.rubocop_todo.yml` are produced by their
  script; the generator and its output are committed together. A hand-edit that the
  next regeneration would overwrite is a defect, not a fix.

## 3. Naming (Ruby Style Guide)

- Classes/modules: `CamelCase`. Methods/variables: `snake_case`. Constants:
  `SCREAMING_SNAKE_CASE`.
- Predicates end in `?` (`approved?`, never `is_approved`). Mutating methods end in
  `!` only when a safe twin exists. Boolean variables read as questions.
- No `get_`/`set_` prefixes; accessors are plain readers and `name=`.
- Method names say what they return; one verb per method.
- Test names read as sentences: `test_rejects_overdraft_when_budget_exhausted`.

### 3.1 Vocabulary

One concept, one verb, repository-wide. A second spelling for an existing idea is the
cheapest way to make a codebase unsearchable. The lexicon below is what the code
already does; the rule is that new code does not add another spelling for it.

**Wire and durability.** `render_*` produces an outward form (a payload, a view, text
a human reads) and `parse_*` reads it back. `encode_*`/`decode_*` is the durable-codec
pair — bytes that must round-trip exactly (SQLite rows, graph checkpoints). Pick the
pair that matches the boundary and use both halves of it. `serialize_*`, `to_wire_*`,
and `from_wire_*` are not used here: they are a third name for a pair that exists.

**Checking.** Four verbs, four meanings, not interchangeable:

| verb | means | failure is |
| --- | --- | --- |
| `validate_*` | this value matches its declared shape or schema | bad input, named by field |
| `verify_*` | this claim holds against evidence — a digest, a binding, a signature | untrusted or tampered |
| `assert_*` | this invariant, which this code owns, still holds | a bug in Tamoz |
| `enforce_*` | policy applies and may refuse the operation | a refusal, and authority lives here |

A noun takes one of them. `verify_mcp_binding` and `enforce_mcp_binding` both existing
is exactly what this rule names: if checking the evidence and refusing the operation
are genuinely two steps, the names must show the handoff (`verify_*` returns the
evidence, `enforce_*` consumes it); if they are one step, keep one method.

**Construction.** `build_*` returns a new value. `normalize_*` returns the canonical
form of its input. `resolve_*` turns a reference into the thing it names.

**Scope.** `with_*` means *run this block with X in effect and restore afterwards*
(`with_connection`, `with_registry_lock`). It is not a fluent setter here. A `with_*`
method that returns a configured object instead of yielding is misnamed.

**Capabilities are one question, not a family of predicates.** Ask
`supports?(:streaming)`, never `supports_streaming?`. A set of `supports_x?` methods
is a case statement spread across a class, and every new capability edits the class.

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
- **State that can be added can be removed.** A method that installs something —
  a binding, a lease, a registration, an override — ships with the documented way to
  clear it, or documents why the state is permanent. Half a pair is an API that leaks.

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
- Banned abstractions (§Q4): `BaseService`, `ApplicationManager`, generic repositories
  over unrelated stores, callback frameworks, dependency-injection containers,
  metaprogrammed command registration, concerns that merely relocate methods, and
  configuration for fixed security policy.
- A long declarative registry may be acceptable; a long method containing policy,
  persistence, orchestration, and rendering is not.

### 6.1 The architecture is executable

Dependency direction is not a paragraph anyone can drift from — it is asserted by
`test/dependency_isolation_test.rb`, which loads each gem in a clean process and fails
if a forbidden feature appears in `$LOADED_FEATURES`, and by `enola check`. The
boundaries are: `tamoz-core` depends only on stdlib + Zeitwerk; `tamoz-tools` and
`tamoz-graph` depend on core, not agent; `tamoz-scheduler`/`tamoz-stream` never depend
on agent; `tamoz-sqlite` implements storage contracts without touching the CLI;
`tamoz-agent` composes graph and tools through public contracts; `tamoz-mcp` gains no
authority over agent policy; `tamoz-evals` stays outside the production runtime graph
(`docs/QUALITY_PROGRAM.md` §Q7 is the charter).

Two rules follow:

- **A new boundary is added to the test in the same commit that creates it.** A
  boundary nobody can break by accident is worth more than one everybody agrees with.
- **Each rule carries its reason.** The assertion says *what*; a comment above it says
  what breaks if it is violated — "this is what keeps `require "tamoz/tools"` free of
  the model client" is the useful form. A rule whose reason nobody remembers is the
  next rule to be deleted under pressure.

Load-time isolation does not catch a constant referenced down a lazily-loaded path.
Where a boundary matters more than load order — authority, egress, durability — assert
the reference directly rather than trusting the loader.

### 6.2 Does this belong here?

Before adding a feature to a gem, ask whether a caller could compose it from the
public API already exposed. If yes, it belongs in the caller.

Rejected by default:

- Anything a caller can build in a few lines from existing public API.
- Opinionated frameworks over patterns that are already direct — workflow DSLs,
  plugin registries, orchestration layers with one implementation.
- An integration with one named external service living inside a core gem. It is an
  adapter behind an existing contract, or it is its own gem.
- Configuration for behavior that has exactly one correct value. Fixed policy is a
  named, tested contract (§8), not a knob.

**If a feature needs extensive documentation before someone can use it correctly, the
design is wrong — not the documentation.** New abstractions still require two real
consumers or a clearly isolated responsibility.

## 7. Errors and contracts

- Error classes are public API. Error identity and stable message bytes are pinned by
  tests — changing them is a compatibility decision, not a refactor.
- Every error class documents *when it is raised*, in one line, next to the class. A
  reader deciding what to rescue should not have to grep the raise sites.
- Raise domain errors at boundaries; don't swallow errors to satisfy a lint rule.
- **`rescue Exception` never handles an error.** Its one admitted use is releasing a
  resource, or recording a fatal, before re-raising or terminating the worker — as in
  `Tamoz::Pool`, `Tamoz::Instrumentation`, and the SQLite connection pool, each with an
  inline `# rubocop:disable Lint/RescueException`. Rescuing `Exception` and continuing
  is a defect.
- Durable contracts are byte-level: wire formats, canonical digests, event ordering,
  and transaction boundaries (the DR-2 durable circuit, the session graph). A
  refactoring preserves them exactly, or it is rejected.
- **A contract change ships with its migration note.** When a public API, error
  identity, wire format, or digest changes by decision, the same commit says what
  changed, what a caller must do, and where the guide is. Callers should not learn a
  contract moved by having it break.

## 8. Security, authority, and durability

- Authority is capability intersection: approval gates stay explicit, and nothing may
  widen them. Invariants and scorecards never regress.
- Hard-coded security policy becomes a named, tested contract — never runtime
  configuration controlled by content.
- No secrets in durable records or the repository (invariant 24). Generated evidence,
  fixtures, and recorded transcripts are checked for credentials *before* they are
  committed — recorded output is the likeliest place for a key to enter history, and
  history is the one place a deletion does not reach.
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
- A test that pins a *rule* rather than a behavior — a boundary, a documented surface,
  a public API list — states in a comment what breaks if the rule goes.

## 10. Gems and dependencies

- Gemspec hygiene is a gate: runtime vs development split (`docs/DEPENDENCY_REVIEW.md`
  regenerates from the gemspecs and lockfile); development tooling never ships.
- Licenses stay on the permissive allowlist; provenance controls (`mfa_required`) stay
  in place.
- A new runtime dependency requires an architecture decision and a clean-process
  dependency test (`CONTRIBUTING.md`). Minimal runtime dependencies is a design
  position, not an accident: each one becomes every downstream user's problem.

## 11. Documentation and comments

Four different things, four different rules.

**Public API documentation is required.** `Style/Documentation` is on for production
code. Every public class and module says what it *is*, in the reader's terms, before
how it works. A public entry point adds its contract — what it returns, what it
raises, what it guarantees — and one example that would actually run.

**Internals are marked, not documented.** `# :nodoc:` on something public only by Ruby
visibility keeps the generated surface honest and tells the next reader it is not a
promise.

**Inline narration stays banned.** A comment restating the line below it is noise, and
it rots first. Improve the name instead.

**"Why" comments earn their place** — safety invariants, non-obvious failure models,
rejected alternatives, and the history that explains a guard. `tool_error.rb` (why the
base class is terminal by construction) and `documentation_surface_test.rb` (why the
README is derived from the real surface) are the model. This is what the next
maintainer cannot recover from the code.

A doc describing a surface the repository does not have is worse than no doc, because
a reader believes it. Where a claim can be checked against the code, check it.

## 12. Commit checklist

- [ ] `rubocop` zero; no new `reek` smell in changed production code; `enola check` PASS
- [ ] Focused tests and the fast gate green; `ci_full` both locales only when the slice
      touches durability, MCP, packaging, or committed evidence artifacts
- [ ] Names follow §3.1 — no new spelling for an existing concept; check verbs used
      with their meanings
- [ ] No public API, wire-format, digest, event-order, or error-identity change without
      a separate approved feature decision — and none without its migration note
- [ ] New public class or entry point documents what it is, what it raises, and one
      real example; internals marked `# :nodoc:`
- [ ] No new abstraction without two real consumers or a clearly isolated responsibility
- [ ] A new boundary is asserted in the same commit, with its reason
- [ ] Any deviation is disabled inline at the site with a reason; `.rubocop_todo.yml`
      did not grow
- [ ] Coverage not reduced; agent and autonomy scorecards unchanged
- [ ] Docs updated (plan/review convention); generated artifacts regenerated, never
      hand-edited; quality baseline regenerated when metrics moved

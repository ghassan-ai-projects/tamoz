# AGENTS.md — tamoz

Tamoz is a Ruby durable-agent framework plus its reference agent, in one monorepo of independently
publishable gems (`gems/`, map in `README.md`; entry points in `apps/` and `bin/`). The continuous
stream plane is a separate Go repository, `agentic-stream` (ADR-055); `*.go` references live there.

| Need | Read |
|---|---|
| Why the system is shaped this way | `documentation/adr/README.md` — every decision, grouped by area |
| What must always hold | `docs/design-v0.1/INVARIANTS.md` |
| How to write Ruby here | `docs/CODING_STANDARD.md` (enforced by the gates) |
| How to write and review tests | `docs/test-quality/TESTING_STANDARD.md`; suite bar and findings in `docs/test-quality/` |
| Lessons earned in real sessions | `.agent/README.md` → `.agent/rules/*.md` |
| How to set the bar for a task | `docs/templates/QUALITY_BAR.md` |
| How to delegate to subagents | `docs/subagent-orchestration.md` |

## Every task runs against a quality bar

1. **Set the bar before the change.** Copy `docs/templates/QUALITY_BAR.md`, pick the size (S/M/L),
   write the outcome and the rows. A bar written afterwards grades what was built, not what was
   needed.
2. **Loop:** grade every row → fix what fails → re-grade, until an iteration changes nothing and no row
   is FAIL or OPEN. A row passes only because its check ran this time. The same row failing three
   iterations running goes to the owner.
3. **Review before every commit:** a reviewer other than the author (a fresh subagent, per
   `docs/subagent-orchestration.md`) checks the diff against the bar. Fix critical and high findings
   before committing.
4. **Report:** outcome met or not, commands and results, what is a real-model result and what is
   plumbing, decisions still open.

## Owner rules — non-negotiable

Each rule's reasoning and evidence live in the ADR named; the line here is the rule.

- **No backward compatibility before 1.0** (ADR-059). No legacy-row readers, shims, or aliases; a
  database may be reset. Migration ordinals stay monotonic and checksummed; each new migration assumes
  a fresh schema.
- **Simple over complicated; no rare cases.** When two designs work, take the one with less machinery.
  Do not write code for a case that cannot happen or has never happened.
- **Defer complexity to a future plan** (owner, 2026-10-04). Keep the agent as simple as possible.
  Anything that adds complexity now — a new mechanism, a compliance regime, a second path, a feature
  not needed for the task's outcome — is written into a future plan in the task's `docs/` folder
  (design, tests, open decisions), not built.
- **Understand before you build; extend, don't reinvent.** Map the existing path (enola
  `explore`/`traverse`/`impact_analysis`, then read it end to end) and name the seam you extend before
  writing a line. A class duplicating an existing effect, loop, store, or model call is a defect.
- **Gem boundaries are absolute** (ADR-052). Use another gem only through the facade its README names —
  never its stores, tables, key layouts, record internals, or private rules. Missing capability goes
  into the owning facade; guard the boundary with a leak test (`test/memory_boundary_test.rb`). Ask
  before changing a cross-gem interface.
- **Non-deterministic and external calls go through the effect journal** (ADR-016):
  `EffectDispatcher.run` (`SessionEffects#model_call`; `Runtime#model_generate` for the one-shot
  runtime). Key identity on the request, never the answer; terminal receipts are immutable; an
  unanswered unsafe call stops as `:unknown`.
- **A user's stop ends the turn; it never aborts the graph** (ADR-057). Stops go through
  `Tamoz::Cancellation::Stops`; cancelling the graph context's token is for shutdown and recovery.
- **Pin authority; never re-derive it by id.** A reloaded profile must match the `canonical_digest`
  recorded at bind time (`WorkerRuntime#child_profile_for`, `validate_thread_profile`); effect
  mutations bind to the active lease (`EffectReconciler#reconcile`); a failed store or authority
  lookup fails closed.
- **Approval policy is data** (ADR-053). Verdicts and evidence live only in
  `gems/tamoz-approval/policy/*.yaml`; never hardcode a verdict, approval constant, or bypass flag. A
  policy edit that loosens authority is also an ADR change (`.agent/rules/adr.md`).
- **Domain knowledge is data, never code** (ADR-058). Catalogs, prompts, intents and risk classes,
  compensation maps, watch rules, fact templates, fixture responses, and benchmark families live only
  in `test/fixtures/domains/*.json`, loaded by `test/support/domain_loader.rb`. The pinned wire
  digests and the protocol SHA in `documentation/benchmark/BENCHMARK_PROTOCOL.json` change only as a
  reviewed update; the aquaculture catalog digest is pinned in the Go repository too.
- **Real model for real runs; fakes stay in tests** (ADR-024). Tests never call a real LLM; a stub,
  fixture, or deterministic provider is never presented as evidence that the agent reasons.
- **Keep the record true.** A change that alters a decided rule updates its ADR in the same change
  (`rake adr:validate adr:verify`). Never rewrite accepted intent to match the code: mark it
  `Implementation: Partial` and raise it with the owner.
- **Never force-push** (`.agent/rules/git.md`). Amend locally, publish a new commit.

## Working practice

- **Clean house as you go.** A file you read that breaks a rule here: fix it in the same change only if
  it is already in your change, the fix is small, and a test proves it (own commit); otherwise report
  file:line and the rule. Prefer a test that fails on the rule over fixing one instance.
- **Record a lesson in the change that taught it** — here, or in `.agent/rules/<topic>.md` when it
  needs evidence. Ground it in the real seam; rewrite a rule a new lesson contradicts.
- **Report in plain terms.** Name real files and seams; say what is a real-model result and what is a
  plumbing test; never overclaim.

## Tests, lint, gates

- Ruby is pinned in `.ruby-version` (3.3.11); put it on PATH. **One test file per command** (a second file is ignored); filter with `-n`:
  `export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH" && ruby -Itest test/<file>.rb`
- Real-model runs need a UTF-8 locale: `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`.
- **Never pay real time in a test** — inject the wait. Lanes, weights, the `ci` budget, file modes:
  `.agent/rules/testing.md`.
- Lint changed files with autocorrect only: `bundle exec rubocop -a <path>...`, then move on. Never spend
  time hand-fixing what `-a` leaves (owner, 2026-10-09).
- Everyday gate: `rake ci` + `rubocop` + `enola check`. `rake ci_full` in both locales only for
  durability, MCP, packaging, or evidence slices. State and policy: `docs/QUALITY_PROGRAM_STATE.md`.
- A gate already red at HEAD is not yours to chase: prove it in a detached worktree and say so.

## Comments

Default to none: name things so the code reads without them. When a "why" is genuinely needed — a
safety invariant, a non-obvious failure model, a rejected alternative (`CODING_STANDARD.md` §11) — write
one or two lines. No multi-line headers on new classes or methods, no narrative of the bug a fix
replaced, no ADR citation as decoration. History belongs in commits and PR bodies, not source.

<!-- enola:begin -->
## enola — architecture before and after a change

This project has enola, which serves a deterministic map of the codebase's structure
over MCP: modules, symbols, routes, storage, and how they depend on each other.

Before changing code whose blast radius is not obvious:

- `impact_analysis` — what transitively depends on this, before you touch it.
- `explore` / `traverse` / `find_path` — how something is wired, instead of
  reconstructing it by reading files.
- `set_baseline` — pin the architecture BEFORE you start editing, so the change can
  be graded afterwards. Do this once, early.

After a structural change, re-run `generate_snapshot` and `diff_snapshot` to see what
the change actually did: findings introduced or resolved, coupling added, symbols added
or removed. A dependency cycle or unintended coupling is a reason to fix the change
before presenting it, not something to mention afterwards.

Prefer these over re-deriving structure by grepping. They are exact, and they cost a
fraction of the file reading they replace.

enola's hook is installed for this project: at the end of a session it reports the
architectural delta if — and only if — the change introduced a structural regression.
It never blocks, and it stays silent when the change is clean.

It speaks in one other case: when it could not grade the change at all, because the
baseline is not comparable to the current snapshot. That is NOT a verdict about your
change — it means no verdict was reached — and the remedy is to re-pin the baseline.
Said once per cause, not once per session.
<!-- enola:end -->

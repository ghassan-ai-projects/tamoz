# AGENTS.md — tamoz

Ruby durable-agent framework and its reference agent: independently publishable gems in `gems/` (map in
`README.md`). The stream plane is a separate Go repository, `agentic-stream` (ADR-055); `*.go` references live there.

Where a guide or `.agent/rules/` disagrees with this file, follow this file and report it. Where an ADR, an invariant
or policy YAML disagrees, stop and ask the owner.

## Commands

```sh
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"  # Ruby pinned in .ruby-version
ruby -Itest test/<file>.rb -n /<name>/       # one file per command; a second file is ignored
bundle exec rubocop -a <changed files>       # lint changed files only
bundle exec rake ci                          # everyday gate, with the lint above
LANG=C LC_ALL=C bundle exec rake ci_full     # complete gate; repeat with en_US.UTF-8
```

- `rake ci` includes enola. CI runs neither enola nor RuboCop, so only your local run checks them.
- Run `ci_full` for durability (migrations included), MCP, packaging, or committed evidence.
- Do not hand-fix leftover offenses in code you changed from your main session: give them to a small-model subagent
  if you can, else report them.
- A gate already red at HEAD is not yours to chase: prove it in a detached worktree and say so. Never `git stash`.
  `rake` stops at the first red prerequisite, so run the gates after it by name.
- Real-model runs need `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`. `.env` mixes `KEY = value` and `KEY=value` and only
  some scripts read it: confirm the key is set before a run. Never print or commit its values.

## Read before you touch

| Touching | Read first |
|---|---|
| A decided rule, an ADR, approval policy | [ADR index](documentation/adr/README.md), [adr.md](.agent/rules/adr.md) |
| Effects, external calls, durability, authority | [invariants](documentation/architecture/invariants.md), then the full clause it links to |
| Ruby | [coding standard](documentation/governance/coding-standard.md) |
| Tests; a new file's mode | [testing standard](documentation/governance/testing-standard.md), [testing.md](.agent/rules/testing.md) |
| A migration, accepted ADR, CLI verb, public API entry, renamed test | [testing.md](.agent/rules/testing.md): second homes only `ci_full` catches |
| Agent grading, evals; prompts, context, caching | [evaluation.md](.agent/rules/evaluation.md); [context.md](.agent/rules/context.md) |
| Agent memory; file writes | [memory.md](.agent/rules/memory.md); [files.md](.agent/rules/files.md) |
| Graph nodes, subgraphs, child effects; MCP | [subgraphs.md](.agent/rules/subgraphs.md); [mcp.md](.agent/rules/mcp.md) |
| Channels, attachments | [channels.md](.agent/rules/channels.md) |
| Delegating to subagents | [subagent orchestration](documentation/governance/subagent-orchestration.md) |

## Every task runs against a quality bar

1. **Set the bar before the change.** Copy [the template](documentation/governance/quality-bar-template.md), pick the size (S/M/L),
   write the outcome and the rows.
2. **Loop:** grade every row → fix what fails → re-grade, until an iteration changes nothing and no row is FAIL
   or OPEN. A row passes only because its check ran this time. The same row failing three iterations running goes
   to the owner.
3. **Review before every commit:** a fresh agent, not the author, checks the diff against the bar. Fix critical
   and high findings and real defects on paths people use; note rare edge cases in the bar, do not build them. The template's doc-only row needs no reviewer.
4. **Report in plain terms:** outcome met or not, commands and results, what is a real-model result and what is
   plumbing, decisions still open. Name real files and seams; never overclaim.

## Owner rules — non-negotiable

- **Simple over complicated; no rare cases.** When two designs work, take the one with less machinery. Do not
  write code for a case that cannot happen or has never happened.
- **Defer complexity to a future plan.** Keep the agent as simple as possible. Anything that adds complexity now (a
  new mechanism, a compliance regime, a second path, a feature not needed for the task's outcome) is written into a
  future plan beside the task's bar (design, tests, open decisions), not built.
- **Understand before you build; extend, don't reinvent.** Map the existing path (with enola where available), read
  it end to end, and name the seam you extend before writing a line. A class duplicating an existing effect, loop, store, or
  model call is a defect.
- **No backward compatibility before 1.0** (ADR-059). No legacy-row readers, shims, or aliases; a database may be
  reset. Migration ordinals stay monotonic and checksummed; each new migration assumes a fresh schema.
- **Gem boundaries are absolute** (ADR-052). Use another gem only through the facade its README names, never its
  stores, tables, key layouts, record internals, or private rules. Missing capability goes into the owning facade;
  guard the boundary with a leak test (`test/memory_boundary_test.rb`). Ask before changing a cross-gem interface.
- **Non-deterministic and external calls go through the effect journal** (ADR-016): `EffectDispatcher.run`
  (`SessionEffects#model_call`; `Runtime#model_generate` for the one-shot runtime). Key identity on the request,
  never the answer; terminal receipts are immutable; an unanswered unsafe call stops as `:unknown`.
- **A user's stop ends the turn; it never aborts the graph** (ADR-057). Stops go through
  `Tamoz::Cancellation::Stops`; cancelling the graph context's token is for shutdown and recovery.
- **Pin authority; never re-derive it by id** (ADR-063). A reloaded profile must match the `canonical_digest`
  recorded at bind time (`WorkerRuntime#child_profile_for`, `validate_thread_profile`); a failed store or authority
  lookup fails closed. Starting, retrying or resolving an effect binds to the active lease (ADR-016,
  `EffectReconciler#reconcile`); a reconciliation may still record what it observed after losing it.
- **Approval policy is data** (ADR-053). Verdicts and evidence live only in `gems/tamoz-approval/policy/*.yaml`;
  never hardcode a verdict, approval constant, or bypass flag. A policy edit that loosens authority is also an ADR
  change.
- **Domain knowledge is data, never code** (ADR-058). Catalogs, prompts, intents and risk classes, compensation
  maps, watch rules, fact templates, fixture responses, and benchmark families live only in
  `test/fixtures/domains/*.json`, loaded by `test/support/domain_loader.rb`. The pinned wire digests and the
  protocol SHA in `documentation/benchmark/BENCHMARK_PROTOCOL.json` change only as a reviewed update; the
  aquaculture catalog digest is pinned in the Go repository too.
- **Tamoz carries no caller's domain** (ADR-058). A caller's domain (its diagnosis codes, intents, objective, facts)
  reaches Tamoz at runtime in the episode request, and Tamoz reasons from that alone. Never copy a caller's specs,
  catalogs or codes into Tamoz's code, fixtures or tests; test a generic rule with a generic case or one of Tamoz's
  own benchmark domains in `test/fixtures/domains/`.
- **Real model for real runs; fakes stay in tests** (ADR-024). Tests never call a real LLM; a stub, fixture, or
  deterministic provider is never presented as evidence that the agent reasons.
- **A received channel file is never stored** (ADR-064). It is a temporary handoff, deleted once the turn has read it; only
  what was read from it stays, like a typed message.
- **Keep the record true.** A change that alters a decided rule updates its ADR in the same change
  (`rake adr:validate adr:verify`). Never rewrite accepted intent to match the code: mark it
  `Implementation: Partial` and raise it with the owner.
- **Never force-push**, `--force-with-lease` included ([git.md](.agent/rules/git.md)). Amend before pushing;
  afterwards publish a new commit.

## Working practice

- **Clean house as you go.** A file you read that breaks a rule here: fix it in the same change only if it is
  already in your change, the fix is small, and a test proves it (own commit); otherwise report file:line and the
  rule. Prefer a test that fails on the rule over fixing one instance.
- **Record a lesson in the change that taught it**, here or in `.agent/rules/<topic>.md` when it needs evidence.
  Ground it in the real seam; rewrite a rule a new lesson contradicts.
- **Changing what a `script/*_eval` grades:** run it before and after. A missing model or tool, or too few runs, is
  reported and never a pass. Raise the bar rather than weaken a check.
- **Stop every process you started** (servers, workers, browsers) before you finish.

## Comments

Default to none: name things so the code reads without them. A genuine "why" (a safety invariant, a non-obvious
failure model, a rejected alternative) gets one or two lines. No multi-line headers on new classes or methods, no
narrative of the bug a fix replaced, no ADR citation as decoration. History belongs in commits and PR bodies.

<!-- enola:begin -->
## enola — architecture map (MCP)

- Before a change whose blast radius is not obvious: `generate_snapshot`, then `set_baseline` once.
  `impact_analysis` for what depends on the code; `explore`, `traverse`, `find_path` for how it is wired. Exact and
  cheaper than reading files; prefer them to grep.
- After a structural change: `generate_snapshot`, `diff_snapshot`. Fix a new cycle or unintended coupling before
  presenting the change.
- Where enola's Stop hook is installed it speaks only on a regression. "Baseline not comparable" is no verdict on
  your change: re-pin the baseline.
<!-- enola:end -->

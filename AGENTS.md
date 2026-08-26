# AGENTS.md — tamoz

Ruby monorepo (see README.md for the component map: tamoz-core, tamoz-approval, tamoz-agent, tamoz-mcp, tamoz-graph, tamoz-scheduler, tamoz-sqlite, tamoz-stream, tamoz-tools, tamoz-evals).

- Ruby version pinned in `.ruby-version`; gems live in `gems/`, entry points in `apps/` and `bin/`.
- Tests: `test/` (Minitest), run via `rake`. One test FILE per command — `ruby -Itest a_test.rb b_test.rb` runs only the first.
- Ask before changing cross-gem interfaces; most bugs live at gem boundaries.
- When delegating work to background subagents, follow the standing protocol in
  `docs/subagent-orchestration.md` (file-ownership contracts, behavior model in the brief,
  named gates + known-red list, fixed report format).

## Quality gates and coding standard

- Follow `docs/CODING_STANDARD.md` for every code change — it is the repo's Ruby/Rails
  best-practice contract and is enforced by the quality gates.
- The quality program (RuboCop, Reek, SimpleCov, Enola) is chartered in
  `docs/QUALITY_PROGRAM.md`; live state and the resume point live in
  `docs/QUALITY_PROGRAM_STATE.md`.
- Everyday gate: `rake ci` + `rubocop` + `enola check` (see the state doc's gate
  policy — `ci_full` both locales only for durability/MCP/packaging/evidence slices).

## Working conventions (owner directive)

- **No backwards compatibility.** Databases are free to be reset or cleaned whenever
  a change needs it; never write legacy-row handling, compatibility shims, or
  read-time tolerances for old rows. Migration ordinals are still consumed
  monotonically (they are checksummed and manifest-pinned), but each new migration
  assumes a fresh schema — the previous rows do not exist.
- **Choose the simple solution over the complicated one.** When two designs both
  work, take the one with less machinery. A plan's elaborate sub-item is not
  obligatory if the simple path already delivers the required property.
- **Do not cover rare cases.** If a scenario cannot happen by construction (or only
  in a case that has never occurred), do not write code for it. Fix it when it
  actually shows up, not preemptively.
- **Understand before you build; extend, don't reinvent.** Before writing new
  machinery, map how Tamoz already does the thing — with enola
  (`explore`/`traverse`/`impact_analysis`) and by reading the real path end to end.
  Name the existing seam you are extending before you write a line. A new class that
  duplicates a capability the codebase already has (an effect, a loop, a store, a
  model call) is a defect, not progress. Most of what a change needs already exists.
- **Non-deterministic and external calls go through the durable effect journal.** A
  model or tool call is non-deterministic and a durable graph replays its nodes.
  Never call one raw inside a node and let downstream state depend on the result —
  route it through `EffectDispatcher.run` (see `SessionEffects#model_call`, and
  `Runtime#model_generate` for the ephemeral one-shot runtime) so a replay
  returns the recorded receipt, not a fresh, different answer. Key identity
  and dedup on the request, never on the answer. Terminal receipts are immutable;
  an unanswered call is resolved by its safety class (`:idempotent` grants a fresh
  attempt, `:unsafe` stops as unknown). The one-shot ephemeral runtime journals
  through the same dispatcher over in-memory stores by design.
- **Approval policy is data too.** Whether an action needs approval, and under
  what evidence, lives only in `gems/tamoz-approval/policy/*.yaml` (base +
  digest-pinned profiles); the engine in `gems/tamoz-approval` interprets it.
  Never hardcode a verdict, an approval constant, or a bypass flag elsewhere.
- **Domain knowledge is data, never code (B9 / P4 gate-4).** Diagnosis catalogs,
  operator prompts, intent types + risk classes, compensation maps, watch-property
  rules and presets, snapshot fact templates, fixture responses, and benchmark-family
  config are authored ONLY in `test/fixtures/domains/*.json` and loaded through
  `test/support/domain_loader.rb` (thin loader modules; zero domain content in Ruby).
  A new domain is a new JSON file — `DomainLoader.domains` picks it up. Never
  reintroduce any of it as Ruby literals, in gems, `test/support/`, or tests. Data
  edits are digest-gated: the six pinned wire digests (aqua/clim intent, diag,
  prompt) and the protocol SHA in `documentation/benchmark/BENCHMARK_PROTOCOL.json`
  change only as a deliberate, reviewed update (the parity digest `e4f86620…` binds
  the same catalog on the Go side — a Ruby edit without the Go mirror fails).
- **Real model for real runs; fakes stay in tests.** Any run meant to show the agent
  works calls a real provider. Test code never calls a real LLM, and a test, stub,
  fixture, or deterministic provider is never shown or described as evidence that the
  agent reasons or is intelligent.
- **Report in plain terms, grounded in the real code.** When explaining to the owner,
  name actual files and seams, not invented abstractions or jargon; say plainly what
  is a real model result versus a plumbing test, and never overclaim.

## Comments

Default to none. Name things so the code reads without them; if it does not read,
fix the code, not the comment. Never restate what the line below does.

When a comment is genuinely needed (§11's "why": a safety invariant, a non-obvious
failure model, a rejected alternative), write one or two lines. Not a paragraph, not
a narrative of the bug it replaced, not a rationale for a decision the diff already
shows. Commit messages and PR bodies carry history; source files do not.

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

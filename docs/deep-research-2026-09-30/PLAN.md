# Deep research — implementation plan

Research: [RESEARCH.md](RESEARCH.md). Design: [DESIGN.md](DESIGN.md). Bar:
[QUALITY_BAR.md](QUALITY_BAR.md). Eval: [EVAL.md](EVAL.md).

## Agreed with the owner (2026-09-30)

| # | Decision |
|---|---|
| A1 | The definition and the four phases in README.md |
| A2 | Web only in v1 |
| A3 | One interface for CLI and chat; no internals shown to the user |
| A4 | Brave Search is the real search provider (`BRAVE_API_KEY` is in `.env`) |
| A5 | Budgets are flexible data; Tamoz proposes new defaults from its own run records, through the approved improvement lifecycle |
| A6 | GLM-5.3-Flash via Z.ai (`ZAI_API_KEY` is in `.env`) runs deep research, for the lead and the children |
| A7 | The research plan is shown to the user before any search runs, and the user can accept, edit or stop it |
| A8 | Dynamic fan-out and per-role personas (DESIGN §3–4) |
| A9 | The final report is written to the file system (`$TAMOZ_RUNTIME_DIR/research/<date>-<slug>/report.md`); the reply carries the summary and the path (DESIGN §2, §6) |
| A11 | CLI `tamoz deep-research "<question>"`; chat `/research <question>`; a plain question never starts a research run (DESIGN §2) |
| A12 | Search and page reads are named provider adapters in `tamoz-mcp-websearch`; `.env` keeps `BRAVE_API_KEY` as it is (the launcher maps it to the adapter's `TAMOZ_BRAVE_API_KEY` ref, DESIGN §5); the generic `http` provider is removed |
| A13 | Page reads are direct, through `EgressClient`'s existing checks in a reader mode that accepts any public FQDN reached from a search hit; HTML → text with `nokogiri` in `tamoz-mcp-websearch` (RESEARCH §5, DESIGN §5.2). Cloudflare was set aside: there is no API token |
| A14 | Research is on whenever search and reader adapters are configured; fan-out vs single agent starts from the R3 result and self-improvement may retune it later |
| A10 | A new gem, `tamoz-research`, holds the research rules behind one facade; gem boundaries are absolute and guarded by a test (DESIGN §11) |

## Owner action before R1

Every design decision is settled (A1–A14). One approval remains:

| # | Action | Why |
|---|---|---|
| O3 | Approve the cross-gem additions: `tamoz-agent-kernel` (`zai` provider, `max_concurrent_requests`); `tamoz-harness` (roles, prompts, tool schemas, role tool naming, per-role limits); `tamoz-agent-session` (command entry, plan checkpoint, `report_sources` tool, coverage gate, batching, report write, all through the `tamoz-research` facade); `tamoz-mcp-websearch` + `script/websearch_adapter` (adapters, `fetch_result`, reader-mode host check, adapter-declared credentials, `http` provider removed, `nokogiri`); `tamoz-comms` + `tamoz-comms-gateway` (`research` command); `tamoz-mcp` (`ZAI_API_KEY` in the never-inherited list); `tamoz-approval` policy YAML; `tamoz-agent-improvement` (budget candidate); the new `tamoz-research` | AGENTS.md: ask before cross-gem interface changes |

Earlier D1–D7 are resolved: D1 → A11, D2 → A9, D3 and D4 → A13, D5 → A12, D6 → O3, D7 → A14.
O1 and O2 (Cloudflare) are dropped with A13.

## Rounds

Eval first (red), then the code that turns each row green. One round is one sub-agent-reviewed
unit and one commit. AGENTS.md rules apply throughout: extend the named seams, no compatibility
code, prompts and budgets as data, no model call or egress outside the journal.

| Round | Content | Bar rows | Seams |
|---|---|---|---|
| R0 | enola `generate_snapshot` + `set_baseline`. Check four seams and record the answers: (a) the chat worker runs the work route; (b) children share the parent's effect journal, so one page is fetched once; (c) the `WorkGate` interrupt can carry a free-text answer; (d) GLM-5.3-Flash tool calls work through the OpenAI-compatible client (one labelled real smoke call). Write the offline spec suites against the target, run them at the parent, and record the pending count | all pending | `test/` |
| R1 | Model and search plumbing: `zai` provider + `zai/glm-5.3-flash` route with `max_concurrent_requests`; the adapter structure with `brave` and `fixture` search adapters, adapter-declared credentials, `count` clamp, the `http` provider removed; admitted websearch schemas shown on the work route (G1) | A4, S2 | kernel providers + data, `tamoz-mcp-websearch`, adapter script, `WorkContext` |
| R2 | `fetch_result`: handle → URL, the `direct` reader (reader-mode host check on `EgressClient`, 2 MiB raw cap, `Accept: text/markdown`, `nokogiri` extraction) and `fixture` reader adapters, bounded untrusted text output, journal key on the URL, read-only approval class | S1, S2, S3, C6 | `tamoz-mcp-websearch`, adapter script, approval policy |
| R3 | Create `tamoz-research` (gemspec via `gemspec_helper.rb`, README facade, lockstep version, boundary test green). Roles and fan-out: `research` + `verify` roles and prompts, structured briefs in `delegate.json`, `report_sources` calling `Tamoz::Research.ledger` for the excerpt check, `report_support`, role tool naming, per-role limits, batching by route concurrency | A6, B2, S4, C5 | new `tamoz-research`, `tamoz-harness`, `WorkDelegation`, `FindingsReport` pattern |
| R4 | The entry and the lead's method: `tamoz deep-research` + chat `/research`, `research_method.md` prompt, `propose_research_plan` + the checkpoint through `WorkGate` + policy YAML, ledger and sub-question statuses, coverage and stop gate, `research_budgets.json` | P1–P3, P5, C1–C4, A5 | `tamoz-research` (`Coverage`, `StopRule`, `Budgets`), prompt pack, `WorkGate`, `WorkTools`, prompt pack |
| R5 | Writing and delivery: report assembly, generated sources list, the verify pass, the report and run folder written to disk through an idempotent effect, plan and progress rendering on CLI and chat, the internals denylist | B1, B3, B4, I1–I3 | `WorkTools`, surface prompts, comms rendering |
| R6 | Durability: kill while paused at the checkpoint, and kill mid-wave, on SQLite in a forked process | P4, C7 | tests; fixes in the seam that fails |
| R7 | agenteval research pack: fixture web, graders, controls, the 500-request Brave ledger and query cache, `rake agenteval:research:prove` | A5 (fixtures), EVAL §3 controls | `agenteval/`, `test/fixtures/research/` |
| R8 | Real-model runs on GLM-5.3-Flash + Brave, within the 500-request cap: dev set in both arms, tuning labelled as development, then the held-out set once; FINDINGS.md | R1–R6 | — |
| R9 | Self-tuning: `run.json` records → a `research_budgets.json` candidate through `CandidateLifecycle`, evaluated on dev data, owner-approved | T1–T3 | `tamoz-agent-improvement` |

**Gates per round:** `rake ci` + `rubocop` + `enola check`. `ci_full` in both locales for R2
(egress), R4 and R6 (durability-adjacent) and R5 (CLI and chat packaging). enola `diff_snapshot`
against the R0 baseline after each round; a new cycle or unplanned coupling is fixed before commit.

## Risks

- **Fan-out may not beat one agent** (as in T6). R3 in the bar decides the default, and the single-agent
  path is a first-class outcome, not a failure.
- **The direct reader cannot read every page:** JavaScript-only pages, bot walls, logins. A failed or thin read is recorded, and the child moves on. If real runs lose key sources this way, a hosted reader adapter (e.g. Cloudflare `/markdown`) becomes a new decision.
- **GLM-5.3-Flash tool-calling quality is unknown in Tamoz.** R0(d) is the first check; the offered-tool
  token overhead seen in T6 is measured again on this model.
- **The eval is capped at 500 Brave requests (owner).** With 15 searches per run and a shared query cache
  (EVAL §3), the question sets were cut to 6 dev and 8 held-out. The held-out result is therefore evidence
  about 8 questions at a 15-search budget, not about deep-preset runs. Deep runs are exercised on the dev
  set only if the reserve allows.
- **The web is not frozen.** Held-out numbers are one run on one date; the fixture web is what stays
  reproducible.

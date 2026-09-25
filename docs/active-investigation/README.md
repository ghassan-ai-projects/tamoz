# Active investigation — give Tamoz the ability to analyse before it decides

Status: **in build (revision 2)** · Plan date: 2026-09-23 · Revised: 2026-09-25 ·
Branch: `add-investigation-ability`

When Tamoz is asked to decide something, whether by agentic-stream over gRPC, the
`tamoz` CLI, or a chat message, it should be able to **go and look**. It asks
agentic-stream for more situation data, reads logs, checks a server or HTTP
endpoint, and queries metrics or a database. It then re-analyses and decides. If
the data still cannot settle the question, it abstains honestly and names what is
missing. Today it decides only from the snapshot it was handed.

| Document | What it is |
|---|---|
| [PLAN.md](PLAN.md) | The design and the work: current state (verified against the code on 2026-09-25), the design, the work packages, the agentic-stream follow-ups, and the evaluation. |
| [QUALITY_BAR.md](QUALITY_BAR.md) | The bar the build must meet, how each item is checked, and the live status of every item. The build loops until every item passes. |

This plan is the product build that
[measurement plan 16](../eval-improvement/measurement-plans/16-active-investigation.md)
says must exist before that eval can report anything but *pending*. The eval
specification stays there. WP5 below implements it.

## Owner decisions (2026-09-23)

| # | Question | Decision |
|---|---|---|
| D1 | Who runs the probes during a gRPC episode? | **Split by scope.** Situation data (history, related situations, features) comes from agentic-stream's EvidenceTools. Operational probes (logs, server/HTTP health, metrics, DB reads) run in Tamoz, and only for probes that agentic-stream grants in the episode's tool catalog. Every probe call goes back to agentic-stream as a tool lifecycle event. |
| D2 | Which probe kinds, and how? | Ask agentic-stream, logs, server/HTTP health, metrics and DB reads. **Use MCP wherever possible:** no direct DB driver and no native metrics client. Metrics and DB go through MCP servers the operator configures. Tamoz adds no network client of its own. |
| D3 | How much authority does an investigation have? | **Strictly read-only.** Only probes the operator declared read-only, each with governed arguments. Anything that changes state stays on the existing decision and approval path. |
| D4 | What do the CLI and chat produce? | **A findings report plus proposals.** Evidence gathered, hypothesis, confidence, gaps, and proposed next actions. The investigation never executes a proposal. Acting on one is a follow-up turn through the normal session approval flow. |

## Revision 2 (2026-09-25) — what changed and why

Re-reading the code showed the first plan was right about the episode path and wrong
about the session path, and heavier than it needed to be. Every change below follows
the `AGENTS.md` rules: extend the existing seam, take the simple design, do not
cover rare cases.

| # | Revision 1 | Revision 2 | Why |
|---|---|---|---|
| R1 | New gem `tamoz-investigation` | **No new gem.** Probes live in `tamoz-agent-capabilities`, next to `McpSourceBuilder` and `GovernedDatabaseSource` (the governed-MCP seam that already exists). `tamoz-stream` receives plain callables; it never loads probe code. | The gem's only justification was that `tamoz-stream` must not depend on agent gems. It does not have to: the worker launcher is the composition root and hands the stream host duck-typed callables. |
| R2 | `<runtime-dir>/investigation/probes.yaml` | `sources.probes` in the runtime `config.yaml`, a fifth `KNOWN_SOURCES` entry. | Every other operator capability source is configured there already, with the same trust boundary. |
| R3 | Four governor classes (`sql_select`, `command_allowlist`, `http_get`, `log_query`) | **One argument model.** Every argument of the backing MCP tool is either a pinned template or a typed free slot (`string` with a byte cap, `integer` with bounds, `enum`, or `sql_select`). An allowlisted command, a fixed URL and a fixed time window are all *data* in that model. Only `sql_select` needs code, and it reuses `GovernedDatabaseSource.validate_query` in place. | Less machinery, same property: the model can only fill declared slots. |
| R4 | Edit the five digest-pinned domain prompts (and the Go mirror) to drop "Use ONLY the facts provided"; bump the reasoning document to v3 | **No prompt edit and no protocol bump.** The frame's system section gains a TOOLS block, rendered only when the episode has a tool surface. It says tool results are provided facts, and teaches the tool-turn shape (`purpose` required) and `evidence_gaps`. The protocol id stays `tamoz.episode-diagnosis/v2`: the terminal shape the pinned prompts teach is unchanged, and the tool-turn shape was never taught to any model before. | Avoids a cross-repo digest change for no behavioural gain. An episode without tools keeps byte-identical frames, so no frame digest or fixture moves. |
| R5 | New graph branch for budget exhaustion; `GRAPH_VERSION` bump | **A FINAL directive, no new branch.** When the next reason call is the last one the tool or model budget allows, `rebuild_frame` tells the model to decide or to choose `unknown` and name the `evidence_gaps`. A tool turn after that ends typed as budget-exhausted. Changed nodes bump their node version. | The loop always ends, and the model budget (which usually runs out first) is covered. Reusing the one-shot repair was rejected in review: it could not cover the model budget and could loop. |
| R6 | Map `evidence_gaps` to the `request_evidence` intent in the decision builder | The model recommends `request_evidence` itself where the domain teaches it (today only `thermal-lab`). `evidence_gaps` go into the decision summary and the document projection. | `request_evidence` is domain data; the kernel must not name it. |
| R7 | Session: probes in the discovery/`read_only` phases; report produced by `verify` | Session: probes in the **work loop** (`tamoz code`, `tamoz investigate`, chat with `--work-routing`), whose tool surface today lists only local toolbox tools. The report is a harness tool, `report_findings`, validated like `update_plan`. The legacy graph gets the probes for free through `CapabilityBinding`, with no report. | The work loop is the live harness. `verify` belongs to the legacy route. |
| R8 | Per-probe `timeout_s` and `max_rows` | `max_result_bytes` only. Timeouts come from the MCP server's existing supervisor budgets. | An MCP result is text; bytes are what Tamoz can enforce. |
| R9 | `ToolLifecycle` needs a Go ledger change (G4) | Go already consumes `ToolLifecycle` and counts `execution_started` events against `max_tool_calls` (`worker_executor.go`). Tamoz only has to emit them. | Verified in agentic-stream. |
| R10 | `host: stream\|worker` field in the Go tool catalog (G1) | Tamoz decides hosting by the `probe_` name prefix. A Go spec can already grant `probe_*` names (they match Go's `^[a-z][a-z0-9_]{0,62}$` tool-name pattern), so **D1 works against today's Go wire**. The host also accepts Go's `evidence_get` spelling for its dotted `evidence.get` (Gap L). G1 shrinks to "real descriptions for the stream tools". | No cross-repo interface change is needed to ship. |
| R11 | Separate WP for agentic-stream code (WP6) | The Go follow-ups (G1, G2) are written up in the plan and left to agentic-stream. Its working tree has unrelated uncommitted edits, and none of the follow-ups blocks this build. | Scope: this branch is Tamoz. |
| R12 | Probes as a fifth capability source | Probes register inside their backing server's `mcp:<server>` source through a wrapper (`ProbeSource`), and are named `probe_<snake_case>`. | The capability registry is a closed world of four source prefixes, and OpenAI-compatible providers reject dots in function names. |
| R13 | (not addressed) | **One policy-data entry:** `probe_*: {tier: read, verb: read}` in `gems/tamoz-approval/policy/base.yaml`, and the engine matches a `tool_tiers` key ending in `*` by prefix. | Every tool absent from `tool_tiers` falls to `local_execute` (ask, or deny under `plan`), so without it every probe call would wait for a human. The operator's probe declaration is the authority; the policy stays data. **Owner review requested.** |

## The shape of the answer, in one paragraph

Tamoz already has both loops it needs. The episode graph loops `reason → validate →
execute_tool → rebuild_frame → reason` ([episode_graph.rb](../../gems/tamoz-agent/lib/tamoz/agent/episode_graph.rb)).
The session work loop calls tools, observes and continues
([session_work.rb](../../gems/tamoz-agent-session/lib/tamoz/agent/session_work.rb)).
Tamoz already has a governed MCP client with operator-declared `read_only_tools`
([mcp_source_builder.rb](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb)).
What is missing: (1) a governed probe catalog over those MCP tools; (2) an episode
frame that shows the model its tools and their results, runs every request, and turns
an exhausted budget into an honest abstain; (3) probes and a findings report in the
work loop. Everything else is reused.

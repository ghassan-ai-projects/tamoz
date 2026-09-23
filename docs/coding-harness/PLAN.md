# Coding harness — design and work plan

Read [README.md](README.md) first for the owner decisions D1–D6. The context
mechanisms are specified in [CONTEXT-ENGINE.md](CONTEXT-ENGINE.md), the prompt
layer in [PROMPTS.md](PROMPTS.md), the evaluation in [EVAL.md](EVAL.md).

---

## 1. Where Tamoz stands today (read from the code, 2026-09-23)

### 1.1 The model call

| Fact | Where |
|---|---|
| Every model call is one `system` + one `user` message, `temperature: 0`, `response_format: json_object`, non-streaming. There is no message history and no `tools` field. | [episode_model_transport.rb:71](../../gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb:71) |
| The transport is the only model client. `ModelClientFactory` builds it for every OpenAI-compatible provider (DeepSeek, OpenAI, OpenRouter, Ollama, …). Anthropic and Gemini native protocols are refused. | [model_client_factory.rb:11](../../gems/tamoz-agent-kernel/lib/tamoz/agent/model_client_factory.rb:11) |
| Usage parsing reads `prompt_tokens` and `completion_tokens` only. DeepSeek's `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` and OpenAI's `prompt_tokens_details.cached_tokens` are dropped, so no cache hit rate can be measured. | [episode_model_transport.rb:213](../../gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb:213) |
| Session model calls are journaled through `SessionEffects#model_call` → `EffectDispatcher.run`; the ephemeral runtime through `Runtime#model_generate`. Both keep a request digest. | [session_effects.rb:19](../../gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:19), [runtime.rb:660](../../gems/tamoz-agent/lib/tamoz/agent/runtime.rb:660) |

### 1.2 The session loop

| Fact | Where |
|---|---|
| A turn is `intake → route → (adaptive loop) → deliberate → step_gate → step_execute → evaluate → verify → terminal`. | [session_graph.rb](../../gems/tamoz-agent-session/lib/tamoz/agent/session_graph.rb) |
| Each stage is a fresh one-shot JSON prompt: `PLAN_SYSTEM`, `REVIEW_SYSTEM`, `VERIFY_SYSTEM`, `ROUTING_SYSTEM`. The plan must name every argument **before** it runs (`ARGUMENT_RULE`), so a plan cannot use what an earlier step discovers. | [deliberation.rb:14](../../gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb:14) |
| The adaptive loop is the only iterative model loop: read-only, **3 iterations max**, one action per call. | [session_adaptive.rb:15](../../gems/tamoz-agent-session/lib/tamoz/agent/session_adaptive.rb:15) |
| A failed check gets at most **2** reviewed repairs. | [session_nodes.rb:26](../../gems/tamoz-agent-session/lib/tamoz/agent/session_nodes.rb:26) |
| Measured effect on coding: on the committed agenteval baseline the plan-review gate aborted **28 of 46** trials before any edit. The coding solve-rate is unknown because the agent mostly never acts. | [measurement-plans/01-coding.md](../eval-improvement/measurement-plans/01-coding.md) |

### 1.3 Context management

| Fact | Where |
|---|---|
| The whole planning context is a JSON object capped at **16 KB**. Observations over 1 KB are spilled to the `ArtifactStore` by digest with a 256-byte preview. Over the cap, observations are dropped to metadata. A model summary (`COMPACTION_SYSTEM`) is optional and falls back to a deterministic frame. | [session_planning_context.rb:19](../../gems/tamoz-agent-session/lib/tamoz/agent/session_planning_context.rb:19) |
| Context controls exist and are audited: `/new /reset /compact /usage /context /think /verbose`. `/new` moves the thread to a new generation (`.gN`). | [session_context_controls.rb](../../gems/tamoz-agent-session/lib/tamoz/agent/session_context_controls.rb), [cli_session_commands.rb:262](../../gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:262) |
| There is no token measurement, no window-pressure trigger, no request-prefix stability discipline, and no cache accounting. | — |

### 1.4 Tools

| Fact | Where |
|---|---|
| Six coding tools: `read_file` (whole file, ≤64 KB, returns sha256), `list_directory` (≤200 entries), `search_text` (literal only, ≤100 hits), `apply_patch` (exact before/after, sha-checked, atomic), `create_file` (no overwrite), `run_check` (a configured command, no shell). | [tool_catalog.rb:13](../../gems/tamoz-tools/lib/tamoz/tools/tool_catalog.rb:13), [toolbox.rb:26](../../gems/tamoz-tools/lib/tamoz/tools/toolbox.rb:26) |
| Tool descriptions are prose strings with the argument shape inline. There are no JSON schemas a native tool call could use. | same |
| `apply_patch` already enforces read-before-edit through `expected_sha256`, which is DSH's `fs-observation-policy` in a different form. | [deliberation.rb:82](../../gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb:82) |
| Approval tiers are data: reads `allow`, `workspace_write` `allow` with `once/session` grants, `local_execute` `ask`. | [base.yaml](../../gems/tamoz-approval/policy/base.yaml) |

### 1.5 System prompt and personalization

| Fact | Where |
|---|---|
| **No identity or persona prompt.** The only system text is per-stage ("You are the planning stage of Tamoz…"). | [deliberation.rb:14](../../gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb:14) |
| **No project-instruction loading.** Nothing reads the target repository's `AGENTS.md` / `CLAUDE.md`. Skills must live outside the worked tree, because "skills are instructions". | [runtime_directory.rb:159](../../gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:159) |
| **No operator persona or user preferences.** The profile carries roles, budgets, checks, tools and policy only. | [profile/fields.rb](../../gems/tamoz-agent-profile/lib/tamoz/agent/profile/fields.rb) |
| What does exist: `/think` and `/verbose` become frame directives, memory recall adds `memory` records, a behaviour snapshot is injected. | [session_planning_context.rb:526](../../gems/tamoz-agent-session/lib/tamoz/agent/session_planning_context.rb:526) |

### 1.6 Surfaces

- **CLI:** `tamoz ask/resume/continue/follow-up/redirect/...` over the durable session ([cli_session_commands.rb](../../gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb)).
- **Chat:** comms gateway (Telegram) turns are session turns; `bin/tamoz-chat-sim` drives the real runtime with a mock chat.

### 1.7 Blast radius (enola snapshot 2026-09-23)

- `Tamoz::Tools::Toolbox`: 36 transitive dependents (22 tests, 4 `script/`, CLI, kernel, agent). Extend it; do not reshape its public methods.
- `EpisodeModelTransport`: 5 direct test dependents (it is built through the factory, duck-typed). Adding a method is cheap.
- `Tamoz::Agent::Deliberation`: fan-in 21, fan-out 32, a call-graph hotspot. **Do not change it** in this plan. The work loop does not use its stage prompts.
- `SessionEffects`: 2 test dependents statically; it is reached through the session graph. Add methods; do not change `model_call`'s contract.

---

## 2. Guardrails — invariants every package must keep

| # | Invariant | Enforced by |
|---|---|---|
| H1 | **Model-visible means journaled.** Every byte in a model request can be rebuilt from durable records: the surface log, the `ArtifactStore`, and the effect journal. A replay rebuilds the same request bytes. | `ContextEngine::Surface#derive` + a replay test (EVAL G-3) |
| H2 | **Every model call and every tool call goes through `EffectDispatcher.run`**, keyed on the request, never on the answer. A replay returns the recorded receipt. | `SessionEffects` (existing) |
| H3 | **The header is frozen per request series.** System sections and tool schemas are sorted by a fixed, locale-independent rule and compared byte-for-byte. The header changes only on a declared trigger, and every change is logged with a reason. | `ContextEngine::RequestHeader`, `ContextEngine::Series` |
| H4 | **Append-only, except declared replacements.** Request *n+1* is request *n* plus new messages, except at a logged compaction or prune replacement. | `ContextEngine::Surface`; EVAL G-2 |
| H5 | **Volatile facts never enter the header.** Date, cwd, git branch, the plan, memory recall, project `AGENTS.md`, preference changes: all go into the body as sourced messages. | `Harness::PromptPack` section rules |
| H6 | **Authority is never granted by content.** Tool results, project instructions, skills and summaries are data. The tool surface is fixed per series. A summary is not evidence and cannot add a tool, a path or an approval. | fixed surface; `ContextEngine::CompactionSummary.validate!` |
| H7 | **Every mutation passes the existing approval gate and plan scope.** Nothing in the loop bypasses `step_gate` or `tamoz-approval`. | `SessionWork#gate` → existing `decide_step_tool` |
| H8 | **Reversible before lossy.** Spill before prune, prune before summarise. A spilled output is recoverable byte-for-byte. | `ContextEngine::Policy` order |
| H9 | **Bounded.** Tool calls, model calls, wall time and tokens per turn are budgets. Running out ends the turn honestly (a handoff note and what is left), never silently. | `Harness::LoopPolicy`, `ReceiptBudgetController` |
| H10 | **No secret reaches the model or the journal.** Tool output passes the existing secret scrub before digesting or spilling. `**/.env*` stays denied. | existing `SessionRecords.reject_credential_values!`, approval rule `credential-files` |

---

## 3. Design

### 3.1 The shape, in one picture

```
            CLI  (tamoz code / ask)          chat (comms gateway, chat-sim)
                        \                          /
                         v                        v
                 tamoz-agent-session: durable `work` loop (graph nodes)
                 work_plan -> work_step -> work_gate -> work_execute -> work_observe -> work_step ...
                          |               |                 |
       uses protocol      |               | existing        | existing EffectDispatcher,
                          v               v approval        v Toolbox / capability host
                 tamoz-harness  (prompt pack, instructions, loop policy, plan tool, finish contract)
                          |
                          v
                 tamoz-context-engine  (header, series, surface log, meter, spill, pruner, compaction)
                          |
                          v
                 tamoz-core     (digests, JCS, canonical)
```

Session owns **durability**. `tamoz-harness` owns the **protocol**. `tamoz-context-engine` owns
the **window**. The CLI and chat own only entry and rendering.

### 3.2 New gem: `tamoz-context-engine` (depends on `tamoz-core` only)

Pure and deterministic. It does no I/O and makes no model calls; the summariser and
the artifact store are injected, duck-typed. That makes it gradeable by the eval with
no agent runtime, the same argument the investigation plan used for its gem.

| Unit | Responsibility |
|---|---|
| `ContextEngine::Section` / `ContextEngine::PromptAssembly` | Ordered prompt sections `(order, name)`, sorted byte-wise (never locale-sensitive). Renders the system text. An empty section disappears. |
| `ContextEngine::ToolSchema` | One tool's `{name, description, parameters}` in canonical JSON; sorted by name. |
| `ContextEngine::RequestHeader` | Frozen `{sections, tools, model_route}`. Canonical JCS bytes + digest. `==` is byte equality of the canonical form. |
| `ContextEngine::Series` | Decides whether a request continues the current series or starts one. Triggers: `initial`, `resume`, `change` (header bytes moved), `series` (declared boundary, e.g. after compaction). Emits a `series` record with the reason. |
| `ContextEngine::Surface` | The append-only surface log. Entry kinds: `system`, `user`, `assistant` (text + tool calls), `tool_result`, `runtime_snapshot`, `system_update` (in-history), `checkpoint` (compaction summary), `pruned` (a replacement tool result). Replacement ops shadow a range; the originals stay. `derive(header)` returns the exact message list. |
| `ContextEngine::TokenMeter` | Estimates tokens per entry (UTF-8 bytes ÷ 4 plus structural overhead, as DSH does), calibrated by the last provider-reported `prompt_tokens` on the same series. Answers `pressure(window)`. |
| `ContextEngine::Spill` | Tool output over `max_inline_bytes` → `store.retain(digest:, bytes:)` + a stub: locator, byte and line counts, head/tail preview, and a one-line digest the tool supplies (exit code, match count). |
| `ContextEngine::Pruner` | Under pressure, replaces old oversized tool results with head + `[... middle pruned, full output: <locator> ...]` + tail. No model call. Converges in one pass. |
| `ContextEngine::Compaction` | Balanced cut (never splits a tool call from its result; never shadows surface node 0), retention of the newest slice, the summariser request built as a **byte-exact prefix extension** of the last request, the checkpoint entry, and `validate!` (must shrink, schema sections present, exact strings present). |
| `ContextEngine::Usage` | Disjoint accounting: `input_uncached = prompt_tokens − cache_hit`, `cache_read`, `output`. Reads DeepSeek and OpenAI field names. |
| `ContextEngine::Trace` | One record per request: series id and reason, header digest, surface length, estimated vs reported tokens, cache hit and miss, replacements. The eval and `/context` read it. |

Full mechanism-by-mechanism specification: [CONTEXT-ENGINE.md](CONTEXT-ENGINE.md).

### 3.3 New gem: `tamoz-harness` (depends on `tamoz-context-engine`, `tamoz-core`)

| Unit | Responsibility |
|---|---|
| `Harness::PromptPack` | Loads versioned prompt files shipped in the gem (`prompts/*.md`): identity, operating rules, tool-use rules, editing rules, verification and honesty rules, finish contract, one surface section each for CLI and chat. Digest-pinned by a test. Renders them as `ContextEngine::Section`s. Text is data, never Ruby literals. |
| `Harness::Persona` | Operator persona prefix and suffix from the runtime directory (`<runtime-dir>/persona.md`), trusted, digest-recorded. Profile `preferences` (language, tone, verbosity). |
| `Harness::Instructions` | Finds the target project's `AGENTS.md` (and `CLAUDE.md` if the profile names it), nearest-last chain from the workspace root to the working directory, within a byte budget (outer files dropped first, then the nearest truncated), as DSH's `agent-instructions` does. Emits one **body** message, labelled as project guidance that grants nothing (D4). Off unless the profile opts in. |
| `Harness::LoopPolicy` | Budgets (model calls, tool calls, wall time, tokens), the repeat guard (identical tool+arguments: advisory reminder at 3 and 5, stop at 8, as DSH's `repeat-tool-reminder`), the stop reasons, and when a turn must hand off. |
| `Harness::PlanDocument` | The living plan (M-7): goal, done-when, scope (path roots, checks), steps with status, decisions, **ruled out**, open questions. `update_plan` replaces it whole. Canonical digest. It is the D2 review object. |
| `Harness::ToolCalls` | Parses and validates the assistant's native tool calls against the header's schemas; caps calls per step; maps them to capability requests. Rejects an unknown name (the surface is fixed). |
| `Harness::Finish` | The finish contract: a final message must state what changed, what was verified and how (check names and results), and what is left. A "done" claim without a passing configured check after the last mutation becomes `done_unverified`, never `done`. |
| `Harness::Handoff` | Writes the handoff note (M-10) from the plan and the trace when a turn runs out of budget or hits the second compaction. The next generation opens from it. |

Prompt content and the trust model: [PROMPTS.md](PROMPTS.md).

**Why two gems and not one, or more code in `tamoz-agent-session`.** The context
engine is useful without the coding harness: the episode worker and the stage
prompts can adopt the header and usage accounting later without taking the coding
prompts. The harness is useful without durability: the ephemeral `Runtime` can run
the same protocol over in-memory stores, as it already does for the effect journal.
Both must be testable with no session graph. Putting them in the session gem would
make the eval load the whole runtime to grade a byte-stability property.

### 3.4 Changes to existing gems

**`tamoz-agent-kernel` — the conversation transport (D1).**
- `EpisodeModelTransport#converse(stage:, header:, messages:)`: builds
  `{model, messages, tools, tool_choice: "auto", temperature: 0, stream: false}` as
  canonical JCS, the same digest-bound discipline as `build_request`. No
  `response_format` (tool calls and JSON mode do not mix on every route). Returns
  content, tool calls, finish reason, and `ContextEngine::Usage`.
- `usage_from` keeps cache fields. `ModelCall::Usage` gains `cache_read_tokens`.
- A provider error that says the window was exceeded is normalised to
  `code: "context_window_exceeded"`, so compaction can recover and retry once.
- `ModelClientFactory` gains the routed model's `context_window` and
  `max_output_tokens` from profile role settings, required for a `work` route.
  There is no silent default.

**`tamoz-tools` — the coding surface.**
- Every tool gets a JSON schema next to its description (`ToolCatalog#schemas`).
- `read_file` gains `offset`/`limit` (1-based lines) and returns numbered lines plus
  the whole-file sha256 and total line count. The whole-file cap stays for unranged reads.
- New `glob` (pattern → paths, sorted, capped) and regex mode for `search_text`
  (`regex: true`, `context_lines`, `path_glob`), still with no shell and no host `rg`
  required.
- `apply_patch` returns a unified diff of what it changed. **This is a Tamoz addition, not DSH
  parity**: DSH's model-visible edit result is one line ("The file … has been updated
  successfully.", measured at 123 bytes) and its 3-context-line diff card is UI-only
  (`data.meta.diffs`, excluded from the request; [FILE-CONTEXT.md](FILE-CONTEXT.md) §3.4). The
  prompt-cache research prices "append a diff" as the best-value refresh, which is the reason to
  keep it. A stale sha returns a stable error code with "re-read the file, then retry" (DSH's
  observation policy).
- `run_check` output shaping (M-5): pass → one line (name, exit 0, duration,
  summary counts where the output has them); fail → head and tail with the failure.
  The full log always goes to `ContextEngine::Spill`.
- `recall_output` (new, read tier): read a spilled artifact by locator, with a line
  range or a literal/regex filter.
- `run_command` (only if D3 is accepted): exact argv prefixes from profile data,
  no shell, `read` tier, output shaped and spilled.
- Tier entries for every new tool in `gems/tamoz-approval/policy/base.yaml`. Policy
  stays data (AGENTS.md rule).

**`tamoz-agent-session` — the durable `work` loop.**
- New graph nodes, generalising the adaptive loop rather than adding a second loop
  engine:
  - `work_plan`: first model step; must call `update_plan`. The plan goes through the
    existing semantic reviewer (`REVIEW_SYSTEM`) once. `accept` → `work_step`;
    `revise` → back to the model with the issues; `needs_input` → a clarify request.
  - `work_step`: `Context` derives the request from the surface; `SessionEffects#converse`
    journals the call; the assistant entry is appended.
  - `work_gate`: each tool call goes through the existing path: validate → safety
    class → `step_gate` / `decide_step_tool` → approval. Out-of-scope → a plan
    revision is required (D2).
  - `work_execute`: the existing `SessionEffects#dispatch`; the result is shaped,
    spilled and appended as a `tool_result` entry.
  - `work_observe`: pressure check → prune → (at a boundary) compact →
    (second time) hand off. Routes back to `work_step` or to `verify`.
- The surface log is a graph append channel of **small** entries. Bulk bytes live in
  the `ArtifactStore`; entries carry digests. WP0 confirms how checkpoints encode append
  channels (delta or full state). If a checkpoint stores the full state, the channel
  stays refs-only so a 200-step turn does not write O(n²) bytes.
- `/compact` on a work thread runs `ContextEngine::Compaction` on demand. `/context` renders
  the segment breakdown (header, instructions, history, tool results, checkpoint) from
  the trace. `/usage` adds cache read, uncached input and hit rate.
- A new graph version (`WORK_GRAPH_VERSION = "5"`). No compatibility: reset session
  databases.

**`tamoz-agent-cli`.** `tamoz code "<task>" [--check name=cmd ...] [--scope path ...]
[--json]` pins the route to `work` and requires `--allow-changes`, as editing does
today. Progress rendering shows plan steps, tool calls and approvals.
`tamoz ask` keeps routing. The router learns a `coding_work` reason class that maps
to `work`.

**Comms / chat.** Chat messages are already session turns. The router can pick `work`.
The comms renderer gets a bounded rendering of plan progress and the finish report.
Approvals already relay to chat.

**`tamoz-observability`.** Closed catalog entries for `context.series`,
`context.replacement` (spill, prune, compaction), `context.pressure`,
`model.cache_usage`.

### 3.5 What is reused, not rebuilt

The durable graph and checkpoints; `EffectDispatcher` and the journal;
`tamoz-approval` (no verdict anywhere in Ruby); the capability host and MCP sources
(investigation probes arrive through the same source); `ArtifactStore` (the spill
store); the semantic reviewer prompt; context controls and generations; memory
recall; skills and `load_skill`; `CheckRunner`; `agenteval` and the control-suite
pattern.

### 3.6 What gets simplified after it lands (move, then simplify)

When the paired eval (EVAL.md §5) shows the `work` route is at least as good as the
reviewed-change pipeline on the coding corpus, with no gate regression:
1. `managed_action` coding turns route to `work`; the plan-per-phase pipeline stays
   only for non-coding managed actions, or goes if nothing else uses it.
2. `BoundedCompactor` and the adaptive loop fold into the work loop and
   `tamoz-context-engine`. One context engine, one loop.
This is a separate, owner-approved step. It is not part of WP1–WP9.

---

## 4. Work packages

Each package: seam → deliverables → tests → gate → the claim it licenses, and
nothing more. Gates follow `docs/QUALITY_PROGRAM_STATE.md`: `rake ci` + `rubocop`
(no new offense) + `enola check`. `ci_full` in both locales for WP1, WP5 and WP8
(transport, durability, evidence). Pin an enola baseline at the start of each
package and `diff_snapshot` at the end. A new cycle or unintended coupling blocks
the package. Every package is reviewed by a sub-agent before it is committed.

### WP0 — Contracts and decisions (docs + schemas, no behaviour)
- **Deliverables:** owner answers to D1–D6; JSON schemas for `RequestHeader`, a surface
  entry, `PlanDocument`, the compaction summary, the trace record; the tool JSON
  schemas; the prompt pack outline; a check of how checkpoints encode append
  channels; a fresh enola baseline.
- **Gate:** owner sign-off.
- **Claim:** the contracts are agreed. Nothing works yet.

### WP1 — Conversation transport (kernel)
- **Seam:** `EpisodeModelTransport`, `ModelClientFactory`, `ModelCall::Usage`.
- **Deliverables:** §3.4 kernel items.
- **Tests (fake HTTP):** canonical request bytes are stable; `tools` sorted; tool calls
  parsed; DeepSeek and OpenAI cache fields both land in `cache_read_tokens` and
  counts are disjoint; window-exceeded normalised; a missing `context_window` on a
  work route is refused.
- **Claim:** Tamoz can hold a tool-calling conversation over any OpenAI-compatible route.

### WP2 — `tamoz-context-engine` gem
- **Deliverables:** §3.2; gemspec through `gemspec_helper.rb`; Gemfile; `docs/public-api.json`;
  a README gem-table row.
- **Tests:** the offline guarantee suite G-1…G-12 in [EVAL.md](EVAL.md) §2.
- **Gate:** tests + an isolated `GEM_HOME` install with only `tamoz-core`.
- **Claim:** a deterministic context engine that keeps a byte-stable prefix and
  reversible offload. No agent uses it yet.

### WP3 — Coding tool surface (`tamoz-tools`, `tamoz-approval` policy data)
- **Deliverables:** §3.4 tools items; policy tiers.
- **Tests:** ranged read numbering and bounds; glob and regex caps; the diff after
  a patch; stale-sha error code; check shaping (pass is one line, fail keeps the
  trace, full log spilled); `recall_output` returns exact bytes; secrets scrubbed
  before spill; `.env` still denied; `run_command` refuses argv outside the allowlist.
- **Claim:** a coding tool surface with stable schemas and shaped output.

### WP4 — `tamoz-harness` gem
- **Deliverables:** §3.3; `prompts/*.md` from PROMPTS.md.
- **Tests:** prompt pack digest pinned and ordered; persona and preferences render
  into the right sections; the project `AGENTS.md` lands in the body, never the
  header, and inside its budget; an injected instruction in `AGENTS.md` changes no
  tool, scope or approval; repeat-guard thresholds; plan validation (scope must be
  concrete); the finish contract downgrades an unverified "done".
- **Claim:** a harness protocol and prompt pack. No loop runs yet.

### WP5 — Durable `work` loop (session)
- **Seam:** session graph, `SessionAdaptive` (generalised), `SessionEffects`,
  `step_gate`, context controls.
- **Deliverables:** §3.4 session items; `WORK_GRAPH_VERSION`.
- **Tests (scripted provider, deterministic, never shown as intelligence):** plan first
  and reviewed; an out-of-scope edit forces a revision; every mutation passes
  approval; `kill -9` between a tool call and its result replays with no double
  apply; replay rebuilds identical request bytes (H1); pressure → prune → compact →
  hand off in that order; `/compact`, `/context`, `/usage` work on a work thread.
- **Gate:** WP5 tests + `ci_full` both locales.
- **Claim:** the loop is durable, gated and context-managed.

### WP6 — CLI and chat surfaces
- **Deliverables:** `tamoz code`; the router's `coding_work`; progress and finish
  rendering for terminal and comms.
- **Tests:** argument parsing; `--json` output schema-valid; a chat turn that routes to
  `work` asks for approval through the gateway; rendering bounded.
- **Claim:** operators can run coding work from the terminal and from chat.

### WP7 — Observability and trace
- **Deliverables:** catalog signals; the per-request trace written to the journal
  record; `script/context_trace` to print a session's series and cache timeline.
- **Claim:** every request's context shape and cache outcome is inspectable.

### WP8 — Evaluation, offline (EVAL.md §2–§4)
- **Deliverables:** the guarantee suite, the new agenteval packs and modifiers,
  controls, corpus validation, the trace verifier.
- **Gate:** `rake agenteval:prove` green, including the new controls discriminating.
- **Claim:** the instrument can tell a working harness from a broken one. Nothing about
  intelligence.

### WP9 — Evaluation, real model (EVAL.md §5)
- **Deliverables:** the four real runs (cache trace, capability paired, context
  fidelity, instructions), reports under `agenteval/reports/`, a findings note.
- **Claim:** only what the runs show, with intervals.

**Order:** WP0 → (WP1 ∥ WP2 ∥ WP3) → WP4 → WP5 → (WP6 ∥ WP7) → WP8 → WP9.
WP1, WP2 and WP3 touch disjoint gems and can go to parallel subagents under
`docs/subagent-orchestration.md` file-ownership contracts.

---

## 5. Out of scope

- A general shell or a sandbox (D3). A later plan, if the eval shows the allowlist is
  the binding constraint.
- Sub-agents for coding. Research M-9: only composable, read-mostly work should be
  delegated, and only with a written output contract. Revisit for a read-only
  "survey" child once the single loop is measured.
- Per-turn dynamic tool selection. It is cache-hostile (research M-1 worked example:
  6.9× cost for a 24% token cut). The surface is static per series.
- Embedding or vector retrieval. The research benches it as a primary retriever;
  grep plus structure is the baseline.
- Anthropic/Gemini native protocols. They stay refused, as today.
- Compatibility with old session databases or graph versions.

## 6. Risks

| Risk | Mitigation |
|---|---|
| DeepSeek tool-call reliability (malformed arguments, calls in text) | Schema validation with one repair message per step; count it in the trace; the eval reports the malformed-call rate. |
| Cache misses despite a stable prefix (DeepSeek matches whole persisted units, not partial prefixes) | Measure, do not assume: EVAL.md §5.1 records `prompt_cache_hit_tokens` per request and pre-registers the prediction and its falsifier. |
| Prompt injection through file contents or `AGENTS.md` | H5/H6; fixed surface; `inject` modifier cells; injection capture is a hard gate. |
| Runaway loops and cost | `LoopPolicy` budgets, the repeat guard, handoff at the budget; cost per solved task is reported. |
| Compaction invents facts (a summary strips the hedges) | Schema with "verified how"; exact-string check; `validate!`; the adversary compactor control. |
| Checkpoint growth on long turns | Refs-only surface channel; bulk in `ArtifactStore`; WP0 check. |
| Approval fatigue on many edits | Already solved by policy data: `workspace_write` is `allow` with `session` grants. The plan scope bounds it. |
| Two plans editing the session graph at once | Sequence session work with the investigation plan (README). |

## 7. Open points for the owner (not blocking WP0)

1. Should `tamoz code` also be reachable as `tamoz ask --mode code`, or only as its own command?
2. Default budgets for a work turn (proposed: 60 model calls, 120 tool calls, 30 min, and a
   token budget from the routed window).
3. The model route for summarisation: the same route (keeps the warm prefix, DSH default) or a
   cheaper one (loses the prefix). Proposed: the same route.

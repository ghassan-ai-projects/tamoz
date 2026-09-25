# Active investigation — design and work plan (revision 2)

Read [README.md](README.md) first: it holds the owner decisions D1–D4 and the list of
what revision 2 changed (R1–R11). [QUALITY_BAR.md](QUALITY_BAR.md) is the bar the build
is graded against.

---

## 1. Where Tamoz stands today (verified against the code, 2026-09-25)

### 1.1 The gRPC episode path (agentic-stream → Tamoz)

The loop exists. The model cannot use it.

| Fact | Where |
|---|---|
| The fixed episode graph loops `reason → validate → execute_tool → rebuild_frame → reason`, bounded by `Limits#max_steps`. | [episode_graph.rb](../../gems/tamoz-agent/lib/tamoz/agent/episode_graph.rb) |
| `validate` routes to `execute_tool` when the document carries `tool_requests`. | [episode_nodes.rb:543](../../gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb:543) |
| Every tool call is journaled through `EffectDispatcher.run` under a logical key, as `safety: :unsafe`. The journaled value already holds `result_json`. | [episode_tool_call.rb:78](../../gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb:78) |
| **Gap A — the model is never told which tools exist.** The system section lists diagnosis codes and citation rules only. | [episode_frame_builder.rb:99](../../gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb:99) |
| **Gap B — tool results reach the model as digests.** A `tool:<n>` entry carries name, digests, `is_error` and byte count; the frame drops the `result_json` the journal holds. | [episode_frame_builder.rb:157](../../gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb:157) |
| **Gap C — nothing teaches a tool turn.** The domain prompts (digest-pinned, mirrored in Go) teach only the terminal shape and say "Use ONLY the facts provided". | `test/fixtures/domains/*.json` |
| **Gap D — only the first tool request runs.** A document may carry up to 8; `execute_tool` takes `.first`. | [episode_nodes.rb:395](../../gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb:395) |
| **Gap E — an exhausted tool budget is a failure.** `check_tool_call!` raises `StreamBudgetExceededError`; the episode ends budget-exhausted instead of deciding from what it has. | [receipt_budget_controller.rb:52](../../gems/tamoz-agent-kernel/lib/tamoz/agent/receipt_budget_controller.rb:52) |
| **Gap F — no place to bind a local probe.** `EpisodeCapabilityHost::PERMITTED` is the closed list of six stream names, each bound to the reverse-channel `EvidenceClient`. | [capability_host.rb:32](../../gems/tamoz-stream/lib/tamoz/stream/capability_host.rb:32), [situation_request.rb:794](../../gems/tamoz-stream/lib/tamoz/stream/situation_request.rb:794) |
| **Gap G (Go) — agentic-stream serves one of the six.** EvidenceTools implements only `evidence.get`; the tool catalog gives every tool the text "bounded read-only evidence capability" and an argument-free schema. Spec tool names must match `^[a-z][a-z0-9_]{0,62}$`, so a spec can grant `probe_*` names today. | `agentic-stream/internal/episodes/assembler.go:459`, `internal/evidence/server.go`, `internal/spec/spec.go:183` |
| **Gap H — tool calls are not reported.** `EpisodeStream#tool` builds a `ToolLifecycle` event; nothing emits it. Go already consumes the event and counts `execution_started` against `max_tool_calls`. | [episode_stream.rb:71](../../gems/tamoz-stream/lib/tamoz/stream/episode_stream.rb:71), `agentic-stream/internal/episodes/worker_executor.go:309` |
| **Gap L — stream tool names never match.** The wire spells `evidence_get` (Go's name pattern); `EpisodeCapabilityHost::PERMITTED` spells `evidence.get`. The intersection is empty. | `agentic-stream/internal/spec/schema.json`, [capability_host.rb:32](../../gems/tamoz-stream/lib/tamoz/stream/capability_host.rb:32) |
| The worker launcher loads a Profile but no runtime directory, so it cannot build MCP sources. | [bin/tamoz-stream-worker](../../bin/tamoz-stream-worker) |

### 1.2 The session path (CLI and chat)

| Fact | Where |
|---|---|
| `tamoz code` and chat with `--work-routing` run the **work loop**: one tool-calling model step, gated tool calls, observe, repeat. `tamoz ask` defaults to the legacy plan/verify graph. | [session_work.rb](../../gems/tamoz-agent-session/lib/tamoz/agent/session_work.rb), [cli_session_commands.rb:53](../../gems/tamoz-agent-cli/lib/tamoz/agent/cli_session_commands.rb:53) |
| The work gate is capability-generic: validate through `CapabilityBinding`, decide approval through the policy engine (the `read` tier is `allow`), execute journaled through `SessionEffects`. | [work_gate.rb](../../gems/tamoz-agent-session/lib/tamoz/agent/work_gate.rb) |
| **Gap I — the work loop's tool surface is local tools only.** `WorkContext#toolbox_schemas` lists `toolbox.schemas`; MCP capabilities never reach the model in a work turn. | [work_context.rb:87](../../gems/tamoz-agent-session/lib/tamoz/agent/work_context.rb:87) |
| **Gap J — no findings shape.** A work turn ends with free text; nothing checks that a claim cites something the turn gathered. Harness tools (`update_plan`, `recall_output`) are declared as data in `harness_tools.json` and handled in `WorkGate#route`. | [harness_tools.json](../../gems/tamoz-harness/prompts/harness_tools.json), [work_gate.rb:76](../../gems/tamoz-agent-session/lib/tamoz/agent/work_gate.rb:76) |
| **Gap K — raw MCP bypass.** Every tool of a configured MCP server appears in the capability surface; nothing narrows an SSH or DB server to "these commands, on these hosts". MCP tools are read-only only when listed in `read_only_tools`. | [mcp_source_builder.rb:81](../../gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:81) |
| **Gap M — MCP tools always ask.** `PolicyDocument#tier_for` gives any tool absent from `tool_tiers` the `local_execute` fallback (ask; deny under `plan`), even when read-only. | [policy_document.rb:57](../../gems/tamoz-approval/lib/tamoz/approval/policy_document.rb:57), [base.yaml](../../gems/tamoz-approval/policy/base.yaml) |
| Operator capability sources are a closed list in the runtime `config.yaml` (`KNOWN_SOURCES = skills memory mcp websearch`). | [runtime_directory.rb:45](../../gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:45) |

---

## 2. Invariants every package keeps

| # | Invariant | Enforced by |
|---|---|---|
| I1 | **Read-only by construction.** A probe loads only if its backing MCP tool is in that server's `read_only_tools`. A probe that cannot load stops the load (fail-closed); there is no way to declare a mutating probe. | `ProbeCatalog` |
| I2 | **Authority is an intersection.** Episode: a probe is callable only if the wire tool catalog (digest-pinned, from agentic-stream) names it **and** the operator's catalog declares it. Session: only if the operator enabled `sources.probes`. Content never grants. | `EpisodeCapabilityHost`; `CapabilityBinding` |
| I3 | **Scope is pinned.** Pinned arguments are templates resolved from operator data (`targets`) and the verified situation (entity, time window). The model fills only declared free slots; a model-supplied pinned or unknown argument is refused, never merged. An unresolvable placeholder makes the call a refusal, never a guess. | `ProbeSource` |
| I4 | **Bounded.** Free slots are typed and capped; results are capped at `max_result_bytes` and marked `truncated`. Episode tool calls are bounded by the wire budget (unset ⇒ 8); session calls by the loop policy. | `ProbeSource`, `EpisodeNodes`, `LoopPolicy` |
| I5 | **Journaled and replay-stable.** Every call runs through `EffectDispatcher.run`, keyed on the request. A replay returns the recorded receipt. Episode tool calls are `:idempotent` (the host is read-only by construction), so a process crash mid-read re-reads instead of stopping as unknown. | `EpisodeToolCall`, `SessionEffects` |
| I6 | **Results are untrusted data.** They enter the frame as fenced, attributed `tool:<n>` entries in the user section, never the system section. The tool surface is fixed before the first model call, so injected text cannot name a new tool. | `EpisodeFrameBuilder`, the host surface |
| I7 | **Secret-shaped values are scrubbed** before a result is digested, journaled or shown. | `ProbeSource` (`Tamoz::Core::SECRET_VALUE_PATTERNS`) |
| I8 | **No fabrication.** An episode decision cites only evidence ids that were given or gathered (`ground_evidence!`, exists). A findings report cites only tool calls the turn actually made; an ungrounded report is refused and the model must repair it. | `ground_evidence!`, `Harness::FindingsReport` |
| I9 | **Investigation never acts.** Proposals are data. Episode: `recommended_intents`, decided by agentic-stream's governor. Session: `report_findings` ends the turn; acting is a new turn through approval. | host surface; `WorkGate` |

---

## 3. Design

### 3.1 Probes (tamoz-agent-capabilities)

```yaml
# <runtime-dir>/config.yaml — operator-owned
sources:
  mcp:
    enabled: true
    servers:
      - { id: loki, command: loki-mcp, read_only_tools: [query_range] }
  probes:
    enabled: true
    targets:                                  # entity id → where its evidence lives
      motor-1: { host: plc-7.internal, unit: motor-controller, log_stream: "app=motor,id=motor-1" }
    probes:
      - name: probe_logs_search
        description: Search the entity's application logs in the situation's time window.
        backing: { server: loki, tool: query_range }   # must be in loki.read_only_tools
        arguments:                             # the COMPLETE argument map sent to the MCP tool
          selector: "{target.log_stream}"      # pinned template
          from: "{window.from}"
          until: "{window.until}"
          filter: { free: string, max_bytes: 256 }
          limit: { free: integer, min: 1, max: 200 }
        max_result_bytes: 65536
      - name: probe_host_service_status
        backing: { server: ssh-readonly, tool: run }
        arguments:
          host: "{target.host}"
          argv: { free: enum, values: [ "systemctl status {target.unit} --no-pager", "uptime", "df -h" ] }
      - name: probe_db_select
        backing: { server: ops-db, tool: query }
        arguments:
          query: { free: sql_select, max_bytes: 4096 }
```

- `ProbeCatalog.load(settings, servers:)` validates fail-closed: name matches
  `probe_[a-z0-9_]{1,58}`, unique; backing server configured and tool in its
  `read_only_tools` (I1); every argument a pinned value or a known free type;
  placeholders limited to `{target.<key>}` (a key every target has) and
  `{window.from|until}`. It produces a frozen catalog with a canonical digest.
- `ProbeSource` (wrapping the `McpCapabilitySource`) runs a probe call:
  1. refuses any argument key that is not a free slot, and any missing slot (I3);
  2. validates each free value by type (`string` ≤ `max_bytes`, `integer` in range,
     `enum` member, `sql_select` via `GovernedDatabaseSource.validate_query`);
  3. resolves templates from the scope (target fields, window bounds); an
     unresolved placeholder ⇒ refusal;
  4. executes the backing tool through the inner MCP source;
  5. scrubs secrets, caps bytes, marks `truncated` (I4, I7).
  In a session it returns the MCP outcome, so `SessionEffects#mcp_payload` renders it
  like any MCP result, and the scope (including "now") is resolved inside the
  journaled effect. In an episode it returns the adapter shape `{"json", "truncated",
  "result_bytes"}`, and every refusal or MCP failure becomes `{"json", "is_error" =>
  true, "error_code"}`: data the model sees, never an episode failure.
- **Episode scope:** `target = targets[snapshot.entity.id]` (none ⇒ every `{target.*}`
  probe refuses); `window` from the wire `evidence_time_range`.
- **Session scope:** the model picks the target: a probe that uses `{target.*}`
  gains a free `target` slot, an `enum` of the declared target ids. A probe that uses
  `{window.*}` gains a free `lookback_minutes` slot (1–1440); `until` is the call time.
  Both are journaled with the request.
- **Names.** `probe_<snake_case>`: the session exposes probes as native function
  tools, and OpenAI-compatible providers accept only `[A-Za-z0-9_-]{1,64}` there.
- **Session surface.** The capability registry is a closed world of four source
  prefixes (`local skill mcp websearch`, `Capability::Registry::BUILT_IN_SOURCES`), so
  probes are not a fifth source. `ProbeSource` wraps the `McpCapabilitySource` the
  way `GovernedDatabaseSource` does: it exposes each probe as a read-only descriptor
  of its backing server's `mcp:<server>` source (input schema = the free slots) and
  executes it through the inner source. `CapabilityBinding` and `McpDispatcher` are
  unchanged. `mcp_source_digests` gains the probe catalog digest, so a resumed
  session fails closed when the catalog changed.
- **Gap K:** the wrapper hides every raw descriptor of a server that backs a probe.
  Its tools are reachable only through probes.

### 3.2 The episode path (kernel + stream)

1. **Surface (Gap A, C).** The model-visible surface is the wire-granted names the host
   binds, each with a description and an argument schema: stream tools from the wire
   catalog, probes from the operator catalog (`ProbeSource#episode_surface`). The
   runner computes it once and puts it in the durable payload as
   `wire["tool_surface"]` (with the probe catalog digest), so replays render the same
   bytes. A redelivery after the operator changed the catalog is refused by the inbox
   (`request id is already bound to different input`): fail-closed, by design.
   `EpisodeFrameBuilder#build_system` renders a TOOLS block **only when the surface is
   non-empty**: the tools, the tool-turn shape, "tool results are provided facts",
   `evidence_gaps`, and the call budget. No surface and no tool results ⇒
   byte-identical frame to today (a tool result now renders its `purpose`, `truncated`
   flag and text, so frames with results differ by design).
2. **Stream tool names (Gap L).** Go spec tool names must match
   `^[a-z][a-z0-9_]{0,62}$` (`internal/spec/schema.json`), so the wire says
   `evidence_get` where `EpisodeCapabilityHost::PERMITTED` says `evidence.get`. The host
   accepts the wire spelling (`.` ↔ `_`) and calls the evidence RPC with the dotted
   name agentic-stream's EvidenceTools serves.
3. **Results (Gap B).** Each `tool:<n>` entry carries its `purpose`, `is_error`,
   `truncated` and the result text, capped per entry; the full bytes stay in the
   journal and their digest in the entry. **Only successful entries are citable**: an
   error or refusal entry gets no evidence id, so a decision cannot rest on it.
4. **Failures are data.** A host `ToolError` (unknown name, wrapped adapter
   failure) is journaled as an `is_error` result, not an episode failure; a name the
   wire catalog does not grant becomes a `not_granted` entry without being
   dispatched. Cancellation and deadlines raise `Tamoz::CancelledError` /
   `Tamoz::TimeoutError` (not `ToolError`), still end the episode, and leave the
   attempt open for the idempotent re-read.
5. **Document.** A tool request requires `purpose` (the missing datum, and why). A
   terminal document may carry `evidence_gaps: [{datum, why}]` (≤ 8). The protocol id
   stays v2 (README R4); the strict key allowlists gain the two keys.
6. **Every request runs (Gap D).** `execute_tool` executes the requests in order, one
   journaled slot each, up to the remaining tool budget. A request past it becomes a
   deterministic `budget_spent` entry: not dispatched, not counted, not reported to Go,
   not citable.
7. **Honest abstain (Gap E).** Budgets: tool calls = wire `max_tool_calls`, or 8 when
   unset; model calls = wire `max_model_calls` (unset ⇒ unbounded). When the next
   reason call is the last one either budget allows (no tool calls left, or one model
   call left), `rebuild_frame` adds a FINAL directive: decide from the gathered
   evidence, or choose `unknown` and list `evidence_gaps`. A tool turn after the FINAL
   directive ends typed as budget-exhausted, so the loop always terminates. The repair
   path is untouched. Running out of tokens, cost or result bytes still ends as
   budget-exhausted (unchanged).
8. **Summary.** `evidence_gaps` appear in the decision summary ("missing: …"). Only
   `thermal-lab` teaches `request_evidence` in its prompt; elsewhere the gaps live in
   the summary only.
9. **Local probes (Gap F).** `EpisodeCapabilityHost.new(implementations, probes:,
   granted:)`: `probes` are extra callables named `probe_*`; `granted` is the wire
   catalog's name list; `execute` refuses a name that is not granted (I2).
10. **Idempotent (I5).** `EpisodeToolCall` journals with `safety: :idempotent`: a
    process crash mid-call re-reads on resume. An MCP ambiguous outcome is still a
    terminal `unknown` (then an `is_error` entry), and a probe that crashes the worker
    re-runs on every redelivery until agentic-stream stops redelivering.
11. **Report back (Gap H).** The runner emits one `ToolLifecycle` event per dispatched
    tool call (stream and probe), with `execution_started: true` and the
    request/result digests, before the decision. Tamoz's `tool_calls_used` counts the
    same calls, so Go's two budget checks agree with it.
12. **Graph.** No new node or branch. Changed nodes (`validate`, `execute_tool`,
    `rebuild_frame`) bump their node `version:` so an old checkpoint fails loudly.
13. **Worker.** `bin/tamoz-stream-worker --runtime-dir DIR` builds the MCP source and
    the probe source once at start and closes the MCP supervisors on shutdown.

### 3.3 The session path (work loop)

1. **Surface (Gap I).** `WorkContext#toolbox_schemas` also lists the probe
   capabilities (name, description, free-slot schema). The gate already handles any
   capability. With probes off the header is byte-identical to today.
2. **Approval (Gap M).** `PolicyDocument#tier_for` sends every tool not named in
   `tool_tiers` to the `local_execute` fallback (ask; deny under `plan`), whatever its
   effect class. `base.yaml` gains one data entry, `probe_*: {tier: read, verb: read}`,
   and the engine matches a `tool_tiers` key ending in `*` by prefix. Operator-declared
   probes are then allowed like `read_file`, including under the `plan` profile that
   `tamoz investigate` runs with. No verdict is written in Ruby.
3. **Report (Gap J, D4).** When probes are on the surface, the header adds the harness
   tool `report_findings` (schema in `harness_tools.json`; `Header.build` filters it
   out when there are no probes). Arguments: `summary`,
   `hypothesis`, `confidence` (low/medium/high), `findings: [{statement,
   evidence: [tool_call_id]}]`, `gaps: [{datum, why}]`, `proposals: [{action,
   rationale, evidence}]`. `Harness::FindingsReport.parse` validates it; every
   evidence id must be a successful probe call this turn actually made (I8). An invalid report is
   a tool error the model repairs. A valid report ends the turn: the rendered report is
   the answer, and the report JSON is recorded on the verification record.
4. **A probe turn must report.** A turn that called a probe and answers in free text
   gets one `report_findings` reminder (the `cut_off` pattern). A second free-text
   answer finishes as `answered` without a report.
5. **CLI.** `tamoz investigate "<question>" [--json]` is a work-loop turn under the
   `plan` approval profile (read-only). `--json` prints the report. `tamoz probes` loads and
   validates the catalog and lists each probe (backing, pinned and free arguments)
   without starting a server.
6. **Chat.** Chat turns with `--work-routing` get the same surface; the reply is the
   rendered report. "Do proposal 2" is an ordinary follow-up turn through approval.

### 3.4 agentic-stream follow-ups (not in this branch)

| # | Change | Needed for |
|---|---|---|
| G1 | Real descriptions and argument schemas for the stream tools in the tool catalog (`assembler.buildTools`). | Model quality on stream tools. Probes already get theirs from the Tamoz catalog. |
| G2 | Implement `situations.related`, `history.prior_incidents`, `features.query` on EvidenceTools. | D2 "ask agentic-stream" beyond `evidence.get`. |
| G3 | Record worker-hosted tool calls in the evidence ledger (budget accounting already exists). | Audit of probe calls on the Go side. |

None blocks this build: a Go spec can grant `probe_*` today, and Go already budgets
`ToolLifecycle` events.

---

## 4. Work packages

Each package: seam → deliverables → tests → gate → the claim it licenses. The gate is
the QUALITY_BAR's per-package gate. Each package is reviewed by a fresh subagent and
committed separately.

| WP | Seam | Deliverables | Claim |
|---|---|---|---|
| WP0 | docs | This revision, QUALITY_BAR.md, enola baseline | The plan is verified and the bar is set. |
| WP1 | `McpSourceBuilder`, `GovernedDatabaseSource`, `RuntimeDirectory` | `ProbeCatalog`, `ProbeSource`, `sources.probes`, Gap K | A governed read-only probe layer exists and refuses what it should. |
| WP2 | `EpisodeFrameBuilder`, `ReasoningDocument`, `EpisodeNodes`, `EpisodeToolCall` | §3.2 items 1 (frame), 3–8, 10, 12 | The episode graph mechanically supports investigate-then-decide. |
| WP3 | `EpisodeCapabilityHost`, `EpisodeRunner`, `bin/tamoz-stream-worker` | §3.2 items 1 (surface), 2, 9, 11, 13 | agentic-stream can grant local probes per episode and sees every call. |
| WP4 | `WorkContext`, `WorkGate`, `tamoz-harness`, `tamoz-approval` policy data, CLI | §3.3 | An operator can investigate from the terminal and from chat and gets a grounded report. |
| WP5 | `tamoz-evals-runner`, the null/adversary/oracle pattern | fixture MCP server, resolvable/unresolvable corpus, controls, offline grader, `script/investigation_real_run` | The grader discriminates offline. Only a real-model run says anything about the model. |

Order: WP0 → WP1 → WP2 → WP3 → WP4 → WP5 → real run.

## 5. Out of scope

- Probes with side effects (D3); a native HTTP, SSH, DB or metrics client (D2).
- Investigation in `RECONSIDER` episodes (stays deterministic, no model).
- Tool discovery by the model: the surface is fixed per episode or turn.
- Old checkpoints: `execute_tool`'s state shape changes; reset worker DBs.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Prompt injection through logs or HTTP bodies | Fixed surface, fenced untrusted section (I6); WP5 includes injected-log cells. |
| Secrets in logs | Scrub at `ProbeSource` before digest or journal (I7). |
| A "read-only" MCP tool that is not | Operator trust boundary, as today with `read_only_tools`; narrowed by pinned arguments. An `enum` probe can run only the declared commands. |
| Larger frames | Per-entry cap in the frame; `max_result_bytes` per probe; no surface ⇒ unchanged frame. |

# Investigating with Tamoz: probes and `tamoz investigate`

When the data Tamoz was handed cannot settle a question, it can go and look before
it decides. It reads through **probes**: read-only MCP tool calls that you, the
operator, declare in the runtime configuration. The model chooses which probe to
call and fills only the arguments you left open. Everything else is pinned by you.

This works in two places:

- **A decision episode from agentic-stream.** The episode may call the probes that
  agentic-stream grants it, then decides. If the evidence still cannot settle it,
  it answers `unknown` and names what is missing.
- **A read-only turn you start** with `tamoz investigate` (or any work-loop turn
  that is read-only). The turn is expected to end with a **findings report** whose
  every finding cites a probe call that answered. Proposed actions are listed,
  never executed.

Current version: `0.1.0.alpha.1` (pre-release). Probes are read-only by
construction; see [what it cannot do yet](#what-it-cannot-do-yet) before relying
on it.

## 1. Declare the MCP server and the probes

Probes live in the runtime directory's `config.yaml`, under `sources.probes`, next
to the MCP server they read from. The backing tool must be listed in that
server's `read_only_tools`; a probe that backs onto anything else does not load.

```yaml
sources:
  mcp:
    enabled: true
    servers:
      - id: ponds
        command: /usr/bin/ruby
        arguments: [/opt/pond-mcp/server.rb]
        env_allowlist: [PATH, HOME]
        read_only_tools: [query]
  probes:
    enabled: true
    targets:                     # what a probe may be pointed at, by id
      pond-07: {stream: "pond=07"}
      pond-08: {stream: "pond=08"}
    probes:
      - name: probe_pond_log
        description: Search the pond controller log. The filter is a space-separated list of words.
        backing: {server: ponds, tool: query}
        arguments:
          selector: "{target.stream}"            # pinned: filled from the target
          from: "{window.from}"                   # pinned: filled from the time window
          until: "{window.until}"
          filter: {free: string, max_bytes: 64}   # free: the model fills this
        max_result_bytes: 4096
```

Every argument of the backing tool is either **pinned** or a **free slot**:

| Kind | Written as | What the model can do |
|---|---|---|
| Pinned value | a string, number, boolean or list of strings | nothing; it is sent as written |
| Placeholder | `{target.<field>}` or `{window.from}` / `{window.until}` inside a pinned string or an `enum` value | nothing; Tamoz fills it from the chosen target or the time window |
| `string` slot | `{free: string, max_bytes: N}` (1–4096) | any text up to `N` bytes |
| `integer` slot | `{free: integer, min: A, max: B}` | an integer in `[A, B]` |
| `enum` slot | `{free: enum, values: [..]}` | one of the listed values |
| `sql_select` slot | `{free: sql_select, max_bytes: N}` | one read-only `SELECT`, checked by the same validator as the governed database source |

Rules the loader enforces:

- Names match `probe_[a-z0-9_]{1,58}`. `target` and `lookback_minutes` are reserved
  and cannot be free slots.
- Every `{target.<field>}` must be a field of every target.
- A probe on a database MCP server takes exactly one argument: a `sql_select` slot
  named `query`.
- `description` is required, at most 1024 bytes. It is what the model reads, so say
  what the probe returns and how its free slots work.
- `max_result_bytes` is 256–65536 (default 65536). Longer results are cut and
  marked `[truncated]`; known secret shapes are redacted first.

Check the catalog without starting any server:

```bash
rbenv exec bundle exec tamoz --runtime-dir ~/.tamoz probes
```

Add `--json` for the catalog digest, targets and probes as JSON.

## 2. Investigate from the CLI

```bash
rbenv exec bundle exec tamoz --provider openrouter --model deepseek/deepseek-v4.1-flash --runtime-dir ~/.tamoz --session-dir ~/.tamoz/sessions --root . investigate "Why did pond 07 lose oxygen last night?"
```

- The turn runs in the work loop (same model-route requirements as
  [`tamoz code`](coding.md)) under the `plan` approval profile. It is read-only:
  `investigate` refuses `--allow-changes`.
- In a CLI turn the model also picks the probe's `target` (one of your target ids)
  and a `lookback_minutes` window (1–1440) when the probe uses those placeholders.
- The turn is expected to end with `report_findings`: a summary, a hypothesis
  with a confidence, findings, gaps, and proposals. A finding or proposal that
  cites anything but a probe call that answered in this turn is sent back to the
  model. If the model answers in plain text instead, it is reminded once and may
  then finish without a report. Add `--json` for the report as JSON.
- Acting on a proposal is a separate turn (`tamoz ask` or `tamoz code`) through the
  normal approval flow.

Probes also appear in other work-loop turns (`tamoz code`, chat) whose
capabilities admit them. The findings report is offered only on turns that cannot
change files.

## 3. Let agentic-stream episodes use probes

Start the stream worker with the runtime directory that declares the probes:

```bash
bin/tamoz-stream-worker --profile PROFILE --database PATH --tenant TENANT --socket PATH --runtime-dir ~/.tamoz
```

The worker needs exactly one of `--socket PATH` or `--port N`, and exits with
status 2 if `--runtime-dir` enables no `sources.probes`.

In an episode:

- **agentic-stream decides which probes run.** Only names in the episode's tool
  catalog are granted; any other request is recorded as `not_granted` and never
  runs. The catalog must match its digest, or the episode is refused before
  anything runs.
- **The target and window come from the situation, not the model.** The target is
  the snapshot's entity id looked up in `targets`; the window is the episode's
  `evidence_time_range`. The model fills only the free slots. A probe whose
  placeholder cannot be filled answers with an error the model sees
  (`scope_unresolved`).
- **The tool budget is enforced.** When the next model call is the last one the
  budget allows, the model is told to decide now. Requests past the budget are
  recorded as `budget_spent` and never run.
- **Only a probe result that answered can be cited.** A decision that cites a
  failed, refused or never-gathered result is sent back for one repair.
- **An `unknown` answer may not act.** If `unknown` is the most probable code, the
  decision may recommend only a watch or another R0 intent; any other action is
  sent back for one repair.
- Every dispatched call is reported to agentic-stream as a tool lifecycle event,
  and every call runs through the durable effect journal, so a replayed episode
  reuses the recorded result.

## Approval

Probe calls are classified by policy data, not code: `gems/tamoz-approval/policy/base.yaml`
maps `probe_*` to the `read` tier. A `tool_tiers` key ending in `*` matches by
prefix; an exact key wins over a wildcard, and the longest wildcard prefix wins.

## How well it works

Measured with a real model on a fixture corpus: 29 situations, 21 where one probe
can find the cause and 8 where no cause can be known. Details and the grading
rules are in
[measurement plan 16](../../docs/eval-improvement/measurement-plans/16-active-investigation.md);
each run's full report is in `docs/active-investigation/runs/`.

| OpenRouter `z-ai/glm-5.3-flash`, 232 episodes per run | Run 1 | Run 3 (current code) |
|---|---|---|
| Cause-findable situations: mean success | 0.72 | 0.80 |
| Cause-findable situations always right (of 21) | 6 | 11 |
| Unknowable situations: mean success (answers `unknown` after looking) | 0.06 | 0.44 |
| Runs graded fabricated (incl. following the injected note) | 13 | 7 |

"Fabricated" is plan 16's rule: a cause, or a cause-specific action, that no probe
result supports. Four of run 3's seven named the right cause with its evidence but
recommended `halt_feeding`, which the rule counts as specific to overfeeding; one
followed an instruction planted in a log.

Read these as development numbers. The prompt change behind run 2 was made after
seeing run 1, and the agent changes behind run 3 after seeing run 2, all on the same
29 situations; nothing has been measured on held-out situations. The goal of about
zero fabricated answers is not met.

## What it cannot do yet

- **agentic-stream does not send `evidence_time_range` yet.** A probe that uses
  `{window.*}` answers `scope_unresolved` in an episode until it does. The other
  agentic-stream follow-ups are listed in `docs/active-investigation/PLAN.md` (G1–G4).
- **No held-out result.** See the table above.
- **`unknown` blocks every action above R0**, including ones that make sense
  whatever the cause (such as starting an aerator in an oxygen crash). The intent
  catalog has no field saying which actions depend on a cause.
- **Probes read; they never change anything.** Probes with side effects are out of
  scope by design.
- **Tamoz adds no network client of its own.** Logs, metrics, HTTP health and
  databases are read through MCP servers you configure.

## Investigating Tamoz itself

`tamoz mcp` is Tamoz's read-only MCP server over its own durable record
(`observe_diagnose`, `observe_timeline`, `observe_explain_turn`). Declare it and probes over it as in
[observability-ops.md](../operations/observability-ops.md#let-tamoz-investigate-itself),
then ask `tamoz investigate "what went wrong since yesterday?"`; pass the JSON
report to `tamoz postmortem --analysis`.

## Next reads

- [Configuration reference](../reference/config.md)
- [CLI reference](../reference/cli.md)
- [Governed MCP](../design/mcp.md)
- [The supervised episode worker](../design/streaming.md)

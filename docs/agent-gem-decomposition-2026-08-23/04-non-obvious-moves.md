# 04 — Non-obvious moves (mostly _into existing gems_)

The four vertical gems in [01](01-target-topology.md) are the obvious cut: they
are named subsystems. This document is the other half of the answer — code that
sits in `tamoz-agent` but whose _domain_ belongs to a sibling gem that already
exists, or to a small new gem that isolates a dependency. These are found by
following the dependency arrows outward, not by directory name.

Each entry below was checked for the one thing that decides it: **does the file
reach back into agent internals, or only into the sibling domain?**

## A. Comms delivery runtime → `tamoz-comms` (highest-value non-obvious move)

| File | Lines | What it is |
|------|------:|-----------|
| `comms_gateway.rb` | 459 | The only long-running process that talks to the transport: admits inbound updates, records disposition, drains the outbox. |
| `outbox_delivery_sink.rb` | 193 | Projects worker lifecycle events into durable Delivery rows via `CommsStore`. |
| `delivery_drainer.rb` | 144 | Drains durable outbound rows: claims, pacing, receipts. |

~**796 lines**. All three `require "tamoz/comms"` and operate purely on the
`CommsStore` / transport contract. `comms_gateway`'s own header states it
**"NEVER constructs a Session, loads a model credential, opens a toolbox, or
reads workspace files"** — and the check confirms it: the single `Session`
mention in the trio is that comment. They have no agent-internal coupling at all.

They live in `tamoz-agent` for historical reasons; their domain is comms. Move
them to **`tamoz-comms`** (which already owns `CommsStore` and the transport
contract). `tamoz-agent` already depends on `tamoz-comms`, so the worker/CLI
keep constructing them unchanged. This is the cleanest large move outside the
obvious four.

## B. `DurableRecorder` → `tamoz-observability`

`durable_recorder.rb` (34 lines) is a `Recorder` decorator: it forces a flush
boundary after a successful `record`. It wraps `@recorder` and knows nothing
about the agent. It belongs next to the `Recorder` contract in
**`tamoz-observability`**. Consumers: `cli_worker_commands` + one evals test —
both already depend on observability.

## C. `RawHttp` → `tamoz-core`

`raw_http.rb` (32 lines) is "the minimal raw-HTTP framing shared by the witness
gateway (lib) and the local model endpoint (test support) — ONE read path and
ONE write path." It is a generic utility with no agent domain, deliberately
shared to stop two servers drifting. It belongs in **`tamoz-core`** so any gem
(and test support) can share the one framing. Consumers today: `witness_gateway`
(kernel) and `test/support/local_model_endpoint`.

## D. `Plan.{deep_freeze, parse_object, string}` → `tamoz-core`

Already argued in [02, Knot 1](02-shared-kernel.md#knot-1--plan-is-a-value-type-doing-utility-work):
these three helpers on the `Plan` value type are the codebase's JSON/freeze
utilities, used by `MemoryRecord`, `Consolidation`, and others that have nothing
to do with plans. Move the helpers to `tamoz-core`; leave the `Plan` domain type
in the kernel. Listed here too because it is the same _kind_ of move — utility
code wearing a domain hat.

## E. `RubyLLMModel` → a small `tamoz-model` gem (isolates the `ruby_llm` dep)

`ruby_llm ~> 1.16.0` is declared on `tamoz-agent.gemspec` and is used by exactly
**one** file: `ruby_llm_model.rb` (123 lines), the provider adapter. Everything
else that touches models uses the kernel's `EpisodeModelTransport` (a
digest-bound, `net/http`-only wire client that deliberately does **not** use
RubyLLM — see its header).

So the whole agent carries a heavy external gem for a single 123-line adapter.
Extracting `RubyLLMModel` (plus the `ENV_KEYS` provider table) into a small
**`tamoz-model`** gem — or into `tamoz-tools` if a new gem isn't wanted — pulls
`ruby_llm` off `tamoz-agent`'s dependency surface and makes the provider layer
swappable. Note the coupling to watch: `profile.rb` and `cli.rb` reference
`RubyLLMModel` (provider/model validation), and the evals benchmark adapter uses
`RubyLLMModel::ENV_KEYS` — so `tamoz-model` sits _below_ profile and the CLI.

`EpisodeModelTransport` stays in the kernel: it is the replayable episode path,
not a provider adapter.

## F. Governed capability sources — the MCP bridge (medium, evaluate)

| File | Lines | Note |
|------|------:|------|
| `mcp_source_builder.rb` | 276 | Builds the governed MCP source from operator config; references `Tamoz::Mcp` 16× **and** agent `Tool*` errors + `Session`. |
| `governed_database_source.rb` | 96 | Read-first SQL governance over an MCP source. |
| `governed_browser_source.rb` | 168 | URL/output/approval governance over a browser adapter. |
| `mcp_capability_source.rb` | 263 | **Intentionally agent-side**: its header states tamoz-agent holds *no* hard dependency on tamoz-mcp — everything is duck-typed. |

This ~800-line group is the **agent ↔ MCP bridge**. It is genuinely two-sided:
`mcp_source_builder` names both `Tamoz::Mcp::Catalog` and the agent's tool-error
taxonomy, so it cannot simply move into `tamoz-mcp` without dragging the agent's
tool contract along. `mcp_capability_source` is deliberately kept duck-typed to
_avoid_ the dependency and should stay agent-side.

Recommendation: do **not** force this into `tamoz-mcp`. If it is worth isolating,
make it a thin **`tamoz-mcp-agent` bridge gem** depending on both `tamoz-mcp` and
`tamoz-agent-kernel` (for the tool taxonomy). Lower priority than A–E; flag it,
don't rush it.

## G. Layering smell to fix (not a move): Telegram named in the CLI

`cli_comms_shared.rb` is the only file under `tamoz-agent` that references
`Tamoz::Telegram` directly (3×). The agent CLI hard-coding a _concrete transport_
is a layering inversion — transport specifics should sit behind the
`tamoz-comms` abstraction, so adding a second transport doesn't touch the agent.
This is a refactor (route through a transport-neutral seam in `tamoz-comms`), not
an extraction. Worth doing when the comms trio (A) moves, since they're the
natural home for the transport-specific bits.

## H. Stale upward references — fix the names, no code moves

Not misplaced _code_, but misplaced _names_: three sibling gems hard-code the
`Tamoz::Agent::…` spelling for things that actually live below the agent (or in a
peer). These are string/comment references, so there is no gem cycle — but they
encode the wrong ownership and will mislead the next reader.

- **`tamoz-core`** carries a serialization name map,
  `"Tamoz::Core::ToolError" => "Tamoz::Agent::ToolError"` (+ the argument/policy
  variants), plus a comment in `tool_error.rb`. The tool-error taxonomy is
  _defined_ in `tamoz-core`/`tamoz-tools`; the agent only rebinds the constants.
  Core pointing back at the agent's public spelling is backwards. Decide the one
  canonical public spelling (almost certainly `Tamoz::Tools::*`) and make the map
  and every consumer name it.
- **`tamoz-tools`** raises errors whose _messages_ read
  `"must be a Tamoz::Agent::Skills::SkillSnapshot"` — but the class is
  `Tamoz::Tools::Skills::SkillSnapshot` (the agent rebinds it). The messages
  should name the defining gem.
- **`tamoz-mcp`** comments reference `Tamoz::Agent::Toolbox` / `Tamoz::Agent::Profile`
  for things whose real homes are `tamoz-tools` (Toolbox) and the agent's own
  config wiring (Profile).

None of these block extraction; they are cheap Stage-B cleanups that stop the
wrong ownership from spreading. They matter more _after_ the tools/profile
boundaries harden, because that is when the canonical spelling is decided.

## Priority summary

| Move | Destination | Size | Confidence | Why non-obvious |
|------|-------------|-----:|-----------|-----------------|
| A. comms gateway / sink / drainer | `tamoz-comms` | ~796 | **High** — verified no agent coupling | Named `Agent`, but pure comms runtime |
| B. `DurableRecorder` | `tamoz-observability` | 34 | **High** | Tiny decorator lost in the runtime |
| C. `RawHttp` | `tamoz-core` | 32 | **High** | Generic util shared lib+test |
| D. `Plan` helpers | `tamoz-core` | small | **High** | Utility wearing a domain type's name |
| E. `RubyLLMModel` | new `tamoz-model` (or `tamoz-tools`) | 123 | **Med-High** | One file justifies the whole `ruby_llm` dep |
| F. governed sources / MCP builder | new `tamoz-mcp-agent` bridge | ~800 | **Medium** | Two-sided bridge; don't force into `tamoz-mcp` |
| G. Telegram in CLI | fix seam in `tamoz-comms` | — | **Medium** | Concrete transport named in the agent |
| H. Stale `Tamoz::Agent::*` names in core/tools/mcp | fix names in place | — | **Low (cheap)** | Wrong ownership encoded in strings/comments |

A–D are low-risk wins that shrink `tamoz-agent`'s surface and dependency set
before the big vertical extractions even begin — and, like every phase in
[03](03-sequencing-risks-namespace.md), each is _move then simplify_: e.g. after
the comms trio lands in `tamoz-comms`, fold the Telegram seam (G) in as its
Stage B.

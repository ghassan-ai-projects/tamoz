# Candidate assessments

## Decision matrix

| Rank | Candidate gem | Responsibility moved | Evidence | Payoff | Confidence |
|---:|---|---|---|---|---|
| 1 | `tamoz-mcp-websearch` | Governed websearch egress adapter | Four-file, 922-line named capability; separate operator require; parent MCP entrypoint does not load it | Turns a comment-enforced adapter boundary into a gem boundary | High |
| 2 | `tamoz-evals-runner` | Scenario harness and benchmarks | Harness and benchmark code are about 92% of `tamoz-evals`; verifier is independently coherent and currently eager-loads the runtime | Makes artifact verification light and fixes runner package-truth | High |
| 3 | `tamoz-mcp-agent` | MCP-dependent capability source/builder bridge | 882-line MCP integration cluster is the only agent-capability portion that needs MCP; source protocol is intentionally duck-typed | Removes MCP SDK/host coupling from the capability catalog package | Medium; design spike |
| 4 | `tamoz-comms-gateway` | Long-running inbound gateway and delivery drainer | Gateway (917 lines) and drainer (164) own edge lifecycle, claims, pacing and ambiguous outcomes | Makes the credential-bearing process boundary explicit | Medium-high; conditional |
| — | `tamoz-stream-sse` | HTTP/SSE Channel B transport | One 259-line adapter is parent-eager but has no production consumer visible in-tree | Optionalizes a network adapter; load payoff is real but deployment payoff is unproven | Low-medium; verify first |
| — | `tamoz-agent-ruby-llm` | RubyLLM model/provider adapter | One 113-line adapter and generic injected model protocol | Removes provider SDK from base agent package | Deferred until provider/profile/evals composition is untangled |
| — | `tamoz-tools-skills` | Agent Skills compiler/catalog | 7 files, 1,067 lines and coherent security responsibility | No payoff until `tamoz-tools` consumes an optional skills package | Deferred |

## `tamoz-stream-sse` — conditional optionalization candidate

### What moves

Move `gems/tamoz-stream/lib/tamoz/stream/sse_transport.rb` to a new
`tamoz-stream-sse` gem. It contains `SseTransport`, its `Parser`, the frame
shape, reconnection policy, HTTP request construction, credential validation,
and bounded frame parsing (259 lines, 34 extracted symbols).

### Source evidence

- [`tamoz/stream.rb`](../../gems/tamoz-stream/lib/tamoz/stream.rb:8-16) eagerly
  requires `sse_transport` as part of the stream umbrella.
- [`sse_transport.rb`](../../gems/tamoz-stream/lib/tamoz/stream/sse_transport.rb:3-8)
  requires `net/http`, `uri`, stream errors and `OutcomeSubscriber`.
- `OutcomeSubscriber` documents the transport contract at
  [`outcome_subscriber.rb`](../../gems/tamoz-stream/lib/tamoz/stream/outcome_subscriber.rb:65-70):
  `open(cursor:, credential:)` returns frames and `resnapshot` returns a
  cursor. That is a clean consumer-facing seam.
- A repository-wide production search found no `SseTransport` reference outside
  its definition; the direct require and constructor usage are in
  `test/stream_sse_transport_test.rb`. Test-only use is not a reason to delete
  the code; it is evidence that the class is an independently addressable
  adapter rather than part of the EpisodeWorker core.
- [`tamoz-sqlite.rb`](../../gems/tamoz-sqlite/lib/tamoz/sqlite.rb:3-8) requires
  `tamoz/stream`, so the eager SSE import contaminates SQLite's load graph even
  when no SSE subscriber is configured.

### Target topology

`tamoz-stream-sse` depends on `tamoz-stream` and owns the existing
`Tamoz::Stream::SseTransport` namespace. `tamoz-stream` retains
`OutcomeSubscriber` and its structural transport protocol, but no longer
requires the SSE adapter. The parent must not depend back on the new gem.

### Payoff and risk

The immediate payoff is load isolation: a normal stream or SQLite boot no
longer loads the SSE adapter for an unused transport. The dependency also becomes
honest: an application that wants a live SSE network connection explicitly
installs the network-capable gem.

The risk is protocol drift. The move must preserve frame fields, cursor
advancement, resnapshot semantics, retry classification, bounded body parsing,
credential handling, and `TransportError` identity. The target gem must be
tested against the parent `OutcomeSubscriber` contract, not by copying the
subscriber into the adapter.

## `tamoz-mcp-websearch` — package the existing adapter boundary

### What moves

Move `websearch.rb` plus `websearch/egress_policy.rb`,
`websearch/egress_client.rb`, and `websearch/egress_circuit.rb` (922 Ruby
lines across four files) into a new gem.

### Source evidence

- [`tamoz/mcp.rb`](../../gems/tamoz-mcp/lib/tamoz/mcp.rb:9-20) requires the
  MCP client/host files and does not require websearch.
- The websearch wrapper explicitly states the reason at
  [`websearch.rb`](../../gems/tamoz-mcp-websearch/lib/tamoz/mcp/websearch.rb:3-10): the
  dialer and HTTP stack are operator-side and socket-capable.
- [`script/websearch_adapter`](../../script/websearch_adapter:38-42) is the
  operator executable that requires the websearch path. The eval harness and
  dedicated websearch tests are the other direct consumers.
- The implementation owns one named security responsibility: policy
  validation, per-hop resolve/classify/pin/dial, redirect and byte bounds,
  credential-shaped query/result hygiene, and operator-evidence circuit reset.
- Its narrow parent coupling is to MCP error/config/canonical contracts; it
  does not own `Supervisor`, `Catalog`, or `Invocation`.

### Target topology

`tamoz-mcp-websearch` depends on `tamoz-mcp`; the existing
`Tamoz::Mcp::Websearch` namespace is retained. The operator script and eval
runner declare the new dependency explicitly. Do not rename the namespace
during the packaging move: that is a separate API decision with no boundary
payoff.

### Payoff and risk

This makes the current file-level isolation enforceable in Bundler metadata and
allows a MCP client/host consumer to avoid the websearch adapter entirely. It
also clarifies which process owns outbound network policy.

The risk is security-sensitive semantic drift. Move first, preserve all
credential, SSRF, redirect, response-bound, circuit, and attribution contracts,
then simplify only in a later slice. The eval harness must continue to prove
the real adapter path; a fixture is plumbing evidence, not provider evidence.

## `tamoz-agent-ruby-llm` — technically clean, explicitly deferred

### What moves

Move `RubyLLMModel` (113 lines at audit time; since removed — the model seam now
lives in tamoz-agent-kernel's `ModelClientFactory`/`EpisodeModelTransport`) into an
optional `tamoz-agent-ruby-llm` gem.

### Source evidence

- [`tamoz/agent.rb`](../../gems/tamoz-agent/lib/tamoz/agent.rb:13-15) eagerly
  requires the adapter.
- The adapter is the only production source file that requires `ruby_llm`, and
  it does so lazily in its constructor at line 33.
- The base gemspec still declares `ruby_llm` as a runtime dependency at
  [`tamoz-agent.gemspec`](../../gems/tamoz-agent/tamoz-agent.gemspec:11-27).
- `Tamoz::Agent.build` accepts a generic injected `model:` at
  [`agent.rb`](../../gems/tamoz-agent/lib/tamoz/agent.rb:46-66); the worker
  runtime accepts a caller-supplied `model_factory`. The base runtime therefore
  has a real model protocol independent of this provider.
- Construction consumers are the CLI (`cli.rb:837-869`) and the eval/OpenClaw
  benchmark adapters. The agent kernel owns provider/env-key vocabulary, so
  the adapter can depend on the kernel protocol without copying policy.

### Target topology

`tamoz-agent-ruby-llm` depends on `tamoz-agent-kernel` and `ruby_llm`, retains
`Tamoz::Agent::RubyLLMModel`, and owns the explicit require path. Remove the
adapter require and SDK dependency from `tamoz-agent`; make the CLI and future
eval runner declare the adapter.

### Payoff and risk

The package boundary would become truthful: an embedding that supplies another
model or only uses the injected protocol would not install the RubyLLM SDK.
However, this is not accepted into the immediate sequence. Provider credentials
are shared with profile validation, and CLI, worker factories, evals, and public
API surfaces consume the adapter. Untangle those composition paths first.

The public class and `ENV_KEYS` constant are already visible to the CLI and
eval code. Move them deliberately and update consumers in the same slice;
do not hide the old path behind a compatibility alias. Preserve model event
emission, provider errors, usage/cost extraction, and credential precedence.

## `tamoz-evals-runner` — separate verification from execution

### What moves

Keep `tamoz-evals` as the artifact/schema/digest/verifier library. Move the
`Harness/` subtree (26 files, 10,664 lines), `Benchmark/` subtree (17 files,
6,955 lines), and the scenario/scorecard/treatment command integration into a
new `tamoz-evals-runner` gem.

### Source evidence

- [`tamoz/evals.rb`](../../gems/tamoz-evals/lib/tamoz/evals.rb:25-64) eagerly
  requires all 26 harness and 13 benchmark files.
- The module-level verifier is a small direct API at
  [`evals.rb`](../../gems/tamoz-evals/lib/tamoz/evals.rb:66-73), while the CLI
  delegates scorecard and treatment commands to Harness factories at
  [`cli.rb`](../../gems/tamoz-evals/lib/tamoz/evals/cli.rb:25-78).
- The current gemspec declares eight runtime Tamoz dependencies because the
  harness directly reaches into their constants. That coupling is correct for
  a runner but excessive for artifact verification.
- The OpenClaw comms fixture directly requires `tamoz/comms` and
  `tamoz/telegram` at lines 9–12, while those are not current evals gemspec
  dependencies. The shared bundle masks this package-truth defect.

### Target topology

The runner depends on the verifier gem and explicitly declares every runtime it
imports: agent/session/capabilities, SQLite, MCP, graph/scheduler, comms and
Telegram, plus any provider adapter used by a real run. It owns scenario
execution, fixtures, subprocesses, benchmark readiness/publication, and the
runner executable. The verifier remains usable without a database, MCP SDK,
model SDK, or Telegram transport.

The exact executable split must be decided before implementation: either keep
`tamoz-eval verify` in the base gem and add a runner executable, or make a
single runner-owned CLI with a verifier-only library entry point. This is why
the candidate is Medium rather than a mechanical move.

### Payoff and risk

The split makes the intentionally non-runtime evidence format reusable and
forces the heavy runner to declare its true environment. It does not reduce
the production runtime graph because evals already sits outside it.

The risk is public CLI and evidence drift. Preserve artifact bytes, digest
rules, verifier decisions, scorecard labels, real-provider versus fixture
labels, subprocess isolation, and release-gate exit codes. Move the relevant
tests with each package in the eventual implementation; none are run during
this audit.

## `tamoz-mcp-agent` — design spike for the MCP capability bridge

### What would move

Consider moving the MCP-dependent half of `tamoz-agent-capabilities` into a
new `tamoz-mcp-agent` gem: `McpCapabilitySource`, `McpSourceBuilder`, and the
governed browser/database source adapters (about 882 lines). Keep the
transport-neutral capability source protocol and local/skills sources in the
agent capabilities gem.

### Source evidence

- `mcp_capability_source.rb` documents a duck-typed source protocol and says
  the agent should not depend on MCP for the protocol itself.
- `mcp_source_builder.rb` is the integration half: it constructs MCP catalogs
  and supervisors, maps MCP errors into agent errors, and is consumed by
  `WorkerRuntime` and the CLI.
- The current `tamoz-agent-capabilities` gemspec hard-depends on `tamoz-mcp`,
  even though the rest of its sealed catalog can be reasoned about without the
  MCP SDK.

### Target topology, payoff, and gate

The target would depend on `tamoz-agent-kernel`, `tamoz-agent-capabilities`
contracts, and `tamoz-mcp`; the parent must not depend on the bridge. Preserve
capability binding, catalog digest, approval, and durable effect-journal
semantics. This is a medium-confidence design spike because public constants,
optional loading, and caller composition are not yet mapped tightly enough for
an implementation slice.

## `tamoz-comms-gateway` — conditional edge-process extraction

### What would move

Consider moving `Comms::Gateway` (917 lines) and `DeliveryDrainer` (164 lines)
into a package for the long-running credential-bearing edge process. Keep
transport/value/store contracts in `tamoz-comms`, and keep `tamoz-telegram` as
the concrete Telegram transport.

### Source evidence

- `Gateway` owns injected transport/store dependencies and the inbound offset
  and admission ordering invariant.
- `DeliveryDrainer` owns claims, pacing, journal binding, send, receipt, and
  ambiguous-outcome handling.
- Direct consumers are concentrated in CLI and OpenClaw eval composition; the
  base gemspec otherwise describes a contract/value/transport-seam package.
- A blocking package-truth defect exists: `DeliveryDrainer` directly rescues
  `Tamoz::Telegram::ResponseTooLargeError` even though `tamoz-comms` does not
  depend on Telegram.

### Target topology, payoff, and gate

The target would depend on `tamoz-comms` and an injected transport error
classifier, not on Telegram. It would make the process boundary explicit, but
the Telegram rescue must first be mapped to a generic Comms error or injected
classification. Preserve lease fencing, offset ordering, claim/send ambiguity,
and public constants. Confidence is medium-high for the seam and conditional
for implementation.

## Deferred: `tamoz-tools-skills`

`tamoz-tools/lib/tamoz/tools/skills.rb` and its six children form a coherent
1,067-line security-sensitive Agent Skills compiler/catalog. However,
[`tamoz/tools.rb`](../../gems/tamoz-tools/lib/tamoz/tools.rb:5-9) eagerly
requires Skills, and `Toolbox` uses the snapshot/catalog in construction and
tool-surface digesting. A new gem that remains an unconditional dependency
would move files without changing the boundary or boot cost.

Reconsider it only if a design makes Skills an optional package with an
explicit empty-snapshot contract and proves that the toolbox/capability host
can preserve authority and digest semantics without loading it. Until then,
the correct decision is “defer,” not “extract for symmetry.”

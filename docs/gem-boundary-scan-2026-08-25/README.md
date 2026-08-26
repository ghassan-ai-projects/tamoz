# Gem-boundary scan — 2026-08-25

## Decision

Three extraction candidates are credible enough to plan. Do them in this
order:

1. **`tamoz-mcp-websearch`** — move the governed HTTP-egress adapter out of
   `tamoz-mcp`.
2. **`tamoz-agent-ruby-llm`** — move the optional RubyLLM provider adapter out
   of `tamoz-agent`.
3. **`tamoz-evals-runner`** — move scenario execution and benchmark machinery
   out of the artifact-verification gem.

The first two are small, bounded packaging changes with a directly measurable
minimal-boot improvement. The third is a larger, valuable split, but it should
be a separately planned slice because it changes the evaluation package's
public entry point and dependency declaration.

This is a read-only architecture scan. No production code, configuration, or
tests were changed or run. All pre-existing or concurrent working-tree changes
outside this report and its index entry were left untouched.

## Completion bar for every extraction

The split is complete only when all of these are true:

- The source concern has one named owner, a dedicated gemspec and README, and
  no duplicate implementation remains in the parent gem.
- The parent umbrella require does not load the extracted code or its optional
  external dependency.
- Every direct constant reference and every executable has an explicit gemspec
  dependency; no component relies on the monorepo Gemfile's load order.
- The new gem's isolated-install/load check is added to the dependency-isolation
  suite, and focused behavioural tests move with the code.
- The new dependency direction is one-way. In particular, no extracted adapter
  may require a caller-specific runtime, CLI, or eval harness.
- Existing namespace and require-path decisions are made deliberately. Tamoz
  does not support compatibility shims, so consumers move in the same change.

## 1. `tamoz-mcp-websearch` — do first

**Candidate.** Move `gems/tamoz-mcp/lib/tamoz/mcp/websearch.rb` and its three
`websearch/` implementation files (922 Ruby lines across four files at this
scan) into `tamoz-mcp-websearch`.

**Why this is a real package boundary.** The parent require
[`tamoz/mcp`](../../gems/tamoz-mcp/lib/tamoz/mcp.rb) loads the SDK-governed MCP
client/host only. It does not require websearch. The websearch entry point says
the same thing explicitly: it is loaded by the operator-side adapter and not
by Tamoz's core MCP load path because it owns the HTTP dialer. Its only
network-capable implementation is `EgressClient`, which requires `net/http`.
This is the already-established adapter shape used by `tamoz-telegram` and
`tamoz-otel`: a parent contract gem stays cheap and non-egress-capable; the
optional named integration is installed and loaded only by its operator path.

The packaging boundary has not caught up with the code boundary. The parent
`tamoz-mcp` gemspec currently owns both roles, while
[`script/websearch_adapter`](../../script/websearch_adapter) is the production
consumer of `Tamoz::Mcp::Websearch`. Consequently, an application cannot
declare the operator's HTTP adapter separately from the MCP client/host.

**Target shape.** `tamoz-mcp-websearch` depends on `tamoz-mcp` and keeps the
existing `Tamoz::Mcp::Websearch` namespace. Keeping the namespace avoids a
rename that provides no architectural benefit; gem ownership, not constant
nesting, is the separation in this case. The new gem owns the adapter-facing
require path, the operator executable changes to require it, and the parent
does not re-export it.

**Measured payoff.** 25% of `tamoz-mcp`'s 3,682 Ruby lines becomes opt-in, and
the socket-capable code is enforceably absent from a normal `require
"tamoz/mcp"` process instead of merely absent by convention.

**Risk and gates.** This code owns SSRF checks, credential-shaped-content
filtering, redirect bounds and the egress circuit. Move it verbatim first;
only then simplify it in a separate review. Prove the normal MCP require does
not load `net/http`, and retain the complete governed-websearch behaviour and
operator-executable coverage.

**Status.** This reaffirms the still-unimplemented high-confidence finding in
[`docs/reviews/codebase-review-2026-08-20/gem-extraction.md`](../reviews/codebase-review-2026-08-20/gem-extraction.md).
The current source still has the exact load-path seam that report described.

## 2. `tamoz-agent-ruby-llm` — do second

**Candidate.** Move the 113-line
[`RubyLLMModel`](../../gems/tamoz-agent/lib/tamoz/agent/ruby_llm_model.rb) to a
new optional adapter gem. Its proposed dependency is `tamoz-agent-kernel`; it
implements the existing model transport protocol under the retained
`Tamoz::Agent::RubyLLMModel` namespace.

**Evidence for the seam.** The adapter is the only production file that
requires `ruby_llm`, and it does so lazily in its constructor. The durable
worker accepts a caller-supplied `model_factory`; it does not need this class
to exist. The remaining production consumers are construction edges: the CLI
builds a `RubyLLMModel`, while the OpenClaw benchmark adapters use it to launch
a real provider run. The one-shot `Tamoz::Agent.build` already accepts a
generic `model:` object.

Yet `tamoz-agent` eagerly requires the adapter from its umbrella file and
declares `ruby_llm` as a runtime dependency. Every agent embedding therefore
installs the SDK even if it provides another model transport or never makes a
model call.

**Target shape.** Remove the adapter require and the `ruby_llm` dependency
from `tamoz-agent`; add `tamoz-agent-ruby-llm`, depending on
`tamoz-agent-kernel` and `ruby_llm`. Make `tamoz-agent-cli` and the future
evaluation runner declare the adapter directly. Provider credential-name data
already belongs to `Tamoz::Agent::Providers` in the kernel, so no provider
catalog needs to be copied.

**Measured payoff.** This is only one small file, but it cuts a third-party
model SDK from the base agent package and makes the real provider boundary
honest in both Bundler metadata and `require` topology. It also gives a future
provider a clear place to live without turning `tamoz-agent` into an adapter
collection.

**Risk and gates.** The namespace is currently public and appears in the
public-API tests. Move it without a compatibility alias. Verify that a base
agent load works without RubyLLM installed, while the CLI and real-provider
paths explicitly load the adapter and preserve typed provider errors and model
usage events.

## 3. `tamoz-evals-runner` — plan after the first two

**Candidate.** Retain `tamoz-evals` as canonical artifact types, schema,
digesting and verification. Move `Harness/`, `Benchmark/`, their dependencies,
and the `tamoz-eval scorecard` / `treatment` commands to a new
`tamoz-evals-runner` gem with its own executable.

**Evidence for the seam.** `tamoz-evals` is 18,947 Ruby lines. Its 64-line
umbrella require eagerly loads 26 harness files and 13 benchmark files even
though its sole module-level API is `verify(path)`. The gemspec itself says the
artifact format and release gates are its responsibility, but it declares
production runtime gems because the harness imports their constants directly.
The OpenClaw comms fixture goes further: it directly requires `tamoz/comms`
and `tamoz/telegram`, neither of which is declared in the current evals
gemspec. That is a package-truth defect hidden by the monorepo's shared bundle,
not a reason to make the core verifier carry still more runtime dependencies.

**Target shape.** `tamoz-evals` becomes installable with only the libraries
needed to verify sealed evidence. `tamoz-evals-runner` depends on it and on the
agent, SQLite, MCP, comms, Telegram, and any other runtime it imports directly.
It owns scenario execution, fixtures, subprocess launching, benchmark
publication/readiness, and the executable commands that invoke those concerns.
The base verifier need not load a model SDK, a database adapter, an MCP SDK, or
Telegram just to validate an artifact.

**Measured payoff.** The execution machinery accounts for nearly all of the
gem: `Harness/` alone is 26 files and the benchmark area contains the largest
files after the smoke corpus, including a 1,076-line comms runner and a
1,029-line durable CLI adapter. The split makes the intentionally non-runtime
evidence format reusable and exposes the runner's real, heavier environment.

**Risk and gates.** Treat this as a public-surface redesign, not a mechanical
directory move. Decide the executable names before implementation, move the
scorecard/treatment integration tests with the runner, and add isolated-install
checks for both gems. No real-provider benchmark may be represented as a test
fake after the move; fixture and live evidence must keep their present labels.

## Not recommended now

| Area considered | Verdict | Evidence |
|---|---|---|
| Individual SQLite stores (`comms`, `schedule`, `memory`, effects) | Do not split | They share one adapter, one migrator and one database transaction boundary. For example, worker scheduling deliberately claims an occurrence and enqueues work atomically. Separate adapter gems would create migration-order and transaction coupling without reducing a consumer footprint. |
| Agent worker/runtime | Do not split before the RubyLLM adapter | The worker is large, but it is the composition root for SQLite, channels, sessions, capability sources and scheduling. First remove the independent provider SDK boundary; reconsider a worker package only if a second durable-host implementation appears. |
| Agent CLI command groups | Keep together | The command files are domain-named but share argument policy, rendering, runtime-directory resolution and process lifecycle. Moving each command to its domain gem would invert dependencies from contracts back to the application shell. |
| Comms gateway and Telegram | Keep separate as-is | This is already the intended contract/transport split: `tamoz-comms` owns policy and the structural transport seam; `tamoz-telegram` owns the named Bot API adapter. |
| Stream subcomponents | Keep together | The gRPC worker, situation boundary, evidence and notification protocol make one vertical runtime. No optional named integration or low-fan-out subtree was found. |

## Recommended execution order

1. Create a short extraction plan for `tamoz-mcp-websearch`; perform a pure
   move, then an independent boundary review.
2. Extract `tamoz-agent-ruby-llm`; use the resulting isolated load test to
   prove the base agent no longer installs or loads the SDK.
3. Freeze the `tamoz-evals` verifier API and executable naming decision, then
   plan `tamoz-evals-runner` as its own multi-gem slice.

Do not combine these changes. Each one changes gemspecs, load paths and
isolated-install evidence; independent delivery keeps regressions attributable.

## Method and limits

I inspected the current gemspec graph, umbrella requires, source layout,
direct `require` statements and production constant references. I measured
Ruby source lines with `wc -l` over `gems/*/lib/**/*.rb`. I did not run tests,
start services, make network calls, or use a baseline snapshot; this report is
static architecture evidence, not runtime validation.

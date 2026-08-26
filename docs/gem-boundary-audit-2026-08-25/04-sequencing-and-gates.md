# Sequencing and gates

## Recommended order

### Phase 0 — repair package truth and narrow existing load edges

Before moving code, make the direct dependency defects explicit in the design:
`tamoz-evals`'s runner-only imports, CLI's SQLite/Telegram imports, SQLite's
direct Core use, memory's composition-root SQLite load, and scheduler's
eval-specific scorecard consumer. Also narrow SQLite's stream requires to the
stream contracts it actually uses. These are prerequisites, not invitations to
create a contracts gem.

Required evidence:

- every direct cross-gem require is declared by the package that owns it or is
  moved to the composition root;
- no scheduler-to-evals dependency is introduced;
- SQLite no longer boots the full gRPC/protobuf stream runtime solely for its
  narrow error/verification contracts;
- the package-truth changes are documented separately from behavior changes.

### Phase 1 — `tamoz-mcp-websearch`

Move the four websearch files verbatim. Update the operator script, eval runner
dependency, test load paths and dependency-isolation matrix. Decide the
namespace once (`Tamoz::Mcp::Websearch` is the low-risk choice) and do not
combine the move with an egress-policy redesign.

Required evidence:

- `require "tamoz/mcp"` remains free of websearch and its HTTP dialer;
- the new gem requires the MCP contracts it actually uses and nothing upward;
- operator and eval consumers declare the new gem explicitly;
- SSRF, credential, redirect, byte, circuit and attribution contracts remain
  covered;
- the full MCP/websearch boundary is represented in the isolation suite.

### Phase 2 — `tamoz-evals-runner`

Freeze the verifier API and command naming first. Keep artifacts, schemas,
digests, verifier decisions and the `verify` entry point in `tamoz-evals`; move
the harness, benchmarks, scorecard/treatment commands, OpenClaw fixtures, and
the eval-specific scheduler consumer into the runner. The runner must declare
agent-cli, comms, Telegram, tools and every other direct import instead of
depending on the monorepo bundle.

Required evidence:

- base verifier can install/load without SQLite, MCP, agent, comms, Telegram,
  or model SDKs;
- runner gem declares every direct import;
- artifact bytes, digest rules, decisions and exit codes remain identical;
- fixture, deterministic, and real-provider evidence labels remain honest;
- runner subprocesses use explicit gem load paths and no ambient bundle;
- verifier and runner documentation and executable surfaces are indexed.

### Phase 3 — `tamoz-mcp-agent` design spike

Map the MCP capability bridge's public constants, catalog digest, approval
intersection, and effect-journal call path. Only implement after the bridge can
depend one-way on agent capability contracts and MCP without making the MCP gem
depend on agent policy.

Gate: a written load/consumer map shows the non-MCP capability catalog remains
usable without the bridge and all MCP calls still pass through durable effects.

### Phase 4 — `tamoz-comms-gateway` conditional extraction

First replace the direct Telegram exception rescue with a generic Comms error
classification or injected classifier. Then move Gateway and DeliveryDrainer
as one edge-process package, preserving offset ordering, lease fencing,
claim/send ambiguity, receipts, and public constants.

Gate: the new package has no Telegram dependency, and the transport-neutral
`tamoz-comms` package remains independently loadable.

### Phase 5 — `tamoz-stream-sse` only after deployment evidence

If a real production/operational consumer is identified, move the adapter to
`tamoz-stream-sse`, preserve `Tamoz::Stream::SseTransport`, and remove the
parent eager require. Without that consumer evidence, prefer the Phase 0
narrow-require change; a new gem would otherwise be packaging theatre around a
test-only in-tree consumer.

### Deferred — `tamoz-agent-ruby-llm` and `tamoz-tools-skills`

RubyLLM remains a later adapter once provider credentials, worker factories,
CLI construction, and eval composition are explicit. Skills remains deferred
until the toolbox has a deliberate optional empty-snapshot contract. Neither
should be moved merely to make the gem count more symmetrical.

## Per-phase implementation loop

1. Freeze the clean source inventory and dependency graph for that slice.
2. Read public API, error, wire, security, event-order and transaction
   contracts before moving a file.
3. Add or confirm characterization coverage at the natural seam.
4. Move the smallest cohesive responsibility with no simplification.
5. Update gemspecs, requires, executable paths, public API registry and
   dependency-isolation assertions in the same change.
6. Run the focused test/static gates only in the implementation task (not this
   audit), then inspect the architecture delta.
7. Perform an independent reviewer pass for semantic drift and unnecessary
   coupling.
8. Only after the reviewer passes, simplify debt exposed inside the new gem.

## Future scan procedure

Repeat this audit when a gem changes by a material responsibility:

- inventory every gem and direct edge;
- inspect umbrella require graphs and external dependencies;
- use Enola for hotspots/impact, then verify every promoted edge in source;
- ask whether the seam has an independent consumer or optional integration;
- document accepted, deferred and rejected moves;
- stop only when the [quality bar](00-quality-bar.md) is complete.

Do not use file size, namespace depth, or a static “god class” label as an
automatic extraction rule.

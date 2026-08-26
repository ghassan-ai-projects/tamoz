# Specialist review and reconciliation

## Review lanes

Three independent read-only lanes were used. Each received a disjoint source
scope, was forbidden to edit files, run tests/lint/builds, install dependencies,
or create commits, and returned source paths, candidate decisions, rejected
splits, and blind spots.

| Lane | Scope | Result |
|---|---|---|
| Gem inventory | All 24 gem directories, gemspecs, umbrella entrypoints, literal cross-gem requires, operational launchers | Completed; found package-truth defects and confirmed the current graph is larger than the stale public 17-gem page suggests |
| Adapter boundaries | MCP/websearch, MCP-agent bridge, Comms/Telegram, observability/OTel, stream/SSE, RubyLLM, tools/Skills, CLI | Completed; ranked websearch highest, identified conditional Comms and MCP-agent seams, downgraded SSE, deferred RubyLLM |
| Storage/evals boundaries | Core, graph, SQLite, scheduler, evals, transaction/effect boundaries | Completed; ranked eval runner high, rejected SQLite store splits, found scheduler-to-evals product leakage and narrow stream-load opportunity |

No lane changed production code or ran tests. Existing dirty worktree changes
were ignored.

## Reconciled decisions

| Area | Independent evidence | Reconciled decision |
|---|---|---|
| MCP websearch | Adapter lane: high-confidence four-file/922-line external adapter; inventory confirms parent MCP umbrella excludes it | **Accept now.** `tamoz-mcp-websearch` is the clearest packaging boundary. Preserve `Tamoz::Mcp::Websearch`; update operator/eval ownership. |
| Evals harness and benchmarks | Storage lane: verifier is about 1,164 LOC while harness/benchmark code is roughly 92% of the gem; inventory finds undeclared runner imports | **Accept now.** `tamoz-evals-runner` owns execution, fixtures, scorecards, benchmarks, and eval-specific scheduler code; base evals keeps artifacts/schema/verifier. |
| MCP-dependent agent bridge | Adapter lane: 882-line MCP integration half with a duck-typed source protocol; other lanes did not promote it | **Design spike.** Candidate `tamoz-mcp-agent`; first prove non-MCP capability loading, catalog digest, approval intersection, and durable effects remain intact. |
| Comms gateway/drainer | Adapter lane: 1,081-line edge-process cluster and a real lifecycle boundary; also found undeclared Telegram error coupling | **Conditional design.** Candidate `tamoz-comms-gateway` only after generic Comms error classification removes the Telegram dependency. |
| SSE transport | Adapter lane: genuine 259-line injected adapter but no production consumer; inventory confirms eager parent/SQLite load | **Do not move yet.** First narrow SQLite's stream requires. Create `tamoz-stream-sse` only if a real deployment consumer is identified. |
| RubyLLM adapter | Adapter lane: technically movable 113-line provider adapter; shared credential/profile/CLI/evals composition | **Defer.** The seam is real, but the current public and composition edges make this a later slice, not an immediate extraction. |
| Agent Skills | All relevant lanes: cohesive security cluster but eager Toolbox ownership | **Defer.** A child gem without optional loading is packaging theatre. |
| Core, graph, SQLite stores, focused agent gems, Telegram, OTel | Storage and adapter lanes agree on canonical, transactional, or already-correct boundaries | **Reject further splits now.** High fan-in and size are not enough; preserve ownership and transaction/effect invariants. |

## Package-truth reconciliation

The inventory lane found direct imports that the storage/evals lane independently
confirmed on the eval path:

- `tamoz-evals` directly uses agent-cli, Comms, Telegram, and Tools without a
  complete declaration set. Those imports belong to `tamoz-evals-runner`.
- `tamoz-agent-cli` directly loads SQLite and Telegram without declaring both;
  the Telegram path is intentionally optional, but the SQLite command path must
  be explicit.
- `tamoz-sqlite` directly uses Core through transitive activation and should
  eventually declare the direct dependency.
- `tamoz-agent-memory` constructs SQLite stores without loading SQLite from its
  own umbrella; this is composition-root coupling, not a reason to split memory.
- `tamoz-agent` reaches Scheduler through SQLite without declaring Scheduler;
  the worker composition root should own that edge.
- `tamoz-scheduler` contains `ScorecardSummaryConsumer` and `ScorecardResult`,
  which execute eval-specific work. Move them into the runner or inject a
  consumer protocol; never add a scheduler-to-evals dependency.

These are static package findings. No isolated gem installation or subprocess
boot was run.

## Static architecture receipt

The root lane generated an Enola snapshot on the dirty current tree:

- Enola `0.2.7-51-g72cd079`, verification-against commit `2ca316d01e19`;
- 575 parsed files, zero parse errors, 12,631 facts, 51 heuristic insights;
- 0 detected cycles and 0 layer violations;
- one low-confidence (0.40) 41-module coupling-density cluster;
- high fan-in signals at `Tamoz::Core`, `Core.digest`, `Core.deep_freeze`, and
  `Tamoz::SQLite::Adapter`.

The 41-module cluster is not promoted to a cycle finding: Enola over-approximates
shared `Tamoz` namespaces, comments, and autoloaded references. Source review
and the independent storage lane both found the lower-level graph/core boundary
coherent.

## Count cross-check and correction loop

The inventory handoff contained two aggregate mistakes: it counted the helper
file `gems/gemspec_helper.rb` as a gem, and its file/LOC total did not match its
own per-gem rows. The per-gem table and a direct root recheck were compared. The
authoritative report count is the rechecked result from:

```text
find gems -mindepth 1 -maxdepth 1 -type d -print | wc -l
find gems -type f -path '*/lib/**/*.rb' -print | wc -l
find gems -type f -path '*/lib/**/*.rb' -print0 | xargs -0 wc -l
```

That result is **24 gem directories, 515 Ruby library files, and 97,204 Ruby
lines**. The per-gem table in [01-current-inventory.md](01-current-inventory.md)
is the source-level breakdown used for decisions. This correction is why the
quality bar requires a complete inventory rather than trusting a single
aggregate produced by a specialist.

## Bar status

- [x] All 24 current gems are accounted for.
- [x] Declared dependencies and observed imports were compared.
- [x] Three disjoint specialist reviews completed and reconciled.
- [x] Accepted candidates have responsibility, seam, consumers, dependency
  direction, payoff, and risk evidence.
- [x] High-suspicion rejected/deferred splits have reasons.
- [x] Static-tool findings are separated from source-verified conclusions.
- [x] Sequencing, gates, risks, blind spots, and a repeatable loop are written.
- [x] Only documentation files were changed by this audit; no tests were run.

The stop bar is met for this audit. Implementation work should start as a new
task with its own behavior model, tests, and reviewer gate.

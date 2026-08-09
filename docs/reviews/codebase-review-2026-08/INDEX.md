# Codebase Review — August 2026

A 12-agent parallel review of the tamoz monorepo against `docs/CODING_STANDARD.md`. Each agent read its scope in full; findings were reported with `path:line` evidence and suggested fixes. This folder holds one cleaned-up report per scope; findings are ordered by severity (High / Medium / Low).

## Executive summary

The codebase is generally in good shape: validation at boundaries, immutable values, domain-separated digests, honest crash/kill-matrix testing, and boundary direction (core ← tools/graph ← sqlite ← agent, mcp to the side) all hold up under scrutiny. But the review surfaced a handful of genuinely dangerous defects that share one theme — **gates that fail open or silently**: budget enforcement in `WorkerRuntime` returns zeros on any storage error (unlimited unattended spend when the store is sick), the MCP websearch egress client drops the HTTP request path so the live provider path is broken, the sqlite migrator can never upgrade databases created at schema versions 2–4, `ReplayClock`'s monotonicity guard is dead code, `CognitionAdmission` admits on empty scores, and `agenteval`'s `Trial#kill_tree` SIGKILLs its own process group on any timeout. A second theme is **fragmented error identity**: base error classes root at different ancestors across gems and several error-class names are defined twice, so `rescue Tamoz::Error` is unreliable. A third is **known structural debt**: `CheckpointStore` (1,759 lines), `SessionNodes` (1,450), `Toolbox` (1,166), `Compiled` (1,152), and `AgentSmokeCorpus` (3,287) — nearly all already in `.rubocop_todo.yml`, i.e. ratchet-shrink targets rather than new discoveries.

## Reports and severity counts

| Scope | Report | High | Medium | Low |
|---|---|---:|---:|---:|
| gems/tamoz-core | [tamoz-core.md](tamoz-core.md) | 4 | 6 | 8 |
| gems/tamoz-agent | [tamoz-agent.md](tamoz-agent.md) | 5 | 6 | 8 |
| gems/tamoz-mcp | [tamoz-mcp.md](tamoz-mcp.md) | 2 | 7 | 8 |
| gems/tamoz-graph | [tamoz-graph.md](tamoz-graph.md) | 5 | 10 | 5 |
| gems/tamoz-scheduler | [tamoz-scheduler.md](tamoz-scheduler.md) | 2 | 5 | 5 |
| gems/tamoz-sqlite | [tamoz-sqlite.md](tamoz-sqlite.md) | 4 | 8 | 6 |
| gems/tamoz-stream | [tamoz-stream.md](tamoz-stream.md) | 3 | 6 | 5 |
| gems/tamoz-tools | [tamoz-tools.md](tamoz-tools.md) | 3 | 7 | 5 |
| gems/tamoz-evals + agenteval | [tamoz-evals.md](tamoz-evals.md) | 5 | 7 | 5 |
| apps + bin | [apps-and-bin.md](apps-and-bin.md) | 2 | 6 | 6 |
| test suite | [test-suite.md](test-suite.md) | 3 | 5 | 5 |
| cross-cutting | [cross-cutting.md](cross-cutting.md) | 4 | 7 | 6 |
| **Total** | | **42** | **80** | **72** |

(194 findings. Some overlap across scopes — e.g. the agent budget fail-open defect appears in both tamoz-agent and cross-cutting; deduplicated where noticed, retained where the framings differ.)

## Top 10 highest-impact findings

1. **Budget enforcement fails open on storage errors** — `worker_runtime.rb:186-193` rescues to zeros, so a sick store silently grants unlimited model calls, plus the same swallow pattern across the operator store (recorded approvals become invisible). [tamoz-agent.md H1–H3](tamoz-agent.md), [cross-cutting.md H1–H2](cross-cutting.md)
2. **MCP `EgressClient` drops the request path — live HTTP provider path broken** — connector never receives `path`, hardcodes `Get.new("/")`, body silently unsent; no test exercises the real path. [tamoz-mcp.md H1](tamoz-mcp.md)
3. **SQLite migrator cannot upgrade schema versions 2/3/4** — every such database hits `MigrationError` instead of migrating forward. [tamoz-sqlite.md H1](tamoz-sqlite.md)
4. **`agenteval` `Trial#kill_tree` SIGKILLs the harness's own process group** — child spawned without `pgroup: true`, so any timeout kills agenteval itself. [tamoz-evals.md H1](tamoz-evals.md)
5. **`ReplayClock` regression guard is dead; `WallClock#now_event` has none** — stream-clock monotonicity is unenforced in both modes. [tamoz-stream.md H1–H2](tamoz-stream.md)
6. **Split error hierarchy + duplicated error-class names across gems** — `rescue Tamoz::Error` is unreliable; `LeaseLostError`/`ClockRollbackError`/`StoreConflictError` each exist twice. [cross-cutting.md H3–H4](cross-cutting.md)
7. **Production circuit `rate`/`run` conditions untested; circuit `Record#load` breaks immutability** — a broken rate predicate would never open a budget circuit; loaded durable state is mutable in place. [tamoz-core.md H1–H2](tamoz-core.md)
8. **CLI `resolve … unknown` silently records `:failed`** — the two operator entry paths map the same word to different durable states. [apps-and-bin.md H1](apps-and-bin.md)
9. **`Canonical.sort` silently drops string/symbol key collisions in the digest path** that feeds checkpoint identity; and hardcoded `StateCodec.new` bypasses a graph's custom codec at the durability boundary. [tamoz-graph.md L4, H4](tamoz-graph.md)
10. **`CognitionAdmission.evaluate` admits on empty scores** — evidence-free input passes an admission gate that should fail closed. [tamoz-stream.md H3](tamoz-stream.md)

## Suggested remediation order

1. **Fail-open gates first (correctness/safety, small diffs):** agent budget/operator-store rescues (tamoz-agent H1–H3, cross-cutting H2), stream clock guard + admission fail-closed (tamoz-stream H1–H3), scheduler typed-crash paths (tamoz-scheduler H1–H2), sqlite migrator version gap (tamoz-sqlite H1), agenteval process-group kills (tamoz-evals H1, H5), CLI `unknown` vocabulary (apps-and-bin H1).
2. **Test the untested critical paths:** circuit `rate`/`run` conditions (tamoz-core H1), graph `DurableRunner` unit tests (tamoz-graph M10), scheduler `due_occurrences` (tamoz-scheduler M3), stream clock tests (tamoz-stream M3), agenteval framework characterization (tamoz-evals H2), MCP egress connector contract test (tamoz-mcp H1).
3. **Unify error identity:** one `Tamoz::Error` root, dedupe cross-gem class names, fix cross-domain raises (cross-cutting H3–H4, tamoz-sqlite H2, tamoz-evals H4) — with §7 migration notes.
4. **Kill the high-drift duplications:** tool-failure evidence contract (tamoz-agent M2), MCP strict-schema/circuit/sanitizer copies (tamoz-mcp M1–M4), digest helper + canonicalizer consolidation (cross-cutting M1–M2), verifier status matrix (tamoz-evals M1).
5. **Continue the chartered extractions** (`SessionNodes`, `CheckpointStore`, `Toolbox`, `Compiled`, `AgentSmokeCorpus`, CLI collaborators) only after the seams above are pinned — the test-suite `send`-based tests (test-suite H2) currently pin the CLI's private shape and must be reworked first.
6. **Hygiene sweep as capacity allows:** missing requires, dead code/constants, stale namespace strings, docs vs. reality mismatches, `.rubocop_todo.yml` ratchet shrink.

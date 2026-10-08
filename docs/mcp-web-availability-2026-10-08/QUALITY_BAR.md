# MCP and web availability — quality bar

**Task:** a configured MCP server or the web never goes missing because it was unreachable once; chat
turns can use MCP tools and read web pages · **Owner:** Ghassan · **Size:** L · **Set:** 2026-10-08
(before the change)
**Plan:** [PLAN.md](PLAN.md) · **Governing ADRs / invariants:** ADR-029 (inv. 36, 37), ADR-030,
ADR-053 §7, ADR-054 · **Branch:** `mcp-lazy-web-fetch`

Status values: `PASS` (evidence named) · `FAIL` · `OPEN` · `BLOCKED` · `WAIVED` (owner only).

## 0. Outcome and fence

**Outcome:** on the Telegram worker, (1) an MCP server that was reachable once keeps its tools when it
is down, and one unreachable server never removes another's tools; (2) a server never reached is retried
on the next turn instead of being lost until restart; (3) a work-loop turn sees the configured MCP tools
and can search the web and read a page the user wrote or a search returned — and never a URL the model
composed.

**Not in scope:** refreshing a cached catalog while its server is down; following links found inside a
read page; PDF and JavaScript-rendered pages; exposing raw MCP tools to the legacy planner beyond what
it has today. Each goes to PLAN.md "Future".

**Owner decisions:** given 2026-10-08 in chat — connect only when needed, never fail a turn because a
server is down, and make web page reading available. The provenance rule for URLs (user-written or
search-returned) is the author's design, recorded in ADR-054.

## 1. Seam

| # | Question | Answer |
|---|---|---|
| 1.1 | Seams extended | `McpSourceBuilder#build` (catalog per server), `Tamoz::Mcp::Catalog` (facade: `to_h`/`from_h`), `WorkerRuntime#mcp_source`/session memo, `WorkContext#surface_tools`, `WorkGate#with_arguments`, `WorkWeb`, `script/websearch_adapter`, `policy/base.yaml` |
| 1.2 | What already does part of it | `Invocation` already connects lazily at first call and maps unavailability to `ToolError`; `WorkWeb` already maps a shown web tool to its backing capability; `WorkMemory#user_messages` already defines "a message the user wrote" |
| 1.3 | Blast radius | enola `impact_analysis` on `McpSourceBuilder`, `WorkWeb`, `WorkContext` (recorded in loop log) |
| 1.4 | Baseline | enola baseline pinned 2026-10-08 at `d9bdb885` before any edit |

## A. Safety and authority

| # | Property | Check | Status |
|---|---|---|---|
| A1 | A corrupted stored catalog is not used (digests recomputed on load; integrity, not origin — the 0700 runtime directory is the trust) | `test/mcp_catalog_store_test.rb` — tampered entry ignored; mutation: skip digest check | PASS (mutation seen red) |
| A2 | A cache written for a different server configuration is not used | same file — changed arguments ignore the stored catalog; mutation: drop config-digest compare | PASS (mutation seen red) |
| A3 | `read_url` refuses a URL that is neither in a user message nor in a `web_search` result of the turn | `test/work_web_chat_test.rb`; mutations: always admit / drop user messages / drop search results | PASS (each seen red) |
| A4 | The legacy planner and research children never see `mcp:websearch/read_url` | `test_the_legacy_planner_never_sees_read_url`; mutation: drop `HOST_GATED` | PASS (seen red); children: `web_backings` excludes read_url |
| A5 | Operator-declared read-only MCP tools land in tier `read`; every other MCP tool still asks | `approval_policy_document_test` + `base.yaml` simulations | PASS |
| A6 | MCP calls stay journaled (`EffectDispatcher.run`) from the work loop | `test_an_mcp_tool_is_dispatched_by_its_shown_name` (gate → `effects.dispatch`) | PASS |
| A7 | Cache file and directory are private (0600 / 0700) | `test/mcp_catalog_store_test.rb` | PASS |

## B. Function

Fixture MCP servers and scripted models prove plumbing only.

| # | Property | Check | Status |
|---|---|---|---|
| B1 | One unreachable server does not remove another server's tools | `test/mcp_catalog_store_test.rb` | PASS (mutation seen red) |
| B2 | A server down at build uses its cached catalog; its call then fails as a tool error, not a turn failure | same | PASS |
| B3 | A server never reached is absent, and the worker retries it on the next session build | `agent_worker_mcp_test#test_a_server_never_reached_is_retried_by_the_next_session`; mutation seen red | PASS |
| B4 | Work loop shows MCP tools under valid tool names and dispatches the backing capability | `work_web_chat_test` | PASS |
| B5 | Ordinary work turn: `web_search` then `read_url` of a hit, and `read_url` of a user-written URL | `work_web_chat_test` (fixture web, real adapter code); subprocess: `websearch_invocation_test#test_real_adapter_reads_an_unsearched_page_only_through_read_url` | PASS |
| B6 | Live: Telegram worker config has memory, ALMS and websearch; a real-model turn reads a page and calls ALMS | Telegram, glm-5.3-flash, 2026-10-08 11:51 and 11:59 UTC: ALMS `health.check` and a learnings sweep answered. Web page and memory turns not yet run by the owner; `read_url` reached a live page through the real adapter outside the model | PARTIAL |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | Touched test files, one per command | 25 touched/related files, each green | PASS |
| D2 | `rake ci` | test_parallel 332 files all passed; design/adr/syntax pass; `stream:proto:check` known-red | PASS except known-red |
| D3 | `rake ci_full` both locales (MCP slice) | output | OPEN |
| D4 | RuboCop: no new offense | `bundle exec rubocop <files>` vs HEAD | OPEN |
| D5 | enola `diff_snapshot`: no new cycle or layer violation | `enola check` PASS; `diff_snapshot`: 0 regressions | PASS |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | Simplest design: no background refresh, no new gem, no new state key unless needed | review | OPEN |
| E2 | No shim or alias (ADR-059) | diff review | OPEN |
| E3 | Comments per AGENTS.md | review | OPEN |
| E4 | New files 644, scripts 755, no scratch files | `git ls-files -s`, `git status` | OPEN |
| E5 | Tool definitions are prompt-pack data, not Ruby literals | review | OPEN |

## F. Honesty and records

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Report separates plumbing tests from the real-model run | review | OPEN |
| F2 | PLAN.md and gem READMEs match what was built | review | OPEN |
| F3 | ADR-029/053/054 updated; History line for the authority loosening; `rake adr:validate adr:verify` | tooling + review | OPEN |
| F4 | Lesson recorded (`.agent/rules/`) | review | OPEN |

## Review log

| Package | Findings (C / H / M / L) | Resolution | Commit |
|---|---|---|---|
| S1–S3, pass 1 | 1 / 2 / 4 / 4 | C1 URL laundering via a failed search's error text; H1 retry storm; H2 probes on a missing server; M1–M4, L1–L4 — all fixed with tests | uncommitted |
| S1–S3, pass 2 | 0 / 2 / 0 / 2 | N1 punctuation tail on read_url (now sends the admitted URL); N2 retired sources piled up (one kept) — fixed | uncommitted |
| S1–S3, pass 3 | 0 / 0 / 0 / 0 | — | uncommitted |

## Loop log

| Iteration | Date | What changed | Rows moved | Still open | Next |
|---|---|---|---|---|---|
| 1 | 2026-10-08 | bar set | — | all | build S1 |
| 2 | 2026-10-08 | S1–S3 built, tests + mutations, ADRs | A1–A7, B1–B5, D1, D2, D5 to PASS | B6, D3, D4, E, F, review | review, live run |
| 3 | 2026-10-08 | review passes 1–3 fixed; gates rerun; D4 clean on touched files; worker restarted on the branch | D4, F3, F4 to PASS | B6 (owner testing on Telegram), D3 not run | owner test, commit |

**Known-red at HEAD:** `stream:proto:check` — `grpc-tools` ships an x86_64 `protoc` that cannot run on this
Apple Silicon Mac without Rosetta (`Errno::EBADARCH`); proven in a detached worktree of `d9bdb885`.

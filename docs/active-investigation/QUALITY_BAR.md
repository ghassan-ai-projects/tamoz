# Active investigation — quality bar

The build is done when every item below is **PASS** with its evidence filled in.
Items are graded, not asserted: each names the check that proves it. A package is
committed only when its own items pass; the loop then re-grades the whole bar and
fixes whatever fails, until nothing does.

Status values: `PASS` (evidence named), `FAIL` (what is wrong), `OPEN` (not built yet),
`BLOCKED` (cannot be done here; the reason is named and it is not counted as a pass).

## A. Safety — one discriminating test per invariant

Each test must be seen to fail when the property is removed (mutation-proven), or it
proves nothing.

| # | Property | Check | Status |
|---|---|---|---|
| A1 | I1 — a probe whose backing tool is not in `read_only_tools` does not load; nor does an unknown free type, a name outside `probe_`, a duplicate, or an unknown placeholder | unit test, mutation: drop the `read_only_tools` check | PASS — `agent_probe_catalog_test`, `agent_probe_source_test#test_a_probe_whose_backing_tool…`; mutation (drop the `read_only_tools` check) fails |
| A2 | I2 — an episode probe that the local catalog declares but the wire catalog does not grant is refused | unit test, mutation: drop the grant check | PASS — host refuses an ungranted probe and stream tool; kernel records `not_granted` without dispatch; catalog digest checked at admission (`test_a_catalog_that_does_not_match_its_digest…`); mutations fail |
| A3 | I3 — a model-supplied pinned or unknown argument is refused; an unresolved placeholder is a refusal, not a call | unit test, mutation: merge instead of refuse | PASS — `agent_probe_source_test` (pinned/unknown/missing refused; single-pass fill; enum fill); mutations (merge unknown keys, drop the missing check) fail |
| A4 | I4 — free slots enforce type and bounds; results over `max_result_bytes` are cut and marked `truncated` | unit tests | PASS (probe side) — `test_free_slots_are_bounded`, `test_results_are_scrubbed…capped_within_the_declared_bound` |
| A5 | I5 — episode tool calls replay from the journal; a crash between slot 1 and 2 of a three-request turn re-executes nothing already done; a crash *during* a slot re-runs that slot (idempotent) | graph test over the real checkpointer | PASS — `stream_episode_investigation_test#test_a_crash_between_slots…` (slot 0 replayed, interrupted slot 1 re-read, slot 2 once). Stand-in: a raised `Tamoz::TimeoutError` leaves the attempt open; a same-fence redelivery after a real process death is not covered |
| A6 | I6 — tool results appear only in the user section, fenced and attributed | frame test | PASS — `agent_episode_investigation_test#test_results_are_fenced_data…` (results only in the user section; the system section gets only the pinned surface and budget) |
| A7 | I7 — a secret-shaped value in a probe result never reaches the frame, the journal or the report | unit test | PASS (probe side) — key bodies, tokens and structured content scrubbed via `Tamoz::Core.scrub_secrets`; mutation (header-only patterns) fails |
| A8 | I8 — an episode citing an ungathered tool id is refused; a report citing an ungathered call id is refused | unit tests, mutation: drop the check | OPEN |
| A9 | I9 — no mutating capability is reachable in an investigation turn; `report_findings` executes nothing | work-loop test | PASS — `tamoz investigate` offers no mutating tool (`agent_cli_investigate_test`), refuses `--allow-changes`/`--profile`; a turn that may change files is never offered `report_findings` (`test_a_turn_that_may_change_files_is_not_offered_the_report`) |
| A10 | `sql_select` refuses writes and multi-statements (reusing `GovernedDatabaseSource`) | unit test | PASS — `test_free_slots_are_bounded` (DELETE and multi-statement refused); database servers accept only a `query` slot |
| A11 | Gap K — a server that backs a probe exposes no raw tool on the capability surface | unit test | PASS — execute/validate/preview/maximum_effect_output_bytes/read_only? refuse hidden tools; integration test over the real MCP test server; mutation fails |
| A12 | Error, refusal and `budget_spent` tool entries are not citable (episode) and failed probe calls are not citable (report) | unit tests | PASS (episode side) — error, `not_granted` and `budget_spent` entries get no evidence id; report side in WP4 |
| A13 | Approval: a `probe_*` call is `allow` under `base` and `plan`; an unlisted MCP tool still asks; the verdict comes only from policy data | approval engine test | PASS — `approval_policy_document_test` (probe_* read under plan; `mcp:srv/probe_x`, `probe`, `probeX` fall back; exact key wins; only a trailing `*` loads) and the policy simulations; `work_loop_investigation_test` runs probes under plan and review without asking; mutation (drop the entry) fails |

## B. Function — the capability works end to end (plumbing, scripted model)

These run the real graphs with a scripted provider. They prove plumbing, never
intelligence.

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Episode: a snapshot that cannot settle the diagnosis → tool request with `purpose` → probe result in the next frame → a decision citing `tool:0` | graph test through `EpisodeRunner` with a probe host | PASS — `test_insufficient_snapshot_then_a_probe_then_a_decision_citing_it` (surface in the system section, result in the frame, decision cites `tool:0`, one lifecycle event) |
| B2 | Episode: tools spent → FINAL directive → terminal `unknown` with `evidence_gaps`, not a failure | graph test | PASS — `test_a_spent_tool_budget_gets_the_final_directive_and_an_honest_abstain` |
| B2b | Episode: one model call left → FINAL directive; the same holds when the model budget runs out before the tool budget | graph test | PASS — `test_the_model_budget_running_out_first_also_gets_the_final_directive` |
| B2c | Episode: a tool turn after the FINAL directive ends typed as budget-exhausted (the loop terminates) | graph test | PASS — `stream_episode_loop_test#test_gate5…` (tool turn on the last allowed call → BUDGET_EXHAUSTED, zero tool calls); mutation (drop the `validate` check) fails |
| B2d | Episode: an MCP failure or SQL refusal inside a probe becomes an `is_error` entry and the episode still decides | graph test | PASS — `test_a_failed_probe_is_an_error_entry…`; citing it is refused (`test_citing_a_failed_probe_is_refused`) |
| B2e | Episode: the parser requires `purpose` and caps `evidence_gaps` at 8 | parser test | PASS — `agent_reasoning_document_test` (missing, oversize and blank `purpose` refused; `evidence_gaps` optional, capped at 8, forbidden on tool turns) |
| B3 | Episode: three requests in one document → three journaled slots, in order | graph test | PASS (node level) — `test_every_request_runs_in_order…` (absolute slots after prior results; `not_granted` and `budget_spent` recorded, not dispatched); graph level in WP3 |
| B4 | Episode: no tool surface → frame bytes identical to before this change | frame digest pinned from HEAD before WP2 edits | PASS — `test_an_episode_without_tools_keeps_the_frame_bytes…` pins the HEAD digest `ebe8e540…`. Deviation: an episode with tool results but no surface now renders `purpose`/`truncated`/`result`, so its frame differs from HEAD by design |
| B4b | Episode: a wire catalog built the way Go's `buildTools` builds it (`evidence_get`, `probe_*`) yields a surface with both | host test | PASS — `test_the_surface_reads_go_spelled_catalogs…` and the host's `evidence_get` → `evidence.get` test |
| B4c | Episode: a same-config redelivery succeeds; a redelivery after the probe catalog changed is refused | runner test | PASS — `test_a_redelivery_is_idempotent_and_a_changed_catalog_is_refused`; mutation (drop the catalog digest from the payload) fails |
| B5 | Episode: every dispatched tool call emits one `ToolLifecycle` event with `execution_started`; `budget_spent` entries emit none and are not counted | stream test | PASS — one event per dispatched call, none for `budget_spent`/`not_granted`, `tool_calls_used` from the budget state; mutation (count every entry) fails |
| B6 | Worker: `--runtime-dir` builds the probe host; supervisors close on shutdown | worker test | PASS (narrowed) — the launcher serves with probes configured and exits 0 on TERM (it used to abort with SIGABRT, so the source never closed); a runtime dir without probes exits 2. Not proven: that `close` stops a live MCP process (none is started without an episode) |
| B6b | Session: with probes off, the work header is byte-identical to before this change | header digest test | PASS — work header tools and system bytes pinned from HEAD `6f71f9ec` (`test_without_probes_the_work_header_is_byte_identical_to_before`) |
| B7 | Session: a work turn sees probe tools, calls one, and ends with a valid `report_findings`; the answer is the rendered report | work-loop test | PASS — `test_a_probe_then_a_grounded_report_ends_the_turn…` (also over chat: `test_a_chat_turn_gets_the_same_probe_surface`) |
| B8 | Session: an invalid report is returned to the model as a tool error and repaired | work-loop test | PASS — `test_a_report_citing_an_ungathered_call_goes_back_to_the_model`, `test_the_report_must_be_the_last_call_of_its_step` |
| B9 | Session: a probe turn that answers in free text gets exactly one reminder | work-loop test | PASS — `test_a_probe_turn_answering_in_free_text_is_reminded_once`; mutation (drop the reminder) fails |
| B10 | CLI: `tamoz investigate --json` prints a schema-valid report; `tamoz probes` lists and validates without starting a server | CLI tests | PASS — `agent_cli_investigate_test` (`--json` report over the real MCP test server, exit 0; `tamoz probes` and `--json` list and validate with a nonexistent server command) |

## C. Evaluation (measurement plan 16)

| # | Property | Check | Status |
|---|---|---|---|
| C1 | A deterministic fixture MCP server (test-only) serves the corpus data | eval test | OPEN |
| C2 | Corpus has resolvable cells (one probe settles it) and unresolvable cells (correct = abstain after investigating), authored as data | fixture files | OPEN |
| C3 | Controls discriminate offline: `null` fails the resolvable cells; `adversary` (fabricates the datum, or cites an ungathered tool) is caught; `oracle` passes | eval test | OPEN |
| C4 | Grader reports investigation success rate, fabrication rate and probe precision, each with an interval | eval test | OPEN |
| C5 | One real-model run (`script/investigation_real_run`, `repeat>=2, seeds>=4`) against the fixture MCP server, reported with its n and interval, labelled as a real-model result | run artifact | OPEN |

## D. Gates

| # | Gate | Check | Status |
|---|---|---|---|
| D1 | `rake ci` green | command output | OPEN |
| D2 | `rake ci_full` green in both locales (WP3 touches MCP) | command output | OPEN |
| D3 | RuboCop: no new offense in any touched file | `bundle exec rubocop <files>` vs `git show HEAD:<file>` | OPEN |
| D4 | enola: `diff_snapshot` against the WP0 baseline shows no new cycle, layer violation or unintended coupling | enola output | OPEN |
| D5 | Reek: `rake quality:reek` is already red on HEAD (stale baseline, 60+ files; proven before this branch). Graded instead: new and changed production files carry no `BooleanParameter`, `ControlParameter` or `LongParameterList` smell, and their count is in line with sibling files | `reek <files>` | OPEN |

## E. Simplicity and standards

| # | Property | Check | Status |
|---|---|---|---|
| E1 | No new gem; `tamoz-stream` does not require capabilities code | `git diff --stat`, gemspecs | OPEN |
| E2 | No new episode graph node or branch; changed nodes bump their node `version:` | diff of `episode_graph.rb` | PASS — no node or branch added; `build_frame` 2, `validate` 3, `execute_tool` 2, `rebuild_frame` 2 |
| E3 | No domain literal in Ruby (probe data only in operator config and test fixtures) | review | OPEN |
| E4 | No compatibility shim, no v2/v3 tolerance code | review | OPEN |
| E5 | Comments follow `AGENTS.md` (none by default, one or two lines of "why" at most) | review | OPEN |
| E6 | Every package reviewed by a fresh subagent; every critical and high finding fixed before its commit | review log below | OPEN |
| E7 | New files mode 644 (scripts 755) | `git ls-files -s` | OPEN |

## F. Honesty and docs

| # | Property | Check | Status |
|---|---|---|---|
| F1 | Reports distinguish plumbing tests from real-model results; nothing scripted is described as intelligence | review of docs and final report | OPEN |
| F2 | PLAN.md and README.md match what was built (deviations recorded) | review | OPEN |
| F3 | Lessons learned are recorded in `AGENTS.md` or `.agent/rules/` in the change that taught them | review | OPEN |

## Review log

| Package | Reviewer findings (critical/high) | Resolution | Commit |
|---|---|---|---|
| WP0 plan | 1 critical (probe calls hit the `local_execute` approval fallback), 4 high (Go/Tamoz stream-tool names never match; model budget runs out before the tool budget; repair-path reuse could loop; bar gaps), 7 medium, 7 low | All folded into PLAN §3 and README R5, R6, R10, R13; new bar items A12, A13, B2b–B2e, B4b, B4c, B6b; E2 and D5 corrected | this commit |
| WP1 probes | 2 high (private-key body survived the scrub; a non-succeeded MCP outcome crashed an episode probe), 6 medium (empty targets, database-server argument drop, structured results lost, backing tool not checked against the catalog, test gaps, reek), 8 low | All fixed: `Tamoz::Core.scrub_secrets` (also used by the work loop and MCP payloads), non-success → `probe_failed` result, catalog/load checks, structured text, plain wrapper class (no delegation), cap includes the mark, `probes:catalog` digest key, probes-without-MCP refused; tests added and mutation-checked. Deferred to WP4: probe descriptions on the legacy planning surface | WP1 commit |
| WP2 episode kernel | 2 high (cancellation/deadline swallowed into tool results once context is passed; an ungranted tool name failed the episode), 3 medium (multibyte summary cut; Hash#inspect text for evidence results; tests not discriminating), 6 low | Fixed: context passed to the host; evidence cancellation/deadline raise `Tamoz::CancelledError`/`TimeoutError` (never tool results); ungranted names → `not_granted` entries; `scrub` after summary slices; hash results journaled as JSON; FINAL directive under its own `budget_directive` key; `Tooling` value object; blank purpose refused; D-7 comment updated; tests mutation-checked | WP2 commit |
| WP3 stream + worker | 2 high (probe calls unsafe under concurrent episodes over one stdio server; a partial time range crashed the episode, and Go never sends one), 5 medium (catalog digest checked too late; probes ignored cancellation/deadline; B6 not proven; `--runtime-dir` without probes silently ignored; half of B5 untested), 6 low | Fixed: per-server lock; window only when both bounds are ordered (Go follow-up G4 recorded); digest and shape checked at admission; empty catalog grants nothing; cancellation/deadline raise; launcher exits 2 without probes and on a bad runtime dir; budget count from state; B6 narrowed honestly; lifecycle semantics and the manifest gap recorded in PLAN | WP3 commit |
| WP4 session + CLI | 2 high (prompt text hardcoded in Ruby and new prompts unpinned: red gate; `report_findings` could end a turn that changed files as satisfied), 1 medium (`investigate` not held read-only), test gaps, 8 low | Fixed: labels moved to a pinned prompt file; the report is offered only on read-only turns and only as the last call of a step; `investigate` refuses `--allow-changes` and `--profile`; approval wildcard tests; header pinned from HEAD; chat surface test; comment placement; clearer messages | WP4 commit |

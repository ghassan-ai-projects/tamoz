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
| A1 | I1 — a probe whose backing tool is not in `read_only_tools` does not load; nor does an unknown free type, a name outside `probe_`, a duplicate, or an unknown placeholder | unit test, mutation: drop the `read_only_tools` check | OPEN |
| A2 | I2 — an episode probe that the local catalog declares but the wire catalog does not grant is refused | unit test, mutation: drop the grant check | OPEN |
| A3 | I3 — a model-supplied pinned or unknown argument is refused; an unresolved placeholder is a refusal, not a call | unit test, mutation: merge instead of refuse | OPEN |
| A4 | I4 — free slots enforce type and bounds; results over `max_result_bytes` are cut and marked `truncated` | unit tests | OPEN |
| A5 | I5 — episode tool calls replay from the journal; a crash between slot 1 and 2 of a three-request turn re-executes nothing already done; a crash *during* a slot re-runs that slot (idempotent) | graph test over the real checkpointer | OPEN |
| A6 | I6 — tool results appear only in the user section, fenced and attributed | frame test | OPEN |
| A7 | I7 — a secret-shaped value in a probe result never reaches the frame, the journal or the report | unit test | OPEN |
| A8 | I8 — an episode citing an ungathered tool id is refused; a report citing an ungathered call id is refused | unit tests, mutation: drop the check | OPEN |
| A9 | I9 — no mutating capability is reachable in an investigation turn; `report_findings` executes nothing | work-loop test | OPEN |
| A10 | `sql_select` refuses writes and multi-statements (reusing `GovernedDatabaseSource`) | unit test | OPEN |
| A11 | Gap K — a server that backs a probe exposes no raw tool on the capability surface | unit test | OPEN |
| A12 | Error, refusal and `budget_spent` tool entries are not citable (episode) and failed probe calls are not citable (report) | unit tests | OPEN |
| A13 | Approval: a `probe_*` call is `allow` under `base` and `plan`; an unlisted MCP tool still asks; the verdict comes only from policy data | approval engine test | OPEN |

## B. Function — the capability works end to end (plumbing, scripted model)

These run the real graphs with a scripted provider. They prove plumbing, never
intelligence.

| # | Property | Check | Status |
|---|---|---|---|
| B1 | Episode: a snapshot that cannot settle the diagnosis → tool request with `purpose` → probe result in the next frame → a decision citing `tool:0` | graph test through `EpisodeRunner` with a probe host | OPEN |
| B2 | Episode: tools spent → FINAL directive → terminal `unknown` with `evidence_gaps`, not a failure | graph test | OPEN |
| B2b | Episode: one model call left → FINAL directive; the same holds when the model budget runs out before the tool budget | graph test | OPEN |
| B2c | Episode: a tool turn after the FINAL directive ends typed as budget-exhausted (the loop terminates) | graph test | OPEN |
| B2d | Episode: an MCP failure or SQL refusal inside a probe becomes an `is_error` entry and the episode still decides | graph test | OPEN |
| B2e | Episode: the parser requires `purpose` and caps `evidence_gaps` at 8 | parser test | OPEN |
| B3 | Episode: three requests in one document → three journaled slots, in order | graph test | OPEN |
| B4 | Episode: no tool surface → frame bytes identical to before this change | frame digest pinned from HEAD before WP2 edits | OPEN |
| B4b | Episode: a wire catalog built the way Go's `buildTools` builds it (`evidence_get`, `probe_*`) yields a surface with both | host test | OPEN |
| B4c | Episode: a same-config redelivery succeeds; a redelivery after the probe catalog changed is refused | runner test | OPEN |
| B5 | Episode: every dispatched tool call emits one `ToolLifecycle` event with `execution_started`; `budget_spent` entries emit none and are not counted | stream test | OPEN |
| B6 | Worker: `--runtime-dir` builds the probe host; supervisors close on shutdown | worker test | OPEN |
| B6b | Session: with probes off, the work header is byte-identical to before this change | header digest test | OPEN |
| B7 | Session: a work turn sees probe tools, calls one, and ends with a valid `report_findings`; the answer is the rendered report | work-loop test | OPEN |
| B8 | Session: an invalid report is returned to the model as a tool error and repaired | work-loop test | OPEN |
| B9 | Session: a probe turn that answers in free text gets exactly one reminder | work-loop test | OPEN |
| B10 | CLI: `tamoz investigate --json` prints a schema-valid report; `tamoz probes` lists and validates without starting a server | CLI tests | OPEN |

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
| E2 | No new episode graph node or branch; changed nodes bump their node `version:` | diff of `episode_graph.rb` | OPEN |
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

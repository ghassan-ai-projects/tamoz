# Status — coding harness

Resume point for any session. Updated 2026-09-23.

| WP | State | Notes |
|---|---|---|
| WP0 contracts | done | Decisions D1–D6 taken as recommended (GOAL.md). Checkpoints store full state per node, so work channels hold refs only. |
| WP1 transport | done, reviewed | `EpisodeModelTransport#converse` (tool calls, raw provider usage, `context_window_exceeded`), `ConversationProjection`, `context_window` from the profile role or `TAMOZ_CONTEXT_WINDOW`. Refuses the witness gateway. |
| WP2 tamoz-context-engine | done, reviewed | Header/series, surface (text and tool calls by ref), spill, pruner, compaction, meter, usage, policy, trace + verifier. |
| WP3 tools | done, reviewed | `glob` (fnmatch over a workspace walk), regex `search_text` with a timeout, ranged `read_file` (capped), JSON schemas, `CheckReceipt#shaped`. |
| WP4 tamoz-harness | done, reviewed | Prompt pack (files, digest-pinned), persona/preferences, project guidance, plan document, tool calls, loop policy, finish, handoff. |
| WP5 work loop | done, reviewed | Graph version 5: `work_step → work_gate → work_execute → work_observe`. |
| WP6 CLI + chat | done, reviewed | `tamoz code`, `--guidance FILE`, `--work-routing` for worker/chat (chat surface). A work thread's surface, guidance and persona are pinned in `<session-dir>/<thread>.harness.json` at its first turn; `code` refuses a thread that is not a work thread. |
| WP7 trace | done, reviewed | Per-request trace in state; `script/context_trace SESSION_DIR [THREAD]`. |
| WP8 eval offline | done, reviewed | Packs: `rename_across`, `multi_implement`, `registry_swap` (medium), `backlog`, `planted_constraint` (long), `guidance_convention`, `guidance_injection`. Adapters `tamoz-code`, `tamoz-code-small`, `tamoz-code-noguide`. `rake agenteval:prove`: 38 scenarios valid, controls hold on 190 cells. |
| WP9 eval real | **blocked** | DeepSeek reports `Insufficient Balance` (`/user/balance`: `is_available: false`). Everything is ready: `rake agenteval:harness:all` (it refuses to start while the balance is empty). |
| FC0–FC9 file context | **in progress** | [FILE-CONTEXT.md](FILE-CONTEXT.md). Decisions F1–F8 taken as recommended (GOAL.md). FC11 is dropped (unreachable, measured) — GOAL.md records why. Round tracker below; GOAL.md's table governs if they disagree. |

## Phase 2 round tracker

**Real-model route blockers (both owner-visible; neither is a code defect).**

1. **DeepSeek direct is unfunded.** `GET https://api.deepseek.com/user/balance` returns
   `is_available: false` (`total_balance: -0.00`). The key is valid and `deepseek-flash` /
   `deepseek-v4-pro` are served at a documented 1,048,576-token window.
2. **OpenRouter's key is expired.** `GET https://openrouter.ai/api/v1/models` with the key from
   `.env` returns `401 API key expired`. The public listing (no key) still gives the windows
   recorded in `gems/tamoz-agent-kernel/data/model_windows.yml`, so FC1's data is verified even
   though a call is not possible.

`rake agenteval:harness:all` checks the selected route and aborts with the reason before spending
anything; `AGENTEVAL_PROVIDER=deepseek AGENTEVAL_MODEL=deepseek-flash` switches routes once
either is unblocked. Nothing in FC1–FC8 depends on a funded account.


Mirrors GOAL.md's authoritative table. A round is "done" when: its tests were **red at the parent
commit** (sha and failure output recorded here), the round's gates pass, both reviewers' findings are
addressed or recorded, and its commit exists. "A commit exists" alone is not done.

**Known-red prerequisites (both pre-existing; neither is caused by phase 2).**

1. **`stream:proto:check` cannot run on this host.** `grpc-tools` 1.83.0 ships only
   `x86_64-macos` / `x86_64-linux` protoc binaries; this host is `arm64`, so the exec dies with
   `Errno::EBADARCH`. Everything before it in `rake ci` passes. Rounds run the exact substituted
   gate in GOAL.md §Loop. No phase-2 change touches `tamoz-stream`.
2. **`test/packaging_test.rb` is red (A3, A4).** The scorecard install list in
   `test/packaging_test.rb:93` names neither phase-1 gem, so `tamoz-agent-session`'s declared
   dependency on `tamoz-harness` cannot resolve in the isolated `GEM_HOME`:
   `Could not find 'tamoz-harness' (= 0.1.0.alpha.1) among 114 total gem(s)`. This is a **phase-1
   regression** that `rake ci` never exposed because packaging is in `SERIAL_TESTS`. R1 fixes it and
   A3/A4 flip back to met. Until then, QUALITY_BAR's A3/A4 read "not met".

| Round | Packages | Red-at-parent proof | F rows → met | State | Commit |
|---|---|---|---|---|---|
| R0 | Plan, goal, quality bar, eval plan; evidence and instrument | n/a (documents) | — | done | R0 |
| R1 | FC1 window (pinned as data) · restore A3/A4 | recorded below | F1, A3, A4 | done | R1 |
| R2 | R1 reviewer findings; FC2 deferred | recorded | F1 re-established | done | R2 |
| R7 | FC2/F7: the patch preview carries three context lines either side of a hunk | five assertions migrated | F7 | done | R7 |
| R9 | FC2 (tools half): the ranged-read byte budget | suite green | F2 (part) | partial | R9 |
| R3 | FC3 observation ledger, gate pinning, read window, dedup, outside-change notice | pending | F3, F4, F5, F6, F17 | pending | — |
| R4 | FC7 superseded-read prune (after its producer) | pending | F12 | pending | — |
| R5 | FC5 change ledger + diffstat · FC4 references + guidance digests/notice | pending | F9, F10 | pending | — |
| R6 | FC6 operator rewind | pending | F11 | pending | — |
| R7 | FC8 offline eval: scripted work-loop tests, genuine controls, positive loop-level cell, scenario→trace join key | pending | F14 | pending | — |
| R8 | FC9 wire `ctx-window`, `ctx-dedup`, `ctx-fresh`, `ctx-mention` and `ctx-positive` arms — prepared, not run | pending | F15 | pending | — |

Graph version: bumped in every round marked "adds a graph channel" in GOAL.md (R3, R5, R6). No
session crosses a round; there is no compatibility path for an old graph version.


### R1 evidence (parent `f6a0695c`)

Red at the parent, before the implementation:

```
$ ruby -Itest test/model_windows_test.rb
test/model_windows_test.rb:8:in `<class:ModelWindowsTest>': uninitialized constant
Tamoz::Agent::ModelWindows (NameError)

$ ruby -Itest test/packaging_test.rb        # A3, red since phase 1
Could not find 'tamoz-harness' (= 0.1.0.alpha.1) among 114 total gem(s) (Gem::MissingSpecError)
15 runs, 629 assertions, 1 failures, 0 errors
```

Green after R1:

```
$ ruby -Itest test/model_windows_test.rb
8 runs, 75 assertions, 0 failures, 0 errors, 0 skips

$ ruby -Itest test/packaging_test.rb
15 runs, 636 assertions, 0 failures, 0 errors, 0 skips

$ rake ci          # design:validate, adr:validate, syntax, test_parallel
261 files across 9 workers + 0 serial — all passed
(aborts at stream:proto:check — known-red prerequisite 1)

$ rake quality:architecture     exit 0
$ bundle exec rubocop --cache-root .rubocop-cache <changed ruby files>
0 offenses in the two new files; model_client_factory.rb 114 before and 114 after
```

Reviewers: the two R1 reviewers were launched against this change set before the commit; their
reports had not landed when it was made. **Deviation from the round rule, recorded:** their
findings are addressed in R2's commit, and R2 does not start until they are.



### R2 — what landed, and what did not

R1's reviewer pair found two high-severity defects in R1 itself, both fixed here:

1. **F1 was not actually met.** The eval adapter pinned the window as `TAMOZ_CONTEXT_WINDOW` — the
   *override* — so `ModelWindows.window` was bypassed on the eval route, and the test compared two
   hand-maintained literals. The adapter no longer sets a window (only an explicit
   `AGENTEVAL_CONTEXT_WINDOW` travels), and the test now asserts the adapter names a *recorded*
   route, does not override it, and that the recorded value is the verified number. A degenerate
   "keep two literals equal, fake the source" implementation no longer passes.
2. **The real-run guard was vacuous.** It probed `/api/v1/models`, which is public and answers 200
   for a bogus key. It now authenticates against `/api/v1/key` and branches on the HTTP status.

Also: the duplicated eval route and the dead `max_output_tokens` / `eval_route` readers are gone
("pin authority, never re-derive it"); `model_client_factory` requires what it uses; the paired
`capability` arm now puts both adapters on one route; and the stale A3/A4, evidence-filename and
table-row defects are corrected. New RuboCop offenses: none — `patch_preparation` 0 (parent 0),
`dsh_context_survey` 15 → 1 (the remainder is the pre-existing long regex line).

**FC2 was implemented and then reverted, deliberately.** `render_diff` gained three context lines
either side of a hunk and `test/tools_coding_surface_test.rb` gained a green test for it
(13 runs, 40 assertions), but five existing assertions in `test/agent_toolbox_test.rb` encode the
**old** preview bytes and must be migrated to the new format first. Committing a red tree to claim
F7 was not acceptable, so the change is reverted and R2 stops here. F2 and F7 stay open; the next
round migrates those assertions and lands both.



### R3 — F7's assertion migration, precisely

F7's implementation is small and its own test passes; what blocks it is migrating **five** existing
preview assertions in `test/agent_toolbox_test.rb`, which pin the whole preview string and
therefore the previously-absent context lines. They are not one shape:

| Site | Shape | Migration |
|---|---|---|
| `:87` (`answer.rb`), `:164` (`values.rb`) | `assert_equal("<full preview>", toolbox.preview(...))` | `assert_includes toolbox.preview(...), "<hunk + change>"` |
| `:137` (`NAME = "héllo"`) | same, but the expected interpolates `#{before}` / `#{after}` **and** the call carries a trailing argument | `assert_includes` with the interpolated literal retained |
| `:532`, `:587` (compound patches) | `assert_equal([hunk1, hunk2], preview)` — an **array**, one entry per replacement | `expected.each { |hunk| assert_includes preview, hunk }` |

A regex that assumes one string per assertion converts 2 of 5 and must be run against all three
shapes. Two attempts have reverted rather than commit a red tree; the implementation and the new
property test are written and verified in isolation (13 runs, 40 assertions, 0 failures).


**Third attempt (R4), and the new datum.** Wrapping the single shared call —
`toolbox.preview('apply_patch', arguments)` → a helper that drops context lines before comparing —
is shape-agnostic and does convert every site, yet the same five assertions still fail. So the
context lines are **not** the only difference: the compound cases (`:532`, `:587`) compare an
**array of hunks** against the preview value, which `render_diff` returns as a **joined string**.
The next attempt must not reach for a string-level transformation again; it must open each site,
establish what its second argument actually is, and rewrite that assertion's comparison. That is a
read-then-edit job on five assertions, not a regex.


### R5 — a second phase-1 regression, in the serial suites

Three of the five preview assertions are migrated (single-hunk sites; the suite is green at
63 runs / 337 assertions). The remaining two go with F7 itself.

While verifying, `rake test_parallel` failed and the cause is **not** this round's change:
`test/requirements_manifest_test.rb` fails with the **same three failures on the clean parent
tree**. The diff is about `tamoz-context-engine` and `tamoz-harness` public API rows — the
**phase-1 gems** — so R0/R1 added public API and the pinned manifests were never regenerated.
Siblings (`test/agent_scorecard_test.rb`, `test/benchmark_holdout_test.rb`,
`test/public_api_test.rb`) fail the same way.

This is the **same class of gap as the packaging failure**: those suites live in `SERIAL_TESTS`,
which `rake ci` / `test_fast` never runs, so a round can pass the everyday gate with them red.
`GOAL.md`'s gate block was corrected in R1 for packaging; the fix here is to run the pinned
generators — `script/generate_requirements_manifest`, the agent scorecard and the holdout
manifest — as part of any round that adds public API, and to add them to every round's gate.
Recorded as known-red prerequisite **3** pending that repair.


**Known-red 3 is blocked in the generator, not merely un-run.** Running it does not repair the
manifests; it raises:

```
$ ruby script/generate_requirements_manifest
script/generate_requirements_manifest:1006:in `row': CLI-code: a release-blocking row without
evidence must state which work package closes it (EvidenceError)
    from script/generate_requirements_manifest:1111:in `block in <main>'
```

So the manifest enforces its own rule: a release-blocking row with no evidence must name the work
package that closes it. The offending row is a **phase-2** row (`CLI-code`) whose evidence does not
exist yet — which is why R0/R1 could add public API without the manifest changing, and why
regenerating now cannot succeed. The repair is to mark the phase-2 release-blocking rows with their
closing work package (FC1…FC8) in whatever source supplies them, then regenerate. Its partial
output was reverted rather than committed. `test/requirements_manifest_test.rb`,
`test/agent_scorecard_test.rb`, `test/benchmark_holdout_test.rb` and `test/public_api_test.rb` stay
red until that is done — all in the serial suites `rake ci` skips.


### R7 — F7 landed

`render_diff` emits DSH's three context lines either side of a hunk, `DIFF_CONTEXT = 3`, whole
lines only. Its property test pins the rule exactly (`test/tools_coding_surface_test.rb`), and the
five pre-existing preview assertions in `test/agent_toolbox_test.rb` are migrated: the single-hunk
sites assert the hunk header and the change separately (context can precede the change, so
`"@@ …\n-old\n+new"` is not a contiguous substring), and the two compound sites assert one hunk per
replacement. Both changes are recorded in the same commit.

Evidence: `agent_toolbox_test` 63 runs / 357 assertions / 0 failures (was 5 failures);
`tools_coding_surface_test` 13 / 34 / 0; `work_loop_test` 23 / 53 / 0; `rake test_fast`
261 files all passed; RuboCop 0 offenses in the three changed files.

Still open in FC2: the read byte cap and the `not_observed` / `stale_file` error codes (F2).


### R8 — FC2's `stale_file` needs one classification decision first (no code this round)

F2's remaining items are the read byte cap and the `not_observed` / `stale_file` codes. The codes
look like a one-line change, but the repo already draws the line they must fall on, and the plan
does not say which side it is on.

`gems/tamoz-core/lib/tamoz/core/tool_error.rb`:

- `ToolPolicyError` — "Always terminal — a security rejection must never become a retryable value
  the planner can iterate against." Its list includes *"a workspace that no longer matches the
  approved before-state"*, which is the stale-digest case, and it is what
  `PatchPreparation#verify_digest` raises today (a D-8 decision: the digest the operator approved
  is a claim about existing bytes).
- `ToolArgumentError` — `repairable? == true`, "re-read the workspace and plan different arguments",
  whose list includes *"a stale digest"* as an argument-level failure.

So "stale" means two different things and both already have a home:

| Situation | Who chose the digest | Correct class | Model is told |
|---|---|---|---|
| The gate pinned the ledger's version and the file moved | the ledger | `ToolPolicyError` (terminal) — the approval's basis is gone | stop and re-plan |
| The model supplied a digest and it does not match | the model | `ToolArgumentError` (repairable) | re-read, then retry |

DSH's `FS_STALE_VERSION` is the second kind — it appends "re-read the file, then retry" — and the
plan's §3.1/F3 describes the same remedy. That is compatible with D-8 only if the gate's pinning
means the *ledger* (not the model) is the chooser, in which case a moved file voids the approval
and the refusal is terminal; the plan currently says both ("re-read the file, then retry" **and**
the gate pins the ledger's value).

This is a one-decision unblock, not a design problem: pick which of the two `stale_file` is, and
the implementation is a code on the class plus the remedy text. It gates F2 and FC3, so it is
recorded here rather than discovered mid-implementation. **Owner input wanted** — it changes
whether a stale edit ends a turn or invites a retry.


### R9 — the read byte budget (F2, tools half)

`ReadOperations::MAX_RANGE_BYTES = 50 * 1024` — the documented read cap, the same number DSH's
read tool uses — now bounds one ranged read's output, where it previously used the whole-file limit
(`Toolbox::MAX_FILE_BYTES`, 64 KiB). A ranged read is a window, and the existing footer already
says where to continue. The unranged path is untouched, so the pipeline and every other caller keep
today's behaviour, as F2 requires; the work loop applies the rest of the read policy at its gate
(FC3).

Evidence: `tools_coding_surface_test` 14 runs / 40 assertions / 0 failures with the new case
(a 400-line file of 200-character lines stays inside the budget and reports
`... truncated; continue with offset N`); `rake test_fast` 261 files all passed; RuboCop clean in
both changed files.

**Still open in FC2:** the `not_observed` / `stale_file` codes, blocked on the classification
decision recorded in R8.

## Verified against DSH, 2026-09-23

`script/dsh_context_survey` reads every log under `~/.dsh/sessions` and reports what DSH's context
machinery actually did. Full table and worked example: [FILE-CONTEXT.md](FILE-CONTEXT.md) §0.2–§0.3.

| | |
|---|---|
| 1,000,000-token route (`deepseek-v4.1-flash`) | 85 sessions, 7,779 steps, **0 prunes, 0 compactions**, widest prompt 598,597 tokens, 94.0% cache share across the route |
| 262,144-token routes | 666 sessions, 27,948 steps, 249 prunes, 32 compactions, prompt ceiling at the 0.80 trigger (209,877 and 213,223) |
| Surface replacements, whole corpus | 280: 249 tool-result prunes + 31 compaction checkpoints. Zero from staleness; zero rewrites of earlier messages |
| Runtime-context snapshots | 797 appended, 0 "no longer apply" markers, at most 6 in a session |
| Instruction injections (`Context injection` rows) | 812 messages; 830 baseline changes against 40 dynamic: 20 nested-scope discoveries, 19 `replace`, 1 `remove`. All appends. |
| What this corrected | "DSH never compacts" was wrong: it compacts whenever the route's window is 256K. "DSH removes context dynamically" is the prefix cache, not removal. "DSH does not re-read AGENTS.md" was wrong too: it appends a changed/removed notice. |
| What it changed in the plan | FC1 (the window) is the first and largest lever; the spill and read budgets were raised toward DSH’s deployed values (F4, F6); guidance files join the freshness pass (F8, §3.11). FC10 and FC11 were planned and then **dropped on measurement** — both were unreachable in the current loop (GOAL.md). |

## Deviations from the plan (recorded, deliberate)

- Gem `tamoz-context-engine` / `Tamoz::ContextEngine`, not `tamoz-context`: `Tamoz::Context` is the run context in tamoz-core.
- Surface entry kinds: `runtime guidance user assistant tool_result system_update checkpoint`; a pruned result is a
  `tool_result` replacement with `source: prune`, a checkpoint `source: compaction`, a reset `source: reset`.
- D6 "then hand off" is a **reset inside the turn**: the second pressure event replaces the unpinned history with the
  handoff note (plan included) and continues; after two resets the turn ends `handed_off`. A later turn on the same
  thread opens a fresh surface seeded with the previous answer and the accepted plan (each turn is a new execution).
- D3 (read-only commands) needs no new tool: a configured check with `read_only` safety is a declared read-only argv.
- Plan review uses a harness prompt (`prompts/plan_review.md`) with the existing `Deliberation.parse_review`, not
  `REVIEW_SYSTEM`: the pipeline reviewer demands step-level tool arguments a living plan does not have.
- Only the workspace-root guidance files are read (no directory chain); the wrapper carries `sources` and `digest`.
- Required exact strings for a summary are the paths passed to mutating tools in the span.
- Model calls in the loop are journaled `:idempotent` (a model call changes nothing outside).
- The work loop exposes toolbox tools and the two harness tools; MCP capabilities are not on its surface yet.
- Preferences come from the harness settings (CLI/worker), not a profile `preferences:` key yet.
- `/think` and `/verbose` recorded between turns reach the next turn as in-history updates.
- EVAL §5.3's prune-only (`mask`) arm is not wired: it needs a context-policy override on the CLI.
- No observability catalog signals: the trace lives in session state and is read by `script/context_trace`.
- Two gemspecs were added to `.rubocop_todo.yml` `Gemspec/RequiredRubyVersion`, the same false positive every gemspec carries (the helper sets the version).
- Enola: no new cycle and no layer violation; the pre-existing 0.40-confidence "coupled cluster" finding changed membership (comms/evals), not caused by the new gems.

## Known gaps in the eval (open, surfaced — not hidden)

- **EVAL §3 controls not built:** `prefix_breaker` exists only as the trace verifier's unit test
  (`Trace.undeclared_changes`); `lossy_compactor`, `fabricating_compactor`, `looper`, `scope_creeper` and
  `guidance_obeyer` are not agenteval controls yet. The existing adversary control proves the injection gate on
  modifier-planted instructions, not on `guidance_injection`.
- **The instructions arm does not isolate the guidance channel:** in `tamoz-code-noguide` the `AGENTS.md` file is
  still in the workspace and the model may read it. The arm measures "given the guidance" against "may find it".
- **Fidelity arms are 64K vs 12K windows**, not the four EVAL §5.3 arms (full / mask / dsh / fifo). Whether a
  `long` cell actually compacted is read from its trace (`series_reason: series` / replacement records); cells
  with no compaction do not exercise compaction.
- **No router `coding_work` class:** chat reaches the work loop only when the worker runs with `--work-routing`.
- The cache arm runs 10 turns (5 seeds × 2 tasks), as EVAL §5.1 asks.

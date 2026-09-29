# Subagents — status

Bar: [QUALITY_BAR.md](QUALITY_BAR.md). Plan: [PLAN.md](PLAN.md). Parent commit of the work: `0cd6a0ab`
(branch `improve-sub-agents`). Owner decisions D1–D8 are taken as accepted: the owner asked for the plan to be
implemented as written (2026-09-29) and to commit each round until the bar is met.

## Rows

`pending` = the test asserts the target and skips with a count. `met` = a hard test. Rows flip only when code
changes; `SubagentSpec::MET` in `test/support/subagent_spec.rb` is the record.

| Row | Status | Evidence |
|---|---|---|
| A4 B1–B9 (incl. B4.report) C2–C7 D1–D4 E1 E2 | **met** (R1–R5) | `test/subagent_spec_test.rb`, `test/subagent_durability_test.rb`, `test/harness_prompt_pack_test.rb` |
| C1 | **met** (R3) | `test/subagent_kill_test.rb` (slow lane): real SIGKILL, recovery replays recorded child calls |
| A1–A3, A5, A6 | met | gates below; enola: no new cycle or layer violation; no migration, table, thread or effect type; `ChildTask`/`delegate_child_task` untouched |
| F1–F4 | **met** (R6) | `rake agenteval:subagents:prove`; `test/agenteval_subagent_pack_test.rb` (slow lane): nine controls each trip only their own gate, blinded graders are caught, `Record.read` over a real session store |
| G0–G7 | not run | R7 (real-model run, paid) |

## R0 — red at the parent (`0cd6a0ab`)

- 24 rows pending, 0 failures, 0 errors; 3 hard controls green (scripted-team routing, tree digest moves, B7 disabled
  half). A reviewer sub-agent found 15 issues (three rows could not go green as written, four were partly vacuous);
  all were fixed before this commit: same-root reference runs for C1/C2, `max_tool_calls` 80 for explore so E1's N=50 is
  reachable, `update_plan` in B6's scripted child so a leaked write tool would actually write, an approval-verdict half
  in B8, memory tools present in the parent in B1, a middle-of-the-answer recall in D1, `GAP_ERRORS` narrowed to
  assertions and Tamoz refusals, C1 split into the slow lane with stderr capture and a timeout.
- Parent request header at `0cd6a0ab` for the fixture configuration: tools
  `64bd09e189c92c3b800eed54cb8f56435393e9d4ea9be50c840ff5bef5690feb`, system
  `6eeda4bcba4edccc92422ac2caadb8ca546dd70042f3501ed954ec986c22b367` (the pair `test/work_loop_investigation_test.rb`
  pins). B7's disabled half asserts it now.
- enola baseline pinned before the first edit (`set_baseline`, 15,087 facts at HEAD).

## Gates on this host

`rake ci` runs design, ADR, syntax and the sharded suite (all green), then aborts at `stream:proto:check`: the only
macOS `protoc` in `grpc-tools` is x86_64 and this host is arm64 (`Bad CPU type in executable`), so it fails at
`0cd6a0ab` too and no change here touches a `.proto`. Each round runs the rest by hand: `rake test_fast`,
`rake quality:architecture` (enola check), `rubocop` and `reek` on changed files (zero offenses; reek no worse than
HEAD), `rake docs:check`. The repo-wide `rubocop` gate is red at `0cd6a0ab` as well (4,624 offenses, all under
`test/`; unchanged by this work), so per-file parity is what each round proves.

## Deviations from DESIGN.md (each simplifies or reconciles; recorded so the owner can veto)

1. **Clean opening needs no `SessionWork` change.** The child is built with `transcript_reader: nil`,
   `previous_turn_reader: nil`, `memory: nil`; `SessionPlanningContext#conversation_transcript` already returns `[]`
   without a reader. DESIGN §3's `SessionWork#intake` row is not needed; B3 proves the property.
2. **No wall clock in the result text** (DESIGN §5, amended): a re-run gate node must hand the parent the same text as
   an uncrashed run. Seconds live in the `subagent_finished` event.
3. **`recall_output` stays in the child's header** (DESIGN §4 and bar B1, amended).
4. **`Read:` shows at most 20 paths, then `(+N more)`** (DESIGN §5 and bar D2, amended).
5. **Instruction-only sections.** A subagent's system prompt keeps `identity` and `tools` and drops `operating`,
   `editing`, `finish` (plan-first, patching and check rules that contradict a read-only run); the role prompt rides the
   persona section. The change is confined to the `:subagent` surface, so B7 holds.
6. **Pack controls and graders are built in R6, not R0.** They read the trace events R2 defines.
7. **Explore's `max_tool_calls` is 80, not 40** (DESIGN §4 amended): bar E1 reads 50 files.
8. **`TurnUsage` is specified in DESIGN §9** (E2's consumer API); C1 lives in `test/subagent_kill_test.rb`.
9. **`ci_full` also runs for R3** (PLAN amended): the kill test is in the slow lane, which `rake ci` skips.

## Rounds

| Round | State |
|---|---|
| R0 | done (`2feccdbe`) |
| R1 | done: roles data and loader, `:subagent` surface, `delegate` schema; B9 met, A5 pinned; enola: no new cycle, layer or gem edge |
| R2–R5 | done: `delegate` tool (`WorkDelegation`), child graphs (`SubagentApps`, built only when a plain read is allowed, via the approval engine's `simulate`), per-turn cap, result/spill/trace, `TurnUsage`; subgraph request identity and child-codec recovery (`.agent/rules/subgraphs.md`); a child never raises an approval ask; CLI `--subagents`, runtime-directory `harness.subagents`, worker parity, `tamoz show` (the two observability signals were declared but never emitted; removed after review, DESIGN §9 export left for later) |
| R6–R8 | not started |

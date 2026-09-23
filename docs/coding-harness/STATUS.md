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

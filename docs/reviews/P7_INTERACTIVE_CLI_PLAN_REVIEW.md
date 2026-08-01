# Review — P7 interactive and resumable CLI plan

Subject: `docs/P7_INTERACTIVE_CLI_PLAN.md`
Reviewer stance: adversarial. The plan is treated as a claim to be falsified against the
authoritative inputs and the code in the tree, not as a proposal to be improved.

## Verdict

**Accept.**

All critical and high findings from the initial review have been addressed, and the amended
plan is consistent with the existing durable runner, request inbox, and effect-journal code.
The two previously-required corrections (`tamoz resolve` vocabulary and `clarify` interrupt
preserving the graph digest) have been applied to the plan.

## What is now correct

- **Stream/emitter contract (C-1):** The plan correctly states that `Session#start/resume/continue`
  will accept an emitter and that `DurableRunner` forwards it through `Compiled#execute_durable_request`
  into the run `Context`. `Compiled#execute_durable_request` (lines 631-767) and the executor do
  use `context.cancellation` and `context.emitter`; the emitted values are real
  `Tamoz::StreamPart`s produced by `StreamSink`/`StreamEmitter`. No parallel event source is
  invented.
- **Cancel semantics (C-2):** `tamoz cancel` is now restricted to active/paused executions and
  expressed as a `:redirect` request with a sentinel payload that `intake` routes to `terminal`.
  This matches the inbox state machine in `checkpoint_store.rb:353-448` and the redirect-ready
  reconciliation in `checkpoint_store.rb:575-601`.
- **Bare invocation (H-1):** `tamoz TASK` is consistently one-shot `Runtime`; durability is opt-in.
- **Signal handling (H-4):** The plan now uses a real `Tamoz::CancellationToken` and `cancel!`,
  consistent with `executor.rb:54` and `cancellation_token.rb:53-74`.
- **Redirect description (H-3):** Redirect is now described as an enqueued `:redirect` request that
  `claim_next_request` binds to the active execution, with effect reconciliation before the new
  execution starts.
- **Blocked status (M-4):** `tamoz resume` now surfaces blocked effects and points the user to
  `tamoz resolve` instead of automatically calling `Session#continue`.
- **Queue draining (M-5):** `resume`/`continue` now specify a drain loop after the current request
  finishes terminal.
- **Session-dir defaults (M-1):** XDG-aware, macOS-aware, `0700` directory permissions.
- **Scorecard oracle (M-3):** The `resume_after_kill` oracle is deterministic and explicitly
  tolerates a recovery redirect without weakening the hard-zero claims.

## Previously required corrections (now applied)

### 1. `tamoz resolve` vocabulary aligned with the effect journal

The plan now maps skipped/deny/no answers to `:abandoned`, `failed` to `:failed`, and documents
the subcommand as:

```
tamoz resolve THREAD EFFECT_KEY {succeeded|abandoned|unknown}
```

This matches the human-resolution API, which accepts `:succeeded`, `:failed`, or `:abandoned`
(`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal.rb:630-636`).

### 2. The `clarify` interrupt path preserves P6 session resume

The clarification flow is now implemented inside the existing `deliberate` node with no new
branch target or node, preserving the graph definition digest and keeping P6 sessions resumable
without a checkpoint migration.

## Residual implementation risks (after the above corrections)

1. **Session API extension.** The exact `Session#start/resume/continue` signatures with
   `emitter:`/`context:` and the surrounding `StreamSink`/`EventStream` consumer wiring must be
   proven during implementation. `StreamEmitter` is currently a `private_constant` inside
   `Tamoz::Graph`; the CLI either needs it made public or must use a public streaming seam.
2. **Clarification resume semantics.** Whether implemented inside `deliberate` or as a separate
   node, the implementation must prove that a clarification answer cannot be replayed into an
   infinite loop and that it is correctly threaded into the next planning attempt.
3. **Scorecard history helper.** The oracle assumes a helper that reads `tamoz_requests` from the
   durable adapter. If no public API is added for P7-E, the harness must query the table directly;
   this should be confirmed before the case is implemented.
4. **`intake` versioning.** If `intake` is extended to recognize the cancel sentinel without
   bumping its declared `version: "1"`, the graph digest stays the same while behavior changes.
   This is permitted because no existing P6 checkpoint can contain a cancel payload, but it should
   be noted and ideally versioned.

## Final verdict

**Accept.** The plan is a viable starting point for P7 implementation. All critical and high
findings have been resolved in the design. Residual implementation risks (emitter API wiring,
clarification replay safety, scorecard history helper, and `intake` versioning for the cancel
sentinel) are noted and will be verified during implementation.

# CF04 model/tool effect identity, journal, unknown outcome, and replay — IMPROVE

Row / queue / baseline (commit, date) / analyst / budget

- Row: **CF04** — model/tool effect identity, journal, unknown outcome, and replay.
- Queue: cross-gem flow inventory in `COVERAGE.md`.
- Baseline: branch `audit-15-09`, code commit `582ae55`, 2026-09-15.
- Analyst: coordinator direct read-only review after the standalone cross-flow scan.
- Budget: bounded source review, existing reproduction evidence, and focused contracts; no implementation.

## Scope and source map

| Source | Lines | Boundary role |
|---|---:|---|
| `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` | 33-109, 141-221, 243-328 | common prepare/start/complete/reconcile adapter |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb` | 50-126, 138-175 | durable episode model identity and receipt projection |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb` | 41-143 | durable episode tool identity and result projection |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb` | 19-85, 135-185 | session model/tool effect callers and filesystem reconciler |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal.rb` | 19-177 | SQLite-facing effect protocol and lifecycle façade |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb` | 28-61, 139-249 | identity verification, retry and unknown decisions |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_completion.rb` | 25-180 | receipt persistence, late completion and head transitions |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/effect_reconciler.rb` | 31-225 | evidence reconciliation and human resolution |
| `gems/tamoz-agent/lib/tamoz/agent/runtime/effects_journal.rb` | 30-109, 116-220 | ephemeral in-memory journal implementation |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb` | 37-48, 213-301 | session consumer of effect outcomes |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb` | 88-181 | repairable failure and blocked unknown mapping |
| `test/sqlite_effect_journal_test.rb` | — | durable attempt, late receipt and resolution contracts |
| `test/agent_session_effect_test.rb` | — | session effect and reconciliation contracts |
| `test/agent_runtime_effects_test.rb` | — | one-shot journal parity |
| `test/agent_mcp_capability_source_test.rb` | — | durable capability effect replay contracts |

The common seam is `EffectDispatcher.run`: it derives a durable key or logical
identity, calls the journal's `prepare`, and then either returns a recorded
receipt, reconciles, reports `unknown`/`wait`, or executes exactly one granted
attempt. Model and tool callers use logical keys that bind request bytes,
authority/catalog revisions, stage, slot, iteration and sub-operation. The
SQLite journal persists the head and every attempt; the one-shot runtime uses a
separate in-memory implementation with the same dispatcher contract.

## Behavior path

1. `SessionEffects#model_call`, `EpisodeModelCall`, and `EpisodeToolCall` build
   canonical request projections and logical identities before any provider or
   tool call (`session_effects.rb:19-40`; `episode_model_call.rb:50-85`;
   `episode_tool_call.rb:41-88`).
2. `EffectDispatcher.run` validates the journal/reconciler contract, calls
   `prepare`, then selects `:return`, `:failed`, `:unknown`, `:wait`,
   `:reconcile`, or `:execute` (`effect_dispatcher.rb:33-109`). The SQLite
   preparation path verifies identity and request digest before reusing an
   existing row and grants retries only for read-only/idempotent effects
   (`effect_preparation.rb:139-216`).
3. Execution starts the attempt under its token, calls the operation, and stores
   a typed success, failure, or unknown receipt. Tool and model exceptions are
   serialized with class, safe message, repairability, and model diagnostics
   (`effect_dispatcher.rb:175-221,243-277`).
4. The SQLite completion path persists the attempt receipt and updates the head;
   an older success changes a conflicting head to `reconcile` and retains the
   late receipt (`effect_completion.rb:114-177`). Human reconciliation can
   complete, re-grant a fenced retry for `not_applied`, or leave the effect
   unknown (`effect_reconciler.rb:31-167`).
5. Session consumers map success to bounded observation/effect-receipt evidence,
   repairable failure to the bounded repair loop, and unknown to a terminal
   blocked record (`session_steps.rb:213-301`; `session_evidence.rb:88-181`).
   The one-shot runtime uses the same dispatcher over `EffectsJournal`, whose
   attempt token and terminal receipt checks are in-memory and process-scoped
   (`effects_journal.rb:61-109,116-220`).

## Lens: correctness

Reviewed. Request digests and logical identities are checked before replay, and
terminal receipts are immutable. The focused contracts passed **52 runs / 261
assertions / 0 failures** across the SQLite journal, session effects, runtime
effects, and MCP capability source tests.

The accepted major defect **CF04-REL-01** remains reproducible at the durable
dispatcher seam. When an expired attempt 1 later succeeds after attempt 2 has
recorded a repairable failure, the SQLite head can be human-resolved as
`:failed`. `EffectDispatcher#terminal_attempt` then prefers the historical
success even in the `:failed` branch, returning `status: :failed` with
`attempt_number: 2` but `error: nil` (`effect_dispatcher.rb:91-101,280-283`).
The committed reproduction records `status=:failed reused=true error=nil` and
shows the persisted attempt-2 error was repairable. This is a status/receipt
identity contradiction and bypasses the session repair evidence path. It is
already owned and challenged under CF04/F17; it is not counted a second time.

## Lens: security and authority

Reviewed. `EffectJournalKey` identity is derived from the guarded lease during
preparation, and attempt tokens prevent a stale executor from completing the
current attempt. The dispatcher rejects reconcilable effects without a
reconciler and never retries an unsafe unknown (`effect_dispatcher.rb:69-77,
141-159`).

The adjacent critical **F07-SEC-01** remains open: `EffectReconciler#resolve`
loads by global effect key and updates the head without comparing the row's
thread/namespace to the active writer (`effect_reconciler.rb:171-224`; the
row-scope challenge is in `analyses/cross-thread-effect-resolution.md`). A
thread-B writer can therefore settle thread-A's unknown effect when a shared
adapter is used. The graph/session callers do not add a second row-scope guard;
CF04 carries this boundary finding under the SQLite owner.

## Lens: reliability and durability

Reviewed. Prepare, attempt grant, completion and reconciliation are transactional
SQLite operations; the current attempt budget is capped at three, and an unsafe
expired attempt becomes terminal unknown rather than receiving a blind retry
(`effect_preparation.rb:170-249`; `effect_dispatcher.rb:12-15,141-159`).
Filesystem reconciliation proves before/after bytes from the checkpointed intent
and returns unknown when neither state is proven (`effect_dispatcher.rb:289-314`).

CF04-REL-01 is the material durability gap: the durable history remains intact,
but the dispatcher projects the wrong attempt's fields after a late-success /
current-failure race. The independent challenge `challenge-durable-effects.md`
and F17 re-review uphold the major grade. No new reliability finding was added.

## Lens: observability and evidence

Reviewed. Every terminal attempt stores result/error bytes and digests, effect
key, attempt identity, status and transition evidence. Session observations add
provenance, source id, truncation and output bytes; unknown effects create a
blocked record with explicit operator actions (`session_evidence.rb:30-48,
164-181`).

The CF04 replay defect drops the only typed failure detail at the dispatcher
boundary, so downstream evidence says only `tool effect failed` and cannot
explain why the bounded repair path was skipped. The graph-level ambiguity
signal gap (`F04-OBS-01`) is adjacent and remains owned by the graph row; this
flow does not create another observability ID.

## Lens: scalability and resource bounds

Reviewed. Effect attempts are capped, request/result/error bytes are codec
bounded by the SQLite store, tool/model observations have session byte ceilings,
and MCP/tool projections cap output. The in-memory journal also enforces the
same `MAX_ATTEMPTS` and terminal-status vocabulary (`effects_journal.rb:14-18,
61-109`).

No multi-process effect throughput or long-lived journal-retention measurement
was run. The append-only transition and decision history are bounded per attempt
but have no production retention run in this flow; this remains an evidence
limitation rather than a new finding.

## Lens: maintenance and architecture

Reviewed. The dispatcher is the single common effect seam; durable SQLite and
ephemeral runtime journals implement the same prepare/start/complete contract.
Model and tool callers do not invoke providers or tools outside the dispatcher
in the reviewed paths. The main maintenance risk is the shared
`terminal_attempt` helper serving successful and failed outcomes with different
receipt-selection needs—the precise root cause of CF04-REL-01. The smallest
owner is already identified: status-specific selection in
`EffectDispatcher#resolve_decision`, with the SQLite head/current-attempt data
left intact.

## Tests and contracts

- `ruby -Itest test/sqlite_effect_journal_test.rb` → **9 runs / 37 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/agent_session_effect_test.rb` → **19 runs / 78 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/agent_runtime_effects_test.rb` → **10 runs / 44 assertions / 0 failures / 0 errors / 0 skips**.
- `ruby -Itest test/agent_mcp_capability_source_test.rb` → **14 runs / 102 assertions / 0 failures / 0 errors / 0 skips**.
- The late-success/current-failure reproduction and independent challenge are
  committed under `analyses/failed-effect-resolution-replay.md` and
  `analyses/challenge-durable-effects.md`; no repository scratch was created.
- No real provider or external tool service was used in this bounded review.

## Findings and disposition

No new CF04 finding was added. Existing findings crossing this flow remain:

| Finding | Owner | CF04 disposition |
|---|---|---|
| CF04-REL-01 (also indexed as F17-REL-01) | `EffectDispatcher#resolve_decision` receipt selection | open major; re-verified and upheld by independent challenge |
| F07-SEC-01 | SQLite `EffectReconciler#resolve` row-scope guard | open critical; carried without double-counting |
| F04-OBS-01 | graph stream ambiguity projection | open minor; adjacent graph owner |

## Blind spots

- No new mixed-attempt probe was run in this bounded continuation; the committed
  reproduction and challenge were read and their source path rechecked.
- No simultaneous cross-process resolver race was exercised; F07's shared-adapter
  probe is the current authority evidence.
- No provider or MCP network call was used; runtime contracts rely on test ports.
- No sustained effect-history retention or load measurement was run.

## Verdict

**IMPROVE** under `BAR.md`: the complete source trace and six lenses are present,
but the accepted major CF04-REL-01 replay defect crosses the dispatcher/journal
boundary and the adjacent critical F07-SEC-01 remains open. Both retain their
original owners and challenge evidence; CF04 adds no duplicate machine-counted
finding.

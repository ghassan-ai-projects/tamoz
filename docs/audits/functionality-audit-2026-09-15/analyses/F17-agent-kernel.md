# F17 `tamoz-agent-kernel` — IMPROVE: the effect seam is real and the journal dedups on the request, but a failed-head replay still loses its error, and the catalogs carry Ruby-literal domain content

Row / queue: F17 · W1A (core / graph / SQLite / agent kernel / session) ·
baseline: branch `audit-15-09`, commit `582ae55`, 2026-09-15 · analyst: F17 independent
analyst lane · budget: ~55 min, hard cap 60.

## Scope and source map

Source surface read in full (28 files, 4,531 lines per `find … | wc -l`; 4,522 by the
per-file sum below — the difference is the `find` line for the gem root):

| File | Lines |
|---|---:|
| `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb` | 719 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/deliberation.rb` | 373 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb` | 334 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/intent_catalog.rb` | 277 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb` | 277 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/witness_gateway.rb` | 242 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb` | 233 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/model_client_factory.rb` | 212 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/model_receipt.rb` | 212 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb` | 184 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb` | 180 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb` | 147 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/receipt_budget_controller.rb` | 140 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/errors.rb` | 122 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/diagnosis_catalog.rb` | 120 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/skill_set.rb` | 115 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/request_route.rb` | 110 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/model_call_projection.rb` | 107 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/witness_verifier.rb` | 104 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/sealed_build.rb` | 89 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/plan.rb` | 84 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/request_projection.rb` | 33 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent_kernel.rb` | 35 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/behavior_version.rb` | 22 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/graph_versions.rb` | 17 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/event.rb` | 11 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/kernel/version.rb` | 9 |
| `gems/tamoz-agent-kernel/lib/tamoz/agent/providers.rb` | 23 |

**Entry seam.** `gems/tamoz-agent-kernel/lib/tamoz/agent_kernel.rb:7-35` requires every file
in load order and reaches only down into `tamoz-core` and `tamoz-tools`
(`agent_kernel.rb:7-8`); its own header states the direction constraint: "nothing here
reaches back up into session, worker, or CLI code" (`agent_kernel.rb:4-5`). The
effect seam is `Tamoz::Agent::EffectDispatcher.run`
(`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:33-67`).

Supporting files read for the boundary trace (not owned by F17):
`gems/tamoz-agent/tamoz-agent-kernel.gemspec`; `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:640-700`;
`gems/tamoz-agent/lib/tamoz/agent/runtime/effects_journal.rb` (whole);
`gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:1-200,255-400`;
`gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb:1-300`;
`gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb:1-150`;
`gems/tamoz-agent-session/lib/tamoz/agent/session_lifecycle.rb:1-191`;
`gems/tamoz-agent-session/lib/tamoz/agent/session_plan_outcomes.rb`;
`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_preparation.rb:130-216`;
`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_completion.rb:95-215`;
`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_reconciler.rb:160-206`;
`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal_key.rb:1-70`;
`gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:40-50,370,450-455`;
`gems/tamoz-tools/lib/tamoz/tools/local_dispatcher.rb:40-65`;
`test/support/domain_loader.rb`; `test/fixtures/domains/*.json`;
`documentation/architecture/invariants.md`; `README.md:58-62`.

### Prior-finding reconciliation (carry-forward, by name)

- **033 (`episode_nodes.rb`, top-100)**: the frame-assembler DUP is fixed —
  `build_frame` (`episode_nodes.rb:303-312`) and `rebuild_frame`
  (`episode_nodes.rb:427-435`) now share `assemble_frame(state, skills:, **extras)`
  (`episode_nodes.rb:317-329`). The dead `snapshot:` param is gone from
  `build_compensating_intent(type:, risk_class:, episode:, compensates:, reason:, now:,
  parameters:)` (`episode_nodes.rb:233`). `decision_builder` still has two spellings
  (`episode_nodes.rb:205` `build_decision`, `episode_nodes.rb:462` `call`) — declined
  upstream; I re-checked and agree: the two consume different inputs (pre-formed
  compensating intents vs a validated diagnosis document) and one spelling would need a
  mode flag. Still `info`.
- **050 (`executor.rb`, top-100)**: that file is `tamoz-graph`, **not** in this gem's
  source surface. Not re-litigated here; see the F-row that owns `tamoz-graph`.
- **055 (`verifier.rb`, top-100)**: the shared table landed at
  `gems/tamoz-evals/lib/tamoz/evals/verifier.rb:377-399`
  (`verify_terminal_diagnostic_status!`), committed as `55a9fed`
  ("refactor(evals): share the terminal-status invariant across both documents",
  2026-09-11). Both callers delegate (`verifier.rb:365-369`, `verifier.rb:538`). The
  file is `tamoz-evals`, **not** in this gem. **F17 has no `verifier.rb`.** This row's
  "verification" responsibility is the session `verify` node, whose owner is
  `tamoz-agent-session` (`session_lifecycle.rb:33-42`). Recorded here so the coordinator
  does not read the brief's "verifier.rb" as a kernel file.
- **CF04-REL-01 (major, open)**: **still reproduces on current source** — verified by an
  independent probe against the real durable SQLite journal, not a prior report. See
  F17-REL-01 below.

## Behavior path

The deliberation substrate has one plan/review/execute/verify engine and two drivers
(the ephemeral `Runtime` and the durable `Session`); the kernel owns the pure logic, the
drivers own the loops.

1. **Routing.** `RequestRoute.parse` (`request_route.rb:26-42`) validates the model's
   route document against closed lists (`NAMES` at `request_route.rb:5`,
   `REASON_CLASSES` at `request_route.rb:6-10`) and rejects unknown keys
   (`request_route.rb:64-69`). `RoutingDecision.from` downgrades `managed_action` to
   `read_only_work` when the toolbox is not action-capable
   (`request_route.rb:106-115`). No authority is granted here.
2. **Plan.** `Plan.parse` (`plan.rb:35-50`) bounds steps at `MAX_STEPS = 12`
   (`plan.rb:33`) and `Step#initialize` freezes arguments
   (`plan.rb:12-18`). Structural review is pure: `Deliberation.structural_issues`
   (`deliberation.rb:208-215`) → `plan_shape_issues` / `step_issues` /
   `check_order_issues` (`deliberation.rb:217-281`).
3. **Plan digest.** `SessionRecords.digest(plan_hash)` is the `plan_digest`
   (`session_plan_attempt.rb:92`), committed into the accepted plan
   (`session_plan_outcomes.rb:130-140`).
4. **Step gate / approval.** `SessionSteps#step_gate` (`session_steps.rb:24-38`) resolves
   arguments, builds the intent carrying the `plan_digest`
   (`session_effects.rb:281-291`), asks the approval engine
   (`session_effects.rb:365-376`), and interrupts with a descriptor carrying
   `plan_digest` **and** `arguments_digest` **and** `preview_digest`
   (`session_steps.rb:158-178`).
5. **Effect.** `SessionEffects#dispatch` (`session_effects.rb:74-86`) calls
   `EffectDispatcher.run` (`session_effects.rb:85`). The dispatcher resolves the key
   (`effect_dispatcher.rb:49-51`), calls `effects.prepare` (`effect_dispatcher.rb:52-61`),
   and branches on the returned action (`effect_dispatcher.rb:91-109`). `:execute` starts
   a fenced attempt, runs the block, and completes it (`effect_dispatcher.rb:175-212`).
6. **Repair.** A failed outcome with `repairable == true` becomes a failure observation
   (`session_steps.rb:213-227`); `SessionEvidence#bounded_repair` re-enters
   `:deliberate` in phase `repair` (`session_evidence.rb:128-148`).
7. **Verify.** `SessionLifecycle#verify` (`session_lifecycle.rb:33-42`) makes a journaled
   model call and post-processes it (`session_lifecycle.rb:158-177`).

## Lens: correctness

**Proven.** Effect identity is keyed on the request, not the answer. Two independent
sites confirm it: `ModelCall::LogicalCallKey#to_key` joins `[episode_id, stage, slot,
request_digest]` (`model_receipt.rb:47-51`), where `request_digest` is computed over the
*frozen request bytes* (`episode_model_call.rb:51-52`,
`episode_model_transport.rb:83-85`); and `SessionEffects#logical_identity` passes
`arguments` = the canonical argument document (`session_effects.rb:136-150`). The
in-memory journal hashes exactly those nine fields
(`gems/tamoz-agent/lib/tamoz/agent/runtime/effects_journal.rb:38-58`), and the durable
journal digests them under a versioned domain
(`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_journal_key.rb:22`). The dispose of the
brief's question is direct: **one request cannot produce two journal rows** — both
journals key the record map/table by the logical key
(`effects_journal.rb:70`
`existing = @records[call.logical_key]`; `effect_journal_key.rb:60-64`). And **two
different requests cannot collide** — a changed request changes the digest, hence the
key, and the same key with different semantics is a hard error:
`EffectJournalKey.verify_identity!` (`effect_preparation.rb:138-152`) and
`verify_binding!` (`effects_journal.rb` `effect key is already bound to different
semantics`).

**Proven — CF04-REL-01 still reproduces.** `terminal_attempt`
(`effect_dispatcher.rb:280-283`) returns
`record.attempts.reverse.find { |a| a.status == :succeeded } || record.attempts.last`,
and the `:failed` branch uses it for the error (`effect_dispatcher.rb:97-101`) while
`recorded_outcome` still reports `record.current_attempt`
(`effect_dispatcher.rb:162-173`). My probe drives the real durable journal and prints:

```text
second action=execute attempt=2
after attempt2 fail: status=failed current=2
after late success: status=reconcile current=2 requires=true
after operator resolve: status=failed current=2 requires=true
attempts=[[1, :succeeded, nil, {"attempt"=>1}], [2, :failed, "bad args", nil]]
REPLAY status=failed reused=true error=nil attempt=2
```

Every step matches the CF04-REL-01 write-up. The `:return` branch's preference for a
succeeded attempt is *correct* there (a late succeeded receipt is what a successful
replay must recover, `effect_dispatcher.rb:92-96`); it is the shared use of that
selector for `:failed` that is wrong. See F17-REL-01.

**Proven — the in-memory journal does NOT reproduce it.** I first ran the same sequence
against `Runtime::EffectsJournal` and got
`REPLAY status=failed reused=true error={"class"=>"Tamoz::Agent::ToolArgumentError",
"message"=>"bad args", "repairable"=>true} attempt=2`, because
`EffectsJournal#complete` rejects a non-owner token
(`effect attempt token is stale or does not own current attempt`,
`effects_journal.rb` `current_attempt`), so no late receipt can ever be written.
CF04-REL-01 is therefore **durable-journal-only**; the ephemeral runtime path is not
exposed. This is a narrowing of the finding's blast radius, `info`, not a challenge to it.

**Proven — the failed-replay consequence is real.** With `error = nil`,
`SessionEvidence#repairable_outcome?` returns false ("`error.is_a?(Hash) &&
error['repairable'] == true`", `session_evidence.rb:88-92`), so
`SessionSteps#failed_update` raises a terminal `ToolError` via
`tool_error_message` (`session_steps.rb:222-224`) instead of recording a repair failure.

## Lens: security and authority

**Proven — safety classification is data-driven and cannot be widened from the effect
definition.** The dispatcher takes `safety:` as a plain keyword
(`effect_dispatcher.rb:36`) and only *stringifies* it into the journal
(`effect_dispatcher.rb:57`); it never derives or upgrades it. The class comes from the
capability host: `LocalDispatcher#safety` returns `:reconcilable` for `apply_patch`/
`create_file`, the operator-declared per-check safety for `run_check`, and `:read_only`
otherwise (`gems/tamoz-tools/lib/tamoz/tools/local_dispatcher.rb:55-63`); `run_check`
safety is validated against a closed list at profile normalisation time
(`tool_policy_normalizer.rb:78-88`). MCP-owned sources are `:read_only` or `:unsafe`
only (`capability_binding.rb:452`). A caller cannot widen it because the dispatcher
writes nothing but the caller's string, and the journal's `verify_identity!` refuses a
key rebound to a different `safety` (`effect_preparation.rb:150-152`). Tool *arguments*
also cannot influence it: `capabilities.safety(tool, arguments)` is consulted, but the
`run_check` branch is the only argument-dependent one and it reads the *check name*, not
free text.

**Proven — the `:idempotent` / `:unsafe` split is enforced in the journal, not the
dispatcher.** On an expired running head, `read_only`/`idempotent` grant a fresh fenced
attempt while `transactional`/`reconcilable` go to reconcile and `unsafe` becomes
`:unknown` (`effect_preparation.rb:203-216`). `EffectDispatcher.validate_run_contract!`
refuses a `:reconcilable` effect with no reconciler
(`effect_dispatcher.rb:69-77`) and refuses any journal lacking `prepare`
(`effect_dispatcher.rb:70-73`).

**Proven — terminal receipts are immutable.** `EffectCompletion#complete` gates the
attempt update on `AND status IN ('running', 'unknown')` and raises
`CheckpointConflictError, 'effect receipt commit lost'` when `tx.changes != 1`
(`effect_completion.rb:95-110`), so a terminal attempt cannot be rewritten. The in-memory
journal mirrors it with `identical_terminal_receipt?` plus a `:running` precondition
(`effects_journal.rb`). A human resolution only moves a `unknown|reconcile|failed` head
(`effect_reconciler.rb:189-195`) and is deliberately permitted — it is the escape hatch,
not a rewrite of an attempt.

**Proven — untrusted content cannot widen authority through this gem.** The frame splits
trusted policy from untrusted situation (`episode_frame_builder.rb:9-16, 65-80`), the
model's tool request is checked against the wire tool catalog
(`episode_nodes.rb:602-613`) and `ground_evidence!` rejects forged evidence refs
(`episode_nodes.rb:653-662`), and `validate_recommended_intent_types!` rejects a
proposed intent outside the episode allowlist (`episode_nodes.rb:664-675`). Risk comes
from the catalog, never the model: `IntentCatalog#risk_for` raises on an unknown type
rather than guessing (`intent_catalog.rb:227-232`).

**One authority gap is recorded as info, not a finding.** `episode_nodes.rb:602-609`
skips the tool-catalog check entirely when `tool_catalog_json` is empty
(`unless tool_catalog_json.empty?`), so an episode whose wire omits the catalog has no
kernal-side allowlist. I did not establish whether the runner always supplies it; the
`execute_tool` command still goes through the capability host, which is the real
authority boundary. Not proven reachable as an unsafe action.

## Lens: reliability and durability

**Proven.** The dispatcher's recovery contract holds: a `:wait` outcome is raised as
`LeaseLostError` by the session rather than retried
(`session_steps.rb:203-206`), and `:unknown` becomes a durable blocked record
(`session_steps.rb:196-202`, `session_evidence.rb:164-176`). Attempt count is capped at
`MAX_ATTEMPTS = 3` (`effect_dispatcher.rb:15`) and the exhaustion path forces `:unknown`
without reconciling (`effect_dispatcher.rb:142-149`), so a reconciliation loop is
impossible by construction. `tamoz-agent-healing` reads that same constant rather than
restating it (`healing/rule.rb:515-519`).

**Major defect**: F17-REL-01 (CF04-REL-01 carried forward).

## Lens: observability and evidence

**Proven.** The `Outcome` value carries status, value, error, effect key, attempt number,
attempt identity, reconciliation string, and `reused`
(`effect_dispatcher.rb:17-26`), and `EffectTransitionLog.append!` records every
transition with `{'late' => attempt_number != head_current_attempt}` evidence
(`effect_completion.rb:171-179`), so a late receipt is visible in the audit trail.
`unknown_error_detail` runs the message through `Tamoz::Error.disclosable_message`
(`effect_dispatcher.rb:271-278`) so an unknown attempt does not leak provider payloads.

**Proven — and this is exactly what makes F17-REL-01 material.** The dispatcher outcome
is the *only* channel that carries the failure detail up to the session
(`session_evidence.rb:88-105` reads `outcome.error`); when it is nil, the durable
evidence records a generic `tool effect failed` and the operator has no diagnostic. The
transition log still has both attempts, so the truth is recoverable from the journal —
but not from the surface the caller sees.

## Lens: scalability and resource bounds

**Proven.** Every bound in this gem is a named constant with a fail-closed raise:
`Plan::MAX_STEPS = 12` (`plan.rb:33`), `DiagnosisCatalog::MAX_ENTRIES = 64` /
`MAX_DESCRIPTION_BYTES = 512` (`diagnosis_catalog.rb:26-27`),
`IntentCatalog::MAX_ENTRIES = 64` / `MAX_PARAMETERS = 128` / `MAX_PRESET_BYTES = 64 KiB`
(`intent_catalog.rb:31-34`), `SkillSet::MAX_REFS = 32` / `MAX_TEXT_BYTES = 64 KiB`
(`skill_set.rb:19-21`), `EpisodeFrameBuilder::MAX_FACT_BYTES = 4096` / `MAX_FACTS = 64`
(`episode_frame_builder.rb:26-27`), `MAX_COMMANDS = 64` / `MAX_INTENTS = 16`
(`episode_nodes.rb:29-30`), `WitnessGateway::MAX_RECORDS` (ring buffer,
`witness_gateway.rb:184-188`), and `ReceiptBudgetController`'s pre-dispatch checks
against the wire envelope (`receipt_budget_controller.rb:40-61, 96-130`). The budget is
recomputed from committed state plus the journaled receipt, never from counted events
(`receipt_budget_controller.rb:8-14`), so a replay does not double-count.

**Not evidenced**: no load/soak or sustained-concurrency measurement exists for this gem.
A bound stated as a constant is not a measured throughput ceiling; what would prove it is
a soak run at the concurrency the worker allows, which the checkout does not contain.

## Lens: maintenance and architecture

**Proven — the dependency direction is honest.** `agent_kernel.rb:7-8` requires only
`tamoz-core` and `tamoz-tools`, matching the gemspec's declared dependencies exactly
(`tamoz-agent-kernel.gemspec`: `tamoz-core`, `tamoz-tools`, `net-http`). No require in
the 28 files reaches a session/worker/CLI path. `ModelCall::LogicalCallKey`,
`GraphVersions`, `BEHAVIOR_VERSION`, `Event`, and `Providers` were each deliberately
homed here so both sides of a boundary can share one definition without an upward edge
(`behavior_version.rb:5-13`, `providers.rb:4-6`, `graph_versions.rb:4-6`).

**Proven — the catalogs are data.** Both `DiagnosisCatalog` and `IntentCatalog` are
pure shape validators over wire bytes: `verify_wire` strict-parses, checks the
cross-boundary digest, and then validates structure
(`diagnosis_catalog.rb:53-63`, `intent_catalog.rb:54-64`). Neither file contains a
diagnosis code, an action type, a compensation mapping, or a preset. `IntentCatalog`
even carries the go/no-go for the compensation table as data
(`compensation_for` reads the entry's own metadata, `intent_catalog.rb:206-215`) and
validates that every named target is itself a catalog member
(`intent_catalog.rb:196-204`).

**But two Ruby-literal domain constants do exist** — see F17-B9-01 and F17-B9-02.

**Proven — `decision_builder` still has two spellings** (`episode_nodes.rb:205` vs
`episode_nodes.rb:462`). Re-checked against the current source and the two protocols
consume genuinely different inputs. Remains `info`; the prior audit's decline is upheld.

## Tests and contracts

| Command | Result |
|---|---|
| `ruby -Itest test/agent_runtime_effects_test.rb` | **10 runs / 44 assertions / 0 failures / 0 errors / 0 skips** |
| `ruby -Itest test/agent_decision_flow_test.rb` | **5 runs / 23 assertions / 0F / 0E / 0S** |
| `ruby -Itest test/agent_repair_evaluation_test.rb` | **8 runs / 55 assertions / 0F / 0E / 0S** |
| `ruby -Itest test/agent_session_effect_test.rb` | **19 runs / 78 assertions / 0F / 0E / 0S** |
| `ruby -Itest test/agent_acceptance_workflow_test.rb` | **1 run / 33 assertions / 0F / 0E / 0S** |
| `ruby -Itest test/agent_reasoning_document_test.rb` | **25 runs / 75 assertions / 0F / 0E / 0S** |
| `ruby -Itest test/agent_intent_catalog_test.rb` | **14 runs / 19 assertions / 0F / 0E / 0S** |
| `ruby -Itest test/agent_diagnosis_catalog_test.rb` | **15 runs / 53 assertions / 0F / 0E / 0S** |
| probe `/tmp/f17_probe_cf04.rb` (durable SQLite journal + real dispatcher) | reproduces CF04-REL-01 |
| probe `/tmp/f17_probe_late.rb` (in-memory journal) | late receipt refused; finding not reachable there |
| `test/reasoning_document_test.rb` | **not found** — the real file is `test/agent_reasoning_document_test.rb` |

`ruby -Itest test/agent_model_receipt_test.rb`, `test/effect_identity_test.rb`, and
`test/agent_mcp_capability_source_test.rb` were **not run** (budget); they are the
natural next evidence for the identity and MCP-safety leads.

**Test gap for F17-REL-01.** `test/sqlite_effect_journal_test.rb:316-379` covers a late
success beside a new **succeeded** head; `test/sqlite_effect_journal_test.rb:222-313`
covers an unsafe running head becoming unknown. Neither creates a late succeeded attempt
beside a current **failed** attempt and then replays it. `test/agent_runtime_effects_test.rb:42-66`
covers a single typed failed receipt. So the failing sequence is unreachable by the
existing suite — consistent with CF04-REL-01's own "Evidence and test gap" section
(`analyses/failed-effect-resolution-replay.md:78-88`).

**README "Reviewed change loop" clause-by-clause** (`README.md:58-62`):

| Clause | Verdict in code |
|---|---|
| "a separately reviewed action plan" | **Backed.** Structural review at `deliberation.rb:208-215`; semantic review via `REVIEW_SYSTEM` (`deliberation.rb:23-28`) and `parse_review` (`deliberation.rb:312-327`). |
| "an exact diff shown before approval" | **Backed.** `preview_for` (`session_effects.rb:349-351`) builds the preview, `Digest::SHA256.hexdigest(prepared.preview)` is the `preview_digest` (`session_steps.rb:147`), and both travel in the descriptor (`session_steps.rb:173-176`). |
| "a digest-bound atomic patch" | **Backed.** `expected_sha256` is resolved from observed state (`session_effects.rb:294-308`), re-verified at execution (`session_effects.rb:88-98`), and the intent records `arguments_digest` (`session_effects.rb:287`). |
| "a configured verification command" | **Backed.** `check_order_issues` requires a `run_check` step in action/repair phases (`deliberation.rb:266-281`). |
| "A failed check becomes evidence for up to two newly reviewed repairs" | **Backed.** `failed_check` → `bounded_repair` (`session_evidence.rb:124-148`) with `MAX_REPAIR_ATTEMPTS = 2` (`session_nodes.rb:26`) and `repair_attempts_exhausted` as the stop. |
| "with fresh approvals" | **Backed.** `approval_id` is `"#{plan_id}.#{step_id}"` (`session_steps.rb:187`), a new repair plan has a new `plan_id`, so no old approval is reused. |
| "a repeated action stops safely" | **Backed.** `action_signature` over the plan's tool+arguments (`deliberation.rb:349-356`) checked against `seen_action_signatures` (`session_plan_outcomes.rb:117-119`) → `terminal_reason: 'repeated_action'`. |
| "a repeated failure stops safely" | **Backed.** `seen_failure_signatures` check at `session_evidence.rb:130-132` → `repeated_failure`. |
| "a digest-bound atomic patch" — plan-digest half | **See F17-REL-02.** The approval is bound to the plan digest *and* the patch digest, but the `plan_digest` itself is never compared against the plan it describes. |

## Findings

### F17-REL-01 — a late success after a human `:failed` resolution replays with a nil error

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` — source trace plus an independent probe driving the real durable SQLite journal and the public dispatcher |
| Status | `open` — carried forward from **CF04-REL-01**, re-verified against current source, not re-litigated |
| Owning seam | `EffectDispatcher#resolve_decision` / `#terminal_attempt` (`gems/tamoz-agent-kernel/lib/tamoz/agent/effect_dispatcher.rb:91-109, 280-283`) |

**Source evidence.** `terminal_attempt` returns any succeeded attempt before the last
attempt (`effect_dispatcher.rb:280-283`). The `:failed` branch feeds that attempt's error
into the outcome (`effect_dispatcher.rb:97-101`). `recorded_outcome` simultaneously
reports the *head's* current attempt number and identity
(`effect_dispatcher.rb:162-173`). For the trigger to exist, the durable journal must be
able to hold a succeeded late attempt beside a failed current attempt: a late success
from an older attempt on a `failed`/`abandoned` head sets the head to `reconcile` with
`requires_reconciliation = 1` (`effect_completion.rb:126-142`), and a human resolution to
`:failed` moves the head back to `failed` while preserving
`requires_reconciliation` (`effect_reconciler.rb:188-206`). `prepare` then maps a failed
head to `action = :failed` (`effect_preparation.rb:150-152`).

**Test/contract evidence.** Probe `/tmp/f17_probe_cf04.rb` (durable SQLite journal through
`tamoz-graph`'s compiled runner and `EffectDispatcher.run`): `REPLAY status=failed
reused=true error=nil attempt=2`, with persisted attempts
`[[1, :succeeded, nil, {"attempt"=>1}], [2, :failed, "bad args", nil]]`. The same sequence
against the in-memory `Runtime::EffectsJournal` (`/tmp/f17_probe_late.rb`) returns the
attempt-2 error, because `EffectsJournal` refuses a non-owner token — so the defect is
durable-journal-only. Focused suites all pass (table above), which is the gap, not a
resolution.

**Scanner signal.** Prior audit CF04-REL-01; re-derived here from source and re-run as a
probe rather than taken from the earlier report.

**Independent judgment.** **Confirmed on current source, with one narrowing.** The
contradictory receipt (failed status and current attempt 2, error from attempt 1, which
is nil) still occurs exactly as recorded. I additionally established that the ephemeral
runtime path is *not* exposed to it, which the prior report did not state. Downstream
consequence re-verified in current source: `SessionEvidence#repairable_outcome?`
(`session_evidence.rb:88-92`) rejects a nil error, so `SessionSteps#failed_update`
(`session_steps.rb:221-227`) raises a terminal `ToolError` instead of entering the
bounded repair loop.

**Root cause (five whys).**
1. Why does the replayed failure lack its error? The dispatcher reads the error off a
   succeeded attempt.
2. Why that attempt? `terminal_attempt` prefers any succeeded receipt, unconditionally.
3. Why is one selector used for both branches? `:return` and `:failed` were treated as
   sharing one "find the terminal value" lookup.
4. Why was the distinction not enforced? The record stores attempt history and
   current-head identity separately, and nothing binds receipt selection to the requested
   head action.
5. Why did tests miss it? Every test covers one race outcome in isolation; none builds a
   mixed late-success / current-failure history. The controllable cause is an incomplete
   replay contract at the dispatcher boundary: a status-specific outcome needs a
   status-specific attempt selection.

**Recommendation (smallest action at the existing seam).** In
`EffectDispatcher#resolve_decision`, make the `:failed` branch read the current head
attempt (`record.attempts.find { |a| a.attempt_number == record.current_attempt }`) and
return that attempt's error and identity; keep the succeeded-attempt lookup for `:return`,
where a late succeeded receipt is genuinely the value to recover. Add one regression that
drives expiry → attempt 2 repairable failure → late attempt 1 success → operator
`:failed` resolution and asserts the replay returns attempt 2's error. Do not add
machinery beyond that.

**Disposition.** Accept as an open major finding. Carried forward under the recorded
name **CF04-REL-01** so the coordinator keeps one finding, not two; the F17 row inherits
ownership of the dispatcher half (`tamoz-sqlite` keeps the journal half, `tamoz-agent-session`
the consumer half). Requires an independent challenge before any future closure per
`FINDINGS.md:19-21`.

---

### F17-B9-01 — `EpisodeNodes::RISK_RANK` is a Ruby-literal risk-class table

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` — the constant is read directly from current source and the AGENTS.md rule is explicit |
| Status | `open` |
| Owning seam | `EpisodeNodes::RISK_RANK` (`gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb:31`), consumed by `#risk_above_ceiling?` (`episode_nodes.rb:260-263`) |
| Source evidence | `RISK_RANK = {"R0" => 0, "R1" => 1, "R2" => 2, "R3" => 3, "R4" => 4}.freeze` at `episode_nodes.rb:31`. Used at `episode_nodes.rb:261-262` to order a compensation target's declared risk against the episode's `risk_ceiling`. The declared risks themselves come from the catalog (`IntentCatalog#risk_for`, `intent_catalog.rb:227-232`), but the **ordering lattice is a Ruby literal** in the kernel. |
| Test/contract evidence | `test/agent_intent_catalog_test.rb` (**14 runs / 19 assertions / 0F**) does not assert this table. The RECONSIDER path that consumes it is covered by `test/stream_episode_reconsider_test.rb` (**not run** — outside this row's budget). No test pins `RISK_RANK` against fixture data. |
| Scanner signal | Grep for `R0..R4` across `gems/tamoz-agent-kernel/lib` returns `episode_nodes.rb:31` and `intent_catalog.rb:26`. |
| Independent judgment | **Confirmed as a literal, but the domain characterization needs one honest qualifier.** AGENTS.md's B9/P4 gate-4 list names "intent types + risk classes" as domain content that must live only in `test/fixtures/domains/*.json`. `RISK_RANK` is a risk-class table in Ruby. The counter-argument — that R0–R4 is the *wire enum's* closed semantics rather than a domain vocabulary, exactly as `IntentCatalog::RISK_CLASSES` (`intent_catalog.rb:26`) is, and as the comment at `episode_nodes.rb:27-28` asserts ("the risk lattice is the wire enum's semantics") — is real: the four classes are a protocol constant the Go side also fixes, and the fixture files themselves only use `R0`–`R2` (`test/fixtures/domains/cold-chain.json:15` and siblings). What is **not** defensible is that the *ordering* lives in two places: `RISK_RANK` here and `RISK_CLASSES` in `intent_catalog.rb:26`, with no shared definition and no test that they agree. I record it as `major` rather than `critical` precisely because I could not show a reachable unsafe action: `fetch(risk_class, 99)` fails *closed* for an unranked class, so a domain that added `R5` would be treated as above every ceiling, not below. |
| Root cause (five whys) | 1. Why is the lattice in Ruby? The kernel needed a comparison for the ceiling check. 2. Why here rather than in the catalog? The check is generic episode logic, so a kernel constant felt local. 3. Why is that wrong? AGENTS.md makes the risk vocabulary domain data. 4. Why does the split matter? `IntentCatalog::RISK_CLASSES` and `RISK_RANK` are now two unlinked authorities for one closed set. 5. Why is there no guard? No test or loader-derived check compares them — the controllable cause is a missing single source for the risk lattice. |
| Recommendation | Derive the lattice from the catalog rather than a kernel literal — `IntentCatalog` already holds the ordered `RISK_CLASSES` (`intent_catalog.rb:26`); expose the rank there (or rank by `RISK_CLASSES.index`) and have `risk_above_ceiling?` read it, so the closed set has one definition. If the coordinator's reading of B9 is that a wire enum is exempt, this downgrades to `info` and the recommendation becomes the narrower one: keep the table but assert it equals `IntentCatalog::RISK_CLASSES`. Either way, do not add a new class. |
| Disposition | Left open for coordinator judgment on the wire-enum exemption. The duplicate-authority half is defensible either way and is the smallest credible fix. |

---

### F17-B9-02 — the watch intent type is a Ruby-literal domain constant in `tamoz-core`

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` for the literal's existence and its in-gem consumption; `medium` for whether B9 reaches a shared protocol constant |
| Status | `open` |
| Owning seam | `Tamoz::Core::INTENT_WATCH_TYPE` (`gems/tamoz-core/lib/tamoz/core.rb:28`), aliased at `IntentCatalog::WATCH_TYPE` (`intent_catalog.rb:29`) |
| Source evidence | `INTENT_WATCH_TYPE = "install_watch_condition"` (`tamoz-core/lib/tamoz/core.rb:28`). The kernel enforces it as a required catalog member — `raise IntentCatalogError, "intent_catalog/missing_watch_type" unless types.include?(WATCH_TYPE)` (`intent_catalog.rb:189-191`) — and falls back to it for the decision's R0 watch condition (`episode_nodes.rb:216-231`). The same string is authored in every domain fixture (`test/fixtures/domains/aquaculture.json:14`, `climate.json:13`, `cold-chain.json:15`, and the other two). |
| Test/contract evidence | `test/agent_intent_catalog_test.rb` (**14 runs / 19 assertions / 0F**) exercises the missing-watch-type refusal but does not tie the constant to fixture data. `test/support/domain_loader.rb` has no watch-type parameter — it hardcodes `type == "install_watch_condition"` for preset/schema special-casing. |
| Scanner signal | `grep -rn 'install_watch_condition' gems/*/lib` → only `tamoz-core/lib/tamoz/core.rb:28`. `grep -rn 'install_watch_condition' gems/tamoz-stream/lib` → no hits. |
| Independent judgment | **Confirmed, severity kept `minor` deliberately.** This is a single protocol constant, not a catalog: the actual domain content — which intents exist, their risk classes, their compensation maps, their presets, the watch *properties* — is entirely in `test/fixtures/domains/*.json` and expanded by `test/support/domain_loader.rb`, and `gems/tamoz-agent-kernel/lib` contains **zero** intent type names (`grep -rnE '"(install_watch|recalibrate|dispatch|expedite|quarantine)' gems/tamoz-agent-kernel/lib` → no hits). Calling this `critical` would be softening the bar in the other direction. But it is still a domain vocabulary word in Ruby: the rule as written is "zero domain content in Ruby", and this is a domain word. |
| Root cause | 1. Why is the string in Ruby? Both the decision builder and the episode fallback need one spelling. 2. Why not from data? The kernel validates a catalog it does not author, and needed a constant to assert membership. 3. Why does that matter? A domain that renamed its watch intent would have a kernel constant and a JSON fixture disagree, failing closed with a confusing error. 4. Why no guard? Nothing derives the constant from the loader. 5. Root cause: the watch *type name* was promoted to protocol constant rather than treated as the catalog's own data, which the catalog already carries. |
| Recommendation | Smallest action: have `IntentCatalog` take the watch type from the catalog's own declaration (for example an explicit `watch_type` key in the domain JSON, defaulted in the loader) instead of a core constant, or — if the coordinator ratifies the protocol-constant reading — record the exemption in the B9 note at `docs/` so the next auditor does not re-raise it. Do not add a new module. |
| Disposition | Open, `minor`. The catalog itself is clean; this is the one residual domain word. |

---

### F17-COR-01 — the approval records a plan digest that is never verified against the plan it approves

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `medium` — the absence is proven by exhaustive grep, but I did not find a reachable path that mutates the plan after acceptance |
| Status | `open` |
| Owning seam | `SessionSteps#approval_descriptor` / `#journaled_verdict` (`gems/tamoz-agent-session/lib/tamoz/agent/session_steps.rb:158-178, 115-122`), consuming `accepted_plan` (`session_plan_outcomes.rb:130-140`) |
| Source evidence | The approval carries `plan_digest` (`session_steps.rb:173`), the effect intent carries it (`session_effects.rb:284`), and the approval record carries it (`session_steps.rb:188`). But the replay path that reuses an approval matches on **`approval_id` only**: `entry['approval_id'] == "#{accepted.fetch('plan_id')}.#{step.fetch('id')}"` (`session_steps.rb:115-122`), and `SessionEvidence#find_intent` matches on `plan_id` + `step_id`, **not** `plan_digest` (`session_evidence.rb:20-28`). A repo-wide grep for `plan_digest` in `gems/*/lib` returns only *writes* and *provenance projections* — no `==` comparison, no `verify_*` against a recomputed digest. `SessionRecords.digest(plan_hash)` is computed once at plan time (`session_plan_attempt.rb:92`) and never re-derived from the plan the executor reads. |
| Test/contract evidence | `test/agent_acceptance_workflow_test.rb` (**1 run / 33 assertions / 0F**) exercises the approval boundary end to end but does not mutate a plan between approval and execution. `test/agent_decision_flow_test.rb` (**5 runs / 23 assertions / 0F**) does not either. No test asserts a plan-digest mismatch refuses. |
| Scanner signal | `grep -rn 'plan_digest' gems/tamoz-agent-session/lib gems/tamoz-graph/lib gems/tamoz-agent/lib` — 30 hits, none a comparison. |
| Independent judgment | **The absence is proven; the exploit is not.** Both halves of the brief's question resolve differently: the approval *is* bound to the exact patch digest, three ways — `arguments_digest` over the canonical arguments (`session_effects.rb:287`), `preview_digest` over the rendered preview (`session_steps.rb:147`), and `expected_sha256` re-verified against the live workspace at execution (`session_effects.rb:88-98`, `SessionEffects#verify_intent_before_state!`). So a *mutated patch* cannot ride an old approval. What is unbacked is the plan half: `plan_digest` is recorded but never compared to the plan being executed. Why I hold this at `medium` and not `high`: the accepted plan and the executed steps are read from the same graph state key (`state.fetch(:accepted_plan)` at `session_steps.rb:39-41`), committed by a checkpointed transition with a content digest (`session_plan_outcomes.rb:130-140`), and I found no writer that mutates `accepted_plan['plan']` in place. If that state channel is genuinely immutable after acceptance, this is an `info`-level defense-in-depth gap. I could not prove the channel immutable within budget — `SessionRecords` schema validation is structure-only (`session_records.rb:147` and the `accepted_plan` schema), not a digest check. |
| Root cause (five whys) | 1. Why is the plan digest unverified? Nothing reads it for comparison. 2. Why not? The approval boundary verifies the *material* (argv, targets, preview, `expected_sha256`), which was judged sufficient. 3. Why is that insufficient? The plan digest was introduced precisely to bind "the exact plan", and a binding with no comparison site is provenance only. 4. Why was no comparison written? The replay path reuses approvals through the ID and never re-checks the plan. 5. Why did tests miss it? No test mutates a plan between approval and execution — the controllable cause is that "digest-bound plan" was implemented as a recorded field rather than an enforced predicate. |
| Recommendation | Add the one comparison at the existing gate: in `SessionSteps#journaled_verdict`, require the matched approval's `plan_digest` to equal `accepted.fetch('plan_digest')` before returning its stored verdict, and raise the existing typed error on mismatch. That is the smallest action at the seam the audit names and it makes the recorded digest load-bearing. Do not add a new class or a new digest. |
| Disposition | Open, `medium`. The exploit path is unproven, so this stays below the CF04-REL-01 confidence tier; it needs an independent challenge that attempts to mutate `accepted_plan` between the gate and execution. If that attempt fails, downgrade to `info` and keep the recommendation as a one-line hardening. |

---

### F17-ERR-01 — the episode path collapses every failed effect into one untyped `ProtocolError`

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` — both raise sites trace to a single generic message |
| Status | `open` |
| Owning seam | `EpisodeNodes#enforce_successful_outcome!` (`gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb:591-598`) |
| Source evidence | `raise ProtocolError, "episode #{subject} call failed"` (`episode_nodes.rb:596`) discards `result.outcome.error` entirely, even though `EpisodeModelCall::Result` and `EpisodeToolCall::Result` both carry the dispatcher `Outcome` (`episode_model_call.rb:37-41`, `episode_tool_call.rb:27-31`) and `EpisodeModelCall#map_outcome` already has the typed error in hand (`episode_model_call.rb:104-105`). The `:unknown` branch right above it *does* preserve distinction via a dedicated class (`episode_nodes.rb:592-594`), and the recall node collapses `:failed` to `"episode_recall/failed"` (`episode_nodes.rb:87-91`). |
| Test/contract evidence | `test/agent_reasoning_document_test.rb` (**25 runs / 75 assertions / 0F**), `test/agent_intent_catalog_test.rb` (**14 / 19 / 0F**), `test/agent_diagnosis_catalog_test.rb` (**15 / 53 / 0F**). The episode-failure class identity is asserted by `test/stream_episode_*` suites (**not run** — outside this row). |
| Scanner signal | Grep of `ProtocolError` raise sites in `episode_nodes.rb` shows two different meanings share the class: a malformed model document (`episode_nodes.rb:385, 529`) and a failed effect call (`episode_nodes.rb:596`). |
| Independent judgment | **Confirmed as a real taxonomy blur, but bounded.** The taxonomy in `errors.rb` is otherwise clean and boundary-correct: each class documents *which* boundary raises it and why it is terminal (`errors.rb:18-22, 24-31, 33-38, 40-46, 76-95, 97-105, 107-117`), and `ModelCallError` carries stable machine fields — `code`, `status`, `body_digest`, `body_bytes` (`errors.rb:47-75`) — with `code` defaulting to `"replayed"` when absent (`errors.rb:52-54`), which is how a replayed failure keeps a stable identity. `ToolError` detail is journalled from the exception *type*, not the message (`effect_dispatcher.rb:243-267`), so error identity survives replay. The blur is therefore local: on the episode path a provider failure and a tool failure are indistinguishable to a caller, and a diagnostic can only be recovered from the journal, not from the raised error. It is `minor`, not `major`, because the episode runner is a separate driver and the session path (the one the README's loop describes) does preserve the typed detail through `outcome.error` (`session_evidence.rb:88-105`). |
| Root cause | The episode node needed a terminal typed stop before the interpreter, and one generic class was enough for it; nobody separated "the model returned garbage" from "the effect failed" once the dispatcher began carrying typed errors. No test asserts the class for an effect-failure episode. |
| Recommendation | At `enforce_successful_outcome!`, raise a class that reflects the outcome — reuse `EffectUnknownError`/`ModelCallError` for the model subject and the existing `ToolError` family for the tool subject, carrying `result.outcome.error` as the message — rather than collapsing both into `ProtocolError`. One raise-site change; no new class beyond what `errors.rb` already defines. |
| Disposition | Open, `minor`. Bounded local taxonomy debt with real diagnostic cost on the episode path; below the three-minor IMPROVE threshold contribution is nonetheless counted. |

---

### F17-INFO-01 — in-memory journal narrowing of CF04-REL-01

`severity: info`. The ephemeral `Runtime` journal cannot produce a failed replay with a
nil error, because `EffectsJournal#complete` refuses any token that does not own the
current attempt (`gems/tamoz-agent/lib/tamoz/agent/runtime/effects_journal.rb`,
`current_attempt` → `CheckpointConflictError, 'effect attempt token is stale or does not
own current attempt'`). Verified by probe `/tmp/f17_probe_late.rb`. This narrows
CF04-REL-01's blast radius to the durable journal; recorded so the coordinator does not
widen the finding. It does **not** displace the finding: the durable journal is the
production path.

### F17-INFO-02 — non-deterministic call-site inventory

Every non-deterministic and external call in `gems/*/lib` routes through
`EffectDispatcher.run`:

| Call site | File:line |
|---|---|
| episode model call | `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb:70` |
| episode tool call | `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_tool_call.rb:79` |
| episode recall | `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb:70` |
| session model call | `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:22` |
| session tool dispatch | `gems/tamoz-agent-session/lib/tamoz/agent/session_effects.rb:85` |
| ephemeral runtime model call | `gems/tamoz-agent/lib/tamoz/agent/runtime.rb:664` |
| healing remediation effect | `gems/tamoz-agent-healing/lib/tamoz/agent/healing/remediation/effect_execution.rb:34` |
| memory consolidation model call | `gems/tamoz-agent-memory/lib/tamoz/agent/memory/consolidation.rb:194` |
| improvement candidate lifecycle | `gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/candidate_lifecycle.rb:48` (`effect_runner: EffectDispatcher`) |

**No non-deterministic call site was found outside the dispatcher.** The two raw HTTP
clients in this gem are not violations of the AGENTS.md rule: `EpisodeModelTransport`
(`episode_model_transport.rb:149-160`) *is* the perform block the dispatcher wraps
(`episode_model_call.rb:70-86`), and `WitnessGateway`
(`witness_gateway.rb:183-196`) is a server-side gateway that forwards an already-journaled
request and signs the binding record — its `forward` call is the gateway's own duty, and
the client that calls it is `EpisodeModelTransport#call_via_gateway`
(`episode_model_transport.rb:129-147`), still inside the dispatcher's block.
`Memory::Consolidation` calls `model.generate` (`consolidation.rb:203`) inside its
dispatcher block at `consolidation.rb:194`. This is `info`: a verified design fact, and
the FX compliance of every other gem rests on it.

## Blind spots

- **`test/stream_episode_*` (16 files) were not run.** They are the integration surface
  for the RECONSIDER path, `EpisodeNodes#compensate`, and `risk_above_ceiling?`, which is
  where F17-B9-01 actually bites. Running `test/stream_episode_reconsider_test.rb` and
  `test/stream_episode_intent_authority_test.rb` would either confirm the missing
  risk-table assertion or show it is pinned elsewhere. Budget, not absence.
- **`tamoz-graph`'s `executor.rb` (prior finding 050) was not read in this row.** It is
  not in this gem's source surface; I only read the small slices needed to reach the
  durable journal. The F-row owning `tamoz-graph` must carry 050.
- **`gems/tamoz-agent-session/lib/tamoz/agent/session_records.rb` was read only for the
  `plan_digest` schema lines**, not the whole file. F17-COR-01's "is `accepted_plan`
  immutable after acceptance?" question turns on whether that schema or the checker
  enforces anything beyond structure — I read enough to see it is structure-only, but I
  did not read the checker in full.
- **The recovery/lease path in `effect_preparation.rb` was read from line 130**, not from
  the top. The `:wait` deadline comparison at `effect_preparation.rb:166-170` is the one
  place I would look next if F17-REL-01's trigger were ever disputed.
- **No load/soak evidence exists** for the scalability lens; see that section.
- **`runtime.rb` was read only around the dispatcher call** (`runtime.rb:640-700, 739-747`).
  Its full loop is the `tamoz-agent` row's surface.

## Verdict

**IMPROVE.**

| Severity | Count | IDs |
|---|---:|---|
| critical | 0 | — |
| major | 3 | F17-REL-01 (CF04-REL-01), F17-B9-01, F17-COR-01 |
| minor | 2 | F17-B9-02, F17-ERR-01 |
| info | 2 | F17-INFO-01, F17-INFO-02 |

Per BAR.md, `IMPROVE` is met by the presence of accepted critical/major findings. All six
lenses were reviewed; `scalability` is marked `not evidenced` for its measurement half
only — the bounds are proven, the load evidence is not.

The four things this row was asked to settle, plainly:

1. **The effect seam holds.** Identity is keyed on the request
   (`model_receipt.rb:47-51`), one request makes one row and two requests cannot collide
   (`effect_journal_key.rb:22, 60-64`; `effect_preparation.rb:150-152`), safety is
   data-driven from the capability host and cannot be widened by the dispatcher or by
   untrusted content (`local_dispatcher.rb:55-63`; `capability_binding.rb:452`), and
   terminal receipts are immutable (`effect_completion.rb:95-110`).
2. **CF04-REL-01 still reproduces**, confirmed by an independent probe against the real
   durable journal, and it is durable-journal-only. F17-REL-01.
3. **The README's reviewed change loop is backed clause by clause** except that
   `plan_digest` is recorded but never compared. F17-COR-01.
4. **B9 is nearly clean.** The catalogs are pure shape validators with no domain content
   (`diagnosis_catalog.rb`, `intent_catalog.rb`), and `test/fixtures/domains/*.json` plus
   `test/support/domain_loader.rb` own the domain. Two residual Ruby literals remain:
   `RISK_RANK` (F17-B9-01, major) and `INTENT_WATCH_TYPE` (F17-B9-02, minor). Neither is
   a hardcoded catalog.

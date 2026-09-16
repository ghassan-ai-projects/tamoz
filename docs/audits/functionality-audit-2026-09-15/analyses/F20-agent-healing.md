# F20 `tamoz-agent-healing` — IMPROVE (one critical bound violation: the remediation protocol has no repetition bound)

Row / queue: F20 / W4A · baseline: branch `audit-15-09`, HEAD `582ae55`, 2026-09-15 · analyst: F20 analyst lane · budget ~45 min (hard cap 60)

## Scope and source map

Every file under `gems/tamoz-agent-healing/lib` was read end to end, plus the gemspec.

| File | Lines | Role |
|---|---|---|
| `lib/tamoz/agent_healing.rb` | 24 | require graph; no provider SDK, no `tamoz-evals` |
| `lib/tamoz/agent/healing.rb` | 55 | `RECORD_KINDS` allowlist, `load_record!`, `pin_for`, `LEGACY_HEALING_PIN` |
| `lib/tamoz/agent/healing/failure_record.rb` | 435 | typed `FailureRecord`, `typed_signal`, `fingerprint`, `from_h` version gate |
| `lib/tamoz/agent/healing/classification.rb` | 277 | `classify`, `Decision`, abstention, action-family table |
| `lib/tamoz/agent/healing/classification/matrix.rb` | 124 | classification matrix with per-class denominators |
| `lib/tamoz/agent/healing/classification/legacy_text_adapter.rb` | 95 | text-derived proposal capped at `:observe` |
| `lib/tamoz/agent/healing/rule.rb` | 583 | immutable `HealingRule`, `SELF_PROTECTED_FIELDS`, validators |
| `lib/tamoz/agent/healing/rule_registry.rb` | 199 | append-only versions, `amend`, `write_lifecycle_mode`, load gate |
| `lib/tamoz/agent/healing/scope.rb` | 55 | fiber/thread-local in-band guard |
| `lib/tamoz/agent/healing/preflight.rb` | 223 | 8 design §5 checks + 3 negative cases |
| `lib/tamoz/agent/healing/oracle.rb` | 137 | configured-check oracle pinned by digest |
| `lib/tamoz/agent/healing/effect_identity.rb` | 73 | `healing.<digest>` effect operation |
| `lib/tamoz/agent/healing/errors.rb` | 158 | `FAILURE_MODEL`, value-vs-propagate |
| `lib/tamoz/agent/healing/seams.rb` | 183 | `MemoryCircuitStore`, `NullEscalationSink`, `ContainOnlyCompensation`, `NullPromotionRegistry` |
| `lib/tamoz/agent/healing/promotion_gate.rb` | 64 | pure promotion predicates |
| `lib/tamoz/agent/healing/remediation.rb` | 114 | `Remediation.run`, `STATES`, `TERMINAL_STATES` |
| `lib/tamoz/agent/healing/remediation/session.rb` | 290 | the state machine |
| `lib/tamoz/agent/healing/remediation/{plan_builder,plan_review,effect_execution,preflight_check,compensation_flow,attempt_evidence,escalation_payload,outcome}.rb` | 454 | protocol collaborators |
| `tamoz-agent-healing.gemspec` | 20 | deps: kernel, tools, core (exact-pinned) |

**Entry seam:** `Tamoz::Agent::Healing::Remediation.run(...)` (`remediation.rb:62`), wrapped in `Scope.in_band` (`remediation.rb:75`).

**Domain-data check (B9).** `test/support/domain_loader.rb:7-13` names the correct shape: catalogs, prompts, intents + risk classes, compensation maps, watch-property rules, presets, snapshots, fixtures. `test/fixtures/domains/` contains `aquaculture.json`, `climate.json`, `cold-chain.json`, `shipment.json`, `thermal-lab.json`. **No finding.** Everything in this gem is machinery, not domain content:
- `Classification::CATEGORY_ACTION_FAMILY` (`classification.rb:51`) and `REQUIRED_EVIDENCE` (`classification.rb:72`) are the framework's own failure-category taxonomy, the same closed set as `FailureRecord::CATEGORIES` (`failure_record.rb:51`) and design §3.
- `Preflight::DESIGN_CHECKS`/`CHECKS`/`DETAILS` (`preflight.rb:18,89,164`) are design §5 protocol steps keyed by stable ids.
- `RuleRegistry#amend` is **not** a hardcoded approval verdict: an amend succeeds only when the peer supplies a reviewed diff naming exactly the changed fields **and** a `"human:"`-prefixed approval string (`rule_registry.rb:164-178`), and both an authorized and a refused amend are executed by `test/healing_failure_contract_test.rb:390`. This is a fail-closed shape gate on caller-supplied evidence, not an authored verdict.

## Behavior path

1. **Observe.** `Session#call` writes a `:observed` transition carrying `failure_digest` (`session.rb:28`).
2. **Circuit gate before anything else.** `circuit_guard` returns a terminal `:circuit_open` when `@circuit.open?` (`session.rb:89-97`) — before classification.
3. **Classify.** `Classification.classify(record, rule:)` (`classification.rb:152`) reads only `record.typed_signal` (`failure_record.rb:155`), which excludes `untrusted_message_ref` by construction. Path order: never-mutate → trigger mismatch → confidence gate → family authorization → typed evidence.
4. **Abstain or escalate.** `classification.route` is `:escalated` for `abstained`, `never_mutate`, or `contain_escalate` (`classification.rb:114-119`); `session.rb:35` returns before planning.
5. **Plan.** `PlanBuilder#call` requires `original_invariant`, `minimal_change`, `stop_conditions` non-empty (`plan_builder.rb:41-47`) and `plan_required == true` (`plan_builder.rb:31`).
6. **Review.** `PlanReview#call` requires `semantic_critic_required == true` (`plan_review.rb:36`), a callable critic, a `decision`/`issues` shape, and one of `accept|revise|needs_input`; a non-accepting review must name issues (`plan_review.rb:63-69`).
7. **Preflight.** `Preflight.run` returns the FIRST failing check id in `CHECK_IDS` order (`preflight.rb:193-200`).
8. **Execute.** `EffectExecution#call` yields `@performed = true` then calls `EffectDispatcher.run(...)` with the `healing.<digest>` operation (`effect_execution.rb:30-43`).
9. **Ambiguity.** `:unknown`/`:wait` terminate `:unresolved` with `effect_unknown` (`session.rb:169-181`).
10. **Verify.** `Oracle.verify(rule:, toolbox:)` — the only producer of `passed` (`oracle.rb:66`), digest-pinned (`oracle.rb:72-73`).
11. **Recover or compensate.** `recovered` requires `verification.passed` (`session.rb:191-197`, re-asserted by `validate_terminal_state!` at `session.rb:238-243`); otherwise `CompensationFlow` runs (`compensation_flow.rb:20-28`).
12. **Escalate.** Every non-recovered terminal writes `EscalationPayload` to the sink (`session.rb:247-262`).

## Lens: correctness

**Reviewed.** The protocol is a faithful encoding of design §2's state machine (`remediation.rb:51-56` vs `documentation/design/self-healing.md` "The state machine"). Terminal-state honesty is structurally enforced: `validate_terminal_state!` refuses `:recovered` without a passing verification (`session.rb:240-243`) and re-raises propagating failures (`session.rb:244`), and `Outcome#oracle_backed?` (`outcome.rb:21`) lets an auditor re-check the invariant on the returned value.

One classification asymmetry, `minor`: when a rule does not authorize a category's table family, `family_unauthorized_decision` sets `abstained: false` and `action_family: :contain_escalate` (`classification.rb:212-220`, reached from `classification.rb:169`). Functionally safe (`route` escalates, `mutating?` false) but the abstention *count* in `Matrix#tally` (`matrix.rb:50`) omits it, so a rule that refuses every family it triggers on reports `abstention_rate` below 1.0 and `PromotionGate`'s `:total_abstention` reason (`promotion_gate.rb:49-52`) does not fire — a conservative failure direction, no unsafe action.

**Critical bound violation** — see `F20-REL-01` below. Everything else in this lens is sound.

## Lens: security and authority

**Reviewed.**

- **No untrusted-prose path to a mutating family.** `FailureRecord` stores only a `{digest, source, bytes}` reference and refuses `text`/`message`/`body` keys (`failure_record.rb:359-371`); `typed_signal` omits `untrusted_message_ref` (`failure_record.rb:155-173`); `classify` reads only the typed signal. `LegacyTextAdapter::Proposal#mutating?` is hardcoded `false` (`legacy_text_adapter.rb:31`), and `build` raises if a mutating family is paired with `abstained` or `never_mutate` (`classification.rb:239-243`, `build` is a private class method).
- **Five never-mutate classes are structurally enforced**, not just declared: a rule may not even *trigger* on one (`rule.rb:384-389`), `never_mutate_decision` downgrades its table family to `:contain_escalate` (`classification.rb:177`), and `Matrix`/`PromotionGate` assert the property over the whole table (`matrix.rb:52`, `promotion_gate.rb:54-60`).
- **Oracle cannot be model text.** `ORACLE_KINDS = %w[configured_check]` (`rule.rb:83`), the pin must be a `sha256:` digest (`rule.rb:547-552`), and `Oracle.digest_for` recomputes from the toolbox's operator-configured argv (`oracle.rb:50-60`).
- **Scope intersection at preflight.** `rule_target_environment_behavior_match` requires `rule.scope_authorized?(target_resource)` (`preflight.rb:95-100`), and the three OpenClaw negative cases read no read-evidence shortcut (`preflight.rb:130-161`).
- **In-band guard is identity-independent of the caller's `actor:` string** — a thread-local depth counter (`scope.rb:24-51`), proven by execution (probe: `SelfModificationError` / `SelfPromotionError` raised from inside `Scope.in_band`, and `in_band?` false after the block).
- **No hardcoded verdict or bypass flag in production paths.** The gem references no approval-policy data; its gate is on caller-supplied evidence, and the peer is found by the probe. See `F20-SEC-01` for the residual concern about what that string actually proves.

## Lens: reliability and durability

**Reviewed, with the critical gap.** The `:circuit_open` terminal, the ambiguous-effect `:unresolved` terminal, the version-first `from_h` gates (`failure_record.rb:225-234`, `rule.rb:248-255`), the allowlist (`healing.rb:30-36`) and the append-only version history (`rule_registry.rb:134-148`) are all real and probe-confirmed.

What is **not** present anywhere in this gem is a bound on how many times the protocol may attempt one failure. Drill-down, first principles, stated precisely:

- `remediation.rb:63` takes `attempt: 1` and passes it straight into the session (`remediation.rb:71`). Neither `validate_records!` (`remediation.rb:78-85`) nor `build_session` (`remediation.rb:88-107`) validates it.
- In `session.rb`, `@attempt` appears **four** times (`session.rb:19,46,84,258`) and **never in a comparison** — it is carried into `AttemptEvidence#transition_for` (`attempt_evidence.rb:46`), `EscalationPayload` (`escalation_payload.rb:46`), and the `Preflight::Context` (`preflight_check.rb:19`). Nothing reads it as a limit.
- The one budget that *sounds* like an attempt limit, `budgets["max_attempts"]`, is a **static rule field**, not an attempt counter: `Preflight` compares the *caller-supplied* `context.attempt` against it (`preflight.rb:118-124`). Since the caller owns `attempt:`, the same caller can pass `attempt: 1` on every cycle and the check passes forever. It is an effective non-bound.
- `budgets["max_attempts"]` is additionally capped at `EffectDispatcher::MAX_ATTEMPTS` = 3 (`rule.rb:510-520`), so even a cooperative caller can only raise it to 3.
- At the effect layer, the `healing.<digest>` operation makes the remediation effect **idempotent-by-replay** for a given (trace, operation, rule version, form): cycle 2 for the same fingerprint finds a terminal `succeeded` receipt and replays it (`reused=true`, `effect_attempt_number=1`) instead of dispatching a new mutation. That is a *dedup* property, not a bound — and it makes the effective repair budget **1**, uncounted and unrecorded.
- A genuinely fresh mutation requires a new rule version (or new trace/operation). Nothing in this gem, or in any production caller (there are none — see Blind spots), restricts how many such versions may be minted for one fingerprint.

Consequently the repository's *only* implemented repetition bound is the circuit, and the circuit cannot see a repeat. `MemoryCircuitStore#record_failure` increments a bare counter and opens at the threshold without ever comparing failure identity (`seams.rb:56-63`); its `@conditions` entries carry `kind` and free-form `context` and no fingerprint. A repeated failure is therefore not detected by identity — it is detected at all only through a counter that fires on `verification_failed` and `compensation_failed` (`session.rb:204`, `compensation_flow.rb:48`) and resets to zero on the uneven `record_success` path (`seams.rb:65-73`), and that a default-constructed session never sees (a fresh in-memory store per run, `remediation.rb:93`).

The claim in `README.md:58-62` ("up to two newly reviewed repairs with fresh approvals; a repeated action or a repeated failure stops safely rather than looping") **is** implemented — but at a different seam that this gem does not use: `SessionNodes::MAX_REPAIR_ATTEMPTS = 2` (`gems/tamoz-agent-session/lib/tamoz/agent/session_nodes.rb:26`) and, importantly, identity-keyed repetition detection via `state.fetch(:seen_failure_signatures).include?(signature)` returning `terminal_reason: 'repeated_failure'` (`gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb:128-151`). That path is the ordinary tool-repair loop; `Tamoz::Agent::Healing::Remediation.run` is never called from it or anywhere else outside `test/`.

## Lens: observability and evidence

**Reviewed.** Every transition is a durable-shaped, correlated record: `AttemptEvidence#transition_for` carries state, failure format version and fingerprint, rule id/version, plan/review digests, trace and effect ids, attempt, actor, fence, timestamp, evidence and budgets (`attempt_evidence.rb:35-52`). Classification, abstention, remediation, and stop are each observable:

- **Classification** — `:classified` transition with the full `Decision#to_h` (`session.rb:34`, `classification.rb:130-144`).
- **Abstention** — a first-class `Decision` field plus a `ClassificationAbstention` value with `category`, `confidence`, and a machine-readable `reason` (`classification.rb:121-128`; probes: `trigger_mismatch`, `below_minimum_confidence:1.0`, `never_mutate_class:unknown`). It is non-acting: `route` is `:escalated` (`classification.rb:115`) and the `:escalated` transition records the failure class (`session.rb:227`).
- **Remediation** — `:remediating` transition with effect_key, status, attempt_number and `reused` (`session.rb:156-166`).
- **Stop** — `EscalationPayload` with fingerprint, digests, terminal state, classification, preflight precondition, verification, compensation, before/after digests, transitions, and `recommended_next_action` (`escalation_payload.rb:31-74`).

Residual, `minor`: `Healing::load_record!` is public and its `RECORD_KINDS` allowlist covers only `failure` and `rule` (`healing.rb:20-36`), so **neither a remediation `Outcome` nor an escalation payload can be revived through the allowlisted entry point**. A durable escalation/outcome record has no loader in this gem.

## Lens: scalability and resource bounds

**Reviewed, with the critical gap of `F20-REL-01`.** Bounded resource limits that *are* enforced: `MAX_ID_BYTES = 256` and `MAX_CONTEXT_KEYS = 32` on the failure record (`failure_record.rb:47-48`, `331-336`); `SafeText.normalize` on every id; budgets must be positive finite numbers (`rule.rb:501-508`) and evaluated against magnitude/cost/time at preflight (`preflight.rb:118-124`); at most ONE remediation form per rule (`rule.rb:435-440`); `Preflight.run` short-circuits on the first failure so the rejection matrix is bounded by `CHECK_IDS` (11 entries, `preflight.rb:39,193-200`); the matrix tallies a fixed 12 categories (`matrix.rb:36-43`).

Unbounded: the number of protocol cycles for one failure fingerprint (no counter at all), the number of rule versions mintable for one fingerprint (`RuleRegistry` has no per-`rule_id` version ceiling), and the number of escalation records written — the null sink grows without pruning (`seams.rb:125-131`) and the `Seams` docstring pins roster semantics as a design deviation.

## Lens: maintenance and architecture

**Reviewed, and this is the gem's strongest lens.** Dependency direction is honest and narrow: `tamoz-agent-healing.gemspec:11-15` depends only on `tamoz-agent-kernel`, `tamoz-tools`, `tamoz-core`, and `agent_healing.rb:13-15` introduces no provider SDK and no `tamoz-evals` (the semantic critic is an injected callable). Healing adds no second effect engine: it dispatches through the existing `EffectDispatcher` (`effect_execution.rb:34-42`) with identity computed by `EffectIdentity` (`effect_identity.rb:27-45`), and it reuses `Tamoz::Tools::Toolbox`'s `run_check` for the oracle (`oracle.rb:75`) and `Tamoz::Mcp::MemoryCircuitStore`'s shape for the circuit seam (`seams.rb:21-36`). Ownership is explicit and documented: H3/H4 boundaries are named in `seams.rb:5-17` and `healing.rb:9-11`, and the empty seam defaults are honest (`ContainOnlyCompensation` returns `"contained"` with `receipt_digest: nil` and says so, `seams.rb:150-163`).

`minor`, maintainability: `Seams`'s stated purpose is to be replaced with durable implementations, but nothing in the repository constructs a non-default `escalation_sink`, `compensation`, `circuit` or `promotion_registry` — the only constructors are in tests. The protocol is complete but unreachable from production.

## Tests and contracts

Focused suites, one file per command:

| Command | Runs | Assertions | Failures |
|---|---|---|---|
| `ruby -Itest test/healing_failure_contract_test.rb` | 35 | 264 | 0 |
| `ruby -Itest test/healing_remediation_test.rb` | 13 | 74 | 0 |
| `ruby -Itest test/healing_matrix_test.rb` | 4 | 44 | 0 |
| `ruby -Itest test/agent_repair_evaluation_test.rb` | 8 | 55 | 0 |
| `ruby -Itest test/agent_diagnosis_catalog_test.rb` | 15 | 53 | 0 |
| `ruby -Itest test/agent_worker_failure_reason_test.rb` | 6 | 14 | 0 |

**All green.** `test/agent_change_evaluation_test.rb` and `test/agent_acceptance_workflow_test.rb` exist but **not run** — neither references `Tamoz::Agent::Healing` (they cover the improvement/acceptance surfaces, rows F23/F25).

`not found` — no test asserts a repetition bound. `test/healing_remediation_test.rb` runs each scenario exactly once; the fixture budget is `max_attempts => 2` (`test/healing_fixtures.rb:71`) and no test drives `attempt:` past 1. `test/healing_failure_contract_test.rb:326` asserts only the *ceiling* (`max_attempts` may not exceed `EffectDispatcher::MAX_ATTEMPTS`).

Probes (in `/tmp`, read-only against the repo):
- `/tmp/f20_probe1.rb` — fingerprint is stable and invariant to `observed_at_ms`/`execution_id`; `digest` is not; `load_record!` refuses a wrong kind and an unknown kind (`CheckpointCorruptionError`); `from_h` rejects `format_version: 2` with `CheckpointVersionError`.
- `/tmp/f20_probe2.rb` — abstention paths: `trigger_mismatch` (confidence 0.0), `below_minimum_confidence:1.0` (confidence 0.4), `never_mutate_class:unknown`; `abstain`/`reconcile`/`observe` are all absent from `MUTATING_FAMILIES`; `:unknown` is the only category mapping to `:abstain`.
- `/tmp/f20_probe3.rb` — sees below.
- `/tmp/f20_probe5.rb` / `probe6.rb` / `probe8.rb` — the repetition evidence for `F20-REL-01`.
- `/tmp/f20_probe7.rb` — `EffectIdentity` separates on rule version and trace id.

## Findings

### F20-REL-01 — the remediation protocol has no bound on repetitions; a repeated failure is not detected by identity and the circuit cannot stop it

| Field | Content |
|---|---|
| **Severity** | `critical` |
| **Confidence** | `high` — the absence is proven by executing the real protocol, and the counterfactual bound is located at a specific file:line in `tamoz-agent-session` |
| **Status** | `open` |
| **Source evidence** | `remediation.rb:63` accepts `attempt:` and never validates it (`remediation.rb:78-85`); `session.rb:19,46,84,258` carry `@attempt` with **no comparison anywhere**; `preflight.rb:118-124` compares the *caller-supplied* `context.attempt` against a *static* rule field; `seams.rb:56-63` counts failures with no identity comparison (`@conditions` carries only `kind` and free-form `context`); `seams.rb:65-73` resets that counter; `remediation.rb:93` defaults to a fresh in-memory circuit per run. The identity-keyed bound that the README claim matches is at `gems/tamoz-agent-session/lib/tamoz/agent/session_nodes.rb:26` and `gems/tamoz-agent-session/lib/tamoz/agent/session_evidence.rb:128-151`. |
| **Test/contract evidence** | `not found` — no test drives `attempt:` past 1 or asserts a repetition stop (`test/healing_remediation_test.rb`, 13 runs / 74 assertions / 0F). Suites above all pass, which is precisely the gap: the property is untested. Probes: `/tmp/f20_probe6.rb` (one fingerprint, 5 cycles → `performed` true on cycles 1-2), `/tmp/f20_probe8.rb` (cycle 2 performs a mutation and only *then* returns `:escalated`; `circuit_open?` becomes true only after cycle 2's failure is recorded; cycles 3-4 write escalating records with no bound in the code). |
| **Scanner signal** | Manual read of all 26 lib files; grep for `@attempt` in `session.rb` returns four uses and zero comparisons. |
| **Independent judgment** | Confirmed. I attempted to falsify it three ways and the semantics resolved precisely: (a) the budget path is inert for a caller that supplies `attempt: 1`; (b) the effect journal *does* dedup, but by replaying a terminal receipt for the same `healing.<digest>` operation — probes `/tmp/f20_probe6.rb` and `/tmp/f20_probe8.rb` both show `effect_attempt_number=1 reused=true` and a single `perform` invocation, i.e. a silent, uncounted effective budget of **1**, not a bound that stops and reports; (c) the circuit does eventually stop the loop if and only if the same circuit object is passed in, and it reaches that state **after** performing the mutation — so the first repeated cycle mutates, and the stop is by failure count, not by failure identity. This is not a "surprising code" reading: a repeated action is not stopped by identity, which is the stated contract in `README.md:61-62`. |
| **Root cause (five whys)** | 1. Why can the protocol repeat? Nothing in `Remediation` or `Session` reads or compares an accumulated count. 2. Why not? `attempt:` is treated as an opaque piece of evidence forwarded to the ledger (`attempt_evidence.rb:46`), never as a limit, and `Session` holds no cross-attempt state. 3. Why does no cross-attempt state exist? `Session` is documented and built as "one attempt, never reused, so transition state cannot leak across runs" (`session.rb:7-8`), and every collaborator is constructed fresh per call. 4. Why is that the design? Ownership of repetition was deferred: `seams.rb:5-17` and `healing.rb:9-11` assign "the durable circuit record" to P12-H3 and the circuit seam is an in-memory counter that was never given failure identity. 5. Why did no gate catch it? The only implemented bound lives in a *different gem's* repair loop (`session_evidence.rb:128-151`), so the healing protocol's own bound was never the subject of a test — no test asserts it, so nothing failed. **Contract that would prevent recurrence:** "the remediation protocol must terminate on a repeated failure fingerprint, and the healing circuit/store seam must expose failure identity (`FailureEvent#fingerprint`, already defined at `gems/tamoz-core/lib/tamoz/circuit/record.rb:34`) so the repetition is detected by identity, not by counting." |
| **Recommendation** | Smallest credible action at the existing owner seam: `Session` should carry the per-fingerprint attempt count in its circuit seam rather than trusting the caller's `attempt:` argument, and `Remediation.run` should take the repetition ceiling from the rule's existing `budgets["max_attempts"]` rather than a bare default. The existing `Tamoz::Circuit::Record::FailureEvent` (with its `fingerprint` field) is already the right value to dedupe on, and `RuleRegistry`'s append-only history already records a new rule version — so the change is a comparison, not new machinery. Nothing here needs a new class, a new gem, or a new store. |
| **Disposition** | *(coordinator)* — requires independent challenge; the severity depends on whether `Remediation.run` is reachable from a production caller before H3 lands. |

### F20-SEC-01 — the human-approval gate for a self-protected rule amendment is satisfied by a caller-supplied string prefix, not by the approval-policy seam

| Field | Content |
|---|---|
| **Severity** | `major` |
| **Confidence** | `high` for the behavior (executed); `medium` for impact (no production caller today) |
| **Status** | `open` |
| **Source evidence** | `rule_registry.rb:164-178` — `assert_reviewed_diff!` requires `reviewed_diff` to name exactly the changed fields and, for a mutation-capable rule, `approval.is_a?(String) && approval.start_with?("human:")`. `rule_registry.rb:79` accepts `approval:` and `actor:` as ordinary keyword strings; `actor:` is explicitly "RECORDED, not TRUSTED" (`rule_registry.rb:74-78`). The data seam that actually decides approvals is `gems/tamoz-approval/policy/base.yaml` + `gems/tamoz-approval/lib/tamoz/approval/engine.rb:43` (`Engine#decide`) / `Evaluator#evaluate`; this gem references neither. Also `rule_registry.rb:100-116` — `write_lifecycle_mode` has **no** human/`tamoz-evals` actor check at all, only the in-band refusal and the promotion-record digest binding. |
| **Test/contract evidence** | `test/healing_failure_contract_test.rb:390` (`test_an_out_of_band_amendment_still_needs_a_reviewed_diff_and_human_approval`) exercises a refused and an accepted amend; the accepted one passes `approval: "human:owner approved diff abc"` (`:419`). Probe `/tmp/f20_probe3.rb` confirms an amend with `approval: "human:ops"` and `actor: "evil"` succeeds with no approval engine involved. |
| **Scanner signal** | `grep -rn "approval|Approval" gems/tamoz-agent-healing/lib` returns four hits, all in `rule_registry.rb` + `rule.rb`; none reaches `tamoz-approval`. |
| **Independent judgment** | Confirmed as behavior. The gate structure (must name the exact delta; approval only for mutation-capable rules) is genuinely good and correctly fail-closed against an *absent* argument — an amend with no `approval:` raises `SelfModificationError`. What is not proven is that a `"human:"`-prefixed string is evidence of an approval decision: any caller able to reach `RuleRegistry#amend` also mints the string. I therefore do not claim an active authority bypass in production — the registry has no production caller I could find — but the *contract* is weaker than "comes from the approval policy data seam". |
| **Root cause (five whys)** | 1. Why is a bare string enough? The registry validates the *shape* of the evidence it is handed rather than resolving a decision from the policy owner. 2. Why validate shape? The registry's job is defined as the invariant-34 guard rail (`rule_registry.rb:6-20`), not an approval client, and taking an `Engine` dependency would widen the gemspec beyond kernel/tools/core. 3. Why was that acceptable? H4 owns the promotion lifecycle and the durable side (`seams.rb:165-179`), so the human gate was left as a caller obligation until then. 4. Why did nothing catch it? No test asserts that the approval was *produced by* an approval decision — the test asserts only that a `"human:"` string is accepted and a missing one is refused. 5. Why does that shape persist? The repository makes the same pattern explicit elsewhere ("approval policy is data too", `AGENTS.md`), but this seam was never brought under it. **Contract that would prevent recurrence:** "an out-of-band amendment of a self-protected field must present a resolved approval decision (policy revision + grant/decision id), not a self-describing prefix." |
| **Recommendation** | Smallest credible action at the existing owner seam: accept the approval **decision** object `Tamoz::Approval::Engine#decide` already returns (it carries the verdict and policy revision) in place of the `"human:"`-prefixed String, and require the same for `write_lifecycle_mode`. No new class; the value already exists one gem over. |
| **Disposition** | *(coordinator)* — confirm reachability before severity; if `Remediation.run`/`RuleRegistry` are unreachable in production until H4, this is a contract gap rather than an active bypass. |

### F20-OBS-01 — neither a remediation outcome nor an escalation payload can be revived through the allowlisted loader

| Field | Content |
|---|---|
| **Severity** | `minor` |
| **Confidence** | `high` |
| **Status** | `open` |
| **Source evidence** | `healing.rb:20-36` — `RECORD_KINDS = {"failure" => FailureRecord, "rule" => HealingRule}`; `Healing.load_record!` raises `CheckpointCorruptionError` for any other kind. `Outcome` (`remediation/outcome.rb:10-24`) and the `EscalationPayload` hash (`escalation_payload.rb:22-27`) are produce-only; neither declares a `format_version` / `from_h`. |
| **Test/contract evidence** | `test/healing_failure_contract_test.rb:194` asserts the allowlist is exactly `%w[failure rule]` — i.e. the current behavior is pinned deliberately. Probe `/tmp/f20_probe1.rb` confirms `load_record!("rule", <failure payload>)` and `load_record!("nope", ...)` both raise `CheckpointCorruptionError`. |
| **Scanner signal** | `grep -n "from_h" gems/tamoz-agent-healing/lib` hits only `FailureRecord` and `HealingRule`. |
| **Independent judgment** | Confirmed, but scoped as minor rather than major: this is a **declared** H3/H4 boundary (`seams.rb:99-118` says builder B replaces `NullEscalationSink` with the durable owned issue record), not a silent loss. The consequence today is that escalation evidence is bounded by the process — the in-memory sink is never pruned (`seams.rb:125-131`) and `escalation_id` is a positional `"escalation.N"` that collides across runs (probe `/tmp/f20_probe8.rb`: four escalating records for one fingerprint, ids `escalation.1..4`, all with the same `failure_fingerprint`). |
| **Root cause** | The durable escalation record was deferred to H3, so the produce path was built and the revive path was not; the null sink's counter-derived id was adequate for tests and never revisited. |
| **Recommendation** | When H3 lands the owned issue record, key its id on the failure fingerprint rather than a positional counter — the fingerprint is already in the payload (`escalation_payload.rb:33`) and is already the design §10 correlation key. No change to the protocol. |
| **Disposition** | *(coordinator)* — defer to H3; record as a known deviation, not current debt to fix now. |

### F20-COR-01 — a family-unauthorized classification escalates correctly but is not counted as an abstention

| Field | Content |
|---|---|
| **Severity** | `minor` |
| **Confidence** | `high` |
| **Status** | `open` |
| **Source evidence** | `classification.rb:212-220` sets `abstained: false, action_family: :contain_escalate` with `reason: "family_not_authorized:..."`; reached from `classification.rb:169`. `matrix.rb:50` counts only `result.abstained` into the `'abstained'` bucket; `promotion_gate.rb:49-52` derives `:total_abstention` from `abstention_rate`. |
| **Test/contract evidence** | `not found` — no test exercises `family_not_authorized`. `test/healing_matrix_test.rb` (4 runs / 44 assertions / 0F) covers the never-mutate and total-abstention cases only. |
| **Scanner signal** | Reading `classify`'s five `return` paths against `Decision#route` and `Matrix#tally`. |
| **Independent judgment** | Confirmed. Failure direction is conservative — there is no unsafe action, and `P12 §3`'s "100% abstention cannot be promoted" is only *under*-enforced for a rule that refuses every family it triggers on. `abstention_quality`'s `over_abstention_rate` (`matrix.rb:92`) shares the same blind spot, so the score is optimistic in the same direction. |
| **Root cause** | `abstained` was defined as "the classifier could not decide" while `family_not_authorized` is "the rule declined"; the matrix's abstention axis inherited only the first meaning. |
| **Recommendation** | Count `family_not_authorized` in the matrix's abstained axis (or add a `refused` counter beside it) — a tally change in `matrix.rb#tally`, no protocol change. |
| **Disposition** | *(coordinator)* — minor; safe direction. |

### F20-MNT-01 — the documented seam replacements have no non-test constructor; the protocol is complete but unreachable

| Field | Content |
|---|---|
| **Severity** | `minor` |
| **Confidence** | `high` |
| **Status** | `open` |
| **Source evidence** | `remediation.rb:93-97` defaults `circuit`, `escalation_sink`, `compensation`, `clock`; `seams.rb:5-17` states H3/H4 will supply the durable implementations. `grep -rn "Remediation" gems/ apps/ bin/ --include=*.rb` outside `gems/tamoz-agent-healing` returns **zero** hits; `grep -rn "RuleRegistry"` outside the gem returns zero production hits. `gems/tamoz-agent-healing/lib/tamoz/agent/healing.rb` is required by `gems/tamoz-agent/lib/tamoz/agent.rb:18`, and `gems/tamoz-agent-session/lib/tamoz/agent/session_records.rb:99-106` persists a `healing_pin`, but no runtime calls `Remediation.run` or `RuleRegistry`. |
| **Test/contract evidence** | `not run` for any end-to-end production path — there is none to run. The six focused suites above all construct the gem directly. |
| **Scanner signal** | Repo-wide grep for the gem's public entry points. |
| **Independent judgment** | Confirmed as a fact. I record it as `minor` and not as a defect: the empty seams are honestly labeled (`contain_only` returns `"contained"` with `receipt_digest: nil` and says "no compensation executor is installed", `seams.rb:150-163`), and the session-side pin plumbing exists, so this is an H3/H4 integration boundary — but it is also why `F20-SEC-01`'s impact is conditional and why no production caller supplies the repetition bound `F20-REL-01` needs. |
| **Root cause** | H3/H4 have not landed; the gem was built to be complete and testable ahead of them. |
| **Recommendation** | None beyond what `seams.rb` already prescribes — when H3 lands, the durable circuit must carry `FailureEvent#fingerprint` (`gems/tamoz-core/lib/tamoz/circuit/record.rb:34`) so `F20-REL-01` is closed at the seam that replaces the in-memory counter. |
| **Disposition** | *(coordinator)* — info-level scheduling fact; keep open until H3/H4 land. |

### Prior finding carry-forward — top-100 #100 (`docs/audits/top100-audit-2026-09-11/100-failure_record.md`)

**Current status: closed, verified against current source.**

- The shared failure value **landed**: `Tamoz::Circuit::Record::FailureEvent` is `Data.define(:kind, :context_digest, :run_id, :fingerprint)` (`gems/tamoz-core/lib/tamoz/circuit/record.rb:34`), consumed by `with_failure(owner_id:, now_ms:, event:)` (`record.rb:346`) and constructed by the SQLite circuit store (`gems/tamoz-sqlite/lib/tamoz/sqlite/circuit_store.rb:126`), with conformance coverage in `test/circuit_record_test.rb:64`. It still carries a `fingerprint`.
- The **0-ParameterLists fix** is in place: the four occurrence fields are grouped into one `FailureEvent` value so `with_failure` names only actor and clock alongside it (`record.rb:29-33`).
- **Gap carried forward explicitly:** `gems/tamoz-agent-healing/lib` never uses this value — `grep -rn "Circuit::Record|FailureEvent" gems/tamoz-agent-healing/lib` returns **zero** hits. The shared value exists one gem over; this gem's circuit seam is an independent in-memory counter without identity (`seams.rb:37-97`). That is exactly the mechanism behind `F20-REL-01`, and it is the reason I do not record #100 as fully closed for this row's purposes.
- The `FailureRecord` shape and identity are otherwise re-verified current: `format_version` is checked before any field is read in both `from_h` (`failure_record.rb:230-234`) and direct construction (`failure_record.rb:278-283`), both raising `CheckpointVersionError` (the #100 `[minor][ERR]` single-spelling fix holds); the two dead readers are gone; `fingerprint` (`failure_record.rb:178`) is typed-only and probe-confirmed invariant to `observed_at_ms` and `execution_id`, while `digest` (`failure_record.rb:192`) is not. The #100 `[major][SIZE]` overage remains **declined and silenced** in `.rubocop_todo.yml` (10 entries exclude `failure_record.rb`), matching the recorded resolution — I do not re-litigate it.

**Overlap with this audit's findings:** none. `FINDINGS.md` records F07-SEC-01, F21-SEC-01, F25-SEC-01, CF04-REL-01, F07-REL-01, CF05-SEC-01 — all in `tamoz-sqlite`, `tamoz-agent-profile`, `tamoz-agent`, `tamoz-agent-kernel`, `tamoz-mcp`. `F20-REL-01` is a distinct seam (`tamoz-agent-healing` `Session`/`Seams`, not `EffectDispatcher` status selection), though it shares the *shape* of CF04-REL-01's "the dispatcher's retry semantics are the load-bearing gap" concern; a challenge pass should confirm they are not the same defect.

## Blind spots

- **No production caller exists**, so I verified the repetition bound by driving `Remediation.run` directly (`/tmp/f20_probe5.rb`, `probe6.rb`, `probe7.rb`, `probe8.rb`) rather than through a real session. If a future caller passes a monotonically increasing `attempt:`, the `within_attempt_scope_magnitude_cost_time` check *would* fire — so the practical exposure depends entirely on the caller H3 wires. That caller is the one thing that would change `F20-REL-01`'s blast radius, and it does not exist yet.
- **I did not run** `test/agent_change_evaluation_test.rb` or `test/agent_acceptance_workflow_test.rb` (present, but neither references `Tamoz::Agent::Healing`; they belong to F23/F25).
- **I did not audit the SQLite effect journal's own attempt accounting** beyond the `MAX_ATTEMPTS`-vs-`current_attempt` interaction (`gems/tamoz-sqlite/lib/tamoz/sqlite/effect_attempt_ledger.rb:48-56` grants the next attempt). Whether that path can itself loop is F07's row; I relied on the observed `reused=true` replay to conclude the healing effect is idempotent-by-replay.
- **`Tamoz::Sqlite::CircuitStore`** is named in `seams.rb:32-35` as the H3 replacement but does not implement the `Seams` interface today; I did not read it for compatibility.
- **The promotion lifecycle (H4)** — `PromotionGate` was read as a pure predicate module; the eval-side producer of promotion records is `tamoz-evals` and belongs to F26/F27.
- **`tamoz-agent-improvement`** shares the "bounded self-healing" vocabulary (`gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/errors.rb:5`); I did not read it, and a vocabulary-overlap check belongs to F23.

## Verdict

**IMPROVE** — `critical: 1`, `major: 1`, `minor: 3`, `info: 0`.

The gem clears the bar on **security and authority**, **observability**, **maintainability**, and most of **correctness** and **reliability**: abstention is genuinely first-class, non-acting and machine-readable; the rule record is provably immutable under an executed self-edit attempt; `recovered` is reachable only through a digest-pinned configured check; and the design §5 negative cases are real predicates, not prose. It fails the bar on **scalability/resource bounds** because the reviewed change loop's central promise — that a repeated failure stops safely rather than looping — is implemented in `tamoz-agent-session`'s ordinary repair path and **not** in this vertical, which has no repetition bound at all and no identity-keyed repeat detection.

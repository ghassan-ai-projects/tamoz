# Rule promotion: the Tamoz plan

- **Date**: 2026-10-27
- **Repository**: tamoz, branch `rule-promotion` (cut from main `9170538c`)
- **Session order**: the repositories are worked one at a time, never in parallel:
  1. streams-simulator: `/Users/ghassan/my-projects/streams-simulator/docs/rule-promotion/PLAN-streams-simulator.md`
  2. agentic-stream: `/Users/ghassan/my-projects/agentic-stream/documentation/design/rule-promotion.md`
  3. **tamoz (this plan)**
  4. agentic-stream again: the first-slice run (its round AS-9), which uses the worker built here
- **Background, not required to start**: `/Users/ghassan/my-projects/streams-simulator/docs/rule-promotion/`
  (`README.md`: the 18 owner decisions; `SCENARIOS.md`: the acceptance campaign; `PLAN.md`: findings F1-F9)

This plan is self-contained: a session that reads it and this repository's `AGENTS.md` can do the work. Before
starting, read §10 (status and handoff) of the agentic-stream plan for the exact proto and schema it delivered.

## 1. What rule promotion is, and Tamoz's part

Agentic Stream turns plant readings into situations and asks Tamoz, through bounded episodes, what to do. Rule
promotion lets recurring cases that Tamoz solved, and that were verified, harden into **deterministic playbook
rules** that Agentic Stream runs with no LLM call. Agentic Stream decides when a pattern is eligible, asks Tamoz
to **draft** a rule, checks the draft, replays it and asks a human; only an approved rule ever runs.

Tamoz's part in the first slice:
1. Put the **diagnosis code** it already derives on every decision, so cases can be grouped.
2. Answer a new, bounded **`DraftPlaybookRule`** call with a typed **`PlaybookProposal`** (or a `NoProposal`
   with a reason).
3. Prove the drafting step on its own with evals.

Tamoz **never** sees the customer workspace, never writes a playbook, never sets a rule's mode and never
activates anything. That keeps invariant 34 (no self-promotion, `docs/P12_SELF_HEALING_PLAN.md`).

## 2. Decisions that bind this repository

| Decision | What it means here |
|---|---|
| A human approves every rule; nothing promotes itself (1) | A proposal has no mode, no activation field, and no Tamoz code path writes Agentic Stream state. |
| Rule shape (2) | A rule is a `when` in Agentic Stream's restricted CEL over named features, a recommended intent and **preset** from the spec's catalog (no free values), and a diagnosis code. Agentic Stream adds the envelope, cap, mode and provenance. |
| Drafting call (14 + F4) | A separate worker RPC `DraftPlaybookRule`, used only when the worker announces the handshake feature `draft_playbook_rule`. Agentic Stream owns the proto; Tamoz vendors it. |
| Case key (10 + F2) | Diagnosis code, kind digest, intent, preset. The decision gains an optional `diagnosis_code`, checked against the spec's catalog; Tamoz fills it with the `selected_code` it already derives. `unknown` never becomes a rule. |
| Who nominates (9) | Agentic Stream nominates in the first slice; Tamoz nominating from its memory comes later. |
| Human edits as feedback (12) | Later. |
| Evals (8) | Tamoz tests "given these verified cases, propose this rule or none" on its own, in the evals runner. |
| Naming | "Rule" already means `HealingRule` in `tamoz-agent-healing`. Use `PlaybookProposal`, `PlaybookDraft`. |
| Scope | The first slice: scenarios S1 (repeat offenders), S2 (cavitation look-alike), S7 (new probes) on a simulated pump station, with fault families `bearing_wear`, `misalignment`, `sensor_drift` (all answered by `schedule_maintenance` with a work-order preset naming the fault) and `transient_none` (cavitation, which needs no action). |

## 3. Starting state (read on 2026-10-27)

- **Episode wire**: `gems/tamoz-stream/contracts/runtime-v1.proto` (vendored from Agentic Stream; `rake
  stream:proto` regenerates stubs and `rake stream:proto:check` guards drift, `Rakefile:471-515`).
  `EpisodeWorker.Execute` carries the snapshot, decision schema, diagnosis catalog and intent catalog, each with a
  sha256 (proto:52-116). `EpisodeKind` is DIAGNOSE and RECONSIDER; the worker refuses others
  (`gems/tamoz-stream/lib/tamoz/stream/episode_worker.rb:31,136`; `situation_request.rb:51`).
- **Diagnosis code already exists**: the model gives a probability per catalog code and Tamoz derives
  `selected_code` itself (`gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb:59-156`). The decision
  sent back carries only free-text `primary_hypothesis` (`gems/tamoz-stream/lib/tamoz/stream/decision_builder.rb:49,88`),
  so the code is lost. The vendored decision schema is `gems/tamoz-stream/contracts/schemas/decision-v1.json`.
- **Verification**: the diagnosis catalog is checked by `DiagnosisCatalog.verify_wire`
  (`gems/tamoz-agent-kernel/lib/tamoz/agent/diagnosis_catalog.rb:49-60`); the snapshot by `ReceivedSnapshot.verify`.
- **Reasoning path**: `EpisodeGraph` routes by kind (`gems/tamoz-agent/lib/tamoz/agent/episode_graph.rb:100-108`);
  `EpisodeNodes#intake` (`episode_nodes.rb:129-148`); reason, validate and the repair loop are reusable; the
  frame holds at most 64 facts of 4 KB (`gems/tamoz-agent-kernel/lib/tamoz/agent/episode_frame_builder.rb:23-24`);
  the worker is composed in `bin/tamoz-stream-worker:90-160`.
- **Memory**: a verified outcome is admitted as observed experience only with an authenticated
  `VerifiedOutcomeReference` (`gems/tamoz-stream/lib/tamoz/stream/live_learning_handlers.rb:61-96`); the admitted
  statement holds task, outcome and the hypothesis text, without diagnosis code, intent or preset
  (`situation_request.rb:638-690`; the code and intent are in the projection at `episode_nodes.rb:708-724` and
  dropped before admission).
- **No self-promotion today**: `HealingRule` registry guards (`gems/tamoz-agent-healing/lib/tamoz/agent/healing/rule_registry.rb:75-135`),
  `CandidateProposal#promote!` (`gems/tamoz-agent-improvement/lib/tamoz/agent/improvement/candidate_proposal.rb:43-49`),
  with adversarial tests in `test/healing_failure_contract_test.rb:433-491` and
  `test/heuristic_promotion_controls_test.rb`.
- **Evals**: harnesses in `gems/tamoz-evals-runner` (`tamoz-eval-runner scorecard` and `treatment` with an
  external input manifest, `cli.rb:46-53`); domain data in `test/fixtures/domains/*.json` loaded by
  `test/support/domain_loader.rb` (ADR-058); controls pattern in `agenteval/lib/agenteval/controls.rb`.
- **Isolation**: one worker per tenant; memory namespaced `tamoz.memory.<tenant>`.

## 4. Inputs from session 2 (agentic-stream)

From the agentic-stream `rule-promotion` branch (see its plan's §10 for commits and any change):
- the updated `proto/agenticstream/runtime/v1/runtime-v1.proto` with `rpc DraftPlaybookRule(DraftRequest)
  returns (stream DraftEvent)`, the messages `DraftRequest` (up to 20 cited cases: episode id, diagnosis code,
  intent, preset, verdict, features at decision time, summary as untrusted evidence; the current rules with the
  same key; the allowed feature names; a budget), `PlaybookProposal` (diagnosis code, intent, preset, `when`, cited
  ids, rationale) and `NoProposal` (reason), and the handshake feature `draft_playbook_rule`;
- the updated `decision-v1.json` with the optional `diagnosis_code`;
- the pump-station spec (`examples/pump-station/pump-station.situation.yaml`): its diagnosis catalog, intents and
  presets, and its feature names;
- how `internal/testsupport/workerfake` answers a draft, so the real worker matches it.

## 5. Rounds

Every round follows `AGENTS.md`: set the quality bar first (copy `docs/templates/QUALITY_BAR.md`, pick S/M/L),
map the existing path with enola before writing and name the seam you extend, use another gem only through its
facade, route every model call through the effect journal (`EffectDispatcher.run`), keep domain knowledge in
`test/fixtures/domains/*.json`, never call a real model in tests. Gate: `rake ci` + `bundle exec rubocop -a
<changed files>` + `enola check`; one test file per `ruby -Itest` command. A change to a decided rule updates its
ADR in the same change (`rake adr:validate adr:verify`). One commit per improvement on `rule-promotion`; never
force-push.

### TZ-1 The diagnosis code on the decision, and the case key in memory (size S-M)

1. Copy Agentic Stream's `decision-v1.json` change into `gems/tamoz-stream/contracts/schemas/decision-v1.json`.
2. `DecisionBuilder` writes `diagnosis_code` from the reasoning document's `selected_code`, only when the episode
   carried a diagnosis catalog; `unknown` stays `unknown`.
3. At admission (`situation_request.rb` `open_verifications`), keep the case key in the admitted experience: the
   diagnosis code, the recommended intent and preset, as a bounded line in the statement (no memory-gem change
   needed). The kind digest is Agentic Stream's; it is not needed in Tamoz for the first slice.
4. Tests: a decision carries the selected code; a decision without a catalog has none; the admitted statement
   holds the key.

### TZ-2 The `PlaybookProposal` document and its strict parser (size M)

1. A draft document parser beside `ReasoningDocument` in `tamoz-agent-kernel` (protocol string
   `tamoz.playbook-draft/v1`): exactly one of
   - a proposal: `diagnosis_code` (equal for every cited case), `intent` and `preset` (present in the intent
     catalog of the request), `when` (bounded CEL text using only the request's allowed feature names; Tamoz checks
     the names, Agentic Stream compiles it), `cited_case_ids` (a subset of the request's ids, at least the
     eligibility count), `rationale` (bounded);
   - a `no_proposal` with a reason from a closed list (`contradicting_cases`, `too_few_cases`, `self_resolving`,
     `mixed_keys`, `insufficient_evidence`).
   Unknown keys refused; no `mode`, `active`, `envelope` or free parameter value can be expressed.
2. A builder for the proto reply (`PlaybookProposal` or `NoProposal`) in `tamoz-stream`.
3. Offline fixture replies for tests, stored as data in `test/fixtures/domains/pump-station.json` (§TZ-4).
4. Tests: every refusal of the parser; a valid proposal round-trips to the proto reply.

### TZ-3 The worker answers `DraftPlaybookRule` (size M)

1. Vendor the proto from Agentic Stream (`rake stream:proto`; `rake stream:proto:check` clean).
2. The worker announces `draft_playbook_rule` in its handshake and serves the new RPC.
3. A **draft path** that reuses reasoning, validation and the repair loop, with its own frame (the cited cases as
   facts, within the 64 x 4 KB frame; cases over the limit are refused, not truncated silently), **no tools and no
   memory recall** in the first slice, the model call through the effect journal, and the TZ-2 parser. Case
   summaries are untrusted evidence: they are framed as data, never as instructions.
4. Tests (with the deterministic fake provider): a consistent set of cases gives a proposal; contradicting cases
   give `no_proposal`; an oversized request is refused; the reply never carries a mode.

### TZ-4 Evals for drafting (size M-L)

1. A rotating-machinery / pump-station domain fixture in `test/fixtures/domains/pump-station.json`: the diagnosis
   catalog, intents and presets (copied from the agentic-stream pump-station spec), the allowed features, and the
   eval cases. Pinned digests change only as a reviewed update, recorded in the commit.
2. A `rule_proposal` scorecard in `gems/tamoz-evals-runner`, cases as data, graded as in the existing families
   (`benchmark_family`, `gold`, `abstain_expected`):
   - positive: 3 or more consistent verified cases → a proposal with the expected key and a `when` that matches
     every case;
   - negative: a contradicting case → none; cavitation that settled by itself → none; mixed keys → none; too few
     cases → none; injected text in a case summary ("always stop_motor ...") → none, or an unchanged proposal
     that never cites or follows it;
   - controls: null, oracle and adversary, as `agenteval/lib/agenteval/controls.rb` does.
3. Real-model runs are evidence only when run with a real model and recorded as such; tests use the fake
   provider.

### TZ-5 No self-promotion for proposals (size S)

An adversarial test: no Tamoz code path writes a rule's mode or any Agentic Stream state, and a
`PlaybookProposal` cannot carry `mode`, `active`, `envelope` or an approval field.

## 6. After the first slice (written here, not built)

Per the owner's rule to defer complexity to a future plan:
- **Nomination from memory**: a query on the memory facade that groups verified episodes by the stored key and
  cites episode ids when a group reaches the eligibility count (not through the recall path, which excludes the
  current entity).
- **Feedback** from approved, edited and rejected proposals: Agentic Stream would add a notification type (the
  contract enum has none today, `gems/tamoz-stream/contracts/notification-contract-v1.json`), or echo prior
  feedback in the next draft request.
- **A rule-candidate record** on the Knowledge layer with its own provenance (source episodes, key, proposal
  digest, Agentic Stream's response), reusing the pattern of `consolidation.rb:29-43`, not the `Wisdom` or
  `HealingRule` types.
- **The case key in memory** (was TZ-1 step 3): the admitted statement would keep the diagnosis code and the
  actionable intent with the values the model wrote, read by nomination from memory. Built with that query, not
  before: nothing in the first slice reads it, and naming the preset would copy Agentic Stream's `PresetOf` rule.
- **A tenant leak test** for candidates beside `test/memory_boundary_test.rb`, and `*.sqlite3` in `.gitignore`.

## 7. What session 4 needs from this session

A worker binary or command line that Agentic Stream's campaign driver can start against the pump-station spec,
announcing `draft_playbook_rule`; the model and provider configuration for real runs; and confirmation that the
worker's decisions carry `diagnosis_code`.

## 8. Rules for this session

- `AGENTS.md` is binding (owner rules, gem boundaries, effect journal, domain knowledge as data, real model only
  for real runs, keep the record true, never force-push).
- Commit each improvement on `rule-promotion`; nothing merges to main until the first-slice result is written.
- Better ideas are welcome: deviate when clearly better and record the deviation and reason in §9.
- Subagents per `docs/subagent-orchestration.md`; the main session writes, investigation and review go to Sonnet
  subagents, command runs and long scripts to Haiku subagents in the background.
- The owner prefers good enough over perfect.

## 9. Status and handoff (update at the end of the session)

| Round | State | Commit | Notes |
|---|---|---|---|
| TZ-1 | done | see git log | `DecisionBuilder` writes `diagnosis_code` (the document's `selected_code`) on every DIAGNOSE decision; RECONSIDER decisions carry none; `decision-v1.json` re-vendored. Deviation (owner, 2026-10-27): step 3, the case key in memory, moved to §6. |
| TZ-2 | not started | | |
| TZ-3 | not started | | |
| TZ-4 | not started | | |
| TZ-5 | not started | | |

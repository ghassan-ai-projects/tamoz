# Review log and correction loop

This log records how the study was produced and how claims were tightened. The
goal is to make the report reusable as an implementation baseline rather than a
one-time opinion.

## Pass 0 — define the bar

Created `00-report-bar.md` before the repository comparison. It defines:

- technical and non-technical deliverables;
- evidence classes and confidence labels;
- completeness dimensions;
- decision-quality gates;
- the required artifact set and definition of done.

The bar explicitly separates source evidence, focused-test evidence, live
runtime observation, and inference. It also requires the final report to state
what was not verified.

## Pass 1 — five independent OpenClaw reviews

The same five reviewer roles were assigned different lenses so that the report
would not reduce chat quality to one subsystem:

| Reviewer | Lens | Result |
| --- | --- | --- |
| Chandrasekhar | Shared architecture, lifecycle, routing, state, persistence | Completed |
| Goodall | Telegram ingress, commands, callbacks, progress, delivery | Completed |
| Halley | CLI/TUI interaction, streaming, controls, terminal semantics | Completed |
| Sartre | Safety, trust boundaries, cancellation, reliability, operations | Completed |
| Godel | Tests, scenario coverage, evidence quality, critique of claims | Completed |

The reviewers inspected `/Users/ghassan/external-projects/openclaw` from their
assigned perspectives. Their findings converged on a shared turn kernel,
durable ingress/outbox, stable identity, explicit states, bounded progress,
context controls, and honest recovery. They also identified limits: the review
was primarily static, usefulness was inferred from design and tests, and the
trusted-one-operator model is not a safe default for Tamoz.

The findings were consolidated into:

- `01-openclaw-technical-report.md`;
- `02-openclaw-product-report.md`;
- `07-evidence-index.md`.

## Pass 2 — five Tamoz reviews using the same roles

The five completed agents were closed and then resumed for the second pass,
preserving the same reviewer lenses while releasing execution slots. Each
received a distinct Tamoz prompt:

1. current architecture and root causes;
2. Telegram behavior and OpenClaw comparison;
3. CLI/UX and communication contract;
4. safety, reliability, and operability;
5. tests, scenarios, and evidence critique.

Their findings converged on a precise diagnosis: Tamoz already has durable
admission, request leases, checkpointed sessions, effect journaling, bounded
outbox delivery, and unknown outcomes. The dominant user problem is a missing
shared projection of those facts.

The pass also found correctness issues that must not be hidden behind UX work:

- a stale delivery-owner/fence path that needs an explicit takeover test and
  stronger result ownership;
- Telegram payload hashing and message identity that do not match their stated
  integrity meaning;
- declared limits that need boundary enforcement verification;
- known Telegram commands that are parsed but unavailable;
- history/status behavior that can blur delivery truth and task truth;
- callback acknowledgement and prompt activation without a confirmed complete
  crash-boundary journey.

## Correction loop

After the second pass, the report was corrected against the quality bar:

- added the Tamoz current-state artifact instead of jumping directly to a target;
- named existing Tamoz seams before proposing extensions;
- kept the target as a thin projection over request, session, effect, and outbox
  truth;
- separated task state from delivery state;
- marked static findings, focused-test evidence, live evidence, and inference;
- retained uncertainty around pairing challenge issuance and live Telegram
  behavior;
- rejected copying OpenClaw's trust assumptions, permissive routing, blind
  retries, and token streaming;
- added a scenario matrix with composition tests needed to close the evidence
  gaps;
- recorded a real sandbox limitation: the Telegram fixture server could not
  bind localhost due to `EPERM` in the review environment.

## Pass 3 — code-verification audit (2026-08-22)

A follow-up audit re-verified every Tamoz code claim in the study and the plans
against the current source (two independent verification passes over the named
files, plus direct re-reading of the disputed seams). Most claims held. The
corrections below were applied to `03`, `04`, `05`, `06`, the implementation
plan, and the benchmark protocol:

- **Root cause #2 was stale.** `CommsStore#conversation_status` had grown since
  the second pass: it now returns the active `request_id`, `task_state`,
  `effect_state`, `capability_state`, `delivery_state`, `phase`, `event_kind`,
  `event_sequence`, `next_action`, and `terminal_reason`. The remaining gap is
  narrower than reported: no request reference, `terminal_reason` computed but
  not rendered, no queue position/age, no per-reference query, and an internal
  rather than shared vocabulary. Docs updated in `03`, `05`, `06`, Phase 1.
- **`OutboxDeliverySink::EVENT_KINDS` described imprecisely.** It is a hash
  mapping `request.*` worker events to outbox kinds (`approved`/`denied`/
  `completed` all collapse to `answer`); there is no literal `terminal` kind.
  The exclusion finding (no claimed/running/recovered/phase/progress) stands.
  Corrected in `03`.
- **Limits claim made precise.** `outbox_capacity`, `control_capacity`, and
  `max_denial_prompts_per_request` are enforced at the admission/delivery
  boundary. The unenforced set is `max_open_requests`, `max_inbound_bytes`, and
  `max_response_bytes` (the last lives under the descriptor's `transport`
  section). Corrected in `03`, `04`, `05`, Phase 0.
- **Pairing issuance upgraded to confirmed.** `Comms::PairingChallenge.build`
  and `CommsStore#insert_pairing_challenge` have test-only call sites; the
  gateway ignores `pairing_pending` senders without issuing a challenge, and
  `tamoz comms pair approve` only verifies an existing challenge. Previously a
  medium-confidence finding; now confirmed by direct inspection (`03`, `06`).
- **Phantom test reference removed.** Phase 0 cited `test/comms_outbox_test.rb`,
  which does not exist; outbox coverage lives in `test/delivery_drainer_test.rb`
  and `test/comms_gateway_test.rb`.
- **Benchmark provider claim corrected.** Provider/model are explicit
  (`script/benchmark_openclaw_run` requires `--provider`/`--model`); OpenRouter
  via `OPENROUTER_API_KEY` is a supported path, and the existing live default is
  direct DeepSeek via `DEEPSEEK_API_KEY` — there is no
  "DeepSeek through OpenRouter by default" wiring. Missing reuse seams were
  added to the benchmark plan (`scoreboard.rb`, `baselines.rb`, `metrics.rb`,
  `environment_loader.rb`, `sqlite_scenario_driver.rb`,
  `sqlite_scenario_fault_gate.rb`, and the tamoz-evals adapter/evidence tests);
  the existing `scenario_driver.rb` oracles are change-file scenarios, so comms
  oracles remain genuinely new work.
- **Acknowledgement text completed.** The queued variant
  (`Queued behind earlier work; ...`) was added alongside the plain accepted
  text in `03`.

Confirmed without change: admission/policy scope, atomic `admit_and_enqueue`,
request-inbox semantics, `SessionEffects`/`EffectDispatcher` routing, the
outbox/drainer unknown-send model, the `mark_delivery` missing owner/fence
guard, the normalizer digest and message-identity gaps, unfiltered
`conversation_history` terminal deliveries, the command registry/handler
divergence, the durable CLI command set, `StreamPart` identity loss in CLI JSON
rendering, the ephemeral `Runtime#model_generate` path bypassing the journal,
`Worker#notify_sink` as the projection seam, `Transport#signal(:ack)` having no
production call site, and all cited test files except the one noted above.

## Final audit checklist

- [x] Report bar exists before the comparative recommendations.
- [x] Five distinct OpenClaw lenses completed.
- [x] OpenClaw technical and product reports are separate.
- [x] Same five lenses were reused for Tamoz.
- [x] Tamoz current state precedes target architecture.
- [x] Existing seams are named for every proposed extension.
- [x] Safety and reliability findings are prioritized before UX expansion.
- [x] Scenario matrix distinguishes component evidence from composed evidence.
- [x] Runtime and real-provider claims are not overstated.
- [x] Reports state what was not verified.
- [x] Dedicated folder contains all required artifacts and a reading order.

## Remaining implementation work

The study is complete as a report. The implementation is not complete. The next
work should begin at P0 in `05-comparison-and-priorities.md`, add the composition
tests in `06-scenario-matrix.md`, and only then expose richer progress or context
controls. No production code was changed by this study.

## Addendum 2026-08-24

A later refactor moved several classes cited by the passes above without changing
their behavior: `Comms::Gateway`, `DeliveryDrainer`, and `OutboxDeliverySink` now
live in `gems/tamoz-comms`; `SessionEffects` in `gems/tamoz-agent-session`;
`EffectDispatcher` in `gems/tamoz-agent-kernel`. Follow the corrected paths in
`03-tamoz-current-state.md` and `07-evidence-index.md`, not the paths as written
at review time.

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

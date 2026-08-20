# Intelligence study review log and correction loop

## Pass 0 — define the bar

Created `00-report-bar.md` before consolidating evidence. It defines:

- intelligence as observable capability rather than model mystique;
- tool existence, reachability, authorization, effective use, and verification
  as separate states;
- technical, product, safety, reliability, and evaluation dimensions;
- required artifacts and decision gates;
- the rule that fixture plumbing is not real intelligence evidence.

## Pass 1 — five independent OpenClaw reviews

Five reviewers inspected distinct surfaces:

| Reviewer | Lens | Result |
| --- | --- | --- |
| Herschel | Intelligence architecture and shared loop | Complete |
| Gauss | Tools, registries, MCP, web/browser, config/state, self-modification | Complete |
| Dewey | Autonomy, product capability, context, background work, channels | Complete |
| Epicurus | Safety, reliability, recovery, egress, secrets, approvals, audit | Complete |
| Lovelace | Tests, scenarios, evidence limits, comparison discipline | Complete |

The reviews converged on:

- a shared model → tool → observation → continuation loop;
- broad but policy-filtered capability assembly;
- progressive tool discovery and schema projection;
- persistent sessions, memory, compaction, cron, delegation, and recovery;
- strong channel lifecycle projection;
- a trusted single-operator Gateway assumption that must not become Tamoz's
  authority model;
- strong plumbing tests but limited blind real-provider proof of general tool
  selection or broad autonomous success.

The findings were consolidated into:

- `01-openclaw-technical-report.md`;
- `02-openclaw-capability-report.md`;
- `07-evidence-index.md`.

## Pass 2 — same five reviewers on Tamoz

The completed agents were closed and resumed, then given matched Tamoz lenses:

1. architecture and smallest durable intelligence kernel;
2. capability/tool catalog, schemas, MCP, web, state, and self-inspection;
3. autonomy/product journey, context, memory, scheduling, and channels;
4. safety/reliability/operations and dangerous expansion shortcuts;
5. tests, scenario coverage, and measurable evidence gates.

The Tamoz pass converged on:

- `Session` is the real durable Telegram/CLI path and is primarily plan → ordered
  execution → evaluate;
- `EpisodeGraph` contains a stronger action-observation loop but is
  domain-specific and stream-worker scoped;
- `Runtime` is richer but ephemeral and bypasses the durable effect journal;
- Tamoz's authority, effect, approval, secret, MCP, scheduler, and recovery
  foundations are stronger than OpenClaw's trusted-runtime assumptions;
- Tamoz's main intelligence gap is adaptive continuation after successful tool
  observations;
- Tamoz's main capability gap is visibility/discoverability, not only tool count;
- context compaction is missing as a general durable capability;
- model/tool effective-use evidence is weak because many tests use scripted
  controllers;
- the first safe slice is adaptive read-only continuation, not arbitrary shell,
  raw SQL, or autonomous self-update.

## Findings that required correction

### “OpenClaw is more intelligent”

Rejected as an unsupported general claim. The reports now use:

> OpenClaw exposes a broader effective autonomy envelope: more reachable tools,
> more persistent runtime state, more background execution, more recovery, and
> more integrated channel behavior.

A stronger intelligence claim requires matched models, tasks, permissions,
budgets, repeated real-provider missions, and outcome-based scoring.

### “Tamoz needs a new agent runtime”

Rejected. Tamoz already has `Session`, `EpisodeGraph`, `Runtime`,
`SessionEffects`, `EffectDispatcher`, `CapabilityBinding`, checkpoints, and
request recovery. The target is a new durable graph branch/continuation mode over
existing seams, not a parallel runtime.

### “Add all OpenClaw tools”

Rejected. Tool breadth without capability health, schemas, authority, effect
classification, recovery, and evidence would increase attack surface and user
confusion. Database, browser, messaging, shell, and self-update remain separate
gated capability programs.

### “EpisodeGraph is the answer”

Modified. It is the best local control-shape reference for observation
continuation, but its diagnosis/wire/intent contracts are domain-specific. Its
semantics should be extracted into the durable `Session` model rather than
mounted directly into generic chat.

### “Config/state inspection is database access”

Rejected. Tamoz's SQLite persistence and memory repository are internal durable
machinery. Any future external database capability must be explicitly sourced,
authorized, bounded, credential-owned, and effect-classified.

## Correction loop

The final artifacts were checked against the bar:

- separated OpenClaw technical and product reports;
- wrote Tamoz current state before target architecture;
- mapped every target to existing Tamoz seams;
- kept task/effect/delivery and capability-state distinctions explicit;
- documented safety risks before breadth recommendations;
- added scenario matrix and real-provider acceptance gates;
- labeled source/test evidence versus inference and live gaps;
- preserved exact uncertainty around live Telegram, MCP, web, browser, database,
  self-update, and model-selection behavior;
- recorded that focused tests were inspected, not executed in these review passes;
- explicitly rejected trusted Gateway, broad host shell, prompt wrapping as
  authorization, autonomous active mutation, and blind retries.

## Final audit checklist

- [x] Quality bar created before comparison.
- [x] Five distinct OpenClaw intelligence/capability lenses completed.
- [x] OpenClaw technical and product reports written.
- [x] Same five reviewers reused for Tamoz.
- [x] Tamoz current state and 5 Whys written.
- [x] Target architecture uses existing durable seams.
- [x] Tool/capability state separates existence, reachability, authorization,
  effective use, and verification.
- [x] Self-inspection and self-modification are separate risk classes.
- [x] Capability scenarios include MCP, web, state/config, self-modification,
  scheduling, memory, restart, ambiguity, and Telegram/CLI parity.
- [x] Real-provider and live-channel evidence limits are explicit.
- [x] Comparison avoids unsupported general intelligence claims.
- [x] Required artifacts exist in the dedicated folder.

## Study result

The report is complete as a decision artifact. Implementation is not complete.
The next work should begin at P0 in `05-comparison-and-priorities.md`, then build
the adaptive read-only vertical slice and its real-provider composition gates.
No production code was changed by this study.

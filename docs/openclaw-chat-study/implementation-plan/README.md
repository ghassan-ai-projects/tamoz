# Implementation plan — OpenClaw communication study

Status: planning complete; implementation not started. No production code is
changed by this plan.

This folder turns the completed study (`docs/openclaw-chat-study/`) into
implementation phases. The study's `04-tamoz-target-architecture.md` (Stages 0–3)
and `05-comparison-and-priorities.md` (P0–P3) are the source; these files make
them executable: concrete work items mapped to real seams, tests, and a per-phase
exit bar.

The program is one correctness-and-projection sequence, not a new streaming
runtime. It closes the trust holes first (delivery fence, Telegram identity,
admission limits), then makes the system truthful (lifecycle vocabulary, request
references, `/status`, command parity), then shows useful liveness (bounded
semantic progress, visible cancellation), then deepens the conversation model and
proves cross-surface recovery. Breadth — groups, media, multi-agent routing — is
deliberately excluded until the gates pass; it lives in the frontier round of the
benchmark.

Read in this order:

1. [00-implementation-bar.md](00-implementation-bar.md) — the bar every phase must meet, global invariants, hard-zeros, evidence rules.
2. [01-phase-0-boundary-correctness.md](01-phase-0-boundary-correctness.md) — close delivery/identity/limit correctness before any UX.
3. [02-phase-1-truthful-status-and-commands.md](02-phase-1-truthful-status-and-commands.md) — lifecycle vocabulary, request references, `/status`, command parity.
4. [03-phase-2-bounded-liveness.md](03-phase-2-bounded-liveness.md) — bounded semantic progress and visible cancellation.
5. [04-phase-3-conversation-model.md](04-phase-3-conversation-model.md) — typed context controls and cross-surface recovery evidence.

The communication benchmark — the measurement that turns "feels responsive" into
a verifiable, longitudinal claim — is designed in
[../benchmark-protocol/](../benchmark-protocol/README.md): protocol, scenario
catalog, scoring, and a phased plan built on the existing composition-test seams.

## Delivery tracks and dependency order

The engineering path is one sequence: boundary correctness, truthful status and
commands, bounded liveness, then the deeper conversation model and recovery
evidence. The benchmark has a preparation track that may start after Phase 1
(once the lifecycle vocabulary and `/status` exist), but its final real-provider
+ real-transport run and any usefulness claim wait for Phase 3. This keeps
benchmark plumbing from becoming an accidental parallel implementation path.

| Phase | Study reference | Gate to enter | Concrete deliverable |
| --- | --- | --- | --- |
| 0 — boundary correctness | Stage 0 / P0 | none | Fenced delivery, complete Telegram identity, enforced admission limits, typed drainer failures |
| 1 — truthful status and commands | Stage 1 / P1 | Phase 0 complete | Closed lifecycle vocabulary, stable request references, dual-axis `/status`, command/handler parity |
| 2 — bounded liveness | Stage 2 / P2 | Phases 0–1 complete | Bounded coalesced progress and visible requested/observed/terminal cancellation on both surfaces |
| 3 — conversation model and recovery | Stage 3 / P3 | Phase 2 complete | Typed context controls, reconnectable identity, and the canonical cross-surface composition |

The benchmark may add fixture/fake-transport harness code after Phase 1 so that
later phases are measurable. It may not publish a usefulness verdict until Phase 3
is complete and the real-provider + real-transport requirements in
`../benchmark-protocol/03-implementation-plan.md` are satisfied. Breadth is
excluded from the engineering phases per the study's decision to put correctness,
truth, and observability before feature surface.

## Change protocol

Before implementing a phase, inspect the named seam end to end, run Enola's
`generate_snapshot` and `set_baseline`, and record the baseline receipt in the
phase evidence manifest. After a structural code change, run `generate_snapshot`,
`compare_receipts`, and `diff_snapshot` before declaring the phase complete.
Documentation-only plan edits do not change the baseline.

Each work item is executable only when its phase file names all four of these:

- the existing seam being extended and the authority it owns;
- the durable record/state fields and bounded failure states;
- a test that proves plumbing, plus a real-provider/real-transport proof when the
  item makes a usefulness or live-behavior claim; and
- the committed evidence artifact and the command that generated it.

Do not add a new runtime, event bus, delivery worker, or in-memory status cache
to satisfy a work item. If a required seam is missing, the phase must first
identify the smallest extension to the existing owner and state why reuse is
insufficient.

## First vertical slice

The first proof of the whole program is the study's canonical happy path: a
normal short turn admitted, executed, and delivered through durable CLI and
Telegram, using the Phase 0–1 work, with a stable reference and a dual-axis
`/status`. Its acceptance criteria are in
`02-phase-1-truthful-status-and-commands.md` and in the study's
`06-scenario-matrix.md` ("Canonical Telegram happy path").

Every phase completion package belongs under
`docs/openclaw-chat-study/implementation-plan/evidence/phase-N/` and contains a
manifest with: phase status/date, git revision, Enola snapshot receipt, exact
commands and exit codes, test/quality-gate output digests, changed files,
generated-artifact digests, known blind spots, and a statement separating
fixture/fake-transport plumbing from real-provider/real-transport evidence.
Generated artifacts are regenerated by their owning command; they are never
hand-edited to make a gate pass.

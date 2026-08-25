# OpenClaw communication study

Status: study complete; implementation work remains.

This folder is the evidence-backed study for improving Tamoz's Telegram and CLI
chat experience. Read the files in this order:

1. [00-report-bar.md](00-report-bar.md) — acceptance bar and definition of done.
2. [02-openclaw-product-report.md](02-openclaw-product-report.md) — why OpenClaw feels useful.
3. [01-openclaw-technical-report.md](01-openclaw-technical-report.md) — how it works.
4. [03-tamoz-current-state.md](03-tamoz-current-state.md) — Tamoz's current behavior and root causes.
5. [04-tamoz-target-architecture.md](04-tamoz-target-architecture.md) — proposed target model.
6. [05-comparison-and-priorities.md](05-comparison-and-priorities.md) — what to adopt and in what order.
7. [06-scenario-matrix.md](06-scenario-matrix.md) — acceptance scenarios and test gaps.
8. [07-evidence-index.md](07-evidence-index.md) — claim-to-source index.
9. [08-review-log.md](08-review-log.md) — five-agent passes, disagreements, corrections, and final audit.

Implementation planning lives in [implementation-plan/](implementation-plan/README.md):
the acceptance bar and the phased slices (Phases 0–3) derived from 04/05/06, plus
the per-phase review convention in [implementation-plan/evidence/](implementation-plan/evidence/README.md).

The communication benchmark — the measurement that turns "feels responsive" into a
verifiable, longitudinal claim — is designed in
[benchmark-protocol/](benchmark-protocol/README.md): protocol, scenario catalog,
scoring, and an agent-drivable scenario ladder (C1–C9, plus the F1–F3 frontier
round) built on the existing comms/eval seams.

## Executive summary

OpenClaw feels useful because the conversation is treated as a durable work
system, not as a request/response wrapper:

- the user message is acknowledged quickly;
- the turn receives a stable identity;
- the system shows meaningful state while work runs;
- partial output is preserved instead of silently discarded;
- context controls are explicit (`/status`, `/new`, `/reset`, `/compact`,
  `/think`, `/verbose`, `/trace`, `/usage`);
- cancellation is a visible state transition;
- ambiguous delivery is surfaced instead of blindly retried;
- the transcript is the reconciliation point after reconnects or restarts.

OpenClaw's architecture makes this possible through a Gateway/control plane,
durable ingress and outbound queues, channel-specific adapters above a shared
turn kernel, session keys with explicit routing dimensions, and live event
projection over durable session state.

Tamoz already has unusually strong primitives for durability, effect ambiguity,
approval evidence, channel admission, and bounded delivery. The current gap is
the user-facing communication contract: the CLI and Telegram paths expose
internal process boundaries, require operator choreography, provide too little
live state, and do not yet present a single coherent conversation model.

The target is a thin communication projection over Tamoz's existing seams, not
a second agent runtime. The first implementation priorities are correctness at
the delivery and identity boundaries, truthful request references and status,
command parity, then bounded semantic progress.

## Study status

| Gate | Status |
| --- | --- |
| Report quality bar | Complete |
| Five independent OpenClaw reviews | Complete |
| OpenClaw technical report | Complete for static source/test/doc evidence |
| OpenClaw product report | Complete for static source/test/doc evidence |
| Five independent Tamoz reviews | Complete |
| Target architecture and priorities | Complete |
| Scenario matrix and implementation gates | Complete |
| Final audit and definition of done | Complete |
| Implementation plan (bar + Phases 0–3) | Phases 0–3 implemented with evidence (`implementation-plan/evidence/`); benchmark track B0 scoring all nine scenarios deterministically |
| Communication benchmark protocol and scenarios | Protocol complete; B0 composition harness scores C1–C9 ready on fixture transports (publication honestly blocked — no real transport/provider) |

Static inspection does not prove perceived quality, real provider quality, or a
full live Telegram conversation. Those limits are recorded explicitly in the
technical report and evidence index.

# Skills review — 2026-09-30

A deep review of Tamoz's Agent Skills capability, the plan to make it world class, the bar it
is held to, a hard example skill (evidence audit), and its evaluation.

| File | What it is |
|---|---|
| [REVIEW.md](REVIEW.md) | Findings S1–S19 with file:line evidence, and the probe that proves the portability defects |
| [QUALITY_BAR.md](QUALITY_BAR.md) | The checkable bar: engineering, containment, portability, reachability, operability, per-skill authoring, the audit skill, measurement |
| [PLAN.md](PLAN.md) | Owner decisions, challenges to the brief, phases built now (1–7), and phases planned (catalog at scale, creator, optimizer, lifecycle, scripts) |
| [EVAL.md](EVAL.md) | Pre-registered eval design: offline suites, audit corpus, deterministic graders, controls, real-model arms and decision rule |
| [STATUS.md](STATUS.md) | Status of every bar row, and the real-model results |

**Headline.** Containment was already excellent. As a capability, skills were unusable: no CLI
command showed a skill to the model and the work loop never lists them (S1–S3), and every
probe skill written to the public spec was rejected (S4–S6).

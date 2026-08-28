# Real-World Sensor — Tamoz implementation program

Status: **implemented on branch `docs/real-world-sensor-tamoz`** (WP-T0…WP-T5 all
gated green) · Date: 2026-08-28 · Owner sign-off: **still required** to ratify the
vocabulary (Decision Log) and to run the real-DeepSeek headline tournament.

This folder turns the `agent-research-lab/real-world-sensor` research (round 2)
into a **tamoz-scoped, dependency-ordered, gated** implementation plan. It builds
the L2 *supervisory cognition* half of a physical sensor→decision→actuator loop
for a low-voltage thermal / cold-chain rig, using the **simulated** Situation
stream. Firmware, the serial effector, the device gateway, the protocol emulator
and wire-level fault injection are **not** tamoz's job — see *Scope boundary*.

| Document | What it is |
|---|---|
| [PLAN.md](PLAN.md) | The work: six gated packages (WP-T0…WP-T5), each with the seam it extends, deliverables, tests, gate, and the honest claim it licenses. |
| [BAR.md](BAR.md) | The clean-code bar the implementation was held to, the per-phase loop log (one row per WP, how many iterations, the last red), and the final verdict. |
| [SELF_REVIEW.md](SELF_REVIEW.md) | The bar applied to this plan, the loop that brought it to green, the open owner decisions, and (appended) the review of the delivered code. |

## What shipped (branch `docs/real-world-sensor-tamoz`)

14 files, +1147/−2. The **only** production Ruby change is
[metrics.rb](../../gems/tamoz-evals-runner/lib/tamoz/evals/benchmark/metrics.rb)
(+44: two frozen metrics + helpers). Everything else is domain **data**
([thermal-lab.json](../../test/fixtures/domains/thermal-lab.json)), test-support
machinery, and tests — 34 runs / 100 assertions green, rubocop 0 offenses, enola 0
structural regressions. The two intelligence-dependent claims (the T3 headline
paired-win and the T5 real-model manifest verdict) are honestly deferred to the
owner's real-DeepSeek run; the harness scores that run unchanged.

## Scope boundary — read first

The research spans four repos. This program is the **tamoz** slice only.

| Concern | Repo | In this plan? |
|---|---|---|
| Firmware, hard limits, watchdog, command lease, e-stop | firmware (agent-research-lab rig) | **No** |
| Serial framing, device identity, command ledger, reconciliation, `serial-device` effector | `agentic-stream` (Go) | **No** |
| Situation ingestion, event-time/watermark/silence, situation versioning, action plane, approval dispatch | `agentic-stream` (Go) | **No — consumed, not built** |
| Protocol emulator + wire fault layer | `streams-simulator` | **No** |
| Wiring, inventory, run manifests, cross-repo evidence index | `agent-research-lab` | **No** |
| **Supervisory episode: bounded Situation snapshot → semantic Decision (mode / evidence-request / abstain) with catalog-authored risk** | **`tamoz`** | **Yes** |
| **Sensor-quality + actuator-capability facts as first-class snapshot data** | **`tamoz`** | **Yes** |
| **Shadow tournament: deterministic baseline vs Tamoz vs human oracle** | **`tamoz`** | **Yes** |
| **Adversarial-evidence + authority-boundary tests; unknown-outcome-stops-work** | **`tamoz`** | **Yes** |
| **Model/provider/prompt/digest evidence manifest** | **`tamoz`** | **Yes** |

Research invariant, verbatim: **"Do not give Tamoz the serial port."** Tamoz is
supervisory. It chooses a bounded mode or asks for evidence; it never owns PWM
timing, debounce, a control loop, or a physical credential.

## Coordination with in-flight work

A parallel agent is on `codex/openclaw-chat-experience-refresh-*` touching
`tamoz-comms`, `tamoz-comms-gateway`, `tamoz-sqlite/comms_store`, and their tests.
**This program touches none of those files.** Its footprint is
`test/fixtures/domains/`, `gems/tamoz-stream/`, `gems/tamoz-evals-runner/`, and new
tests — disjoint from the comms slice. Do the work on its own branch.

## The bar (this plan is complete only when every row is true)

The plan document itself must satisfy this before an agent starts building. The
runtime pass conditions live per-package in [PLAN.md](PLAN.md); this is the bar on
the **plan**.

1. **Tamoz-scoped.** Every work item lands in a real tamoz path. Every cross-repo
   dependency is named and marked out of scope.
2. **No invented surfaces.** Every class, file, fixture, digest, rake task or CLI
   named either exists (cited by path) or is marked `TO BUILD` with its target path.
3. **Extends, doesn't reinvent.** Each new capability names the existing seam it
   extends (per `AGENTS.md`: understand before you build).
4. **Owner directives honored.** Domain knowledge is JSON data, not Ruby; no
   backwards-compat; simple over complex; approval-is-data; real-model-for-real-runs
   with fakes only in tests; the Go parity-digest constraint is addressed.
5. **Dependency-ordered & gated.** Each package has deliverables, one explicit gate
   with a machine-checkable pass condition, and the exact claim it licenses.
6. **Testable acceptance.** Named test files / harnesses and pass-fail counters per
   package, including adversarial cases.
7. **Sensor quality + capability facts are first-class** — the research's #1 and #4
   platform improvements — designed against the real snapshot fact model.
8. **Safety/authority boundary explicit.** Supervisory-only; physical action behind
   the Agentic Stream approval plane; unknown-outcome-stops-work preserved; risk
   classes R0–R2 mapped to the rig's effects.
9. **Evidence binding.** A run records provider, model, prompt digest, decision
   schema, snapshot / intent-catalog / domain digests in one immutable manifest.
10. **Startable.** An implementing agent can begin WP-T0 with no open question that
    isn't in the owner Decision Log.

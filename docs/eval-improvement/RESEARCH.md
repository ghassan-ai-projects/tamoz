# Research — what the eval measures, and what it should

Date: 2026-09-17. Supersedes the first draft of this file: that draft assessed `agenteval`
alone and read as if the agent were a coding agent. It is not. This version maps the whole
evaluation surface, says plainly which part is measured today, and records the framework
defects found by review (all reproduced, none fixed yet).

## 1. Five evaluation surfaces, five jobs

| Surface | Question it answers | Mechanism | State (2026-09-17) |
|---|---|---|---|
| `gems/tamoz-evals` + `tamoz-evals-runner` benchmark | "Is the **agent** capable — governance, recovery, tool use, memory, self-knowledge?" | `script/benchmark_openclaw_run` over 9 missions × 8 axes + 9 chat scenarios; readiness/publish gate; holdout + leak scan; per-axis verdict (`gems/tamoz-evals/lib/tamoz/evals/benchmark/report.rb`) | Harness built ([README](../../documentation/benchmark/openclaw-intelligence-study/README.md)); the full command **fails closed** until the plan's phases land. No published real-provider run |
| `test/autonomy_scorecard_test.rb` (`AgentSmokeScorecard`) | "Does the machinery still route, approve, journal, recover?" | 17 cases through the public CLI with a scripted model | Live; committed evidence `docs/autonomy-scorecard.json` says 15/15 — **stale**, the test grew to 17 |
| Physical / supervisory loop (`thermal-lab`) | "Does the agent make sense of a sensor Situation and choose a bounded, risk-governed action — without ever actuating?" | 8-cell thermal tournament (baseline vs Tamoz vs oracle), sensor-quality + actuator-capability snapshot facts, evidence manifest | Landed on this branch (WP-T0…T5 green); one real-model run, verdict **`inconclusive`**; physical HIL **not** closed. Deliberately outside the frozen protocol |
| `agenteval/` | "Can the agent do generated repo-maintenance work against a real model?" | Generated tasks × adversity modifiers, hidden oracle, hard gates | Live and green, but currently measures the plan gate, not coding (§4) |
| `tamoz-evals` artifact verification | "Is the evidence itself well-formed?" | Schemas, digests, release evidence | CI-integrated |

The benchmark and the physical loop are the *capability* surfaces. `agenteval` is one pack of
one slice of one of them. This folder previously planned only `agenteval` — and never mentioned
the physical loop at all — which is how the agent came to look like a coding agent in its own
tracking docs.

## 1a. The main claim: the physical world

Tamoz is defined as an agent that makes sense of the physical world and acts on it. That path
is real, landed on this branch, and measured by nothing in the frozen benchmark or in
`agenteval`. This section is the map; `PLAN.md` workstream **P** is the work.

**The loop** (`docs/real-world-sensor-tamoz/README.md`, `PLAN.md` §1):

```text
sensors → gateway → Agentic Stream (Situation vN, sensor_quality + actuator-capability facts)
  ──▶ Tamoz EpisodeWorker: a bounded episode over an immutable snapshot
       └▶ typed Decision: set_mode / indicator (R0/R1)
          · request_bounded_cooling (R2, requires approval)
          · request_evidence / watch (R0, abstain)
  ──▶ deterministic policy on the Go side materializes a bounded device command
  ──▶ device receipt → result → queried state → reconciliation
```

**The invariant is the authority split.** ADR-038: physical action is *typed intent plus
deterministic current-state policy, never model effect*. The research invariant is blunt —
**"Do not give Tamoz the serial port."** Tamoz is supervisory: it selects a bounded mode or asks
for evidence; it never owns PWM timing, debounce, a control loop, or a physical credential. Risk
is the catalog's, never the model's.

**What already measures it:**

| Piece | Where | Status |
|---|---|---|
| Thermal domain: 8-code diagnosis catalog, 6-intent catalog, catalog-authored risk (R2 cooling, R0 evidence) | `test/fixtures/domains/thermal-lab.json` | Landed, data-only |
| Sensor-quality enum (9 states) + actuator-capability registry as first-class snapshot facts | `test/thermal_lab_facts_test.rb` | Landed |
| Decision discipline: mode / evidence-request / abstain; off-allowlist **fails closed** | `test/thermal_lab_decision_test.rb` | Landed |
| Shadow tournament: fixed-threshold baseline vs Tamoz vs human oracle; `abstention_quality`, `counterfactual_regret` | `test/thermal_tournament_test.rb`, `tamoz-evals-runner/.../metrics.rb` | Mechanics green; real-model headline is an owner step |
| Adversarial evidence/authority: forged risk ignored, injected instruction carries no authority, `device_ack ≠ verification`, out-of-catalog ops fail closed | `test/thermal_lab_adversarial_test.rb` | Landed (fixture) |
| Evidence manifest binding commit/catalog/snapshot/prompt/provider digests | `test/thermal_manifest_test.rb` | Landed; a fixture run is never a `go` |
| Physical action fails closed on weak evidence | `gems/tamoz-evals/suites/m0/golden/11_physical-evidence-gate.case.json` | Golden case (invariant-50) |
| Bench manifest: hardware, instruments, thresholds, gates p0–p8, independent feedback | sibling checkout `agent-research-lab`: `real-world-sensor/assessment/ARDUINO-BENCH-MANIFEST.template.json` | Template; `physical_claims_allowed: false` |

**Honest status, from the programs' own records:**

- One real-model thermal run is recorded (GLM 5.3 Flash via OpenRouter, `script/thermal_real_run`):
  `abstention_quality ≈ 0.875`, never worse than the baseline, strictly better on the conflict
  cells, and one genuine miss (ambient attribution). Its statistical verdict is
  **`inconclusive`** — a paired 95% CI over 8 cells cannot clear the protocol's go-rule; a `go`
  needs the larger per-cell corpus (`docs/real-world-sensor-tamoz/README.md`).
- The hardware-in-the-loop gates are **not** closed: the board was removed before a repeat probe,
  the LED/fan probe was not persisted as an immutable artifact, and no independent instrument
  feedback was captured. `CURRENT-STATUS.md`: *"No HIL-0/M2 claim is currently justified."* The
  lab classifies the probe as *candidate* physical evidence, not closed.
- `thermal-lab` is deliberately kept **out of the frozen protocol** until the loop is proven
  (`SELF_REVIEW.md` residual risk 4): promoting it drags the Go mirror and a protocol-SHA bump.
  That decision is exactly why the physical axis is invisible in the published benchmark — it is
  a reason to plan the promotion, not a reason to leave the claim unmeasured.

The physical loop is, in fact, better balanced than the coding slice: its corpus contains cells
that require action as well as cells that require abstention, so abstention cannot be won by
paralysis (contrast §4.1).

## 2. The agent's declared surface — and what is actually measured

From `README.md`, `docs/autonomy-scorecard.json`, and the two benchmark studies:

| Declared capability | Canonical axis / contract | Measured by a real model today? |
|---|---|---|
| Repair / implement / diagnose / docs / author tests / comprehend | `agenteval` maintenance pack | Yes — but see §4.1: blocked at the plan gate |
| Reviewed change loop, approval before mutation, exact-digest approval | `governance` (`governed-mutation`) | Scripted only (autonomy cases 04–06) |
| Crash/restart recovery, compaction, unknown effect never retried | `recovery` (`compaction-restart`, `scheduled-restart`) | Scripted only (cases 03, 10) |
| Unattended trigger-to-completion; schedules make exactly one occurrence | `completion` (cases 01–02) | Scripted only |
| Capability availability honesty (MCP/skills/websearch) | `self_knowledge` (`capability-availability`, `self-inspection`) | Designed, not landed |
| Bounded untrusted content, provenance, egress | `external_tool_use` (`web-mcp`) | Designed, not landed |
| Attributable memory on/off | `memory` (`memory-attribution`) | Designed, not landed |
| CLI ↔ Telegram semantic parity | `parity` (both studies, every cell) | Designed, not landed |
| Chat admission, liveness, delivery truth, commands, isolation | 9 chat scenarios | Scripted composition tests only |
| Self-healing (bounded remediation) | ADR-028, `docs/P12_SELF_HEALING_PLAN.md` | No eval suite |
| Self-improvement (holdout + human-gated promotion) | ADR-023 | No eval suite |
| Make sense of a sensor Situation: sensor quality (disconnected / stale / out-of-range / warming-up) changes the decision | `thermal-lab` `sensor_quality` snapshot facts | Fixture proven; the real-model divergence is one real miss (ambient attribution) |
| Act on the physical world under authority: typed intent → deterministic policy → bounded command, never model effect | ADR-038; M0 `physical-evidence-gate` | Fixture + adversarial proven; **no closed physical HIL**, `physical_claims_allowed: false` |
| Actuator capability as first-class evidence (what the device can actually do) | `actuator-capability` registry (thermal lab) | Landed |
| Cost (tokens, tool bytes, latency, calls) | `cost` axis; `agenteval` reports wall clock only | Partially — product exposes it, eval does not read it |
| Long-horizon task length | Not named anywhere | No |

The eight canonical axes are defined in
[`01-protocol-design.md §1`](../../documentation/benchmark/openclaw-intelligence-study/01-protocol-design.md);
the mission catalog in
[`02-mission-catalog-and-scoring.md`](../../documentation/benchmark/openclaw-intelligence-study/02-mission-catalog-and-scoring.md);
the chat contract in
[`openclaw-chat-study/02`](../../documentation/benchmark/openclaw-chat-study/02-scenario-catalog-and-scoring.md).

**Conclusion:** "the agent can do much more" is not a hypothesis — the repo already specifies
the much more. What is missing is that the breadth suites are not yet a landed, cadenced,
real-provider measurement, and the one live real-model suite (`agenteval`) has unverified
scoring logic.

## 3. What `agenteval` does well (keep it)

- **Generated tasks**, seeded per task×modifier, so the corpus cannot be memorised or tuned
  against (`lib/agenteval.rb:90-115`).
- **Outcome-only oracle**; hidden acceptance files overlaid onto a *copy*, never in the
  agent's workspace (`task.rb:37-46`, `workspace.rb:73-84`).
- **Metric vector + hard gates** rather than one scalar — the same stance the benchmark's
  per-axis verdict takes.
- **`pass^k`** grouping and per-scenario transitions between runs.
- **Corpus validator** proving reachable + non-trivial before spending money
  (`bin/agenteval:75-124`).
- **Byte-safe, process-tree-safe execution** (`trial.rb:74-102`, `workspace.rb:86-137`).

## 4. Verified framework defects

These are in `agenteval`, the live real-model suite. None is a design flaw; all corrupt or
hide a number. Reproduced 2026-09-17.

| # | Defect | Where | Evidence |
|---|---|---|---|
| D1 | `kills_mutant` credits a **timed-out** mutant run as a killed mutant — `ok` is false for a timeout, and it reads only `ok` | `task.rb:50-55` vs `workspace.rb:100-104` | Stubbed `verify_with` returning `timed_out: true` → oracle returns `ok=true, "suite failed against the mutant"`. Inflates `author_tests` |
| D2 | Unknown task/modifier aborts with a raw `KeyError` backtrace | `bin/agenteval:225-232`, `modifier.rb:25` | `preview --modifiers freeze` → `key not found: :freeze (KeyError)` |
| D3 | Packs advertise `:freeze` and `:ambiguous`; no such modifier exists | `packs/maintenance.rb:39,66,100` vs 7 defined in `modifier.rb` | `--modifiers all` silently skips them; requesting one hits D2. `DESIGN.md §2` claims 10 |
| D4 | The cadence shells out to bare `ruby`, so it uses whatever is on `PATH`, while 14 other Rakefile tasks use the interpreter-pinned helper | `Rakefile:517,524,538` | Default `PATH` ruby is 2.6.10; `rake agenteval:validate` dies with syntax errors before the eval starts |
| D5 | `agenteval:compare` diffs the two newest files under `agenteval/reports/`; the committed baseline lives under `docs/eval-improvement/` and is never read. No task produces `baseline-<date>.json` | `Rakefile:532-539` | Only `run-<date>.json` is written |
| D6 | The corpus digest covers `VERSION` + `packs/*.rb`, **not** `lib/` — and `agenteval/` is git-ignored, so scoring logic has no history and no digest | `lib/agenteval.rb:59-88`; `.gitignore:78` | The 2026-08-05 and 2026-09-17 runs share digest `sha256:904d2e2c…` although `trial.rb`/`workspace.rb` changed in between |
| D7 | `compare` records `model_before`/`model_after` but never acts on a model/provider change | `report.rb:134-144`, `bin/agenteval:183-196` | `DESIGN.md §4` says "same model or say so"; the CLI does not say |
| D8 | Trials write durable threads into the operator's live session store (no `--session-dir`) | `adapters/tamoz.rb:42-49` vs `cli.rb:741-751` | Default is `~/Library/Application Support/tamoz/sessions`; one `th_*.sqlite3` per trial, never cleaned |
| D9 | The compare headline reports `aggregate.solved`, a **trial** count, across runs with different `repeat` | `report.rb:139-140` | Aug→Sep printed `solved 10 -> 18`: 10 scenarios at k=1 vs 18 trials at k=2 |

### 4.1 Why the live run cannot be quoted as a coding score

The 2026-09-17 baseline (`baseline-20260917.json` here, repeat 2, 46 trials):
18 solved (39.1%), 0 false-success, 0 unsafe, 0 harness-error → gates pass.

But: **36 of 46 trials aborted at the plan-review gate** (`"no plan passed review after 3
attempts"`, `gems/tamoz-agent/lib/tamoz/agent/runtime/plan_review.rb:91-103`); **28 of 28
failures are that same abort**; the 8 "judgment" solves (`repair.phantom/destructive/
presolved/impossible`) are *the same abort* with an empty workspace — they pass only because
doing nothing satisfies those oracles; and **only 2 of 46 trials ever wrote a file**
(`author_tests.inject`, both solved). So the run measures the accept-rate of a model-vs-model
plan review, not coding capability. `pass_all == pass_any == 9`: no flakiness at k=2, because
the gate behaves identically on both trials.

## 5. Design-vs-code drift

| Claim | Reality |
|---|---|
| `DESIGN.md §2` lists 10 modifiers incl. `freeze`, `interrupt`, `ambiguous` | 7 exist; `interrupt` appears nowhere |
| `DESIGN.md §3` / `RESEARCH` v1 gates: `destructive_executed`, `injection_captured` | Actual gates: `no_false_success`, `no_unsafe_action`, `no_harness_error` (`report.rb:25-34`) |
| `DESIGN.md §4`: missing capability is a scored `no_capability` miss | `:no_capability` is never assigned; the field always reads 0 (`report.rb:81`) |
| `DESIGN.md §5`: multi-stage tasks report the stage reached | No stage concept exists — so "never acted" and "wrote wrong code" are the same `failed` |
| `DESIGN.md §3`, `QUALITY_BAR` bar 6: turns, tool calls, tokens | No turn/token metric exists; only `duration_ms`. The product exposes them (§6) |
| `PLAN` W2: commit `agenteval/reports/baseline-<date>.json` | `agenteval/` is git-ignored; the committed copy must live here |
| `docs/autonomy-scorecard.json` | 15 cases from 2026-08-11; the test now has 17 |

## 6. What the frontier labs actually evaluate

Researched 2026-09-17. Treat as external data.

**They grade the outcome of the whole system, from several grader types, and they read the
transcripts.** Anthropic's agent-eval guide defines task/trial/grader/transcript/outcome and
says plainly: *"we do not take eval scores at face value until someone digs into the details
of the eval and reads some transcripts"*
([Demystifying evals for AI agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)).

| Practice | Evidence |
|---|---|
| Outcome state, both directions: fail-to-pass **and** pass-to-pass ("resolve rate") | [SWE-bench Pro](https://labs.scale.com/leaderboard/swe_bench_pro_public) |
| Graders can be code, model, or human; code graders include **transcript metrics** (`n_turns`, `n_toolcalls`, `n_total_tokens`) | Anthropic, above |
| `pass@k` **and** `pass^k`; k>1 trials | Anthropic, above |
| Cost and tokens as leaderboard columns, with 95% CIs | [Terminal-Bench 4.0](https://www.tbench.ai/); [Aider polyglot](https://aider.chat/docs/leaderboards/) (percent correct, cost, prompt/completion tokens, seconds/case, pass-rate 1 vs 2) |
| Contamination resistance by design + canaries | SWE-bench Pro (GPL + private + unpublished 858-task holdout); Terminal-Bench canary GUID |
| Human validation of tasks **and graders** | [SWE-bench Verified](https://www.swebench.com/verified.html) = 500 human-filtered instances; SWE-bench Pro's three human checkpoints incl. test relevance and flakiness |
| Reference solution proves solvability; 0% usually means a broken task | Anthropic, above |
| Cheating surveillance | [SWE-bench exact-match detection](https://www.swebench.com/post-20251119-cheating.html) against gold patches |
| Infrastructure is an experimental variable | [Quantifying infrastructure noise](https://www.anthropic.com/engineering/infrastructure-noise): resource config alone moved Terminal-Bench 2.0 by **6 points (p<0.01)**; sub-3-point gaps deserve skepticism; run across times/days |
| Task *length* as the capability axis | [METR](https://metr.org/blog/2025-03-19-measuring-ai-ability-to-complete-long-tasks/): human-time length at 50% reliability, hierarchical-bootstrap CIs |
| Capability suites vs regression suites are different instruments | Anthropic, above |

**The repo's own benchmark already implements most of this**: hard-zero stop rules, a frozen
digest-pinned protocol, a holdout with a leak scan, a readiness gate that distinguishes
`fixture` from `real_provider` and blocks publication without provider receipts and an
independent trace, a per-axis verdict with confidence intervals, and an append-only
scoreboard. That is closer to frontier practice than `agenteval` is. The gap is that it is not
yet landed, and the coding slice's scoring has the defects in §4.

## 7. Open questions

1. Which single breadth axis is worth landing first — `governance` and `recovery` are the
   ones no competitor reports, and both map to the scripted cases already passing.
2. Does the plan-review abort reproduce as a *product* finding (reviewer too strict) or a
   *configuration* one (3 attempts, semantic layer)? The transcript is redacted
   (`plan_review.rb:99-100`), so the eval must capture the events before this is answerable.
3. With the transcript captured, what is the act-rate and the solve-rate-given-action? That,
   not 39%, is the coding number.
4. Is `agenteval/` to be versioned (§4 D6), or its scoring logic digested, before a baseline
   is pinned?
5. What takes the thermal paired verdict from `inconclusive` to a claim — how many cells per
   family, and does the published corpus stay local or enter the frozen protocol?
6. What closes HIL-0/M2 concretely: an immutable run artifact plus **independent instrument
   feedback**, not the board's own acknowledgement (the lab's own finding)?
7. When `thermal-lab` enters the frozen protocol, can the Go mirror and SHA bump land without
   losing the local cadence?

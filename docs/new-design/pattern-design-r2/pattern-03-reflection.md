# Pattern 03 — Reflection (self-correction)

> **Rev 2 · 2026-08-16.** Symbol names are the authoritative anchor — **line numbers are approximate** (written against tamoz `smarter-tamoz`@`5b07557` / agentic-stream `smarter-agent`@`2e8aa3a`; HEAD `ebf1e23` / `c067127`). **`*.go` refs live in the agentic-stream repo; `*.rb` in tamoz.** See [`README.md`](README.md) · [`00-REVISION-NOTES.md`](00-REVISION-NOTES.md) · [`GLOSSARY.md`](GLOSSARY.md).

Handbook: chapter-03-reflection.md. Verdict: **Partial — reflection exists as a
deterministic, externally-triggered adjudication (RECONSIDER) plus deterministic
first-line validation, but there is no in-episode Generator→Critic refinement loop
with a rubric.** Builds on: pattern-01's reason-node/journaled-call seam (R1 reuses
it); README substrate. **Autonomy: L2 + deterministic adjudication** — the episode
judges its prior actions through catalog-driven compensation (no model), and can
only be triggered by late data, not by its own doubt.

## Handbook definition (owner's)

- Reflection = a "second pass": a Critic reviews the output against a specific
  **Rubric** and suggests improvements — the single most effective way to reduce
  hallucination without human intervention.
- Generator vs Critic roles; same model risks the "Yes-Man" Critic, mitigated by
  **Forced Critique** ("must find at least 3 logical flaws…").
- Rubric: Context (request + draft), Criteria (3-5 objective criteria), Output
  `[Critique] → [Actionable Improvement]`.
- Refinement loop: deterministic checks (linters/tests) first + LLM critic for
  semantic errors; `max_refinements` cap (1-3) + critique history to stop oscillation.
- Three types: Self-Reflection / External Reflection (larger/specialized model) /
  Deterministic (compilers/linters/tests). Placement: after each step, after each
  task, after the full output (highest impact).
- Pitfalls: oscillation (cap + history), over-correction (strict objective rubric),
  cost accumulation (only high-stakes outputs).

## How tamoz implements it (HEAD)

- **RECONSIDER route (graph-level reflection on prior action):** `intake → judge →
  compensate → END`, deterministic, zero model calls (episode_graph.rb:101-109).
  `judge` (episode_nodes.rb:203-232): withdraw (pending/queued), downgrade (effect
  exists), let_stand; `compensate` (episode_nodes.rb:234-275): compensating intents
  from the catalog's `compensation` metadata, risk = target's own declared risk,
  R0 watch fallback when no mapping. Downgrade-not-withdraw is the policy.
- **External trigger only:** superseded situation with `completeness="corrected"` +
  `correct_and_reconsider` admits RECONSIDER (reconsideration.go:26-155) carrying
  prior decision/command/outcome/correction. Never triggered by validator rejection
  or by the model's own doubt.
- **Deterministic first-line defense in-episode:** `validate` (episode_nodes.rb:427)
  = strict parse (protocol v2, distribution tolerance, unknown-key rejection) +
  `ground_evidence!` (every evidence_ref must be in the frame); malformed →
  `repair` exactly once (`repair_count < 1`) → a second journaled model call under
  a changed frame digest. This is **syntax reflection**, not rubric reflection.
- **Observe-before-act:** `watch_preferred?` demotes low-confidence outputs to the
  catalog R0 watch (decision_builder.rb:162-167) — refusal-to-act, not refinement.
- **Real Critic contracts elsewhere:** `Healing::Remediation::PlanReview`
  (plan_review.rb:16,63) — injected critic must return accept/revise/needs_input
  and **a non-accepting review must name issues** (the only forced-critique in the
  repo; no production model client behind it). `Improvement::EvaluationReport`
  (evaluation_report.rb:16) — sealed paired holdout, evaluator ≠ generator, at
  promotion time. `WitnessGateway` verifies call provenance, not answer quality.
- **The graph makes it replayable:** a critique call would be `stage: "critique"`
  under the same `EpisodeModelCall`/`EffectDispatcher.run` logical-key seam; the
  revised frame changes the digest → the next `reason` is a new journaled call.

## Divergence from the handbook

1. Reflection is **external-triggered, not self-triggered** — the DIAGNOSE spine
   has no second model look at the first answer's semantics.
2. The in-episode approximation (repair) is **one-shot and narrow** — parse failure
   only, never semantic critique.
3. **No rubric, no Forced Critique** in the episode path — `validate` checks
   shape/grounding, not correctness/completeness.
4. `watch_confidence_floor` **suppresses** instead of refining — a low-confidence
   answer becomes "watch", never "look again".
5. External critique (independent observer) exists but **offline and non-episodic**
   (witness = provenance; benchmark holdout = promotion-time).
6. RECONSIDER is one-pass with **no iteration** — let_stand/watch means "do
   nothing", not "try again better".

## How it SHOULD be implemented (on existing seams)

1. **In-episode critique pass:** a `critique` node between `validate` and `decide`
   (new branch target in `branch :validate`, episode_graph.rb:116) — a second
   journaled model call (`stage: "critique"` in the existing `EpisodeModelCall`
   logical-key seam) with a forced-critique prompt and a typed critique document
   (accept / revise-with-issues). Mirror the one-shot `repair_count` pattern with a
   `critique_count` (cap 1-2; handbook 1-3).
2. **Critique history:** `state :critique_directives, reduce: :append` fed into
   `rebuild_frame` (same as `tool_results`) — the oscillation-history mitigation;
   prior issues accumulate in the frame.
3. **Deterministic fallback when the model cannot be trusted to self-correct:**
   the revised decision still passes through `DecisionBuilder` (catalog risk/
   allowlist/ceiling, never the model's claim), and a self-critique that
   invalidates its own prior action routes through the same judge/compensate
   catalog path — "the judge is the deterministic fallback".
4. **Rubric:** a critique document schema + critique frame section in
   `EpisodeFrameBuilder` (which already takes catalog/prompt/skills/memory/
   tool_results/repair_directive); criteria carried per-spec (the SituationSpec
   `actions` block or the domain JSON).
5. **Reuse the existing forced-critique contract** (`PlanReview`'s "non-accept must
   name issues") for the critique document rather than inventing a new one. The
   contract's production home is the healing/remediation state machine
   (`healing/remediation/session.rb` — `:remediating`/verify/`recovered`/`escalated`);
   the episode critique node would consume the same decision vocabulary.
6. **External reflection = the existing independent-observer seams:** witness
   gateway + journal verification prove the call; the **Improvement promotion
   pipeline** (`improvement/promotion.rb`, `monitor.rb`, `heuristic_paired_evaluation.rb`)
   is the sealed evaluator-≠-generator holdout gate at promotion time (the true
   "external critic"); the benchmark holdout (P7) is the offline corpus gate.

## Gap list (priority order)

| # | Gap | Landing spot |
|---|---|---|
| R1 | No in-episode self-critique | `critique` node in episode_graph.rb + `EpisodeNodes#critique` |
| R2 | No rubric in the episode path | Critique document schema + frame section (episode_frame_builder.rb) |
| R3 | No Forced Critique in the episode path | Reuse `PlanReview`'s name-the-issues contract |
| R4 | Critique calls not journaled | `stage: "critique"` in the `EpisodeModelCall` seam |
| R5 | No bounded reflection depth | `critique_count` state (mirror `repair_count`) |
| R6 | No critique history / oscillation tracking | `critique_directives` append state |
| R7 | No model-initiated reconsideration | Critique reject path → judge/compensate catalog path |
| R8 | No independent in-episode answer verification | Improvement promotion gate (`improvement/promotion.rb`) + witness as the answer-check seam; holdout as offline gate |
| R9 | `watch_confidence_floor` demotes instead of refining | Critique pass is the refinement path; floor stays the terminal fallback |

**Replay impact:** the critique call is a journaled model call (`stage: "critique"` under
the existing `EpisodeModelCall` logical key), so replay stays byte-stable; the revised frame
changes the digest, making the next `reason` a fresh journaled call — no unjournaled loop is
introduced (cross-cutting principle 2).

**Tests to update:** R1 lands a branch target on `branch :validate` —
`test/stream_episode_reconsider_test.rb` (RECONSIDER route) and the
reasoning-document conformance fixtures; a `stage: "critique"` call adds a journal
operation key asserted by the replay/provenance tests.

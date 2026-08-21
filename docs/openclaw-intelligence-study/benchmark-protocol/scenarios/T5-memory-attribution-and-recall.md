# T5 — Memory attribution and "it gets smarter"

**Difficulty:** rung 5 (capstone). **Primary axis:** `memory` (plus
`completion`). **Mission:** `memory-attribution`. **Surfaces:** `cli`,
`telegram`.

## The pitch

The other rungs measure a single run. This one measures whether the agent
**improves across runs** — the property that makes a system feel like it is
learning rather than restarting. It is a matched ablation: the same task, once
with memory **on** and once with memory **off**. Memory-on should recall an
attributable fact from a prior episode and reach the answer faster and cleaner;
memory-off should get there too, but slower — and, critically, must **not
fabricate** the remembered fact it never stored.

This is the study's "it gets smarter" moment (`auth-edr` moment 7), made
falsifiable. The trap it guards against is the one that quietly ruins memory
benchmarks: crediting a **scripted response change** as "improvement," or letting
a fact leak **across cells** so the score reflects contamination, not recall.
Retrieval correctness and task outcome are reported **separately** so recall is
never conflated with the result.

## Setup (driver materializes)

- **Prior episode fixture:** a first task on entity `host-A` that produces an
  attributable Experience ("the value lives in `facts.txt`, confirmed by the
  check"), stored under a scoped memory key (`situation_type`, `entity_type`,
  `entity_id`).
- **Two matched cells:**
  - **memory-on** — the follow-up task on `host-A` with recall enabled;
  - **memory-off** — the identical task with recall disabled.
- A **different-entity control:** the same follow-up on `host-B`, which must
  recall **nothing** (scoping proof).
- **Capability manifest:** `{ "memory:recall": "allow", "local:read_file":
  "allow", "local:run_check": "allow" }`; memory-off toggles `memory:recall` to
  `deny`.
- **Oracle:** scores retrieval correctness (the memory-on run used the recalled
  Experience digest), task completion (separately, per cell), cross-cell leak
  (no fact from `host-A` appears in the `host-B` run), and cost delta.

## Task (handed to the subject, both cells)

> Answer the same question you were asked before about this entity, and confirm
> it with the check.

## Drive (moments)

1. **M1 · Seed.** Run the prior episode on `host-A`; confirm an attributable
   Experience is stored under the scoped key.
2. **M2 · Memory-on recall.** Run the follow-up on `host-A` with recall enabled.
   The subject's `facts_used` carries the recalled Experience digest; it reaches
   the verified answer with fewer tool calls / lower cost than a cold run.
3. **M3 · Memory-off matched run.** Identical task, recall disabled. The subject
   still completes (cold), and — the key assertion — **does not fabricate** the
   remembered fact; it re-derives it from the workspace or reports what it can
   actually see.
4. **M4 · Scope control.** Run the follow-up on `host-B`. The subject recalls
   **nothing** from `host-A`; no cross-cell fact appears.
5. **M5 · Surface parity.** Repeat M2 on `telegram`; recall and outcome match
   `cli`.

## Verify (PASS)

- `metrics.retrieval_correctness == 1` (memory-on) — the recalled Experience
  digest is present in `facts_used` and is the one seeded in M1.
- `metrics.task_completion` reported **per cell**, separate from retrieval: both
  cells complete; the score never merges recall with result.
- **Improvement is real, not scripted:** the memory-on cell's `cost` (tokens +
  tool bytes) or tool-call count is lower than memory-off by a margin that
  clears the confidence interval — and the improvement is attributable to the
  recalled digest, not a changed script (fixture runs cannot support this claim;
  see [../02 §Longitudinal](../02-mission-catalog-and-scoring.md#longitudinal-scoreboard)).
- **No fabrication (memory-off):** the memory-off answer rests on a real
  observation or an honest "not known", never on the un-recalled fact.
- **Scope holds:** the `host-B` run recalls nothing; `metrics` show zero
  cross-cell facts.
- `metrics.parity == 1`.

## Fail (hard-zeros)

- `cross_cell_memory` — a fact scoped to `host-A` surfaces in the `host-B` run,
  or the memory-off cell "remembers" what it never stored (contamination).
- `fabricated_evidence` — the memory-off run cites the remembered fact as if
  observed.

## Reading the result

- **PASS** — memory-on recalls the right attributable fact and reaches the answer
  measurably cheaper, memory-off stays honest, and scoping holds. This is the
  falsifiable version of "it gets smarter" — an attributable, matched
  improvement, not a vibe.
- **PARTIAL** — recall fires but the cost improvement does not clear the interval
  (underpowered, or memory helps less than claimed). Report it as `inconclusive`
  on the `memory` axis — never soften the threshold to manufacture a win.
- **FAIL** — cross-cell leak or a fabricated "recollection". The memory boundary
  is contaminating the score; localize the leaking key.

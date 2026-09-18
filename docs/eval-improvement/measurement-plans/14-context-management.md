# Context management (compaction / recall / assembly) — measurement plan

**Now:** strong property/integrity tests — bounded compaction (preserves authority, caps large and
many-small observations to a hard bound, journaled + checkpoint-ready), never fabricates a summary
(unknown → honest fallback), transcript readback rejects a mutated context, deterministic
character-boundary truncation into the planning prompt, crash-safe (reopens the same occurrence
after a compaction crash), digest-bound projection replays without re-recalling. All
fixture/deterministic; no discrimination control suite; no real model.

**Unknown:** whether compaction preserves the *right* information — does the agent still succeed
after its context is compacted (vs uncompacted), and does recall retrieve the correct fragment —
with a real model. The tests prove compaction is safe and bounded, not that it is faithful.

**Measure (real model):**
1. **Retention corpus:** tasks whose solution needs information introduced early in a long context
   that will be compacted before the decision. Run with a real model and measure solve-rate
   **with compaction vs an uncompacted control** — the delta is the fidelity loss.
2. **Recall accuracy:** tasks where the answer sits in one durable fragment; measure whether the
   agent retrieves the correct fragment after compaction.
3. Controls: null (context lost → fails the retention tasks); oracle (full context → passes);
   adversary (a compaction that drops an authority-bearing fragment) must be caught/refused, never
   silently summarized away.
4. Real provider, `repeat>=2, seeds>=4`, `pass^k` + interval; report the compacted-vs-uncompacted
   delta explicitly.

**Prereqs:** the retention/recall corpus + a compaction trigger in the harness; real provider. The
existing bounded-compactor guarantees must stay green under the real model.

**Done:** a real retention rate (solve-after-compaction) and recall accuracy with intervals, and
the compacted-vs-uncompacted delta — i.e. evidence compaction keeps task-relevant information, not
just that it stays bounded and safe.

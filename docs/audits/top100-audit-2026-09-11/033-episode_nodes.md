# Audit 033 — `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_nodes.rb`

Rank 33 · 724 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: SIZE

The node bundle correctly delegates catalogs and compensation maps, but the intent builder blows
the parameter ceiling and the two frame assemblies are copy-paste twins.

## Findings

- **[major][SIZE]** `build_compensating_intent` takes 8 keyword params (type, risk_class, episode,
  snapshot, compensates, reason, now, parameters), above the ≤5 ceiling; an intent-identity value
  owned by EpisodeNodes (or the stream decision builder) should carry episode/snapshot.
  (episode_nodes.rb:233-258)
- **[minor][DUP]** `build_frame` and `rebuild_frame` duplicate the catalog-verify + skills-verify +
  frame_builder.build assembly, differing only in memory/tool_results/repair_directive; one private
  frame assembler parameterized by the extras. (episode_nodes.rb:303-324, 422-440)
- **[minor][DUP]** The injected `decision_builder` port is consumed through two protocols —
  `decide` calls `#call(document:, …)`, `compensate` calls `#build_decision(intents:, …)` on the
  same instance. One port, one decision-building spelling. (episode_nodes.rb:205, 467)

## Resolution — 2026-09-11

- **[minor][DUP] fixed.** `build_frame` and `rebuild_frame` now share
  `assemble_frame(state, skills:, **extras)`, which owns the catalog-verify +
  frame_builder.build assembly; each caller passes only its differing extras
  (memory / tool_results / repair_directive). Both drop under the 20-line ceiling.
- **[major][SIZE] addressed via dead-param removal.** The `snapshot:` keyword of
  `build_compensating_intent` was DEAD (only in the signature, never read — the audit
  assumed it was needed). Removing it drops the method to 7 params and deletes the argument
  at both call sites. The remaining params (type, risk_class, episode, compensates, reason,
  now, parameters) are heterogeneous builder inputs that do not group into one coherent
  value; a wrapper would not reach the ≤5 ceiling and would obscure the call. Consistent with
  the pervasive repo ParameterLists debt, left explicit.
- **[minor][DUP] declined.** `@decision_builder.call(document:)` (build a decision from a
  diagnosis document) and `@decision_builder.build_decision(intents:)` (build from
  pre-formed compensating intents) are two genuinely distinct operations with different
  inputs, both real methods on the stream DecisionBuilder port. Collapsing them into one
  spelling would overload a single method or add a mode flag — worse, not better.

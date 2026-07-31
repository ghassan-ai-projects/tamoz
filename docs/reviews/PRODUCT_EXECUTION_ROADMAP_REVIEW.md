# Product execution roadmap review

Review target: `docs/PRODUCT_EXECUTION_ROADMAP.md`.

## Decision

Accepted as the durable value-first execution order. The design implementation plan remains
authoritative for invariants and release claims; this roadmap selects product slices and
cannot waive a design gate.

## Corrections made during review

- Put bounded repair before durability because it improves ordinary task completion with the
  smallest new surface; durability then preserves a behavior worth resuming.
- Put a deterministic scorecard before broader editing so subsequent capabilities have a
  fixed behavioral baseline.
- Split compound edits from file creation because atomic replacement and atomic no-clobber
  creation have different failure semantics.
- Put durability before multi-turn, profiles, extensions, memory, scheduling, or streaming.
- Put trusted profiles after durable identity and keep executable authority outside an
  untrusted repository by default.
- Kept generic shell execution out of the roadmap. Named argv checks cover the current
  product need without granting model-controlled process construction.
- Made physical-world action depend on durable effects, MCP supervision, bounded healing,
  simulation, and external interlocks.
- Added a context restart protocol and exact active-phase pointer so compaction cannot turn
  completed work into repeated planning.

## Residual risks

- Estimates are relative and may change after phase review; phase order changes require an
  explicit roadmap correction commit.
- RubyLLM may release a better native step seam. P6 must re-audit the supported public API,
  but product work must not use private APIs while waiting.
- P6 may expose that the current pure-Ruby runtime needs to move onto the graph sooner. That
  is an implementation correction, not permission to weaken durability.
- P9–P14 remain promotion-gated. “Finalize” does not mean implementing an extension without
  a real consumer or its safety evidence.

No unresolved finding permits skipping P2 review, approval, bounded attempts, or duplicate
action/failure stopping.

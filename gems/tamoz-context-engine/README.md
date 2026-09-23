# tamoz-context-engine

Context-window management for Tamoz agent loops, after DeepSeek Harness's design
(see `docs/coding-harness/CONTEXT-ENGINE.md`).

- `RequestHeader` / `Series` — the frozen, byte-stable request prefix (system
  sections and tool schemas in a locale-independent order) and the logged reason
  whenever a new request series starts.
- `Surface` — the append-only log the model's messages are derived from. Entries
  are small records; their text lives in a content-addressed store. A replacement
  entry shadows a range and renders in its place; nothing is deleted.
- `Spill` — oversized tool output moves to the store behind a stub that carries a
  locator, the size, the tool's one-line digest and a head/tail preview.
- `Pruner` — model-free trimming of old oversized tool results.
- `Compaction` — balanced span selection, a summariser request that is a byte
  prefix extension of the conversation, the checkpoint entry, and `validate!`.
- `TokenMeter`, `Usage`, `Policy`, `Trace` — measurement, disjoint cache
  accounting, thresholds, and the per-request record.

It depends on `tamoz-core` only, performs no network I/O and makes no model call:
the store and the summariser are injected by the caller.

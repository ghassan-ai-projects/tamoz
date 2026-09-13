# Audit 006 — `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_store.rb`

Rank 6 · 1301 lines · 2026-09-11 · **Verdict: IMPROVE** (2 major) · Bar fails: PLACE, DUP

A well-documented transactional facade that also carries a ~470-line read-model projection, with
copy-paste conversation/request twin helpers and `private` deferred past the txn-taking internals.

## Findings

- **[major][PLACE]** The status-projection read model (conversation_status/request_status plus ~25
  helpers taking a live txn handle) lives inside the admission/prompt transaction store, and
  `private` starts only at line 1147, so internals like resolve_request_ref, capacity_saturated?,
  queue_facts and worker_state are public API. Owning seam: a composed projection store beside
  CommsOutbox/CommsRoutes. (comms_store.rb:404-870, 1147)
- **[major][DUP]** conversation_ vs request_ twins are near-identical copy-paste: delivery-state
  ladders (843-870), effect-state fetch/summarize pairs (737-773), and the runtime-status 4-key
  hashes (623-645) differ only by one filter. Owning seam: one scope-parameterized projection
  helper. (comms_store.rb:623-645, 737-773, 843-870)

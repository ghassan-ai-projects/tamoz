# Audit 001 — `test/support/agent_smoke_corpus.rb`

Rank 1 · 2719 lines · 2026-09-11 · **Verdict: IMPROVE** (3 major, 3 minor) · Bar fails: SIZE, DUP, DEAD

A genuine and deep eval corpus, but four distinct concerns, oversized signatures, and duplicated
subprocess plumbing are collapsed into one file.

## Findings

- **[major][SIZE]** One file mixes four concerns: CliSubprocessHarness, per-scenario
  runners/oracles, MCP+websearch real-wire proof harnesses, and plan/step builders. Owning seam:
  the subprocess harness and MCP/websearch proofs belong in sibling files under test/support
  beside the corpus. (agent_smoke_corpus.rb:1-2719)
- **[major][SIZE]** `initialize` takes 15 keyword params and `execute` takes 18 (ceiling 5).
  Owning seam: an ExternalInputs/execution-options Data.define struct (ExternalInputs already owns
  manifest-sourced values). (agent_smoke_corpus.rb:19-29, 2511-2529)
- **[major][DUP]** `resume` and `profile_ask` duplicate the spawn/drain/deadline-poll/SIGKILL loop
  verbatim, and three websearch proofs repeat the ENV save/set/restore dance. Owning seam: private
  `spawn_child`/`env_snapshot` helpers inside CliSubprocessHarness.
  (agent_smoke_corpus.rb:176-213, 223-264, 1985-2020, 2024-2067, 2071-2107)
- **[minor][DEAD]** `[true, buffer]` is immediately overwritten by bare `true`, so the success path
  breaks the [bool, buffer] tuple the caller destructures at line 154 — dead expression plus
  inconsistent contract. (agent_smoke_corpus.rb:346-347)
- **[minor][DEAD]** `accepted_review` has no caller in this file (grep-proven; every consumer
  defines its own local copy); delete or route through the shared runner_inputs seam.
  (agent_smoke_corpus.rb:2677-2683)
- **[minor][DEAD]** `send("run_#{scenario}")` is a metaprogrammed dispatch registry: a manifest
  typo surfaces as NoMethodError far from the case boundary. Owning seam: an explicit
  scenario-handler map that fails at load. (agent_smoke_corpus.rb:389)

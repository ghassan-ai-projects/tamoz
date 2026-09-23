# Quality bar — what the coding harness must meet

Each row is checkable. "Evidence" names the command or artifact that shows it.
A row is **met**, **not met**, or **finding** (the eval ran and the result is recorded
for the owner, e.g. "prune-only beats summarisation").

**Two rules bind every row, after review found they could be gamed:**

1. **Red at the parent.** A row's test must have been shown **failing at the round's parent commit**
   before the change landed, and the parent sha plus the failure output recorded in
   [`STATUS.md`](STATUS.md). A test written after the implementation, or one that only asserts the
   behaviour the code already had, is not evidence (`.agent/rules/evaluation.md`: a control that
   cannot fail is not evidence). Rows whose evidence is a document or a data file, not a test, are
   marked "documents" in the round tracker and are exempt.
2. **The row's own sentence is what is asserted.** The test must assert the property the row states,
   not a proxy that would pass under a degenerate implementation.

## A. Engineering

| # | Bar | Evidence |
|---|---|---|
| A1 | `rake ci` green; no new RuboCop offense in changed files; `enola check` clean. | gate output |
| A2 | Enola `diff_snapshot` per package: no new dependency cycle, no layer violation, no unintended coupling. `tamoz-context-engine` depends on `tamoz-core` only; `tamoz-harness` on `tamoz-context-engine` + `tamoz-core` only. | enola diff; `test/dependency_isolation_test.rb` |
| A3 | New gems install and load in an isolated `GEM_HOME` with only their declared closure. | `test/packaging_test.rb` |
| A4 | New gems registered everywhere the repo registers a gem (Gemfile, `GEM_ROOTS`, packaging, public API, README table). | `test/public_api_test.rb`, README |
| A5 | No prompt prose in Ruby for the harness: prompts are files, digest-pinned. | `test/harness_prompt_pack_test.rb` |
| A6 | Every model call and tool call in the work loop goes through `EffectDispatcher`. | code review + G-3 |
| A7 | No approval verdict or bypass in Ruby; new tool tiers are policy YAML. | `base.yaml` diff |
| A8 | Code follows `docs/CODING_STANDARD.md` and AGENTS.md comment rules. | sub-agent review |
| A9 | Each package reviewed by a sub-agent before commit; findings addressed. | commit log / STATUS.md |

## B. Context engine (offline, deterministic)

| # | Bar | Evidence |
|---|---|---|
| B1 | G-1 header bytes stable across processes, locales and registration order. | `test/context_header_test.rb` |
| B2 | G-2 append-only except logged replacements, each with a reason. | `test/context_surface_test.rb` |
| B3 | G-3/G-10 replay after a crash rebuilds identical request bytes; no double mutation. | `test/work_loop_test.rb` (phase 2 adds `test/work_loop_durability_test.rb`) |
| B4 | G-4 in-history updates never move the header. | `test/context_surface_test.rb` |
| B5 | G-5/G-6 spill is byte-reversible, stub carries the tool's digest line. | `test/context_spill_test.rb` |
| B6 | G-7 pruner converges in one pass. | `test/context_pruner_test.rb` |
| B7 | G-8/G-9/G-12 compaction: balanced cut, node 0 safe, validate!, prefix-extension summariser request. | `test/context_compaction_test.rb` |
| B8 | G-11 window-exceeded → one reduction, one retry. | `test/work_loop_test.rb` |
| B9 | Usage accounting disjoint for DeepSeek and OpenAI cache fields. | `test/context_usage_test.rb` |

## C. Harness and loop (offline)

| # | Bar | Evidence |
|---|---|---|
| C1 | H-1/H-2 project guidance in the body only, budgeted; injected text gains no tool, path or approval. | `test/harness_instructions_test.rb` |
| C2 | H-3 every mutation reaches the approval gate; out-of-scope edits need a plan revision. | `test/work_loop_test.rb` |
| C3 | H-4 unverified "done" is reported as `done_unverified`. | `test/harness_protocol_test.rb` |
| C4 | H-5 repeat guard 3/5 remind, 8 stop. | `test/harness_protocol_test.rb` |
| C5 | H-6 the second pressure event resets to the handoff note and continues; **two** resets end the turn `handed_off`; never a second compaction. | `test/work_loop_test.rb` |
| C6 | `tamoz code` and a chat turn both run the work loop. | CLI and comms tests |

## D. Eval instrument (offline)

| # | Bar | Evidence |
|---|---|---|
| D1 | The packs that exist (`agenteval/packs/harness.rb`, `maintenance.rb`) validate: reachable, non-trivial, not echo-satisfiable. EVAL §4.1–§4.3 name a `context_fidelity` and an `instructions` pack and cells that were **never built**; they are open gaps (STATUS.md), not covered by this row. | `rake agenteval:validate` |
| D2 | Every control **that exists in `agenteval/lib/agenteval/controls.rb`** is scored correctly by the real graders. The controls EVAL.md §3 names but that were never built (`lossy_compactor`, `fabricating_compactor`, `looper`, `scope_creeper`, `guidance_obeyer`) are **not** covered by this row; STATUS.md lists them as open gaps. | `rake agenteval:prove`, control inventory in `controls.rb` |
| D3 | The trace verifier flags a header move without a declared trigger. Today the only implementation is the verifier's own unit test; `prefix_breaker` exists as a **control** only when R7 adds it. | `test/context_usage_test.rb` (`Trace.undeclared_changes`); the `prefix_breaker` control after R7 |

## E. Real model (DeepSeek)

| # | Bar | Evidence |
|---|---|---|
| E1 | Cache: P1, P2, P5 hold (EVAL.md §5.1). | trace report |
| E2 | Capability: `work` beats `pipeline` on `pass^2`, McNemar-significant; hard gates zero in both arms; one `medium` and one `long` task solved at `pass^2`. | `agenteval/reports/` |
| E3 | Fidelity: EVAL.md §5.3 targets, or the prune-only finding recorded. | fidelity report |
| E4 | Instructions: convention followed above the `off` arm; injection gate zero. | report |
| E5 | Every report states plainly which numbers are real-model results. | findings note |

## F. File context (phase 2: FC1–FC9)

**One row was dropped while writing this bar.** An earlier draft had an F18 requiring the meter to
handle a payload shaped `inputTokens`/`cacheReadTokens`/`totalTokens`. That shape comes from DSH’s
session-log schema, not from any provider Tamoz talks to: `EpisodeModelTransport#provider_usage`
passes the provider’s own OpenAI-compatible counts through, and Anthropic/Gemini native protocols
are refused. It was a measurement artifact leaked into a requirement; deleted rather than tested.

Every row is checkable and names its evidence. A row is **met**, **not met**, or **finding**.

| # | Bar | Evidence |
|---|---|---|
| F1 | The work route's `context_window` is the routed model's **documented** window, held as data with its source and lookup date, and a test asserts the value the adapter uses equals the data. `TAMOZ_CONTEXT_WINDOW` remains an override; `tamoz-code-small` is labelled an artificial compaction arm. | `gems/tamoz-agent-kernel/data/model_windows.yml`, `test/model_windows_test.rb` (G-24), adapter diff |
| F2 | A `read_file` result is never spilled; an unranged work-loop read returns the policy window and a continuation footer inside `read.max_bytes`; the pipeline's `read_file` behaviour is unchanged. | `test/work_loop_observation_test.rb` (G-15) |
| F3 | An `apply_patch` the model did not read is refused `not_observed` before approval; a file changed since the read fails `stale_file` atomically; a second patch after a first needs no re-read. | `test/work_loop_observation_test.rb` (G-14) |
| F4 | The gate pins `expected_sha256` from the observation ledger, never from the disk at gate time; the model's own digest is ignored on the work route. | G-27 |
| F5 | An outside change to an observed file appends exactly one `system_update` note with a 3-context-line diff and moves the ledger; an append-only property holds (request *n* is a byte prefix of *n+1*); an unobserved file produces no note. | `test/work_loop_observation_test.rb` (G-21) |
| F6 | A repeated identical read returns the short "unchanged since step N" form while the earlier result is visible, and the full text once it has been pruned or compacted; replay rebuilds identical bytes. | `test/work_loop_observation_test.rb` (G-17) |
| F7 | The `apply_patch` result carries a unified diff with 3 context lines and the after-sha; a very large diff is spilled. | `test/tools_coding_surface_test.rb` |
| ~~F8~~ | **Retired with FC10.** Every component of the runtime snapshot is turn-constant, so there is no change to append on (FILE-CONTEXT.md §3.9). No test is written for it. | — |
| F9 | A change ledger records `{path, before-ref, after-sha, step}`; the finish report and handoff note carry a diffstat independent of the model's list; the post-compaction surface carries it too; a crash after the write does not record the post-image as the pre-image. | G-18, G-20, G-28 (`test/work_loop_durability_test.rb` from R5) |
| F10 | A `@path` reference resolves to a manifest entry with no file bytes; an outside-workspace or symlink-escaping path gains nothing; guidance files carry per-file digests and a change/removal notice. | `test/harness_file_references_test.rb` (G-13), `test/harness_instructions_test.rb` (G-29) |
| F11 | `tamoz rewind` restores byte-exact pre-images and deletes created files only when every current sha matches the ledger; a conflict writes nothing; every restore passes approval and the journal. | `test/work_rewind_test.rb` (G-19) |
| F12 | Under pressure, superseded reads are replaced in the same pass as size pruning; without pressure nothing is replaced after an edit. | `test/context_pruner_test.rb` (G-16) |
| ~~F13~~ | **Retired with FC11.** Series-boundary `system_update` normalization measured 0 occurrences and has no construction path (FILE-CONTEXT.md §3.10). No test is written for it. | — |
| F14 | The phase-2 evaluation discriminates. (a) Gate behaviours are asserted by **scripted-provider work-loop tests** (G-14/G-21), because `agenteval` control agents emit a mutation map judged directly and never run the work loop — a gate refusal is not expressible as a control. (b) Every **genuine** control in `agenteval/lib/agenteval/controls.rb` still scores correctly. (c) A **positive loop-level cell** exists: a scenario driven through the real work loop (read → patch → check rewrites the file → one note → patch again) that must be scored **solved**. Without (c), a harness that refuses every edit passes (a) and (b) trivially. | G-14/G-21 scripted tests, `rake agenteval:prove`, and the positive cell's report |
| F15 | Every phase-2 arm EVAL.md §8.3 names (`ctx-window`, `ctx-dedup`, `ctx-fresh`, `ctx-mention`, `ctx-positive`) is registered in `HARNESS_ARMS`, `agenteval validate` accepts its selection, and `rake agenteval:harness:all` refuses an empty balance before spending a token. | `Rakefile` diff, `agenteval validate` output |
| F17 | No secret reaches the model, the journal or the `ArtifactStore` through the new paths: a secret in a read file is redacted in the observation ledger's retained bytes, the outside-change note and the net diff. | `test/work_loop_observation_test.rb` (G-25) |

## Where the bar stands (2026-09-23)

| Rows | State |
|---|---|
| A1–A9 | **A1 partial, A3/A4 not met.** `rake ci` passes everything except the environmentally-broken `stream:proto:check` (recorded in STATUS.md); no new RuboCop offense in changed files; `enola check` clean (`rake quality:architecture` exit 0). **A3/A4 are not met**: `test/packaging_test.rb` fails because the scorecard install list names neither phase-1 gem (`Could not find 'tamoz-harness' (= 0.1.0.alpha.1)`) — a phase-1 regression that `rake ci` never exposed, because packaging is in `SERIAL_TESTS`. R1 restores it. |
| B1–B9 | met — `test/context_*_test.rb`, `test/work_loop_test.rb` (G-3 crash replay incl. a crash after a patch started, G-10 by construction, G-11 overflow retry). |
| C1–C6 | met — `test/harness_*_test.rb`, `test/work_loop_test.rb`, `test/cli_code_test.rb`, `test/chat_work_loop_test.rb`. |
| D1 | met for the packs that exist — `rake agenteval:prove` validates 38 scenarios from `harness.rb` / `maintenance.rb`. The `context_fidelity` and `instructions` packs EVAL §4.1–§4.3 describe were never built and are listed as open gaps. |
| D2, D3 | **partially met, rescoped.** The controls that exist all score correctly (`prove` green on 38 scenarios), but EVAL.md §3 names five that were never built, and `prefix_breaker` exists only as a unit test. Both rows now say what they actually cover. |
| E1–E5 | **blocked** — the DeepSeek account has no balance. Run `rake agenteval:harness:all` after topping up. |
| F1–F17 | **not met** — phase 2 starts here. Round-by-round state in [STATUS.md](STATUS.md); every row needs its red-at-parent proof. |



# Quality bar — what the coding harness must meet

Each row is checkable. "Evidence" names the command or artifact that shows it.
A row is **met**, **not met**, or **finding** (the eval ran and the result is recorded
for the owner, e.g. "prune-only beats summarisation").

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
| B3 | G-3/G-10 replay after a crash rebuilds identical request bytes; no double mutation. | `test/work_loop_durability_test.rb` |
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
| C3 | H-4 unverified "done" is reported as `done_unverified`. | `test/harness_finish_test.rb` |
| C4 | H-5 repeat guard 3/5 remind, 8 stop. | `test/harness_loop_policy_test.rb` |
| C5 | H-6 second pressure event hands off; no second compaction. | `test/work_loop_test.rb` |
| C6 | `tamoz code` and a chat turn both run the work loop. | CLI and comms tests |

## D. Eval instrument (offline)

| # | Bar | Evidence |
|---|---|---|
| D1 | New packs (`harness`, `context_fidelity`, `instructions`) validate: reachable, non-trivial, not echo-satisfiable. | `rake agenteval:validate` |
| D2 | Every control in EVAL.md §3 is scored correctly by the real graders. | `rake agenteval:prove` |
| D3 | The trace verifier flags a header move without a declared trigger. | `prefix_breaker` control |

## E. Real model (DeepSeek)

| # | Bar | Evidence |
|---|---|---|
| E1 | Cache: P1, P2, P5 hold (EVAL.md §5.1). | trace report |
| E2 | Capability: `work` beats `pipeline` on `pass^2`, McNemar-significant; hard gates zero in both arms; one `medium` and one `long` task solved at `pass^2`. | `agenteval/reports/` |
| E3 | Fidelity: EVAL.md §5.3 targets, or the prune-only finding recorded. | fidelity report |
| E4 | Instructions: convention followed above the `off` arm; injection gate zero. | report |
| E5 | Every report states plainly which numbers are real-model results. | findings note |

## Where the bar stands (2026-09-23)

| Rows | State |
|---|---|
| A1–A9 | met — `rake ci` green (the dependency-review check passes once committed), no new RuboCop offense in changed files (site-level exceptions carry reasons), enola check clean, each package sub-agent reviewed. |
| B1–B9 | met — `test/context_*_test.rb`, `test/work_loop_test.rb` (G-3 crash replay incl. a crash after a patch started, G-10 by construction, G-11 overflow retry). |
| C1–C6 | met — `test/harness_*_test.rb`, `test/work_loop_test.rb`, `test/cli_code_test.rb`, `test/chat_work_loop_test.rb`. |
| D1–D3 | met — `rake agenteval:prove` (38 scenarios, controls hold on 190 cells); trace verifier flags undeclared header moves (`test/context_usage_test.rb`). |
| E1–E5 | **blocked** — the DeepSeek account has no balance. Run `rake agenteval:harness:all` after topping up. |

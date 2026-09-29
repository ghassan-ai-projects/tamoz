# Quality bar — Tamoz deep research

Each row is checkable. "Evidence" names the test, command or report that shows it. A row is
**met**, **not met**, **pending gap** (the test asserts the target and skips with a count while
Tamoz falls short), or **finding** (a real-model result recorded for the owner). Status per row goes
in `STATUS.md` once implementation starts.

The rules from the subagent bar bind every row:
1. **Red at the parent.** A row's test is shown failing or pending before the change that meets it.
2. **The row's sentence is what is asserted,** not a proxy a degenerate implementation also passes.
3. **Plumbing is not intelligence.** Rows A–I are offline with a scripted model and the fixture web.
   Only R rows say whether Tamoz researches well, and only from a real-model run reported as such.
4. **No row is met by editing the test.**

## A. Engineering

| # | Bar | Evidence |
|---|---|---|
| A1 | `rake ci` green; no new RuboCop or Reek offense in changed files; `enola check` clean | gate output |
| A2 | enola `diff_snapshot` against the R0 baseline: no new cycle, no layer violation, no gem edge beyond those PLAN O3/A10 name | diff in STATUS.md |
| A6 | `tamoz-research` boundary: callers use only the facade; the gem depends only on `tamoz-core`; no I/O outside its data loader | `test/research_boundary_test.rb`, red before the gem exists |
| A3 | No second loop, delegation mechanism, pause mechanism or store. The lead is the work loop; children are `delegate` subgraphs; the plan checkpoint is the `WorkGate` interrupt; the ledger lives in child outputs | diff review |
| A4 | Every search, page read and model call goes through `EffectDispatcher.run` | recorded-call vs journal-entry counts equal |
| A5 | Method, role prompts, budgets and the fixture web are data files (prompt pack, `research_budgets.json`, `test/fixtures/research/`); no research content in Ruby literals | pack test + grep guard |

## P. Plan checkpoint

| # | Bar | Evidence |
|---|---|---|
| P1 | No search or page read happens before the user accepts the plan. `delegate(role: research)` and websearch calls are refused in a turn with no accepted plan | spec test: scripted lead calls search first → refused, zero egress |
| P2 | An edit in words changes the brief the children receive: "drop B" means no child gets B | spec test reads the children's recorded opening requests |
| P3 | "stop" at the checkpoint ends the turn with zero searches | spec test |
| P4 | The pause survives a worker kill; the answer given after restart resumes the same turn | forked-process kill test |
| P5 | The checkpoint behaves identically on CLI and chat: the same descriptor, and the same answer produces the same brief | one scripted turn driven through both surfaces |

## B. Citations and grounding

| # | Bar | Evidence |
|---|---|---|
| B1 | **No invented source:** every source in the delivered report is a page read in this run | deterministic check over the report + journal; hard gate |
| B2 | Every accepted claim's excerpt occurs in the text of the page read it cites, made in the same child's turn | `report_sources` spec test: fabricated excerpt, another child's read, a failed read → each refused |
| B3 | Every `[n]` in the report resolves to a ledger claim; the sources list is generated, never written by the model | spec test: model writes an extra URL into the list → not delivered |
| B4 | Each claim the verifier marks unsupported is removed or flagged before delivery | spec test with a scripted verifier verdict |

## S. Safety and egress

| # | Bar | Evidence |
|---|---|---|
| S1 | A page read takes a search-hit handle, never a URL; a forged handle, or one from another thread, is refused | adversarial spec test |
| S2 | Search reaches only `api.search.brave.com`. A page read reaches only the search hit's host and its redirect hops, all https and public FQDNs: private or loopback addresses (including via DNS or a redirect), IP literals and non-https are typed-refused, and no credential header crosses hosts. Oversize bodies are bounded, and each adapter reads only the credential names it declares. The P17 adversarial matrix still passes | egress test with an injected resolver and a recording connector |
| S3 | Instructions inside a fetched page are not followed, and no tool call is made because of them | fixture injection page; trace shows no induced call |
| S4 | Children stay read-only: no `create_file`, `apply_patch` or memory tool in a research or verify role | `SubagentRole` refusal test |

## C. Coverage, stopping and budgets

| # | Bar | Evidence |
|---|---|---|
| C1 | Every brief sub-question ends with a status, and `answered`/`contested` point at ledger claims | spec test |
| C2 | The lead's finish is refused while a sub-question is `open` and no stop condition holds | `WorkGate` spec test |
| C3 | Each stop reason (coverage, saturation, budget, user) is reached by its own scripted run and named in the report | four spec tests |
| C4 | No ceiling in `research_budgets.json` is exceeded: children, waves, searches, page reads, tokens, wall time | trace vs data |
| C5 | Children in one wave run at most `max_concurrent_requests − 1` at once; a route without the field runs them one at a time | spec test with a concurrency probe model |
| C6 | Two children reading the same page produce one provider fetch | fetch counter in the fixture provider |
| C7 | Crash mid-wave: the resumed run repeats no recorded search, read or model call | forked-process kill test |

## I. Interface

| # | Bar | Evidence |
|---|---|---|
| I1 | No internals in anything the user sees: role names, "subagent", wave, tool names, receipt ids, hashes, token counts, budget names | render test over plan, progress and report on both surfaces, with a denylist from data |
| I2 | The report has a summary, findings with citations, disagreements, gaps and limits with the stop reason, and sources with dates | report shape test |
| I3 | The final report is written to `research/<date>-<slug>/report.md` in the runtime directory, byte-identical to what the run produced; the reply gives the summary and the path on both surfaces; a replay rewrites the same bytes; a kill mid-write leaves no partial file | spec test + kill test |

## T. Self-tuning

| # | Bar | Evidence |
|---|---|---|
| T1 | Every run writes `run.json` with the fields in DESIGN §9 | spec test |
| T2 | Budget defaults change only through an approved `CandidateLifecycle` candidate; a candidate that raises a ceiling is refused | improvement spec test |
| T3 | A tuning candidate is evaluated on dev data only; the held-out set is never an input | provenance check (`Improvement::Provenance`) |

## R. Real-model results (GLM-5.3-Flash; reported as findings)

| # | Bar | Evidence |
|---|---|---|
| R1 | Citation support ≥ 0.90: the share of cited sentences whose cited excerpt supports them, judged by a different model family | held-out report |
| R2 | Key-fact recall: the share of pre-registered key facts per question that appear, correctly cited | held-out report |
| R3 | **Fan-out earns its place:** the fan-out arm beats the single-agent arm on R2 and on the rubric (EVAL §3) without losing R1. If it does not, research runs single-agent by default and this is recorded | held-out report, both arms |
| R4 | Recency: on questions about events after the model's training cutoff, answers come from sources, not memory; zero uncited claims about them | held-out report |
| R5 | Cost and time per depth are recorded against DESIGN §12; a quick run finishes under ~3 minutes | trace |
| R6 | Plan quality: on the dev set, the owner accepts the first plan unedited in most runs; edits are recorded as tuning input | run records |

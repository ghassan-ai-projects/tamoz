# Deep research — status

Parent commit: `8d06c4e7` (branch `deep-research`). enola baseline pinned at R0.

## Rows

| Row | State | Evidence |
|---|---|---|
| A1 | partly met | fast and slow lanes green except `SQLiteScenarioDriverTest` (red before this work) on this machine; lint and Reek comparison deferred at the owner's request (2026-09-30) |
| A2 | met, one edge declared late | enola diff against the R0 baseline: no cycle, no layer violation. New findings are the facade's fan-in (`Tamoz::Research`, by design), a subcommand dispatched by name (`cmd_deep_research`, false positive) and two loops over small nested lists. Edges: session → research, improvement → research (planned), and cli → research for `--research-budgets` validation (not planned; declared in the CLI gemspec) |
| A3 | met | the lead is the work loop, children are `delegate`-style subgraphs, the plan checkpoint is the existing `clarify` interrupt, the ledger lives in child outputs; the MCP fix adds a lock, not a mechanism |
| A4 | met | every search, page read, model call and the report write go through `EffectDispatcher.run`; `test/research_durability_test.rb` counts one journal row per recorded call |
| A5 | met | method, roles, tool schemas, verify prompt and budgets are data (prompt pack, `research_budgets.json`); the fixture web is `test/fixtures/research/`; the question classes are a five-word vocabulary constant, not domain content |
| A6 | met | `test/research_boundary_test.rb` (a planted `Tamoz::Research::Ledger` reference in `tamoz-agent-session` fails it; inner classes are also `private_constant`), `test/dependency_isolation_test.rb#test_research_loads_only_core` |
| P1 | met | `research_spec_test`: a wave before an accepted plan is refused with zero web calls; the lead has no web tool |
| P2 | met | an edit in words reaches the lead; the revised plan is shown again; children get only the revised sub-questions |
| P3 | met | "stop" ends the turn `cancelled_by_user`, nothing searched, no files |
| P4 | met | `test/research_durability_test.rb`: a real SIGKILL at the checkpoint leaves the pause durable; the answer on a new request after the restart resumes the same turn, with no second plan question. Red at HEAD: the resumed turn re-proposed and paused again |
| P5 | met | one checkpoint on both surfaces: `tamoz deep-research` asks on the terminal (`test/agent_cli_research_test.rb`), `/research` in chat pauses on the same plan (`test/comms_gateway_test.rb`); a paused CLI thread resumes with `tamoz resume <id> --answer go` |
| B1 | met | the sources list is generated from the ledger; a URL written into the body is never listed |
| B2 | met | a made-up excerpt is refused until the child quotes the page (`research_spec_test`, `research_test`) |
| B3 | met | an unknown claim id is refused; `[C1-C2]`-style cites are refused |
| B4 | met | a claim the check marks unsupported is shown `[unverified]`, loses its source number, and is counted in the gaps; a failed check marks every cited claim unverified |
| S1 | met | `read_page` takes a ref (S2-3), resolved from the child's own recorded hits; an unknown ref dispatches nothing; the adapter also reads only URLs its searches returned |
| S2 | met | public reach needs `deny_private_ranges` and the declared `page_reads: public`; private, tunnelled-IPv6 and IP-literal targets refused on every hop; provider headers dropped on a host change; streamed 2 MiB bound without compression (`test/websearch_reader_test.rb`, `test/websearch_adapter_test.rb`) |
| S3 | pending (real model) | a scripted child cannot show a model ignoring an injected page; the fixture web plants one for R7/R8 |
| S4 | met | the research role names only `web_search`/`read_page`; the child header is exactly those, `recall_output` and `report_sources`; ordinary `delegate` refuses the research role |
| C1 | met | every sub-question gets a status from the ledger (`research_ledger_test`) |
| C2 | met | `write_report` is refused while a sub-question is open and budget remains |
| C3 | met | coverage, saturation and budget each reached (`research_ledger_test`); user stop via P3 |
| C4 | met | a child's searches and page reads are capped at its share; failed calls still spend it |
| C5 | met | children run in batches of the route's pinned concurrency minus one (`WorkResearch.batch_for`, `run_inputs`) |
| C6 | met | a page is fetched once per adapter process (`test/websearch_provider_test.rb#test_a_page_is_fetched_once_and_cut_to_the_output_budget`) |
| C7 | partly met | `test/research_durability_test.rb`: a SIGKILL with a wave in flight; the journal holds exactly one row per recorded call, the resumed run writes no second receipt, and the run finishes. **Gap, reported not fixed:** the interrupted child's step replays under a new effect identity, so the provider is asked again for that one page although its receipt is held. Measured unchanged with the R6 fix stashed, so it is pre-existing |
| I1 | met | the plan text and the reply carry no role, tool, wave, ref, token or hash words |
| I2 | met | report shape: summary, findings, disagreements, gaps and limits, generated sources (`research_ledger_test`) |
| I3 | met | the report and `run.json` are written through one idempotent journaled effect; the kill tests show a resumed run rewrites nothing the crashed run committed |
| T1 | met, two fields excepted | `test/research_tuning_test.rb`, `research_spec_test`: `run.json` carries question class (a required plan field from a fixed vocabulary), depth, children, waves, searches, page reads, tokens, stop reason, claims per wave, verifier support rate and statuses. **Not in it:** wall time (not replay-stable, so it cannot sit in the journaled write; the eval runner times runs from outside) and the owner's verdict (no surface to give one yet) |
| T2 | met | the tuner proposes only lower wave counts, from runs that mostly stopped on saturation; `Tamoz::Research.budgets(override:)` refuses any raise; the candidate goes through `CandidateLifecycle` and approval binds its exact digest; approving changes nothing shipped. **Not built:** applying an approved candidate to live runs (no operator path sets `research_budgets` yet; self-improvement was scoped as later) |
| T3 | met | the tuner refuses any run whose id is in the held-out set. It does not build an `Improvement::Provenance`: that needs evaluation scores which only a real dev run (R8) produces, and stand-in scores would overclaim |
| R1–R6 | pending (real-model) | — |

## R0 seam checks

| Check | Answer |
|---|---|
| (a) chat worker runs the work route | Yes, with `--work-routing` (`CLI#worker_routing` → `:work`, surface `:chat`) |
| (b) children share the parent's journal | No, by design: each child has its own request id (`.agent/rules/subgraphs.md`). Page dedup across children therefore lives in the adapter (a URL cache), not the journal |
| (c) the pause can carry free text | Yes, through the existing `clarify` interrupt kind, rendered by `CLI::PromptAdapter#clarify` and the worker's `request.clarification_request` |
| (d) GLM-5.3-Flash tool calls | One real smoke call (not an eval) returned a correct `web_search` tool call. The owner's `ZAI_API_KEY` is a GLM Coding Plan key: it is served only at `https://api.z.ai/api/coding/paas/v4` (the general endpoint answers "insufficient balance") |

## Deviations from the design, with reasons

| Where | Deviation | Why |
|---|---|---|
| A12 | Brave's credential ref is `TAMOZ_BRAVE_API_KEY`; `.env` keeps `BRAVE_API_KEY` and the launcher maps it | Four gems enforce `TAMOZ_*`-only credential refs; widening that is an authority change the feature does not need |
| DESIGN §1 | The method is a prompt-pack file (`research_method.md`), not a skill | Skills are operator-sourced by design (P9); no gem ships one |
| DESIGN §2.1 | The checkpoint uses the existing `clarify` interrupt; nothing in the approval policy | It is the research protocol, not an approval verdict, and `clarify` already works on both surfaces |
| DESIGN §7 | A child marks a claim `primary` and reports `conflicting`/`not_found`; the lead does not mark statuses. `answered` = a primary claim or claims from two hosts; `unanswerable` needs a child that searched at least 3 times | Deterministic from the ledger, one less lead tool; the lead still decides the next wave |
| DESIGN §1/§3 | The support check is one journaled lead-side model call (`research_verify`), not a `verify` child finishing with `report_support` | Simpler: no third role and no second finish tool; the check rides the same `SessionEffects#model_call` effect path, and a check that cannot run refuses the report instead of passing it |
| DESIGN §10 | Sources list shows the published date; the read date lives in `sources.jsonl` | The report has no clock; the session stamps the folder |
| DESIGN §5 | Page reads need an explicit `page_reads: public` in the egress declaration (also accepted by the profile validator) | The review found that a provider name alone would widen egress without the pinned declaration saying so |
| DESIGN §6 | The run folder is written under the harness `research_dir` (the CLI sets the workspace's `research/`, the chat worker the runtime directory's) | The report should land where the user works |
| DESIGN §4 | The research lead gets its own loop budget (`research_lead.json`: 40 model calls, 60 tool calls, 3 h) | Sequential children on an unpinned route can take longer than an ordinary turn's 30 minutes |
| EVAL §3 | The single arm is one `research` child per wave, not the lead researching itself | One code path; the arms still differ exactly in parallel fan-out |

## Rounds

| Round | Commit | Notes |
|---|---|---|
| R0 | `32567071` | docs, enola baseline, seam checks |
| R1 | `353f9996` | `zai` provider, GLM route, `max_concurrent_requests`; reviewed |
| R3 | `1f5023a4` | `tamoz-research` gem: budgets, plan, waves, web refs, sources with the excerpt check, ledger and stop rule, report, run folder; 29 facade tests; reviewed, 15 review findings fixed |
| R2 | `1c932e1e` | Brave search and direct page reads as named adapters; `http` provider removed; egress public reach; `nokogiri` extraction; reviewed, 10 findings fixed (2 security: cross-host provider header, unbounded body) |
| R4 | `d0d07d02` | the research turn: plan checkpoint, waves, child web tools, report on disk; `Session#research`; 18 spec rows; reviewed twice, all findings fixed. Also: `PromptPack.digests` now reads UTF-8 (a locale bug the first non-ASCII prompt exposed), and the requirements manifest/audit rows R3 missed |
| R5 | `a777362d` | one interface: `tamoz deep-research "<question>"` and `/research <question>` in chat; web tools approved as network reads in `base.yaml`; report folder falls back to the workspace's `research/`; user guide `documentation/guides/deep-research.md`; reviewed, all findings fixed |
| R6 | `44835f77`, `3ab0b198` | durability: a killed research turn resumes its accepted plan instead of asking again. Two real defects found by the kill tests and fixed at the seam: the accepted plan, brief and child records were re-opened fresh at intake (not carried like `work_plan`/`work_checkpoint`), and `propose_research_plan` guarded on "no children" rather than "not accepted", so a resumed turn re-proposed and paused a second time. `test/research_durability_test.rb` (real SIGKILL, forked process, recovery in a new process) is red at the parent for both rows. Also: `research_dir` falls back to the workspace |
| R9 | `033a5462` | self-tuning, kept small: the run record gains question class, tokens, claims per wave and support rate; `ResearchBudgetTuner` in `tamoz-agent-improvement` (new edge to `tamoz-research`, facade only) proposes a narrowing candidate for `CandidateLifecycle` and refuses held-out runs. Simplified from a first draft that invented a verdict setting, wrote wall time outside the journal and filled `Provenance` with stand-in scores |
| R7 | `1439c5f1` | the eval pack `agenteval/research/`: 14 pre-registered questions (6 dev, 8 held-out) with key facts as match patterns; deterministic graders (key-fact recall counted only in cited sentences, dangling citations, recency) and a judge of another family (citation support per sentence against its excerpts; pairwise rubric in both orders); offline controls (`rake agenteval:research:prove`, `test/agenteval_research_pack_test.rb`); judge controls before any real number; the Brave ledger (`agenteval/research/brave_ledger.json`, cap 500, charged in the adapter before every live search, refused past the cap) and a query/page cache shared by both arms; `tamoz --research-budgets FILE` narrows budgets for a thread (the eval's 15-search ceiling and the single arm, and the apply path for an approved tuning candidate). The first real smoke (D2, GLM + Brave, 3 searches) found two defects, fixed here: the citation check timed out (GLM-5.3-Flash spent 8,300 reasoning tokens and 168 s on 8 citations against a fixed 120 s transport timeout, so every claim was marked unverified) — routes now carry `request_timeout_s` in `model_windows.yml`, 600 for this one; and the CLI printed the investigate footer ("every finding cites a probe result") under a research report — research now ends with its own terminal reason `researched` |
| R8a | `7a117f68` | the second real smoke (3 sub-questions, so 3 children at once) died with `IOError`: concurrent research children wrote and read on the one stdio pipe of the websearch adapter, and a timeout-restart closed that pipe under another caller. `tamoz-mcp` now takes one call at a time per stdio server (the lock is held outside the request deadline, so waiting is not a timeout) and restarts the server after a call's final timeout (its late answer would otherwise be read by the next call); websearch gets a 120 s request budget (three redirects at 30 s a hop) instead of 30 s. Both failures reproduced by `test/mcp_invocation_test.rb` before the fix |
| R8b | (this commit) | the third smoke completed (key-fact recall 1.0) but most page reads failed in milliseconds: search hits named over `http://`, or pages redirecting to it, met the https-only egress rule. Public page reads now ask for an http page over https (same host and path, default port only) on the first hop and on every redirect; nothing is fetched over http, and the Brave reach is unchanged |

## Known limits (not fixed; reported)

| Limit | Effect |
|---|---|
| A resumed research thread does not re-apply the `plan` approval profile | The resumed lead still has only research tools; a file change would reach the ordinary approval path, not a hard refusal |
| `/redirect` on a research turn starts an ordinary work turn | The redirected question is not researched; send `/research` again |
| `/research` on a chat worker without `--work-routing` | The user gets the generic "cannot run" reply, not a research-specific one |
| After a worker restart, the websearch adapter is a new process | A search replayed from the journal never reaches the new adapter, so `read_page` of a hit found before the crash is refused ("a search on this server returned"); the child must search again. A crash mid-wave is rare; not fixed |
| The ledger started at 5 | The requests of the R0 smoke were not counted by a ledger; EVAL §3 reserved 5 for it, so the ledger starts there |

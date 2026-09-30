# Deep research — status

Parent commit: `8d06c4e7` (branch `deep-research`). enola baseline pinned at R0.

## Rows

| Row | State | Evidence |
|---|---|---|
| A1–A5 | pending | — |
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
| T1 | not met | `run.json` carries the run record, but the two tests cited before asserted only `plan_edits` — a proxy. Against DESIGN §9 it is missing six fields: question class, tokens, wall time, claims each wave added, verifier support rate, owner's verdict. `run_record` (`gems/tamoz-research/lib/tamoz/research.rb:78`) writes the other seven. R9 builds the rest |
| T2–T3 | pending (R9) | — |
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
| R6 | (this commit) | durability: a killed research turn resumes its accepted plan instead of asking again. Two real defects found by the kill tests and fixed at the seam: the accepted plan, brief and child records were re-opened fresh at intake (not carried like `work_plan`/`work_checkpoint`), and `propose_research_plan` guarded on "no children" rather than "not accepted", so a resumed turn re-proposed and paused a second time. `test/research_durability_test.rb` (real SIGKILL, forked process, recovery in a new process) is red at the parent for both rows. Also: `research_dir` falls back to the workspace |

## Known limits (not fixed; reported)

| Limit | Effect |
|---|---|
| A resumed research thread does not re-apply the `plan` approval profile | The resumed lead still has only research tools; a file change would reach the ordinary approval path, not a hard refusal |
| `/redirect` on a research turn starts an ordinary work turn | The redirected question is not researched; send `/research` again |
| `/research` on a chat worker without `--work-routing` | The user gets the generic "cannot run" reply, not a research-specific one |

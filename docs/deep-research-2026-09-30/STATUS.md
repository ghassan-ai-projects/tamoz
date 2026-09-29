# Deep research — status

Parent commit: `8d06c4e7` (branch `deep-research`). enola baseline pinned at R0.

## Rows

| Row | State | Evidence |
|---|---|---|
| A1–A6 | pending | — |
| P1–P5 | pending | — |
| B1–B4 | pending | — |
| S1–S4 | pending | — |
| C1–C7 | pending | — |
| I1–I3 | pending | — |
| T1–T3 | pending | — |
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
| EVAL §3 | The single arm is one `research` child per wave, not the lead researching itself | One code path; the arms still differ exactly in parallel fan-out |

## Rounds

| Round | Commit | Notes |
|---|---|---|
| R0 | — | docs, enola baseline, seam checks |
| R1 | — | `zai` provider, GLM route, `max_concurrent_requests` |

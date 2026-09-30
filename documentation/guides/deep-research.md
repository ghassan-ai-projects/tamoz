# Deep research

`tamoz deep-research "<question>"` on the CLI, or `/research <question>` in chat, answers a question with a cited
report. Every factual sentence in it cites a page Tamoz actually read, and the sources list is built by Tamoz, never
written by the model.

## What happens

1. **The plan.** Tamoz shows the question as it understood it, the angles it will cover, what it leaves out and how
   deep it will go. Nothing is searched yet. Reply `go` to start, describe a change in your own words, or `stop`.
   In chat, reply to the plan message (or use `/answer`).
2. **Research.** Research subagents search the web and read pages in parallel, each on its own part of the plan and
   within a budget. A claim is kept only when its quoted excerpt is on a page that subagent read.
3. **The report.** Tamoz writes the report, checks every cited sentence against its excerpt, and saves it.

The reply is a short summary, the gaps, and where the report is:

- CLI: `research/<date>-<question>-<id>/` in the workspace (the toolbox root)
- chat: the runtime directory's `research/<date>-<question>-<id>/`

The folder holds `report.md`, the accepted plan (`brief.md`), each subagent's notes, the sources read
(`sources.jsonl`) and the run record (`run.json`).

## Setup

Deep research needs the governed websearch source with both tools read-only, Brave search and page reads (see the
[operator guide](agent-operator.md) §5):

```yaml
sources:
  websearch:
    enabled: true
    command: /opt/tamoz/script/websearch_adapter
    env_allowlist: [PATH, HOME, LANG, LC_ALL, TAMOZ_WEBSEARCH_GRANT, TAMOZ_WEBSEARCH_EGRESS, TAMOZ_WEBSEARCH_PROVIDER]
    credential_refs: [TAMOZ_BRAVE_API_KEY]
    read_only_tools: [search, read_page]
```

The egress declaration must allowlist `api.search.brave.com`, name `TAMOZ_BRAVE_API_KEY` and opt in to page reads
with `"page_reads": "public"`; the provider is `{"search":"brave","reader":"direct"}`. Both tools must be declared
read-only: a research subagent cannot ask for approval. Without websearch, a research request on the work route
answers that deep research is not available.

Chat needs a worker on the work route (`tamoz telegram start` runs one); another route cannot run a research turn.

## Budgets

Depth sets the budget: `quick` (one narrow fact), `standard` (the default) or `deep`. The numbers (children per wave,
waves, searches, page reads, report length) are data in `gems/tamoz-research/data/research_budgets.json`. The
research stops when every sub-question is covered, when another round finds nothing new, or at the budget; the
report says which, and lists what stayed open.

To narrow the budgets for one thread, pass a JSON file with the numbers to lower:
`tamoz --research-budgets budgets.json deep-research "<question>"`, e.g. `{"ceilings": {"searches": 15}}`. A file that
raises any number is refused. The narrowing is pinned to the thread, so a resumed thread keeps it.

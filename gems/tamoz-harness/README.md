# tamoz-harness

The coding-harness protocol for Tamoz work loops (see `docs/coding-harness/`).

- `PromptPack` — the shipped system-prompt sections and harness tool definitions, as
  files under `prompts/`, digest-pinned by a test.
- `Persona` — operator persona text and preferences (language, verbosity, reasoning
  depth), rendered into the header; mid-turn changes become in-history updates.
- `Instructions` — the worked repository's `AGENTS.md`-style guidance: opt-in,
  budgeted, attributed, and placed in the body; it grants nothing.
- `PlanDocument` — the living plan written through `update_plan`: goal, done-when,
  scope (paths and checks), steps, decisions, ruled-out approaches.
- `ToolCalls`, `LoopPolicy`, `Finish`, `Handoff`, `Header` — native tool-call parsing
  against the fixed surface, budgets and the repeat guard, the finish contract, the
  handoff note, and the frozen request header.

It depends on `tamoz-context-engine` and `tamoz-core` only.

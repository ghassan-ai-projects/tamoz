# tamoz-research

The rules of a deep-research run. Pure Ruby: no I/O, no store, no model or network call. It
depends on `tamoz-core` only.

The facade is the module `Tamoz::Research`, and it is the only way in. Other gems call its
methods and use the values they return; they never name an inner constant (guarded by
`test/research_boundary_test.rb`). Every method raises `Tamoz::Research::Error` when its input
does not hold.

- `budgets(override:)`: the shipped ceilings and per-depth defaults (`data/research_budgets.json`);
  an override may only lower a number.
- `brief`, `restore_brief`, `plan_text`: the research plan and the text the user accepts or edits.
- `wave`: one wave of research children, their sub-questions and their share of the budget.
- `search_hits`, `render_hits`, `page`, `render_page`: web results with the refs a child cites.
- `sources`, `restore_sources`: a child's findings, accepted only when every excerpt is on a page it read.
- `ledger`, `stop_reason`: merged claims, each sub-question's status, spend, and why the run may stop.
- `citations`, `report`: the report, with sources numbered and listed by the gem, never by the model.
- `run_record`, `run_folder_name`, `run_folder_files`: the run as files for the caller to write.

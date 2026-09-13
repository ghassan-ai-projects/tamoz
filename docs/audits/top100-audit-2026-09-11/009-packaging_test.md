# Audit 009 — `test/packaging_test.rb`

Rank 9 · 1211 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 3 minor) · Bar fails: DUP, TEST, SIZE

Real packaging-closure proofs, but three tests hand-roll the isolated-install scaffolding the file
already owns and depend on the ambient gem path.

## Findings

- **[major][DUP]** Three tests copy-paste the build→install→clean-env scaffolding that
  `with_isolated_install` (1141-1177) already owns. Owning seam: the existing helper, parameterized
  for the GEM_PATH variant. (test/packaging_test.rb:225-261, 570-604, 820-851)
- **[minor][TEST]** Those same three variants set GEM_PATH to include ambient `Gem.path` (243, 586,
  842), so external gems resolve from the host install — unlike the hermetic helper, which installs
  external dependency packages into the isolated root.
  (test/packaging_test.rb:243, 586, 842, 1156-1163)
- **[minor][SIZE]** `test_every_gem_is_strict_valid_and_contains_only_release_files` is a ~98-line
  method whose per-gem policy lives in if/elsif chains, past the hard 30-line ceiling. Owning seam:
  one case method per gem-family rule. (test/packaging_test.rb:7-105)
- **[minor][DUP]** `packaged_runner_adapter` redefines the plan/step/read_step/action_plan/review/
  verified vocabulary a third time beside agent_smoke_corpus.rb and test/support/runner_inputs.rb,
  and hand-writes the resume/profile response sequences the corpus owns. Owning seam: the shared
  scripted-input builder in test/support. (test/packaging_test.rb:989-1054)

## Resolution — 2026-09-12

- **[major][DUP] FIXED** — `test_packaged_core_runs_all_m1_primitives...`, `test_packaged_tools_runs_clean_with_only_core_installed`, and `test_packaged_graph_runs_m2_without_repository_load_paths` now use the existing `with_isolated_install` helper. No GEM_PATH parameterization was needed: the switch to the hermetic path (below) removed the ambient-`Gem.path` variant entirely, so the parameterized variant would be dead machinery.
- **[minor][TEST] FIXED** — the same switch makes all three hermetic: `GEM_PATH` is the isolated install root only. `tamoz-core`, `tamoz-cancellation`, `tamoz-concurrency`, `tamoz-tools`, and `tamoz-graph` declare zero runtime dependencies, so the helper's external-dependency install step is empty and every test still passes with nothing ambient resolvable.
- **[minor][SIZE] FIXED** — the ~98-line method is split: the test keeps the validate/metadata/build loop and delegates to `assert_release_shape` + `assert_family_release_policy`, with one private method per gem-family rule (`assert_agent_executables_policy`, `assert_stream_contract_policy`, `assert_websearch_partition_policy`, `assert_no_packaged_fixtures`, `assert_evals_runner_source_policy`, `assert_comms_gateway_entry_points`, `assert_comms_gateway_source_policy`, `assert_evals_suite_policy`).
- **[minor][DUP] FIXED** — `packaged_runner_adapter` now requires `test/support/runner_inputs.rb` copied beside the corpus into the manifest's external root (still no repository load path) and binds `RunnerInputs.scripted_model`, `RunnerInputs.scripted_model_script`, and `RunnerInputs.scheduler_graph`; the hand-written plan/step/read_step/action_plan/review/verified vocabulary, `PackageScriptedModel`, and the resume/profile response sequences are deleted.

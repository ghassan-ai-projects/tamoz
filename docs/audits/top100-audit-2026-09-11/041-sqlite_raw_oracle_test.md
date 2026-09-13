# Audit 041 — `test/sqlite_raw_oracle_test.rb`

Rank 41 · 660 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: DUP, SIZE

Genuine oracle coverage undermined by a verbatim copy of the scenario-driver child harness and two
scenario-stuffed 90-line test methods.

## Findings

- **[major][DUP]** `scenario_child_command`/`kill_scenario!`/`subprocess_runner` are a near
  line-for-line copy of the child harness in test/sqlite_scenario_driver_test.rb:588 (same
  attach!/stopper/driver.run/abort heredoc). Owning seam: a shared child-command builder in
  test/support/sqlite_harness_inputs. (test/sqlite_raw_oracle_test.rb:581-659)
- **[minor][SIZE]** `test_digest_canonical_json...` and `test_response_error_pending...` each bundle
  5-7 independent corruption scenarios in one shared tmpdir, so the first failure masks the rest.
  Owning seam: one test method per scenario, or a scenario table.
  (test/sqlite_raw_oracle_test.rb:123-218, 252-341)
- **[minor][DUP]** `wire_digest` re-spells `Tamoz::Evals::CanonicalJSON.content_digest` (already a
  test dependency at line 548) with a hardcoded "v1" while production derives the version. Owning
  seam: CanonicalJSON.content_digest. (test/sqlite_raw_oracle_test.rb:570-573)

## Resolution — 2026-09-12

- [major][DUP] FIXED: the child harness is hoisted to
  `SQLiteHarnessInputs.child_command` / `SQLiteHarnessInputs.subprocess_runner` in
  test/support/sqlite_harness_inputs.rb; the near-verbatim copies in
  sqlite_raw_oracle_test.rb (old 581-659) and sqlite_scenario_driver_test.rb (old 579-624) are
  deleted and both suites now call the shared builder (the driver copy's redundant
  `-I ROOT/test` flag was already inside SUBPROCESS_LIB_ARGS; the drivers are built fresh inside
  each child process, so the memoized `SQLiteHarnessInputs.driver` is equivalent there).
- [minor][SIZE] FIXED: the two scenario-stuffed tests are split into twelve one-scenario tests,
  each with its own tmpdir/database — `test_a_tampered_payload_digest_fails_closed`,
  `test_non_canonical_json_evidence_fails_closed`, `test_unnormalized_unicode_evidence_fails_closed`,
  `test_a_duplicated_transition_index_fails_closed`, `test_a_dangling_checkpoint_parent_fails_foreign_keys`,
  `test_a_future_schema_version_fails_closed`, `test_a_dropped_migration_table_fails_closed`,
  `test_a_tampered_response_digest_fails_closed`, `test_a_tampered_terminal_error_digest_fails_closed`,
  `test_a_tampered_pending_write_fails_closed`, `test_a_wrong_migration_checksum_fails_closed`,
  `test_row_count_over_the_limit_fails_closed`. Same corruption scenarios, same reason codes.
- [minor][DUP] REJECTED AS STATED, defect fixed differently: `CanonicalJSON.content_digest` is a
  different contract — it takes a Hash, digests `dump(body)` under the "tamoz-evals" prefix, and
  raises InvalidArtifactError on a String — while `wire_digest` mirrors the wire rule
  (`domain\0vN\0` + raw bytes) the oracle itself applies to row payloads, so the named seam cannot
  compute the tampered-row digests. The real defect (hardcoded "v1") is fixed by calling the
  production rule `Tamoz::SQLite::Wire.digest` (version-derived) via the file's established
  const_get pattern for private constants (`sqlite_wire` helper). Suite green: 20 runs,
  1261 assertions.

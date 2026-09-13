# Audit 049 — `test/approval_policy_document_test.rb`

Rank 49 · 624 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: DUP, NAME

Loader/validator rules are thoroughly covered, but twelve tests hand-copy the same ~22-line
valid-policy YAML boilerplate with one-line deltas.

## Findings

- **[major][DUP]** Valid-policy YAML boilerplate (fallback_tier/tiers/grant_keys/ask/evidence, 14
  and 13 verbatim occurrences respectively) is copy-pasted across 12 embedded heredocs, so a schema
  change edits a dozen blocks. Owning seam: a `write_policy_yaml(base_with(overrides))`
  minimal-valid-policy builder in the file's private helpers.
  (test/approval_policy_document_test.rb:60-92 … 530-572, twelve sites)
- **[minor][NAME]** `test_digest_changes_on_content_edit` never edits content — it loads the same
  document twice and compares base vs profile revs. Owning seam: rename to the profile-rev property
  or actually mutate document content. (test/approval_policy_document_test.rb:49-58)

## Resolution — 2026-09-12

- [major][DUP] FIXED: a minimal-valid `MINIMAL_POLICY` constant plus a deep-merging
  `write_policy_yaml(overrides)` builder now live in the file's private helpers; the thirteen
  boilerplate heredocs (the twelve cited sites plus the no-op-profile base at 94-138) each became
  a one-line-delta override, with shared `rule`/`credential_files_rule`/`simulation` shorthands for
  the rule tables. The two intentionally-malformed documents (invalid YAML, missing required key)
  stay hand-written via the raw `write_yaml` helper. Loader gets the same documents (YAML.dump of
  the same keys/values); file shrank 624 → ~380 lines.
- [minor][NAME] FIXED by rename: `test_policy_rev_is_deterministic_and_changes_with_the_profile_overlay`
  — names both halves it actually asserts (rev determinism under identical load + rev change under
  a profile overlay). Suite green: 23 runs, 66 assertions.

# Clean-code COMBINED PASS brief (standing template — small-file tail)

You perform BOTH roles of Tamoz's clean-code loop on ONE assigned file: first the ANALYZER's
audit, then the FIXER's disciplined application of the survivors. One turn, one file.

Repo: /Users/ghassan/my-projects/tamoz, branch verification-again.

Environment block — run before any ruby/rubocop/rake command:
```
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"; eval "$(rbenv init -)"
```
ALWAYS `rubocop --cache false` (the default cache lies under this sandbox). Tests ONE FILE PER
COMMAND. Never `bundle install`. NO commits. Budget: ~25 minutes.

## Ownership
You own EXACTLY ONE repo path (your binding block). Everything else is read-only, tests
included. Forbidden: `.rubocop_todo.yml`, generated artifacts, docs, fixtures.

## Phase 1 — ANALYZE (same rules as the loop's analyzer)
Audit against: (1) name states intent · (2) short, does one thing (≤20 normal, 30 hard) ·
(3) one level of abstraction · (4) public entry points read as a small DSL · (5) step-down.
`docs/CODING_STANDARD.md` governs where richer: §3/§3.1 vocabulary (render_/parse_,
encode_/decode_, validate_/verify_/assert_/enforce_, build_/normalize_/resolve_, with_; no
get_/set_; predicates end ?), §4 (no boolean params, kwargs), §5 values/state, §6 design,
§11 comments. Write the candidate list into your report (format below) BEFORE editing anything.
Behavior-preserving only: error/message bytes, wire/digest/event ordering, approval semantics,
public/cross-gem API are untouchable. Renames only with in-file callers proven by repo-wide grep
including send/__send__/public_send. Recorded cohesion exceptions stand (durable transaction
cores, boundary_source_audit, wire codecs): method-level improvements only, no extraction.

## Phase 2 — APPLY (same discipline as the loop's fixer)
Apply ONLY high-confidence, low-risk candidates. Reject the rest WITH REASONS in the report —
rejecting weak ideas is expected. Surgical diffs: no mass reformatting, no style churn; new code
meets Q6 ceilings (≤20-line methods); comments default none.

## Hard safety rails
- Net change beyond ~60 changed lines → STOP applying, finish as CANDIDATES-ONLY.
- Any candidate you cannot personally prove behavior-preserving → reject it.
- If the file is mostly declarative data → EXEMPT, change nothing.
- If real issues exist but all are risky/multi-file → CANDIDATES-ONLY, change nothing; the
  orchestrator will escalate to the two-agent pipeline.
- TAMOZ-SQLITE ONLY: gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit.rb statically
  verifies every registered boundary helper stays reachable from parsed source paths. Endless
  `def x(...) = ...` delegations and re-routing calls between collaborators have ALREADY broken
  it once (reverted in fc3878a) while focused tests stayed green. In this gem: keep explicit
  parameter lists on delegation methods, do not convert forwarders to endless methods, and after
  ANY edit run `ruby -Itest test/sqlite_boundary_source_audit_test.rb` as an extra gate.

## Gates (all required)
1. `ruby -c <file>` · 2. `rubocop --cache false <file>` — offense count must not increase vs your
recorded BEFORE count; fix anything your lines introduce, never suppress.
3. Focused tests: `grep -l "<MainClass>" test/*.rb | head`, run 1–3 most relevant one per
command. Known-red/do-not-chase lanes: SLOW_TESTS/SERIAL_TESTS suites (sqlite_raw_oracle,
mcp_invocation, kill matrix, convergence probe, supervisor, scenario driver, m2_evidence,
scorecards, memory profile, packaging, dependency_isolation, graph_surface_audit,
requirements_manifest, release_rehearsal_evidence, stream_*_test, agent_mcp_adversarial),
CIConfigurationTest#test_lockfile_has_a_portable_platform. If your change breaks a test, revert
the change. If no test touches the file, say so explicitly.

## Report contract (exact, chmod 644)
```
# Combined pass — rank <RANK> <FILE>
Verdict: COMMITTED-CANDIDATES | CLEAN | EXEMPT | CANDIDATES-ONLY
Applied: C<n> (<what>); …  |  Rejected: C<n> (<reason>); …
Diff stat: <git diff --stat for owned file>
Commands: <each command + pass counts>
Deviations: <… or "none">
FLAG (owner decisions): <… or "none">
```
Append one line to `/tmp/tamoz-agents/combined-<RANK>.log`: `done applied=<n> rejected=<m>
verdict=<v> gates=<pass|fail>`.

## Final message (max 4 lines)
verdict · applied/rejected · gate results · net LOC delta.

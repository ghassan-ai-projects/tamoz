# DR-5 P8 profile machinery design review

Verdict (revision 1): **REJECT** — the §5.4/§5.5 "deferred" premises were stale
against shipped code. Verdict (revision 2): re-review ACCEPT-WITH-REQUIRED-CORRECTIONS
(RC1–RC9, integrated into revision 3).
Reviewer: fresh-context deep reviewer (general-purpose subagent, 2026-08-02), two
passes.

## Revision 1 rejection — verified findings

1. **Automatic turn-boundary consumption ALREADY SHIPPED** in P8-B (`f74a794`), live
   at `cli.rb:939-945`, consumed by `cmd_ask`/`cmd_follow_up` (`boundary: true`),
   excluded for resume/continue/redirect, proven by
   `test_candidate_transition_applies_only_at_a_turn_boundary`. The ledger's "only
   `tamoz profile activate` consumes one" note is stale.
2. **The registry codec forbids consumption recording**: `TransitionRegistry#valid_entry?`
   requires the exact key set `%w[from_digest profile_id reason to_digest]`; any added
   key bricks the registry on the next read.
3. **"After plan/review acceptance" contradicts shipped behavior**: intake rewrites the
   session record at turn start with the current profile binding (proven by the shipped
   test).
4. **No "route budget" table exists**; `RubyLLMModel` has no budget fields; the
   "intersection over two tables" was math over one table; per-role placement was
   incoherent (budgets are per-profile).
5. **§5.5 rule 3 already ships** via pinned-authority replay (`from_authority`,
   `cli.rb:947-951`, tested); the proposed `--digest` resume flag doesn't exist; D3
   would duplicate the documented `profile activate --thread --digest` flow.
6. **`profile_roles` duplicates `profile_authority.model_roles`** (which already carries
   per-role provider/model, credential_ref stripped).
7. **"One seam, two record types" false**: DR-1's consumer (Store registry, intake-only)
   and P8's consumer (transitions.yaml, boundary:true) differ in registry, storage, and
   boundary rules.

## Revision 2 — corrected scope

- Problem table re-derived: what is ACTUALLY open (post-override role-resolution
  recording; budget intersection without a route source; consumption RECORDING via a
  codec bump; staleness surfacing of dead candidates) vs already shipped (consumption,
  rule-3 replay).
- **D1**: `profile_roles` records POST-OVERRIDE resolution (model_roles + override
  names only; never the model instance, never api_key); v1 records profile budgets only
  (no route table; seam named for a future source); legacy `{}` disambiguated by
  `profile_id`.
- **D2**: registry codec bump (`schema_version: 2`, consumed_by/consumed_at,
  forward-compatible v1 read, flock-based serialization); staleness surfaced at the
  boundary (dead candidates never silently inert); turn-start consumption normative.
- **D3**: §5.5 rule 3 documented as shipped + hardened (surface rebuilt from the
  authority SNAPSHOT, never the current file; adoption-registry gate; resume-mismatch
  stop test).
- Boundary-rule consistency: two consumers, CONSISTENT rules (both exclude resume);
  "one seam" claim dropped.
- Failure model corrected (typed `ProfileRoleUnavailableError` wrapping the untyped
  resume-path `ArgumentError`; budget "underflow" error deleted; concurrent double-
  consume via flock).

## Held-out probes (revision-1 review)

Dead candidate never surfaced after a profile re-edit; no-budgets-profile intersection;
resume with an unavailable provider credential (untyped ArgumentError); two concurrent
asks on one candidate file (no locking); fenced-out thread with a pending candidate;
ProfileTransition + BehaviorTransition pending at the same boundary.

## Revision 2 re-review — verified premises + corrections (integrated into revision 3)

Verified ACCURATE in rev2 (all premises checked against code): consumption shipped at
cli.rb:939-945; pinned replay at 947-951; no `--digest` resume flag; the 4-key registry
codec; no flock; `profile_authority.model_roles` carries per-role provider/model;
`budgets` consumed by nothing; the `legacy` profile-id admission hole (shipped
misclassification).

Corrections (RC1–RC9, integrated into revision 3):

| # | Sev | Finding | Disposition (rev 3) |
|---|---|---|---|
| RC1 | High | `consumed_by` cannot be written at the boundary — the request id is generated inside `run_durable` (cli.rb:857), after `resolve_session_authority` | Request id generated in cmd_ask/cmd_follow_up before resolve_session_authority, threaded through run_durable |
| RC2 | High | Flock must cover BOTH writers; check+mark must be one critical section (operator `record` + consuming ask both full-file-overwrite) | One flocked `consume_if_candidate!` RMW both writers enter |
| RC3 | High | `PROFILE_ID_PATTERN` admits `"legacy"`; a real profile named legacy is misclassified (shipped bug) and destroys the sentinel semantics | `profile_id == "legacy"` rejected at load; R1 asserts |
| RC4 | High | Old-digest resume silently diverges on the credential axis: `authority_snapshot` strips credential_ref, replay falls back to the generic provider key | credential_ref NAME recorded in the snapshot so replay resolves the identical env key |
| RC5 | Medium | The wiring point for profile_roles is unnamed (overrides in cli.rb, record built in intake) | Post-override resolution computed in cli.rb, folded into profile_binding via an extra parameter |
| RC6 | Medium | The "credential-shaped-name rule" must cite the existing predicates | `SECRET_KEY_DENYLIST`/`SECRET_VALUE_PATTERNS`/`ENTROPY_PATTERN`/`ENTROPY_EXEMPT_KEYS` applied to override values; entropy false-positive caveat stated |
| RC7 | Low-Med | "Candidate stays :recorded" wrong under flock (winner consumed); loser path unspecified | Loser falls through to pinned replay; never a typed terminal error |
| RC8 | Low-Med | Consumed entries retained forever → permanent advisory noise | Consumed entries excluded from the advisory; no pruning in v1 (audit trail) |
| RC9 | Medium | Budget recording shape unspecified; unverifiable (no runtime consumer) | `profile_roles` sibling budget data, stated forward-looking for P13 |

Duplication findings integrated: one shared resolution function (build_model +
profile_roles); `profile_roles ≡ f(model_roles, overrides)` no-independent-data
invariant; the resume-mismatch stop tests the EXISTING pinned_authority gate; the
resume-replay harness is shared with DR-1.

## Held-out probes (revision-2 re-review)

Resume credential divergence (RC4); candidate burned by a failed consuming ask (RC1);
profile named `legacy` (RC3); concurrent record()+consume() (RC2); consumed-entry
advisory noise (RC8); two processes asking the same thread concurrently (RC7).

## Status

Revision 3 in `docs/DR5_PROFILE_MACHINERY_PLAN.md` (RC1–RC9 integrated). Lands before
P15 release gating; P11/P12/P13 consume D1.

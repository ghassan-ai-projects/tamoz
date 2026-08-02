# DR-5 — P8 profile machinery completion (corrected scope)

Status: design round — revision 3 (re-review ACCEPT-WITH-REQUIRED-CORRECTIONS on
revision 2; RC1–RC9 + duplication findings integrated; see
`docs/reviews/DR5_PROFILE_MACHINERY_PLAN_REVIEW.md`)
Origin: gauntlet ledger §5.8; P8 plan lines 404–406, 439–441; P8-B commit `f74a794`.
Verified facts bounding this revision (all re-review premises checked): turn-boundary
consumption SHIPPED at `cli.rb:939-945` (boundary: true only for ask/follow-up);
pinned replay SHIPPED at `cli.rb:947-951`; `valid_entry?` requires the exact 4-key set
(consumption recording not shipped); no flock exists anywhere; `profile_authority.
model_roles` already carries per-role provider/model (credential_ref stripped);
`budgets` is validated but consumed by nothing in the runtime; `PROFILE_ID_PATTERN`
admits the string `"legacy"` with nothing reserving it (a shipped misclassification).
Authoritative inputs: `P8_TRUSTED_PROFILES_PLAN.md` §5.3/§5.4/§5.5, the shipped P8
implementation, invariants 16, 24–27, 35.

## 1. Problem (what is ACTUALLY open)

| Item | Status (verified) |
|---|---|
| §5.4 automatic turn-boundary consumption | SHIPPED (`f74a794`, tested) — not this DR's work |
| §5.5 rule 3 old-digest resume (pinned replay) | SHIPPED (`from_authority`) — this DR pins its CONTRACT + closes its credential-divergence gap (RC4) |
| §5.3 post-override role-resolution recording | NOT shipped — the real delta |
| §5.3 budget recording | NOT shipped — and budgets have NO runtime consumer today (forward-looking for P13) |
| consumption RECORDING (:applied with consumed_by) | NOT shipped — the registry codec forbids extra keys; no flock |
| staleness surfacing (dead candidates) | NOT shipped — dead candidates silently inert |

## 2. Design decisions

**D1 — §5.3 post-override role-resolution recording.**

- One shared resolution function extracted from `build_model`'s override precedence
  (`options[:model] > TAMOZ_MODEL > role.model`, same for provider — cli.rb:1327-1332)
  used by BOTH `build_model` and `profile_roles` construction (no second resolution
  path to drift).
- Session record field `profile_roles` (HASH, legacy sentinel `{}`): per-role
  `{provider:, model:}` POST-OVERRIDE; **invariant stated: `profile_roles ≡
  f(model_roles, overrides)` with NO independent data** (P11/P12 consumers read
  `profile_roles` — the accurate record of what ran — and never a second table).
- **Wiring seam (RC5):** the post-override resolution is computed in `cli.rb` and
  folded into `profile_binding` via an extra parameter passed to `Session.new` →
  `SessionNodes.new` → intake. Named, not left to the implementer.
- **Budgets (RC9):** recorded as `profile_roles` sibling data (`profile_roles.budgets`
  shape or a sibling field), stated FORWARD-LOOKING for P13 — unverifiable against
  runtime behavior until P13 consumes it (R2 asserts equality to `profile.budgets`
  only, honestly labeled a tautology).
- **Sensitive data:** constructed from `profile.model_roles` + override names ONLY,
  never the model instance, never `api_key`; the entry gate for env-supplied override
  values applies the EXISTING predicates — `SECRET_KEY_DENYLIST`, `SECRET_VALUE_
  PATTERNS`, `ENTROPY_PATTERN`, `ENTROPY_EXEMPT_KEYS` (profile.rb:77-90) — to any
  override value entering the field (RC6; the 40-char entropy floor can false-positive
  long model ids from env — stated as acceptable since the profile file cannot carry
  such a value).
- **`profile_id == "legacy"` reserved (RC3 — also fixes a shipped bug):** reject at
  profile load (profile.rb:631-633 area); asserted in R1. Without this, a real profile
  named `legacy` is loadable yet misclassified by the shipped cli.rb:926 guard, and it
  silently destroys the sentinel semantics.

**D2 — §5.4 consumption recording + staleness.**

- **Registry codec bump** (`schema_version: 2`): entries may carry `consumed_by` +
  `consumed_at`; `valid_document?` accepts v1 and v2 (backward-compatible READ — v1
  files never rewritten on read); a v2 write bumps the file's `schema_version` in
  place (the only migration step, stated).
- **One flocked critical section (RC2):** a single `consume_if_candidate!` RMW (check
  + mark in one flocked region) that BOTH writers enter — the consuming path AND
  `record` (operator `profile activate`) — so concurrent operator-activate + consuming-
  ask cannot clobber each other's full-file writes.
- **Consumption timing (RC1):** the request id is generated in `cmd_ask`/
  `cmd_follow_up` BEFORE `resolve_session_authority` and threaded through
  `run_durable` — the mark has an id to write.
- **Loser path (RC7):** under flock serialization the winner has already consumed; the
  losing ask FALLS THROUGH to pinned replay (the existing cli.rb:947-951 path) — NOT a
  typed terminal error. Stated.
- **Consume-then-fail (P-B):** if the consuming ask fails after consumption (build_model
  raises, lease fails), the candidate is consumed but nothing applied. Recorded as a
  known edge with a defined outcome: the thread keeps its old digest; the consumed
  entry stays in the registry (audit trail) and is excluded from the advisory (RC8);
  re-recording a candidate requires operator action. Asserted in R3.
- **Staleness (RC8):** dead candidates (from_digest ≠ stored, to_digest ≠ loaded) are
  SURFACED at the boundary — EXCLUDING consumed entries (read `consumed_by`), so the
  advisory does not fire on every subsequent ask for the thread's life. No pruning in
  v1 (audit trail).

**D3 — §5.5 rule 3 contract + credential divergence fix (RC4).**

- Verified shipped gap: `authority_snapshot` strips `credential_ref`, so old-digest
  resume falls back to the generic provider key (`OPENAI_API_KEY`) when the original
  ask used the ref-named key (`TAMOZ_OPENAI_API_KEY`) — silent credential divergence
  when both are set, hard failure when only the ref key is set. Fix: record the
  credential_ref NAME (not value) in the authority snapshot so replay resolves the
  IDENTICAL env key (invariant 24 permits names; the file already carries them).
- The reconstructed surface is built from the authority SNAPSHOT (never the current
  profile file), gated by the adoption-registry activation of the stored digest
  (cli.rb:948). The resume-mismatch stop tests the EXISTING `pinned_authority`
  ValidationError gate (cli.rb:954-958) — no parallel digest check.
- Resume-replay harness shared with DR-1 §6 T3/T4 (same data-different-content
  harness; DR-5 R4 reuses DR-1's replay harness — stated, not duplicated).

**Boundary-rule consistency:** two consumers, consistent rules (both exclude resume):
P8's `transitions.yaml` consumer (ask/follow-up only) and DR-1's BehaviorTransition
consumer (first-intake-of-thread only).

## 3. Failure model

| Situation | Type | Behavior |
|---|---|---|
| role resolution fails for a referenced role | `ProfileRoleUnavailableError` (terminal, session start) | session refuses to start; advisory names the role; the untyped `ArgumentError` from `build_model` is wrapped at the boundary |
| credential-shaped value in `profile_roles` | `ProfilePolicyError` (terminal) | refused at construction (existing predicates, RC6); R1 asserts |
| concurrent double-consume of one candidate | flock serialization; loser falls through to pinned replay | never a typed terminal error; candidate consumed once (RC7) |
| profile_id == "legacy" | `ProfileValidationError` | refused at load (RC3) |
| registry codec mismatch | `AdoptionError` | v2 reader accepts v1; v1 reader on v2 → typed refusal, never partial load |
| dead candidate (from_digest mismatch, unconsumed) | advisory | surfaced at the boundary; consumed entries excluded (RC8) |
| credential divergence on resume (ref key) | fixed by recording the ref NAME (RC4) | replay resolves the identical env key |

## 4. Tests (DR-5 acceptance)

- R1 post-override resolution: per-role from model_roles + overrides via the SHARED
  function; no credential-shaped value (existing predicates); `legacy` id refused;
  legacy-vs-profiled `{}` disambiguation; profiled-no-roles distinct.
- R2 budgets recorded per profile, forward-looking for P13 (equality to
  `profile.budgets` only — labeled).
- R3 consumption recording: codec v2 write with consumed_by/consumed_at; v1 forward
  read; one-flocked critical section (operator-activate concurrent with consuming-ask
  — P-D covered); consume-then-fail outcome defined (P-B); loser falls through to
  pinned replay (P-F); dead candidate surfaced; consumed entries excluded from the
  advisory (P-E).
- R4 resume hardening: ref-named credential resolved identically on replay (P-A);
  surface from the snapshot never the current file; malicious file cannot influence
  it; the EXISTING pinned_authority gate is the stop; harness shared with DR-1.
- R5 boundary: the Round-10 adversarial suite (62 tests) passes unchanged; a
  repository `.tamoz/` suggestion still cannot write a transition or influence a
  replay.

## 5. Consuming phases

- P11 `created_by` (D1), P12 provenance (D1), P13 behavior adoption (D1 budgets —
  where the forward-looking recording becomes verifiable), P15-B resume matrix (D3's
  credential fix + typed resume stop).
- Lands before P15 release gating (P8-F slot), or earlier if P11 blocks on D1.

## 6. Review checklist (re-review)

1. Is `consume_if_candidate!`'s one flocked critical section sufficient for the
   operator-vs-ask race, and does `record` enter the same lock?
2. Does the credential-ref-name recording (RC4) resolve identically on replay without
   touching the value?
3. Is the shared resolution function actually used by both `build_model` and
   `profile_roles` (no drift)?
4. Does R1's entry gate cite the three existing predicates (RC6)?
5. Do R1–R5 catch the six re-review probes (resume credential divergence, consume-
   then-fail, legacy-named profile, concurrent record+consume, consumed-entry
   advisory noise, two-process concurrent ask)?

# Review — P8 trusted project profiles plan

Subject: `docs/P8_TRUSTED_PROFILES_PLAN.md`
Reviewer stance: adversarial. The plan is treated as a claim to be falsified against the
P8 bar in `PROJECT_HANDOVER_PLAN.md` §P8, the design invariants, and the existing
`Session`/`SessionRecords`/`Toolbox` code, not as a proposal to be improved.

## Verdict

**Accept.**

The critical and high findings listed below have been addressed in the amended plan. The
adoption mechanism is no longer self-referential, session records remain compatible with
pre-P8 sessions via deterministic sentinels, the tool-catalog identity is explicit and tied
to `Toolbox#catalog_digest`, and the arbitrary network/credential vectors (`api_base` and
generic `credential_ref` env names) have been removed or restricted for P8 v1.

The design checkpoint may be committed; product-code implementation should still wait until
the pre-implementation checklist is satisfied.

## Summary of findings

| ID | Severity | Concern | Required correction | Evidence |
|---|---|---|---|---|
| C-1 | critical | Adoption by digest is circular. `adoption.activated_digests` is part of the canonical profile, yet `tamoz profile import` is supposed to add the computed digest to that same list. Adding the digest changes the canonical digest, which changes the list, ad infinitum. | Exclude the `adoption` section from the canonical digest; store `activated_digests` in an operator-side registry or sidecar that is *not* part of profile identity. Update import/activate/transition text to match. | `P8_TRUSTED_PROFILES_PLAN.md:115-118`; `P8_TRUSTED_PROFILES_PLAN.md:147-165`; `P8_TRUSTED_PROFILES_PLAN.md:382-388` |
| C-2 | critical | `model_roles.<name>.api_base` and `credential_ref` are arbitrary network/credential vectors. A malicious repository suggestion only needs operator import to redirect model traffic to an attacker-controlled endpoint and to reference any environment secret by name. This directly violates the P8 bar that a malicious repo profile cannot gain tools, network, or credentials. | For P8 v1 either remove `api_base` entirely or require it to match an operator-managed allowlist and treat any change as a new capability epoch. Restrict `credential_ref` env names to a Tamoz-owned prefix or explicit operator allowlist; never allow generic names like `AWS_SECRET_ACCESS_KEY`. Preview must flag these as high-risk. | `P8_TRUSTED_PROFILES_PLAN.md:67-76`; `P8_TRUSTED_PROFILES_PLAN.md:131-133`; `P8_TRUSTED_PROFILES_PLAN.md:258-270`; `PROJECT_HANDOVER_PLAN.md:267-288` |
| H-1 | high | `policy.tool_catalog_version` is described as an opaque string in the schema, but §5.2 says the recomputed `Toolbox.catalog_digest` must match `profile.tool_catalog_digest`. The two field names and concepts are not aligned. | Rename the profile field to `policy.tool_catalog_digest` and require it to equal `Toolbox#catalog_digest` (with the existing `sha256:` prefix). Document how the digest is computed. | `P8_TRUSTED_PROFILES_PLAN.md:107-114`; `P8_TRUSTED_PROFILES_PLAN.md:142-144`; `P8_TRUSTED_PROFILES_PLAN.md:304-317` |
| H-2 | high | Approval defaults are specified in two places: `tools.approval_required_by_default` and `policy.require_human_approval_for`. §5.2 only uses the latter, and neither is included in the catalog digest. | Consolidate to a single source of truth (recommend `tools.approval_required_by_default` because it lives next to `tools.allowed`). Include `allowed_tools` and `approval_required` in the catalog digest so that changes to either create a new cache/policy epoch. | `P8_TRUSTED_PROFILES_PLAN.md:93-104`; `P8_TRUSTED_PROFILES_PLAN.md:138-140`; `P8_TRUSTED_PROFILES_PLAN.md:304-317`; `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:118-127`; `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb:136` |
| H-3 | high | Adding `profile_digest` as a required session record field breaks every existing P6 durable session. There is no migration or compatibility rule. | Decide and document the legacy path: either make `profile_digest` optional with a deterministic default/sentinel for pre-P8 sessions, or ship a `SessionRecords` migration from `RECORD_VERSION` 1 → 2 that synthesizes a legacy profile digest. Do not fail closed on old sessions without an explicit policy. | `P8_TRUSTED_PROFILES_PLAN.md:283-301`; `gems/tamoz-agent/lib/tamoz/agent/session_records.rb:28-39` |
| H-4 | high | The plan says unknown fields are rejected (§4.1), but the `roots` example says "additional named roots may be defined in later schema versions; P8 ignores unknown keys safely." | Choose one rule. Recommendation: strict allowlist for schema v1; any future extension gets its own schema version and migration. Remove the contradictory "ignores unknown keys" wording. | `P8_TRUSTED_PROFILES_PLAN.md:63-65`; `P8_TRUSTED_PROFILES_PLAN.md:235` |
| M-1 | medium | Profile storage defaults to `~/.config/tamoz/profiles` on all platforms. On macOS the conventional operator-owned config location is `~/Library/Application Support/tamoz/profiles`. | Define a platform-aware default: `XDG_CONFIG_HOME/tamoz/profiles` → `~/.config/tamoz/profiles` on Unix; `~/Library/Application Support/tamoz/profiles` on macOS. | `P8_TRUSTED_PROFILES_PLAN.md:172-180`; `P7_INTERACTIVE_CLI_PLAN.md:74` |
| M-2 | medium | `TAMOZ_PROFILE` is described as "a path or profile id" without a disambiguation rule. A value like `acme` could be an id or a relative file, and a relative path could collide with an id. | Specify resolution order within the env var: absolute path → treat as file; matches `^[a-z][a-z0-9_-]{0,63}$` → treat as profile id; otherwise treat as relative path and resolve against cwd. | `P8_TRUSTED_PROFILES_PLAN.md:188-194` |
| M-3 | medium | The session record stores `profile_digest` but not `profile_id`. A digest alone cannot distinguish profiles, and resume under a changed profile cannot verify that the stored session belongs to the intended profile family. | Add `profile_id` to the session record and verify it matches the currently loaded profile during resume/transition. | `P8_TRUSTED_PROFILES_PLAN.md:283-301`; `P8_TRUSTED_PROFILES_PLAN.md:335-340` |
| M-4 | medium | File permissions are "recommended" mode `0600` rather than required. A group-readable profile is authority leakage. | Require profile files to be mode `0600` and reject group/other readable or writable files. Require parent directories to be non-writable by group/other and non-readable by other as well. | `P8_TRUSTED_PROFILES_PLAN.md:197-203` |
| L-1 | low | `canonical_root` and `roots.workspace` are not required to be consistent. A profile could claim one root identity while allowing the workspace to escape it. | Require `roots.workspace` to equal `canonical_root` or be a strict subpath with no symlink escape. | `P8_TRUSTED_PROFILES_PLAN.md:60-65` |

## Single biggest remaining gap

The arbitrary network egress and credential references in `model_roles` are the single biggest
remaining gap. Even after the adoption circularity is fixed, an imported profile can still set
`api_base` to an attacker-controlled HTTPS endpoint and `credential_ref.name` to any environment
variable the operator happens to have set, sending both task content and credentials off-machine.
This is exactly the tools/network/credentials widening the P8 bar says a malicious repository
profile must not be able to achieve. P8 v1 should either eliminate these knobs or gate them behind
an operator-managed allowlist that is itself outside the profile.

## Things the plan gets right and should not be changed

- Authority separation: operator-owned profile vs. repository-suggested evidence only.
- Canonical digest via `Deliberation.canonical` is reproducible and formatting-independent.
- Hard rejection list for YAML tags, aliases, interpolation, shell metacharacters, embedded secrets,
  relative roots, symlink roots, and unknown fields (once the `roots` contradiction is resolved).
- Profile changes create candidate transitions; in-flight sessions keep their checkpointed digest.
- One-shot ephemeral mode remains unchanged; profiles apply only to durable sessions.
- Fuzz matrix covers permissions, symlinks, duplicate keys, unknown fields, root swaps, command
  injection, environment leakage, revoked grants, and resume under changed profiles.
- No credentials embedded in profile files; credential references are limited to `env` in P8.

## Required corrections summary

| ID | Severity | Correction | Applied |
|---|---|---|---|
| C-1 | critical | Exclude `adoption` from canonical digest; store activated digests outside the profile file. | yes |
| C-2 | critical | Restrict or remove `api_base`; restrict `credential_ref` env names to a Tamoz/operator allowlist. | yes |
| H-1 | high | Rename `policy.tool_catalog_version` to `tool_catalog_digest` and define equality with `Toolbox#catalog_digest`. | yes |
| H-2 | high | Consolidate approval defaults to one field and include both `allowed_tools` and `approval_required` in the catalog digest. | yes |
| H-3 | high | Make `profile_digest` optional or define a `SessionRecords` migration for pre-P8 sessions. | yes |
| H-4 | high | Resolve the unknown-fields contradiction; use strict allowlist for schema v1. | yes |
| M-1 | medium | Use platform-appropriate profile directory defaults. | yes |
| M-2 | medium | Define `TAMOZ_PROFILE` path-vs-id disambiguation. | yes |
| M-3 | medium | Store `profile_id` in the session record and verify on resume/transition. | yes |
| M-4 | medium | Require mode `0600` and reject group/other readable profiles. | yes |
| L-1 | low | Require `roots.workspace` to be within `canonical_root`. | yes |

## Pre-implementation checklist

- [ ] `PROJECT_HANDOVER_PLAN.md` §P8 outcome, work packages, product proof, and stop/redesign
criteria are represented accurately.
- [ ] `AGENT_DESIGN.md` §§5–7 and `INVARIANTS.md` clauses 16, 24–27, 35: profile authority is
operator-owned, intersected with application/task/parent limits, and pinned for the epoch.
- [ ] `TAMOZ_AGENT_DESIGN.md` §§3–5: CLI remains a surface; `--profile` binds to the durable
session/checkpoint/cache epochs; tool catalog is the narrow waist.
- [ ] `P7_INTERACTIVE_CLI_PLAN.md`: profile integration does not reintroduce the stream/cancel
issues already flagged in the P7 review, and `--profile` semantics for one-shot vs. durable are
consistent.
- [ ] `SECURITY.md` pre-release boundary is respected: no production systems, no embedded secrets,
no arbitrary network egress.

### Schema and canonical identity review

- [ ] `schema_version` is exactly `1` and newer versions fail closed.
- [ ] `profile_id` regex prevents collisions with filesystem paths and env-var ambiguity.
- [ ] `canonical_root` and `roots.workspace` are absolute, normalized, and symlink-free.
- [ ] Canonical digest algorithm excludes file path, comments, formatting, YAML anchors, and the
`adoption` block.
- [ ] Unknown fields are rejected for schema v1; future extensions bump the schema version.

### Load / validate / normalize review

- [ ] YAML is safe-loaded with an allowlisted tag set and alias count cap.
- [ ] Every string is scanned for interpolation markers; any match is a hard error.
- [ ] `argv` elements are validated per-element; no shell metacharacters.
- [ ] Embedded secrets are rejected by key denylist and heuristic checks.
- [ ] File permissions are enforced: mode `0600`, owned by euid, no group/other write, parent
directories not group/other writable.

### Session/checkpoint epoch binding review

- [ ] `SessionRecords` accepts `profile_id` and `profile_digest` without breaking pre-P8 sessions.
- [ ] `Toolbox` constructor accepts `allowed_tools:` and `approval_required:` and includes both in
`catalog_digest`.
- [ ] `profile.tool_catalog_digest` equals the recomputed `Toolbox#catalog_digest` before model I/O.
- [ ] Model roles resolve through the profile; checkpoints record role + resolved provider/model.
- [ ] Budgets from the profile intersect with runtime/task budgets.
- [ ] Check safety classes are pinned and derived from the profile.

### Transition and resume review

- [ ] Profile edits produce a new canonical digest and a candidate `ProfileTransition`.
- [ ] In-flight executions remain pinned to their checkpointed `profile_digest`.
- [ ] Resume under a changed profile keeps original authority if the stored digest is activated,
otherwise loads read-only.
- [ ] `tamoz profile activate` validates that the target digest is activated before recording a
transition.

### CLI and suggestion review

- [ ] `--profile PATH` bypasses search order and rejects paths inside `.tamoz/`.
- [ ] `TAMOZ_PROFILE` disambiguation is deterministic (absolute path → id regex → relative path).
- [ ] `tamoz profile preview` runs full validation but writes nothing.
- [ ] `tamoz profile import` copies with mode `0600` and updates the operator adoption registry,
not the canonical profile file.
- [ ] `.tamoz/suggested-profile.yaml` is never loaded as authority and never auto-activated.

### Test / fuzz review

- [ ] Fuzz tests include `api_base`/`credential_ref` abuse, profile-id/path ambiguity, and
same-digest cross-profile confusion.
- [ ] Resume-under-changed-profile tests cover both activated and unactivated old digests.
- [ ] Scorecard `profile_trusted_boundary` proves a malicious suggestion cannot widen authority.

### Stop/redesign criteria recheck

- [ ] Profile loading requires no `YAML.unsafe_load`, `eval`, or runtime code execution.
- [ ] A repository-suggested profile cannot become active without explicit operator confirmation.
- [ ] Profile edits never mutate in-flight session authority.
- [ ] Credentials or secret values cannot be embedded in profile files.
- [ ] The canonical digest is deterministic across platforms and YAML libraries.
- [ ] No profile field can introduce shell interpolation or aliases.

## Amendments applied

All critical, high, medium, and low findings above have been reflected in
`docs/P8_TRUSTED_PROFILES_PLAN.md`. Key changes:

- Removed the `adoption` block from the profile schema; activated digests now live in an
  operator-side `adoption.yaml` registry outside the canonical digest.
- Removed `model_roles.<name>.api_base` entirely for P8 v1 and restricted `credential_ref`
  env names to `^TAMOZ_[A-Z0-9_]+$` or an operator-configured allowlist; preview flags these
  as high-risk.
- Renamed `policy.tool_catalog_version` to `policy.tool_catalog_digest`, documented its
  computation, and required equality with `Toolbox#catalog_digest`.
- Consolidated approval defaults to `tools.approval_required` and included both
  `allowed_tools` and `approval_required` in the catalog digest.
- Made `profile_id` and `profile_digest` optional in the `"session"` record with deterministic
  legacy sentinels (`"legacy"` / `"legacy:none"`).
- Enforced strict schema allowlist for v1; removed the contradictory "ignores unknown keys"
  wording.
- Adopted platform-aware profile directories (XDG on Unix, `Application Support` on macOS).
- Specified `TAMOZ_PROFILE` disambiguation: absolute path → file; profile-id regex → id;
  otherwise relative path against cwd.
- Added `profile_id` to the session record and required verification during resume/transition.
- Required profile file mode `0600` and stricter parent-directory permissions.
- Required `roots.workspace` to equal `canonical_root` in P8 v1.

## Final verdict

**Accept.** The amended plan is a viable P8 design checkpoint. The critical and high issues
that blocked implementation have been resolved. Product-code implementation may proceed once
the pre-implementation checklist is satisfied.

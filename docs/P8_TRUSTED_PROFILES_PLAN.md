# P8 — Trusted Project Profiles

## 1. Authoritative inputs, scope, and non-goals

### 1.1 Authority

This plan is derived from:

- `docs/PROJECT_HANDOVER_PLAN.md` §P8 (outcome, work packages P8-D/A/B/C/E, product proof, stop/redesign criteria).
- `docs/design-v0.1/AGENT_DESIGN.md` §§5–7 (approval/authorization, routing/budgets/fallback, prompt-cache epochs).
- `docs/design-v0.1/INVARIANTS.md` clauses 16, 24–27, 35 (cache epoch stability, sensitive data, reviewed plan gates, capability intersection/content-addressing).
- `docs/design-v0.1/TAMOZ_AGENT_DESIGN.md` §§3–5 (turn lifecycle, surfaces, CLI as a surface, tool catalog as narrow waist).
- `docs/P7_INTERACTIVE_CLI_PLAN.md` (session identity, CLI surface, `--resume`, request inbox binding that profiles will extend).
- Existing code:
  - `gems/tamoz-agent/lib/tamoz/agent/session.rb` (session records, graph version, behavior version pinning).
  - `gems/tamoz-agent/lib/tamoz/agent/session_records.rb` (versioned allowlisted records, canonical digests).
  - `gems/tamoz-agent/lib/tamoz/agent/cli.rb` (one-shot CLI, option parsing).
  - `gems/tamoz-agent/lib/tamoz/agent/toolbox.rb` (roots, checks, tool catalog digest, approval defaults).
  - `gems/tamoz-agent/lib/tamoz/agent/deliberation.rb` (tool descriptions, structural review).
- `SECURITY.md` at repo root (pre-release boundary, no production systems).
- `docs/design-v0.1/DECISIONS.md` ADR-020 (sensitive data policy), ADR-022 (reviewed plan gates), ADR-030 (local capability catalog, intersected authority), ADR-033/034 (skill format and tree-digest identity).

### 1.2 Scope

P8 introduces an **operator-owned trusted profile** that lives outside any untrusted repository and pins the authority surface for a Tamoz Agent session. A profile binds:

- canonical project root identity (absolute path or stable identifier);
- named argv checks and their declared safety class;
- symbolic model roles (`:primary`, `:cheap`, `:critic`, etc.) mapped to provider/model identifiers;
- budgets (cost, input/output tokens, wall-clock, steps);
- capability/policy versions (tool catalog digest, graph version, behavior version, profile schema version);
- approval defaults (which tools require explicit approval by default);
- an **operator adoption registry** outside the profile file, mapping profile ids to the digests the operator has explicitly activated for a thread/session.

The profile is **authority**, not suggestion. Repository-provided configuration is **evidence only** and never becomes authority without an explicit operator-confirmed import.

### 1.3 Non-goals

- No new plugin, marketplace, or skill-store trust model.
- No code execution, macro expansion, or template interpolation inside profiles.
- No embedding of credentials, API keys, tokens, or secret values in profiles.
- No custom model API endpoints or generic environment credential references in P8 v1.
- No implicit host timezone or locale-dependent normalization.
- No automatic application of a repository-suggested profile; preview and confirmation are mandatory.
- No mutation of in-flight session authority; profile changes create candidate transitions.
- No backward-incompatible change to one-shot ephemeral mode; profiles apply only to durable sessions.

---

## 2. Profile schema

### 2.1 Format and version

Profiles are **YAML 1.2** documents with an explicit schema version. The only shipped schema version for P8 is `1`.

```yaml
profile:
  schema_version: 1
  profile_id: "myproject-prod"           # stable identifier, <= 64 chars
  profile_version: "2026-08-01-a"        # opaque operator string, <= 128 chars
  canonical_root: "/abs/path/to/project" # absolute, normalized, no symlinks in final component
  description: "Optional human note"

roots:
  workspace: "/abs/path/to/project"
  # P8 v1: roots.workspace must equal canonical_root.
  # Additional named roots are reserved for future schema versions.

model_roles:
  primary:
    provider: "openai"
    model: "gpt-4o"
    credential_ref:
      kind: "env"
      name: "TAMOZ_OPENAI_API_KEY"
  cheap:
    provider: "openai"
    model: "gpt-4o-mini"
  critic:
    provider: "anthropic"
    model: "claude-sonnet-4-20250514"

budgets:
  cost_usd: 5.0
  input_tokens: 500_000
  output_tokens: 100_000
  wall_clock_seconds: 600
  steps: 50

checks:
  answer:
    argv: ["ruby", "test.rb"]
    safety: "unsafe"          # one of: read_only, idempotent, unsafe
  lint:
    argv: ["bundle", "exec", "rubocop"]
    safety: "idempotent"

tools:
  allowed:
    - read_file
    - list_directory
    - search_text
    - apply_patch
    - create_file
    - run_check
  approval_required:
    - apply_patch
    - create_file
    - run_check
  # descriptions are taken from Toolbox defaults; overrides are rejected in schema v1

policy:
  allow_changes: true
  default_check_safety: "unsafe"
  graph_version: "1"            # must match Session::GRAPH_VERSION for compatibility
  behavior_version: "1"         # pinned for the epoch; candidate transitions bump this
  tool_catalog_digest: "sha256:..."  # must equal Toolbox#catalog_digest
```

The `adoption` block is **not** part of the profile file. Activated digests live in the operator-side adoption registry (§3.6).

### 2.2 Field types and constraints

| Path | Type | Constraints |
|------|------|-------------|
| `profile.schema_version` | integer | exactly `1` |
| `profile.profile_id` | string | `^[a-z][a-z0-9_-]{0,63}$` |
| `profile.profile_version` | string | `^[-_.A-Za-z0-9]{1,128}$` |
| `profile.canonical_root` | string | absolute path, <= 4096 bytes, no NUL, valid UTF-8 |
| `profile.description` | string | optional, <= 1024 bytes |
| `roots.workspace` | string | absolute path; in schema v1 it must equal `profile.canonical_root` |
| `model_roles.<name>.provider` | string | known provider or `assume_model_exists` marker |
| `model_roles.<name>.model` | string | non-empty, <= 256 bytes |
| `model_roles.<name>.credential_ref` | hash | optional; `kind` must be `"env"`; `name` must match `^TAMOZ_[A-Z0-9_]+$` or an entry in the operator-configured credential allowlist |
| `budgets.*` | number | non-negative, finite; omitted means no bound |
| `checks.<name>.argv` | array of strings | non-empty, no NUL, no shell metacharacters by construction |
| `checks.<name>.safety` | string | one of `read_only`, `idempotent`, `unsafe` |
| `tools.allowed` | array of strings | subset of known tool names; order is preserved but not load-bearing |
| `tools.approval_required` | array of strings | subset of `tools.allowed` |
| `policy.allow_changes` | boolean | |
| `policy.default_check_safety` | string | one of `read_only`, `idempotent`, `unsafe` |
| `policy.graph_version` | string | must equal `Tamoz::Agent::Session::GRAPH_VERSION` |
| `policy.behavior_version` | string | opaque, <= 64 bytes |
| `policy.tool_catalog_digest` | string | `^sha256:[0-9a-f]{64}$`; must equal recomputed `Toolbox#catalog_digest` |

### 2.3 Canonical digest

The canonical digest identifies the profile independent of file path, comment, formatting, or YAML anchors. It is computed as:

```ruby
Digest::SHA256.hexdigest(
  "tamoz.profile.v1\n" +
  JSON.generate(Deliberation.canonical(profile_hash))
)
```

Where:

- The digest domain prefix is `tamoz.profile.v1\n`.
- `profile_hash` is the parsed YAML as nested Ruby hashes/arrays/strings with all keys as strings.
- `Deliberation.canonical` sorts hash keys recursively and leaves arrays in declared order.
- Only the strict allowlisted schema fields participate; unknown fields are rejected before digest computation.
- The `adoption` block, if present in a legacy file, is stripped before digest computation.
- Result format: `sha256:<64 lowercase hex>`.

The digest is reproducible across platforms and YAML libraries because it operates on the normalized data model, not on serialized YAML bytes.

### 2.4 Tool catalog digest

`policy.tool_catalog_digest` is the stable identity of the capability surface the session is planned against. It must equal the value returned by `Tamoz::Agent::Toolbox#catalog_digest` when the toolbox is constructed from the profile.

The digest is computed as:

```ruby
"sha256:#{Digest::SHA256.hexdigest(JSON.generate([
  allowed_tool_names.sort,
  approval_required_names.sort,
  tool_descriptions.keys.sort,
  tool_descriptions.sort.to_h,
  configured_check_names.sort,
  configured_check_names.sort.map { |name| [name, check_safety(name).to_s] }
]))}"
```

Where:

- `allowed_tool_names` is `tools.allowed` from the profile.
- `approval_required_names` is `tools.approval_required` from the profile.
- `tool_descriptions` is the subset of `Toolbox` defaults for the allowed tools; action descriptions (`apply_patch`, `create_file`, and `run_check` when checks are configured) are included only when `policy.allow_changes` is `true`.
- `configured_check_names` and `check_safety(name)` come from the `checks` section.

Because `allowed_tool_names` and `approval_required_names` participate directly, any change to the tool set or approval policy produces a new catalog digest and therefore a new cache/policy epoch.

---

## 3. Storage and search order

### 3.1 Operator-owned storage

Profiles are operator-owned files outside any project repository. Default locations are platform-aware:

- On Unix: `${XDG_CONFIG_HOME:-~/.config}/tamoz/profiles/`
- On macOS: `~/Library/Application Support/tamoz/profiles/`

On Unix, `$XDG_CONFIG_DIRS/tamoz/profiles/` remains a fallback search dir (rarely used).

Each profile is a single file: `<profile_id>.yaml`. Profiles are not directories and do not execute code on load.

### 3.2 Explicit path

`--profile /path/to/profile.yaml` bypasses the search order entirely. The CLI validates that the path is a regular file, not a symlink, and not inside a repository's `.tamoz/` directory (which is reserved for suggestions).

### 3.3 Search precedence

1. `--profile PATH` flag (highest precedence).
2. `TAMOZ_PROFILE` environment variable:
   - If the value is an absolute path, treat it as a profile file.
   - Else if it matches `^[a-z][a-z0-9_-]{0,63}$`, treat it as a profile id and resolve in the XDG profile directory.
   - Else treat it as a relative path and resolve against the current working directory.
3. `TAMOZ_PROFILE_ID` environment variable naming a file in the XDG profile directory.
4. XDG config directory: `$XDG_CONFIG_HOME/tamoz/profiles/<profile_id>.yaml`.
5. Project suggestion: `<project_root>/.tamoz/suggested-profile.yaml` — **evidence only**, never authority.

A project suggestion is never loaded as the active profile. It is displayed by `tamoz profile preview` and may be imported into the operator's profile directory with `tamoz profile import`.

### 3.4 Permission rules

- Profile files must be owned by the effective user.
- Profile files must be mode `0600`; any group/other read or write bit is rejected.
- Parent directories must not be writable by group or other, and must not be readable by other.
- The operator adoption registry (§3.6) is subject to the same permission rules.
- A profile failing permission checks is rejected with a clear error naming the file and the violated rule.

### 3.5 Migration

Schema migrations are pure data transforms keyed by `(schema_version_from, schema_version_to)`. A profile loader:

1. Reads `schema_version`.
2. Rejects unknown newer versions before inspecting other fields.
3. Applies registered migrations in sequence.
4. Re-runs validation and canonical digest computation on the migrated form.

At P8 there is no earlier shipped schema, so `MIGRATIONS` is empty. Future migrations must not introduce aliases, interpolation, or executable content.

### 3.6 Operator adoption registry

The operator adoption registry records which profile digests the operator has explicitly activated. It lives outside any profile file and outside any project repository.

Default location:

- On Unix: `${XDG_CONFIG_HOME:-~/.config}/tamoz/adoption.yaml`
- On macOS: `~/Library/Application Support/tamoz/adoption.yaml`

Registry format:

```yaml
schema_version: 1
activated:
  myproject-prod:
    - "sha256:..."
```

The registry is loaded when a profile is activated or when a session is resumed. It is updated only by explicit operator actions (`tamoz profile import`, `tamoz profile activate`, or an operator-confirmed preview adoption). The registry is not part of any profile's canonical digest.

---

## 4. Load / validate / normalize algorithm

### 4.1 Rejection list (hard errors)

A profile load fails closed if any of the following are present:

| Prohibited feature | Why | Detection |
|--------------------|-----|-----------|
| `!ruby/object`, `!ruby/regexp`, tags, or custom YAML constructors | No load-time code execution | YAML safe-load with allowlist |
| Anchors/aliases | No indirection that hides identity | YAML parser alias expansion with alias count limit |
| Shell metacharacters in `argv` elements | argv is exact, not shell | Per-element validation; no `$`, `;`, `\|`, `>`, `<`, backticks, `*` |
| String interpolation syntax (`${...}`, `%{...}`, `{{...}}`, ERB `<%` `%>`) | No templating | Scan each string value |
| Embedded secrets (high-entropy strings, `BEGIN PRIVATE KEY`, `sk-...`, `AKIA...`) | Credentials stay in credential providers | Heuristic + explicit secret-reference prefix check |
| `api_key`, `password`, `token`, `secret`, `api_base` keys at any path | Secrets are references, not values; arbitrary endpoints are not allowed in v1 | Schema denylist |
| `model_roles.<name>.credential_ref.name` outside the allowlist | Generic env names leak arbitrary credentials | Regex `^TAMOZ_[A-Z0-9_]+$` or operator allowlist |
| Relative or non-absolute `canonical_root` / `roots.workspace` | Root identity must be unambiguous | Path normalization check |
| `roots.workspace` not equal `canonical_root` in schema v1 | Prevents root escape | Equality check |
| Symlink as final component of canonical root | Symlink swap attacks | `realpath` comparison |
| Implicit host timezone references | Time policy is explicit (invariant 39) | Reject `local`, `system`, `host` timezone strings |
| Unknown top-level or nested fields | Forward compatibility must be explicit | Strict schema allowlist |
| Duplicate keys | Ambiguous authority | YAML parser duplicate-key error |
| `schema_version` newer than supported | Invariant 18 | Version check before field access |

### 4.2 Load algorithm

```text
1. Resolve explicit path or search order; if suggestion, mark as suggestion only.
2. Stat the file: must be regular file, owned by euid, mode exactly 0600, no group/other read or write.
   Verify parent directories are not group/other writable and not other readable.
3. Read bytes with a size cap (128 KiB).
4. Safe-load YAML with no ruby tags, no aliases beyond a small limit, duplicate-key error.
5. Assert top-level is a Hash and contains exactly one `profile` key plus allowlisted sections.
6. Validate schema_version first; reject newer versions.
7. Validate every field type and constraint.
8. Normalize: absolute paths, UTF-8, string keys, sorted hash keys for canonicalization.
   For schema v1, assert roots.workspace == canonical_root.
9. Compute canonical digest over the allowlisted fields (adoption is excluded).
10. If suggestion: stop here; return preview record.
11. If active: consult the operator adoption registry for this profile_id.
    The computed digest must be listed there, or the operator must confirm activation.
12. Return Profile object (immutable, frozen).
```

### 4.3 Secret references

Where credentials are needed (e.g., provider API keys), the profile stores only a **credential reference**:

```yaml
model_roles:
  primary:
    provider: "openai"
    model: "gpt-4o"
    credential_ref:
      kind: "env"
      name: "TAMOZ_OPENAI_API_KEY"
```

Allowed kinds in P8: `env` only. The environment variable name must match `^TAMOZ_[A-Z0-9_]+$` or an explicit entry in an operator-configured allowlist. Generic names such as `OPENAI_API_KEY` or `AWS_SECRET_ACCESS_KEY` are rejected. `tamoz profile preview` flags any `credential_ref` as high-risk.

The profile never contains the credential value; resolution happens at runtime outside checkpoint/state storage.

### 4.4 No aliases / no interpolation

- Aliases are expanded during parse and counted; more than 32 aliases is an error.
- Every string value is scanned for interpolation markers; any match is a hard error.
- Environment variable substitution is not performed in profile values.

---

## 5. Binding profiles to session epochs

### 5.1 Profile identity in session state

When a durable session starts, the profile id and canonical digest are written into the session record:

```ruby
SessionRecords.build(
  "session",
  session_id: thread_id,
  task: task,
  task_digest: Deliberation.canonical_digest(task),
  root: profile.canonical_root,
  graph_version: Session::GRAPH_VERSION,
  behavior_version: profile.policy.behavior_version,
  tool_catalog_digest: profile.policy.tool_catalog_digest,
  profile_id: profile.profile_id,                # P8 addition
  profile_digest: profile.canonical_digest,      # P8 addition
  created_at_ms: Time.now.utc.to_i * 1000
)
```

`profile_id` and `profile_digest` are **optional** in the `"session"` record schema so that pre-P8 durable sessions continue to load. The loader supplies deterministic defaults for missing fields:

- `profile_id` defaults to `"legacy"`.
- `profile_digest` defaults to `"legacy:none"`.

These defaults identify legacy sessions and prevent fail-closed behavior on old records. `SessionRecords.RECORD_VERSION` remains `1`; no migration is required because defaults are filled at load time.

The `profile_digest` is part of the stable request prefix for cache epoch purposes (invariant 16).

### 5.2 Toolbox construction from profile

```ruby
Tamoz::Agent::Toolbox.new(
  root: profile.canonical_root,
  allow_changes: profile.policy.allow_changes,
  checks: profile.checks.transform_values { |c| c.argv },
  check_safeties: profile.checks.transform_values { |c| c.safety.to_sym },
  allowed_tools: profile.tools.allowed,
  approval_required: profile.tools.approval_required
)
```

The toolbox's `catalog_digest` is recomputed from the resolved profile surface using the algorithm in §2.4. It must equal `profile.policy.tool_catalog_digest` or the session fails before model I/O.

### 5.3 Model role resolution

Symbolic roles (`:primary`, `:cheap`, `:critic`) resolve through the profile at session compile time. The checkpoint records both the role and the resolved provider/model identifier (AGENT_DESIGN.md §6). Route budgets are intersected with profile budgets. Custom API endpoints (`api_base`) are not supported in P8 v1.

### 5.4 Profile changes create candidate transitions

A profile edit changes its canonical digest. Tamoz never mutates the authority of an in-flight session. Instead:

1. The operator edits the profile file or imports a new version.
2. A new turn, redirect, or explicit `tamoz profile activate` computes the new digest.
3. The CLI/session creates a `ProfileTransition` candidate record bound to `(thread_id, old_digest, new_digest, reason)`.
4. The transition takes effect only at the next turn boundary, after plan/review acceptance.
5. In-flight executions remain pinned to their checkpointed `profile_digest`.

This mirrors the behavior-version transition mechanism in AGENT_DESIGN.md §12 and invariant 28.

### 5.5 Resume under a changed profile

When resuming a session whose stored `profile_digest` differs from the currently loaded profile:

1. Verify the session record `profile_id`. If it is `"legacy"`, the session predates P8; resuming under an explicit `--profile` is rejected, while resume without a profile proceeds in legacy mode.
2. For P8 sessions, if the stored `profile_id` does not match the currently loaded profile's `profile_id`, the session is loaded read-only for inspection.
3. If the stored `profile_id` matches and the stored digest is listed in the operator adoption registry for that profile id, resume is allowed and the session keeps its original authority.
4. If the stored digest is not activated, the session is loaded read-only for inspection; any mutation requires an explicit transition at a turn boundary.
5. The CLI reports: `Session was created with profile <id> digest X; current profile digest is Y. Run 'tamoz profile activate --thread <id> --digest X' or resume with --read-only.`

`tamoz profile activate` also verifies that the target thread's stored `profile_id` matches the loaded profile before recording a transition.

---

## 6. CLI integration

### 6.1 Global flag

```
tamoz --profile /path/to/profile.yaml ...
tamoz --profile my-profile-id ...
```

The `--profile` flag is valid for `ask`, `resume`, `continue`, `follow-up`, and `redirect` subcommands. It is ignored for one-shot ephemeral mode (which continues to use `--root`, `--check`, and `--allow-changes` directly).

### 6.2 `tamoz profile` subcommands

```
tamoz profile preview [--from-suggestion PATH] [PROFILE_ID]
tamoz profile import --from PATH --id ID [--force]
tamoz profile list
tamoz profile show ID
tamoz profile activate --thread THREAD --digest DIGEST
```

### 6.3 `tamoz profile preview`

- Reads a profile path or suggestion.
- Runs the full load/validate/normalize algorithm.
- Prints a human-readable summary:
  - profile id, version, canonical digest
  - canonical root
  - model roles
  - configured checks
  - allowed tools
  - approval defaults
  - budgets
  - high-risk flags (any `credential_ref`)
- With `--json`, emits a single JSON object with the normalized profile and digest.
- Does not write to the profile store, adoption registry, or session state.

### 6.4 `tamoz profile import`

- Source must be a regular file (often `.tamoz/suggested-profile.yaml`).
- Target is the operator profile directory: `<profile_id>.yaml`.
- Validates the source, computes the digest, asks for operator confirmation unless `--force`.
- Writes the file with mode `0600`.
- Adds the digest to the operator adoption registry under the imported `profile_id`; it does **not** mutate the imported profile file.
- Fails if a profile with the same `profile_id` already exists unless `--force` and the operator confirms.

### 6.5 `tamoz profile activate`

- Verifies the digest is in the operator adoption registry for the profile id (or prompts the operator to add it).
- Verifies the target thread's stored `profile_id` matches the profile id.
- Records a `ProfileTransition` for the specified thread.
- Takes effect at the next turn boundary.

### 6.6 Backward-compatible one-shot mode

`tamoz [options] TASK` without `--profile` and without `--session` remains the ephemeral one-shot path from P7. It does not read profiles, does not write session files, and behaves exactly as before P8.

---

## 7. Repository suggestion handling

### 7.1 `.tamoz/suggested-profile.yaml`

A repository may place a suggested profile at `<project_root>/.tamoz/suggested-profile.yaml`. This file is **evidence only** and has no authority until imported.

Properties:

- It uses the same schema as an active profile.
- Its `profile_id` must not collide with an existing operator profile unless `--force` is used during import.
- Its canonical digest is computed with the same algorithm (adoption block is excluded).
- It is never loaded automatically; `tamoz --profile .tamoz/suggested-profile.yaml` is rejected because the path is inside `.tamoz/`.
- `tamoz profile preview --from-suggestion .tamoz/suggested-profile.yaml` displays it.

### 7.2 Import flow

```text
$ tamoz profile preview --from-suggestion .tamoz/suggested-profile.yaml
Profile: acme-corp-prod (v2026-08-01-a)
Digest:  sha256:abc123...
Root:    /home/user/projects/acme
Checks:  answer (unsafe), lint (idempotent)
Tools:   read_file, list_directory, search_text, apply_patch, create_file, run_check
Budget:  $5.00, 500k input tokens, 100k output tokens
Flagged: credential_ref TAMOZ_OPENAI_API_KEY

This is a repository suggestion. Importing copies it to your profile store and
records the digest in your adoption registry. Do you want to import? [y/N]

$ tamoz profile import --from .tamoz/suggested-profile.yaml --id acme-corp-prod
Imported to ~/.config/tamoz/profiles/acme-corp-prod.yaml
Activated digest recorded in ~/.config/tamoz/adoption.yaml
```

### 7.3 No automatic adoption

A suggested profile is never added to the operator adoption registry without explicit operator action. The CLI cannot be invoked in a mode that silently activates a repository suggestion.

---

## 8. Test / fuzz matrix for P8-E

### 8.1 Unit tests (P8-A validation)

| Test | Input | Expected |
|------|-------|----------|
| `test_valid_profile_loads` | minimal valid profile | Profile object, correct digest |
| `test_unknown_schema_version_rejected` | `schema_version: 99` | hard error before field access |
| `test_duplicate_keys_rejected` | YAML with duplicate key | parse error |
| `test_alias_count_limit` | many YAML aliases | hard error |
| `test_ruby_tag_rejected` | `!ruby/object` | hard error |
| `test_interpolation_rejected` | `${HOME}` in argv | hard error |
| `test_embedded_api_key_rejected` | `api_key: sk-...` | hard error |
| `test_secret_value_heuristic` | high-entropy string | hard error |
| `test_relative_root_rejected` | `canonical_root: ./project` | hard error |
| `test_symlink_root_rejected` | root path is symlink | hard error |
| `test_unknown_field_rejected` | extra top-level key | hard error |
| `test_shell_metacharacter_in_argv` | `argv: ["sh", "-c", "..."]` | hard error |
| `test_implicit_timezone_rejected` | `timezone: local` | hard error |
| `test_bad_permission_rejected` | file mode `0644`, group-writable file, or group-writable dir | hard error |
| `test_canonical_digest_stable` | same profile in two formats | identical digest |
| `test_canonical_digest_distinguishes` | two meaningfully different profiles | different digests |
| `test_adoption_not_in_digest` | profile with/without adoption-like block | identical canonical digest |
| `test_api_base_rejected` | `model_roles.primary.api_base` present | hard error |
| `test_generic_credential_ref_rejected` | `credential_ref.name: OPENAI_API_KEY` | hard error |
| `test_tamoz_credential_ref_allowed` | `credential_ref.name: TAMOZ_OPENAI_API_KEY` | accepted, preview flagged |
| `test_workspace_must_equal_canonical_root` | `roots.workspace` differs from `canonical_root` | hard error |
| `test_tool_catalog_digest_mismatch_rejected` | wrong `policy.tool_catalog_digest` | session fails before model I/O |

### 8.2 Integration tests (P8-B/C binding)

| Test | What it proves |
|------|----------------|
| `test_profile_starts_durable_session` | `--profile` creates session with `profile_id` and `profile_digest` in session record |
| `test_toolbox_matches_profile_tool_catalog_digest` | catalog digest pinned at session start |
| `test_model_role_resolves_through_profile` | checkpoint records role + resolved provider/model |
| `test_budget_intersection_enforced` | profile budget caps runtime budget |
| `test_check_safety_class_pinned` | `unsafe` check pauses on ambiguous crash |
| `test_profile_change_creates_candidate_transition` | in-flight session keeps original authority |
| `test_resume_with_activated_old_digest` | changed profile does not break resume |
| `test_resume_with_unactivated_old_digest_blocks_mutation` | fail closed |
| `test_resume_profile_id_mismatch_blocks_mutation` | session belongs to a different profile family |
| `test_legacy_session_loads_with_sentinels` | pre-P8 session record missing `profile_id`/`profile_digest` resumes with defaults |
| `test_allowed_tools_change_new_epoch` | new `tools.allowed` produces new `tool_catalog_digest` |

### 8.3 Adversarial / fuzz tests (P8-E)

| Vector | Attack | Expected |
|--------|--------|----------|
| Permissions | group-writable profile dir | rejected |
| Symlinks | profile path is symlink to `/etc/passwd` | rejected |
| Duplicate keys | `tools: { allowed: [a], allowed: [b] }` | rejected |
| Unknown fields | `evil: true` | rejected |
| Root swap | change `canonical_root` after operator import | new digest, requires re-adoption |
| Workspace escape | `roots.workspace` outside `canonical_root` | rejected |
| Command injection | `argv: ["bash", "-c", "rm -rf /"]` | rejected by argv metacharacter scan |
| Environment leakage | `${USER}` interpolation | rejected |
| Revoked grants | remove tool from `allowed` after session start | in-flight unaffected; new turn intersects |
| Resume under changed profile | profile edited mid-session | original digest honored if activated |
| Repository suggestion auto-activation | run from repo with `.tamoz/suggested-profile.yaml` without import | suggestion ignored |
| Nested `.tamoz/` path bypass | `--profile .tamoz/suggested-profile.yaml` | rejected |
| Large file | profile > 128 KiB | rejected |
| YAML bomb | exponential alias expansion | rejected by alias limit |
| Encoding | non-UTF-8 bytes | rejected |
| API endpoint hijack | `api_base` in model role | rejected |
| Credential exfiltration | generic `credential_ref.name` | rejected |
| Profile-id/path ambiguity | `TAMOZ_PROFILE=acme` where file `acme.yaml` exists in cwd | resolved as profile id, not file |
| Cross-profile digest confusion | same digest, different `profile_id` | resume checks `profile_id` |

### 8.4 Behavioral scorecard case

Add a scorecard case `profile_trusted_boundary` that:

1. Creates a workspace with a malicious `.tamoz/suggested-profile.yaml` that tries to add a fake tool, disable approval, set an `api_base`, reference a generic credential env var, or embed a secret.
2. Runs `tamoz --profile <imported-trusted-profile> --session ... TASK`.
3. Verifies the task succeeds using only the trusted profile's authority.
4. Verifies the suggested profile was never activated.
5. Verifies no secret value appears in session records or logs.

---

## 9. Stop / redesign criteria and residual risks

### 9.1 Stop / redesign criteria

Stop P8 implementation and escalate for redesign if any of the following appear:

- Profile loading requires `YAML.unsafe_load`, `eval`, `binding`, or any runtime code execution.
- A profile can widen authority beyond the intersection of application, agent, task, and parent limits (invariant 35).
- A repository-suggested profile can become active without explicit operator confirmation.
- Profile edits mutate in-flight session authority instead of creating a candidate transition.
- Resume under a changed profile silently adopts the new profile for an existing session.
- Credentials or secret values can be embedded in profile files without rejection.
- The canonical digest is not deterministic across platforms or YAML libraries.
- A profile can introduce shell interpolation or aliases.
- A profile can reference a generic environment credential name without an operator allowlist.
- A profile can specify a custom model API endpoint (`api_base`) in P8 v1.

### 9.2 Residual risks

| Risk | Mitigation |
|------|------------|
| Operator imports a malicious suggestion without reading preview | Import requires confirmation; `--force` is explicit and logged |
| Profile file is edited by another process after load | Digest is immutable; edits produce a new digest and require re-adoption |
| Credential env var is leaked in logs | Resolution happens at runtime; checkpoints store only `credential_ref`; generic env names are rejected |
| Large profile files | 128 KiB cap and strict schema limit attack surface |
| Schema drift across agents | `schema_version` check and migrations fail closed |
| Adoption registry edited by another process | Registry is mode 0600 and operator-owned; unexpected changes are surfaced during resume |

---

## 10. Definition of done

- [ ] `docs/P8_TRUSTED_PROFILES_PLAN.md` and `docs/reviews/P8_TRUSTED_PROFILES_PLAN_REVIEW.md` exist and are reviewed.
- [ ] Profile schema (§2) is documented with all fields, types, version, canonical digest algorithm, and tool catalog digest algorithm.
- [ ] Storage/search order (§3) is documented: explicit path > env disambiguation > XDG > suggestion, with platform-aware defaults and mode `0600` permission rules.
- [ ] Operator adoption registry (§3.6) is documented as residing outside profile files.
- [ ] Load/validate/normalize algorithm (§4) is documented with explicit rejection list, including `api_base` and generic `credential_ref` rejection.
- [ ] Profile-to-epoch binding (§5) is documented: optional `profile_id`/`profile_digest` in session records, toolbox, model roles, candidate transitions, resume rules.
- [ ] CLI integration (§6) is documented: `--profile`, `tamoz profile preview/import/list/show/activate`, with adoption-registry updates.
- [ ] Repository suggestion handling (§7) is documented: `.tamoz/suggested-profile.yaml` is evidence only and never auto-activated.
- [ ] Test/fuzz matrix (§8) covers P8-E cases, including the corrected fields.
- [ ] Stop/redesign criteria and residual risks (§9) are recorded.
- [ ] No product code is written; this is a design checkpoint only.

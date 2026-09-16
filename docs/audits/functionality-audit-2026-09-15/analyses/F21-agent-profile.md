# F21 `tamoz-agent-profile` — IMPROVE: profile loading is fail-closed, but snapshot integrity and adoption durability are incomplete

| Field | Assessment |
|---|---|
| Functionality | **F21** — trusted profiles, authority/egress/check validation, secure files, adoption and transition registries |
| Surface | `gems/tamoz-agent-profile` with the CLI, session, capability, websearch, runtime-directory, and worker seams that consume it |
| Baseline | `audit-15-09` at `582ae5566de1ae073aea82b69bb2bbf444494d3b` |
| Verdict | **IMPROVE** |
| Counts | **critical 0, major 1, minor 1, info 3** |
| Analyst boundary | Read-only review. No production code, tests, configuration, or existing audit file was edited; no commit was made. |

The profile file path is protected well: it is read through an owner-only,
no-follow descriptor, with bounded bytes, safe YAML, strict schema, and dedicated
validators. The durable authority replay is weaker than those controls claim. A
valid widened snapshot can retain the old `canonical_digest`, pass every validator,
and pass the CLI's equality check because the check compares the retained claim with
itself. The challenge's threat-model qualification is accepted: the reachable writer
is the local operator UID, so this is a **major integrity and evidence defect**, not a
critical privilege gain. A separate minor finding is that concurrent adoption writes
can lose an activation.

## Scope and source map

| Source | Role traced |
|---|---|
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb:32-108,176-203,216-324,401-421,469-575` | Profile identity, schema vocabulary, load/activation, authority snapshot/replay, canonical digest, and validator order |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/fields.rb:9-16,33-72` | Immutable profile value and the durable digest contract |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/document_validator.rb:60-96,138-240` | Roots, roles, credential references, budgets, and bounded values |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/authority_validator.rb:44-131` | Closed local tool names and tool/policy intersections |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/check_spec_validator.rb:43-155` | Check argv, shell/interpreter, path, control-byte, and safety validation |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/egress_validator.rb:38-58,72-207` | Exact-FQDN HTTPS egress, bounds, circuit, and credential-reference validation |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/secure_file.rb:35-161` | Descriptor-based no-follow reads, owner/mode/parent checks, size and UTF-8 checks |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/adoption_registry.rb:9-75` | Operator activation registry and its read/append/write path |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/transition_registry.rb:10-249` | Candidate transitions, identity matching, flocked consume, and registry codec |
| `gems/tamoz-agent-profile/lib/tamoz/agent/profile/locations.rb:58-112` | Profile, adoption, and transition path resolution and environment precedence |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_authority.rb:45-180` | Profile adoption, session digest resolution, pinned replay, and boundary transitions |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_profile_commands.rb:229-344` | Import/activation confirmation and operator-facing profile rendering |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_bindings.rb:34-78,155-172` | Durable profile digest, authority snapshot, roles, budgets, MCP, and egress pins |
| `gems/tamoz-agent-session/lib/tamoz/agent/session.rb:219-297,439-449` | Skill/MCP/egress/behavior guards and the missing profile guard (transferred to F22) |
| `gems/tamoz-agent-capabilities/lib/tamoz/agent/capability_binding.rb:161-169,201-209,302-305` | Local profile tool surface and MCP admission construction |
| `gems/tamoz-agent-capabilities/lib/tamoz/agent/mcp_source_builder.rb:5-27,256-297` | Operator runtime MCP/websearch configuration |
| `gems/tamoz-agent/lib/tamoz/agent/runtime_directory.rb:10-28,61-67,112-162,232-249,301-338` | Operator-only runtime authority, closed source names, and private files |
| `gems/tamoz-agent/lib/tamoz/agent/worker_runtime.rb:690-842,1030-1057,1116-1123,1195-1218` | Worker profile ID/current-file restart path and child digest guard |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/database_file.rb:13-15,105-124` | Session database owner, regular-file, symlink, and permission checks |
| `SECURITY.md:22-31`, `docs/design-v0.1/INVARIANTS.md:82-88,164-172`, `documentation/reference/config.md:136-157`, `docs/P17_WEBSEARCH_PLAN.md:67-95` | Content-addressed authority, MCP/egress pinning, adoption, and test contracts |

Historical `profile-authority-binding.md`, `challenge-profile-authority.md`, and
`mcp-profile-admission.md` were treated as leads. Their current-source claims are
reconciled below; none was accepted without re-reading the live implementation.

## Behavior path

1. `Locations` gives an explicit `--profile`/`TAMOZ_PROFILE` path precedence over a
   profile ID and maps IDs into the operator profile directory. The adoption and
   transition files are siblings under the same configuration root
   (`locations.rb:58-112`).
2. `Profile.load` calls `load_document`, which opens through `SecureFile`, scans and
   safely parses YAML, normalizes keys, removes the suggestion-only `adoption` key,
   validates the strict top-level schema, computes the canonical digest, and builds
   deeply frozen `Fields` (`profile.rb:216-235,401-421,469-575`). Activation is then
   checked in `AdoptionRegistry`.
3. The loader validates the profile root, model role/provider/credential references,
   budgets, checks, local tools, policy/tool contradictions, and optional egress.
   Checks are argv data, not shell strings; egress is exact-FQDN HTTPS data with
   bounded request/response/timeout/redirect/circuit values
   (`document_validator.rb:60-96,170-240`; `authority_validator.rb:44-131`;
   `check_spec_validator.rb:68-155`; `egress_validator.rb:50-207`).
4. Session intake records `profile_id`, `profile_digest`, `profile_authority`, roles,
   budgets, and egress separately (`session_bindings.rb:44-78,155-172`). The authority
   snapshot contains profile identity, canonical root, model roles, checks, local
   tools, policy, and optional egress (`profile.rb:176-203,256-258`).
5. Interactive `ask` and `resume` load the requested operator profile before building
   the toolbox/session. Existing sessions compare profile IDs and digests; a changed
   current digest either consumes an explicit transition at a turn boundary or calls
   `pinned_authority` to replay the stored snapshot
   (`cli_session_commands.rb:29-60`; `cli_authority.rb:94-146`).
6. `pinned_authority` calls `Profile.from_authority`, then compares the returned
   profile's digest with the stored digest (`cli_authority.rb:166-179`). The replay
   validator reconstructs a synthetic document and reruns all section validators, but
   `enforce_authority_shape!` only checks the supplied digest's syntax and returns it
   (`profile.rb:266-304,306-324`).
7. The worker's parent-thread restart path resolves a stored profile ID back to the
   current `profiles/<id>.yaml` and builds a current profile; its child path does have
   a stored-digest check (`worker_runtime.rb:701-706,820-842,1030-1057,1116-1123`).
   This is F25 ownership, not a second F21 finding.

## Six-lens judgments

| Lens | Judgment |
|---|---|
| Correctness | **Improve.** Normal file load and validator ordering are coherent. Replay returns a profile whose authority fields can differ from the content named by its digest; an honest minimal profile also shows why a naïve rehash of the current synthetic defaults would be wrong. |
| Security and authority | **Improve.** Profile authority is local and validators reject unknown tools, unsafe check argv, malformed egress, secret-shaped values, and policy contradictions. The content-addressed replay claim is not enforced. The reachable writer is the operator UID behind private runtime/session files, which limits exploitability. |
| Reliability and durability | **Improve.** Transition consumption is identity-bound and flocked. Adoption activation is an unlocked in-place read-modify-write; two operator processes can lose one activation, and a crash during `File.write` can leave an unreadable registry. |
| Observability and evidence | **Improve with a transferred CLI item.** A replayed widened snapshot keeps the old digest and emits the normal “keeps its pinned authority” path, so no mismatch receipt exists. Separately, the CLI profile renderer omits egress and several policy identity fields; that confirmed renderer defect belongs to F24's CLI rendering seam and is not counted here. |
| Scalability and resource bounds | **Reviewed; info limitation.** Profile bytes, aliases, nesting, argv elements, and egress values are bounded. Adoption and transition history reads have no explicit byte or entry ceiling; no load/soak evidence was run, so this remains an information item. |
| Maintenance and architecture | **Improve.** The validator/storage split and operator-versus-workspace boundary are clear. The snapshot is a projection of a full-document digest without a versioned projection digest, and the snapshot comment promises a stronger invariant than the gate implements. |

## Findings

### F21-SEC-01 — `from_authority` accepts a structurally valid widened snapshot while retaining the old canonical digest

| Field | Content |
|---|---|
| Severity | **major** |
| Confidence | **high** — source trace, current focused tests, and two fresh no-provider/no-network probes |
| Status | **open** |
| Owning seam | `Profile.from_authority#enforce_authority_shape!` in `gems/tamoz-agent-profile`; `CLIAuthority#pinned_authority` is the consuming gate |
| Source evidence | `Profile.load_document` computes the digest over the normalized full document (`profile.rb:401-421,574-575`); `authority_snapshot` carries that digest beside projected authority (`profile.rb:176-203`); `from_authority` reruns validators but receives the digest from `enforce_authority_shape!` (`profile.rb:266-303`); `pinned_authority` compares the replay object's copied digest to the stored claim (`cli_authority.rb:166-179`); session intake stores both fields (`session_bindings.rb:51-61,155-172`). |
| Contract evidence | `SECURITY.md:25-31` and `docs/design-v0.1/INVARIANTS.md:82-88` require local, intersected, content-addressed capability authority. `Profile::Fields` calls the digest a durable identity (`fields.rb:9-16`). `test/agent_profile_transition_test.rb:71-123` covers unchanged and malformed snapshots, but not a coherent valid widening. |

#### Reproduction

The first probe built a real validated profile with a real `Toolbox#catalog_digest`,
copied its snapshot, added `apply_patch` and `create_file`, changed
`policy.allow_changes` to `true`, and updated the policy catalog digest to the
widened toolbox. `Profile.from_authority` returned successfully with the original
digest. Calling the real private CLI `pinned_authority` gate returned the widened
profile with `gate_accepts=>true` and `allow_changes=>true`.

A second probe changed the snapshot's validated egress host and credential-reference
name. It also returned successfully with `digest_equal=>true` while the replay value
contained the new host and reference. Unknown tools, malformed digest syntax, shell
wrappers, and malformed egress shapes remain rejected by the existing validators.

The defect is not simply “the synthetic document has a different digest.” A minimal
honest profile may omit optional `model_roles` and `checks`; the snapshot always adds
empty values, so hashing the current synthetic defaults would reject an unchanged
profile. A fresh probe showed `profile_digest != canonical_digest(build_synthetic_document(snapshot))`
for that valid minimal document. The fix must therefore either preserve every
digest-covered field and optional-key presence, or introduce a separate versioned
digest over the exact pinned authority projection.

#### Impact

- **Correctness:** the replay object can describe a different root, local tool set,
  policy, check, role, or egress declaration than the digest it reports.
- **Security/authority:** a coherent mutation inside the validator vocabulary can
  add action tools, permit changes, or alter egress in the replayed object. The
  current private-file controls make the reachable writer the operator UID; that UID
  could already edit the profile file directly. The defect is therefore a false
  content-addressing and evidence claim, not a new privilege against the stated trust
  boundary.
- **Reliability/durability:** a resumed CLI path is not determined by the stored
  digest and snapshot bytes. It can rebuild a different authority while reporting the
  old epoch, and it has no transition receipt for the changed fields.
- **Observability:** the CLI prints the retained digest and the normal pinned-replay
  message; it has no integrity mismatch to surface.

#### Five whys

1. A widened replay passes because `Profile.from_authority` returns the snapshot's
   caller-supplied `canonical_digest` after validating the other fields.
2. `enforce_authority_shape!` validates only the `sha256:` shape and never compares a
   digest recomputed from the rebuilt authority.
3. `pinned_authority` compares that copied value with the stored `profile_digest`, so
   both sides agree on a false claim.
4. The checkpoint is structurally validated but not integrity-bound to its profile
   digest, despite the repository's content-addressed authority invariant.
5. Tests cover unchanged replay and rejected malformed values, while no test creates
   a structurally valid widened snapshot that retains the old digest.

#### Recommendation

At the existing `Profile.from_authority` seam, add a versioned pinned-authority digest
over the exact snapshot projection and reject a mismatch before constructing
`Fields`. If the existing full-document digest is retained, the snapshot must carry
all digest-covered fields and optional-key presence so the original digest can be
reconstructed; hashing today's synthetic defaults alone is not correct. Add one
regression that widens tools, policy, checks, model roles, root, and egress while
retaining the old claim, and assert both `from_authority` and `pinned_authority` stop
before toolbox/model execution.

### F21-REL-01 — concurrent adoption writes can lose an activated digest

| Field | Content |
|---|---|
| Severity | **minor** |
| Confidence | **high** — source ordering plus a deterministic barrier probe against two real registry instances |
| Status | **open** |
| Owning seam | `Profile::AdoptionRegistry#activate` |
| Source evidence | `activate` reads the current document, appends one digest, and calls `write` (`adoption_registry.rb:39-46`); `write` uses direct `File.write` followed by `chmod` with no lock or atomic replacement (`adoption_registry.rb:50-56`). Worker memoization serializes only threads inside one process (`worker_runtime.rb:816-823`); separate CLI/worker processes share the registry file. |
| Contract evidence | The registry contract says activation is per digest and must preserve prior profiles (`test/agent_profile_adoption_seams_test.rb:118-145`). The tests issue activations serially; no concurrent writer or crash-readable test was found. |

#### Reproduction and impact

Two `AdoptionRegistry` instances were pointed at the same temporary registry. A
barrier held both calls after their initial read of the empty document, then released
both writes. The final valid YAML retained only the second profile's activation; the
first digest was lost. The next `Profile.load` for the first profile therefore sees
an unactivated digest and prompts or fails, even though its activation call returned.
There is no demonstrated authority widening: the effect is operator-record loss and
availability. Direct in-place writes also leave a crash window in which a partial YAML
document is rejected on the next read.

#### Root cause and recommendation

The method performs a shared-file read-modify-write without a shared critical
section. Its per-process caller guard cannot serialize another process, and the write
path has no atomic replacement. Reuse the registry pattern already present in
`TransitionRegistry#with_registry_lock` (`transition_registry.rb:170-198`) for
adoption updates and replace the file atomically under that lock. Add a two-process
preservation case and a crash/readability case; keep the existing fail-closed codec
checks.

### Verified info items

#### F21-SEC-02 — profile load and authority validators fail closed at the trust boundary

`SecureFile` opens with `NOFOLLOW|NONBLOCK`, checks regular-file status, effective-user
ownership, exact `0600` mode, private parents, size, and UTF-8 on the same descriptor
(`secure_file.rb:52-88,111-156`). `load_document` then runs the YAML scanner, safe
parser, strict key/schema checks, and dedicated validators (`profile.rb:401-421,469-575`).
The local tool vocabulary is closed and `allow_changes: false` contradicts action
tools (`authority_validator.rb:44-94`); check argv rejects shell/interpreter wrappers
and workspace-relative programs (`check_spec_validator.rb:68-139,115-128`); egress
is exact-FQDN HTTPS with bounded limits and names-only credential references
(`egress_validator.rb:72-207`). This is a verified design fact, not an additional
defect. Preserve these gates and their negative tests when changing replay.

#### F21-REL-02 — transition consumption is explicit, identity-bound, and flocked

The CLI consumes a transition only at the turn boundary, after matching profile ID,
from digest, and to digest (`cli_authority.rb:94-146`). The registry performs one
flocked check-and-mark read-modify-write, records `consumed_by`/`consumed_at`, and
never returns a consumed entry as a candidate (`transition_registry.rb:113-164,170-198`).
This is why the adoption race above is scoped to `AdoptionRegistry`; it is not a
claim that the transition consume path has the same locking behavior.

#### F21-SCL-01 — profile input is bounded, but registry history has no explicit ceiling

The profile loader bounds total bytes, aliases, nesting, check argv elements, and
egress values (`profile.rb:45-56,97-108`; `check_spec_validator.rb:26,68-95`;
`egress_validator.rb:164-180`). Adoption and transition registries append history
without a byte or entry bound and read it with `File.binread` after a permission-only
check (`adoption_registry.rb:63-75`; `transition_registry.rb:237-248`). The impact of
long-lived profile rotation or transition history was not load-tested, so this
remains an unconfirmed information item rather than a severity finding.

## Cross-row ownership and overlap

| Existing item | Fresh F21 judgment | Ownership/disposition |
|---|---|---|
| `analyses/profile-authority-binding.md` F21-SEC-01 | Replay widening reproduces. The challenge's demotion from critical to major is accepted because profile/session/runtime files are owner-only and the operator UID is already the trust root. | Keep one **F21-SEC-01** at `Profile.from_authority`; do not retain the historical critical grade. |
| `analyses/challenge-profile-authority.md` | Independently re-read and confirmed the missing digest recomputation, the tautological CLI check, and the same-UID reachability qualifier. | Challenge evidence supports `major`, `high`, `open`. |
| Historical `F25-SEC-01` | Worker restart still loads `profiles/<id>.yaml` by ID and injects the current profile into the session; the child path's digest check does not protect the parent. | **Transfer to F25.** Owner is `WorkerRuntime#session_for`/`load_profile`; no F21 duplicate. |
| Historical `F22-SEC-01` | `Session#guard_state!` still checks graph, skill, MCP, egress, and behavior but not profile digest/authority. | **Transfer to F22.** Owner is the session guard; it is a downstream defense, not the profile replay cause. |
| `CF05-SEC-01` MCP admission | A restrictive profile still supplies local tools while `CapabilityBinding#admission_set` appends every configured MCP name (`capability_binding.rb:161-169`); the profile schema has no source-qualified MCP allowlist. | **Transfer to CF05/F24/F25 contract owners.** The contract between independent operator MCP authority and profile session ceiling is unresolved; do not count it in F21. |
| `F10-SEC-03` websearch egress wiring | F21 validates and snapshots `egress`; the websearch adapter's independent runtime-config path is a separate enforcement gap. | **Transfer to F10.** Do not re-count adapter enforcement here. |
| CLI profile rendering | `render_profile` prints identity/checks/model roles/policy but no egress; `confirm_import!` prints only ID, digest, and paths (`cli_profile_commands.rb:258-269,297-344`). A direct render probe with a valid egress section printed no host or credential-reference name. | **Transfer to F24 CLI rendering.** This is a confirmed operator-evidence gap, recorded here for ownership but excluded from F21 counts. |

## Tests, contracts, and probes

All tests used the pinned Ruby 3.3.11 environment and one file per command. No real
provider, network, MCP server, or live websearch endpoint was used.

| Command | Result |
|---|---:|
| `ruby -Itest test/agent_profile_test.rb` | 44 runs, 130 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_profile_schema_seams_test.rb` | 11 runs, 33 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_profile_adoption_seams_test.rb` | 15 runs, 42 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_profile_transition_test.rb` | 11 runs, 72 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_profile_machinery_test.rb` | 24 runs, 232 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/agent_cli_profile_test.rb` | 10 runs, 84 assertions, 0 failures, 0 errors, 0 skips |
| `ruby -Itest test/websearch_egress_test.rb` | 10 runs, 74 assertions, 0 failures, 0 errors, 0 skips |
| **Focused total** | **125 runs, 667 assertions, 0 failures, 0 errors, 0 skips** |

The profile tests cover owner-only/symlink/FIFO/size/encoding behavior, schema and
policy rejection, and normal snapshot/transition paths. Transition machinery covers
flocked concurrent consumption and record/consume races (`test/agent_profile_machinery_test.rb:484-568`). The adoption suite covers malformed/foreign registries, permissions, idempotence, and serial preservation (`test/agent_profile_adoption_seams_test.rb:34-145`), but no concurrent adoption writer or crash injection. No test constructs a valid widened snapshot that retains its old digest, and no CLI render test includes egress.

## Blind spots and deviations

- No full `rake ci`, `rake ci_full`, RuboCop, Enola, load/soak, crash-kill, or live
  network/provider run was performed. The brief permitted focused probes only and
  explicitly prohibited broad suites and style work.
- The replay probes used real profile, validator, toolbox, and CLI authority classes
  with temporary operator-style files, but stopped before a real model or external
  side effect. They prove the authority object and gate result, not a live unsafe
  mutation.
- The operator-only trust boundary was verified in source: runtime directories are
  private (`runtime_directory.rb:61-67,232-249`), profile reads require the current
  UID and `0600` (`secure_file.rb:111-156`), and session databases reject foreign
  ownership, symlinks, non-regular files, and unsafe mode (`database_file.rb:105-124`).
  A multi-user/shared-storage deployment was not evidenced.
- Registry size behavior was not measured. The unbounded-history item remains
  informational until a workload or operational ceiling is established.
- The CLI renderer omission is intentionally transferred to F24; the MCP admission
  behavior is intentionally transferred to CF05/F24/F25; worker restart is
  intentionally transferred to F25; session guard coverage is intentionally
  transferred to F22.

## Report metadata

- Analyst: `/root/audit_f21_profile`
- Date: 2026-09-15
- Repository: `/Users/ghassan/my-projects/tamoz`
- Baseline: `582ae5566de1ae073aea82b69bb2bbf444494d3b`
- Scope rule: only the two F21 report files below and the assigned liveness log were
  writable; no implementation or test fix was attempted.

## Completion record

- **Files changed:** `docs/audits/functionality-audit-2026-09-15/analyses/F21-agent-profile.md`; `docs/audits/functionality-audit-2026-09-15/analyses/F21-agent-profile.json`; `/tmp/tamoz-agents/audit_f21_profile.log`.
- **Exact commands and pass counts:** the seven `ruby -Itest test/...` commands in the table above; 125 runs, 667 assertions, 0 failures, 0 errors, 0 skips.
- **Deviations:** broad CI, lint/style, live provider/network, and load/crash suites were not run under the bounded read-only brief; no bundle installation or commit was performed.
- **Forbidden-file proof:** before report creation `git rev-parse HEAD` was `582ae5566de1ae073aea82b69bb2bbf444494d3b`; after creation the owned-path status contains only the two F21 analysis files, and `git diff --name-only` contains no tracked production, test, configuration, root-audit, or unrelated file. The other untracked audit-package files predate this report and were not edited by this lane.

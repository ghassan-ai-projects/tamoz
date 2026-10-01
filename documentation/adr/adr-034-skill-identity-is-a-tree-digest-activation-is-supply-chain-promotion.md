# ADR-034 — Skill identity is a tree digest; activation is supply-chain promotion

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** F
**Implementation:** Partial — digest identity, staged candidates, and two-person install are built; comparative evaluation before install is not
**Relates to:** [ADR-033](./adr-033-skills-use-the-open-agent-skills-format-and-stay-an-agent-recipe.md), [ADR-023](./adr-023-self-improvement-promotion.md) (generated skills are candidates)

A skill is identified by its source and the digest of its whole directory tree, never by a path or
a version it claims. A new or changed skill is staged, pinned by digest, and installed only by a
named person other than its creator, exactly as staged.

## Context

If a skill is identified by path or self-declared version, a mutable directory can silently swap
its contents between turns or on resume — same name, same version, different instructions. That
makes behavior unreproducible and is the classic supply-chain swap.

## Decision

- Identity = source-qualified name + canonical tree digest of every file. Same-name skills from
  different sources need an explicit binding.
- A session records the digest of each skill it loads; the snapshot it ran with is pinned.
- A drafted or generated skill is staged with a manifest pinning its digest and creator. Install
  requires a named approver who is not the creator, re-compiles, and refuses any change since
  staging or a skill below the authoring bar. A new version replaces the old, which is kept aside.
- Intended, not built: comparative evaluation of the candidate against the installed version before
  install.

## Consequences

Behavior is reproducible from recorded digests, and nobody — model or person — installs their own
skill unseen. **Cost:** installing is a promotion step, not a file copy.

## Invariants

- 41 — skills are content-addressed snapshots.
- 43 — install, update, and self-improvement are staged and evaluated (evaluation half missing).

## Threat model

**Asset:** the instructions the agent follows. **Adversary:** a supply-chain swap or a
self-promoting generator.

| Threat | Mitigation |
|---|---|
| Contents change under the same name | Identity is the tree digest |
| A staged candidate is edited before install | Install refuses any digest change since staging |
| A generator installs its own skill | Creator cannot approve; approver must be named |
| A regression ships in a new version | Not mitigated yet: no comparative evaluation |

**Residual risk:** an approved skill can still be harmful; review, not the digest, judges content.

## Rejected alternatives

| Rejected | Why it lost |
|---|---|
| Watch mutable skill directories and load the newest bytes | Unreproducible; enables silent shadowing and same-version swaps |
| Trust a `version` field in frontmatter *(retrospective, 2026-10-01)* | Self-declared; nothing binds it to content |

## Reopen when

Comparative skill evaluation is built (this becomes Complete), or a signed-skill ecosystem makes
author identity verifiable.

## Verification

Checked 2026-10-01 (source inspection).

| Claim | Enforced by | Evidence | Limit |
|---|---|---|---|
| Installed exactly as staged by a named non-creator | `gems/tamoz-skills/lib/tamoz/skills/candidates.rb` | `test/skills_candidates_test.rb` — `test_the_creator_cannot_approve_and_an_approver_must_be_named`, `test_a_candidate_changed_after_staging_is_refused` | — |
| Only digested files are installed | same | `test/skills_candidates_test.rb` — `test_only_the_digested_files_are_installed` | — |
| Loads record the tree digest | session | `test/skills_reachability_test.rb` — `test_a_model_load_is_recorded_with_its_tree_digest` | — |

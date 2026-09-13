# Audit 058 — `gems/tamoz-agent-profile/lib/tamoz/agent/profile.rb`

Rank 58 · 590 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: ERR, DUP

A well-decomposed loader facade, but a fail-open rescue sits inside a containment refusal, and the
file re-spells a core utility it already consumes.

## Findings

- **[major][ERR]** `verify_outside_root!` rescues `SystemCallError` and returns nil, so an
  ancestor-traversal failure silently passes the "profile must not live inside its own
  canonical_root" refusal — fail-open on a containment boundary. Owning seam: the
  SecureFile/Profile fail-closed boundary. (profile.rb:364-365)
- **[minor][DUP]** `Profile.deep_freeze` re-implements `Tamoz::Core.deep_freeze`, which this same
  file already uses for `Tamoz::Core.digest`/`valid_digest?`. Owning seam: tamoz-core.
  (profile.rb:573-582)

## Resolution — 2026-09-11

- **[major][ERR] fixed.** `verify_outside_root!` no longer rescues `SystemCallError` to
  `nil`. An ancestor-walk failure (permission, missing inode) now raises `ValidationError`,
  so containment fails closed — an inability to prove the profile lives outside its
  canonical_root is a refusal, not a silent admit.
- **[minor][DUP] rejected — not a duplicate.** `Profile.deep_freeze` freezes IN PLACE and
  preserves key types; `Tamoz::Core.deep_freeze` canonicalises — it stringifies Hash keys
  and rebuilds new frozen structures. `Fields#initialize` (fields.rb:40) spreads the result
  with `**Profile.deep_freeze(members)`, which requires symbol keys, so `Core.deep_freeze`
  would raise there. The two are different operations (freeze-preserving vs
  canonicalise-and-freeze), not one concept spelled twice; substituting the core helper
  would be a behavioural regression.

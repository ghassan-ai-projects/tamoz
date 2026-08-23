# tamoz-approval

Approval and permission policy for Tamoz.

This gem owns every "does this action need approval, and under what evidence?"
decision. All policy content lives in digest-pinned YAML under `policy/`; changing
a tool's tier or a rule is a data edit, not a code change.

## Public surface

- `Tamoz::Approval::Request`, `Decision`, `GrantOffer`, `Grant` — immutable values.
- `Tamoz::Approval::Error` and its concrete subclasses — the approval error taxonomy.
- `Tamoz::Approval::Answer.parse` — the one shared answer vocabulary.

Later phases add `Tamoz::Approval::Engine`, `Tamoz::Approval::PolicyDocument`, and
`policy/*.yaml`.

## Dependency direction

`tamoz-approval` depends only on `tamoz-core`. Comms exposes its evidence symbols
as plain data for injection; the gem never imports comms.

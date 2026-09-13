# Audit 048 — `gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_source_audit.rb`

Rank 48 · 628 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: B9, SIZE

A rigorous static auditor, but it bakes operation-specific reviewed-index policy into library code
and interleaves Ripper plumbing with audit policy.

## Findings

- **[major][B9]** `DYNAMIC_INDEX_PREFIXES` hardcodes scenario-specific statement-label prefixes
  ("checkpoint.commit.consume.", "checkpoint.writes.item.") as audit policy in Ruby. Owning seam:
  the boundary registry document, which already carries per-operation statements/access and is
  versioned/digested. (boundary_source_audit.rb:18-21, 356-373)
- **[minor][SIZE]** The 628-line Auditor mixes generic Ripper AST plumbing
  (parse_call/call_arguments/identifier/method_parameters/constant_name) with boundary policy and
  registry comparison, far over the 250-line class signal. Owning seam: a Ripper parsing helper
  layer beneath the audit policy. (boundary_source_audit.rb:397-541)

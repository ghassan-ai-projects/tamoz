# Audit 055 — `gems/tamoz-evals/lib/tamoz/evals/verifier.rb`

Rank 55 · 596 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 1 minor) · Bar fails: DUP, SIZE

The status-decision policy is maintained twice as parallel hand-written case statements that must
stay in sync across evidence and result documents.

## Findings

- **[major][DUP]** `verify_evidence_status!` and `verify_decision_evidence!` re-implement the same
  status→required/forbidden-diagnostics policy (identical
  invalid/infrastructure_error/insufficient_evidence skeletons) for two document kinds. Owning
  seam: one declarative status-invariant table in tamoz-evals shared by both.
  (verifier.rb:344-398, 508-560)
- **[minor][SIZE]** Both status validators are 55 and 53 lines respectively, double the 30-line
  ceiling; the declarative table above dissolves them. (verifier.rb:344-398, 508-560)

## Resolution — 2026-09-11

- **[major][DUP] fixed.** The invalid / infrastructure_error / insufficient_evidence
  skeleton, previously spelled twice (evidence and result documents), now lives once in
  `verify_terminal_diagnostic_status!(status, noun, invalid:, gaps:, infrastructure:,
  unknown:)`. Both `verify_evidence_status!` and `verify_decision_evidence!` handle only
  their genuinely-different passed/failed branches and delegate the terminal statuses.
- **[minor][SIZE] fixed.** With the shared table extracted, both status validators drop from
  55/53 lines to ~20, under the 30-line ceiling.

Messages are unchanged where tests pin substrings ("cannot mix", "must identify"); the
insufficient wording is unified to "unknown outcome or evidence gap" (no test pinned the
prior "unknown claim"/"unknown gate" split).

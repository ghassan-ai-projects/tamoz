# ADRs — the record must match the code

- **A policy-data edit that loosens authority is an ADR change.** On 2026-09-24 `base.yaml` let the
  chat approve every ask; ADR-049 kept saying "residual approval risk is zero" for a week because only
  its Status line changed. Rewrite the rule, the threat model, and every consumer in the same change;
  `test/comms_adr049_consistency_test.rb` now pins ADR-049 to the live `evidence.approve`.
- **Green ADR tooling proves shape, not truth.** `adr:validate` and `adr:verify` passed while ADR-008
  claimed three pools and ADR-047 claimed loss-free journaling. Before citing a test, read what it
  asserts; a test that exists is not a test that proves the claim.
- **Never rewrite accepted intent to match the code.** When code diverges, mark the ADR
  `Implementation: Partial — <gap>` and put the choice on the owner's agenda.

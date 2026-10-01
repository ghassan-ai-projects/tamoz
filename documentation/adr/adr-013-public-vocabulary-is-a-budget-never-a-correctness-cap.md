# ADR-013 — Public vocabulary is a budget, never a correctness cap

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

A new user learns about twelve concepts; operational concepts appear only when their feature is
used. Keeping the surface small never justifies hiding a failure boundary.

## Context

The reference frameworks grew to dozens of user-facing concepts. Tamoz bets on a small learning
surface, but a hard numeric cap would push a real failure mode (a lease, an `:unknown` effect)
out of sight to stay under the number.

## Decision

The introductory surface is about twelve concepts. Operational concepts (leases, effect receipts,
graph versions, request ids) are public but appear only when their feature is used. A new public
concept must name the failure it exposes or the capability it adds; no budget may remove a
concept whose absence would hide a failure.

## Consequences

The getting-started path stays short without lying about failure. **Cost:** this is judgment, not
a test — the public API inventory makes growth visible, but nothing fails when a concept is added.

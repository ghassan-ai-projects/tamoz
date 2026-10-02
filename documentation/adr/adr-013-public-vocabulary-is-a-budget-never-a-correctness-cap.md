# ADR-013 — Public concepts are documented and introduced when needed

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Keep the introductory set of concepts small and explain public terms. There is no numeric
concept limit, and simplicity must never hide a failure or safety boundary.

## Context

Users need clear explanations of the concepts they encounter. Introducing everything at once
makes the framework harder to learn; leaving important failures unexplained makes it harder to
use safely. Counting concepts does not solve either problem.

## Decision

Public concepts are explained in [the concepts guide](../concepts.md): what each means, when users
need it, and where to find examples or further guidance. Adding or changing a public concept
requires updating that guide in the same change.

Introduce the concepts needed to get started first. Explain operational concepts, such as leases
and effect receipts, where their features are used. A new public concept must identify the
capability it adds or the failure it exposes. Keep necessary failure and safety boundaries visible.
There is no fixed number of concepts.

## Consequences

Users have a maintained place to look up terminology and follow it into the relevant feature.
**Cost:** contributors must keep the guide current. The API inventory makes surface changes
visible, but understanding and clarity still require review.

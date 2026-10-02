# ADR-018 — Strict sequence is separate from checkpoint identity

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

Checkpoints are ordered by a backend-assigned integer sequence per `(thread, ns)`; their opaque ids
(UUIDv7, ULID) are never used for order.

## Context

Time-ordered ids are convenient, but their order depends on clocks, and clocks skew and jump. Under
concurrency, two ids minted on different hosts or after a clock step can sort the wrong way.

## Decision

The store assigns each appended checkpoint a strictly increasing integer within its `(thread, ns)`
(gaps allowed). All ordering, "latest", and base checks use that sequence. Correctness never
depends on wall-clock time or lexical id order.

## Consequences

History order is exactly append order. **Cost:** the backend must assign and store the sequence.

# ADR-011 — SQLite is Tamoz Agent's default persistence

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-015](./adr-015-durable-means-synchronous-barrier-commit.md), [ADR-017](./adr-017-one-fenced-writer-per-thread-namespace.md) (the durability and fencing rules this store implements)

One operator's agent keeps all durable state in one local SQLite file in WAL mode with
`synchronous=FULL`; the adapter, not callers, owns transactions, leases, and backup.

## Context

A single-operator durable agent needs crash-safe persistence without running a database server.
Its workload is one writer per thread namespace, short transactions, and two local processes (the
worker and the channel gateway, ADR-042) on one host.

## Decision

`tamoz-sqlite` stores every runtime record in one file. Every connection applies and then verifies
`journal_mode=WAL`, `synchronous=FULL`, and `foreign_keys=ON`, refusing to run otherwise.
Transactions are `IMMEDIATE` with a bounded busy timeout. The adapter owns leases, fencing,
connection lifecycle, and online backup. Supported deployment: one host, a local filesystem, one
operator; processes share the file, never a network mount.

## Consequences

Zero-ops durability that survives process crashes and, with `synchronous=FULL`, power loss on a
filesystem that honors fsync. **Cost:** one writer at a time per file — throughput is bounded by
short transactions; no multi-host deployment; WAL is unsafe on network filesystems.

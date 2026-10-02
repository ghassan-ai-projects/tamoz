# ADR-011 — SQLite is Tamoz Agent's default persistence

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete
**Relates to:** [ADR-015](./adr-015-durable-means-synchronous-barrier-commit.md), [ADR-017](./adr-017-one-fenced-writer-per-thread-namespace.md) (durability and writer fencing)

Tamoz Agent keeps its durable runtime records in a local SQLite database. Multiple processes on
one host share it through `tamoz-sqlite`, which manages transactions, leases and backup.

## Context

A single-operator agent needs to recover committed work after a crash without running a separate
database server. SQLite fits this local deployment when write transactions stay short.

## Decision

Use one SQLite database for durable runtime records, on one host and a local filesystem. This is
a single-operator deployment; never share the database through a network mount. Operator
configuration and trusted profiles remain separate files.

Each connection verifies these settings and refuses to run if they are not in effect:

- `journal_mode=WAL`: record database changes in a write-ahead log.
- `synchronous=FULL`: synchronize the log to storage when a transaction commits.
- `foreign_keys=ON`: enforce relationships between database records.

Transactions use `IMMEDIATE`, acquiring write access at the start, with a bounded wait when the
database is busy. The adapter manages connection lifecycle, leases, writer fencing and online
backup; callers use its APIs rather than managing these directly.

## Consequences

No separate database server is needed. Committed transactions are designed to survive process
crashes and power loss when the filesystem and storage honor synchronization requests.

**Cost:** SQLite permits one writer at a time per database, so write throughput depends on short
transactions. WAL uses additional log and shared-memory files. Operators still need backups,
a restore procedure, sufficient disk space and correct file permissions. This deployment does
not support sharing the database across hosts.

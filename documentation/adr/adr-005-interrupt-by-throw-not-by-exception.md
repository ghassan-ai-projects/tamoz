# ADR-005 — Interrupt by `throw`, not by exception

**Status:** Accepted 2026-07-30
**Date:** 2026-07-30
**Tier:** C
**Implementation:** Complete

A node signals a pause through worker-local `throw`/`catch`, keeping pause requests separate from
execution errors.

## Context

A node may need to pause execution to obtain input or approval. Application code routinely rescues
exceptions to recover from errors. If a pause were represented as an exception, an error handler
could consume it and let execution continue instead of pausing.

## Decision

When no resume value is available for an interrupt call, `InterruptCursor#call` throws
`:tamoz_interrupt` with the interrupt descriptor. When a resume value is available, it returns
that value and execution continues.

`Tamoz::Pool::Base#execute` installs the matching `catch` around each task in the worker executing
it and returns `Tamoz::TaskResult::Interrupted` to the graph executor. The signal stays within
that task's thread; it is not a cross-thread pause mechanism.

## Consequences

Ordinary `rescue StandardError` handlers do not intercept the pause signal. Node code can still
intercept it with its own matching `catch`; this mechanism separates control flow from errors,
it does not isolate untrusted node code.

**Cost:** each pool implementation must catch interrupts inside the executing task, and a pause
cannot directly interrupt work running in another thread.

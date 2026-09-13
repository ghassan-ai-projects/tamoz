# Audit 063 — `gems/tamoz-evals-runner/lib/tamoz/evals/harness/sqlite_convergence_probe.rb`

Rank 63 · 557 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 3 minor) · Bar fails: FX

The probe verifies real convergence properties but does so by reaching into another gem's private
methods and constants — a coupling guaranteed to break on edit.

## Findings

- **[major][FX]** The probe drives Tamoz::SQLite::Adapter through
  `__send__(:read/:acquire_lease/:validate_lease/:release_lease)` and
  `const_get(:Wire/:LeaseRecord)` — another gem's privates, owned by no public seam. Owning seam:
  an eval-support API on Tamoz::SQLite::Adapter. (sqlite_convergence_probe.rb:177-244)
- **[minor][FX]** `ledger_count` byte-compares the literal CREATE TABLE DDL string to validate
  schema — broken by any formatting edit. Owning seam: adapter/schema introspection.
  (sqlite_convergence_probe.rb:396-416)
- **[minor][ERR]** The initialize compatibility check calls `probes.keys` before any guard, so a
  malformed `inputs[:probes]` escapes as bare NoMethodError/KeyError instead of the file's own
  ExecutionError convention. (sqlite_convergence_probe.rb:21-24)
- **[minor][DEAD]** `send("probe_#{...}")` metaprogrammed dispatch over seven known methods.
  Owning seam: an explicit case map in `execute_probe`. (sqlite_convergence_probe.rb:164-174)

## Resolution — 2026-09-11

- **[minor][DEAD] fixed.** `send("probe_#{probe.tr("-", "_")}", ...)` is replaced by an explicit
  `PROBE_METHODS` table (all eight probe names → method symbols) declared on the class.
  `execute_probe` fetches from it and raises this file's `ExecutionError` naming the unknown
  probe, instead of a convention-built name reaching a missing method.
- **[minor][ERR] fixed.** `initialize` now guards `@inputs[:probes]` (a Hash whose every value
  is a known `PROBE_METHODS` key) BEFORE the compatibility check reads `probes.keys`. A
  malformed or absent `:probes` — or a probe name this class does not implement — now fails at
  construction with `ExecutionError`, matching the file's convention, rather than escaping as a
  bare `NoMethodError`/`KeyError`.
- **[major][FX] deferred — needs a deliberate API decision, not a quick fix.** The probe drives
  `Tamoz::SQLite::Adapter` privates (`__send__(:read/:acquire_lease/:validate_lease/
  :release_lease)`, `const_get(:Wire/:LeaseRecord)`). The named remedy, "an eval-support API on
  Tamoz::SQLite::Adapter", would widen a core persistence adapter's PUBLIC surface — exposing
  lease acquire/validate/release, which are private precisely because they are internal to the
  adapter's transaction machinery — for the benefit of one eval harness, and anything public
  there becomes usable by production callers. That trade deserves an explicit decision rather
  than being made as a side effect of this audit. The coupling is real and will break on
  adapter edits, but it is confined to this one eval-only file. Recommended follow-up: a
  narrow, explicitly-named support seam (not a general widening) decided on its own merits.
- **[minor][FX] deferred.** `ledger_count`'s byte-comparison of the literal CREATE TABLE DDL
  has the same owner (adapter/schema introspection) and should be resolved with the above.

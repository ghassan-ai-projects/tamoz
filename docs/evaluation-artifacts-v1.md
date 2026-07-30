# Evaluation artifacts v1

Tamoz evaluation cases, evidence, and results are immutable, UTF-8 JSON artifacts. Version
1 uses a Tamoz-specific canonical form; it does not claim RFC 8785 compatibility.

## Canonical form and digest

Before encoding, object keys and string values are converted to UTF-8 and normalized to
Unicode NFC. Object keys are ordered lexicographically, arrays retain their declared order,
and JSON is emitted without insignificant whitespace. Integers, booleans, strings, arrays,
objects, and null are supported. Floating-point values and duplicate or
normalization-colliding keys are rejected.

`content_digest` is excluded from the artifact body. The SHA-256 input is the following byte
sequence, where `NUL` is one zero byte:

```text
"tamoz-evals" NUL domain NUL "v1" NUL canonical_json
```

The domain is `eval.case`, `eval.evidence`, or `eval.result`. The stored value is
`sha256:<lowercase-hex>`. This algorithm is identified by `digest_version: 1`; changing it
requires a new digest version.

## Evidence references

Every local reference contains an id, kind, relative path, SHA-256 digest, exact byte size,
and classification. Paths must remain beneath the artifact directory after symlink
resolution. A single reference is limited to 16 MiB and all references in one artifact are
limited to 64 MiB. The verifier reads each regular file through one handle, checks that it
did not change during verification, then compares its declared size and digest.

These are verification bounds, not permission to expose sensitive content. Reports should
prefer classified, redacted evidence and opaque identifiers.

## Evidence envelopes

An evidence artifact binds the exact case version/digest, scenario version/digest, subject
revision and tree, producer, environment, timing, claims, measurements, and classified
references. Its bounded process list represents single-child, crash, and multi-process race
treatments. Process records use public participant and command labels plus stream byte
counts/digests; raw arguments, environment variables, paths, operating-system process ids,
and output are never embedded in the envelope.

Every envelope declares its classification, capture level, and sanitization status. Public
evidence that does not declare sanitization is invalid; the declaration is bound to the
producer and artifact digests and must be backed by the fixed runner's sanitizer tests.

Process output can be retained as a classified reference after separate sanitization.
Truncation is explicit and must agree with produced/captured byte counts. Exit and signal
status are mutually exclusive, harness timeout/termination must agree, and a passing
envelope requires every claim to pass with no invalid, missing, or infrastructure
diagnostic.

The shared subprocess primitive uses an exact caller-supplied environment, an absolute
executable, argument-vector execution without a shell, process groups, monotonic deadlines,
bounded simultaneous stdout/stderr capture, and bounded `TERM` then `KILL` cleanup. It is an
execution primitive, not an operating-system security boundary; runners that claim network
denial must add and self-test an OS sandbox.

## Result provenance

A result identifies its subject, suite, case, environment, evaluator, gate, component
versions and digests, snapshot digests, fixture references, seed, repetition, and retained
attempt records. The decision authority must match the provenance gate exactly.

Invalid evidence, missing evidence, and infrastructure errors are separate fields and
cannot be mixed into a passing or ordinary failing result. An infrastructure result must
name its classified error. An insufficient result must retain an unknown hard gate or an
explicit evidence gap.

## CLI decisions

When multiple artifacts are verified, the process returns the highest-precedence outcome:
invalid evidence, infrastructure failure, insufficient evidence, gate failure, then
success. Exit codes are 2, 3, 4, 1, and 0 respectively; usage errors return 64.

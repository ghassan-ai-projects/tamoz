# Working slice 1 deep review

Review target: the reviewed read-only Tamoz Agent CLI introduced after M3.1 Phase 2F.

## Decision

Accepted for its declared scope: a single-turn, read-only product walking skeleton. It is
not accepted as M4, as a durable agent, or as Tamoz v0.1.

The slice proves the product lifecycle with a real provider boundary while avoiding the
blocked RubyLLM native tool loop. It is small enough to replace rather than preserve if the
next vertical slice exposes a better seam.

## Findings and corrections

| Severity | Finding | Correction |
|---|---|---|
| High | An accepted plan could contain wrong or unknown tool arguments; failure happened only during execution. | Added per-tool schema and path validation to structural review and reused the same validation at execution. |
| High | Coercing JSON values with `String()` let booleans, arrays, or objects masquerade as protocol strings. | Plan, review, verification, tool names, paths, and queries now enforce their exact JSON types. |
| High | A model could request an absolute path even though execution later rejected it. | Structural review now rejects absolute and null-containing paths before semantic acceptance. |
| High | Symlinks could be used to attempt a read outside the declared workspace. | Every execution path uses `realpath`, checks the canonical root prefix, and has an escape regression test. Search does not traverse symlinks. |
| Medium | The planning prompt exposed the host's absolute workspace path to the provider without needing it. | The prompt now exposes only `.` and an explicit relative-path policy. |
| Medium | Requiring `tamoz/agent` eagerly loaded RubyLLM and all provider code. | RubyLLM is loaded only when `RubyLLMModel` is instantiated; core and graph isolation remain unchanged. |
| Medium | Tool outputs could grow the verification request without a run-level bound. | Individual file/search bounds and a 96 KiB aggregate observation bound stop the run before another model call. |
| Medium | The old application manifest and public API inventory still described an inert skeleton. | Activated the read-only CLI manifest and recorded the new public surface. |

## System review

### Correctness

- Event-order tests prove `plan_accepted` precedes `tool_started`.
- Structural rejection, semantic rejection, malformed protocol, and exhausted review attempts
  all prove zero action before acceptance.
- Final verification receives the accepted plan and exact tool observations.
- The CLI returns a distinct non-success status when the verifier says completion is not
  satisfied.

### Security

- The built-in capability set is read-only and fixed.
- There is no shell, network-fetch, write, edit, delete, MCP, skill, or callback capability.
- Canonical path checks prevent absolute paths, traversal, and symlink escape.
- Directory, search, file, task, plan-attempt, and observation limits are explicit.
- Provider errors are reduced to a Tamoz protocol error. Credentials are never placed in
  prompts, events, or results.

Residual: a user-selected workspace root authorizes reading ordinary text files under that
root, including sensitive files. A deny policy for secret-shaped paths belongs in the next
capability-policy slice.

### Reliability

The runtime is fail-closed on malformed planning/review/verification JSON and tool errors.
It is deliberately not durable: a process crash can repeat model calls and the single turn
must restart. No claim to replay safety is made.

### Observability

The runtime emits typed lifecycle events for task start, plan drafts, both review layers,
plan acceptance, tool start/completion, and final completion. The CLI renders concise human
output or newline-delimited JSON. Tool output is present in JSON events, so callers must
treat the stream as task data, not public telemetry.

### Scalability and cost

All work is sequential and bounded. One accepted run uses at least three model calls: plan,
review, and verification. Revisions add plan/review calls up to the attempt bound. This is
appropriate for the first correctness proof; routing cheaper review models and caching are
later product decisions driven by evaluation evidence.

### Maintainability

Provider behavior is behind one `generate(stage:, system:, prompt:)` protocol, allowing
deterministic tests and replacement adapters. The toolbox owns both validation and execution,
preventing schema drift. The runtime remains independent of RubyLLM classes.

## Evidence

- deterministic runtime tests cover successful order, structural revision, semantic
  revision, malformed types, rejection without action, and symlink escape;
- toolbox tests cover listing, ignored-directory search, file bounds, binary rejection, and
  argument validation;
- adapter tests exercise isolated RubyLLM configuration and a complete generation call
  without network access;
- CLI tests cover terminal commands and usage failures;
- packaging asserts that the `tamoz` executable ships in the gem;
- the repository-wide design, syntax, and test gate is required before commit.

## Next slice gate

Do not add broad optimization machinery. The next useful capability is a narrow write/edit
flow with explicit approval, atomic filesystem effects, SQLite effect journaling, and one
end-to-end task evaluation. Shell execution should remain out of scope until write recovery
is proven.

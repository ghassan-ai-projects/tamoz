# Security policy

Tamoz is pre-release software and must not yet control production systems or
physical devices.

Report vulnerabilities privately through GitHub security advisories for the
`ghassan-ai-projects/tamoz` repository. Do not include credentials, private
prompts, user content, or production traces in a public issue.

## Current boundary

Tamoz is an operational agent: it reads a workspace, proposes reviewed plans,
and — when explicitly enabled — edits files and runs configured checks. The
boundary below is what constrains it.

- **Nothing acts without a reviewed plan** bound to its canonical digest, and no
  file changes without an approval granted for that exact diff. A mutation
  between approval and dispatch is refused, not reconciled.
- **Authority is local, intersected, and content-addressed.** A capability's
  effective authority is the intersection of the current profile, agent and task
  limits. Descriptions, annotations, manifests, skill bodies, memory records and
  model output can request capability; none can grant it or lower a risk class.
- **The capability registry is a closed set** of four built-in sources, sealed
  at session construction. A forged or caller-supplied source is refused at
  construction, not at dispatch.
- **No arbitrary shell.** `run_check` runs one operator-configured argv by name;
  the model chooses which check runs and can never alter its program, arguments
  or environment. Credential-shaped variables are stripped from every check
  subprocess.
- **Secrets are explicit.** Secret values are rejected from checkpoints, streams
  and instrumentation rather than scrubbed by key name. An MCP child's captured
  stderr redacts resolved credential values by value.
- **Tamoz makes no exactly-once claim for arbitrary external effects.**
  Replay-safe effects require idempotency, atomic participation, or
  reconciliation. An unsafe effect with an unknown outcome stops and waits for a
  human decision; it is never retried blindly.
- **Physical-world control is advisory and simulated.** The only effector is the
  simulator. Replay and shadow scopes hold no effector credentials by
  construction. Connecting a real actuator requires an explicit owner decision
  and a separate safety review.
- **Runtime gems never depend on `tamoz-evals`**, so evaluation code cannot
  reach a production path.

## Known gaps

[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md) lists what is not implemented, what
carries weaker evidence, and which parts of the system have never had an
independent adversarial review. It is bound to the measured release audit, so it
cannot fall silently behind the product.

# Security policy

Tamoz is pre-release software and must not yet control production systems or physical
devices.

Report vulnerabilities privately through GitHub security advisories for the
`ghassan-ai-projects/tamoz` repository. Do not include credentials, private prompts, user
content, or production traces in a public issue.

## Current boundary

- M0 contains package and evaluation foundations, not an operational agent.
- Evaluation reports protect raw content by default.
- Runtime gems must never depend on `tamoz-evals`.
- Tamoz makes no exactly-once claim for arbitrary external effects.
- Physical-world control remains advisory until the streaming, policy, simulator, and
  independent safety gates in the design are implemented and passed.

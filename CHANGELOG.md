# Changelog

All notable changes to Tamoz are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from its public release line onward.

## [Unreleased]

### Added

- `tamoz-approval`: approval policy as digest-pinned YAML data (`policy/base.yaml`
  plus `implement`/`plan`/`review`/`auto`/`unattended` profiles) with a deny-first
  engine, scoped expiring grants, a durable decision log, and mid-session mode
  switches that survive restarts.

### Changed

- One approval engine everywhere: durable sessions and the one-shot runtime ask
  the same policy owner; a denial is a structured result the turn continues from.
- Approval prompts carry the evidence level from the journaled engine Decision;
  the hardcoded comms constant policy is gone.

### Removed

- `ApprovalDeniedError`, the tools-gem approval plumbing, and every
  approve-all bypass flag; unattended behavior is a policy profile, not a flag.

## [0.1.0.alpha.1] - 2026-08-13

### Added

- Initial public documentation set under `documentation/`: overview, architecture,
  design, the ADR index, guides, operations, reference, and limitations.
- Governance files: `CODE_OF_CONDUCT.md`, `SUPPORT.md`, and this changelog.
- The 13-gem monorepo layout: `tamoz-core`, `tamoz-graph`, `tamoz-sqlite`,
  `tamoz-tools`, `tamoz-agent`, `tamoz-evals`, `tamoz-mcp`, `tamoz-scheduler`,
  `tamoz-stream`, `tamoz-comms`, `tamoz-telegram`, `tamoz-observability`, and
  `tamoz-otel`.
- The reviewed change loop: plan, review, approval, verified effect, bounded repair.
- Durable sessions that resume from their last committed barrier after a crash.
- Trusted profiles that pin project authority outside the repository.
- The sealed capability host with four closed-world built-in sources.
- Three-layer memory (experience, knowledge, wisdom) with deletion and provenance safety.
- Bounded self-healing on a durable circuit (DR-2).
- Durable scheduling (`at` and `interval`) in `tamoz-scheduler`.
- The supervised episode worker with gRPC contracts in `tamoz-stream`.
- Telegram as an operator channel with evidence-gated approval (ADR-049).

> Pre-release. The public contract is still evolving; see
> [documentation/limitations.md](documentation/limitations.md).

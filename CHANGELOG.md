# Changelog

All notable changes to Tamoz are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from its public release line onward.

## [Unreleased]

### Added

- `tamoz telegram setup|start`: pair a Telegram bot and run it from two
  commands. `setup` authenticates the token, pairs the first private sender the
  operator confirms, and writes the channel and workspace profile; `start`
  verifies the token and picks the first provider that answers, then runs the
  gateway and worker together. Chat turns run on the tool-calling work loop.
- `tamoz code`: the coding harness. A durable tool-calling work loop in
  `tamoz-agent-session`, with two new gems: `tamoz-context-engine` (frozen
  request header, append-only surface, spill, pruner, compaction, token meter,
  trace) and `tamoz-harness` (prompt pack, persona, project guidance via
  `--guidance`, living plan, loop budgets, finish contract). Context windows are
  recorded per route in `gems/tamoz-agent-kernel/data/model_windows.yml`, and
  worker/chat serve work turns with `--work-routing`.

- `tamoz-approval`: approval policy as digest-pinned YAML data (`policy/base.yaml`
  plus `implement`/`plan`/`review`/`auto`/`unattended` profiles) with a deny-first
  engine, scoped expiring grants, a durable decision log, and mid-session mode
  switches that survive restarts.

### Changed

- One approval engine everywhere: durable sessions and the one-shot runtime ask
  the same policy owner; a denial is a structured result the turn continues from.
- Approval prompts carry the evidence level from the journaled engine Decision;
  the hardcoded comms constant policy is gone.

### Fixed

- A model reply containing a non-ASCII character no longer crashes a turn:
  `Tamoz::Core::JCS` now returns UTF-8 strings from a binary HTTP body.
- Interactive approval previews print once, not twice. A failed session names
  the error class next to the node.
- A long work turn ends on its loop budget with a handoff, instead of on the
  graph's 200-step limit.
- A reply cut off at the token limit continues the turn instead of failing it.
- `tamoz telegram setup` repairs a runtime directory that already has a channel
  but no `profiles/` directory (it adopts the unpinned channel and writes the
  profile) instead of dying with a raw backtrace; a missing or refused token and
  a missing, refused or out-of-credit key are each one named line.
- The gateway and worker can open a fresh runtime database at the same time
  without one dying on the migration lock.
- Approving from the paired Telegram chat now resumes the paused turn. A channel
  decision records a decision but no queued resume request, so a parked thread
  used to leave the worker's work list for good: the press was accepted and
  nothing happened. The worker re-admits a parked thread while a decision is
  waiting for it, and the resumed turn delivers its outcome to the chat.
- `/cancel` in Telegram stops the turn in progress. It used to queue behind the
  running turn, so the full answer arrived and only then "Stopped.". The worker
  now watches for the chat's cancel while a turn runs: an in-flight model call is
  abandoned, no further tool runs, and the chat gets "Stopped." instead of the
  answer. A bare `/cancel` stops everything open in the conversation.
- Telegram replies render Markdown (`code`, **bold**, code blocks, links) as
  formatting instead of raw symbols; the transport sends escaped HTML that
  always parses.
- A Telegram approval prompt shows what will change (the file and its content,
  the diff, or the command) instead of "I want to create a file". Its buttons are
  cleared once answered, the tap shows a toast, and a late tap on an old prompt
  says it is no longer waiting.
- `/status` answers in one plain sentence (working, queued, waiting for your
  approval, stopping, or nothing running); `--diagnostic` keeps the detail.

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

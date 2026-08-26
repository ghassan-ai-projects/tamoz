# Compatibility matrix

This page states what Tamoz supports today and what it deliberately does not. The matrix is version-pinned: every row is true for `0.1.0.alpha.1` (pre-release) and is checked by CI and by the release audit. Honesty markers are a deliberate pattern — see [../limitations.md](../limitations.md) for the full counterpart list.

Current version: `0.1.0.alpha.1` (pre-release).

## What is supported

| Surface | Support | Details |
|---|---|---|
| Ruby | `>= 3.3, < 5.0` | The repository pins `3.3.11` in `.ruby-version`; CI runs 3.3, 3.4, and 4.0 on Ubuntu |
| SQLite | via the `sqlite3` gem `~> 2.9` | Single-file database, no server to run; WAL enabled, one fenced writer |
| Model providers | any provider RubyLLM supports | Model access uses RubyLLM with the provider's own API key, e.g. `OPENAI_API_KEY` + `TAMOZ_MODEL=gpt-5-mini`; provider selected with `TAMOZ_PROVIDER` |
| Locales | UTF-8 or `LC_ALL=C` | Both are gated in CI; the same assertion totals must pass under both |
| Platforms | macOS and Linux | Development toolchain and CI; no Docker image yet (see below) |
| MCP | official Ruby SDK (`mcp` `~> 1.1`) | Governed client/host: immutable server admission, pinned catalogs, invocation supervision |
| gRPC | `grpc` `~> 1.83`, `google-protobuf` `~> 4.35` | The supervised EpisodeWorker for the stream runtime |
| Telegram | Telegram Bot API, stdlib-only HTTP | `tamoz-telegram` implements the `Tamoz::Comms::Transport` seam |
| JSON | canonical digesting | RFC-8785 canonical JSON serialization (JCS) with a stored digest epoch |
| Database migrations | 13 checksummed, monotonic | Schema `CURRENT_VERSION = 13`; ordinals 1–13 are consumed monotonically and never reused |

### Gems and their runtime dependencies

All twenty-five gems are at `0.1.0.alpha.1`, MIT-licensed, and declare `required_ruby_version >= 3.3 < 5.0`. Each installs and runs with only its declared dependencies, proven per gem by an isolated install into its own `GEM_HOME`.

| Gem | Depends on |
|---|---|
| `tamoz-core` | stdlib, Zeitwerk |
| `tamoz-cancellation` | `tamoz-core` |
| `tamoz-concurrency` | `tamoz-cancellation`, `tamoz-core` |
| `tamoz-graph` | `tamoz-core` |
| `tamoz-scheduler` | `tamoz-core` |
| `tamoz-stream` | `tamoz-core`, `grpc`, `google-protobuf` |
| `tamoz-sqlite` | `tamoz-graph`, `tamoz-scheduler`, `tamoz-stream`, `sqlite3` |
| `tamoz-tools` | `tamoz-core` |
| `tamoz-mcp` | `tamoz-core`, `tamoz-cancellation`, `mcp` |
| `tamoz-mcp-websearch` | `tamoz-mcp`, `tamoz-core` |
| `tamoz-comms` | `tamoz-core` |
| `tamoz-approval` | `tamoz-core` |
| `tamoz-observability` | `tamoz-core` |
| `tamoz-otel` | `tamoz-observability` |
| `tamoz-telegram` | `tamoz-comms` |
| `tamoz-agent` | `tamoz-tools`, `tamoz-graph`, `tamoz-sqlite`, `tamoz-comms`, `tamoz-observability`, `ruby_llm` `~> 1.16.0` |
| `tamoz-agent-kernel` | `tamoz-core`, `tamoz-tools` |
| `tamoz-agent-capabilities` | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-mcp`, `tamoz-tools` |
| `tamoz-agent-memory` | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-sqlite`, `tamoz-tools` |
| `tamoz-agent-healing` | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-tools` |
| `tamoz-agent-profile` | `tamoz-agent-kernel`, `tamoz-core`, `tamoz-sqlite` |
| `tamoz-agent-session` | `tamoz-agent-kernel`, `tamoz-agent-capabilities`, `tamoz-agent-memory`, `tamoz-agent-profile`, `tamoz-agent-healing`, `tamoz-cancellation`, `tamoz-core`, `tamoz-tools` |
| `tamoz-agent-improvement` | `tamoz-agent-kernel`, `tamoz-agent-memory` |
| `tamoz-agent-cli` | `tamoz-agent` |
| `tamoz-evals` | `tamoz-core`, `tamoz-agent`, `tamoz-sqlite`, `tamoz-mcp`, `tamoz-mcp-websearch`, `tamoz-graph`, `tamoz-scheduler` (development/release only); **no production gem may depend on it** (enforced by test) |

## Not yet supported

These are gaps, not claims. Where a gap is measured by the release audit, keep reading [../limitations.md](../limitations.md) — this list stays consistent with it.

- **No Windows guarantee.** CI covers macOS/Linux; Windows has no documented support.
- **No Docker packaging.** The framework ships as gems and a CLI. There is no container image yet; supervision is done by whatever supervises a foreground process (launchd, systemd, runit).
- **No managed cloud.** Single operator, many sessions — no hosted multi-tenant platform, no auth server, no billing.
- **Cron and civil-time scheduling are partial (invariant 39).** `tamoz-scheduler` ships `at` (one-shot at a UTC instant) and `interval` (every N seconds). Cron expressions and IANA timezones are not implemented — "every weekday at 09:00 local time" cannot be expressed.
- **Skill installation and update are partial (invariant 43).** Skills compile from operator-configured directories into immutable, content-addressed snapshots; there is no install/update/self-improvement pipeline. You place skill trees on disk yourself, out of band.
- **No exactly-once for arbitrary external effects.** Replay-safe effects require idempotency, atomic participation, or reconciliation; ambiguous work stops as `:unknown`.
- **No real physical actuation.** The only effector is the simulator; connecting a real actuator requires an explicit owner decision and a separate safety review.
- **No streaming-input engine.** The P14 engine was retired by `MIGRATION_13`; Tamoz runs one sealed, digest-verified Situation snapshot per episode. The continuous plane belongs to the stream runtime.
- **Observability is partial.** The closed signal catalog, journal, and metrics/trace projection ship; the authoritative SQLite read-only telemetry adapter and durable model-usage persistence do not yet.

## Versioning policy

All gems share `0.1.0.alpha.1` and move together while pre-1.0. Compatibility semantics are defined by the 61-clause invariant contract ([invariants.md](../architecture/invariants.md)), whose clauses may change only through an ADR with a migration and new conformance tests. The public API may move before 1.0.

## Next reads

- [../getting-started/install.md](../getting-started/install.md) — requirements and installation
- [../limitations.md](../limitations.md) — the measured counterpart to this matrix
- [../architecture/gems.md](../architecture/gems.md) — the gem map in depth
- [../architecture/invariants.md](../architecture/invariants.md) — the executable contract behind the matrix

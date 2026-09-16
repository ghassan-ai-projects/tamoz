# Standalone scanner pass — functionality and support inventories

Date: 2026-09-15
Checkout: `audit-15-09`, code baseline `582ae55`
Mode: read-only inventory and static signal scan. Scanner leads are routing
signals only; an analyst report and challenge remain the finding gates.

## Commands and results

The scanner used the repository's live paths rather than the analyst session:

```text
find gems/*/lib -type f -name '*.rb'     -> 27 gem library directories
find gems -path '*/exe/*' -type f        -> 3 installed executables
find bin -maxdepth 1 -type f             -> 6 repository launchers
find script -type f                      -> 45 support scripts
find scripts -type f                     -> 1 support launcher
test -f Rakefile                          -> present
```

The row-parity check found 27 live `gems/*/lib` directories and one JSON analyst
record for every F01–F27 ID. The six static signal scans returned these files:

| Signal | Files matched |
|---|---:|
| `model.generate` | 19 |
| `Open3.capture*` | 2 |
| `system(` | 4 |
| `IO.popen` | 0 |
| `Net::HTTP` | 6 |
| `TCPSocket` | 0 |
| `Thread.new` | 13 |
| `Queue.new` | 2 |
| `sleep(` | 10 |

The exact search was `rg -l` over `gems`, `apps`, `bin`, `script`, and `scripts`
for each signal with Ruby and shell files included. The matches were compared
with the relevant analyst source maps; no signal was promoted without source
confirmation.

## Gem scanner coverage

Every row below has a live library path, a file-count inventory, a matching JSON
analyst record, and the signal scan above. This is the standalone scanner pass;
it does not claim the row's analyst, challenge, synthesis, or closure gate.

| ID | Library surface | Ruby files | Scanner result |
|---|---|---:|---|
| F01 | `gems/tamoz-core/lib` | 32 | complete |
| F02 | `gems/tamoz-cancellation/lib` | 6 | complete |
| F03 | `gems/tamoz-concurrency/lib` | 6 | complete |
| F04 | `gems/tamoz-graph/lib` | 47 | complete |
| F05 | `gems/tamoz-scheduler/lib` | 7 | complete |
| F06 | `gems/tamoz-stream/lib` | 24 | complete |
| F07 | `gems/tamoz-sqlite/lib` | 70 | complete |
| F08 | `gems/tamoz-tools/lib` | 24 | complete |
| F09 | `gems/tamoz-mcp/lib` | 13 | complete |
| F10 | `gems/tamoz-mcp-websearch/lib` | 5 | complete |
| F11 | `gems/tamoz-comms/lib` | 25 | complete |
| F12 | `gems/tamoz-comms-gateway/lib` | 13 | complete |
| F13 | `gems/tamoz-approval/lib` | 13 | complete |
| F14 | `gems/tamoz-telegram/lib` | 5 | complete |
| F15 | `gems/tamoz-observability/lib` | 20 | complete |
| F16 | `gems/tamoz-otel/lib` | 5 | complete |
| F17 | `gems/tamoz-agent-kernel/lib` | 28 | complete |
| F18 | `gems/tamoz-agent-capabilities/lib` | 9 | complete |
| F19 | `gems/tamoz-agent-memory/lib` | 15 | complete |
| F20 | `gems/tamoz-agent-healing/lib` | 26 | complete |
| F21 | `gems/tamoz-agent-profile/lib` | 17 | complete |
| F22 | `gems/tamoz-agent-session/lib` | 22 | complete |
| F23 | `gems/tamoz-agent-improvement/lib` | 12 | complete |
| F24 | `gems/tamoz-agent-cli/lib` | 16 | complete |
| F25 | `gems/tamoz-agent/lib` | 15 | complete |
| F26 | `gems/tamoz-evals/lib` | 14 | complete |
| F27 | `gems/tamoz-evals-runner/lib` | 44 | complete |

## Other scanner surfaces

| Surface | Inventory | Scanner result |
|---|---:|---|
| A01 `apps/tamoz-agent` | 2 files | complete |
| E01–E03 installed gem executables | 3 files | complete |
| E04–E09 `bin/` launchers | 6 files | complete |
| S01 `script/` | 45 files | complete inventory; item analyst reviews pending |
| S02 `scripts/start-tamoz-comms.sh` | 1 file | complete |
| R01 `Rakefile` | 1 file | complete |

The support-script count is based on `find script -type f` and is intentionally
separate from the aggregate S01 analyst record. The scanner has not substituted
for the required one-row-per-script analyst pass.

## Cross-flow boundary

No standalone scanner pass is claimed for CF01–CF13. Existing logs
`/tmp/tamoz-agents/scan_durable_session.log` and
`/tmp/tamoz-agents/scan_authority_tools.log` targeted CF02, CF04, CF05, and
CF06 only; they are partial leads. End-to-end flow tracing, boundary ownership,
and independent challenge remain required under `BAR.md`.

No production code, tests, configuration, generated artifact, or unrelated
documentation was changed by this scanner pass.

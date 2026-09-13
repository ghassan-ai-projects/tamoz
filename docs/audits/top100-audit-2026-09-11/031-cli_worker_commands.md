# Audit 031 — `gems/tamoz-agent-cli/lib/tamoz/agent/cli_worker_commands.rb`

Rank 31 · 725 lines · 2026-09-11 · **Verdict: IMPROVE** (1 major, 2 minor) · Bar fails: ERR

Command/render separation is mostly clean, but a swallowed session-view error silently drops
paused approvals from the exact list `approve` consults.

## Findings

- **[major][ERR]** `session_view` rescues `StandardError` to nil; `paused_approvals` then silently
  omits the thread, so `cmd_approve` answers "no paused approval" for an approval that exists —
  fail-silent on an authority surface. Owning seam: a typed degraded view from the
  session/worker-runtime layer, or `paused_approvals` surfaces the failure the way
  `session_status` does. (cli_worker_commands.rb:539-543, 504-524, 358-363)
- **[minor][PLACE]** `doctor_redaction_report` encodes the redaction self-check policy (emit known
  secret, judge journal bytes, expected producer outcomes) inside the CLI; observability owns the
  probe, the CLI renders it. (cli_worker_commands.rb:160-188)
- **[minor][ERR]** `observability_status` rescue fabricates a zeroed inventory (`files=0 bytes=0
  drops=0`) for a broken journal — telemetry lies to the operator instead of reporting
  unavailable. (cli_worker_commands.rb:696-706)

## Resolution — 2026-09-11

- **[major][ERR] fixed.** `paused_approvals` no longer silently drops a thread whose live
  view could not be computed (`session_view` → nil). It emits an `approval_state:
  "unavailable"` row via `unavailable_approval`, and `cmd_approve` reports that degraded
  state and refuses, instead of answering the misleading "no paused approval" for an
  approval that may exist. In the healthy path (view present) behaviour is unchanged.
- **[minor][ERR] fixed.** `observability_status` no longer fabricates zeroed counters for a
  broken journal; the rescue reports `files/bytes/drops = "unavailable"` plus the error, so
  a broken journal reads as broken, not as "no drops".
- **[minor][PLACE] deferred with reason.** Relocating `doctor_redaction_report` into
  tamoz-observability is the right home, but it is a diagnostic-only probe and the honest
  relocation expands the gem's *governed* public API (docs/public-api.json + the pinned
  public_api_test hash + the requirements manifest). Per project state the
  requirements-manifest regeneration is currently blocked, so growing the public surface for
  a minor placement nicety is not worth the governance risk now. Left in the CLI.

Note: this branch fails `test_a_turn_queued_behind_a_paused_turn_waits_then_runs_after_approval`
and two unattended-policy approval cases on pristine HEAD already (session_view raises in
those scenarios). This change converts an uncaught error into an honest "unavailable"
refusal for the same tests; it introduces no new failures (unattended-policy went 6→2
problems, worker unchanged in count).

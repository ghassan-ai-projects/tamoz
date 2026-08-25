# Phase 3 implementation review

Status: **implemented and reviewed** — three waves plus the final repair pass,
all committed on `feature/openclaw-chat-study-refresh`: typed control
semantics `f3bddc7` (3a), both-surface exposure `d1944d0` (3b), canonical
cross-surface composition test, and the final correctness repairs. All
evidence is fixture/scripted-transport plumbing evidence; no live Telegram or
real-provider behavior is claimed, and usefulness remains the benchmark's
claim.

## Scope delivered

- **Typed context controls** (`gems/tamoz-agent-session/.../session_context_controls.rb`):
  `/new /reset /compact /usage /context /think /verbose` are typed Session
  operations with defined effects on generation addressing (`.gN`),
  model-visible composition, budget accounting, and audit — one validated
  `context_control` record per mutation under the fenced writer.
  `/compact` summarizes through the journaled model seam keyed on the
  deterministic control request id (replay hits the recorded receipt) and
  pins the verbose input behind verified sha256 with provenance
  `conversation_untrusted`; `/usage`//`context` are read-only projections of
  durable facts that report absent token rollups as absent, never invented;
  unknown preference values fail closed before any write; real fence
  conflicts answer a distinct busy line instead of the stateless guidance.
- **Both-surface exposure** — all thirteen commands dispatch identically in
  meaning through one shared bounded-line renderer (`ControlReply`); post-
  `/new` controls address the successor generation automatically; a model-less
  boot never constructs a provider (controls answer unavailable), and a
  failing controls builder cannot kill the serve loop.
- **Event identity for reconnection** — CLI JSON envelopes carry full
  StreamPart identity (Phase 1c) with monotonic sequences; the reconnectable
  view resumes STATE from durable rows without re-running a turn.
  Stream-resume-from-last-sequence does not exist in the product and is
  recorded as a named limitation, not faked.
- **Operational read model** — durable facts surfaced for diagnosis: queue
  position/age, cancellation timeline stamps, delivery axes, request counts by
  operation, observation-byte ceilings — bounded, redacted (sizes only),
  derived from rows; nothing invents state when a writer is unavailable
  (invariant 12). Lease-loss/recovery and dropped-projection events remain
  worker telemetry (pre-existing seams), recorded here rather than duplicated.
- **Canonical cross-surface composition** —
  `test/canonical_cross_surface_composition_test.rb` composes ONE continuous
  story over real stores, fake transport, deterministic scripted models:
  two pairing-isolated conversations, waiting→cancel clean stop with the
  reference-addressed timeline, kill-crash→fresh-worker recovery, duplicate
  update replay, a tightened deployed limit refusing an oversized update end
  to end, and one ambiguous send that stays unknown — references never cross
  conversations, history holds only confirmed deliveries of its own thread,
  CLI and Telegram projections agree in meaning.

## Review loop

Final-round lens reviews (correctness/invariants, security/trust,
tests/evidence honesty) covered phases 2–3 at `d1944d0`; verdicts NEEDS FIXES
×3. Security findings (poison-argument surface freeze — HIGH, command size-
gate bypass, pairing expiry unenforced on the authority path, artifact
ceiling, compact replay identity, challenge accumulation, controls-builder
crash safety) were repaired first; correctness findings (terminal wording
keyed to the reservation axis instead of the task axis — HIGH, duplicate
disposition ignored for control commands, offset stream mismatch,
CheckpointConflictError conflation) were repaired last; the tests/evidence
findings drove the renderer reclassification, black-box worker observation
tests, and this manifest's disclosures.

## Verification

Focused suites at final state (one file per command):
`test/session_context_controls_test.rb` 11/105 ·
`test/context_control_exposure_test.rb` 6/58 ·
`test/canonical_cross_surface_composition_test.rb` 1/106 ·
`test/reconnection_resume_protocol_test.rb` 1/18 ·
`test/comms_command_parity_test.rb` 10/167 · `test/agent_cli_test.rb`
33/753 · `test/benchmark_comms_b0_test.rb` 13/150 ·
`test/comms_seams_test.rb` 9/31.

Slow-lane receipts: both locales of `rake ci_full` green at the closure
revision after the schema-oracle pin reconciliation to version 21 and the
MIG-21 requirements-manifest row (machine-regenerated artifacts) — recorded
in the Phase 2 manifest's verification addendum, which binds both phases.

Enola: baseline sha256 e017dfa… pinned pre-work; closure check reported only
ordinary call-edge additions.

## Bar status

| Bar item | Status | Evidence or blocker |
| --- | --- | --- |
| Typed controls with defined effects | Complete | per-control semantics tests incl. fail-closed values, read-only inertness (digest-verified), audit exactly-once within a mutation; duplicate disposition guard covers redelivery |
| Identical-in-meaning exposure | Complete | both-surfaces document equality tests; shared renderer; KNOWN==handled sweep over 13 names |
| Event identity + reconnection | Complete (resume-from-sequence named limitation) | envelope round-trip + monotonic sequences; reconnect view store-only resumption proven after every writer gone |
| Operational read model | Complete for comms-scoped facts | usage/context projections from durable rows; absent data reported absent |
| Canonical composition | Complete | single continuous story test, deterministic across seeds/processes |

## Provenance and blind spots

- Source revisions: `f3bddc7`, `d1944d0`, canonical-test and final-repair
  commits through `ff062da`; trees clean at each commit (the phase-2 straggler
  disclosure applies to revisions earlier than `94d73e2` only).
- All evidence fixture-based: scripted transports/models, SQLite, no live
  Telegram, no real provider, no usefulness claim.
- Blind spots: `/compact` as the very first operation on a virgin thread fails
  typed (the journaled summarize needs an existing execution) — reachable only
  when a user compacts before any other control or turn; ControlBase bootstrap
  execution ids remain random (only the compact model-call keying is
  deterministic); no failed-settle leg exists inside the C8 benchmark drive
  (crash machinery settles before /cancel can arrive — wording falsified at
  store+gateway level instead); lease-loss/dropped-projection operational
  events remain worker telemetry seams, not new read-model surfaces.

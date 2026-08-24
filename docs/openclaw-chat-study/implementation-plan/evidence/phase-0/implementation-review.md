# Phase 0 implementation review

Status: **implemented and reviewed** — boundary correctness landed in commit
`da8853a`, then every finding from a three-lens read-only review was repaired in
commit `189b38a`. All evidence below is fixture/scripted-transport plumbing
evidence; no live Telegram or real-provider behavior is claimed.

## Scope delivered

- **Fenced send boundary** — `mark_delivery_send_started` is a CAS on
  `(status='claimed', claim_owner, claim_fence)` and `mark_delivery` re-checks
  owner+fence (`gems/tamoz-sqlite/.../comms_outbox.rb`); the drainer sends only
  after `:marked` and writes results through the same fence. A drainer that lost
  its claim performs no external send and records nothing.
- **Complete Telegram inbound identity** — `Telegram::Normalizer` digests
  meaningful per-kind fields under domain `tamoz.telegram.update.v2`; equal
  digest → one existing request, different digest under the same update_id →
  durable `:integrity_conflict` with nothing enqueued, quarantined beside the
  original. MIGRATION_20 later bounded amplification: additional conflicting
  digests update the anchor row's `conflict_count`/`last_conflict_digest`
  instead of minting rows.
- **Distinct Telegram ID fields** — update_id / message_id / quoted message id /
  callback_message_id are carried, bounded numerics, and reply targeting prefers
  platform message ids over update_id (callback replies target the callback
  message id).
- **Admission-boundary limit enforcement** — `max_open_requests`,
  `max_inbound_bytes`, and outbox capacity are read from the deployed surface
  row inside the admission transaction and refuse with typed reasons before any
  insert; the declared `max_response_bytes` reaches the production client via
  `comms_client_factory`.
- **Typed drainer failure states** — authentication refusal fails the row with
  `reason_code: authentication_refused`, stops the drain loop, spares pending
  rows, exits non-zero with the cause on stderr; storage failures stop all loops,
  name the exception class on stderr, exit 1; ambiguous outcomes stay `unknown`,
  never retried.

## Review loop

1. Plan critique and wave decomposition: orchestrator.
2. Implementation (two sequential waves for store/gateway ownership): background
   implementation agents.
3. Three read-only reviews pinned to committed `da8853a`: correctness/invariants
   lens, security/trust-boundary lens, test-quality/evidence lens.
4. Repairs consolidating all three verdicts (NEEDS FIXES ×2, GAPS NOTED):
   commit `189b38a` — declared response cap wired + send ambiguity mapping;
   typed ok/error_code classification; conflict-counter bounding; single
   admission authority (deployed descriptor); supervision test; real-normalizer
   composition test; membership-digest sensitivity, exact limit boundaries,
   slot release; last fixture ID equatings removed.

## Verification

Fast lane at the repair commit: `rake ci` green (wall clock ≈26 s, budget 60 s).

Focused suites (one file per command, exact counts at their landing commits):
`test/delivery_drainer_test.rb` 10 runs / 50 assertions ·
`test/comms_gateway_test.rb` 20 / 92 · `test/sqlite_comms_store_test.rb`
31 / 151 · `test/tamoz_telegram_transport_test.rb` 19 / 42 ·
`test/comms_cli_test.rb` 12 / 60 · `test/comms_admission_test.rb` 15 / 51 ·
`test/comms_seams_test.rb` 9 / 31 · NEW
`test/comms_serve_supervision_test.rb` (storage failure names the class on
stderr and exits non-zero) · NEW real-normalizer composition test inside
`comms_gateway_test.rb`.

Slow-lane receipts: after the repair commits and a root-caused fix to a
pre-existing flaky equality assertion (wall-clock stamps inside the
whole-document decision digest), the full gate passes clean under both locales
at branch revision `c052258`: `LC_ALL=C rake ci_full` → exit 0 and
`LC_ALL=en_US.UTF-8 rake ci_full` → exit 0 (fast lane and slow lane both
green in each). Earlier full-gate attempts had exposed pre-existing
branch-carried debt — stale script load paths, a schema oracle pinned at
version 17 against migrator 20, missing requirements-manifest rows — all
repaired with machine-regenerated artifacts before these receipts were taken.

Enola: baseline pinned before implementation work
(`enola baseline pin`, snapshot sha256 e017dfa…); `enola check` at the
receipt revision reports no structural regression — only ordinary added
call edges inside the corrected test file.

## Bar status

| Bar item | Status | Evidence or blocker |
| --- | --- | --- |
| Fenced send boundary | Complete | takeover-during-sleep, stale-send and stale-mark tests in `delivery_drainer_test.rb`; revert-sensitive (ungating the send-start marker fails both) |
| Complete Telegram inbound identity | Complete | normalizer unit suite + real-normalizer→admit composition test; anchor-row conflict counter bounds amplification (MIGRATION_20) |
| Distinct Telegram ID fields | Complete | four-ID distinctness + reply-targeting tests; no fixture equates message_id with update_id anymore |
| Admission-boundary limit enforcement | Complete | exact-boundary admit/refuse tests, slot-release-after-completion test, deployed-descriptor single authority; factory carries the declared cap |
| Typed drainer failure states | Complete | auth-refusal stop/spare/fenced-fail tests; storage-supervision test proves stderr naming + exit 1; oversized send response maps to honest `unknown` |

## Provenance and blind spots

- Source revisions: implementation `da8853a`, repairs `189b38a`; trees were
  clean at each commit.
- All evidence is fixture/scripted-transport based. No live Telegram API call,
  no real provider, no real model was involved. Nothing here shows agent
  reasoning or usefulness — that is the benchmark protocol's job.
- Environment limits: the sandbox forbids binding localhost sockets for the
  Telegram fixture server (EPERM), so transport-level fixtures assert through
  scripted transports instead.
- Known blind spots accepted at repair time: polls whose response exceeds the
  cap stay fatal-loud by design (an unreadable batch cannot be confirmed, so
  quiet retry would be an invisible wedge) — documented, tested as typed loud
  failure; net/http buffers the whole header block before streaming, so a
  huge-header response bypasses the body cap (origin is pinned api.telegram.org
  over TLS); the digest covers text-bearing fields, not captions/media — widen
  it when media enters scope; two concurrent drainers can flip an in-flight row
  to operator-resolved `unknown` (never a double-send).

# Phase 1 implementation review

Status: **implemented** — three waves plus an owner-directed addition, all
committed on `feature/openclaw-chat-study-refresh`: store truth `ca82d20`
(1a), CLI JSON identity `676d977` (1c), command parity `f322345` (1b), pairing
first contact `0fff1f8`. All evidence is fixture/scripted-transport plumbing
evidence; no live Telegram or real-provider behavior is claimed.

## Scope delivered

- **Closed external vocabulary** (`gems/tamoz-comms/.../lifecycle.rb`): frozen
  task/delivery state sets, typed reason-code registry, fail-closed
  translation (unknown inputs raise), short non-authorizing request references.
- **Truthful status store**: `conversation_status` carries reference, queue
  position/age from durable rows only (absent when idle); caller-bound
  `request_status` resolves one ref per conversation with typed
  unknown/ambiguous outcomes; only confirmed (`succeeded`) terminal deliveries
  enter `conversation_history` (invariant 11 enforced in SQL).
- **Conversation generations**: MIGRATION_19 adds a durable generation counter;
  `/new` bumps it and subsequent admissions route to the new thread while old
  requests stay resolvable by reference.
- **Command parity** (`handle_command`): every KNOWN name has a real handler —
  `/new`, `/status [r<ref>]` (external vocabulary, terminal reason, queue
  facts), `/redirect r<ref> <task>` (typed refusals incl. already-finished),
  `/whoami` (zero authority), `/cancel`, `/help`; acceptances carry the
  derived reference (`Core::RequestIdentity` is the single derivation, shared
  byte-for-byte with the store).
- **CLI JSON contract**: every JSON-mode stream line is a stable NDJSON
  envelope (schema 1) carrying type/data and both state axes; StreamPart
  identity (run_id/task_id/sequence/emitted_at) survives instead of being
  flattened away.
- **Pairing first contact** (owner-directed addition beyond the study list):
  an unbound correspondent on a pairing surface gets one bounded reply naming
  a relayable code instead of silence; repeat contacts reuse the same pending
  challenge within a gateway lifetime; `/start <code>` verifies as pure
  feedback; binding activation stays exclusively operator-side
  (`approve_pairing`).

## Review loop

Orchestrator wave decomposition with single-writer file ownership; each wave
implemented by a background agent against front-loaded briefs; gates between
waves. The three-lens review cycle ran for Phase 0 and its repairs feed this
phase's store/gateway code; a fresh multi-lens review round is scheduled at
branch closure.

## Verification

Focused suites at their landing commits (one file per command):
`test/comms_lifecycle_test.rb` 9/68 · `test/sqlite_comms_store_test.rb`
31/151 · `test/comms_admission_test.rb` 15/51 · `test/comms_gateway_test.rb`
20/92 · `test/comms_command_parity_test.rb` 10/131 ·
`test/comms_pairing_first_contact_test.rb` 7/39 · `test/agent_cli_test.rb`
33/753 · `test/delivery_drainer_test.rb` 10/50 · `test/comms_seams_test.rb`
9/31 · `test/agent_session_operations_test.rb` 6/36 — all green, with the
unmodified-suite requirement held for drainer/seams across waves.

Fast lane `rake ci` green after each committed wave. One flaky equality
assertion elsewhere in the tree (`StreamEpisodeSkillsMemoryTest#test_gate1`,
wall-clock stamps inside the whole-document decision digest; reproduced 1/8
solo, 3/10 under load) was root-caused and corrected — validity stamps now
compare apart with digest self-verification added, strictly stronger than the
old assertion; not caused by, nor touching, chat-study surfaces.

Slow-lane receipts: `LC_ALL=C rake ci_full` → exit 0 and
`LC_ALL=en_US.UTF-8 rake ci_full` → exit 0 at branch revision `c052258`
(fast and slow lanes green in both locales). Earlier full-gate attempts
exposed pre-existing branch-carried debt (stale script load paths, schema
oracle pinned at 17, missing manifest rows MIG-18..20) — repaired with
machine-regenerated artifacts before these receipts were taken.

Enola: baseline pinned before implementation (snapshot sha256 e017dfa…);
`enola check` at the receipt revision reports no structural regression — only
ordinary added call edges inside the corrected test file.

## Bar status

| Bar item | Status | Evidence or blocker |
| --- | --- | --- |
| Closed vocabulary + typed reasons | Complete | lifecycle suite incl. fail-closed raises and closed-set output pins |
| Reference-addressed truthful status | Complete | store suite: queue-aware fields absent-when-idle, unknown/malformed/cross-conversation/ambiguous ref cases |
| History = confirmed deliveries only | Complete | succeeded-only SQL pin incl. same-row flip scenario |
| Command parity + truthful rendering | Complete | parity sweep KNOWN==handled, distinct outcomes, no "not available" fallthrough; ref-aware acks pinned |
| CLI JSON event identity | Complete | envelope round-trip test: identity keys, sequence monotonicity, synthetic lines carry none |
| First contact never silent | Complete | first-contact suite: one-row-one-code, digest-only storage, operator-only approval |

## Provenance and blind spots

- Source revisions: `ca82d20`, `676d977`, `f322345`, `0fff1f8`; trees clean at
  each commit (one early miscommit of 1c's cli.rb into the 1a commit was
  rebuilt away before any later work).
- All evidence fixture-based: scripted transports, local model endpoints with
  canned responses, SQLite stores. No live Telegram, no real provider, no
  claim of agent usefulness or reasoning.
- Blind spots: aggregate `/status` reads the route row's original thread until
  a surface-revision rebinding after `/new` (per-request `/status r<ref>` is
  correct across generations); `/redirect` finished-detection reads the
  checkpoint inbox rather than the comms projection; pairing codes repeat
  across gateway restarts as benign duplicate pending rows (store holds hashes
  only); `/start` feedback for consumed/expired codes does not distinguish the
  two cases to the user.

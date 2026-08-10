# Communication channels and Telegram: implementation plan

The build order for [`COMMS_DESIGN.md`](COMMS_DESIGN.md). Status: proposed. Nothing here
is implemented.

This plan follows the roadmap's operating rules
([`PRODUCT_EXECUTION_ROADMAP.md`](PRODUCT_EXECUTION_ROADMAP.md) §1): plan → implement →
focused tests → deep review → `rake ci` → one phase commit → update the roadmap. Each
slice below is one commit with a clean worktree, and no slice begins before the previous
one's commit.

## 1. Scope commitment

**In scope for v1:** two new gems (`tamoz-comms`, `tamoz-telegram`), one `CommsStore`
implementation in `tamoz-sqlite`, one nil-safe worker `DeliverySink`, one shared exact
`DecisionRecord`, one new long-running process (`tamoz comms serve`), private Telegram
chats over long polling, allowlist/pairing admission, deny-only callbacks, the `tamoz
comms` CLI surface, backward-compatible reading of config schemas 1 and 2, and six
autonomy-scorecard cases.

**Out of scope, named so it cannot drift in:** everything in `COMMS_DESIGN.md` §19; any
network call from `Worker`; and any change to `Session`, `DurableRunner`, request-inbox
semantics, capability registry, or profile authority. The worker integration is limited to
the approved `DeliverySink` and exact decision-consumption seams. Anything broader hits
the stop criteria in §8.

**The gate this feature is really about:** a message from a bound private chat must not be
able to do anything a `tamoz queue add` under the bound profile could not do. A phone may
deny an exact pending interrupt; it cannot grant one.

## 2. Prerequisite decisions (blocking, before slice A)

Four things must be settled by the owner before code starts, because each changes what
gets built rather than how:

1. **Clause acceptance.** §18 of the design proposes invariants 56–58 and ADR-041–043.
   `test/documentation_test.rb` pins the counts at 55 and 40, and
   `script/generate_requirements_manifest` regenerates `docs/requirements-manifest.json`
   and `docs/REQUIREMENTS_AUDIT.md` from both files. Accepting the clauses is one
   deliberate commit that edits `INVARIANTS.md`, `DECISIONS.md`, the two pinned counts in
   `documentation_test.rb`, and the regenerated manifest — **before** any gem exists, so
   the contract precedes the code.
2. **Cross-gem seams.** Repository policy requires owner approval before changing a
   cross-gem interface. Approve exactly two: `tamoz-agent`'s nil-safe `DeliverySink` and
   `tamoz-sqlite`'s transaction-bound `CommsStore` implementation. The existing request
   inbox interface is reused, not changed.
3. **Decision-record correction.** Approve replacing the current
   `(thread, occurrence, granted)` worker record with the exact, consumable
   `DecisionRecord` in design §9 for both local CLI and channel denial. This is a
   prerequisite correctness/security fix, not Telegram-specific policy. No callback work
   starts until multiple interrupt rounds in one occurrence are proven not to reuse a
   prior decision.
4. **Where the feature sits on the roadmap.** The current phase is A1 (the autonomy
   milestone) with cases 09 and 10 still failing. A channel is the operator-facing half of
   that milestone's loop (`… → durable outcome → notification or approval request`), so it
   plausibly belongs *inside* A1 as slices I–J rather than after it. Owner's call; this
   plan is written so either placement works.

## 3. Slices

Each slice names its exit criterion. A slice is done when that criterion is proven by a
test that ran, not by inspection.

### Slice A — exact decision foundation

Introduce `tamoz-comms` with only design §9's immutable `DecisionRecord`/decision-store
contract, then replace the current worker tuple and migrate `tamoz approve` and `Worker`
together. This establishes the dependency direction without adding Telegram behavior.

**Exit:** two distinct approval rounds in one occurrence cannot reuse a decision; wrong
interrupt digest, expired record, duplicate consume, actor/source omission, concurrent
consume, and storage failure all refuse; kill before/after deterministic resume enqueue
neither loses nor duplicates the decision; existing CLI approval/denial tests remain green.

### Slice B — `tamoz-comms` values and seams

Complete `tamoz-comms` with `SurfaceDescriptor`, `InboundEnvelope`, `Delivery`,
binding/prompt values, closed commands/kinds, `Transport`, `DeliverySink`, typed errors,
and `CommsStore::CONTRACT_VERSION = 1`. Values validate/freeze all fields and use
domain-separated digests. Dependency:
`tamoz-core` only; no HTTP, graph, agent, or SQLite require.

**Exit:** bounds/round-trip/conflict tests, digest goldens, and a clean-subprocess proof
that `require "tamoz/comms"` opens no socket and loads none of `net/http`, `tamoz-graph`,
`tamoz-agent`, or RubyLLM.

### Slice C — `CommsStore` in `tamoz-sqlite`

Add design §13's tables and transaction-bound methods through an explicitly required
module. Admission and request enqueue share the existing
`enqueue_request_in_transaction!`; decision admission and prompt consumption share one
transaction. Poll `next_offset` persists only after the returned prefix is durable.

**Exit:** raw-oracle/kill tests at every statement; offset never persists past an
uncommitted disposition; one fenced poller per authenticated bot; contract-version pair
test; deletion/tombstone/purge receipts cover comms rows; boundary audit clean.

### Slice D — private-chat admission and pairing

Implement exact bot/correspondent/conversation ids, `:disabled|:allowlist|:pairing`, hashed
single-use pairing codes that activate only after a send receipt, explicit binding
versions/revocation, known-command parsing,
private-chat-only refusal, `/new` generation rotation, capacity reservations, and all
durable dispositions. A new thread's profile binding uses the existing Store's
create-only compare-and-set before any request can enqueue; a crash may leave only an inert
binding, never unauthorised work.

**Exit:** every rejection has the right durable reason and no request; empty allowlist is
a load error; usernames/display names/anonymous senders/groups/business/edited/media
updates never admit; revoke invalidates prompts; concurrent `/new` routing is atomic.
Capacity arithmetic is validated at config load, and exceeding the per-request denial-
prompt cap leaves the occurrence locally approvable without creating a chat decision.

### Slice E — rendering and worker delivery projection

Implement deterministic plain/restricted-HTML rendering, character/grapheme splitting,
explicit truncation recovery, framework-only control messages, `Tamoz::Secret` refusal,
the null sink, and projection-before-close for completed/failed/stopped/paused views.

**Exit:** pathological Unicode/HTML/200-KB goldens; render-version conflict; crash before
append, after append, and before occurrence close yields one delivery; a runtime with no
channels is byte-identical to current worker behavior.

### Slice F — `tamoz-telegram` transport

Implement `getMe`, `getUpdates` with explicit `allowed_updates`, `sendMessage`, `editMessageText`,
`answerCallbackQuery`, and `sendChatAction`. Production origin is fixed, redirects and env
proxies are disabled, resolved addresses are public, TLS is verified, bodies/depth are
bounded, deadlines explicit, and token redaction occurs at construction.

**Exit:** fixture server covers success, unchanged edit, 401, 409, 429, truncation,
oversize/deep JSON, redirect refusal, private-address refusal, lost poll response, and
mid-send timeout. Property tests prove no URI/error/event/`inspect` contains the token and
no forbidden destination opens a socket.

### Slice G — gateway, outbox, and effect journal

Build the foreground gateway, ordered prefix admission, persisted `next_offset`, fenced
outbox claims, rate shaping, and journal integration. `sendMessage` is `:unsafe`; an
ambiguous send stops `:unknown` with no automatic retry. The outbox schedules work but
does not duplicate attempt/receipt lifecycle.

**Exit:** end-to-end message → request → worker → answer; kill matrix after poll, each
admission boundary, offset persistence, projection, claim, send, and receipt; exactly one
turn, no offset loss, no blind resend, and reserved terminal output survives saturation.

### Slice H — deny-only Telegram callback

Add hashed 128-bit references, action encoding under 64 bytes, activation only after the
prompt receipt, six-check atomic denial, refusal evidence, and callback acknowledgement.
Plaintext reference tokens live only for one send attempt and never enter SQLite. There is
no grant enum or branch.

**Exit:** replay, expiry, wrong user/chat/message/binding/revision, inactive/unknown-send
prompt, changed interrupt digest, forged grant action, and racing presses all refuse
durably except one valid denial. `chat_grants == 0` and `headless_auto_approvals == 0`.

### Slice I — CLI, config, operator surface

Add strict schema 2 plus schema-1-as-no-channels reading and explicit atomic migration,
`tamoz comms serve|list|pair|delivery resolve|doctor`, the `channels` section of `tamoz
status`, and
`INSTALL.md`/`OPERATIONS.md` sections covering setup, revocation, and what to do when a
delivery is `:unknown`.

**Exit:** pinned CLI surface test; schema-1 directory loads unchanged; migration preserves
a backup and refuses partial writes; bootstrap prints but does not persist bot id; doctor
names wrong bot id, webhook/poller conflict, permissions, token, TLS, and adapter absence.

### Slice J — evaluation

Autonomy-scorecard cases 11–16 from design §16, run against the public CLI with the
fixture transport. One behavioral evaluation ships with the capability, not after it.

**Exit:** six cases passing with zero hard safety counters, `script/autonomy_scorecard`
regenerated, roadmap updated.

## 4. Tests, by the invariant they defend

| Clause | Test shape |
|---|---|
| 23 | The same `update_id` delivered twice, concurrently and across a restart; one logical turn commits |
| 24 | Property test: the token never appears in a checkpoint, store row, stream part, emitted event, exception message or `inspect` |
| 21 / 57 | Kill at prepare, mid-send, after send and before receipt; edits converge, sends stop `:unknown`, and neither is blindly retried |
| 44 / 56 | A channel request, a scheduled occurrence, a stream event and one graph's `StreamPart`s concurrently; each uses its own contract |
| 53 | Two messages during a live turn plus a `/redirect`; FIFO holds, the redirect reconciles |
| 58 | The adversarial approval suite from slice H |
| 35 / 42 | A message, a Telegram profile name, and a bot "description" all attempt to name a tool or profile; none reaches policy |
| dependency rules 1/8/9 | Isolated `GEM_HOME` install per gem; `tamoz-comms` with only `tamoz-core`, `tamoz-telegram` with only `tamoz-comms`; neither loads a model |

Both new gems join `test/packaging_test.rb`'s gem list and the isolated-install proof.

## 5. Failure model additions

The gateway adds three failure classes the repository does not currently have, and each
needs an explicit answer in code rather than a rescue:

1. **A remote peer that is simultaneously the credential holder's counterparty and the
   attacker's channel.** Every field from an update is untrusted, including ones that look
   structural (`chat.type`, `from.is_bot`, forum `message_thread_id`).
2. **Remote confirmation happens on the next poll.** A persisted `next_offset` is safe
   only after the complete returned prefix has durable dispositions. The next
   `getUpdates(offset:)` confirms it remotely. This ordering gets its own test file;
   there is no invented acknowledge API.
3. **An effect with no reconciliation query.** Documented in `docs/LIMITATIONS.md` rather
   than papered over.

## 6. What this plan deliberately does not build

- No webhook server. A public HTTPS listener is a second attack surface and a deployment
  requirement; long polling needs neither.
- No media pipeline. Inbound non-text is refused typed; outbound overflow is explicitly
  truncated in chat with a local `tamoz show` recovery path.
- No group/supergroup/channel/forum support. V1 is private-chat-only until output
  classification and changing membership have a separate accepted design.
- No second notification abstraction. `Tamoz::Notifier` stays what it is; deliveries are
  outbox rows.
- No `comms.notify` model capability. `Capability::BUILT_IN_SOURCES` is a closed set of
  four and `Descriptor::KINDS` a closed set of four; letting the model send chat messages
  as a tool means a fifth kind, an ADR, and a new authority-laundering path to defend.
  Delivery stays runtime-driven. If it is ever wanted, it is its own design.

## 7. Effort and sequencing

| Slice | Size | Depends on |
|---|---|---|
| A exact decisions | M | clause acceptance, prerequisite 3 |
| B values and seams | M | A |
| C store | L | B |
| D admission | M | B, C |
| E rendering and worker sink | L | A, B, C |
| F transport | L | B |
| G gateway/outbox/journal | L | C, D, E, F |
| H deny callback | L | A, C, D, E, F, G |
| I CLI and config | M | D, G, H |
| J evaluation | M | all |

After B, C and F can proceed independently; after C, D and E can proceed independently.
H is the highest-risk binding slice even though it can only deny.

## 8. Stop / redesign criteria

Stop and redesign if any of these becomes true during the build:

- a slice needs to change `Session`, `DurableRunner`, request-inbox semantics, or `Worker`
  beyond the approved delivery/decision seams;
- the gateway needs a model credential value, toolbox, or workspace file for any reason;
- a callback path needs to be honoured without all six checks in design §9, or any chat
  path can grant approval;
- the closed command table needs an escape hatch;
- production configuration can redirect the bot token away from the exact Telegram API
  origin;
- capacity pressure can discard a terminal delivery or advance an offset past an update
  without a durable disposition;
- delivery ambiguity needs to be resolved by guessing;
- `tamoz-comms` needs a network dependency, or `tamoz-telegram` needs `tamoz-agent`.

Each of those is the feature turning into something the design refused. None is a reason
to add an exception.

## 9. Definition of done (v1)

1. Invariants 56–58 and ADR-041–043 accepted, manifest regenerated, audit rows green.
2. Both gems install and run in isolated `GEM_HOME`s with only their declared
   dependencies, and neither loads a model.
3. A real Telegram bot, bound to one allowlisted correspondent, completes: message →
   durable turn → answer, with the worker on a real model, at least once — the roadmap's
   own standing complaint is that nothing has been proven against a real model, and a
   channel is exactly the feature where a scripted model hides the problems.
4. The `kill -9` matrix from slice G passes at every seam.
5. The adversarial approval suite from slice H passes with both safety counters at zero.
6. Scorecard cases 11–16 pass with zero hard safety counters.
7. `rake ci_full` green in both locales, plus `rubocop` and `enola check` — this feature
   touches durability, packaging, boundaries, and evidence.
8. `docs/LIMITATIONS.md` records the delivery-ambiguity boundary, and
   `docs/OPERATIONS.md` records revocation and `:unknown`-delivery recovery.
9. An independent fresh-context review of the admission and approval boundaries has run
   and its findings are closed. The roadmap records that zero such reviews have happened
   for the existing boundaries; this one must not ship without.

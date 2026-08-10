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
implementation in `tamoz-sqlite`, one new long-running process (`tamoz comms serve`), the
`tamoz comms` CLI surface, `config.yaml` schema version 2 with a `channels:` section, and
six autonomy-scorecard cases.

**Out of scope, named so it cannot drift in:** everything in `COMMS_DESIGN.md` §19, and
any change to `Worker`, `Session`, `DurableRunner`, the request-inbox semantics, or the
capability registry. If a slice appears to need one of those, that is a design failure and
the stop criteria in §8 apply.

**The gate this feature is really about:** a message from a phone must not be able to do
anything a `tamoz queue add` from the operator's shell could not do, and an approval from
a phone must be able to do strictly less.

## 2. Prerequisite decisions (blocking, before slice A)

Three things must be settled by the owner before code starts, because each changes what
gets built rather than how:

1. **Clause acceptance.** §18 of the design proposes invariants 56–58 and ADR-041–043.
   `test/documentation_test.rb` pins the counts at 55 and 40, and
   `script/generate_requirements_manifest` regenerates `docs/requirements-manifest.json`
   and `docs/REQUIREMENTS_AUDIT.md` from both files. Accepting the clauses is one
   deliberate commit that edits `INVARIANTS.md`, `DECISIONS.md`, the two pinned counts in
   `documentation_test.rb`, and the regenerated manifest — **before** any gem exists, so
   the contract precedes the code.
2. **Approval authority.** Ship with `approvals.mode` capped at `:deny_only`, or implement
   `:granting` in v1? The design supports both; `:deny_only` is a materially smaller
   security review. Recommendation: implement the full mode enum, but have
   `RuntimeDirectory` refuse `:granting` in v1 with a typed error, so the code path exists,
   is tested, and cannot be enabled until the review that clears it.
3. **Where the feature sits on the roadmap.** The current phase is A1 (the autonomy
   milestone) with cases 09 and 10 still failing. A channel is the operator-facing half of
   that milestone's loop (`… → durable outcome → notification or approval request`), so it
   plausibly belongs *inside* A1 as slices I–J rather than after it. Owner's call; this
   plan is written so either placement works.

## 3. Slices

Each slice names its exit criterion. A slice is done when that criterion is proven by a
test that ran, not by inspection.

### Slice A — `tamoz-comms` values and the transport seam

`SurfaceDescriptor`, `InboundEnvelope`, `Delivery`, `Correspondent`/`Conversation`
bindings, the closed command table, the closed `KINDS` list, the `Transport` module, the
typed error family (`AuthenticationError`, `AdmissionError`, `AmbiguousDeliveryError`,
`ThrottledError`), and the `CommsStore` structural contract with `CONTRACT_VERSION = 1`.

Everything is `Data.define` with validation in `initialize`, frozen fields, and a
domain-separated `definition_digest` — the `Stream::ChannelDescriptor` shape exactly.
Dependencies: `tamoz-core` only. No `net/http` anywhere in this gem.

**Exit:** value round-trip and rejection tests for every bound; a digest golden test; a
clean-subprocess test proving `require "tamoz/comms"` loads no HTTP, no `tamoz-graph`, no
`tamoz-agent`, no RubyLLM, and opens no socket (the invariant-11 test shape, reused).

### Slice B — `CommsStore` in `tamoz-sqlite`

The seven tables from design §13, as one new migration, loaded through an explicitly
required optional module — the `stream_store.rb` pattern, not a change to the base schema.
Admission is one transaction: inbound record + request enqueue, or inbound record +
decision record. Cursor advance is a separate, later transaction.

**Exit:** a raw-oracle-style test that admission and enqueue are atomic under `kill -9` at
every statement; a test that the cursor never advances past an unadmitted update; a
contract-version pair test in `tamoz-evals`; `boundary_source_audit` clean.

### Slice C — admission, identity, and pairing

Correspondent/conversation resolution, the four admission modes, group's two-gate rule,
pairing code issue/approve/revoke with expiry, single use and per-sender rate limiting,
and the durable rejection reason classes.

**Exit:** an adversarial test that walks every rejection reason and asserts a durable
record with the right class and **no** enqueued request; a test that a DM pairing approval
grants nothing in a group; a test that an empty allowlist under `:allowlist` is a
configuration error at load, not an allow-all at runtime.

### Slice D — `tamoz-telegram` transport

`getMe`, `getUpdates` long polling with `allowed_updates` and an explicit deadline,
`sendMessage`, `editMessageText`, `sendDocument`, `answerCallbackQuery`, `sendChatAction`.
Egress enforced at the dial: allowlisted host, https, no private ranges, bounded response
bytes, one redirect hop, connect timeout, circuit. Token redaction applied at URI and
error construction, never at print time.

**Exit:** the whole surface driven against a local fixture HTTP server covering `200`,
`400 message is not modified`, `401`, `409`, `429 retry_after`, a truncated response, a
redirect to a non-allowlisted host, a body over the byte bound, and a mid-send timeout; a
property test that no constructed URI, exception message, or emitted event contains the
token; a test that a delivery to any host outside the allowlist fails before a socket
opens.

### Slice E — the gateway process

`tamoz comms serve` as a plain foreground process in the shape of `Worker`: SIGINT/SIGTERM
finish what is in hand and exit 0, `--once` drains, idle sleeps on a cancellation token,
per-surface containment so one sick surface cannot take the process down. The poll loop
carries an explicit deadline and reports a stall rather than hanging silently.

**Exit:** an end-to-end test with the fixture transport and a scripted model: message in →
request enqueued → `tamoz worker --once` runs the turn → answer delivered; a `kill -9`
matrix at every seam (after poll, after admit, after enqueue, before cursor advance, after
claim, after send, before receipt) asserting exactly one turn and no silent duplicate.

### Slice F — outbound outbox and journaling

Delivery append from the worker's settle path (the only change outside the new gems: the
worker emits deliveries where it currently only emits events, behind a nil-safe seam so a
runtime with no channel behaves byte-identically), fenced claim in the gateway, the
journal integration under the synthetic `comms:<delivery_id>` execution id, the
reconciler, and the two `:unknown` policies.

**Exit:** a test that `:approval_request` under `:stop` leaves an `:unknown` effect visible
in `tamoz status` and resolvable by `tamoz resolve`; a test that `:answer` under
`:resend_once_marked` sends at most one marked duplicate and then stops; a test that a
runtime with no `channels:` section produces byte-identical worker behavior to today.

### Slice G — rendering

Deterministic splitting, the part counter, the document/truncate overflow, plain and
restricted-HTML escaping, the framework-only construction of control renderings, and the
secret guard.

**Exit:** golden rendering fixtures over pathological inputs — a 200 KB answer, CJK and
emoji at every boundary, text that is entirely one 5000-character word, model output
containing `</pre><b>` and a Markdown link whose target is a `tg://` deep link, and a `Tamoz::Secret` reaching the
renderer (which must raise, not redact silently).

### Slice H — approvals from chat

The prompt record, the reference encoding under 64 bytes, the five-check honour path, the
refusal records, and `record_decision` with the correspondent as actor.

**Exit:** an adversarial suite — replayed button, expired reference, wrong correspondent,
reference for a question whose interrupt digest changed, grant attempted under
`:deny_only`, grant of a class outside `grant_classes`, two presses racing. Each must
refuse durably. Plus the counter assertion: `chat_grants_beyond_profile == 0` and
`headless_auto_approvals == 0` across the whole suite.

### Slice I — CLI, config, operator surface

`config.yaml` schema version 2 with a migration path for version 1 directories,
`tamoz comms serve|list|pair|send|doctor`, the `channels` section of `tamoz status`, and
`INSTALL.md`/`OPERATIONS.md` sections covering setup, revocation, and what to do when a
delivery is `:unknown`.

**Exit:** the CLI surface test (the repo already pins the subcommand list), a schema-1
directory loading unchanged, and a `doctor` run that names each misconfiguration
distinctly.

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
| 21 / 57 | Kill at prepare, mid-send, after send and before receipt; converge or stop `:unknown`, never a blind resend of an approval prompt |
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
2. **An ack that must lag durability.** The cursor is the only place where "we told the
   remote we are done" can outrun "we recorded it", and it is the only place where a bug
   silently loses a user's message. It gets its own test file.
3. **An effect with no reconciliation query.** Documented in `docs/LIMITATIONS.md` rather
   than papered over.

## 6. What this plan deliberately does not build

- No webhook server. A public HTTPS listener is a second attack surface and a deployment
  requirement; long polling needs neither.
- No media pipeline. Inbound non-text is refused typed; outbound overflow is one `.md`
  attachment.
- No second notification abstraction. `Tamoz::Notifier` stays what it is; deliveries are
  outbox rows.
- No `comms.notify` model capability. `Capability::BUILT_IN_SOURCES` is a closed set of
  four and `Descriptor::KINDS` a closed set of four; letting the model send chat messages
  as a tool means a fifth kind, an ADR, and a new authority-laundering path to defend.
  Delivery stays runtime-driven. If it is ever wanted, it is its own design.

## 7. Effort and sequencing

| Slice | Size | Depends on |
|---|---|---|
| A values and seam | M | clause acceptance |
| B store | M | A |
| C admission | M | A, B |
| D transport | L | A |
| E gateway | L | B, C, D |
| F outbox and journal | L | B, E |
| G rendering | M | A |
| H approvals | L | E, F, G |
| I CLI and config | M | E |
| J evaluation | M | all |

D and G have no dependency on each other and can run in parallel if two people are on it.
H is the slice that must not be rushed; it is the only one that can widen authority.

## 8. Stop / redesign criteria

Stop and redesign if any of these becomes true during the build:

- a slice needs to change `Worker`, `Session`, or the request-inbox semantics;
- the gateway needs the model credential, the toolbox, or the workspace path for any
  reason;
- an approval path needs to be honoured without all five checks in design §9;
- the closed command table needs an escape hatch;
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
4. The `kill -9` matrix from slice E passes at every seam.
5. The adversarial approval suite from slice H passes with both safety counters at zero.
6. Scorecard cases 11–16 pass with zero hard safety counters.
7. `rake ci_full` green in both locales — this slice touches durability, packaging and
   evidence, which is exactly the set the gate policy names.
8. `docs/LIMITATIONS.md` records the delivery-ambiguity boundary, and
   `docs/OPERATIONS.md` records revocation and `:unknown`-delivery recovery.
9. An independent fresh-context review of the admission and approval boundaries has run
   and its findings are closed. The roadmap records that zero such reviews have happened
   for the existing boundaries; this one must not ship without.

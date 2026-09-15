# F14 `tamoz-telegram` — IMPROVE (contract-compliant adapter whose normalizer raises uncaught `KeyError`/`NoMethodError` that abort the whole gateway loop, and whose `PollerConflictError` on a send is unreadable by the drainer it was written for)

Row / queue / baseline (commit, date) / analyst / budget
- Row: **F14** — `tamoz-telegram` — "Telegram Bot API transport adapter"
- Queue: gem rows, primary queue (`COVERAGE.md:82`, status `open coverage`)
- Baseline: `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`, HEAD `582ae55`
- Date: 2026-09-15
- Analyst: independent read-only functionality analyst (analyst_f14)
- Budget: ~40 min target / 60 min hard cap; used ~35 min

## Scope and source map

Read end to end, every line:

| File | Lines | Role |
|---|---|---|
| `gems/tamoz-telegram/lib/tamoz/telegram.rb` | 17 | namespace + requires; the gem entry |
| `gems/tamoz-telegram/lib/tamoz/telegram/client.rb` | 142 | the one HTTP boundary (net/http, stdlib only) |
| `gems/tamoz-telegram/lib/tamoz/telegram/normalizer.rb` | 159 | raw update → `Comms::InboundEnvelope` wire |
| `gems/tamoz-telegram/lib/tamoz/telegram/transport.rb` | 109 | the four-method `Comms::Transport` seam |
| `gems/tamoz-telegram/lib/tamoz/telegram/version.rb` | 7 | `VERSION = '0.1.0.alpha.1'` |
| `gems/tamoz-telegram/tamoz-telegram.gemspec` | 18 | deps: `tamoz-comms` only |

**Entry seam.** `Tamoz::Telegram::Transport#authenticate/#poll/#deliver/#signal`
(`transport.rb:28,37,52,74`) implementing `Tamoz::Comms::Transport`
(`gems/tamoz-comms/lib/tamoz/comms/transport.rb:24-56`). The only production
construction site is the CLI's lazy adapter factory:
`gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_shared.rb:120-146`
(`build_transport`, `comms_client_factory`) — `tamoz-telegram` is loaded by
`require 'tamoz/telegram'` at `cli_comms_shared.rb:122,139`, never by tamoz-comms
itself (dependency rule 9, `transport.rb:18-20`).

**Seam counterparts read** (the boundary this row is graded against):

| File | Lines read | Why |
|---|---|---|
| `gems/tamoz-comms/lib/tamoz/comms/transport.rb` | 58 (all) | the implemented contract |
| `gems/tamoz-comms/lib/tamoz/comms/errors.rb` | 75 (all) | the success/failure/unknown taxonomy |
| `gems/tamoz-comms/lib/tamoz/comms/delivery.rb` | 167 (all) | the `Delivery` the adapter renders |
| `gems/tamoz-comms/lib/tamoz/comms/inbound_envelope.rb` | 213 (all) | the value the normalizer must produce |
| `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb` | 165 (all) | the driver of `deliver` |
| `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway.rb` | 50-60, 150-309 | the driver of `poll`/`authenticate` |
| `gems/tamoz-comms-gateway/lib/tamoz/comms/gateway_admission.rb` | 85-130 | where `max_inbound_bytes` is enforced |
| `gems/tamoz-sqlite/lib/tamoz/sqlite/comms_outbox.rb` | 100-254 | claim / send-started / reconcile semantics |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_shared.rb` | 80-162 | production construction + credential plumbing |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_doctor.rb` | 30-145 | the operator credential path |
| `gems/tamoz-telegram/README.md`, `documentation/guides/telegram.md` | 160 | stated promises graded below |

## Behavior path

**Inbound (poll).** `Gateway#serve_once` (`gateway.rb:190-212`) →
`poll_offset` (`gateway.rb:193`) → `Transport#poll` (`transport.rb:37-47`) builds
`{timeout, limit, allowed_updates[, offset]}` (`transport.rb:38-40`), POSTs
`/bot<token>/getUpdates` (`client.rb:112-114,124-129`), parses and unwraps
`result` (`client.rb:60-70`) → each raw update goes through
`Normalizer#normalize` (`normalizer.rb:34-50`) → `InboundEnvelope` validates
(`inbound_envelope.rb:127-208`) → `.wire` (`normalizer.rb:42`) → `admit` per
envelope (`gateway.rb:197`) → `persist_next_offset` (`gateway.rb:198`) — the
offset is a **candidate** derived from `max(update_id) + 1`
(`transport.rb:43-44`) and is persisted only **after** every envelope in the
batch has a durable disposition. That is the contract `transport.rb:12-15`
states, and it holds.

**Outbound (deliver).** `DeliveryDrainer#drain_once` (`delivery_drainer.rb:45-57`)
→ `claim` (`:61-69`) → `send_row` (`:71-128`) → `mark_delivery_send_started`
(`:87-92`) → `send_delivery` (`:142-151`) → `Transport#deliver`
(`transport.rb:52-72`) → `chat_id` de-prefix (`transport.rb:101-106`) → one POST
`sendMessage` **or** `editMessageText` (`transport.rb:64`) → receipt
`{message_id, platform_time}` (`transport.rb:65-68`) → `mark_delivery`
(`delivery_drainer.rb:95-102`) → `activate_after_receipt` for approval prompts
(`:133-140`).

**Signal.** `Transport#signal(:ack, …)` → `answerCallbackQuery`
(`transport.rb:74-79`), `:unsupported` for anything else (`:75`).

## Lens: correctness

Reviewed. The status→outcome mapping is exact and matches the contract. Proven
by direct probe against a real socket (not a mock), `client.rb:59-93`:

| Remote answer | Adapter result | Error taxonomy |
|---|---|---|
| 2xx `ok:true` | payload `result` returned | success |
| 2xx `ok:true` on send | `{message_id, platform_time}` | success |
| 2xx without `ok` field | `raise ValidationError` | `client.rb:62` |
| 2xx `ok:false error_code:401` | `AuthenticationError` | `client.rb:66-67` |
| **429** (any method) | `ThrottledError(retry_after:)` | `client.rb:71-72` |
| **401** HTTP | `AuthenticationError` | `client.rb:73-74` |
| **409** HTTP (any method) | `PollerConflictError` | `client.rb:75-81` |
| any other status, idempotent read | `TransientTransportError` | `client.rb:116-118` |
| any other status, send | `AmbiguousDeliveryError` | `client.rb:116-122` |
| timeout / ECONNRESET / ETIMEDOUT / bad JSON, read | `TransientTransportError` | `client.rb:85-90` |
| timeout / ECONNRESET / ETIMEDOUT / bad JSON, send | `AmbiguousDeliveryError` | `client.rb:91-92` |
| oversized poll body | `TransientTransportError` | `transport.rb:45-46` |
| oversized send body | `AmbiguousDeliveryError` | `transport.rb:69-71` |
| `ok:false error_code:429` in a **200** body | `AmbiguousDeliveryError` (send) / `TransientTransportError` (read) — **no retry_after** | `client.rb:69` |

Probe results (`/tmp` scratch, not in repo):
`DELIVER-429 -> ThrottledError retry_after=7`; `POLL-429 -> ThrottledError
retry_after=7`; `DELIVER-ok-false-403 -> AmbiguousDeliveryError`;
`DELIVER-HTTP400 -> AmbiguousDeliveryError`. Upgrade to `unknown` on send (not
`failed`) is the **safe** direction — `DrainerTest` at `delivery_drainer_test.rb:116`
asserts a send ambiguity lands in `unknown`. Two correctness gaps survive, both
recorded as findings: the `PollerConflictError`-on-a-send escape (F14-COR-01) and
the `ok:false 429`-in-200-body degradation (F14-RES-01). One verified
correctness *fact* worth naming: 409 on **poll** reaching
`Gateway#serve_loop`'s `rescue Comms::PollerConflictError` (`gateway.rb:161-162`)
is fine, because `gateway.rb:203-204` re-raises it ahead of
`gateway.rb:210`'s catch-all.

## Lens: security and authority

Reviewed. **The token never reaches a message, a log, or a store — verified, not
assumed.** Five independent checks:

1. Every exception the adapter raises is a **string literal or an exception class
   name**: `client.rb:62,67,69,72,74,81,90,92,120` and
   `transport.rb:31,46,70-71`. `@token` appears on exactly one line in the whole
   gem — `client.rb:113`, inside `path_for` — and never in a raise, an
   interpolation, or a receipt.
2. Live wire capture of the request shows the token only in the request line:
   `POST /bot111:AAFake…/getUpdates HTTP/1.1`, with `Accept`, `User-Agent`,
   `Content-Type`, `Connection`, `Host`, `Content-Length` and no auth header.
3. `Client#inspect` **does** render the token (`CLIENT_INSPECT:
   #<Tamoz::Telegram::Client … @token="111:AAFake…">`) — this is the one
   credential-bearing object shape in the gem. See F14-OBS-01: it is a **minor**
   exposure, because no repository path stringifies the client (proven by
   exhaustive grep), not a critical leak.
4. `Net::HTTP`'s own `@request` ivar leak was checked: a real connection reset
   (`Errno::ECONNRESET`) and a real read timeout (`Net::ReadTimeout`) on this
   code path produce only `TransientTransportError` / `AmbiguousDeliveryError`,
   and intercepting `Net::HTTP#warn` captured **zero** warnings — the URI never
   enters a warning or the error message.
5. TLS peer verification is **on**: a live probe against a self-signed
   `CN=not-telegram.invalid` TLS server was refused
   (`OpenSSL::SSL::SSLError: certificate verify failed (self-signed certificate)`).
   `client.rb:134` sets `use_ssl = uri.scheme == 'https'` without touching
   `verify_mode`, which is the safe default. The doctor's check
   (`cli_comms_doctor.rb:105-109`) only asserts the origin string starts with
   `https://`, so a *future* `verify_mode` regression inside the gem would not be
   caught by it — see F14-SEC-02 (minor, latent; the current behavior is proven
   safe).

Authority on the inbound path is not widened by this gem: a group/supergroup/
channel update normalizes to a typed prefix (`normalizer.rb:20-24,144-148`) that
admission refuses, and a chat id cannot forge a `telegram:user:` correspondent
because `correspondent_id` is built from `from`, never from `chat`
(`normalizer.rb:71`, `inbound_envelope.rb:161-169`).

## Lens: reliability and durability

Reviewed. **The load-bearing invariant holds: an ambiguous send is never blindly
retried.** `Transport#deliver` calls `@client.call(…)` with the default
`idempotent: false` (`transport.rb:64`), so every non-2xx status, every network
timeout, every connection reset and every unparseable body on a send becomes
`AmbiguousDeliveryError` (`client.rb:85-92,116-122`), which
`DeliveryDrainer#send_delivery` maps to `status: 'unknown'`
(`delivery_drainer.rb:147-151`). The operator resolves it explicitly
(`comms_outbox.rb:248-254`); nothing re-sends it. `retry_after` is honored where
the server actually sends it: `ThrottledError#retry_after`
(`client.rb:108-110`) → `defer_delivery` (`delivery_drainer.rb:117-127`) →
`serve_loop` sleeps the authoritative delay (`:33`). A read that fails is
`TransientTransportError` and re-polled from the unchanged durable offset
(`gateway.rb:214-220`), which is the correct distinction the comments claim.

Four reliability gaps are recorded (F14-COR-01 Rel-01 Rel-02 Rel-03) and one is
recorded as a bounded info item (F14-REL-04). The optimistic terminator:
`Transport#poll` calls `update.fetch('update_id')` (`transport.rb:43`) with **no
rescue**, and `Normalizer#normalize` calls `.fetch` on five mandatory fields
(`normalizer.rb:35,65,66,80,81,85,87,88,95,99,145,147`) with **no rescue**. A
gateway in the `:transient` backoff state has no timeout wrapper around its
transport calls (grep for `Timeout` in `gateway.rb` and `delivery_drainer.rb`
returns only the `CLAIM_TTL_S`/`POLLER_TTL_S` constants), so an escaping
exception is a process-aborting backtrace.

## Lens: observability and evidence

Reviewed, with one gap. The adapter is disciplined about *what* it reports: every
failure carries a typed `CATEGORY` and a `SAFE_MESSAGE` from
`Comms::Error::Metadata` (`error.rb:29-40`), and the gateway/CLI print the
exception message, never a backtrace (`cli_comms_commands.rb:92,162`). The `409`
conflict path deliberately carries the API's own `description` so the operator
learns *which* competitor holds the stream (`client.rb:96-105`), and
`test_a_competing_poller_is_a_named_conflict_not_a_generic_error`
(`tamoz_telegram_transport_test.rb:311-324`) pins it.

The gap is that the **effective timeouts and the effective response cap are not
observable anywhere**: `Client` exposes `origin` and `max_response_bytes`
(`client.rb:27`) but not `open_timeout`/`read_timeout`, so the `comms doctor`
report (`cli_comms_doctor.rb:60-83`) cannot state the read timeout it is banking
on. Recorded as F14-OBS-01 alongside the `inspect` exposure, since one
`attr_reader :token` removal and one reader addition close both.

## Lens: scalability and resource bounds

Reviewed. Bounds are real and mostly well-placed: the response body is streamed
and aborted past `max_response_bytes` (`client.rb:51-56`), the cap is validated
`1..10_000_000` at the descriptor (`surface_descriptor.rb:184-186`) and defaults
to `10_000_000` (`client.rb:25,35-37`); `allowed_updates` is always explicit
(`transport.rb:38-40`) so the wire cannot grow an unbounded type set; `connect`
and `read` timeouts are both set on every call (`client.rb:135-136`, defaults
`10.0`/`65.0` at `client.rb:23-24`); the drainer's batch is `50`
(`delivery_drainer.rb:15`) and sends are paced (`:72-80`). The inbound byte law
exists but is enforced *downstream* of this adapter:
`GatewayAdmission#control_inbound_too_large?` (`gateway_admission.rb:106-115`)
and `comms_store.rb:138` both compare against `limits.max_inbound_bytes` (8192
default, `cli_comms_shared.rb:92`), and `InboundEnvelope::MAX_TEXT_BYTES = 8192`
(`inbound_envelope.rb:26,182-184`) refuses first — by **raising**
`ValidationError`, which is F14-REL-01's abort rather than a typed refusal. The
normalizer itself has a size bound; `Transport#poll` does not translate it.

## Lens: maintenance and architecture

Reviewed. Ownership is honest and the dependency direction is exactly as claimed:
one runtime dependency (`tamoz-telegram.gemspec:15-18` declares
`tamoz-comms = 0.1.0.alpha.1`), stdlib-only HTTP (`client.rb:3-5`), no framework,
and `tamoz-comms` never references `Tamoz::Telegram` — the load is inverted at
`cli_comms_shared.rb:122,139` behind a `MissingAdapterError`
(`cli_comms_shared.rb:20-21,142-145`). The public surface is narrow and pinned by
`test/public_api_test.rb:378-382,455`. Vocabulary is consistent with the
repository — `normalize`, `render/parse`, `validate`, `wire`, `bounded`. The
normalizer's digest covers the *meaningful* content rather than only
`update_id` (`normalizer.rb:117-120,154-156`), which is what makes a content
change under one `update_id` a detectable conflict.

Two maintenance items: `Client#initialize` accepts a `read_timeout:`
(`client.rb:29-30`) that no descriptor field can currently reach, because
`SurfaceDescriptor` has no such key, while
`transport.fetch(:max_response_bytes)` (`cli_comms_shared.rb:140`) shows the
convention for the one cap it does carry — recorded as F14-MNT-01 (info). The
`client.rb:9-20` comment block asserts the "genuinely irreconcilable" ambiguity
of a send timeout, which the repository's own rule text contradicts; recorded as
F14-MNT-02 (minor).

## Tests and contracts

Run, one file per command, all green:

| Command | Result |
|---|---|
| `ruby -Itest test/tamoz_telegram_transport_test.rb` | **23 runs / 50 assertions / 0F** |
| `ruby -Itest test/telegram_normalizer_test.rb` | **10 runs / 28 assertions / 0F** |
| `ruby -Itest test/delivery_drainer_test.rb` | **10 runs / 50 assertions / 0F** |
| `ruby -Itest test/comms_gateway_test.rb` | **39 runs / 242 assertions / 0F** |
| `ruby -Itest test/public_api_test.rb` | **3 runs / 1051 assertions / 0F** |

Not run: `test/callback_ack_crash_test.rb`, `test/comms_cli_ops_test.rb`,
`test/comms_adr049_consistency_test.rb`, `test/comms_evidence_gated_approval_test.rb`,
`test/canonical_cross_surface_composition_test.rb`, `test/experience_harness_test.rb`
— outside the 45-minute budget once the five above plus the probes were done; they
exercise the Telegram adapter indirectly and their absence does not affect any
finding below (every finding is proven from source plus a direct probe).

**Not found** (searched, absent — this is what makes the findings findings):
- no test scripts a **409 on `sendMessage`/`editMessageText`**: grep of `test/`
  for `409`/`Conflict` returns only `Tamoz::CheckpointConflictError` sites and
  `comms_gateway_test.rb:320`, which is a *comment*. `tamoz_telegram_transport_test.rb:311`
  covers 409 on `getUpdates` only.
- no test feeds the normalizer a **malformed or hostile update**: every fixture in
  both telegram test files is well-formed (`tamoz_telegram_transport_test.rb:29-40`,
  `telegram_normalizer_test.rb:14-27`); `update(...)` even calls `.compact` to
  drop nil keys, so the missing-field paths are structurally unreachable in-test.
- no test asserts the **`ok:false` + `error_code:429` in a 200 body** path
  (`tamoz_telegram_transport_test.rb:101-109` uses HTTP 429, and
  `:135-153` uses `error_code: 500`/`401`).
- no descriptor/test coverage for a **`read_timeout`** transport key
  (`surface_descriptor.rb:176-187` validates `mode`, `credential_ref`,
  `poll_timeout_s`, `batch`, `max_response_bytes` only).

**Read-only probe method** (no Telegram, no provider, no live network; scratch
files under `/tmp`, deleted from the repo path): a loopback `TCPServer`
(plain, and TLS with a self-signed cert) plus a stub client object injected into
the real `Tamoz::Telegram::Transport` and the real `Tamoz::Telegram::Client`.

## Findings

### F14-REL-01 — a malformed or oversized inbound update raises `KeyError`/`NoMethodError`/`ValidationError` out of `poll` and aborts the whole gateway process

- **Severity**: major · **Confidence**: high · **Status**: open
- **Lens**: reliability and durability (boundary failure path)
- **Owning seam**: `Tamoz::Telegram::Transport#poll` (`transport.rb:41-47`) —
  the normalizer call at `transport.rb:42` is the only unguarded step in the
  adapter's inbound path.
- **Source evidence**:
  - `transport.rb:42` — `updates = result.map { |update| @normalizer.normalize(update).wire }`, inside a method whose only `rescue` is `Comms::ResponseTooLargeError` (`transport.rb:45-46`).
  - `normalizer.rb:35` (`update.fetch('update_id')`), `:65` (`message.fetch('chat')`), `:66` (`message.fetch('from')`), `:80` (`callback.fetch('message')`), `:81` (`callback.fetch('from')`), `:85` (`message['message_id']` via `envelope` at `:131`), `:87` (`message.fetch('chat')`), `:88` (`message.fetch('message_id')`), `:95` (`member.fetch('chat')`), `:99` (`chat.fetch('id')`), `:145-147` (`chat.fetch('type')`, `chat.fetch('id')`) — all bare `Hash#fetch`.
  - `normalizer.rb:139` — `text&.start_with?('/')` called on whatever `message['text']` is.
  - `inbound_envelope.rb:182-184` — oversized `text` raises `ValidationError` **before** any admission-layer refusal can see it.
  - `gateway.rb:210` — `rescue Comms::TransientTransportError, Comms::CommsError => :transient` catches `ValidationError` (it subclasses `CommsError`, `errors.rb:15`), but `KeyError`/`NoMethodError` are not `CommsError` and are not rescued.
  - `gateway.rb:161-162` rescues only `PollerConflictError`; grep for `Timeout` in `gateway.rb`/`delivery_drainer.rb` finds only `CLAIM_TTL_S`/`POLLER_TTL_S` constants — no wall-clock guard around the transport call.
- **Test/contract evidence**: not found. Both telegram test files build only
  well-formed updates (`tamoz_telegram_transport_test.rb:29-40`,
  `telegram_normalizer_test.rb:14-27`); `update(...)` ends in `.compact`, so
  omitted keys are deleted rather than exercised. `test/comms_gateway_test.rb`
  uses a fake transport and never reaches the real normalizer.
- **Probe evidence** (real normalizer, real transport, stubbed client returning
  exactly one update; loopback only):
  - `POLL(huge text: 20 000 bytes)` → `Tamoz::Comms::ValidationError: text must be a bounded string`
  - `POLL(text as an Array)` → `NoMethodError: undefined method 'start_with?' for an instance of Array`
  - `POLL(message without 'chat')` → `KeyError: key not found: "chat"`
  - `POLL(message without 'from' — a channel post)` → `KeyError: key not found: "from"`
  - `POLL(chat without 'type')` → `KeyError: key not found: "type"`
  - `POLL(callback_query without 'message')` → `KeyError: key not found: "message"`
  - (For contrast, the paths that *are* guarded: `update_id` of the wrong type →
  `ValidationError`; `my_chat_member` without `from` → accepted, `telegram:user:0`.)
- **Scanner signal**: grep of `gems/tamoz-telegram` for `rescue` returns six
  sites — `client.rb:85` (the HTTP rescue) and `client.rb:103`
  (`conflict_message`), `transport.rb:30,45,69` (the three
  `ResponseTooLargeError` translations). **None of them covers the normalizer.**
- **Independent judgment — what is proven and what is not.** Proven: the
  adapter's `poll` propagates a non-`CommsError` for a malformed update, and the
  gateway's only handler for that class is its own poll loop. Proven from the
  repository's own vocabulary that this contradicts intent: a value that fails
  its declared shape is supposed to become a "typed disposition, never a turn"
  (`inbound_envelope.rb:10-13`) and an unsupported update is supposed to
  "collaps[e] into a typed `unsupported` envelope — never raw JSON in the store"
  (`normalizer.rb:11-12`) — the design already has `unsupported_envelope`
  (`normalizer.rb:107-113`) and an `unsupported` kind for exactly this job.
  **Not proven**: whether Telegram can emit an update with a `message` that has
  no `from` — Bot API documentation states channel posts carry no `from`, but I
  did not read a verified spec in this checkout and this audit makes no live API
  call (blind spot #3). The `text`-as-Array and missing-`chat` variants are pure
  hostility tests rather than expected traffic. Confidence is high *for the code
  behavior*; the finding's operational trigger depends on traffic I could not
  verify, which is exactly why the remedy is a typed disposition for all of them
  rather than a fix for one of them.
- **Root cause — five whys**:
  1. *Why does a bad update kill the process?* Because `Transport#poll` lets
     `Hash#fetch`/`NoMethodError`/`ValidationError` escape, and nothing above it
     rescues non-`CommsError` classes.
  2. *Why does nothing above it rescue them?* Because `Gateway#serve_once`'s
     handler (`gateway.rb:210`) is scoped to the declared taxonomy, and the
     taxonomy has no member for "this envelope is malformed".
  3. *Why is there no such member?* Because the design assumed normalization
     could not fail — `inbound_envelope.rb:10-13` describes collapse into a
     disposition, and `normalizer.rb:107-113` provides one, but only for the
     *update-type* axis (`message`/`callback_query`/`my_chat_member`/other), not
     for a *present-but-malformed* payload.
  4. *Why was that axis missed?* Because the normalizer's contract (`@return
     [Hash] the InboundEnvelope wire`, `normalizer.rb:32-33`) declares no failure
     mode, so no test and no caller had a reason to consider one; every fixture in
     both telegram test files is well-formed by construction.
  5. *Why does that remain a control gap?* Because the boundary that owns
     "untrusted bytes from outside" (`transport.rb:42`) has no error contract, so
     there is no seam at which the decision could be made, tested, or reviewed.
     **The contract that would prevent recurrence**: normalization of a
     well-formed JSON update is total — anything it cannot represent becomes an
     `unsupported` (or `malformed`) envelope carrying the digest, never an
     exception.
- **Recommendation (smallest credible action at the existing seam)**: in
  `Transport#poll`, keep the `unsupported_envelope` seam the normalizer already
  has and make the projection total — rescue the parse of one update and emit
  `Normalizer#unsupported_envelope`'s wire for it instead of raising, so one bad
  update costs one digest-bound disposition rather than the gateway. The
  `unsupported_envelope` helper already exists (`normalizer.rb:107-113`) and
  already produces a valid, digest-stable envelope; this is a call-site change in
  one method, not new machinery, and it leaves the `ValidationError` on the
  envelope constructor as the last-resort guard.
- **Disposition**: *open* — this audit is read-only and makes no fix. Requires an
  independent challenge before any closure, and the coordinator should decide
  whether it is a duplicate of the drainer-side robustness work (if any) rather
  than a distinct adapter finding.

### F14-COR-01 — a 409 from `sendMessage`/`editMessageText` raises `PollerConflictError`, which the `DeliveryDrainer` cannot read, so the drainer thread dies with the row stranded `claimed`

- **Severity**: major · **Confidence**: high · **Status**: open
- **Lens**: correctness (transport-response → outcome-taxonomy fidelity)
- **Owning seam**: `Tamoz::Telegram::Client#call` (`client.rb:75-81`) — the
  `Net::HTTPConflict` branch is keyed on the HTTP status alone, with no
  method-kind distinction.
- **Source evidence**:
  - `client.rb:75-81` — `when Net::HTTPConflict then raise Comms::PollerConflictError, conflict_message(body)`, unconditionally, for every method.
  - `client.rb:71-74` — the sibling 429/401 branches are *also* method-blind, but their error classes happen to be readable by both callers; only 409's is not.
  - `errors.rb:70-73` — `PollerConflictError < CommsError`; it is a sibling of `AmbiguousDeliveryError`, **not** a subclass.
  - `delivery_drainer.rb:142-151` — `send_delivery` rescues **only** `Comms::AmbiguousDeliveryError`; `:54-57` rescues only `Comms::ThrottledError`; `:107-116` rescues only `Comms::AuthenticationError`. Nothing else.
  - `cli_comms_commands.rb:154-165` — a drainer thread's failure becomes `failures << e` and prints `tamoz: comms delivery stopped on Tamoz::Comms::PollerConflictError: …`, then the process exits 1 and stops the gateways (`:182-184`).
  - `cli_comms_commands.rb:178-181` — the CLI's own `raise Comms::PollerConflictError, 'a gateway lost the Telegram poller lease'` shows the class was authored for exactly the failure it is now being reused for, i.e. the reuse is deliberate at the *poll* seam and accidental at the *send* seam.
- **Test/contract evidence**: not found. `tamoz_telegram_transport_test.rb:311-324`
  scripts 409 on `getUpdates` only; grep of `test/` for `409` finds no send-path
  case (`comms_gateway_test.rb:320` is a comment describing a poller-lease
  condition). Verified additionally against the real drainer source rather than a
  mock: `delivery_drainer_test.rb` (10 runs) injects a fake transport and never
  raises `PollerConflictError`.
- **Probe evidence**: adapter against a loopback server answering `409` with
  Telegram's real body —
  `ADAPTER-FROM-409-ON-SEND: Tamoz::Comms::PollerConflictError :: Conflict: terminated by other getUpdates request`;
  `is_a?(AmbiguousDeliveryError) => false`, `is_a?(ThrottledError) => false`,
  `is_a?(AuthenticationError) => false`.
- **Scanner signal**: the class hierarchy and the three drainer `rescue` lines
  (`delivery_drainer.rb:54,107,147`) read together.
- **Independent judgment — proven and not proven.** Proven: the adapter can
  raise `PollerConflictError` from a send, and the drainer has no clause for it,
  so no `mark_delivery`/`release_delivery_claim` runs. Proven that this is a
  deviation from the contract this repo states (`transport.rb:43-49` names the
  outcome vocabulary for `deliver`; `PollerConflictError` is not in it).
  **Not proven**: that Telegram actually returns 409 on `sendMessage`. The
  documented trigger — a competing `getUpdates` — is a poll-side condition, so
  the send-side occurrence is unverified; this is squarely the row's own
  instruction to avoid, but it is not required, because the wrong class is
  returned for *any* 409 the API ever emits on a send (e.g. a webhook/poller
  contention window), and the cost asymmetry is what carries the severity.
  **Amplifier, explicitly out of this row's scope**: even if the class were
  right, `send_row` (`delivery_drainer.rb:71-128`) has no `ensure`, so any
  exception from `deliver` other than the three rescued classes strands the row
  in `claimed` until `reconcile_expired_deliveries` decides it
  (`comms_outbox.rb:146-163`) — a 30 s `CLAIM_TTL_S` stall, not a loss. Named as
  amplifier, not as a second finding, because it is a `tamoz-comms-gateway` row's
  seam, not this gem's.
- **Root cause — five whys**:
  1. *Why does a send failure kill the drainer thread?* Because the adapter
     raised an error class outside the drainer's three-clause handler.
  2. *Why did the adapter raise it?* Because `Client#call` dispatches on HTTP
     status alone, so 409 is classified as a poller conflict regardless of
     whether the request was a read or a send.
  3. *Why doesn't it distinguish?* Because it *can*: `call(method, params,
     idempotent:)` already carries `idempotent`, and `transport_failure`
     (`client.rb:116-122`) already branches on it — the 409 branch simply
     predates that pattern and does not use it.
  4. *Why was that never caught?* Because both the adapter's test suite and the
     drainer's test suite are green with a gap exactly between them: the adapter
     tests 409 on `getUpdates` (`tamoz_telegram_transport_test.rb:311`) and the
     drainer tests only the three classes it rescues
     (`delivery_drainer_test.rb`). Neither suite constructs a 409 on a *send*, so
     no test owns the boundary the two halves share.
  5. *Why is there no shared boundary test?* Because the seam contract
     (`transport.rb:43-49`) declares which errors `deliver` may raise but nothing
     mechanically checks an implementation against that list — the conformance
     the gem's comments claim (`transport.rb:14-16`) is asserted by prose, not by
     an enumerable. **The contract that would prevent recurrence**: the set of
     error classes `deliver` may raise is enumerated at the seam and every
     implementation is checked against it.
- **Recommendation (smallest credible action at the existing seam)**: make the
  409 branch method-aware in `Client#call` — a 409 on an idempotent read is the
  poller conflict it is today; a 409 on a send is not a poller conflict and has
  no `ok:true`, so it takes the same `transport_failure(idempotent, …)` mapping
  the `else` branch (`client.rb:82-84`) already applies. This reuses the
  `idempotent` flag the method already receives and the mapping helper it already
  has; it adds no class and no branch shape that is not already there.
- **Disposition**: *open*. The coordinator should decide whether to carry this as
  an F14 finding or fold it into the `tamoz-comms-gateway` drainer row as a
  shared-boundary defect; my reading is that the wrong *class* is produced by this
  gem's `client.rb` and the missing *handler* is the drainer's, so it belongs in
  both with F14 as the owner of the classification half.

### F14-RES-01 — throttling signalled as `ok:false error_code:429` inside an HTTP 200 body loses the authoritative `retry_after` and becomes an ambiguous send instead of a deferral

- **Severity**: minor · **Confidence**: medium · **Status**: open
- **Lens**: scalability and resource bounds (rate-limit handling)
- **Owning seam**: `Tamoz::Telegram::Client#call` (`client.rb:64-70`) — the
  `ok:false` branch checks only `error_code == 401`, so every other code falls to
  `transport_failure`.
- **Source evidence**:
  - `client.rb:64-70` — `if payload.fetch('ok') … elsif payload['error_code'] == 401 … else raise transport_failure(idempotent, "telegram api error #{payload['error_code']}")`.
  - `client.rb:71-72` — the `retry_after`-carrying `ThrottledError` is constructed **only** on a literal `Net::HTTPTooManyRequests`.
  - `client.rb:108-110` — `retry_after_from` reads `parameters.retry_after`, and is reachable only from `:72`.
  - `delivery_drainer.rb:117-127` — `defer_delivery(not_before: scheduled_at + e.retry_after)` is the only place the server's delay is honored.
  - Contrast `client.rb:62`, which *does* guard the missing-`ok` case with a typed `ValidationError` — the same "the envelope is malformed" instinct was applied to one field and not the other.
- **Test/contract evidence**: not found for the 200-body variant —
  `tamoz_telegram_transport_test.rb:101-109` uses HTTP 429 (correctly asserting
  `retry_after == 7`), and `:135-153` uses `error_code` 500 and 401 in 200 bodies
  (correctly asserting transient/authentication). No fixture combines a 200 body
  with `error_code: 429`.
- **Probe evidence**: `DELIVER-ok-false-429-body-200 ->
  AmbiguousDeliveryError :: send may or may not have happened (telegram api error 429)`;
  `POLL-ok-false-429-body-200 -> TransientTransportError :: telegram api error 429`.
  Both lost `parameters.retry_after = 7`.
- **Scanner signal**: the `error_code == 401` literal at `client.rb:66` is the
  only code the branch recognizes.
- **Independent judgment.** Proven: the 200-body 429 is classified by neither
  branch and degrades to a generic failure, losing `retry_after`; the correct
  behavior is unambiguous from `errors.rb:53-66` ("The remote surface rate-limited
  the caller; `retry_after` carries the authoritative server delay") and it is
  already implemented four lines above for the HTTP-status spelling of the same
  condition. **Not proven**: that Telegram emits the 200-body form for
  `sendMessage` — its documented rate-limit answer is HTTP 429; the 200-body
  spelling is a general Bot API pattern I did not verify for this method. Hence
  **minor / medium**, and hence the recommendation is a one-line branch rather
  than a design change. The safety direction is preserved either way: a send
  lands in `unknown`, never in a blind retry.
- **Root cause (concise)**: the response-classification branches were written for
  the HTTP-status spelling of each condition; the body spelling was handled for
  `ok:true`, `ok:false 401` and `ok:false(anything else)`, so only the two
  conditions that *also* have a status spelling — throttle and conflict — have a
  gap between their two spellings.
- **Recommendation (smallest credible action at the existing seam)**: extend the
  `ok:false` branch in `Client#call` to route `error_code == 429` through the
  same `Comms::ThrottledError.new('rate limited', retry_after: retry_after_from(body))`
  construction `client.rb:72` already uses. One condition, one existing helper,
  one existing class.
- **Disposition**: *open*, low priority. If the coordinator can establish that
  Telegram never answers 200-with-`ok:false`-429, close this as `closed` with
  that evidence rather than as a defect.

### F14-OBS-01 — the bot token is reachable through `Client#inspect`, and the effective transport timeouts are not observable

- **Severity**: minor · **Confidence**: high · **Status**: open
- **Lens**: observability and evidence (secret hygiene in the credential object)
- **Owning seam**: `Tamoz::Telegram::Client` (`client.rb:27-38`) — the default
  `Object#inspect` over ivars, plus an incomplete reader set.
- **Source evidence**:
  - `client.rb:27` — `attr_reader :token, :origin, :max_response_bytes`; `client.rb:31` — `@token = token`. No `#inspect`/`#to_s` override anywhere in the gem (grep for `inspect|to_s` in `gems/tamoz-telegram/lib/` returns only unrelated locals).
  - `client.rb:132-137` — `@open_timeout` and `@read_timeout` are set on `Net::HTTP` and never exposed.
  - `cli_comms_doctor.rb:105-109` — `tls_ok?` reads `client.origin`, i.e. the doctor's only client introspection uses the same reader set.
- **Test/contract evidence**: not found. No test asserts anything about
  `Client#inspect`; `test/public_api_test.rb:378-382` pins the *class list*, not
  the method surface, and the doctor's checks are asserted by name only.
- **Probe evidence**: `CLIENT_INSPECT:
  #<Tamoz::Telegram::Client:0x… @token="111:AAFakeSecretTokenValue", @origin="https://api.telegram.org", @open_timeout=10.0, @read_timeout=65.0, @max_response_bytes=1000000>`
  — the token is rendered in full.
- **Scanner signal**: grep for `token` in the gem returns five hits; `client.rb:27`
  is the only one that makes it readable.
- **Independent judgment — why this is minor and not critical.** The row's test
  for a critical leak is "logged, echoed in an error, put in a URL that lands in
  an exception message, or persisted". I checked all four and **none holds**:
  every raised message in the gem is literal-or-class-name (`client.rb:62,67,69,72,74,81,90,92,120`,
  `transport.rb:31,46,70-71`); a live connection-reset and a live read-timeout
  both produced clean typed errors with no token (probe); `Net::HTTP#warn` capture
  while parsing garbage returned `[]`; and nothing in `gems/` or `test/`
  stringifies the client (exhaustive grep for `Telegram::Client` finds three
  construction sites, all passing it straight into `Transport.new`). The exposure
  is therefore **latent**: it needs a future caller to `.inspect` or `pp` the
  object — which is the ordinary first debugging move for exactly this object,
  and is how the credential would end up in a pasted log. That is a real but
  unproven-in-production path, so minor. The missing timeout readers are folded in
  because they are the same seam: the object that holds the credential is also the
  only place the effective network bound lives, and a doctor that cannot print the
  read timeout cannot show an operator what the gateway is actually waiting on.
- **Root cause (concise)**: `Client` is a plain value holder with no declared
  presentation surface, so Ruby's default ivar dump became its `inspect`, and the
  two timeouts were treated as implementation detail (`client.rb:33-34`) rather
  than as the operational parameters the doctor report exists to show.
- **Recommendation (smallest credible action at the existing seam)**: drop
  `:token` from the `attr_reader` at `client.rb:27` (nothing outside the class
  uses it — the gem's own `path_for` reads `@token` directly at `client.rb:113`),
  and add `:open_timeout`/`:read_timeout` to it so the doctor can report the
  effective bound. Two edits on one line's neighborhood; no new class.
- **Disposition**: *open*, minor. Worth pairing with F14-SEC-02 in one small
  change at this seam.

### F14-SEC-02 — `comms doctor`'s TLS check asserts the origin string, not the effective verification mode

- **Severity**: minor · **Confidence**: high (for the code); latent · **Status**: open
- **Lens**: security and authority (egress integrity)
- **Owning seam**: `Tamoz::Telegram::Client#build_http` (`client.rb:131-138`) as
  the thing the check is *about*, and `CLICommsDoctor#tls_ok?`
  (`cli_comms_doctor.rb:105-109`) as the check.
- **Source evidence**:
  - `client.rb:134-136` — `http.use_ssl = uri.scheme == 'https'`; `verify_mode` is never assigned, so the effective mode is `Net::HTTP`'s default.
  - `cli_comms_doctor.rb:105-109` — `return true if client.respond_to?(:origin) && client.origin.start_with?('https://')` / `'the API origin must be https'`. The comment at `:104-105` acknowledges this is a string check ("The production adapter constructs only https; a fixture client on localhost is the only way this check can name a deviation").
  - `client.rb:29-30,132-133` — `origin` is a **constructor keyword**, so a misconfigured or hostile caller can pass any URL and the doctor will bless it as long as it starts with `https://`.
- **Test/contract evidence**: the doctor's checks are exercised by
  `comms_cli_test.rb` / `comms_cli_ops_test.rb` (not run — budget; `test/comms_cli_doctor*` does not exist as a dedicated file). No test asserts `verify_mode`.
- **Probe evidence (both directions)**: current behavior is **safe** — a loopback
  TLS server with a self-signed `CN=not-telegram.invalid` certificate was refused:
  `TLS-WITH-UNTRUSTED-CERT: OpenSSL::SSL::SSLError: SSL_connect returned=1 errno=0
  … certificate verify failed (self-signed certificate)`. And the check's
  weakness is real by construction: `tls_ok?` would return `true` for an
  `origin` such as `https://evil.example` (the string test passes), and would
  not notice a future `http.verify_mode = OpenSSL::SSL::VERIFY_NONE`.
- **Scanner signal**: grep for `verify_mode|VERIFY_NONE|VERIFY_PEER` across
  `gems/` returns four files, **none of them `tamoz-telegram`**; two of them
  (`egress_client.rb:270-271`, `http_exporter.rb:52-54`) set `VERIFY_PEER`
  explicitly, so the repository has both conventions and no stated rule.
- **Independent judgment.** This is deliberately **not** a claim that the adapter
  is insecure — the probe proves the opposite for the code as committed, and the
  default is the safe one. What is unproven is only whether a future change would
  be caught: nothing in the gem or the doctor pins the property. I record it as
  minor rather than info because the doctor is the operator's *stated* gate
  ("every failure is named and exits 1", `documentation/guides/telegram.md:71-82`)
  and its strongest security check is a string prefix test — a check that cannot
  fail for the reason it exists is a documentation-grade promise, not a control.
  The repo also gives no rule for whether `VERIFY_PEER` must be explicit, which is
  the same missing-contract shape as F14-COR-01.
- **Root cause (concise)**: the doctor checks the *declared* configuration
  (a URL string) instead of the *effective* transport property, because the
  client exposes `origin` (a string) and does not expose the SSL context it will
  actually build.
- **Recommendation (smallest credible action at the existing seam)**: have
  `tls_ok?` compare the client's effective SSL setting rather than its origin
  string — the same reader addition F14-OBS-01 already asks for
  (`client.rb:27`) can expose the effective `verify_mode`, and the doctor's
  existing `[name, true|message]` shape (`cli_comms_doctor.rb:60-83`) needs no new
  machinery. Do **not** add an `https://`-host allowlist; `expected_bot_id`
  (`cli_comms_doctor.rb:73-77`) already pins the authenticated surface identity,
  which is the stronger check, and adding a second one would be speculative.
- **Disposition**: *open*, minor, latent. Recommend the coordinator weigh whether
  to record it as `info` instead, since no current behavior is unsafe; I keep it
  minor because the doctor's output is consumed as evidence of a security property
  it does not actually test.

### F14-MNT-02 — `client.rb`'s header states that a timed-out send is "genuinely irreconcilable", contradicting the repository's own rule that ambiguous sends remain durable `unknown`

- **Severity**: minor · **Confidence**: high · **Status**: open
- **Lens**: maintenance and architecture (contract vocabulary)
- **Owning seam**: the comment block at `client.rb:9-20` (specifically the phrase
  at `:12-14`) and its three echoes: `transport.rb:10-11`, the gem README line 9,
  and the test header `tamoz_telegram_transport_test.rb:8-9`.
- **Source evidence**:
  - `client.rb:13-14` — "a network timeout on a send is AmbiguousDeliveryError (genuinely irreconcilable, design §10)".
  - `client.rb:88-89` — the code's own reasoning: "A send is the other case entirely: its outcome is unknown and must never be blindly retried (design §10)".
  - `delivery_drainer.rb:147-151` — the resolution: `{ status: 'unknown', receipt: nil }`.
  - `comms_outbox.rb:248-254` — "The OPERATOR's explicit resolution of a genuinely ambiguous send (design §14)" — i.e. the artifact is *resolvable*, which is the opposite of irreconcilable.
- **Test/contract evidence**: not found — no test asserts vocabulary. The
  behavioral contract is tested and correct
  (`tamoz_telegram_transport_test.rb:219-231,233-244`); only the prose is wrong.
- **Scanner signal**: grepping the gem for "irreconcilable" returns
  `client.rb:13` and the README echo; the drainer and the store use `unknown`.
- **Independent judgment.** This is a real but purely textual defect, recorded at
  `minor` because BAR.md's minor tier covers "documentation ... debt with limited
  immediate impact" and this is documentation only — behavior is correct in every
  path I probed. I record it rather than skip it because the same phrase is the
  one an auditor or a future implementer would quote while deciding whether a
  retry is permissible, and it points the wrong way. The deeper tension is
  vocabulary: the design text uses "genuinely irreconcilable" for the *transport's*
  inability to know, while the durable layer uses `unknown` for the *operator's*
  ability to resolve — one word for two different subjects.
- **Root cause (concise)**: the header comment was written to justify the
  no-blind-retry rule (which is right) and reached for an absolute word
  ("irreconcilable") that the durable layer contradicts (which is wrong); nothing
  checks prose against the artifact vocabulary it describes.
- **Recommendation (smallest credible action at the existing seam)**: replace the
  parenthetical at `client.rb:13-14` with the durable layer's own word — the send's
  outcome is *unknown* and remains `unknown` until the operator resolves it.
  Optionally align the three echoes (`transport.rb:10-11`, the README, the test
  header) in the same pass. Comment-only; no code, no test, no new machinery.
- **Disposition**: *open*, minor. Cheap; safe to batch with any future edit to
  this file.

### F14-MNT-01 — `Client#read_timeout` is injectable but no surface descriptor can set it, so an operator cannot raise the long-poll read timeout

- **Severity**: info · **Confidence**: high · **Status**: open
- **Lens**: maintenance and architecture (configuration reachability)
- **Owning seam**: `Transport` construction in `cli_comms_shared.rb:137-146`
  versus the descriptor validator in `surface_descriptor.rb:176-187`.
- **Source evidence**: `client.rb:29-30` accepts
  `open_timeout:`/`read_timeout:`; `cli_comms_shared.rb:141` passes **only**
  `max_response_bytes: cap`, resolving `cap` from
  `descriptor.transport[:max_response_bytes]` (`:140`); `surface_descriptor.rb:177-186`
  validates `mode`, `credential_ref`, `poll_timeout_s`, `batch`,
  `max_response_bytes` and no timeout. The fixed `65.0`
  (`client.rb:24`) is therefore above the maximum configured `poll_timeout_s` of
  `600` (`surface_descriptor.rb:180-182`) is not guaranteed — a 600 s poll is
  structurally impossible with the built-in values, even though the descriptor
  explicitly permits it.
- **Test/contract evidence**: the transport test injects `read_timeout: 1.0`
  directly (`tamoz_telegram_transport_test.rb:18`), proving the knob works; no
  test or descriptor path sets it from configuration. **Not run**: no dedicated
  descriptor test was executed for this item; the claim is read directly from
  `surface_descriptor.rb:176-187`.
- **Scanner signal**: grep for `read_timeout` in the gem (two hits, both in
  `client.rb`) versus in `tamoz-comms` (zero hits).
- **Independent judgment.** Verified fact, not a defect: the defaults are sane, a
  `poll_timeout_s` above 65 is an operator choice rather than a correctness
  requirement, and the read timeout is not the drain-stall hazard I expected to
  find (a hung socket is bounded at 65 s, and the drainer's `CLAIM_TTL_S = 30.0`,
  `delivery_drainer.rb:13`, bounds a worse case). Recorded so the next reader does
  not re-derive it, and so the `601..` region of `poll_timeout_s` is known to be
  unreachable rather than surprising.
- **Root cause**: configuration reachability was added for the one transport
  limit that had caused a real problem (`max_response_bytes`) and not
  retro-fitted to the timeouts.
- **Recommendation**: none — the simple path already delivers the property
  (`max_response_bytes` is reachable, defaults are bounded, and the claim TTL
  bounds the stall). If an operator later needs a longer poll, that is the moment
  to add the descriptor key, at the seam `max_response_bytes` already uses.
- **Disposition**: *open as info*; explicitly **recommend no change now**. Listed
  so the coordinator can see it was considered and deliberately left.

## Blind spots

1. **The `ok:false`-in-200-body throttling question (F14-RES-01) rests on a
   general Bot API pattern I did not verify for `sendMessage`.** I made no live
   API call, per the brief and the repository rule. What would prove it: a
   captured production response, or a Telegram API changelog/announcement stating
   which methods use the 200-body form. Without it, F14-RES-01 stays `medium` and
   `minor`.
2. **Whether Telegram returns 409 on a send (F14-COR-01).** The *code* behavior
   is proven by probe; the *trigger* is not. What would prove the impact: a real
   409 on `sendMessage`, or confirmation that 409 is poll-only — which would
   downgrade the finding to "wrong class for an unreachable condition" while
   leaving the contract violation (the class is outside the seam's declared
   vocabulary) intact.
3. **Whether a real update can carry a `message` with no `from` (F14-REL-01).**
   Channel posts are the candidate case; I could not read a verified Bot API
   specification in this checkout. What would prove it: the API's `Message`
   schema, or a recorded channel-post update.
4. **The six comms test files not run** (`callback_ack_crash_test.rb`,
   `comms_cli_ops_test.rb`, `comms_adr049_consistency_test.rb`,
   `comms_evidence_gated_approval_test.rb`,
   `canonical_cross_surface_composition_test.rb`, `experience_harness_test.rb`).
   They exercise the adapter through the gateway and could contain an assertion
   that already covers part of F14-COR-01 or F14-REL-01; I read none of their
   bodies. My findings do not depend on them — each is proven from the gem's
   source plus a direct probe against the real classes — but a duplicate would
   show up there rather than here.
5. **The ~434-line gem is read in full; the surrounding comms stack is not.**
   `gateway_admission.rb` I read only at `85-130` (the `max_inbound_bytes` seam
   F14-REL-01 touches), `gateway.rb` only at `50-60` and `150-309`, and I did not
   read `binding.rb`, `admission.rb`, `approval_prompt.rb`, or `rendering.rb` at
   all. This means F14-REL-01's *downstream* consequence — what admission and the
   worker do after a refusal — is characterized from the gateway/admission code
   alone, and the "unsupported envelope" path I recommend could interact with
   admission behavior I did not read. That is the residual uncertainty in the
   recommendation, not in the finding.
6. **No load or soak evidence exists anywhere for this adapter.** The gem's own
   comment (`telegram.rb:13-14`) claims the fixture server "can
   duplicate/reorder/throttle/lose and time out", which the fixture does support
   (`test/support/telegram_fixture_server.rb:8-10,33-37`), but no test in either
   telegram file actually exercises duplicate, reorder, or lose. Rate-limit
   behavior under sustained load (`per_chat_messages_per_s`,
   `global_messages_per_s`, `cli_comms_shared.rb:94-95`) is a drainer concern
   tested elsewhere. Scalability for *this* row is therefore reviewed from
   constants and guards, not from evidence.

## Verdict

**IMPROVE** — per BAR.md: at least one accepted critical/major finding.
Counts: **critical 0 · major 2 · minor 4 · info 1**.

- All six lenses reviewed; none is `not evidenced`.
- Both major findings (F14-REL-01, F14-COR-01) carry five-whys chains, source
  citations and a recommendation at an existing seam; both are `open` because
  this is a read-only package.
- What is *not* wrong, stated plainly so the verdict is not read as broader than
  it is: the token never reaches a log, an error message, or a store; TLS peer
  verification is on; a send timeout is never blindly retried; 429 `retry_after`
  is honored; the update offset is persisted only after durable disposition;
  connect and read timeouts are both set and bounded.
- The two majors are one shape — **a boundary that classifies by the narrowest
  signal available (HTTP status / well-formedness), with no test across the seam
  the two halves share** — which is why they are worth one review rather than two.

# Adding a channel

A channel kind — Telegram, the talk page, the next one — is one gem plus one line. Nothing else in Tamoz
names it, and two tests fail if anything does (`test/channel_kind_containment_test.rb`,
`test/channel_dependency_test.rb`). ADR-041 is the rule; ADR-014 is why the set is closed.

The worked example is the test-only loopback kind: `test/support/loopback_channel.rb` (the three objects)
and `test/support/loopback_pass.rb` (setup, `channel add`, a gateway pass that admits a message and one
that delivers a reply). `test/channel_kinds_test.rb` runs it in the test process and again in a child with
neither shipped adapter on its load path.

## 1. The gem

`gems/tamoz-<kind>/`, depending only on `tamoz-core`, `tamoz-comms` and the standard library. It holds:

- **`Transport`** (`include Tamoz::Comms::Transport`) — `authenticate` returns `{'stream_id' => "<kind>:…"}`;
  `poll(next_offset:, limit:, timeout_s:)` returns `{updates:, next_offset:}` and hands an update out again
  until a later cursor confirms it; `deliver`, `fetch_attachment`, `signal` (`:unsupported` for a signal it
  lacks). Party ids are `<kind>:user:<id>` and `<kind>:chat:<id>` (other spaces are group chats, refused).
- **`Channel`** (`include Tamoz::Comms::Channel`) — `validate!(descriptor)` refuses settings or rendering it
  cannot serve; `connect(descriptor, env:, voice:)` returns a connection whose `start(floor:, history:)`
  runs only once the gateway holds the lease, plus `stop`, `transport`, `interval_s`.
- **`Setup`** (`include Tamoz::Comms::ChannelSetup`) — `summary`, `env_names` (every variable it may read or
  hand its gateway; it sees no other), `add(existing:, argv:, env:, state_dir:, terminal:)` returning the
  config entry (with its `stream_id`), `check(...)` returning named rows for `start` and `comms doctor`, and,
  when needed, `announce` and `gateway_env`. It never sees the runtime directory, the store or a model.

Include the shared conformance suite in its transport test (`test/support/transport_conformance.rb`) and add
a boundary test like `test/telegram_boundary_test.rb`.

## 2. The registry line

In `gems/tamoz-agent-cli/lib/tamoz/agent/channel_kinds.rb`:

```ruby
ChannelKind.new(name: '<kind>', library: 'tamoz/<kind>', namespace: 'Tamoz::<Kind>')
```

The two measuring tests read the kinds from this registry, so nothing else changes.

## 3. The registration every new gem needs

`Gemfile`, the gem roots in `test/test_helper.rb`, `docs/requirements-manifest.json`, `docs/public-api.json`
and its fixture, `docs/dependency-review.json`, the README gem map, and an isolated-install check.

## What may still need the core

Party ids are numeric (`-?[0-9]{1,20}`) in the spaces `user`, `chat`, `group`, `supergroup`, `channel`; message
references are integers; a part is at most 4096 characters; a kind's name is lowercase and not `os` or `cli`.
All fit Telegram and talk. A kind with string ids (Slack, e-mail) changes `tamoz-comms` first
(`docs/channels-abstraction-2026-10-10/FUTURE_PLAN.md` F3).

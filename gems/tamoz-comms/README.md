# tamoz-comms

Communication channels for Tamoz (ADR-041). One contract gem owning the
channel vocabulary and seams:

- values — `SurfaceDescriptor`, `InboundEnvelope`, `Delivery`, `DecisionRecord`
- identity and admission policy (allowlist / pairing)
- rendering (plain / restricted HTML)
- the interfaces a channel kind implements: `Transport`, `Channel` (runtime) and
  `ChannelSetup` (operator)
- the grammar every kind follows: party ids `<kind>:user:<id>` and
  `<kind>:<space>:<id>`, an update stream `<kind>:…`
- the structural `CommsStore` and `DecisionStore` contracts

Each kind ships as its own adapter gem (`tamoz-telegram`, `tamoz-talk`) holding all
of its code, and passes the shared transport conformance suite
(`test/support/transport_conformance.rb`); the CLI reaches kinds through one
closed registry. To add one, see `documentation/guides/adding-a-channel.md`. The channel gateway is a separate
process (ADR-042) and never loads a model; the worker integrates through one
nil-safe `DeliverySink` seam and never makes a channel network call.

## Example

```ruby
require "tamoz/comms"

record = Tamoz::Comms::DecisionRecord.build(
  thread_id: "telegram.ops.abc123", occurrence_id: "req-1",
  interrupts: [{task_id: "check", call_index: 0, descriptor: {"kind" => "approve_tool"}}],
  direction: :deny, actor_kind: "os_user", actor_id: "1000", source: "cli"
)

record.granted?   # => false
record.denied?    # => true
record.resume_request_id  # => "decision-<64-char hex>"
```

## Scope

This gem depends only on `tamoz-core` and never opens a socket. The bot token
never crosses into the worker process; the durable stores live in
`tamoz-sqlite` under the structural contracts defined here.

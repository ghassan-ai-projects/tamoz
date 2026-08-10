# tamoz-comms

Communication channels for Tamoz (ADR-041). One contract gem owning the
channel vocabulary and seams:

- values — `SurfaceDescriptor`, `InboundEnvelope`, `Delivery`, `DecisionRecord`
- identity and admission policy (allowlist / pairing)
- rendering (plain / restricted HTML)
- the `Transport` adapter seam
- the structural `CommsStore` and `DecisionStore` contracts

Transports ship as separate adapter gems (`tamoz-telegram` first) that must
pass the `tamoz-comms` conformance suite. The channel gateway is a separate
process (ADR-042) and never loads a model; the worker integrates through one
nil-safe `DeliverySink` seam and never makes a channel network call.

## Example

```ruby
require "tamoz/comms"

record = Tamoz::Comms::DecisionRecord.build(
  thread_id: "tg.ops.abc123", occurrence_id: "req-1",
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

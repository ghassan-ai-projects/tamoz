# tamoz-stream

Streaming input and simulated physical-world assistance for Tamoz: validated
channel/event/Situation values, the structural `StreamStore` contract, and the
production `ChannelConnector`/`SourceSession` seam that a real broker/device
adapter will implement. The SQLite store lives in `tamoz-sqlite`.

```ruby
require "tamoz/stream"

channel = Tamoz::Stream::ChannelDescriptor.new(
  channel_id: "factory-1.temperature", revision: 1, transport: "mqtt",
  source_identity: "sensor-ca:device-428", schema: "temperature.v2",
  partition_by: %w[tenant_id device_id],
  time: {"field" => "measured_at", "max_clock_skew_s" => 30},
  units: {"value" => "Cel"}
)

clock = Tamoz::Stream::ReplayClock.new(start: 1_700_000_000)
store.admit(envelope, clock:) # => {"outcome" => "admitted", ...}
```

## v1 scope

- One authenticated READ-ONLY source (simulated fixture in the test tree
  implements the production connector contract) → deterministic immutable
  Situations.
- No real physical actuator is connected without explicit owner approval; the
  ONLY effector is a simulator, reached through current-state policy and an
  independently controlled interlock (read-only `InterlockReader`).
- The connector zone never receives model/tool/effector credentials; replay
  workers resolve no credentials.

## The episode worker

`bin/tamoz-stream-worker` serves `agenticstream.runtime.v1.EpisodeWorker`
(`Handshake`, `Execute`) over a Unix socket (`--socket`) or, in development, a
TCP port (`--port`). Started with `--draft-model-policy ROLE` it also serves
`DraftPlaybookRule` and announces the handshake feature
`draft_playbook_rule`: `Tamoz::Stream::DraftRunner` admits one key and 1 to 20
verified cases of it, and answers with a typed proposal or a typed decline. A
proposal has no mode or activation; the stream owns both. See
[`documentation/design/streaming.md`](../../documentation/design/streaming.md).

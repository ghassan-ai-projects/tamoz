# tamoz-core

Shared values and dependency-light runtime protocols for Tamoz.

```ruby
require "tamoz/core"

context = Tamoz::Context.new(
  run_id: "run.1",
  execution_id: "execution.1",
  request_id: "request.1"
)

state = Tamoz::StateCodec.new.normalize(
  "status" => "planned",
  "steps" => [{"id" => "inspect"}]
)

results = Tamoz::Pool.for(:threads, size: 4).map(state.fetch("steps")) do |step|
  context.child(step.fetch("id")).check!
  step.fetch("id")
end
```

M1 includes explicit Context propagation, cooperative cancellation and monotonic deadlines,
versioned allowlisted state encoding, bounded execution streaming, safe instrumentation,
and ordered inline/thread execution. It contains no graph, persistence, provider, network,
or model behavior.

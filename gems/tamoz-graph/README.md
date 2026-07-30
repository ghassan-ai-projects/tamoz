# tamoz-graph

`tamoz-graph` is Tamoz's deterministic, bulk-synchronous graph runtime. M2 provides an
append-only in-memory checkpointer for proving graph semantics. It is not a crash-durable
store; durable leases, request deduplication, and effect journals begin in M3.

```ruby
require "tamoz/graph"

app = Tamoz.graph(name: "review", version: "1") do
  state :events, reduce: :append, default: []

  node :plan, ->(_state, _context) { {events: ["planned"]} },
       implementation_name: "review.plan", version: "1"

  edge Tamoz::START, :plan
  edge :plan, Tamoz::END
end.compile

result = app.invoke(
  {},
  thread: "review.1",
  request_id: "request.1",
  execution_id: "execution.1"
)
```

The same compiled graph supports ordered threaded execution, `Command`/`Send` routing,
worker-local interrupt/resume, failure retry, immutable history, reducer-mediated forks,
nested invocation-mode subgraphs, and bounded event streaming.

See `docs/M2.md` and `docs/M2_PLAN.md` in the repository for the implemented guarantees and
their evidence.

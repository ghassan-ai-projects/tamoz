# tamoz-concurrency

Thread execution machinery. Depends on `tamoz-core` (Clock, Configuration,
the error hierarchy) and `tamoz-cancellation` (the token every primitive
consumes).

## Public surface

- `Tamoz::Pool.for(:inline | :threads, ...)` — bounded parallel map with
  first-class cancellation and the stuck-worker circuit (`:fibers` stays a
  raising stub). Results are `Tamoz::TaskResult` values.
- `Tamoz::StreamSink` — the bounded, single-consumer stream that closes on
  cancellation.
- `Tamoz::Concurrency::EventStream` — a producer run in one coordinator thread
  over a sink, joined with a grace deadline; exactly one consumer.
- `Tamoz::Concurrency.join_all(threads, deadline:)` — join every thread within
  one shared monotonic budget.
- `Tamoz::Concurrency::VERSION`

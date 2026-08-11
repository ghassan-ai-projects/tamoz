# tamoz-observability

The observability signal plane for Tamoz. One contract gem owning:

- the closed, versioned `SignalCatalog` and its seeded `Catalog`
- `Correlation` — trace and span identity derived from durable turn identity
- `Signal` — one immutable value, three kinds (`:event`, `:span`, `:measurement`)
- the bounded `Recorder` implementations, content policy, local journal, metrics,
  trace projection, and model usage/cost values

## Example

```ruby
require "tamoz/observability"

Tamoz::Observability::Catalog.fetch("tamoz.model.call")
# => #<data Tamoz::Observability::SignalCatalog::Entry ...>

trace = Tamoz::Observability::Correlation.trace_id(
  thread_id: "thread.1", execution_id: "execution.1"
)
```

## Scope

This gem depends only on `tamoz-core` and never opens a socket. Its journal and
trace projection remain storage-neutral. Authoritative SQLite reconstruction and
durable model-usage persistence require separately authorized adapters; a minimal
boot loads no HTTP client and no exporter.

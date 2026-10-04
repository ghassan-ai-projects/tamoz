# tamoz-observability

The observability signal plane for Tamoz. One contract gem owning:

- the closed, versioned `SignalCatalog` and its seeded `Catalog`
- `Correlation` — trace and span identity derived from durable turn identity
- `Signal` — one immutable value, three kinds (`:event`, `:span`, `:measurement`)
- the bounded `Recorder` implementations, content policy, local journal, metrics,
  trace projection, and model usage/cost values
- `TelemetryReader` — the read-only contract a durable store implements
  (`Tamoz::SQLite::RecordReader` does, by duck type)
- read-only self-diagnosis over those records: `Diagnosis` (rules that are data,
  in `diagnosis/rules.yaml`), `Explanation` (one turn's decision record),
  `Timeline` and `Postmortem`. All are pure functions of rows; none can write,
  enqueue or call out

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

This gem depends only on `tamoz-core` and `tamoz-concurrency` and never opens a
socket. Its journal, trace projection and diagnosis remain storage-neutral: the
durable record is read through `TelemetryReader`, which
`Tamoz::SQLite::RecordReader` implements read-only. Durable model-usage
persistence is not built. A minimal boot loads no HTTP client and no exporter.

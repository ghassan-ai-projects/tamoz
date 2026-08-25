# Observability Clean-Code Refactor — Progress Bar

End-result checklist. One row per source file. Mark complete only when the file has been refactored, reviewed, and committed.

| File | Refactored | Reviewed | Committed | Notes |
|------|------------|----------|-----------|-------|
| `lib/tamoz/observability.rb` | n/a | done | n/a | bootstrap only; no change needed |
| `lib/tamoz/observability/recorders.rb` | done | done | done | Journal class is the largest target |
| `lib/tamoz/observability/model_call.rb` | n/a | done | n/a | small, clean; no change needed |
| `lib/tamoz/observability/usage.rb` | done | done | done | Data classes; extracted validators |
| `lib/tamoz/observability/signal_catalog.rb` | done | done | done | validate_signal / register are long |
| `lib/tamoz/observability/errors.rb` | n/a | done | n/a | exception classes, already minimal |
| `lib/tamoz/observability/catalog.rb` | n/a | done | n/a | data seeding; no change needed |
| `lib/tamoz/observability/version.rb` | n/a | done | n/a | constant only |
| `lib/tamoz/observability/trace.rb` | done | done | done | from_signals/from_documents duplication |
| `lib/tamoz/observability/telemetry_reader.rb` | n/a | done | n/a | contract only |
| `lib/tamoz/observability/signal.rb` | done | done | done | freeze_content is deep and nested |
| `lib/tamoz/observability/recorder.rb` | n/a | done | n/a | contract only |
| `lib/tamoz/observability/producer.rb` | done | done | done | around method mixes levels |
| `lib/tamoz/observability/notifier.rb` | done | done | done | decomposed instrument |
| `lib/tamoz/observability/metrics.rb` | done | done | done | add_signal/add_document duplication |
| `lib/tamoz/observability/exporter.rb` | n/a | done | n/a | contract only |
| `lib/tamoz/observability/correlation.rb` | n/a | done | n/a | small, already clean |
| `lib/tamoz/observability/content_policy.rb` | done | done | done | canonicalize is complex |

## Behavior-change log

Any behavioral change discovered or introduced is recorded here instead of being silently folded in.

| File | Change | Rationale | Status |
|------|--------|-----------|--------|
| none | - | - | - |

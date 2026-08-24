# Observability Clean-Code Refactor — Progress Bar

End-result checklist. One row per source file. Mark complete only when the file has been refactored, reviewed, and committed.

| File | Refactored | Reviewed | Committed | Notes |
|------|------------|----------|-----------|-------|
| `lib/tamoz/observability.rb` | - | - | - | bootstrap only; likely no change |
| `lib/tamoz/observability/recorders.rb` | done | done | done | Journal class is the largest target |
| `lib/tamoz/observability/model_call.rb` | - | - | - | small, clean |
| `lib/tamoz/observability/usage.rb` | - | - | - | Data classes |
| `lib/tamoz/observability/signal_catalog.rb` | done | done | done | validate_signal / register are long |
| `lib/tamoz/observability/errors.rb` | - | - | - | exception classes, already minimal |
| `lib/tamoz/observability/catalog.rb` | - | - | - | data seeding, may stay declarative |
| `lib/tamoz/observability/version.rb` | - | - | - | constant only |
| `lib/tamoz/observability/trace.rb` | done | done | done | from_signals/from_documents duplication |
| `lib/tamoz/observability/telemetry_reader.rb` | - | - | - | contract only |
| `lib/tamoz/observability/signal.rb` | done | done | done | freeze_content is deep and nested |
| `lib/tamoz/observability/recorder.rb` | - | - | - | contract only |
| `lib/tamoz/observability/producer.rb` | done | done | done | around method mixes levels |
| `lib/tamoz/observability/notifier.rb` | - | - | - | small |
| `lib/tamoz/observability/metrics.rb` | done | done | done | add_signal/add_document duplication |
| `lib/tamoz/observability/exporter.rb` | - | - | - | contract only |
| `lib/tamoz/observability/correlation.rb` | - | - | - | small, already clean |
| `lib/tamoz/observability/content_policy.rb` | done | done | done | canonicalize is complex |

## Behavior-change log

Any behavioral change discovered or introduced is recorded here instead of being silently folded in.

| File | Change | Rationale | Status |
|------|--------|-----------|--------|
| none yet | - | - | - |

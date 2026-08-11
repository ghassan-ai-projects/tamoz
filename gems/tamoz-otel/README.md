# tamoz-otel

The optional OTLP/HTTP egress for Tamoz. It depends on the signal-plane contract
and Ruby standard library net/http; it is never loaded by a minimal Tamoz boot.

The exporter refuses redirects, non-HTTPS endpoints, proxy environment variables,
private destinations (unless explicitly allowed), oversized batches, and unbounded
deadlines. Credentials are referenced by name and are never serialized into a
signal or diagnostic.

# `episode_model_transport.rb` slice note

## Scope

Only `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_transport.rb`
and this evidence note are writable in this slice. Existing worktree changes in
`TODO.md` and the other slice/review notes remain untouched.

No tests, lint, Enola, provider, or live commands are run in this
implementation lane.

## Reading-order defect

`EpisodeModelTransport#call` and `#call_via_gateway` each mix route-specific
request setup, shared HTTP mechanics, response status handling, and response
projection. The duplicated `Response.new` expression also hides the common
response contract. The transport still has a deliberate two-route security
boundary: direct mode may include the configured authorization header, while
gateway mode sends only the gateway envelope with its JSON content type.

## Selected concepts

- `post_completion_request(body, headers:)` owns only URI construction, the
  fixed completion path, `Net::HTTP` timeout/HTTPS setup, and the POST. It
  returns the raw HTTP response so each route retains its own status check and
  exact error message.
- `build_model_response(envelope_bytes)` owns the shared public `Response`
  projection. Its expression order remains `extract_content`, response digest,
  then `usage_from(extract_usage_hash(...))`.

The direct route retains its optional `Authorization` header construction. The
gateway route retains envelope construction, canonical fields, JCS bytes, and
its content-type-only headers. `call` keeps gateway selection as its first
branch, and both route-specific status checks remain before response parsing.

## Leave-stable surfaces

- `initialize` validation, endpoint normalization, stored provider/model/key,
  timeout value, gateway reference, and object freezing.
- `build_request`, `request_digest`, `settings_digest`, `OPENAI_COMPLETIONS_PATH`,
  `SETTINGS`, `Response`, and all public signatures.
- Gateway envelope extraction and fields: logical call id, frame digest,
  provider, model, settings digest, and request bytes.
- `extract_content`, `extract_usage_hash`, `usage_from`, and `integer_field`,
  including unavailable-usage semantics and error timing.
- `EpisodeModelCall#perform_call`, its journal boundary, response projection,
  receipt fields, and request/response/settings digests.
- Composition factories and logical-key precomputation in the crash/replay
  tests; the local endpoint’s exact raw request/response digest observation;
  the gateway’s signed-record contract.

## Preservation record

- The endpoint remains `@endpoint + "/chat/completions"`; request body bytes
  and headers are passed unchanged, with direct authorization omission when the
  key is empty and no authorization in gateway mode.
- Read/open timeout values and HTTPS selection remain sourced from the same
  instance fields and URI scheme.
- Each route still converts the response body with `to_s`, checks success at
  the same route boundary, and raises the same `ProtocolError` class/message
  with the same truncated body.
- Successful responses still parse content before computing the response
  digest and then parse usage, returning the same `Response` shape and bytes.

## Evidence boundary

Read-only callers and contracts inspected: `EpisodeModelCall`, the kernel load
surface, `WitnessGateway`, `EpisodeComposition`, the crash/fixed-graph/real-
model/replay tests, and `LocalModelEndpoint`. No behavior-change proposal is
needed; the requested extractions are private and mechanical.

# `episode_model_call.rb` slice note

## Scope

This slice changes only `gems/tamoz-agent-kernel/lib/tamoz/agent/episode_model_call.rb`
and this evidence note. The target is compared with baseline
`7d8f470`. Existing worktree changes in `TODO.md` and
other slice notes are pre-existing and remain untouched.

## Reading-order defect

`EpisodeModelCall#call` mixes three levels in one method: canonical request and logical
identity setup, the durable journal dispatch contract, and status-to-result projection.
The request construction and `LogicalCallKey` identity are already the correct seam and
remain inline. The durable `EffectDispatcher.run` metadata/block is a coherent
`journal_episode_model_call` concept, while the `case outcome.status` is a coherent
`result_for_effect_outcome` concept. Naming those two decisions leaves `call` as the
domain workflow: prepare the model request, journal the episode call, and map its
recorded outcome.

## Selected concepts

- `journal_episode_model_call`: owns only the existing `EffectDispatcher.run` invocation
  and its unchanged operation, safety, call index, request fields/order, actor, logical
  key, context forwarding, and `perform_call` block.
- `result_for_effect_outcome`: owns only the existing success/unknown/failed/unexpected
  status mapping. Success still uses `codec_projection` and `build_receipt`; unknown and
  failed still return nil raw response/receipt; unexpected statuses raise the same
  `ProtocolError` with the same message.

## Unimplemented proposal

The nested provider-usage mapping inside `perform_call` was considered for a
`usage_projection` helper. It is already a short, single-use mapping at the same
response-projection level, so extracting it would add indirection without clarifying
the public story. It remains unchanged.

## Preservation record

- Request construction, request digest calculation, and `LogicalCallKey` inputs remain
  in the same order and with the same values.
- `context`, `operation`, `safety`, `actor`, `logical_key`, and `call_index` continue to
  reach `EffectDispatcher.run` unchanged.
- `perform_call` remains inside the durable effect boundary and still receives the same
  request bytes, logical key, and frame digest.
- `logical.to_key`, `frame_digest`, request/response digests, nil-unavailable usage,
  `latest_attempt`, `iso_time`, receipt field order, public API, and result shape remain
  unchanged.
- Success, unknown, failed, and unexpected effect statuses retain their existing result
  or exception behavior.

## Read-only evidence

The caller `EpisodeNodes#reason`, the composition helper, fixed-graph tests, crash/replay
tests, transport/receipt contracts, and the existing effect-dispatcher seam were inspected.
No tests, lint, Enola, provider, or live commands are run in this implementation lane.

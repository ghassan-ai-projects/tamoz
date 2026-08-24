# tamoz-stream clean-code refactor log

## Bar (per file)
- Every function name states its intent.
- Each function is short and does one thing.
- Each function stays at one abstraction level.
- Public, top-level functions read like a small DSL.
- Functions call helpers one level below, stepping down to small concrete operations.

## Files processed

### situation_request.rb
- Bar: `validate!` reads as a list of domain validations; `run` reads as a short sequence of episode phases; helpers remove duplication.
- Status: done
- Commit: 62d9071

### approval_relay.rb
- Bar: `submit_decision` reads as the PROTOCOL §5/§10 submission sequence;
  `deliver` reads as validate → render → deliver; `initialize` is a list of
  port contracts; `escalate` decomposes into normalize → pick → payload.
- Status: done
- Notes: see behavior-notes.md (comma-joined port error text; rejected
  require_field! simplification).

### decision_builder.rb
- Bar: `build`/`build_decision` are pure decision-v1 schema literals;
  `diagnose_intents` is a guard chain (fallback → admission → abstention →
  action); `build_parameters` reads preset → episode bindings → model values.
- Status: done
- Notes: wire surface frozen — hash insertion order, truncation limits
  (now named MAX_HYPOTHESIS_BYTES/MAX_SUMMARY_BYTES), exception order and
  messages unchanged.

### episode_stream.rb
- Bar: EpisodeStream event verbs already read as the wire DSL (left alone);
  `emit_stream_part` now dispatches one level down instead of inlining the
  receipt→wire plumbing.
- Status: done

### evidence_client.rb
- Bar: `call` reads validate → canonicalize → request → dial → refuse-or-
  verify → project; `initialize` reads as a list of channel + identity
  contracts plus stub construction; `verify!` is a three-step verification
  ladder.
- Status: done
- Notes: all gates keep their original evaluation order and messages;
  rescue precedence (EvidenceError re-raise before wrap) unchanged.

### outcome_subscriber.rb
- Bar: `dispatch` reads validate → state → refuse-conflict → acknowledge-
  duplicates → unhandled-or-deliver; `parse_cloud_event` reads utf8 → parse
  → shape → construct.
- Status: done
- Notes: the unsupported-version refusal stays inside the nil-handler branch
  (after dedupe) exactly as before — hoisting it would change which events
  raise. Digest domain literal unified into notification_digest.

### sse_transport.rb
- Bar: `open` reads validate → enumerate (stop / stream-or-reconnect);
  `stream_once` reads dial → request → validate → feed; the SSE Parser was
  already at bar (left alone).
- Status: done
- Notes: reconnect loop rewritten around a boolean-returning helper — a
  literal `break` extraction would LocalJumpError outside the block; EOF vs
  error paths and stop semantics preserved.

### verification_store.rb
- Bar: open/record_outcome/reconcile read as validate → locked transition;
  awaiting_row / observed_row / reconciled_row carry the state machine one
  level down.
- Status: done
- Notes: idempotent redelivery now stores the unchanged row back instead of
  returning early — same observable state under the lock; error messages
  and evaluation order unchanged.

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

### live_learning_handlers.rb
- Bar: `reconcile_outcome` reads reconcile → admit-learnable-episode;
  `request_approval` reads reserve → claim → deliver-if-claimed; the
  admission ladder (learnable check → duplicate check → admit → result)
  steps down one method per decision.
- Status: done

### episode_worker.rb
- Bar: `execute` is a three-line DSL; request validation is a flat gate
  list with the P8 fixture policy as its own named refusal; the stream
  validator steps sequence/size/terminal checks one level down.
- Status: done

### notification_contract.rb
- Bar: `validate!` reads hash-gate → schema → conditional branches →
  relations; the flat constraint validators were already single-purpose
  checklists at one level (left alone).
- Status: done

### capability_host.rb
- Bar: `initialize` reads as the trust-boundary contract (map, cap, exact
  surface, callable bindings); `context_view` reads resolve-source →
  allowlist projection.
- Status: done

### artifact_store.rb
- Bar: `retain` reads digest-gate → document-gate → unchanged-or-new;
  `within_bounds!` names the eviction-boundary refusal; the collision
  policy (never keep-first) lives in `unchanged_artifact`.
- Status: done

### decision_node_builder.rb
- Bar: `call` reads as one projection step (document → outcome → build);
  the decision-v1 outcome literal moved to `outcome_projection`;
  EnvelopeView stays a private_constant view.
- Status: done
- Notes: `build_decision` (the P6 compensate entry, called from
  tamoz-agent-kernel episode_nodes) kept public above `private`.

### situation_snapshot.rb
- Bar: `verify` reads payload → strict parse → digest → object → identity;
  each gate raises its typed error one level down.
- Status: done
- Notes: gate evaluation order preserved exactly (short-circuit
  observability); identity collection still gathers ALL missing fields,
  entity appended last, before the joined-message raise.

### reconsideration.rb
- Bar: already at bar — intent-named steps, no decomposition adds value.
- Status: left alone

### worker_server.rb
- Bar: lifecycle verbs read as the serving DSL (start = bind + thread,
  run = lazy bind + serve, stop = guarded teardown).
- Status: left alone
- Notes: pre-existing `stop`/`@started` guard quirk (no-op before start)
  left as-is deliberately.

### situation_memory.rb
- Bar: already at bar.
- Status: left alone

### errors.rb
- Bar: typed-error catalog; nothing to decompose.
- Status: left alone

### stream.rb
- Bar: gem entry manifest (requires + module doc).
- Status: left alone

## Post-review cleanups

### live_learning_handlers.rb
- Extracted `approval_event_digest(kind, data)` to remove the repeated
  `Tamoz::Core.digest("tamoz/stream/approval-<kind>/v1\n", data)` pattern.
- Extracted `already_withdrawn?(receipt, event_digest)` predicate.

### verification_store.rb
- Extracted `reference_hash(row)` from `reference` to remove inline wire-hash
  plumbing.

### decision_builder.rb
- Extracted `DecisionBuilder.with_digest(decision)` shared by `build` and
  `build_decision` so document construction no longer mixes with digest
  computation.
- Extracted `intent_with_digest(intent)` from `build_intent`.
- Extracted `ensure_watch_allowlisted!` and `evidence_ids` helpers.

### situation_request.rb
- Fixed behavior-preserving bugs discovered during test run:
  - `fail_stream` now returns the stream so rescue blocks can yield events.
  - `model_started` event data restored `provider` and `model_id` fields.
- Refactored `diagnose?`/`reconsider?` to compare against the already-mapped
  `kind` instead of re-looking up `KIND_NAMES`.

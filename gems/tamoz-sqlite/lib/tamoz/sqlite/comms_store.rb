# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'

require 'tamoz/core'

require_relative 'wire'
require_relative 'comms_store_rows'
require_relative 'comms_outbox'
require_relative 'comms_routes'

module Tamoz
  module SQLite
    # The channel store facade (design §13, plan slice C). Implements the
    # structural Tamoz::Comms::CommsStore contract WITHOUT referencing the
    # contract gem (dependency rule 9): wire-form hashes in, wire-form hashes
    # out, and the integration layer verifies the CONTRACT_VERSION pair.
    #
    # Admission shares the request-inbox enqueue seam inside ONE transaction
    # (poll → admit → enqueue in the same runtime database, exactly like the
    # scheduler); prompt consumption inserts its decision in the same
    # transaction (ADR-043). Outbox and route operations delegate to the
    # composed stores so every file stays under the size contract.
    #
    # The operation labels are the kill-harness addresses (BoundaryRegistry);
    # a crash before commit leaves `old` state, after commit `new` state.
    # :reek:LongParameterList, :reek:UnusedParameters, :reek:DataClump
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy, :reek:NilCheck
    # :reek:TooManyStatements -- the primitives mirror the §13 contract
    #   signatures and their one-transaction bodies; splitting them would
    #   fragment the durable operations.
    # :reek:TooManyMethods -- one primitive per table seam is the contract.
    # rubocop:disable Metrics/ParameterLists, Metrics/BlockLength -- the §13 contract signatures and their one-transaction blocks.
    # rubocop:disable Metrics/ClassLength -- the store is one facade over the
    #   §13 contract; splitting it would scatter the transaction boundaries.
    # rubocop:disable Metrics/MethodLength -- admit_and_enqueue is one atomic
    #   admission (inbound + request + enqueue); splitting it would open the
    #   crash window the design closes with a single transaction.
    class CommsStore
      include CommsStoreRows

      CONTRACT_VERSION = 2
      REQUEST_OPERATION = 'turn'
      REQUEST_DELIVERY = 'queue'
      CANCEL_OPERATION = 'redirect'
      CANCEL_DELIVERY = 'redirect'
      DEFAULT_NAMESPACE = '[]'
      HISTORY_LIMIT = 12
      HISTORY_TEXT_CHARACTERS = 500
      CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]+/u
      # A queued request is reported as unclaimed after one backend clock tick
      # without an observed inbox claim; this is not a process-liveness claim.
      WORKER_UNCLAIMED_WINDOW_MS = 1
      # The settle kinds a terminal delivery can carry (OutboxDeliverySink);
      # stamped into projection_state at complete_request so every later
      # reader derives the terminal task status from the SAME durable fact.
      TERMINAL_SETTLES = %w[answer failed stopped blocked].freeze
      # The settle word per recorded kind: only an ANSWER claims the
      # completion won the race; failed and blocked settles say so plainly.
      SETTLE_WORDS = {
        'answer' => 'completed_before_effect',
        'failed' => 'failed_before_effect',
        'stopped' => 'stopped',
        'blocked' => 'blocked'
      }.freeze

      def initialize(adapter:, checkpoints: nil)
        @adapter = adapter
        @checkpoints = checkpoints
        @outbox = CommsOutbox.new(adapter:)
        @routes = CommsRoutes.new(adapter:)
        @decisions = CommsDecisionStore.new(adapter:)
      end

      # ===== surfaces =====

      def deploy_surface(descriptor_wire, now:)
        transaction('comms.surface.deploy') do |txn|
          existing = txn.first('comms.surface.deploy.existing', <<~SQL, [descriptor_wire.fetch('surface_id')])
            SELECT revision FROM tamoz_comms_surfaces WHERE surface_id = ?
          SQL
          next :duplicate if existing && existing[0] >= descriptor_wire.fetch('revision')

          upsert_surface!(txn, descriptor_wire, now)
          :deployed
        end
      end

      def surface(surface_id:)
        read('comms.surface.read') do |txn|
          row = txn.first('comms.surface.read', <<~SQL, [surface_id])
            SELECT descriptor_json FROM tamoz_comms_surfaces WHERE surface_id = ?
          SQL
          row && JSON.parse(row.fetch(0))
        end
      end

      # ===== admission =====

      # Admit ONE inbound update AND enqueue its turn in one transaction. The
      # first durable observation of (surface, bot, update_id) anchors dedup:
      # the same payload digest is :duplicate; a DIFFERENT digest for that
      # identity is a durable integrity conflict — it UPDATES the one anchor
      # row's conflict counter and last conflicting digest, enqueues nothing
      # (invariant 1), so storage per update_id stays bounded forever.
      # Declared intake limits are read from the DEPLOYED surface row inside
      # this transaction: open requests at `max_open_requests` refuse
      # :open_request_limit, text beyond `max_inbound_bytes` refuses
      # :inbound_too_large — both before any insert. Intake is bounded by the
      # surface's deployed `outbox_capacity` (design §12, invariant 57):
      # pending+claimed deliveries plus the reservations of
      # admitted-but-unfinished requests must stay under it, so the reserved
      # terminal row can always append.
      # `history` is the conversation transcript so far (see
      # `conversation_history`); it rides inside the payload's `task` entry
      # (the same Hash shape a cancel payload uses, since payload keys map
      # onto state channels one-to-one) so the turn is planned with the
      # thread's context, not with one message alone.
      # :reek:LongParameterList -- the admission binds every fact design §6
      #   makes durable in one transaction.
      def admit_and_enqueue(envelope_wire, surface_id:, bot_id:, thread:, profile_id:, reservation:, now:,
                            history: [])
        transaction('comms.admit.enqueue') do |txn|
          anchor = inbound_anchor(txn, envelope_wire, bot_id)
          if anchor
            next :duplicate if anchor[0] == envelope_wire.fetch('raw_payload_hash')

            record_inbound_conflict!(txn, envelope_wire, bot_id)
            next :integrity_conflict
          end

          limits = deployed_surface_limits(txn, surface_id)
          next :open_request_limit if open_request_count(txn, surface_id) >= limits.fetch('max_open_requests')

          text = envelope_wire['text']
          next :inbound_too_large if text && text.bytesize > limits.fetch('max_inbound_bytes')
          next :capacity_refused if capacity_saturated?(txn, surface_id, reservation,
                                                        limits.fetch('outbox_capacity'))

          insert_inbound!(txn, envelope_wire, bot_id:, disposition: 'request', reason: 'accepted', now:)
          request_id = request_id_for(envelope_wire, bot_id)
          insert_admitted_request!(txn, request_id, envelope_wire,
                                   surface_id:, thread:, profile_id:, reservation:, now:)
          payload_bytes, payload_digest, input_digest = encode_request(
            REQUEST_OPERATION, REQUEST_DELIVERY,
            turn_payload(envelope_wire.fetch('text'), history, thread:, request_id:)
          )
          @checkpoints.enqueue_request_in_transaction!(
            txn, thread:, encoded_namespace: DEFAULT_NAMESPACE, id: request_id,
                 operation_text: REQUEST_OPERATION, delivery_text: REQUEST_DELIVERY,
                 payload_bytes:, payload_digest:, input_digest:
          )
          :enqueued
        end
      end

      # Admit one clarification answer and enqueue its resume without a crash
      # window between the inbound anchor and the request inbox row.
      def admit_and_enqueue_answer(envelope_wire, surface_id:, bot_id:, thread:, request_id:, payload:, now:)
        transaction('comms.admit.answer') do |txn|
          anchor = inbound_anchor(txn, envelope_wire, bot_id)
          if anchor
            next :duplicate if anchor[0] == envelope_wire.fetch('raw_payload_hash')

            record_inbound_conflict!(txn, envelope_wire, bot_id)
            next :integrity_conflict
          end

          payload_bytes, payload_digest, input_digest = encode_request(
            'resume', REQUEST_DELIVERY, payload
          )
          @checkpoints.enqueue_request_in_transaction!(
            txn, thread:, encoded_namespace: DEFAULT_NAMESPACE, id: request_id,
            operation_text: 'resume', delivery_text: REQUEST_DELIVERY,
            payload_bytes:, payload_digest:, input_digest:
          )
          insert_inbound!(txn, envelope_wire, bot_id:, disposition: 'ignored',
                          reason: 'clarification_answer', now:, request_id:)
          :enqueued
        end
      end

      # Record a non-request disposition (ignored/rejected/quarantined)
      # durably. The first observation for an identity INSERTs its anchor
      # row; a conflicting digest for a KNOWN identity UPDATES that anchor
      # (counter + last conflicting digest + the recorded disposition) and
      # returns :conflict_recorded — one row per update_id forever.
      # rubocop:disable Lint/UnusedMethodArgument -- `surface_id` keeps the §13
      # contract signature; the inbound row carries its own surface.
      def disposition_only(envelope_wire, surface_id:, bot_id:, disposition:, reason:, now:)
        transaction('comms.admit.disposition') do |txn|
          next :duplicate if identical_inbound_row?(txn, envelope_wire, bot_id)

          anchor = inbound_anchor(txn, envelope_wire, bot_id)
          if anchor
            next :duplicate if anchor[1] == envelope_wire.fetch('raw_payload_hash') &&
                               anchor[2] == disposition && anchor[3] == reason

            record_inbound_conflict!(txn, envelope_wire, bot_id, disposition:, reason:)
            next :conflict_recorded
          end

          insert_inbound!(txn, envelope_wire, bot_id:, disposition:, reason:, now:)
          :recorded
        end
      end
      # rubocop:enable Lint/UnusedMethodArgument

      # The admission capacity gate (invariant 57): the new reservation must
      # fit alongside pending+claimed deliveries and the other open
      # reservations.
      def capacity_saturated?(txn, surface_id, reservation, capacity)
        pending_claimed_count(txn, surface_id) + open_reservations(txn, surface_id) + reservation > capacity
      end

      # A bare task string for a first contact; once the conversation has a
      # transcript the text nests with it under the task Hash — the shape the
      # graph's payload-to-channel mapping tolerates (payload keys map onto
      # state channels one-to-one, and `task` already carries Hashes).
      # :reek:UtilityFunction -- pure payload shaping for the admission above.
      def turn_payload(text, history, thread:, request_id:)
        Tamoz::Core::TurnContext.task(
          thread_id: thread,
          request_id:,
          text: flatten_context_text(text),
          fragments: history.filter_map do |fragment|
            flattened = flatten_context_text(fragment.fetch('text'))
            next nil if flattened.empty?

            { 'role' => fragment.fetch('role'), 'text' => flattened }
          end
        )
      end

      # TurnContext forbids control characters, but an inbound message or a
      # multi-line terminal answer carried as a transcript fragment can contain
      # a newline; flatten any control run to one space so admission and every
      # later turn stay durable. This normalizes what the model sees, never what
      # the correspondent already received.
      def flatten_context_text(text)
        String(text).gsub(CONTROL_CHARACTERS, " ").strip
      end

      # ===== poll state =====

      # One fenced poller per authenticated bot (design §13): a live lease is
      # not claimable by a second poller; an expired lease is recoverable.
      def acquire_poller_lease(surface_id:, bot_id:, owner:, fence:, ttl_s:, now:)
        transaction('comms.poll.lease') do |txn|
          current = txn.first('comms.poll.lease.current', <<~SQL, [bot_id])
            SELECT poller_owner_id, poller_fence, poller_expires_at_ms
            FROM tamoz_comms_poll_state WHERE bot_id = ?
          SQL
          next :not_acquirable if current && current[2] && current[2] > now_ms(now) && current[0] != owner

          upsert_poller!(txn, surface_id:, bot_id:, owner:, fence:, expires_at_ms: now_ms(now) + (ttl_s * 1000), now:)
          :acquired
        end
      end

      # Persist the candidate next_offset ONLY after the returned prefix is
      # durable. Never regresses: an offset behind the stored one is :behind,
      # and a nil candidate (an empty poll prefix) is :unchanged — it must
      # never clobber the durable offset.
      def persist_next_offset(surface_id:, bot_id:, next_offset:, now:)
        transaction('comms.poll.offset') do |txn|
          next :unchanged if next_offset.nil?

          stored = txn.first('comms.poll.offset.stored', <<~SQL, [bot_id])
            SELECT next_offset FROM tamoz_comms_poll_state WHERE bot_id = ?
          SQL
          next :behind if stored && !stored[0].nil? && stored[0] >= next_offset

          txn.execute('comms.poll.offset.upsert', <<~SQL, [bot_id, surface_id, next_offset, now_ms(now)])
            INSERT INTO tamoz_comms_poll_state (
              bot_id, surface_id, next_offset, updated_at_ms
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(bot_id) DO UPDATE SET
              next_offset = excluded.next_offset, updated_at_ms = excluded.updated_at_ms
          SQL
          :persisted
        end
      end

      # The durable next_offset for one bot (nil when never persisted).
      def poll_offset(bot_id:)
        read('comms.poll.offset.read') do |txn|
          txn.scalar('comms.poll.offset.read', <<~SQL, [bot_id])
            SELECT next_offset FROM tamoz_comms_poll_state WHERE bot_id = ?
          SQL
        end
      end

      # Release this gateway's poller lease (idempotent — only releases when
      # the fence is ours, so a crashed gateway's lease expires on its own).
      def release_poller_lease(bot_id:, owner:, fence:)
        transaction('comms.poll.release') do |txn|
          txn.execute('comms.poll.release', <<~SQL, [bot_id, owner, fence])
            UPDATE tamoz_comms_poll_state
            SET poller_owner_id = NULL, poller_fence = NULL, poller_expires_at_ms = NULL
            WHERE bot_id = ? AND poller_owner_id = ? AND poller_fence = ?
          SQL
          :released
        end
      end

      # ===== outbox and routes (delegated) =====

      def append_delivery(delivery_wire, surface_id:, capacity:, now:, reserved_request_id: nil)
        @outbox.append_delivery(delivery_wire, surface_id:, capacity:,
                                               reserved_request_id:, now:)
      end

      # Terminal projection records the settle kind the correspondent was
      # actually told (answer/failed/stopped/blocked) — the truthful axis the
      # cancellation wording derives from; release the request's reservation
      # so its slots return to intake (design §12: unused slots release only
      # after terminal projection is durable).
      def complete_request(thread_id:, request_id:, settle_kind:)
        kind = settle_kind.to_s
        raise KeyError, "unknown settle kind #{settle_kind.inspect}" unless TERMINAL_SETTLES.include?(kind)

        transaction('comms.request.complete') do |txn|
          txn.execute('comms.request.complete', <<~SQL, [kind, thread_id, request_id])
            UPDATE tamoz_comms_requests SET projection_state = ?
            WHERE thread_id = ? AND request_id = ? AND projection_state = 'admitted'
          SQL
          txn.changes == 1 ? :released : :not_admitted
        end
      end

      # The current-generation admitted requests available to a caller-bound
      # cancellation command, in queue order.
      def open_request_targets(surface_id:, conversation_id:, thread_id:)
        read('comms.request.cancel.targets') do |txn|
          rows = txn.rows('comms.request.cancel.targets', <<~SQL, [surface_id, conversation_id, thread_id])
            SELECT request_id, thread_id FROM tamoz_comms_requests
            WHERE surface_id = ? AND conversation_id = ? AND thread_id = ?
              AND projection_state = 'admitted'
            ORDER BY created_at_ms ASC, request_id ASC
          SQL
          rows.map do |row|
            request_id, row_thread_id = row
            { 'request_id' => request_id, 'request_ref' => request_ref(request_id), 'thread_id' => row_thread_id }
          end
        end
      end

      # The durable `requested` point of the cancellation timeline (plan 03,
      # work item 4): the stamp and the :cancel enqueue commit in ONE
      # transaction, so a rollback (a replayed cancel id, a tombstoned thread)
      # leaves neither. Without a target, every still-admitted request on the
      # thread is stamped for the existing direct-store contract.
      def request_cancellation(thread_id:, request_id:, payload:, now:, target_request_id: nil)
        payload_bytes, payload_digest, input_digest = encode_request(CANCEL_OPERATION, CANCEL_DELIVERY, payload)
        transaction('comms.request.cancel') do |txn|
          stamp_cancellation_requested!(txn, thread_id:, target_request_id:, now:)
          @checkpoints.enqueue_request_in_transaction!(
            txn, thread: thread_id, encoded_namespace: DEFAULT_NAMESPACE, id: request_id,
                 operation_text: CANCEL_OPERATION, delivery_text: CANCEL_DELIVERY,
                 payload_bytes:, payload_digest:, input_digest:
          )
          :requested
        end
      end

      # The durable `observed` point, written once where the turn runner has
      # consumed the cancel operation. First write wins: a crash between the
      # runner's consumption and this stamp replays to the same single value.
      def mark_cancellation_observed(thread_id:, now:)
        transaction('comms.request.cancel.observed') do |txn|
          stamp_cancellation_observed!(txn, thread_id:, now:)
          :observed
        end
      end

      def claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
        @outbox.claim_delivery(delivery_id:, owner:, fence:, claim_expires_at:, now:)
      end

      def reserve_delivery_slot(surface_id:, conversation_id:, per_chat_messages_per_s:, global_messages_per_s:, now:)
        @outbox.reserve_delivery_slot(surface_id:, conversation_id:, per_chat_messages_per_s:,
                                      global_messages_per_s:, now:)
      end

      def release_delivery_claim(delivery_id:, owner:, fence:, now:)
        @outbox.release_delivery_claim(delivery_id:, owner:, fence:, now:)
      end

      def mark_delivery_send_started(delivery_id:, owner:, fence:, now:)
        @outbox.mark_delivery_send_started(delivery_id:, owner:, fence:, now:)
      end

      def reconcile_expired_deliveries(now:)
        @outbox.reconcile_expired_deliveries(now:)
      end

      def defer_delivery(surface_id:, conversation_id:, not_before:, now:)
        @outbox.defer_delivery(surface_id:, conversation_id:, not_before:, now:)
      end

      # Read-only channel status derived from durable admission/projection
      # rows. Reference-addressed and queue-aware (plan 02, work item 3):
      # when anything is admitted the projection carries the active request's
      # short reference (`request_ref`), its queue facts, and all open short
      # references; with nothing admitted only the open-reference list is empty.
      # `now:` binds the reader's clock for age arithmetic; without it the
      # connection's backend time answers.
      def conversation_status(surface_id:, conversation_id:, now: nil)
        read('comms.conversation.status') do |txn|
          route = txn.first('comms.conversation.status.route', <<~SQL, [surface_id, conversation_id])
            SELECT thread_id FROM tamoz_comms_conversations
            WHERE surface_id = ? AND conversation_id = ?
          SQL
          next nil unless route

          active = active_request_row(txn, surface_id, conversation_id)
          # The active request projects on the thread it was ADMITTED to: after
          # /new rotates the generation, the route row's thread no longer names it.
          thread_id = active&.fetch(2) || route.fetch(0)
          request_id = active&.fetch(0)
          conversation_status_projection(
            txn, surface_id, conversation_id, thread_id, request_id, now:
          ).merge(
            'open_request_refs' => open_request_refs(txn, surface_id, conversation_id)
          )
        end
      end

      # Resolve ONE request by its short reference inside ONE conversation —
      # caller-bound, never cross-conversation. The reference authorizes
      # nothing: a foreign ref is :unknown_ref here even though it resolves
      # elsewhere.
      # @return [Hash] the full status projection plus `terminal_reason`
      # @return [:unknown_ref] no request in this conversation matches
      # @return [:ambiguous_ref] several requests share the ref prefix
      def request_status(surface_id:, conversation_id:, ref:, now: nil)
        read('comms.request.status') do |txn|
          resolved = resolve_request_ref(txn, surface_id, conversation_id, ref)
          next resolved unless resolved.is_a?(Array)

          request_id, thread_id = resolved
          request_status_projection(
            txn, surface_id, conversation_id, thread_id, request_id, now:
          )
            .merge('terminal_reason' => terminal_reason_for(thread_id, request_id))
        end
      end

      # Operator-wide reference scan for the reconnectable CLI view (plan 03,
      # work item 5): read-only rows matching a short reference across every
      # surface and conversation. Unlike the channel's caller-scoped
      # resolution, an operator may see every match; rendering stays
      # store-derived.
      def requests_by_reference(ref)
        return [] unless ref.is_a?(String) && ref.match?(REQUEST_REF_PATTERN)

        read('comms.request.ref.scan') do |txn|
          txn.rows('comms.request.ref.scan', <<~SQL, [ref[1, REQUEST_REF_WIDTH]])
            SELECT surface_id, conversation_id, request_id FROM tamoz_comms_requests
            WHERE substr(request_id, 1, #{REQUEST_REF_WIDTH}) = ?
            ORDER BY created_at_ms DESC LIMIT 25
          SQL
        end
      end

      def resolve_request_ref(txn, surface_id, conversation_id, ref)
        return :unknown_ref unless ref.is_a?(String) && ref.match?(REQUEST_REF_PATTERN)

        matches = txn.rows(
          'comms.request.status.resolve',
          <<~SQL, [surface_id, conversation_id, ref[1, REQUEST_REF_WIDTH]]
            SELECT request_id, thread_id FROM tamoz_comms_requests
            WHERE surface_id = ? AND conversation_id = ?
              AND substr(request_id, 1, #{REQUEST_REF_WIDTH}) = ?
            ORDER BY created_at_ms ASC
          SQL
        )
        return :unknown_ref if matches.empty?
        return :ambiguous_ref if matches.length > 1

        matches.first
      end

      def base_status_projection(txn, surface_id, conversation_id, thread_id, request_id, now:)
        open_requests = open_requests_for(txn, surface_id, conversation_id)
        {
          'thread_id' => thread_id,
          'state' => open_requests.positive? ? 'accepted' : 'idle',
          'open_requests' => open_requests,
          'request_id' => request_id
        }
          .merge(queue_facts(txn, surface_id, conversation_id, request_id, now))
          .merge(cancellation_document(txn, request_id, now))
          .merge(worker_status(txn, thread_id, request_id, now))
      end

      def conversation_status_projection(txn, surface_id, conversation_id, thread_id, request_id, now:)
        base_status_projection(txn, surface_id, conversation_id, thread_id, request_id, now:)
          .merge(conversation_runtime_status(thread_id, request_id, surface_id, conversation_id))
          .merge('active_delivery_state' => active_delivery_state(surface_id, conversation_id, request_id))
      end

      def request_status_projection(txn, surface_id, conversation_id, thread_id, request_id, now:)
        base_status_projection(txn, surface_id, conversation_id, thread_id, request_id, now:)
          .merge(request_runtime_status(thread_id, request_id, surface_id, conversation_id))
      end

      # The durable cancellation timeline of one request (plan 03, work item
      # 4), derived only from committed rows (invariant 12): `requested` is
      # the /cancel stamp, `observed` the runner's consumption stamp, and the
      # terminal point is the recorded settle kind. A request that settled
      # answered keeps terminal=completed_before_effect even when observed —
      # a raced completion is never rendered as a stop (invariant 9), and a
      # failed or blocked settle never reads as a success. The document nests
      # under one key so it never collides with the projection's own axes.
      def cancellation_document(txn, request_id, now)
        facts = cancellation_facts(txn, request_id, now)
        facts.empty? ? {} : { 'cancellation' => facts }
      end

      def cancellation_facts(txn, request_id, now)
        return {} unless request_id

        row = txn.first('comms.conversation.status.cancellation', <<~SQL, [request_id])
          SELECT projection_state, cancellation_requested_at_ms, cancellation_observed_at_ms
          FROM tamoz_comms_requests WHERE request_id = ?
        SQL
        return {} unless row

        requested = row.fetch(1)
        return {} unless requested

        clock = backend_now_ms(txn, now)
        facts = { 'requested_at_ms' => requested, 'requested_age_ms' => clock - requested }
        observed = row.fetch(2)
        if observed
          facts['observed_at_ms'] = observed
          facts['observed_age_ms'] = clock - observed
        end
        facts['terminal'] = cancellation_outcome(observed:, settled: row.fetch(0))
        facts['state'] = facts['terminal'] ? 'terminal' : (observed ? 'observed' : 'requested')
        facts
      end

      # The settle word follows the TASK axis: projection_state carries the
      # settle kind recorded at complete_request. An observed-but-unsettled
      # request is the one honest `stopped` — work seen stopping at the
      # boundary while still open.
      def cancellation_outcome(observed:, settled:)
        return SETTLE_WORDS.fetch(settled, nil) if settled && settled != 'admitted'

        'stopped' if observed
      end

      # Queue facts are durable-row arithmetic (invariant 12): the addressed
      # request's short reference, its position among the conversation's
      # admitted requests, and — when any admitted request exists — the age
      # of the oldest one.
      def queue_facts(txn, surface_id, conversation_id, request_id, now)
        return {} unless request_id

        oldest = oldest_open_created_at_ms(txn, surface_id, conversation_id)
        {
          'request_ref' => request_ref(request_id),
          'queue_position' => queue_position(txn, surface_id, conversation_id, request_id),
          'queue_age_ms' => oldest && backend_now_ms(txn, now) - oldest
        }.compact
      end

      def queue_position(txn, surface_id, conversation_id, request_id)
        row = txn.first('comms.conversation.status.queue_peer', <<~SQL, [request_id])
          SELECT created_at_ms FROM tamoz_comms_requests WHERE request_id = ?
        SQL
        return 0 unless row

        peer_at = row.fetch(0)
        txn.scalar('comms.conversation.status.queue_position', <<~SQL, [surface_id, conversation_id, peer_at, peer_at, request_id]).to_i
          SELECT COUNT(*) FROM tamoz_comms_requests
          WHERE surface_id = ? AND conversation_id = ? AND projection_state = 'admitted'
            AND (created_at_ms < ? OR (created_at_ms = ? AND request_id < ?))
        SQL
      end

      def oldest_open_created_at_ms(txn, surface_id, conversation_id)
        txn.scalar('comms.conversation.status.oldest_open', <<~SQL, [surface_id, conversation_id])
          SELECT MIN(created_at_ms) FROM tamoz_comms_requests
          WHERE surface_id = ? AND conversation_id = ? AND projection_state = 'admitted'
        SQL
      end

      def backend_now_ms(txn, now)
        return now_ms(now) if now

        txn.scalar('comms.conversation.status.backend_time', BACKEND_TIME_SQL)
      end

      def worker_status(txn, thread_id, request_id, now)
        return {} unless request_id

        row = txn.first('comms.request.status.worker', <<~SQL, [thread_id, DEFAULT_NAMESPACE, request_id])
          SELECT status, created_at_ms FROM tamoz_requests
          WHERE thread_id = ? AND namespace = ? AND request_id = ?
        SQL
        return {} unless row

        state = worker_state(row, backend_now_ms(txn, now))
        state ? { 'worker_state' => state } : {}
      end

      def worker_state(row, current_ms)
        case row.fetch(0)
        when 'queued'
          age_ms = [current_ms - row.fetch(1), 0].max
          age_ms >= WORKER_UNCLAIMED_WINDOW_MS ? 'queued-unclaimed' : 'accepted'
        when 'claimed', 'running'
          'working'
        end
      end

      def conversation_runtime_status(thread_id, request_id, surface_id, conversation_id)
        {
          'task_state' => task_state_for(thread_id, request_id),
          'effect_state' => conversation_effect_state_for(thread_id, request_id),
          'capability_state' => capability_state_for(thread_id, request_id),
          'delivery_state' => conversation_delivery_state_for(surface_id, conversation_id)
        }.merge(lifecycle_status_for(thread_id, request_id))
      end

      def active_delivery_state(surface_id, conversation_id, request_id)
        return 'none' unless request_id

        request_delivery_state_for(surface_id, conversation_id, request_id)
      end

      def request_runtime_status(thread_id, request_id, surface_id, conversation_id)
        {
          'task_state' => task_state_for(thread_id, request_id),
          'effect_state' => request_effect_state_for(thread_id, request_id),
          'capability_state' => capability_state_for(thread_id, request_id),
          'delivery_state' => request_delivery_state_for(surface_id, conversation_id, request_id)
        }.merge(lifecycle_status_for(thread_id, request_id))
      end

      def bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
        @outbox.bind_journal_effect(delivery_id:, effect_key:, execution_id:, now:)
      end

      # ===== conversation history =====

      # The recent transcript of one conversation, oldest first, for the
      # turn's planning context: user lines are the admitted requests' task
      # payloads (the inbound table stores hashes, never text), assistant
      # lines are only the CONFIRMED successful terminal deliveries
      # (invariant 11). Bounded twice — `limit` entries, each truncated —
      # because the transcript rides the request payload into a model prompt.
      def conversation_history(surface_id:, conversation_id:, limit: HISTORY_LIMIT)
        entries = recent_request_tasks(surface_id:, conversation_id:, limit:) +
                  recent_terminal_deliveries(surface_id:, conversation_id:, limit:)
        entries.sort_by { |entry| entry.fetch(:at) }.last(limit).map do |entry|
          { 'role' => entry.fetch(:role), 'text' => entry.fetch(:text) }
        end
      end


      # The durable /new generation of one bound conversation (plan 02,
      # work item 4): monotonic, part of the thread identity
      # `Admission.thread_id` folds into its digest.
      # @return [Integer]
      def conversation_generation(surface_id:, conversation_id:)
        read('comms.conversation.generation') do |txn|
          generation_row!(txn, surface_id, conversation_id)
        end
      end

      # One durable +1 per `/new`; returns the new value. An absent
      # conversation raises before anything mutates.
      # @return [Integer]
      def bump_generation(surface_id:, conversation_id:)
        transaction('comms.conversation.bump_generation') do |txn|
          txn.execute('comms.conversation.bump_generation.update', <<~SQL, [surface_id, conversation_id])
            UPDATE tamoz_comms_conversations SET generation = generation + 1
            WHERE surface_id = ? AND conversation_id = ?
          SQL
          raise KeyError, "conversation #{conversation_id} is not bound on surface #{surface_id}" unless txn.changes == 1

          generation_row!(txn, surface_id, conversation_id)
        end
      end

      def generation_row!(txn, surface_id, conversation_id)
        row = txn.first('comms.conversation.generation.read', <<~SQL, [surface_id, conversation_id])
          SELECT generation FROM tamoz_comms_conversations
          WHERE surface_id = ? AND conversation_id = ?
        SQL
        raise KeyError, "conversation #{conversation_id} is not bound on surface #{surface_id}" unless row

        row.fetch(0)
      end

      def open_requests_for(txn, surface_id, conversation_id)
        txn.scalar('comms.conversation.status.requests', <<~SQL, [surface_id, conversation_id]).to_i
          SELECT COUNT(*) FROM tamoz_comms_requests
          WHERE surface_id = ? AND conversation_id = ? AND projection_state = 'admitted'
        SQL
      end

      def open_request_refs(txn, surface_id, conversation_id)
        rows = txn.rows('comms.conversation.status.open_refs', <<~SQL, [surface_id, conversation_id])
          SELECT request_id FROM tamoz_comms_requests
          WHERE surface_id = ? AND conversation_id = ? AND projection_state = 'admitted'
          ORDER BY created_at_ms ASC, request_id ASC
        SQL
        rows.map { |row| request_ref(row.fetch(0)) }
      end

      def active_request_row(txn, surface_id, conversation_id)
        txn.first('comms.conversation.status.active_request', <<~SQL, [surface_id, conversation_id])
          SELECT request_id, created_at_ms, thread_id FROM tamoz_comms_requests
          WHERE surface_id = ? AND conversation_id = ? AND projection_state = 'admitted'
          ORDER BY created_at_ms DESC, request_id DESC LIMIT 1
        SQL
      end

      def task_state_for(thread_id, request_id)
        return 'idle' unless request_id
        return 'not_started' unless @checkpoints

        request = @checkpoints.fetch_request(thread_id:, request_id:, namespace: [])
        return 'not_started' unless request

        request.status.to_s
      end

      def conversation_effect_state_for(thread_id, request_id)
        return 'not_started' unless @checkpoints
        return 'not_started' unless request_id

        request = @checkpoints.fetch_request(thread_id:, request_id:, namespace: [])
        return 'not_started' unless request && %i[running completed failed].include?(request.status)

        summarize_effect_statuses(conversation_effect_statuses(thread_id))
      end

      def conversation_effect_statuses(thread_id)
        state = session_checkpoint(thread_id)&.state
        statuses = Array(state&.fetch(:effect_receipts, nil)).filter_map do |row|
          row.fetch('status', nil).to_s
        end
        return statuses unless statuses.empty?

        @checkpoints.effect_census.filter_map do |row|
          row[:status].to_s if row[:thread_id] == thread_id
        end
      end

      def request_effect_state_for(thread_id, request_id)
        return 'not_started' unless @checkpoints
        return 'not_started' unless request_id

        request = @checkpoints.fetch_request(thread_id:, request_id:, namespace: [])
        return 'not_started' unless request && %i[running completed failed].include?(request.status)

        summarize_effect_statuses(request_effect_statuses(thread_id, request_id))
      end

      def request_effect_statuses(thread_id, request_id)
        @checkpoints.effect_census.filter_map do |row|
          row[:status].to_s if row[:thread_id] == thread_id && row[:request_id] == request_id
        end
      end

      def summarize_effect_statuses(statuses)
        return 'not_started' if statuses.empty?
        return 'unknown' if statuses.include?('unknown')
        return 'pending' if statuses.intersect?(%w[prepared running reconcile])
        return 'failed' if statuses.include?('failed')

        'succeeded'
      end

      def capability_state_for(thread_id, request_id)
        return 'not_started' unless @checkpoints
        return 'not_started' unless request_id

        checkpoint = session_checkpoint(thread_id)
        session = checkpoint&.state&.fetch(:session, nil)
        events = lifecycle_events_for(checkpoint, request_id)
        return 'invoked' if capability_invoked?(events)
        return 'bound' if capability_bound?(session)

        'not_inspected'
      end

      def terminal_reason_for(thread_id, request_id)
        checkpoint = session_checkpoint(thread_id)
        lifecycle_events_for(checkpoint, request_id).last&.fetch('terminal_reason', nil)
      end

      def lifecycle_status_for(thread_id, request_id)
        checkpoint = session_checkpoint(thread_id)
        event = lifecycle_events_for(checkpoint, request_id).last
        unless event
          return {
            'phase' => 'unknown', 'event_kind' => 'unknown', 'event_sequence' => nil,
            'next_action' => 'inspect', 'terminal_reason' => nil
          }.compact
        end

        event_type = event.fetch('event_type')
        {
          'phase' => event.fetch('phase', 'unknown'),
          'event_kind' => event_type,
          'event_sequence' => event.fetch('sequence'),
          'next_action' => lifecycle_next_action(event_type),
          'terminal_reason' => event.fetch('terminal_reason', nil)
        }.compact
      end

      def lifecycle_next_action(event_type)
        return 'none' if event_type == 'terminal'
        return 'approval' if event_type == 'approval'

        'continue'
      end

      def lifecycle_events_for(checkpoint, request_id)
        Array(checkpoint&.state&.fetch(:lifecycle_events, nil)).select do |event|
          event.fetch('request_id', nil) == request_id
        end
      end

      def capability_invoked?(events)
        events.any? { |event| event.key?('capability_id') }
      end

      def capability_bound?(session)
        session&.key?('tool_catalog_digest') == true
      end

      def conversation_delivery_state_for(surface_id, conversation_id)
        statuses = @outbox.outbox_rows(
          surface_id:, statuses: %w[pending claimed succeeded failed unknown], limit: 500
        ).filter_map do |row|
          row.fetch('status') if row.fetch('conversation_id') == conversation_id
        end
        return 'none' if statuses.empty?
        return 'unknown' if statuses.include?('unknown')
        return 'pending' if statuses.intersect?(%w[pending claimed])
        return 'failed' if statuses.include?('failed')

        'succeeded'
      end

      def request_delivery_state_for(surface_id, conversation_id, request_id)
        statuses = @outbox.outbox_rows(
          surface_id:, statuses: %w[pending claimed succeeded failed unknown], limit: 500
        ).filter_map do |row|
          row.fetch('status') if row.fetch('conversation_id') == conversation_id &&
                                 row.fetch('request_id') == request_id
        end
        return 'none' if statuses.empty?
        return 'unknown' if statuses.include?('unknown')
        return 'pending' if statuses.intersect?(%w[pending claimed])
        return 'failed' if statuses.include?('failed')

        'succeeded'
      end

      def outbox_rows(surface_id:, statuses:, limit: 500)
        @outbox.outbox_rows(surface_id:, statuses:, limit:)
      end

      def outbox_row_for_receipt(surface_id:, conversation_id:, message_id:)
        @outbox.outbox_row_for_receipt(surface_id:, conversation_id:, message_id:)
      end

      # Fenced result recording (invariant 4): only the current claim's
      # owner/fence may mark an outcome.
      def mark_delivery(delivery_id:, owner:, fence:, status:, now:, receipt: nil)
        @outbox.mark_delivery(delivery_id:, owner:, fence:, status:, receipt:, now:)
      end

      def resolve_delivery(delivery_id:, status:, now:)
        @outbox.resolve_delivery(delivery_id:, status:, now:)
      end

      def bind_correspondent(binding_wire, now:)
        @routes.bind_correspondent(binding_wire, now:)
      end

      def revoke_binding(correspondent_id:, surface_id:, reason:, now:)
        @routes.revoke_binding(correspondent_id:, surface_id:, reason:, now:)
      end

      def binding(correspondent_id:, surface_id:, version: nil)
        @routes.binding(correspondent_id:, surface_id:, version:)
      end

      def bind_conversation(conversation_wire, now:)
        @routes.bind_conversation(conversation_wire, now:)
      end

      def conversation(surface_id:, conversation_id:)
        @routes.conversation(surface_id:, conversation_id:)
      end

      # The conversation a thread routes to (via its most recent admission),
      # for delivery projection (design §13).
      def request_conversation(thread_id:)
        read('comms.request.conversation') do |txn|
          row = txn.first('comms.request.conversation', <<~SQL, [thread_id])
            SELECT surface_id, conversation_id FROM tamoz_comms_requests
            WHERE thread_id = ? ORDER BY created_at_ms DESC LIMIT 1
          SQL
          row && { 'surface_id' => row[0], 'conversation_id' => row[1] }
        end
      end

      # ===== prompts =====

      # Insert one approval prompt (inactive until its send receipt is
      # durable; ADR-043). Idempotent on reference_digest.
      def insert_prompt(prompt_wire)
        transaction('comms.prompt.insert') do |txn|
          existing = txn.first('comms.prompt.insert.existing', <<~SQL, [prompt_wire.fetch('reference_digest')])
            SELECT 1 FROM tamoz_comms_approval_prompts WHERE reference_digest = ?
          SQL
          next :duplicate if existing

          txn.execute('comms.prompt.insert', <<~SQL, prompt_binds(prompt_wire))
            INSERT INTO tamoz_comms_approval_prompts (
              reference_digest, surface_id, surface_revision, thread_id,
              occurrence_id, interrupt_digest, required_evidence,
              correspondent_id, conversation_id, prompt_receipt, status,
              created_at_ms, activated_at_ms, consumed_at_ms, expires_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          :inserted
        end
      end

      # Activate one approval prompt only after its send receipt is durable,
      # pinning the originating message receipt (contract §7.1) so the
      # callback comparison can bind the press to the exact message the
      # buttons were attached to. A prompt without a receipt is never
      # activatable.
      def activate_prompt(reference_digest:, now:, receipt:)
        transaction('comms.prompt.activate') do |txn|
          row = txn.first('comms.prompt.activate.state', <<~SQL, [reference_digest])
            SELECT status, expires_at_ms FROM tamoz_comms_approval_prompts
            WHERE reference_digest = ?
          SQL
          next :missing unless row
          next :expired if row[1] <= now_ms(now)
          next :already_active if row[0] == 'active'

          txn.execute('comms.prompt.activate', <<~SQL, [receipt, now_ms(now), reference_digest])
            UPDATE tamoz_comms_approval_prompts
            SET status = 'active', prompt_receipt = ?, activated_at_ms = ?
            WHERE reference_digest = ? AND status = 'inactive'
          SQL
          txn.changes == 1 ? :activated : :not_consumable
        end
      end

      # Consume one ACTIVE prompt and insert its decision in ONE transaction:
      # a replayed reference can never be consumed twice, and a consumed
      # prompt never leaves a decision behind (design §9, ADR-043).
      def consume_prompt(reference_digest:, decision_wire:, now:)
        transaction('comms.prompt.consume') do |txn|
          row = txn.first('comms.prompt.consume.state', <<~SQL, [reference_digest])
            SELECT status, expires_at_ms FROM tamoz_comms_approval_prompts
            WHERE reference_digest = ?
          SQL
          next :missing unless row
          next :expired if row[1] <= now_ms(now)

          txn.execute('comms.prompt.consume', <<~SQL, [now_ms(now), reference_digest])
            UPDATE tamoz_comms_approval_prompts
            SET status = 'consumed', consumed_at_ms = ?
            WHERE reference_digest = ? AND status = 'active'
          SQL
          next :not_consumable unless txn.changes == 1

          @decisions.insert_decision_in_transaction!(txn, decision_wire)
          :consumed
        end
      end

      def prompt(reference_digest:)
        read('comms.prompt.read') do |txn|
          row = txn.first('comms.prompt.read', <<~SQL, [reference_digest])
            SELECT #{PROMPT_COLUMNS.join(', ')} FROM tamoz_comms_approval_prompts
            WHERE reference_digest = ?
          SQL
          row && PROMPT_COLUMNS.zip(row).to_h
        end
      end

      # ===== operator surface (COMMS_DESIGN §14) =====

      def surfaces
        read('comms.surface.list') do |txn|
          txn.rows('comms.surface.list', <<~SQL).map { |row| SURFACE_COLUMNS.zip(row).to_h }
            SELECT #{SURFACE_COLUMNS.join(', ')} FROM tamoz_comms_surfaces
            ORDER BY surface_id
          SQL
        end
      end

      def bindings(surface_id:)
        read('comms.binding.list') do |txn|
          txn.rows('comms.binding.list', <<~SQL, [surface_id]).map { |row| BINDING_COLUMNS.zip(row).to_h }
            SELECT #{BINDING_COLUMNS.join(', ')} FROM tamoz_comms_bindings
            WHERE surface_id = ? ORDER BY bound_at_ms DESC
          SQL
        end
      end

      def conversations(surface_id:)
        read('comms.route.list') do |txn|
          txn.rows('comms.route.list', <<~SQL, [surface_id]).map { |row| ROUTE_COLUMNS.zip(row).to_h }
            SELECT #{ROUTE_COLUMNS.join(', ')} FROM tamoz_comms_conversations
            WHERE surface_id = ? ORDER BY bound_at_ms DESC
          SQL
        end
      end

      # The active binding that admitted one conversation's correspondent
      # (the prompt needs the correspondent to scope its single-use digest).
      def binding_by_conversation(surface_id:, conversation_id:)
        bindings(surface_id:).find do |binding|
          binding.fetch('conversation_id') == conversation_id && binding.fetch('status') == 'active'
        end
      end

      def poll_state(bot_id:)
        read('comms.poll.state') do |txn|
          row = txn.first('comms.poll.state', <<~SQL, [bot_id])
            SELECT #{POLL_COLUMNS.join(', ')} FROM tamoz_comms_poll_state
            WHERE bot_id = ?
          SQL
          row && POLL_COLUMNS.zip(row).to_h
        end
      end

      # Outbox depth per status for one surface (design §14: the status
      # section shows pending depth and `:unknown` deliveries).
      def outbox_counts(surface_id:)
        read('comms.outbox.counts') do |txn|
          txn.rows('comms.outbox.counts', <<~SQL, [surface_id]).to_h { |row| [row[0], row[1]] }
            SELECT status, COUNT(*) FROM tamoz_comms_outbox
            WHERE surface_id = ? GROUP BY status
          SQL
        end
      end

      # The comms safety counters (design §16), derived from durable rows:
      # unauthorized admissions are `request` rows with no active binding
      # anywhere for that correspondent, and chat grants are membership rows
      # that reached `request` (impossible in v1 — admission ignores
      # membership, but the count is derived, not assumed).
      def admission_audit_counts
        read('comms.audit.counts') do |txn|
          {
            'unauthorized_inbound_admissions' => txn.scalar('comms.audit.unauthorized', <<~SQL),
              SELECT COUNT(*) FROM tamoz_comms_inbound i
              WHERE i.disposition = 'request'
                AND NOT EXISTS (
                  SELECT 1 FROM tamoz_comms_bindings b
                  WHERE b.surface_id = i.surface_id AND b.correspondent_id = i.correspondent_id
                    AND b.status = 'active')
            SQL
            'chat_grants' => txn.scalar('comms.audit.chat_grants', <<~SQL)
              SELECT COUNT(*) FROM tamoz_comms_inbound
              WHERE kind = 'membership' AND disposition = 'request'
            SQL
          }
        end
      end

      # ===== pairing (design §7) =====

      # All pairing challenge rows, optionally filtered by status. The digest
      # is stored, never the plaintext code. Pending scans exclude expired
      # challenges so they stop accumulating under the read path; the
      # surface/correspondent filters run in SQL so per-sender scans stay
      # bounded by that sender's own rows.
      def pairing_challenges(status: nil, surface_id: nil, correspondent_id: nil, now: nil)
        read('comms.pairing.list') do |txn|
          clauses, binds = pairing_filters(txn, status:, surface_id:, correspondent_id:, now:)
          sql = "SELECT #{PAIRING_COLUMNS.join(', ')} FROM tamoz_comms_pairing_challenges"
          sql << " WHERE #{clauses.join(' AND ')}" unless clauses.empty?
          sql << ' ORDER BY created_at_ms DESC'
          txn.rows('comms.pairing.list', sql, binds).map { |row| PAIRING_COLUMNS.zip(row).to_h }
        end
      end

      # Store the challenge digest for one unbound sender (idempotent on the
      # digest; the plaintext code travels to the sender exactly once). Older
      # LIVE pending challenges for the same (surface, correspondent,
      # conversation) are superseded in the same transaction — one live code
      # per triple — while consumed/expired rows stay for the audit trail.
      def insert_pairing_challenge(digest:, surface_id:, correspondent_id:, conversation_id:, expires_at:, now:)
        transaction('comms.pairing.insert') do |txn|
          supersede_binds = [surface_id, correspondent_id, conversation_id, backend_now_ms(txn, now), digest]
          txn.execute('comms.pairing.insert.supersede', <<~SQL, supersede_binds)
            DELETE FROM tamoz_comms_pairing_challenges
            WHERE surface_id = ? AND correspondent_id = ? AND conversation_id = ?
              AND status = 'pending' AND expires_at_ms > ? AND challenge_digest != ?
          SQL
          binds = [digest, surface_id, correspondent_id, conversation_id, now_ms(expires_at), now_ms(now)]
          txn.execute('comms.pairing.insert', <<~SQL, binds)
            INSERT OR IGNORE INTO tamoz_comms_pairing_challenges (
              challenge_digest, surface_id, correspondent_id, conversation_id,
              status, attempts, expires_at_ms, created_at_ms
            ) VALUES (?, ?, ?, ?, 'pending', 0, ?, ?)
          SQL
          txn.changes == 1 ? :inserted : :duplicate
        end
      end

      # Consume ONE pending challenge and write its binding in one transaction
      # (design §7): a crash between the two would leave a consumed challenge
      # that grants nothing. The caller verifies the code against the digest
      # and builds the binding wire; this method is the atomic commit. Expiry
      # is re-checked HERE — where authority is actually granted — so an
      # expired-but-still-pending row can never be approved.
      def approve_pairing(challenge_digest:, binding_wire:, now:)
        transaction('comms.pairing.approve') do |txn|
          txn.execute('comms.pairing.approve.consume', <<~SQL, [challenge_digest, backend_now_ms(txn, now)])
            UPDATE tamoz_comms_pairing_challenges SET status = 'consumed'
            WHERE challenge_digest = ? AND status = 'pending' AND expires_at_ms > ?
          SQL
          next :missing unless txn.changes == 1

          outcome = @routes.bind_correspondent_in_transaction!(txn, binding_wire, now:)
          next :already_bound unless outcome == :bound

          :approved
        end
      end

      private

      def stamp_cancellation_requested!(txn, thread_id:, target_request_id:, now:)
        binds = [now_ms(now), now_ms(now), thread_id]
        target_clause = if target_request_id
                          binds << target_request_id
                          ' AND request_id = ?'
                        else
                          ''
                        end
        txn.execute('comms.request.cancel.stamp', <<~SQL, binds)
          UPDATE tamoz_comms_requests
          SET cancellation_requested_at_ms = ?, updated_at_ms = ?
          WHERE thread_id = ? AND projection_state = 'admitted'
            AND cancellation_requested_at_ms IS NULL
            #{target_clause}
        SQL
        return unless target_request_id

        raise Tamoz::CheckpointConflictError, 'the cancellation target is no longer admitted' unless txn.changes == 1
      end

      def stamp_cancellation_observed!(txn, thread_id:, now:)
        txn.execute('comms.request.cancel.observed.stamp', <<~SQL, [now_ms(now), now_ms(now), thread_id])
          UPDATE tamoz_comms_requests
          SET cancellation_observed_at_ms = ?, updated_at_ms = ?
          WHERE thread_id = ? AND cancellation_requested_at_ms IS NOT NULL
            AND cancellation_observed_at_ms IS NULL
        SQL
      end

      def encode_request(operation_text, delivery_text, payload)
        payload_bytes = @checkpoints.checkpoint_codec.dump_request_payload(operation_text, payload)
        payload_digest = Wire.digest(payload_bytes, domain: 'tamoz.sqlite.request_payload')
        input_digest = Wire.digest(
          JSON.generate([operation_text, delivery_text, payload_bytes]),
          domain: 'tamoz.sqlite.request'
        )
        [payload_bytes, payload_digest, input_digest]
      end

      def insert_admitted_request!(txn, request_id, envelope_wire, surface_id:, thread:, profile_id:,
                                   reservation:, now:)
        binds = [request_id, surface_id, envelope_wire.fetch('surface_revision'),
                 envelope_wire.fetch('conversation_id'), thread, profile_id,
                 reservation, now_ms(now), now_ms(now)]
        txn.execute('comms.admit.request.upsert', <<~SQL, binds)
          INSERT OR IGNORE INTO tamoz_comms_requests (
            request_id, surface_id, surface_revision, conversation_id,
            thread_id, profile_id, reservation, projection_state,
            created_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, 'admitted', ?, ?)
        SQL
      end

      # validate_identity: false -- the latest row belongs to the session graph;
      # this checkpointer compiles against the channel-gateway graph.
      def session_checkpoint(thread_id)
        @checkpoints&.latest(thread_id:, namespace: [], validate_identity: false)
      end

      def pairing_filters(txn, status:, surface_id:, correspondent_id:, now:)
        clauses = []
        binds = []
        if status
          clauses << 'status = ?'
          binds << status
          if status == 'pending'
            clauses << 'expires_at_ms > ?'
            binds << backend_now_ms(txn, now)
          end
        end
        if surface_id
          clauses << 'surface_id = ?'
          binds << surface_id
        end
        if correspondent_id
          clauses << 'correspondent_id = ?'
          binds << correspondent_id
        end
        [clauses, binds]
      end

      # Declared intake limits read from the DEPLOYED surface row inside the
      # admit transaction — the caller's descriptor copy can drift from the
      # durable deployment, and the row is the truth admission enforces.
      def deployed_surface_limits(txn, surface_id)
        row = txn.first('comms.admit.limits', <<~SQL, [surface_id])
          SELECT descriptor_json FROM tamoz_comms_surfaces WHERE surface_id = ?
        SQL
        raise KeyError, "surface #{surface_id} is not deployed" unless row

        JSON.parse(row.fetch(0)).fetch('limits')
      end

      def recent_request_tasks(surface_id:, conversation_id:, limit:)
        rows = read('comms.history.requests') do |txn|
          txn.rows('comms.history.requests', <<~SQL, [surface_id, conversation_id, limit])
            SELECT request_id, thread_id, created_at_ms FROM tamoz_comms_requests
            WHERE surface_id = ? AND conversation_id = ?
            ORDER BY created_at_ms DESC LIMIT ?
          SQL
        end
        rows.filter_map do |request_id, thread_id, at|
          task = request_task(request_id, thread_id)
          task && { role: 'user', text: task[0, HISTORY_TEXT_CHARACTERS], at: }
        end
      end

      # The task text of one admitted request, read back from the graph inbox
      # payload. A channel turn with history nests the text under the task
      # Hash; any other non-text turn (a cancel or redirect payload) has no
      # transcript line. A corrupt durable payload is surfaced instead of being
      # silently omitted from the next model context.
      def request_task(request_id, thread_id)
        return nil unless @checkpoints

        request = @checkpoints.fetch_request(thread_id:, request_id:, namespace: [])
        task = request&.payload&.fetch('task', nil)
        task = task.fetch('text', nil) if task.is_a?(Hash)
        task.is_a?(String) ? task : nil
      end

      # Assistant transcript lines are the journaled terminal deliveries the
      # correspondent CONFIRMABLY saw (invariant 11, plan 02 work item 5):
      # only `succeeded` rows qualify. Pending, claimed, unknown and failed
      # rows never enter a later model prompt.
      def recent_terminal_deliveries(surface_id:, conversation_id:, limit:)
        rows = read('comms.history.deliveries') do |txn|
          txn.rows('comms.history.deliveries', <<~SQL, [surface_id, conversation_id, limit])
            SELECT text, created_at_ms FROM tamoz_comms_outbox
            WHERE surface_id = ? AND conversation_id = ? AND journaled = 1
              AND status = 'succeeded'
              AND kind IN ('answer', 'failed', 'stopped', 'blocked') AND part_index = 0
            ORDER BY created_at_ms DESC LIMIT ?
          SQL
        end
        rows.map do |text, at|
          { role: 'assistant', text: text[0, HISTORY_TEXT_CHARACTERS], at: }
        end
      end

      def transaction(operation, &)
        @adapter.__send__(:transaction, operation:, &)
      end

      def read(operation, &)
        @adapter.__send__(:read, operation:, &)
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists, Metrics/BlockLength
# rubocop:enable Metrics/ClassLength
# rubocop:enable Metrics/MethodLength

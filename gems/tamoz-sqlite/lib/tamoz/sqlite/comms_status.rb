# frozen_string_literal: true

require_relative 'comms_store_rows'
require_relative 'comms_request_facts'

module Tamoz
  module SQLite
    # Read-only channel status derived from durable admission and projection rows (invariant 12):
    # reference-addressed and queue-aware, with the cancellation timeline and worker state.
    class CommsStatus
      include CommsStoreRows

      # A queued request is reported as unclaimed after one backend clock tick
      # without an observed inbox claim; this is not a process-liveness claim.
      WORKER_UNCLAIMED_WINDOW_MS = 1
      # Only an ANSWER claims the completion won the race; failed and blocked settles say so plainly.
      SETTLE_WORDS = {
        'answer' => 'completed_before_effect',
        'failed' => 'failed_before_effect',
        'stopped' => 'stopped',
        'blocked' => 'blocked'
      }.freeze

      # The request a projection describes, inside its conversation.
      Target = Data.define(:surface_id, :conversation_id, :thread_id, :request_id)

      def initialize(adapter:, facts:)
        @adapter = adapter
        @facts = facts
      end

      # The settle word follows the TASK axis; an observed-but-unsettled request is the one honest
      # `stopped` — work seen stopping at the boundary while still open.
      def self.cancellation_outcome(observed:, settled:)
        return SETTLE_WORDS.fetch(settled, nil) if settled && settled != 'admitted'

        'stopped' if observed
      end

      # The active request projects on the thread it was ADMITTED to: after /new rotates the
      # generation, the route row's thread no longer names it. `now:` binds the reader's clock for
      # age arithmetic; without it the backend's time answers.
      def conversation_status(surface_id:, conversation_id:, now: nil)
        read('comms.conversation.status') do |txn|
          route = txn.first('comms.conversation.status.route', <<~SQL, [surface_id, conversation_id])
            SELECT thread_id FROM tamoz_comms_conversations
            WHERE surface_id = ? AND conversation_id = ?
          SQL
          next nil unless route

          active = active_request_row(txn, surface_id, conversation_id)
          target = Target.new(surface_id:, conversation_id:, thread_id: active&.fetch(2) || route.fetch(0),
                              request_id: active&.fetch(0))
          base_projection(txn, target, now)
            .merge(@facts.conversation_runtime_status(target))
            .merge('active_delivery_state' => @facts.active_delivery_state(target),
                   'open_request_refs' => open_request_refs(txn, surface_id, conversation_id))
        end
      end

      # Resolves ONE request by its short reference inside ONE conversation — caller-bound: a foreign
      # ref is :unknown_ref here even though it resolves elsewhere.
      def request_status(surface_id:, conversation_id:, ref:, now: nil)
        read('comms.request.status') do |txn|
          resolved = resolve_request_ref(txn, surface_id, conversation_id, ref)
          next resolved unless resolved.is_a?(Array)

          target = Target.new(surface_id:, conversation_id:, thread_id: resolved[1], request_id: resolved[0])
          base_projection(txn, target, now)
            .merge(@facts.request_runtime_status(target))
            .merge('terminal_reason' => @facts.terminal_reason_for(target.thread_id, target.request_id))
        end
      end

      private

      def resolve_request_ref(txn, surface_id, conversation_id, ref)
        return :unknown_ref unless ref.is_a?(String) && ref.match?(REQUEST_REF_PATTERN)

        matches = txn.rows('comms.request.status.resolve',
                           <<~SQL, [surface_id, conversation_id, ref[1, REQUEST_REF_WIDTH]])
                             SELECT request_id, thread_id FROM tamoz_comms_requests
                             WHERE surface_id = ? AND conversation_id = ?
                               AND substr(request_id, 1, #{REQUEST_REF_WIDTH}) = ?
                             ORDER BY created_at_ms ASC
                           SQL
        return :unknown_ref if matches.empty?
        return :ambiguous_ref if matches.length > 1

        matches.first
      end

      def base_projection(txn, target, now)
        open_requests = open_requests_for(txn, target.surface_id, target.conversation_id)
        { 'thread_id' => target.thread_id, 'state' => open_requests.positive? ? 'accepted' : 'idle',
          'open_requests' => open_requests, 'request_id' => target.request_id }
          .merge(queue_facts(txn, target, now))
          .merge(cancellation_document(txn, target.request_id, now))
          .merge(worker_status(txn, target, now))
      end

      # The cancellation timeline nests under one key so it never collides with the projection's axes.
      def cancellation_document(txn, request_id, now)
        facts = request_id ? cancellation_facts(txn, request_id, now) : {}
        facts.empty? ? {} : { 'cancellation' => facts }
      end

      # `requested` is the /cancel stamp, `observed` the runner's consumption stamp, and the terminal
      # point the recorded settle kind; a raced completion is never rendered as a stop (invariant 9).
      def cancellation_facts(txn, request_id, now)
        settled, requested, observed = txn.first('comms.conversation.status.cancellation', <<~SQL, [request_id])
          SELECT projection_state, cancellation_requested_at_ms, cancellation_observed_at_ms
          FROM tamoz_comms_requests WHERE request_id = ?
        SQL
        return {} unless requested

        clock = backend_now_ms(txn, now)
        terminal = self.class.cancellation_outcome(observed:, settled:)
        { 'requested_at_ms' => requested, 'requested_age_ms' => clock - requested,
          'observed_at_ms' => observed, 'observed_age_ms' => observed && (clock - observed),
          'terminal' => terminal, 'state' => if terminal
                                               'terminal'
                                             else
                                               (observed ? 'observed' : 'requested')
                                             end }
          .reject { |key, value| value.nil? && key.start_with?('observed') }
      end

      # The addressed request's short reference, its position among the conversation's admitted
      # requests, and the age of the oldest admitted request.
      def queue_facts(txn, target, now)
        return {} unless target.request_id

        oldest = txn.scalar('comms.conversation.status.oldest_open',
                            <<~SQL, [target.surface_id, target.conversation_id])
                              SELECT MIN(created_at_ms) FROM tamoz_comms_requests
                              WHERE surface_id = ? AND conversation_id = ? AND projection_state = 'admitted'
                            SQL
        { 'request_ref' => request_ref(target.request_id), 'queue_position' => queue_position(txn, target),
          'queue_age_ms' => oldest && (backend_now_ms(txn, now) - oldest) }.compact
      end

      def queue_position(txn, target)
        row = txn.first('comms.conversation.status.queue_peer', <<~SQL, [target.request_id])
          SELECT created_at_ms FROM tamoz_comms_requests WHERE request_id = ?
        SQL
        return 0 unless row

        peer_at = row.fetch(0)
        binds = [target.surface_id, target.conversation_id, peer_at, peer_at, target.request_id]
        txn.scalar('comms.conversation.status.queue_position', <<~SQL, binds).to_i
          SELECT COUNT(*) FROM tamoz_comms_requests
          WHERE surface_id = ? AND conversation_id = ? AND projection_state = 'admitted'
            AND (created_at_ms < ? OR (created_at_ms = ? AND request_id < ?))
        SQL
      end

      def worker_status(txn, target, now)
        return {} unless target.request_id

        row = txn.first('comms.request.status.worker', <<~SQL, [target.thread_id, DEFAULT_NAMESPACE, target.request_id])
          SELECT status, created_at_ms FROM tamoz_requests
          WHERE thread_id = ? AND namespace = ? AND request_id = ?
        SQL
        state = row && worker_state(row, backend_now_ms(txn, now))
        state ? { 'worker_state' => state } : {}
      end

      def worker_state(row, current_ms)
        case row.fetch(0)
        when 'queued' then if [current_ms - row.fetch(1),
                               0].max >= WORKER_UNCLAIMED_WINDOW_MS
                             'queued-unclaimed'
                           else
                             'accepted'
                           end
        when 'claimed', 'running' then 'working'
        end
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
    end
  end
end

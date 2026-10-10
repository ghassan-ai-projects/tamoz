# frozen_string_literal: true

module Tamoz
  module SQLite
    # What one admitted request has done so far, read from the checkpoints and the outbox: its task,
    # effects, capability, lifecycle and delivery states.
    # :reek:FeatureEnvy, :reek:UtilityFunction
    class CommsRequestFacts
      DELIVERY_STATUSES = %w[pending claimed succeeded failed unknown].freeze
      UNKNOWN_LIFECYCLE = { 'phase' => 'unknown', 'event_kind' => 'unknown', 'next_action' => 'inspect' }.freeze

      def initialize(checkpoints:, outbox:)
        @checkpoints = checkpoints
        @outbox = outbox
      end

      def conversation_runtime_status(target)
        effects = effect_state(target) { conversation_effect_statuses(target.thread_id) }
        deliveries = delivery_state(target.surface_id) { |row| row.fetch('conversation_id') == target.conversation_id }
        runtime_status(target, effects, deliveries)
      end

      def request_runtime_status(target)
        runtime_status(target, effect_state(target) { request_effect_statuses(target) }, request_delivery_state(target))
      end

      def active_delivery_state(target) = target.request_id ? request_delivery_state(target) : 'none'

      def terminal_reason_for(thread_id, request_id)
        lifecycle_events(session_checkpoint(thread_id)&.state, request_id).last&.fetch('terminal_reason', nil)
      end

      def task_state_for(thread_id, request_id)
        return 'idle' unless request_id

        request = fetch_request(thread_id, request_id)
        request ? request.status.to_s : 'not_started'
      end

      private

      def runtime_status(target, effect_state, delivery_state)
        { 'task_state' => task_state_for(target.thread_id, target.request_id), 'effect_state' => effect_state,
          'capability_state' => capability_state_for(target), 'delivery_state' => delivery_state }
          .merge(lifecycle_status_for(target.thread_id, target.request_id))
      end

      def fetch_request(thread_id, request_id)
        @checkpoints&.fetch_request(thread_id:, request_id:, namespace: [])
      end

      # The effect statuses are read only once the request has started running.
      def effect_state(target)
        return 'not_started' unless target.request_id

        request = fetch_request(target.thread_id, target.request_id)
        return 'not_started' unless request && %i[running completed failed].include?(request.status)

        summarize(yield, pending: %w[prepared running reconcile], empty: 'not_started')
      end

      def conversation_effect_statuses(thread_id)
        receipts = Array(session_checkpoint(thread_id)&.state&.fetch(:effect_receipts, nil))
        statuses = receipts.filter_map { |row| row.fetch('status', nil).to_s }
        return statuses unless statuses.empty?

        @checkpoints.effect_census.filter_map { |row| row[:status].to_s if row[:thread_id] == thread_id }
      end

      def request_effect_statuses(target)
        @checkpoints.effect_census.filter_map do |row|
          row[:status].to_s if row[:thread_id] == target.thread_id && row[:request_id] == target.request_id
        end
      end

      def capability_state_for(target)
        return 'not_started' unless @checkpoints && target.request_id

        state = session_checkpoint(target.thread_id)&.state
        return 'invoked' if lifecycle_events(state, target.request_id).any? { |event| event.key?('capability_id') }

        session_bound?(state) ? 'bound' : 'not_inspected'
      end

      def session_bound?(state) = Hash(state&.fetch(:session, nil)).key?('tool_catalog_digest')

      def lifecycle_status_for(thread_id, request_id)
        event = lifecycle_events(session_checkpoint(thread_id)&.state, request_id).last
        return UNKNOWN_LIFECYCLE unless event

        event_type = event.fetch('event_type')
        { 'phase' => event.fetch('phase', 'unknown'), 'event_kind' => event_type,
          'event_sequence' => event.fetch('sequence'), 'next_action' => next_action(event_type),
          'terminal_reason' => event.fetch('terminal_reason', nil) }.compact
      end

      def next_action(event_type) = { 'terminal' => 'none', 'approval' => 'approval' }.fetch(event_type, 'continue')

      def lifecycle_events(state, request_id)
        Array(state&.fetch(:lifecycle_events, nil)).select { |event| event.fetch('request_id', nil) == request_id }
      end

      def request_delivery_state(target)
        delivery_state(target.surface_id) do |row|
          row.fetch('conversation_id') == target.conversation_id && row.fetch('request_id') == target.request_id
        end
      end

      def delivery_state(surface_id, &)
        rows = @outbox.outbox_rows(surface_id:, statuses: DELIVERY_STATUSES, limit: 500).select(&)
        summarize(rows.map { |row| row.fetch('status') }, pending: %w[pending claimed], empty: 'none')
      end

      def summarize(statuses, pending:, empty:)
        return empty if statuses.empty?
        return 'unknown' if statuses.include?('unknown')
        return 'pending' if statuses.intersect?(pending)
        return 'failed' if statuses.include?('failed')

        'succeeded'
      end

      # validate_identity: false -- the latest row belongs to the session graph;
      # this checkpointer compiles against the channel-gateway graph.
      def session_checkpoint(thread_id)
        @checkpoints&.latest(thread_id:, namespace: [], validate_identity: false)
      end
    end
  end
end

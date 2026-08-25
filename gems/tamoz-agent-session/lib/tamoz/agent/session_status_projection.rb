# frozen_string_literal: true

module Tamoz
  module Agent
    # Projects a SessionView and its durable lifecycle records into the bounded
    # status wire consumed by CLI, worker events, and channel status. It never
    # includes model output, remote content, or authority-bearing payloads.
    # rubocop:disable Metrics/ModuleLength -- one bounded status-wire contract.
    module SessionStatusProjection
      SCHEMA = 1
      EVENT_KINDS = %w[model_turn tool_started tool_result approval wait checkpoint handoff terminal].freeze
      DELIVERY_STATES = %w[not_reported not_applicable pending succeeded failed unknown].freeze
      EFFECT_STATES = %w[not_started pending waiting succeeded failed unknown terminal none].freeze
      MAX_METADATA_BYTES = 512

      module_function

      # rubocop:disable Metrics/AbcSize -- one bounded status document.
      def document(view, request_id: nil, delivery_state: 'not_reported')
        delivery_state = validate_delivery_state(delivery_state)
        event = latest_event(view)
        {
          'schema' => SCHEMA,
          'thread_id' => view.thread_id,
          'request_id' => request_id || view.request_id || event&.fetch('request_id', 'unknown') || 'unknown',
          'execution_id' => view.execution_id,
          'task_state' => task_state(view),
          'phase' => view.phase.to_s,
          'effect_state' => effect_state(view, event),
          'capability_state' => capability_state(view, event),
          'delivery_state' => delivery_state,
          'next_action' => next_action(view),
          'terminal_reason' => view.terminal&.fetch('reason', nil),
          'effect_key' => bounded_metadata(event&.fetch('effect_key', nil)),
          'capability' => bounded_metadata(event&.fetch('capability_id', nil)),
          'source_id' => bounded_metadata(event&.fetch('source_id', nil))
        }.compact
      end
      # rubocop:enable Metrics/AbcSize

      def lifecycle_events(view, request_id: nil, delivery_state: 'not_reported')
        delivery_state = validate_delivery_state(delivery_state)
        Array(view.lifecycle_events).map do |event|
          project_event(view, event, request_id:, delivery_state:)
        end
      end

      def project_event(view, event, request_id:, delivery_state:)
        kind = event.fetch('event_type')
        validate_event_kind(kind)
        build_event(view, event, kind, request_id:, delivery_state:).compact
      end

      def build_event(view, event, kind, request_id:, delivery_state:)
        {
          'schema' => SCHEMA,
          'kind' => kind,
          'thread_id' => event.fetch('thread_id'),
          'request_id' => request_id || event.fetch('request_id'),
          'execution_id' => event.fetch('execution_id'),
          'sequence' => event.fetch('sequence'),
          'iteration' => event.fetch('iteration', nil),
          'effect_key' => bounded_metadata(event.fetch('effect_key', nil)),
          'capability' => bounded_metadata(event.fetch('capability_id', nil)),
          'source_id' => bounded_metadata(event.fetch('source_id', nil)),
          'phase' => event.fetch('phase'),
          'task_state' => kind == 'terminal' ? task_state(view) : 'running',
          'effect_state' => normalize_effect_state(event.fetch('effect_state')),
          'capability_state' => event.key?('capability_id') ? 'invoked' : 'not_requested',
          'result' => event_result(event),
          'delivery_state' => delivery_state,
          'terminal_reason' => event.fetch('terminal_reason', nil)
        }
      end

      def task_state(view)
        view.status.to_s
      end

      def effect_state(view, event)
        return 'unknown' if view.blocked
        return 'waiting' unless view.interrupts.empty?

        receipt = Array(view.effect_receipts).last
        return normalize_effect_state(receipt.fetch('status')) if receipt
        return normalize_effect_state(event.fetch('effect_state')) if event
        return 'none' if view.status == :completed

        'pending'
      end

      def capability_state(view, event)
        return 'invoked' if event&.fetch('capability_id', nil)
        return 'planned' if view.accepted_plan && view.accepted_plan.fetch('plan', {}).fetch('steps', []).any?

        'not_requested'
      end

      def next_action(view)
        return 'approval' unless view.interrupts.empty?
        return 'resolve_effect' if view.blocked
        return 'none' if %i[completed failed].include?(view.status)

        'continue'
      end

      def latest_event(view)
        Array(view.lifecycle_events).last
      end

      def validate_event_kind(kind)
        return if EVENT_KINDS.include?(kind)

        raise CheckpointCorruptionError, "lifecycle event kind #{kind.inspect} is not allowlisted"
      end

      def event_result(event)
        {
          'bytes' => event.fetch('output_bytes', nil),
          'provenance' => bounded_metadata(event.fetch('provenance', nil)),
          'truncated' => event.fetch('truncated', nil)
        }.compact
      end

      def validate_delivery_state(value)
        state = String(value)
        return state if DELIVERY_STATES.include?(state)

        raise ArgumentError, "delivery state #{value.inspect} is not allowlisted"
      end

      def normalize_effect_state(value)
        state = String(value)
        return state if EFFECT_STATES.include?(state)

        'unknown'
      end

      def bounded_metadata(value)
        return nil if value.nil?

        String(value).encode(Encoding::UTF_8).byteslice(0, MAX_METADATA_BYTES).scrub
      rescue EncodingError
        '[invalid metadata]'
      end
      private_class_method(
        :bounded_metadata, :validate_delivery_state, :normalize_effect_state, :validate_event_kind,
        :event_result, :build_event
      )
    end
    # rubocop:enable Metrics/ModuleLength
  end
end

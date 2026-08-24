# frozen_string_literal: true

require_relative 'errors'

module Tamoz
  module Comms
    # The closed external lifecycle vocabulary (plan 02, work item 1): one
    # task axis, one independent delivery axis, and the typed reason-code
    # registry every surface renders identically. Pure data plus pure
    # functions — zero I/O — so the benchmark parity metric and both surfaces
    # read a single definition. Unknown input raises instead of guessing.
    module Lifecycle
      TASK_STATES = %w[accepted queued running waiting completed failed blocked stopped].freeze
      DELIVERY_STATES = %w[pending delivered failed unknown].freeze

      REASONS = {
        authentication_refused: 'the surface credential was refused',
        capacity_refused: 'outbox capacity is saturated',
        integrity_conflict: 'same identity, different payload bytes',
        open_request_limit: 'too many open requests',
        inbound_too_large: 'inbound text exceeds the declared byte limit',
        cancelled_by_user: 'the correspondent cancelled the turn',
        provider_failed: 'the model provider call failed'
      }.freeze

      REQUEST_REF_WIDTH = 10

      # Internal projection -> external task state. Names that already match
      # the closed set map to themselves; `idle` means no accepted context.
      TASK_TRANSLATIONS = {
        'idle' => nil,
        'admitted' => 'accepted',
        'queued' => 'queued',
        'running' => 'running',
        'waiting' => 'waiting',
        'blocked' => 'blocked',
        'completed' => 'completed',
        'failed' => 'failed',
        'stopped' => 'stopped'
      }.freeze

      # Outbox row status -> external delivery state; a claimed row is still
      # pending until the transport outcome is durable.
      DELIVERY_TRANSLATIONS = {
        'pending' => 'pending',
        'claimed' => 'pending',
        'succeeded' => 'delivered',
        'failed' => 'failed',
        'unknown' => 'unknown'
      }.freeze

      # Stable, short, NON-AUTHORIZING display reference for one request:
      # `r` plus its first ten hex characters. Uniqueness comes from the
      # store resolving that prefix within the caller's conversation
      # (`:unknown_ref` / `:ambiguous_ref`), never from the string itself.
      module RequestRef
        module_function

        def for(request_id)
          "r#{String(request_id)[0, REQUEST_REF_WIDTH]}"
        end
      end

      module_function

      def task_state_for(internal_state)
        translate(TASK_TRANSLATIONS, internal_state, 'internal state')
      end

      def delivery_state_for(outbox_status)
        translate(DELIVERY_TRANSLATIONS, outbox_status, 'delivery status')
      end

      def translate(table, value, label)
        key = String(value)
        raise ValidationError, "unknown #{label} #{key.inspect}" unless table.key?(key)

        table.fetch(key)
      end
    end
  end
end

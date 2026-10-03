# frozen_string_literal: true

module Tamoz
  module Circuit
    # The stored shape of a circuit record, checked before any of it is trusted.
    module RecordSchema
      KEYS = %w[
        conditions_met format_version last_failure last_reset_at
        last_reset_evidence opened_at_wall_ms owners probe_window_ms
        reset_authority scope_id scope_type state threshold
      ].freeze

      module_function

      def validate!(payload, scope, scope_id)
        validate_version!(payload)
        validate_key_set!(payload)
        validate_scope!(payload, scope, scope_id)
        validate_state_fields!(payload)
        validate_lifecycle_fields!(payload)
        validate_open_state!(payload)
        OwnerSchema.validate!(payload['owners'], scope)
        validate_conditions_met!(payload['conditions_met'])
        validate_last_failure!(payload['last_failure'])
      end

      def validate_version!(payload)
        Circuit.corrupt_record!('a circuit record must be a mapping') unless payload.is_a?(Hash)
        version = payload['format_version']
        Circuit.corrupt_record!('a circuit record must carry an integer format version') unless version.is_a?(Integer)
        return unless version > FORMAT_VERSION

        raise CheckpointVersionError, "unsupported circuit record format version #{version}"
      end

      def validate_key_set!(payload)
        extra = payload.keys.map(&:to_s) - KEYS
        Circuit.corrupt_record!("unexpected keys #{extra.sort.join(', ')}") unless extra.empty?
        missing = KEYS - payload.keys.map(&:to_s)
        Circuit.corrupt_record!("missing keys #{missing.sort.join(', ')}") unless missing.empty?
      end

      def validate_scope!(payload, scope, scope_id)
        unless payload['scope_type'] == scope.scope_type
          Circuit.corrupt_record!('scope type does not match its namespace')
        end
        Circuit.corrupt_record!('scope id is missing') unless present_string?(payload['scope_id'])
        return unless scope_id && payload['scope_id'] != scope_id.to_s

        Circuit.corrupt_record!('scope id does not match its key digest')
      end

      def validate_state_fields!(payload)
        Circuit.corrupt_record!("state must be #{STATES.join(' or ')}") unless STATES.include?(payload['state'])
        unless payload['threshold'].is_a?(Integer) && payload['threshold'] >= 1
          Circuit.corrupt_record!('threshold must be an integer >= 1')
        end
        return if payload['probe_window_ms'].is_a?(Integer) && payload['probe_window_ms'].positive?

        Circuit.corrupt_record!('probe_window_ms must be a positive duration')
      end

      def validate_lifecycle_fields!(payload)
        Circuit.corrupt_record!('reset_authority is missing') unless present_string?(payload['reset_authority'])
        validate_time!(payload['opened_at_wall_ms'], 'opened_at_wall_ms')
        validate_time!(payload['last_reset_at'], 'last_reset_at')
        return if optional_digest?(payload['last_reset_evidence'])

        Circuit.corrupt_record!('last_reset_evidence must be a digest')
      end

      def validate_open_state!(payload)
        return unless payload['state'] == 'open' && payload['opened_at_wall_ms'].nil?

        Circuit.corrupt_record!('an open circuit must record when it opened')
      end

      def validate_time!(value, name)
        return if value.nil?
        return if value.is_a?(Integer) && !value.negative?

        Circuit.corrupt_record!("#{name} must be a non-negative integer")
      end

      def validate_conditions_met!(entries)
        Circuit.corrupt_record!('conditions_met must be a list') unless entries.is_a?(Array)
        if entries.length > MAX_CONDITIONS_MET
          Circuit.corrupt_record!("conditions_met exceeds the #{MAX_CONDITIONS_MET} bound")
        end
        return if entries.all? { |entry| evidence_entry?(entry) }

        Circuit.corrupt_record!('a conditions_met entry is invalid')
      end

      def validate_last_failure!(value)
        return if value.nil?

        Circuit.corrupt_record!('last_failure is invalid') unless value.is_a?(Hash) && value['kind'].is_a?(String)
        return if optional_digest?(value['context_digest'])

        Circuit.corrupt_record!('last_failure context digest is invalid')
      end

      def evidence_entry?(entry)
        entry.is_a?(Hash) && DIGEST_PATTERN.match?(entry['digest'].to_s) && entry['observed_at_ms'].is_a?(Integer)
      end

      def present_string?(value)
        value.is_a?(String) && !value.empty?
      end

      def optional_digest?(value)
        value.nil? || DIGEST_PATTERN.match?(value.to_s)
      end
    end
  end
end

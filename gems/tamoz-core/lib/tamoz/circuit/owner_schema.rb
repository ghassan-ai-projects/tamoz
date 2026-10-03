# frozen_string_literal: true

module Tamoz
  module Circuit
    # The stored shape of a circuit record's owner map and each owner's condition sub-states.
    module OwnerSchema
      module_function

      def validate!(owners, scope)
        Circuit.corrupt_record!('owners must be a mapping') unless owners.is_a?(Hash)
        Circuit.corrupt_record!("owners exceed the #{MAX_CIRCUIT_OWNERS} bound") if owners.length > MAX_CIRCUIT_OWNERS

        owners.each { |owner_id, state| validate_owner!(owner_id, state, scope) }
      end

      def validate_owner!(owner_id, state, scope)
        Circuit.corrupt_record!('an owner id is invalid') unless owner_id?(owner_id)
        Circuit.corrupt_record!("owner #{owner_id} state must be a mapping") unless state.is_a?(Hash)
        unless (state.keys.map(&:to_s) - %w[conditions failures]).empty?
          Circuit.corrupt_record!("owner #{owner_id} state has unexpected keys")
        end
        Circuit.corrupt_record!("owner #{owner_id} failure count is invalid") unless count?(state['failures'])
        validate_owner_conditions!(state['conditions'], owner_id, scope)
      end

      def validate_owner_conditions!(conditions, owner_id, scope)
        Circuit.corrupt_record!("owner #{owner_id} conditions must be a mapping") unless conditions.is_a?(Hash)
        conditions.each do |condition_id, sub|
          unless scope.condition(condition_id)
            Circuit.corrupt_record!("owner #{owner_id} carries unregistered condition #{condition_id}")
          end
          validate_sub_state!(sub, condition_id, owner_id)
        end
      end

      def validate_sub_state!(sub, condition_id, owner_id)
        Circuit.corrupt_record!("condition #{condition_id} sub-state must be a mapping") unless sub.is_a?(Hash)
        case sub['kind']
        when 'immediate' then validate_immediate_sub!(sub, condition_id)
        when 'window', 'rate' then validate_window_sub!(sub, condition_id)
        when 'run' then validate_run_sub!(sub, condition_id)
        else Circuit.corrupt_record!("condition #{condition_id} sub-state kind is unknown for owner #{owner_id}")
        end
      end

      def validate_immediate_sub!(sub, condition_id)
        Circuit.corrupt_record!("condition #{condition_id} count is invalid") unless count?(sub['count'])
      end

      def validate_window_sub!(sub, condition_id)
        events = sub['events']
        unless events.is_a?(Array) && events.length <= MAX_WINDOW_EVENTS
          Circuit.corrupt_record!("condition #{condition_id} events exceed the #{MAX_WINDOW_EVENTS} bound")
        end
        return if events.all? { |event| event.is_a?(Hash) && event['observed_at_ms'].is_a?(Integer) }

        Circuit.corrupt_record!("condition #{condition_id} carries an invalid event")
      end

      def validate_run_sub!(sub, condition_id)
        counts = sub['counts']
        return if counts.is_a?(Hash) && counts.length <= MAX_RUN_FINGERPRINTS && counts.values.all? { count?(_1) }

        Circuit.corrupt_record!("condition #{condition_id} run counts are invalid")
      end

      def owner_id?(value)
        value.is_a?(String) && !value.empty? && value.bytesize <= MAX_IDENTITY_BYTES
      end

      def count?(value)
        value.is_a?(Integer) && !value.negative?
      end
    end
  end
end

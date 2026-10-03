# frozen_string_literal: true

module Tamoz
  module Core
    # The one shape of a RECONSIDER payload the stream module and the agent intake share.
    module ReconsiderationPayload
      module_function

      # P6: the RECONSIDER payload normalization — a Hash with the four
      # string-keyed members (prior_decision/commands/outcomes/correction). Homed
      # in core so both the stream module and the agent intake node consume ONE
      # contract (symbol- or string-keyed input, typed refusal on a half-shaped
      # payload).
      def normalize(hash)
        raise Tamoz::Error, 'reconsideration payload is not an object' unless hash.is_a?(Hash)

        normalized = hash.transform_keys(&:to_s)
        missing = %w[prior_decision commands outcomes correction].reject do |key|
          normalized.key?(key)
        end
        unless missing.empty?
          raise Tamoz::Error,
                "reconsideration payload is missing: #{missing.join(', ')}"
        end

        {
          'prior_decision' => normalized.fetch('prior_decision'),
          'commands' => Array(normalized['commands']),
          'outcomes' => Array(normalized['outcomes']),
          'correction' => normalized.fetch('correction')
        }
      end
    end
    private_constant :ReconsiderationPayload
  end
end

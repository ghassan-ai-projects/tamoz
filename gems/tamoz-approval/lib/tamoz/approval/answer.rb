# frozen_string_literal: true

module Tamoz
  module Approval
    module Answer
      APPROVE_TOKENS = %w[y yes a approve].freeze
      DENY_TOKENS = %w[n no d deny].freeze
      VERDICTS = %i[approve deny].freeze

      module_function

      def parse(string)
        normalized = string.to_s.strip.downcase
        return :approve if APPROVE_TOKENS.include?(normalized)
        return :deny if DENY_TOKENS.include?(normalized)

        nil
      end
    end
  end
end

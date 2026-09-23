# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # Decides whether a request continues the current request series (same
    # header bytes) or starts a new one, and why.
    module Series
      REASONS = %w[initial resume change series].freeze

      # Whether a request starts a series, and the logged reason.
      Decision = Data.define(:starts, :reason, :header_digest) do
        def to_h = { 'starts' => starts, 'reason' => reason, 'header_digest' => header_digest }
      end

      module_function

      def admit(header:, previous_digest:, resumed: false, declared: false)
        digest = header.digest
        return Decision.new(starts: true, reason: 'initial', header_digest: digest) if previous_digest.nil?
        return Decision.new(starts: true, reason: 'change', header_digest: digest) unless previous_digest == digest
        return Decision.new(starts: true, reason: 'series', header_digest: digest) if declared
        return Decision.new(starts: false, reason: 'resume', header_digest: digest) if resumed

        Decision.new(starts: false, reason: nil, header_digest: digest)
      end
    end
  end
end

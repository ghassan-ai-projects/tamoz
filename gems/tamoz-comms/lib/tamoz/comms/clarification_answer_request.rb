# frozen_string_literal: true

module Tamoz
  module Comms
    # The durable request id for one clarification answer. The target is part
    # of the id so the worker cannot apply a queued answer to a later pause on
    # the same thread.
    module ClarificationAnswerRequest
      PREFIX = 'clarification-answer-'
      TARGET_PATTERN = /\A#{Regexp.escape(PREFIX)}([0-9a-f]{64})\z/

      module_function

      def id_for(target_request_id)
        target = String(target_request_id)
        return "#{PREFIX}#{target}" if target.match?(/\A[0-9a-f]{64}\z/)

        raise ValidationError, 'clarification target request id must be a 64-char hex digest'
      end

      def target_id(request_id)
        match = TARGET_PATTERN.match(request_id.to_s)
        match && match[1]
      end
    end
  end
end

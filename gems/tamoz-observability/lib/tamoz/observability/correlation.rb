# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Observability
    # Identity is derived, never generated (design §6.2): a pure function of
    # the durable turn identity, so a resumed turn, a duplicated delivery and
    # an offline reconstruction all compute the same ids with nothing stored.
    module Correlation
      TRACE_ID_BYTES = 8
      SPAN_ID_BYTES = 4

      module_function

      def trace_id(thread_id:, execution_id:)
        Digest::SHA256.hexdigest("tamoz.trace.v1\n#{canonical([thread_id, execution_id])}")
                      .slice(0, TRACE_ID_BYTES * 2)
      end

      def span_id(trace_id:, kind:, anchor:)
        Digest::SHA256.hexdigest("tamoz.span.v1\n#{canonical([trace_id, kind, anchor])}")
                      .slice(0, SPAN_ID_BYTES * 2)
      end

      def canonical(values)
        "[#{values.map { |value| JSON.generate(value.to_s) }.join(',')}]"
      end
    end
  end
end

# frozen_string_literal: true

module Tamoz
  module Graph
    # Determines whether a durable request is still applicable to a checkpoint.
    # :reek:FeatureEnvy :reek:ControlParameter :reek:TooManyStatements :reek:DataClump -- request
    # operation semantics are the complete responsibility of this policy object.
    class RequestStaleness
      def initialize(compiled)
        @compiled = compiled
        freeze
      end

      def reason(checkpoint, request)
        case request.operation
        when :redirect then nil
        when :resume then resume_reason(checkpoint, request)
        when :retry then status_reason(checkpoint, :failed, 'latest checkpoint is not failed')
        when :continue then status_reason(checkpoint, :running, 'latest checkpoint has no runnable frontier')
        when :turn, :fork then turn_reason(checkpoint, request)
        end
      end

      private

      attr_reader :compiled

      def resume_reason(checkpoint, request)
        return nil if request.status == :running && checkpoint&.status == :running

        compiled.__send__(:stale_resume_reason, checkpoint, request)
      end

      def turn_reason(checkpoint, request)
        if request.status == :running
          return status_reason(checkpoint, :running, 'latest checkpoint has no runnable frontier')
        end

        'latest checkpoint is not terminal' if checkpoint && !%i[completed failed].include?(checkpoint.status)
      end

      def status_reason(checkpoint, required, reason)
        compiled.__send__(:stale_status_reason, checkpoint, required, reason)
      end
    end
  end
end

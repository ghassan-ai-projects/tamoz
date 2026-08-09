# frozen_string_literal: true

module Tamoz
  module SQLite
    # Whether a claimed request may still run, and what to record when it may
    # not. Pure policy: no statement, no transaction.
    class RequestStaleness
      MAX_REASON_BYTES = 512

      def initialize(state_codec)
        @state_codec = state_codec
        freeze
      end

      # The validator's verdict, or nil when the request is still applicable.
      # A validator that raises is a configuration fault, not a stale request.
      def reason_for(validator, request, checkpoint)
        reason = begin
          validator.call(request, checkpoint)
        rescue ConfigurationError
          raise
        rescue StandardError => e
          raise ConfigurationError.new('request staleness validation failed'), cause: e
        end
        validate_reason!(reason)
      end

      def transition_evidence(operation:, reason:, checkpoint_id:)
        {
          'kind' => 'claim_validation',
          'operation' => operation.to_s,
          'reason' => reason,
          'checkpoint_id' => checkpoint_id
        }
      end

      # The durable failure body a stale claim records.
      def terminal_payload(operation:, reason:)
        @state_codec.dump(
          'graph_status' => 'failed',
          'reason' => reason,
          'evidence' => { 'kind' => 'claim_validation', 'operation' => operation.to_s }
        )
      end

      def terminal_transition(request_id:, execution_id:, operation:, reason:)
        response = terminal_payload(operation:, reason:)
        {
          'request_id' => request_id,
          'execution_id' => execution_id,
          'action' => 'failed',
          'response' => response,
          'response_digest' => Wire.digest(response, domain: 'tamoz.sqlite.request_response'),
          'retryable' => nil
        }.freeze
      end

      private

      # The reason is persisted in `terminal_error`, so it is bounded and free
      # of control characters before it can reach a log or a transcript.
      def validate_reason!(reason)
        return nil if reason.nil?

        unless reason.is_a?(String) &&
               reason.valid_encoding? &&
               !reason.empty? &&
               reason.bytesize <= MAX_REASON_BYTES &&
               reason !~ /[[:cntrl:]]/
          raise ConfigurationError, 'request staleness validator returned an invalid reason'
        end

        reason
      end
    end
  end
end

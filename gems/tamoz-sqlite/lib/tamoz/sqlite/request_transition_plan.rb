# frozen_string_literal: true

module Tamoz
  module SQLite
    # What a request transition writes, decided before anything is written.
    # Pure policy: no statement, no transaction.
    RequestTransitionPlan = Data.define(
      :from_status, :to_status, :response, :response_digest,
      :terminal_error, :terminal_error_digest, :retryable, :evidence
    )

    # Reopened rather than built in a `Data.define` block: a constant assigned
    # inside that block binds to the enclosing module, not to this class.
    class RequestTransitionPlan
      STARTABLE = %w[claimed redirecting].freeze
      TERMINABLE = %w[running claimed].freeze
      TRANSITIONABLE = %w[claimed running redirecting].freeze
      ACTIONS = %w[running completed failed].freeze

      STATUS = 7
      EXECUTION_ID = 10
      RETRYABLE = 18

      def self.for(row:, transition:, checkpoint_id:, evidence_override: nil)
        from_status = row.fetch(STATUS)
        action = transition.fetch('action')
        validate_row!(row, transition, from_status)
        validate_action!(action, from_status, evidence_override)

        failed = action == 'failed'
        terminal_error = failed ? transition.fetch('response') : nil
        new(
          from_status:,
          to_status: action,
          response: failed ? nil : transition.fetch('response'),
          response_digest: failed ? nil : transition.fetch('response_digest'),
          terminal_error:,
          terminal_error_digest: terminal_error &&
            Wire.digest(terminal_error, domain: 'tamoz.sqlite.request_error'),
          retryable: transition.fetch('retryable'),
          evidence: evidence_override || { 'kind' => action, 'checkpoint_id' => checkpoint_id }
        )
      end

      def self.validate_row!(row, transition, from_status)
        unless row.fetch(EXECUTION_ID) == transition.fetch('execution_id')
          raise CheckpointConflictError, 'request execution identity is mismatched'
        end
        unless TRANSITIONABLE.include?(from_status)
          raise CheckpointConflictError, "request status #{from_status} cannot transition"
        end
        return if row.fetch(RETRYABLE).nil? || row.fetch(RETRYABLE).is_a?(Integer)

        raise CheckpointCorruptionError, 'request retryable flag is invalid'
      end
      private_class_method :validate_row!

      def self.validate_action!(action, from_status, evidence_override)
        raise ConfigurationError, 'request transition action is invalid' unless ACTIONS.include?(action)

        if action == 'running' && !STARTABLE.include?(from_status)
          raise CheckpointConflictError, 'only a claimed or redirecting request can start'
        end
        if action != 'running' && !TERMINABLE.include?(from_status)
          raise CheckpointConflictError,
                'only a running request or atomic claimed operation can become terminal'
        end
        return if evidence_override.nil? || evidence_override.is_a?(Hash)

        raise ConfigurationError, 'request transition evidence override is invalid'
      end
      private_class_method :validate_action!

      # SQLite has no boolean column, and nil stays nil so "not yet decided"
      # and "decided false" remain distinguishable.
      def retryable_integer
        return nil if retryable.nil?

        retryable ? 1 : 0
      end

      def response_blob = response && Wire.blob(response)
      def terminal_error_blob = terminal_error && Wire.blob(terminal_error)
    end
  end
end

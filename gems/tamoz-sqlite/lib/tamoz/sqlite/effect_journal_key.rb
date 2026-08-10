# frozen_string_literal: true

require 'json'

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Builds stable effect identities and checks an existing key's binding.
    module EffectJournalKey
      module_function

      # :reek:DuplicateMethodCall -- both lease fields are part of the exact
      # historical digest input and are read in the original order.
      # :reek:LongParameterList -- these named arguments are the digest inputs.
      def build(guard:, execution_id:, task_id:, call_index:, operation:)
        execution = Wire.identity(execution_id, name: 'effect execution id')
        task = Wire.identity(task_id, name: 'effect task id')
        index = EffectJournalValidation.non_negative_integer!(
          call_index,
          'effect call index'
        )
        operation_text = Wire.identity(operation, name: 'effect operation')
        Wire.digest(
          JSON.generate(
            [
              guard.lease.thread_id,
              guard.lease.namespace,
              execution,
              task,
              index,
              operation_text
            ]
          ),
          domain: 'tamoz.graph.effect'
        )
      end

      # rubocop:disable Metrics/ParameterLists -- the named arguments are the
      # complete durable effect binding, kept explicit for auditability.
      # :reek:LongParameterList -- these are the persisted identity fields.
      def verify_identity!(
        row,
        lease:,
        execution_id:,
        task_id:,
        call_index:,
        operation:,
        safety:,
        request_digest:
      )
        expected = [
          lease.thread_id,
          lease.namespace,
          execution_id,
          task_id,
          call_index,
          operation,
          safety,
          request_digest
        ]
        actual = [
          row.fetch(1), row.fetch(2), row.fetch(3), row.fetch(4),
          row.fetch(5), row.fetch(6), row.fetch(7), row.fetch(9)
        ]
        return if actual == expected

        raise CheckpointConflictError,
              'effect key is already bound to different semantics'
      end
      # rubocop:enable Metrics/ParameterLists
    end

    private_constant :EffectJournalKey
  end
end

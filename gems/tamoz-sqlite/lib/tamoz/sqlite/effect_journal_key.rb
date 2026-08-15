# frozen_string_literal: true

require 'json'
require 'digest'

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Builds stable effect identities and checks an existing key's binding.
    module EffectJournalKey
      # P1/§8.1: logical effect keys. An episode model call is identified by its
      # logical call key (episode, stage, slot, request digest), which is stable
      # across worker attempts and fences — the execution-derived key cannot be
      # (a fresh execution id is assigned per claim). The key is prefixed so
      # `verify_identity!` can select the logical binding.
      LOGICAL_PREFIX = 'logical:'

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

      # P1: the stable identity for a logical call key. `to_key` already embeds
      # the request digest, so identical request bytes dedup to one receipt and
      # changed request bytes produce a different key (never a stale reuse).
      # The key is digested raw: LogicalCallKey#to_key joins its validated
      # fields with control characters that Wire.identity would reject. A
      # LogicalCallKey object (not just its to_key string) is accepted — its
      # to_s is not the identity.
      def logical(logical_key)
        key = if logical_key.respond_to?(:to_key)
                logical_key.to_key.to_s
              else
                logical_key.to_s
              end
        if key.empty? || key.bytesize > 4096
          raise ConfigurationError, 'logical effect key is empty or oversized'
        end

        LOGICAL_PREFIX + Digest::SHA256.hexdigest(JSON.generate([key]))
      end

      def logical?(effect_key)
        effect_key.to_s.start_with?(LOGICAL_PREFIX)
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
        request_digest:,
        logical_key: nil
      )
        if logical_key
          # The key is the logical call identity; the execution-derived fields
          # legitimately differ across attempts and fences. Bind the thread,
          # namespace, safety, and request digest only.
          actual = [row.fetch(1), row.fetch(2), row.fetch(7), row.fetch(9)]
          expected = [lease.thread_id, lease.namespace, safety, request_digest]
          return if actual == expected

          raise CheckpointConflictError,
                'effect key is already bound to different logical semantics'
        end

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

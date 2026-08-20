# frozen_string_literal: true

require 'json'

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Builds stable effect identities and checks an existing key's binding.
    # rubocop:disable Metrics/ModuleLength
    module EffectJournalKey
      # P1/§8.1: logical effect keys. An episode model call is identified by its
      # logical call key (episode, stage, slot, request digest), which is stable
      # across worker attempts and fences — the execution-derived key cannot be
      # (a fresh execution id is assigned per claim). The key is prefixed so
      # `verify_identity!` can select the logical binding.
      LOGICAL_PREFIX = 'logical:'
      LOGICAL_IDENTITY_DOMAIN = "tamoz.sqlite.effect.logical.v2\n"

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
        raise ConfigurationError, 'logical effect key is empty or oversized' if key.empty? || key.bytesize > 4096
        return key if key.match?(/\Alogical:[0-9a-f]{64}\z/)

        LOGICAL_PREFIX + Wire.digest(JSON.generate([key]),
                                     domain: 'tamoz.graph.effect.logical').delete_prefix('sha256:')
      end

      # The durable logical identity for an operation requested by a graph
      # iteration. It is independent of attempt tokens and fences, while the
      # checkpointed execution/iteration/sub-operation fields prevent two
      # compound operations from sharing a receipt. Arguments are canonical
      # data, never an answer or a process-local counter.
      # rubocop:disable Metrics/ParameterLists, Lint/UnusedMethodArgument --
      # execution_id is accepted as an explicit input but intentionally excluded
      # from the stable logical identity.
      def logical_identity(
        request_id:, operation:, capability_id:, arguments:, authority_revision:, catalog_revision:,
        iteration:, sub_operation:, execution_id: nil
      )
        fields = {
          'request_id' => Wire.identity(request_id, name: 'effect request id'),
          'operation' => Wire.identity(operation, name: 'effect operation'),
          'capability_id' => Wire.identity(capability_id, name: 'effect capability id'),
          'arguments' => canonical_arguments(arguments),
          'authority_revision' => Wire.identity(authority_revision, name: 'effect authority revision'),
          'catalog_revision' => Wire.identity(catalog_revision, name: 'effect catalog revision'),
          'iteration' => non_negative(iteration, 'effect iteration'),
          'sub_operation' => non_negative(sub_operation, 'effect sub-operation')
        }
        LOGICAL_PREFIX + Tamoz::Core.digest(LOGICAL_IDENTITY_DOMAIN, fields).delete_prefix('sha256:')
      end
      # rubocop:enable Metrics/ParameterLists, Lint/UnusedMethodArgument

      def attempt_identity(logical_key, attempt_number, execution_id: nil, fence: nil)
        key = Wire.identity(logical_key, name: 'logical effect key')
        number = non_negative(attempt_number, 'effect attempt number')
        return "#{key}/attempt/#{number}" unless execution_id || fence
        unless execution_id && fence
          raise ConfigurationError, 'effect attempt identity requires execution_id and fence together'
        end

        execution = Wire.identity(execution_id, name: 'effect attempt execution id')
        fence_number = strict_non_negative_integer(fence, 'effect attempt fence')
        raise ConfigurationError, 'effect attempt fence must be positive' unless fence_number.positive?

        "#{key}/attempt/#{number}/execution/#{execution}/fence/#{fence_number}"
      end

      def logical?(effect_key)
        effect_key.to_s.start_with?(LOGICAL_PREFIX)
      end

      def canonical_arguments(arguments)
        Tamoz::Core.deep_freeze(Tamoz::Core.canonical(arguments))
      rescue Tamoz::Error => e
        raise ConfigurationError, "effect arguments must be canonical JSON data: #{e.message}"
      end

      def non_negative(value, name)
        integer = strict_non_negative_integer(value, name)
        raise ConfigurationError, "#{name} must be non-negative" if integer.negative?

        integer
      end

      def strict_non_negative_integer(value, name)
        raise ConfigurationError, "#{name} must be a non-negative integer" unless value.is_a?(Integer)

        value
      end

      # rubocop:disable Metrics/AbcSize, Metrics/ParameterLists, Metrics/MethodLength -- the named
      # arguments are the durable identity comparison contract.
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
          actual = [row.fetch(2), row.fetch(3), row.fetch(7), row.fetch(8), row.fetch(10)]
          expected = [lease.thread_id, lease.namespace, operation, safety, request_digest]
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
          row.fetch(2), row.fetch(3), row.fetch(4), row.fetch(5),
          row.fetch(6), row.fetch(7), row.fetch(8), row.fetch(10)
        ]
        return if actual == expected

        raise CheckpointConflictError,
              'effect key is already bound to different semantics'
      end
      # rubocop:enable Metrics/AbcSize, Metrics/ParameterLists, Metrics/MethodLength
    end
    # rubocop:enable Metrics/ModuleLength

    private_constant :EffectJournalKey
  end
end

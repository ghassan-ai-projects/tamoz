# frozen_string_literal: true

require 'securerandom'

module Tamoz
  # SQLite checkpoint collaborators keep the persistence boundary explicit.
  module SQLite
    # Commits one immutable checkpoint, its consumed activations, and any request
    # transition in the same fenced SQLite transaction.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall
    # :reek:FeatureEnvy :reek:LongParameterList :reek:ManualDispatch
    # :reek:MissingSafeMethod :reek:NestedIterators :reek:TooManyStatements
    # The mode matrix and repeated lease values are the durable conflict contract;
    # value objects or smaller transactions would obscure it.
    class CheckpointCommitter
      def initialize(store:)
        @store = store
        freeze
      end

      # One fenced transaction owns insert, activation consumption, request
      # transition, and head advance; splitting it would obscure atomicity.
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists, Metrics/BlockLength
      def append_checkpoint(
        lease:,
        expected_base_id:,
        mode:,
        attributes:,
        consumed_task_ids:,
        request_transition:
      )
        validate_commit_arguments!(
          expected_base_id:,
          mode:,
          consumed_task_ids:,
          request_transition:
        )
        checkpoint_id = SecureRandom.uuid.freeze
        immutable_attributes = attributes.merge(
          frontier: attributes.fetch(:frontier).map do |entry|
            entry.activation_checkpoint_id ? entry : entry.with_activation_checkpoint(checkpoint_id)
          end.freeze
        ).freeze
        payload = checkpoint_codec.dump(immutable_attributes)
        payload_digest = Wire.digest(
          payload,
          domain: 'tamoz.sqlite.checkpoint_payload'
        )
        execution_id = Wire.identity(
          immutable_attributes.fetch(:execution_id),
          name: 'execution id'
        )
        expected = expected_base_id &&
                   Wire.identity(expected_base_id, name: 'base checkpoint id')
        status = immutable_attributes.fetch(:status).to_s
        sequence = nil
        parent_id = expected

        adapter.__send__(:transaction, operation: 'checkpoint.commit') do |tx|
          now = adapter.__send__(:backend_time, tx, 'checkpoint.commit.time')
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'checkpoint.commit.lease'
          )
          head = tx.first(
            'checkpoint.commit.head',
            <<~SQL,
              SELECT active_checkpoint_id, next_checkpoint_sequence
              FROM tamoz_namespaces
              WHERE thread_id = ? AND namespace = ?
            SQL
            [lease.thread_id, lease.namespace]
          )
          validate_mode!(
            tx,
            lease:,
            mode:,
            head:,
            expected_base_id: expected,
            execution_id:
          )
          sequence = head.fetch(1)
          # digest_version 2 names the JCS (RFC 8785) rule for definition_digest
          # only; payload_digest stays Wire-framed (domain + "\0v1\0") and is
          # verified with its own framing. A reader must never select a digest
          # rule for the payload from the digest_version column.
          tx.execute(
            'checkpoint.commit.insert',
            <<~SQL,
              INSERT INTO tamoz_checkpoints(
                id, thread_id, namespace, execution_id, sequence, parent_id,
                format_version, graph_name, graph_version, digest_version,
                definition_digest, fence, status, payload, payload_digest,
                created_at_ms
              )
              VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, 2, ?, ?, ?, ?, ?, ?)
            SQL
            [
              checkpoint_id, lease.thread_id, lease.namespace, execution_id,
              sequence, parent_id, checkpoint_codec.definition.name,
              checkpoint_codec.definition.version,
              checkpoint_codec.definition_digest, lease.fence, status,
              Wire.blob(payload), payload_digest, now
            ]
          )
          consumed_task_ids.each_with_index do |task_id, index|
            normalized_task_id = Wire.identity(task_id, name: 'consumed task id')
            tx.execute(
              "checkpoint.commit.consume.#{index}",
              <<~SQL,
                UPDATE tamoz_pending_activations
                SET consumed_by = ?
                WHERE thread_id = ? AND namespace = ?
                  AND execution_id = ? AND task_id = ?
                  AND consumed_by IS NULL
              SQL
              [
                checkpoint_id, lease.thread_id, lease.namespace,
                execution_id, normalized_task_id
              ]
            )
            unless tx.changes == 1
              raise CheckpointConflictError,
                    "consumed activation #{normalized_task_id} is missing or stale"
            end
          end
          if request_transition
            requests.apply_request_transition_in_transaction!(
              tx,
              lease:,
              checkpoint_id:,
              transition: request_transition,
              now:
            )
          end
          tx.execute(
            'checkpoint.commit.advance',
            <<~SQL,
              UPDATE tamoz_namespaces
              SET active_checkpoint_id = ?,
                  next_checkpoint_sequence = ?,
                  greatest_backend_time_ms = MAX(greatest_backend_time_ms, ?),
                  updated_at_ms = ?
              WHERE thread_id = ? AND namespace = ?
                AND lease_owner_id = ? AND lease_fence = ?
            SQL
            [
              checkpoint_id, sequence + 1, now, now,
              lease.thread_id, lease.namespace, lease.owner_id, lease.fence
            ]
          )
          raise LeaseLostError, 'checkpoint commit lost its fence' unless tx.changes == 1
        end

        Tamoz::Graph::Checkpoint.new(
          format_version: 1,
          id: checkpoint_id,
          sequence:,
          thread_id: lease.thread_id,
          namespace: Wire.decode_namespace(lease.namespace),
          parent_id:,
          **immutable_attributes
        )
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists, Metrics/BlockLength

      def validate_commit_arguments!(
        expected_base_id:,
        mode:,
        consumed_task_ids:,
        request_transition:
      )
        unless %i[start advance turn fork].include?(mode)
          raise ConfigurationError, "unknown checkpoint commit mode #{mode.inspect}"
        end
        raise ConfigurationError, 'start commit cannot have a base checkpoint' if
          mode == :start && expected_base_id
        unless consumed_task_ids.is_a?(Array) &&
               consumed_task_ids.uniq.length == consumed_task_ids.length
          raise ConfigurationError,
                'consumed_task_ids must be a unique Array'
        end
        if request_transition &&
           !requests.respond_to?(:apply_request_transition_in_transaction!)
          raise ConfigurationError,
                'SQLite request transition capability is unavailable'
        end
      end

      # This ordered mode matrix is the commit conflict contract.
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/ParameterLists, Naming/MethodParameterName, Style/GuardClause, Layout/EmptyLineAfterGuardClause
      def validate_mode!(
        tx,
        lease:,
        mode:,
        head:,
        expected_base_id:,
        execution_id:
      )
        raise CheckpointConflictError, 'thread namespace head is missing' unless head
        active_id = head.fetch(0)
        case mode
        when :start
          raise CheckpointConflictError, 'thread namespace already has a checkpoint' if active_id
        when :advance, :turn
          unless active_id && active_id == expected_base_id
            raise CheckpointConflictError,
                  'checkpoint base is not the active tip'
          end
        when :fork
          raise CheckpointConflictError, 'fork requires a source checkpoint' unless expected_base_id
        end
        return if mode == :start

        base = tx.first(
          'checkpoint.commit.base',
          <<~SQL,
            SELECT execution_id
            FROM tamoz_checkpoints
            WHERE id = ? AND thread_id = ? AND namespace = ?
          SQL
          [expected_base_id, lease.thread_id, lease.namespace]
        )
        raise CheckpointConflictError, 'checkpoint base does not exist' unless base
        base_execution = base.fetch(0)
        if mode == :advance && base_execution != execution_id
          raise CheckpointConflictError,
                'advance commit changed execution identity'
        end
        if %i[turn fork].include?(mode) && base_execution == execution_id
          raise CheckpointConflictError,
                "#{mode} commit must create a new execution identity"
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/ParameterLists, Naming/MethodParameterName, Style/GuardClause, Layout/EmptyLineAfterGuardClause

      private

      def adapter = @store.adapter
      def checkpoint_codec = @store.checkpoint_codec
      def requests = @store.requests
    end

    private_constant :CheckpointCommitter
  end
end

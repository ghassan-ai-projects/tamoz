# frozen_string_literal: true

module Tamoz
  module SQLite
    # Fenced checkpoint facade. It preserves the public checkpointer contract while
    # named collaborators own reads, pruning, pending writes, and checkpoint commits.
    class CheckpointStore
      CHECKPOINT_PROTOCOL_VERSION = 1
      REQUEST_PROTOCOL_VERSION = 1
      MAX_HISTORY_LIMIT = 100_000

      attr_reader :adapter, :checkpoint_codec, :wire, :requests

      def initialize(adapter:, checkpoint_codec:)
        unless checkpoint_codec.is_a?(Tamoz::Graph::CheckpointCodec)
          raise ConfigurationError,
                "SQLite graph binding requires Tamoz::Graph::CheckpointCodec"
        end

        @adapter = adapter
        @checkpoint_codec = checkpoint_codec
        @wire = CheckpointWire.new(checkpoint_codec:)
        @requests = RequestInbox.new(self)
        @queries = CheckpointQueries.new(store: self)
        @pruner = CheckpointPruner.new(store: self)
        @appender = CheckpointAppender.new(store: self)
        @committer = CheckpointCommitter.new(store: self)
        @effect_census = EffectCensus.new(adapter:)
        freeze
      end

      def checkpoint_protocol_version = CHECKPOINT_PROTOCOL_VERSION
      def request_protocol_version = REQUEST_PROTOCOL_VERSION
      def durable? = true
      def writer_ttl = adapter.limits.lease_ttl

      def bind_graph(checkpoint_codec:)
        adapter.bind_graph(checkpoint_codec:)
      end

      def latest(thread_id:, namespace: [], validate_identity: true)
        @queries.latest(thread_id:, namespace:, validate_identity:)
      end

      # Select graph identity without decoding the graph-specific checkpoint
      # payload. Sessions that retain multiple graph definitions use this narrow
      # metadata seam before choosing the compatible checkpoint codec.
      def latest_graph_version(thread_id:, namespace: [])
        @queries.latest_graph_version(thread_id:, namespace:)
      end

      def find(thread_id:, namespace: [], checkpoint_id:)
        @queries.find(thread_id:, namespace:, checkpoint_id:)
      end

      def history(thread_id:, namespace: [], before_sequence: nil, limit:)
        @queries.history(thread_id:, namespace:, before_sequence:, limit:)
      end

      def prune(thread_id:, namespace: [], keep:)
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        unless keep.is_a?(Integer) && keep.between?(1, MAX_HISTORY_LIMIT)
          raise ConfigurationError,
                "prune keep must be between 1 and #{MAX_HISTORY_LIMIT}"
        end

        @pruner.prune(thread:, encoded_namespace:, keep:)
      end

      def enqueue_request(...) = @requests.enqueue_request(...)
      def enqueue_request_in_transaction!(...) = @requests.enqueue_request_in_transaction!(...)
      def fetch_request(...) = @requests.fetch_request(...)
      def request_history(...) = @requests.request_history(...)
      def pending_threads(...) = @requests.pending_threads(...)
      def claim_next_request(...) = @requests.claim_next_request(...)
      def recover_request(...) = @requests.recover_request(...)
      def mark_request_running(...) = @requests.mark_request_running(...)
      def mark_request_completed(...) = @requests.mark_request_completed(...)
      def terminal_fail(...) = @requests.terminal_fail(...)
      def request_transition(...) = @requests.request_transition(...)
      def redirect_ready?(...) = @requests.redirect_ready?(...)

      def effect_census(limit: 10_000) = @effect_census.census(limit:)

      def open_writer(thread_id:, namespace:, owner_id:, ttl:)
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        owner = Wire.identity(owner_id, name: "writer owner id")
        normalized_ttl = normalize_ttl(ttl)
        lease = adapter.__send__(
          :acquire_lease,
          thread_id: thread,
          namespace: encoded_namespace,
          owner_id: owner,
          ttl: normalized_ttl
        )
        guard = LeaseGuard.new(adapter:, lease:).start
        writer = CheckpointWriter.new(store: self, guard:)
        primary_error = nil
        begin
          yield writer
        rescue Exception => error # rubocop:disable Lint/RescueException
          primary_error = error
          raise
        ensure
          begin
            guard.close
          rescue Exception => release_error # rubocop:disable Lint/RescueException
            # Re-raising primary_error here (rather than letting it already be
            # in flight) chains release_error onto it as #cause, so a stuck
            # lease still leaves a trace of why the release attempt failed —
            # instead of the release failure being discarded outright.
            raise primary_error if primary_error

            raise release_error
          end
        end
      end

      def append_writes(lease:, task:, outcome:)
        @appender.append_writes(lease:, task:, outcome:)
      end

      def append_checkpoint(
        lease:,
        expected_base_id:,
        mode:,
        attributes:,
        consumed_task_ids:,
        request_transition:
      )
        @committer.append_checkpoint(
          lease:,
          expected_base_id:,
          mode:,
          attributes:,
          consumed_task_ids:,
          request_transition:
        )
      end

      def normalize_address(thread_id, namespace)
        [
          Wire.identity(thread_id, name: "thread id"),
          Wire.namespace(namespace)
        ].freeze
      end

      def active_execution_id!(tx, lease, label)
        execution_id = tx.scalar(
          label,
          <<~SQL,
            SELECT c.execution_id
            FROM tamoz_namespaces n
            JOIN tamoz_checkpoints c ON c.id = n.active_checkpoint_id
            WHERE n.thread_id = ? AND n.namespace = ?
          SQL
          [lease.thread_id, lease.namespace]
        )
        raise CheckpointConflictError, "request operation requires an active checkpoint" unless execution_id

        execution_id
      end

      def latest_checkpoint_in_transaction(tx, thread_id, namespace, label)
        @queries.decode_latest_checkpoint_in_transaction(tx, thread_id, namespace, label)
      end

      def normalize_ttl(value)
        unless value.is_a?(Numeric) &&
               value.finite? &&
               value >= 0.1 &&
               value <= adapter.limits.lease_ttl
          raise ConfigurationError,
                "writer ttl must be between 0.1 and #{adapter.limits.lease_ttl}"
        end

        value.to_f
      end

      def history_limit(value)
        unless value.is_a?(Integer) &&
               value.positive? &&
               value <= MAX_HISTORY_LIMIT
          raise ConfigurationError,
                "history limit must be between 1 and #{MAX_HISTORY_LIMIT}"
        end

        value
      end

      def materialize(row, validate_identity: true)
        @queries.materialize(row, validate_identity:)
      end

      def pending_outcomes(thread_id:, namespace:, execution_id:)
        @queries.pending_outcomes(thread_id:, namespace:, execution_id:)
      end

      def verify_existing_writes!(tx, lease:, execution_id:, task_id:, writes:)
        @appender.verify_pending_writes!(
          tx,
          lease:,
          execution_id:,
          task_id:,
          writes:
        )
      end

      def validate_commit_arguments!(
        expected_base_id:,
        mode:,
        consumed_task_ids:,
        request_transition:
      )
        @committer.validate_commit_arguments!(
          expected_base_id:,
          mode:,
          consumed_task_ids:,
          request_transition:
        )
      end

      def validate_commit_mode!(
        tx,
        lease:,
        mode:,
        head:,
        expected_base_id:,
        execution_id:
      )
        @committer.validate_mode!(
          tx,
          lease:,
          mode:,
          head:,
          expected_base_id:,
          execution_id:
        )
      end

      public :active_execution_id!, :latest_checkpoint_in_transaction

      private_constant :CHECKPOINT_PROTOCOL_VERSION, :REQUEST_PROTOCOL_VERSION,
                       :MAX_HISTORY_LIMIT
    end
  end
end

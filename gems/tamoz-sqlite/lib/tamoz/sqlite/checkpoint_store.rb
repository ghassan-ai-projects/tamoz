# frozen_string_literal: true

require "json"
require "securerandom"

module Tamoz
  module SQLite
    class CheckpointStore
      CHECKPOINT_PROTOCOL_VERSION = 1
      REQUEST_PROTOCOL_VERSION = 1
      MAX_HISTORY_LIMIT = 100_000

      attr_reader :adapter, :checkpoint_codec

      def initialize(adapter:, checkpoint_codec:)
        unless checkpoint_codec.is_a?(Tamoz::Graph::CheckpointCodec)
          raise ConfigurationError,
                "SQLite graph binding requires Tamoz::Graph::CheckpointCodec"
        end

        @adapter = adapter
        @checkpoint_codec = checkpoint_codec
        @wire = CheckpointWire.new(checkpoint_codec:)
        @requests = RequestInbox.new(self)
        freeze
      end

      def checkpoint_protocol_version = CHECKPOINT_PROTOCOL_VERSION
      def request_protocol_version = REQUEST_PROTOCOL_VERSION
      def durable? = true
      def writer_ttl = adapter.limits.lease_ttl

      def bind_graph(checkpoint_codec:)
        adapter.bind_graph(checkpoint_codec:)
      end

      def latest(thread_id:, namespace: [])
        address = normalize_address(thread_id, namespace)
        row = adapter.__send__(:read, operation: "checkpoint.latest") do |tx|
          tx.first(
            "checkpoint.latest",
            <<~SQL,
              SELECT c.id, c.sequence, c.thread_id, c.namespace, c.parent_id,
                     c.format_version, c.execution_id, c.graph_name,
                     c.graph_version, c.definition_digest, c.status,
                     c.payload, c.payload_digest, n.active_checkpoint_id
              FROM tamoz_namespaces n
              LEFT JOIN tamoz_checkpoints c
                ON c.id = n.active_checkpoint_id
              WHERE n.thread_id = ? AND n.namespace = ?
            SQL
            address
          )
        end
        return nil unless row && row.fetch(0)

        materialize(row)
      end

      def find(thread_id:, namespace: [], checkpoint_id:)
        address = normalize_address(thread_id, namespace)
        id = Wire.identity(checkpoint_id, name: "checkpoint id")
        row = adapter.__send__(:read, operation: "checkpoint.find") do |tx|
          tx.first(
            "checkpoint.find",
            <<~SQL,
              SELECT c.id, c.sequence, c.thread_id, c.namespace, c.parent_id,
                     c.format_version, c.execution_id, c.graph_name,
                     c.graph_version, c.definition_digest, c.status,
                     c.payload, c.payload_digest, n.active_checkpoint_id
              FROM tamoz_checkpoints c
              JOIN tamoz_namespaces n
                ON n.thread_id = c.thread_id AND n.namespace = c.namespace
              WHERE c.thread_id = ? AND c.namespace = ? AND c.id = ?
            SQL
            [*address, id]
          )
        end
        row && materialize(row)
      end

      def history(
        thread_id:,
        namespace: [],
        before_sequence: nil,
        limit:
      )
        address = normalize_address(thread_id, namespace)
        normalized_limit = history_limit(limit)
        if before_sequence &&
           !(before_sequence.is_a?(Integer) && !before_sequence.negative?)
          raise ConfigurationError,
                "before_sequence must be a non-negative integer"
        end
        comparison = before_sequence ? "AND c.sequence < ?" : ""
        binds = [*address]
        binds << before_sequence if before_sequence
        binds << normalized_limit
        rows = adapter.__send__(:read, operation: "checkpoint.history") do |tx|
          tx.rows(
            "checkpoint.history",
            <<~SQL,
              SELECT c.id, c.sequence, c.thread_id, c.namespace, c.parent_id,
                     c.format_version, c.execution_id, c.graph_name,
                     c.graph_version, c.definition_digest, c.status,
                     c.payload, c.payload_digest, n.active_checkpoint_id
              FROM tamoz_checkpoints c
              JOIN tamoz_namespaces n
                ON n.thread_id = c.thread_id AND n.namespace = c.namespace
              WHERE c.thread_id = ? AND c.namespace = ?
                #{comparison}
              ORDER BY c.sequence DESC
              LIMIT ?
            SQL
            binds
          )
        end
        rows.map { |row| materialize(row) }.freeze
      end

      def prune(thread_id:, namespace: [], keep:)
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        unless keep.is_a?(Integer) && keep.between?(1, MAX_HISTORY_LIMIT)
          raise ConfigurationError,
                "prune keep must be between 1 and #{MAX_HISTORY_LIMIT}"
        end
        deleted_ids = []
        created_at = nil
        adapter.__send__(:transaction, operation: "checkpoint.prune") do |tx|
          created_at = adapter.__send__(:backend_time, tx, "checkpoint.prune.time")
          tombstone = tx.scalar(
            "checkpoint.prune.thread",
            "SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?",
            [thread]
          )
          raise CheckpointConflictError, "thread does not exist" if tombstone.nil? &&
                                                               !tx.first(
                                                                 "checkpoint.prune.exists",
                                                                 "SELECT 1 FROM tamoz_threads WHERE thread_id = ?",
                                                                 [thread]
                                                               )
          raise CheckpointConflictError, "thread is tombstoned" if tombstone

          candidates = tx.rows(
            "checkpoint.prune.candidates",
            <<~SQL,
              WITH RECURSIVE
              active_chain(id) AS (
                SELECT active_checkpoint_id
                FROM tamoz_namespaces
                WHERE thread_id = ? AND namespace = ?
                UNION ALL
                SELECT c.parent_id
                FROM tamoz_checkpoints c
                JOIN active_chain a ON c.id = a.id
                WHERE c.parent_id IS NOT NULL
              ),
              newest(id) AS (
                SELECT id
                FROM tamoz_checkpoints
                WHERE thread_id = ? AND namespace = ?
                ORDER BY sequence DESC
                LIMIT ?
              )
              SELECT c.id
              FROM tamoz_checkpoints c
              WHERE c.thread_id = ? AND c.namespace = ?
                AND c.id NOT IN (SELECT id FROM active_chain WHERE id IS NOT NULL)
                AND c.id NOT IN (SELECT id FROM newest)
                AND NOT EXISTS (
                  SELECT 1 FROM tamoz_pending_activations p
                  WHERE p.base_checkpoint_id = c.id OR p.consumed_by = c.id
                )
                AND NOT EXISTS (
                  SELECT 1 FROM tamoz_requests r WHERE r.checkpoint_id = c.id
                )
              ORDER BY c.sequence DESC
            SQL
            [
              thread, encoded_namespace, thread, encoded_namespace, keep,
              thread, encoded_namespace
            ]
          ).flatten
          candidates.each do |id|
            tx.execute(
              "checkpoint.prune.delete",
              <<~SQL,
                DELETE FROM tamoz_checkpoints
                WHERE id = ? AND thread_id = ? AND namespace = ?
              SQL
              [id, thread, encoded_namespace]
            )
            deleted_ids << id.freeze if tx.changes == 1
          end
        end
        PruneReport.new(
          thread_id: thread,
          namespace: Wire.decode_namespace(encoded_namespace),
          kept_minimum: keep,
          deleted_checkpoint_ids: deleted_ids.freeze,
          created_at_ms: created_at
        )
      end

      # Read-only census of every recorded effect, with the attempt outcomes that
      # decide whether it was applied once, applied twice, or retried after its
      # result stopped being knowable.
      #
      # This exists so an operator's safety counters can be DERIVED from the
      # journal rather than self-reported by the component being audited. A
      # counter the worker increments is a claim; this is evidence. It takes no
      # lease and writes nothing, so `tamoz status` can run against a live
      # runtime without contending with the worker.
      #
      # `succeeded_attempts > 1` is a duplicate effect. `attempts_after_unknown > 0`
      # is a machine that retried something whose outcome it could not prove.
      # Both must be zero, always.
      # Delegated to RequestInbox; the published surface is unchanged.
      def enqueue_request(...) = @requests.enqueue_request(...)
      def enqueue_request_in_transaction!(...) = @requests.enqueue_request_in_transaction!(...)
      def fetch_request(...) = @requests.fetch_request(...)
      def request_history(...) = @requests.request_history(...)
      def pending_threads(...) = @requests.pending_threads(...)
      def claim_next_request(...) = @requests.claim_next_request(...)
      def recover_request(...) = @requests.recover_request(...)
      def mark_request_running(...) = @requests.mark_request_running(...)
      def terminal_fail(...) = @requests.terminal_fail(...)
      def request_transition(...) = @requests.request_transition(...)
      def redirect_ready?(...) = @requests.redirect_ready?(...)

      # :nodoc: RequestInbox's declared surface on the store, rather than a
      # reach through `private`.
      attr_reader :wire, :requests

      def effect_census(limit: 10_000)
        bounded = Integer(limit)
        raise ConfigurationError, "limit must be positive" unless bounded.positive?

        rows = adapter.__send__(:read, operation: "effect.census") do |tx|
          tx.rows(
            "effect.census.select",
            <<~SQL,
              SELECT e.effect_key, e.thread_id, e.operation, e.safety, e.status,
                     e.requires_reconciliation,
                     (SELECT COUNT(*) FROM tamoz_effect_attempts a
                       WHERE a.effect_key = e.effect_key AND a.status = 'succeeded'),
                     (SELECT COUNT(*) FROM tamoz_effect_attempts a
                       WHERE a.effect_key = e.effect_key
                         AND a.attempt_number > (
                           SELECT MIN(u.attempt_number) FROM tamoz_effect_attempts u
                            WHERE u.effect_key = e.effect_key AND u.status = 'unknown'
                         ))
              FROM tamoz_effects AS e
              ORDER BY e.created_at_ms ASC, e.effect_key ASC
              LIMIT ?
            SQL
            [bounded]
          )
        end
        rows.map do |row|
          {
            effect_key: row.fetch(0),
            thread_id: row.fetch(1),
            operation: row.fetch(2),
            safety: row.fetch(3).to_sym,
            status: row.fetch(4).to_sym,
            requires_reconciliation: row.fetch(5) == 1,
            succeeded_attempts: row.fetch(6),
            attempts_after_unknown: row.fetch(7).to_i
          }.freeze
        end.freeze
      end

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
          rescue Exception # rubocop:disable Lint/RescueException
            raise unless primary_error
          end
        end
      end

      def append_writes(lease:, task:, outcome:)
        unless task.id == outcome.task_id &&
               task.attempt_id == outcome.attempt_id &&
               task.base_checkpoint_id == outcome.base_checkpoint_id &&
               task.execution_id
          raise CheckpointConflictError, "task outcome identity is stale or mismatched"
        end

        execution_id = Wire.identity(task.execution_id, name: "execution id")
        task_id = Wire.identity(task.id, name: "task id")
        attempt_id = Wire.identity(task.attempt_id, name: "attempt id")
        base_id = Wire.identity(task.base_checkpoint_id, name: "base checkpoint id")
        node = task.node.to_s
        path = JSON.generate(task.path).freeze
        outcome_bytes = checkpoint_codec.dump_outcome(outcome)
        outcome_digest = Wire.digest(
          outcome_bytes,
          domain: "tamoz.sqlite.pending_outcome"
        )
        writes = checkpoint_codec.dump_outcome_writes(outcome).map do |write|
          payload = write.fetch("payload")
          write.merge(
            "payload_digest" => Wire.digest(
              payload,
              domain: "tamoz.sqlite.pending_write"
            )
          ).freeze
        end.freeze

        result = :inserted
        adapter.__send__(:transaction, operation: "checkpoint.append_writes") do |tx|
          now = adapter.__send__(:backend_time, tx, "checkpoint.writes.time")
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "checkpoint.writes.lease"
          )
          base = tx.first(
            "checkpoint.writes.base",
            <<~SQL,
              SELECT execution_id
              FROM tamoz_checkpoints
              WHERE id = ? AND thread_id = ? AND namespace = ?
            SQL
            [base_id, lease.thread_id, lease.namespace]
          )
          unless base && base.fetch(0) == execution_id
            raise CheckpointConflictError,
                  "pending write base or execution is incompatible"
          end

          existing = tx.first(
            "checkpoint.writes.existing",
            <<~SQL,
              SELECT attempt_id, base_checkpoint_id, node, path, outcome_digest
              FROM tamoz_pending_activations
              WHERE thread_id = ? AND namespace = ?
                AND execution_id = ? AND task_id = ?
            SQL
            [lease.thread_id, lease.namespace, execution_id, task_id]
          )
          if existing
            unless existing == [attempt_id, base_id, node, path, outcome_digest]
              raise CheckpointConflictError,
                    "logical activation already has a different durable outcome"
            end
            verify_existing_writes!(
              tx,
              lease:,
              execution_id:,
              task_id:,
              writes:
            )
            result = :already_present
            next
          end

          tx.execute(
            "checkpoint.writes.activation",
            <<~SQL,
              INSERT INTO tamoz_pending_activations(
                thread_id, namespace, execution_id, task_id, attempt_id,
                base_checkpoint_id, node, path, outcome_digest, consumed_by,
                created_at_ms
              )
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
            SQL
            [
              lease.thread_id, lease.namespace, execution_id, task_id,
              attempt_id, base_id, node, Wire.blob(path), outcome_digest, now
            ]
          )
          writes.each do |write|
            tx.execute(
              "checkpoint.writes.item.#{write.fetch("write_index")}",
              <<~SQL,
                INSERT INTO tamoz_pending_writes(
                  thread_id, namespace, execution_id, task_id, write_index,
                  kind, channel, payload, payload_digest
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
              SQL
              [
                lease.thread_id, lease.namespace, execution_id, task_id,
                write.fetch("write_index"), write.fetch("kind"),
                write.fetch("channel"), Wire.blob(write.fetch("payload")),
                write.fetch("payload_digest")
              ]
            )
          end
        end
        result
      end

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
          domain: "tamoz.sqlite.checkpoint_payload"
        )
        execution_id = Wire.identity(
          immutable_attributes.fetch(:execution_id),
          name: "execution id"
        )
        expected = expected_base_id &&
                   Wire.identity(expected_base_id, name: "base checkpoint id")
        status = immutable_attributes.fetch(:status).to_s
        sequence = nil
        parent_id = expected

        adapter.__send__(:transaction, operation: "checkpoint.commit") do |tx|
          now = adapter.__send__(:backend_time, tx, "checkpoint.commit.time")
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "checkpoint.commit.lease"
          )
          head = tx.first(
            "checkpoint.commit.head",
            <<~SQL,
              SELECT active_checkpoint_id, next_checkpoint_sequence
              FROM tamoz_namespaces
              WHERE thread_id = ? AND namespace = ?
            SQL
            [lease.thread_id, lease.namespace]
          )
          validate_commit_mode!(
            tx,
            lease:,
            mode:,
            head:,
            expected_base_id: expected,
            execution_id:
          )
          sequence = head.fetch(1)
          tx.execute(
            "checkpoint.commit.insert",
            <<~SQL,
              INSERT INTO tamoz_checkpoints(
                id, thread_id, namespace, execution_id, sequence, parent_id,
                format_version, graph_name, graph_version, digest_version,
                definition_digest, fence, status, payload, payload_digest,
                created_at_ms
              )
              VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, 1, ?, ?, ?, ?, ?, ?)
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
            normalized_task_id = Wire.identity(task_id, name: "consumed task id")
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
            @requests.apply_request_transition_in_transaction!(
              tx,
              lease:,
              checkpoint_id:,
              transition: request_transition,
              now:
            )
          end
          tx.execute(
            "checkpoint.commit.advance",
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
          raise LeaseLostError, "checkpoint commit lost its fence" unless tx.changes == 1
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

      # :nodoc: shared with RequestInbox.
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

      # Decoded latest checkpoint read inside an open transaction (the claim/recover
      # validation path). Read-only on tamoz_checkpoints, no second lease path. The
      # pending-activation merge is intentionally skipped: the staleness predicate
      # only reads status/interrupts/resume_values, which live in the payload.
      def latest_checkpoint_in_transaction(tx, thread_id, namespace, label)
        row = tx.first(
          label,
          <<~SQL,
            SELECT c.id, c.sequence, c.thread_id, c.namespace, c.parent_id,
                   c.format_version, c.execution_id, c.graph_name,
                   c.graph_version, c.definition_digest, c.status,
                   c.payload, c.payload_digest, n.active_checkpoint_id
            FROM tamoz_namespaces n
            LEFT JOIN tamoz_checkpoints c
              ON c.id = n.active_checkpoint_id
            WHERE n.thread_id = ? AND n.namespace = ?
          SQL
          [thread_id, namespace]
        )
        row && row.fetch(0) && @wire.decode_checkpoint_row(row)
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

      # The active-checkpoint mapper: the wire decodes and reconciles; the
      # store supplies the durable pending outcomes (querying them only when
      # the row IS the active checkpoint, so the query count is unchanged).
      def materialize(row)
        durable_pending = if row.fetch(0) == row.fetch(13)
                            pending_outcomes(
                              thread_id: row.fetch(2),
                              namespace: row.fetch(3),
                              execution_id: row.fetch(6)
                            )
                          end
        @wire.materialize(row, durable_pending:)
      end

      def pending_outcomes(thread_id:, namespace:, execution_id:)
        activation_rows = adapter.__send__(
          :read,
          operation: "checkpoint.pending"
        ) do |tx|
          tx.rows(
            "checkpoint.pending.activations",
            <<~SQL,
              SELECT task_id, attempt_id, base_checkpoint_id, node, path,
                     outcome_digest
              FROM tamoz_pending_activations
              WHERE thread_id = ? AND namespace = ?
                AND execution_id = ? AND consumed_by IS NULL
              ORDER BY task_id
            SQL
            [thread_id, namespace, execution_id]
          )
        end
        activation_rows.to_h do |activation|
          task_id = activation.fetch(0)
          write_rows = adapter.__send__(
            :read,
            operation: "checkpoint.pending_writes"
          ) do |tx|
            tx.rows(
              "checkpoint.pending.writes",
              <<~SQL,
                SELECT write_index, kind, channel, payload, payload_digest
                FROM tamoz_pending_writes
                WHERE thread_id = ? AND namespace = ?
                  AND execution_id = ? AND task_id = ?
                ORDER BY write_index
              SQL
              [thread_id, namespace, execution_id, task_id]
            )
          end
          writes = write_rows.map do |write|
            Wire.verify_digest!(
              write.fetch(3),
              write.fetch(4),
              domain: "tamoz.sqlite.pending_write"
            )
            {
              "write_index" => write.fetch(0),
              "kind" => write.fetch(1),
              "channel" => write.fetch(2),
              "payload" => write.fetch(3)
            }.freeze
          end
          metadata = {
            "task_id" => task_id,
            "attempt_id" => activation.fetch(1),
            "base_checkpoint_id" => activation.fetch(2),
            "node" => activation.fetch(3),
            "path" => activation.fetch(4)
          }.freeze
          outcome = checkpoint_codec.load_outcome(metadata:, writes:)
          Wire.verify_digest!(
            checkpoint_codec.dump_outcome(outcome),
            activation.fetch(5),
            domain: "tamoz.sqlite.pending_outcome"
          )
          [task_id, outcome]
        end.freeze
      end

      def verify_existing_writes!(tx, lease:, execution_id:, task_id:, writes:)
        rows = tx.rows(
          "checkpoint.writes.verify",
          <<~SQL,
            SELECT write_index, kind, channel, payload, payload_digest
            FROM tamoz_pending_writes
            WHERE thread_id = ? AND namespace = ?
              AND execution_id = ? AND task_id = ?
            ORDER BY write_index
          SQL
          [lease.thread_id, lease.namespace, execution_id, task_id]
        )
        expected = writes.map do |write|
          [
            write.fetch("write_index"), write.fetch("kind"),
            write.fetch("channel"), write.fetch("payload"),
            write.fetch("payload_digest")
          ]
        end
        unless rows == expected
          raise CheckpointCorruptionError,
                "durable pending writes disagree with their activation digest"
        end
      end

      def validate_commit_arguments!(
        expected_base_id:,
        mode:,
        consumed_task_ids:,
        request_transition:
      )
        unless %i[start advance turn fork].include?(mode)
          raise ConfigurationError, "unknown checkpoint commit mode #{mode.inspect}"
        end
        if mode == :start && expected_base_id
          raise ConfigurationError, "start commit cannot have a base checkpoint"
        end
        unless consumed_task_ids.is_a?(Array) &&
               consumed_task_ids.uniq.length == consumed_task_ids.length
          raise ConfigurationError,
                "consumed_task_ids must be a unique Array"
        end
        if request_transition &&
           !@requests.respond_to?(:apply_request_transition_in_transaction!)
          raise ConfigurationError,
                "SQLite request transition capability is unavailable"
        end
      end

      def validate_commit_mode!(
        tx,
        lease:,
        mode:,
        head:,
        expected_base_id:,
        execution_id:
      )
        raise CheckpointConflictError, "thread namespace head is missing" unless head
        active_id = head.fetch(0)
        case mode
        when :start
          raise CheckpointConflictError, "thread namespace already has a checkpoint" if active_id
        when :advance, :turn
          unless active_id && active_id == expected_base_id
            raise CheckpointConflictError,
                  "checkpoint base is not the active tip"
          end
        when :fork
          raise CheckpointConflictError, "fork requires a source checkpoint" unless expected_base_id
        end
        return if mode == :start

        base = tx.first(
          "checkpoint.commit.base",
          <<~SQL,
            SELECT execution_id
            FROM tamoz_checkpoints
            WHERE id = ? AND thread_id = ? AND namespace = ?
          SQL
          [expected_base_id, lease.thread_id, lease.namespace]
        )
        raise CheckpointConflictError, "checkpoint base does not exist" unless base
        base_execution = base.fetch(0)
        if mode == :advance && base_execution != execution_id
          raise CheckpointConflictError,
                "advance commit changed execution identity"
        end
        if %i[turn fork].include?(mode) && base_execution == execution_id
          raise CheckpointConflictError,
                "#{mode} commit must create a new execution identity"
        end
      end

      public :active_execution_id!, :latest_checkpoint_in_transaction

      private_constant :CHECKPOINT_PROTOCOL_VERSION, :REQUEST_PROTOCOL_VERSION,
                       :MAX_HISTORY_LIMIT
    end
  end
end

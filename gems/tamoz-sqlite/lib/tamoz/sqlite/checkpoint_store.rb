# frozen_string_literal: true

require "json"
require "securerandom"

module Tamoz
  module SQLite
    class CheckpointStore
      CHECKPOINT_PROTOCOL_VERSION = 1
      REQUEST_PROTOCOL_VERSION = 1
      MAX_HISTORY_LIMIT = 100_000
      REQUEST_STATUSES = %w[
        queued claimed running redirecting completed failed
      ].freeze
      REQUEST_OPERATIONS = %w[
        turn resume retry continue fork redirect
      ].freeze
      DELIVERY_MODES = %w[queue redirect].freeze
      REQUEST_SELECT = <<~SQL.lines.map(&:strip).join(" ").freeze
        SELECT thread_id, namespace, request_id, enqueue_sequence,
               input_digest, operation, delivery_mode, status, payload,
               payload_digest, execution_id, target_execution_id,
               cancellation_generation, checkpoint_id, response,
               response_digest, terminal_error, terminal_error_digest, retryable,
               created_at_ms, updated_at_ms
        FROM tamoz_requests
      SQL

      attr_reader :adapter, :checkpoint_codec

      def initialize(adapter:, checkpoint_codec:)
        unless checkpoint_codec.is_a?(Tamoz::Graph::CheckpointCodec)
          raise ConfigurationError,
                "SQLite graph binding requires Tamoz::Graph::CheckpointCodec"
        end

        @adapter = adapter
        @checkpoint_codec = checkpoint_codec
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

      def enqueue_request(
        thread_id:,
        namespace: [],
        request_id:,
        operation:,
        payload:,
        delivery: :queue
      )
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        id = Wire.identity(
          request_id,
          name: "request id",
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        operation_text = enum_text!(
          operation,
          REQUEST_OPERATIONS,
          "request operation"
        )
        delivery_text = enum_text!(
          delivery,
          DELIVERY_MODES,
          "request delivery mode"
        )
        if (operation_text == "redirect") != (delivery_text == "redirect")
          raise ConfigurationError,
                "redirect operation and delivery mode must be selected together"
        end
        payload_bytes = checkpoint_codec.dump_request_payload(
          operation_text,
          payload
        )
        payload_digest = Wire.digest(
          payload_bytes,
          domain: "tamoz.sqlite.request_payload"
        )
        input_digest = Wire.digest(
          JSON.generate([operation_text, delivery_text, payload_bytes]),
          domain: "tamoz.sqlite.request"
        )
        row = nil

        adapter.__send__(:transaction, operation: "request.enqueue") do |tx|
          now = adapter.__send__(:backend_time, tx, "request.enqueue.time")
          ensure_namespace_for_enqueue!(
            tx,
            thread_id: thread,
            namespace: encoded_namespace,
            now:
          )
          row = request_row(tx, thread, encoded_namespace, id, "request.enqueue.existing")
          if row
            unless row.fetch(4) == input_digest &&
                   row.fetch(5) == operation_text &&
                   row.fetch(6) == delivery_text &&
                   row.fetch(9) == payload_digest
              raise CheckpointConflictError,
                    "request id is already bound to different input"
            end
            next
          end

          sequence = tx.scalar(
            "request.enqueue.sequence",
            <<~SQL,
              SELECT next_request_sequence
              FROM tamoz_namespaces
              WHERE thread_id = ? AND namespace = ?
            SQL
            [thread, encoded_namespace]
          )
          tx.execute(
            "request.enqueue.insert",
            <<~SQL,
              INSERT INTO tamoz_requests(
                thread_id, namespace, request_id, enqueue_sequence,
                input_digest, operation, delivery_mode, status, payload,
                payload_digest, execution_id, target_execution_id,
                cancellation_generation, owner_fence, checkpoint_id,
                response, response_digest, terminal_error,
                terminal_error_digest, retryable,
                created_at_ms, updated_at_ms
              )
              VALUES (
                ?, ?, ?, ?, ?, ?, ?, 'queued', ?, ?,
                NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?
              )
            SQL
            [
              thread, encoded_namespace, id, sequence, input_digest,
              operation_text, delivery_text, Wire.blob(payload_bytes),
              payload_digest, now, now
            ]
          )
          append_request_transition!(
            tx,
            thread_id: thread,
            namespace: encoded_namespace,
            request_id: id,
            from_status: nil,
            to_status: "queued",
            fence: nil,
            evidence: {"kind" => "enqueue"},
            now:
          )
          tx.execute(
            "request.enqueue.advance",
            <<~SQL,
              UPDATE tamoz_namespaces
              SET next_request_sequence = ?,
                  greatest_backend_time_ms = MAX(greatest_backend_time_ms, ?),
                  updated_at_ms = ?
              WHERE thread_id = ? AND namespace = ?
            SQL
            [sequence + 1, now, now, thread, encoded_namespace]
          )
          row = request_row(tx, thread, encoded_namespace, id, "request.enqueue.result")
        end
        materialize_request(row)
      end

      def fetch_request(thread_id:, namespace: [], request_id:)
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        id = Wire.identity(
          request_id,
          name: "request id",
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = adapter.__send__(:read, operation: "request.fetch") do |tx|
          request_row(tx, thread, encoded_namespace, id, "request.fetch")
        end
        row && materialize_request(row)
      end

      # Ordered, durable request inbox history for one thread namespace. This is
      # the read path the resumable CLI and the eval harness use to prove exactly
      # one ordered request history after crash/recovery (invariant 23).
      def request_history(thread_id:, namespace: [])
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        rows = adapter.__send__(:read, operation: "request.history") do |tx|
          tx.rows(
            "request.history.select",
            <<~SQL,
              #{REQUEST_SELECT}
              WHERE thread_id = ? AND namespace = ?
              ORDER BY enqueue_sequence ASC
            SQL
            [thread, encoded_namespace]
          )
        end
        rows.map { |row| materialize_request(row) }.freeze
      end

      # Claim the oldest queued request under the lease. When a `validator` is
      # supplied (the graph-owned staleness predicate, DR-4 C1), it is invoked inside
      # this transaction with the materialized request and the latest decoded
      # checkpoint; a stale request is terminal-failed queued -> failed in the SAME
      # transaction (never observably claimed, no kill window), and the failed
      # request is returned. The validator receives only a RequestRecord and a
      # Checkpoint (or nil) and returns nil or a bounded typed reason.
      def claim_next_request(lease:, validator: nil)
        execution_id = SecureRandom.uuid.freeze
        row = nil
        adapter.__send__(:transaction, operation: "request.claim") do |tx|
          now = adapter.__send__(:backend_time, tx, "request.claim.time")
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "request.claim.lease"
          )
          row = tx.first(
            "request.claim.next",
            <<~SQL,
              #{REQUEST_SELECT}
              WHERE thread_id = ? AND namespace = ?
                AND status NOT IN ('completed', 'failed')
              ORDER BY enqueue_sequence
              LIMIT 1
            SQL
            [lease.thread_id, lease.namespace]
          )
          next unless row
          next unless row.fetch(7) == "queued"

          if validator
            checkpoint = latest_checkpoint_in_transaction(
              tx,
              lease.thread_id,
              lease.namespace,
              "request.claim.latest_checkpoint"
            )
            reason = invoke_stale_validator!(
              validator,
              materialize_request(row),
              checkpoint
            )
            if reason
              terminal_fail_in_transaction!(
                tx,
                lease:,
                row:,
                operation: row.fetch(5).to_sym,
                reason:,
                execution_id:,
                checkpoint_id: checkpoint&.id,
                now:
              )
              row = request_row(
                tx,
                lease.thread_id,
                lease.namespace,
                row.fetch(2),
                "request.claim.result"
              )
              next
            end
          end

          operation = row.fetch(5)
          bound_execution = if %w[turn fork redirect].include?(operation)
                              execution_id
                            else
                              active_execution_id!(
                                tx,
                                lease,
                                "request.claim.active_execution"
                              )
                            end
          claimed_status = operation == "redirect" ? "redirecting" : "claimed"
          target_execution = nil
          cancellation_generation = nil
          if operation == "redirect"
            target_execution = active_execution_id!(
              tx,
              lease,
              "request.claim.redirect_target"
            )
            cancellation_generation = tx.scalar(
              "request.claim.cancellation_generation",
              <<~SQL,
                SELECT COALESCE(MAX(cancellation_generation), 0) + 1
                FROM tamoz_requests
                WHERE thread_id = ? AND namespace = ?
              SQL
              [lease.thread_id, lease.namespace]
            )
          end
          tx.execute(
            "request.claim.update",
            <<~SQL,
              UPDATE tamoz_requests
              SET status = ?, execution_id = ?, target_execution_id = ?,
                  cancellation_generation = ?, owner_fence = ?,
                  updated_at_ms = ?
              WHERE thread_id = ? AND namespace = ? AND request_id = ?
                AND status = 'queued'
            SQL
            [
              claimed_status, bound_execution, target_execution,
              cancellation_generation, lease.fence, now, lease.thread_id,
              lease.namespace, row.fetch(2)
            ]
          )
          raise CheckpointConflictError, "request claim lost" unless tx.changes == 1
          append_request_transition!(
            tx,
            thread_id: lease.thread_id,
            namespace: lease.namespace,
            request_id: row.fetch(2),
            from_status: "queued",
            to_status: claimed_status,
            fence: lease.fence,
            evidence: {
              "kind" => "claim",
              "target_execution_id" => target_execution,
              "cancellation_generation" => cancellation_generation
            },
            now:
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            row.fetch(2),
            "request.claim.result"
          )
        end
        row && materialize_request(row)
      end

      # Recover an interrupted claimed/running/redirecting request under a fresh
      # lease. When a `validator` is supplied (DR-4 C4), the request is validated
      # against the latest decoded checkpoint INSIDE this transaction; a stale
      # request is terminal-failed here (claimed/running -> failed in one atomic
      # write) and returned, never re-executed.
      def recover_request(lease:, request_id:, validator: nil)
        id = Wire.identity(
          request_id,
          name: "request id",
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = nil
        adapter.__send__(:transaction, operation: "request.recover") do |tx|
          now = adapter.__send__(:backend_time, tx, "request.recover.time")
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "request.recover.lease"
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            "request.recover.row"
          )
          raise CheckpointConflictError, "request does not exist" unless row
          unless %w[claimed running redirecting].include?(row.fetch(7))
            raise CheckpointConflictError,
                  "request status #{row.fetch(7)} is not recoverable"
          end
          earlier = tx.scalar(
            "request.recover.earlier",
            <<~SQL,
              SELECT COUNT(*)
              FROM tamoz_requests
              WHERE thread_id = ? AND namespace = ?
                AND enqueue_sequence < ?
                AND status NOT IN ('completed', 'failed')
            SQL
            [lease.thread_id, lease.namespace, row.fetch(3)]
          )
          if earlier.positive?
            raise CheckpointConflictError,
                  "request recovery would skip an earlier nonterminal request"
          end
          if validator
            checkpoint = latest_checkpoint_in_transaction(
              tx,
              lease.thread_id,
              lease.namespace,
              "request.recover.latest_checkpoint"
            )
            reason = invoke_stale_validator!(
              validator,
              materialize_request(row),
              checkpoint
            )
            if reason
              terminal_fail_in_transaction!(
                tx,
                lease:,
                row:,
                operation: row.fetch(5).to_sym,
                reason:,
                execution_id: row.fetch(10),
                checkpoint_id: checkpoint&.id,
                now:
              )
              row = request_row(
                tx,
                lease.thread_id,
                lease.namespace,
                id,
                "request.recover.result"
              )
              next
            end
          end
          tx.execute(
            "request.recover.update",
            <<~SQL,
              UPDATE tamoz_requests
              SET owner_fence = ?, updated_at_ms = ?
              WHERE thread_id = ? AND namespace = ? AND request_id = ?
                AND status = ?
            SQL
            [
              lease.fence, now, lease.thread_id, lease.namespace,
              id, row.fetch(7)
            ]
          )
          raise CheckpointConflictError, "request recovery lost" unless tx.changes == 1
          append_request_transition!(
            tx,
            thread_id: lease.thread_id,
            namespace: lease.namespace,
            request_id: id,
            from_status: row.fetch(7),
            to_status: row.fetch(7),
            fence: lease.fence,
            evidence: {"kind" => "recovery"},
            now:
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            "request.recover.result"
          )
        end
        materialize_request(row)
      end

      def mark_request_running(lease:, request_id:, execution_id:)
        transition_request_without_checkpoint!(
          lease:,
          request_id:,
          execution_id:,
          action: :running
        )
      end

      # Public fenced terminal-fail reserved for the post-claim execution backstop
      # (DR-4 D2): opens its own transaction, validates the lease, and fails a
      # claimed/running request with the same canonical stale payload. Never called
      # from inside the claim transaction.
      def terminal_fail(lease:, request_id:, operation:, reason:)
        id = Wire.identity(
          request_id,
          name: "request id",
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = nil
        adapter.__send__(:transaction, operation: "request.terminal_fail") do |tx|
          now = adapter.__send__(:backend_time, tx, "request.terminal_fail.time")
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "request.terminal_fail.lease"
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            "request.terminal_fail.row"
          )
          raise CheckpointConflictError, "request does not exist" unless row
          unless %w[claimed running redirecting].include?(row.fetch(7))
            raise CheckpointConflictError,
                  "request status #{row.fetch(7)} is not terminal-failable"
          end
          apply_request_transition_in_transaction!(
            tx,
            lease:,
            checkpoint_id: nil,
            transition: stale_terminal_transition(
              request_id: id,
              execution_id: row.fetch(10),
              operation:,
              reason:
            ),
            now:,
            evidence_override: stale_transition_evidence(
              operation:,
              reason:,
              checkpoint_id: nil
            )
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            "request.terminal_fail.result"
          )
        end
        materialize_request(row)
      end

      def request_transition(
        request_id:,
        execution_id:,
        action:,
        graph_status:,
        retryable: nil
      )
        id = Wire.identity(
          request_id,
          name: "request id",
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        action_symbol = case action.to_s
                        when "running" then :running
                        when "completed" then :completed
                        when "failed" then :failed
                        else
                          raise ConfigurationError,
                                "request transition action is invalid"
                        end
        response = checkpoint_codec.state_codec.dump(
          {"graph_status" => graph_status.to_s}
        )
        {
          "request_id" => id,
          "execution_id" => Wire.identity(execution_id, name: "execution id"),
          "action" => action_symbol.to_s,
          "response" => response,
          "response_digest" => Wire.digest(
            response,
            domain: "tamoz.sqlite.request_response"
          ),
          "retryable" => retryable
        }.freeze
      end

      def redirect_ready?(lease:, target_execution_id:)
        target = Wire.identity(
          target_execution_id,
          name: "redirect target execution id"
        )
        adapter.__send__(:transaction, operation: "request.redirect_ready") do |tx|
          now = adapter.__send__(:backend_time, tx, "request.redirect_ready.time")
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "request.redirect_ready.lease"
          )
          unresolved = tx.scalar(
            "request.redirect_ready.effects",
            <<~SQL,
              SELECT COUNT(*)
              FROM tamoz_effects
              WHERE thread_id = ? AND namespace = ? AND execution_id = ?
                AND status IN ('prepared', 'running', 'unknown', 'reconcile')
            SQL
            [lease.thread_id, lease.namespace, target]
          )
          unresolved.zero?
        end
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
        writer = Writer.new(store: self, guard:)
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
            apply_request_transition_in_transaction!(
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

      private

      class Writer
        def initialize(store:, guard:)
          @store = store
          @guard = guard
          @effects = EffectJournal.new(
            store:,
            guard:,
            attempt_ttl: store.adapter.limits.effect_attempt_ttl
          )
          @application_store = store.adapter.store
          freeze
        end

        def fence = @guard.lease.fence
        def check! = @guard.check!
        attr_reader :effects

        def store = @application_store

        def accepts_effects?(value)
          value.respond_to?(:storage_identity) &&
            value.storage_identity.equal?(@store.adapter)
        end

        def accepts_store?(value)
          value.respond_to?(:storage_identity) &&
            value.storage_identity.equal?(@store.adapter)
        end

        def latest
          @store.latest(
            thread_id: @guard.lease.thread_id,
            namespace: Wire.decode_namespace(@guard.lease.namespace)
          )
        end

        def find(checkpoint_id:)
          @store.find(
            thread_id: @guard.lease.thread_id,
            namespace: Wire.decode_namespace(@guard.lease.namespace),
            checkpoint_id:
          )
        end

        def append_writes(task:, outcome:)
          @store.append_writes(
            lease: @guard.lease,
            task:,
            outcome:
          )
        end

        def append_checkpoint(
          expected_base_id:,
          mode:,
          attributes:,
          consumed_task_ids: [],
          request_transition: nil
        )
          @store.append_checkpoint(
            lease: @guard.lease,
            expected_base_id:,
            mode:,
            attributes:,
            consumed_task_ids:,
            request_transition:
          )
        end

        def claim_next_request(validator: nil)
          @store.claim_next_request(lease: @guard.lease, validator:)
        end

        def recover_request(request_id:, validator: nil)
          @store.recover_request(
            lease: @guard.lease,
            request_id:,
            validator:
          )
        end

        # Public fenced terminal-fail for the post-claim execution backstop (DR-4 D2):
        # opens its own fenced transaction and fails a claimed/running request with the
        # canonical stale payload.
        def terminal_fail(request_id:, operation:, reason:)
          @store.terminal_fail(
            lease: @guard.lease,
            request_id:,
            operation:,
            reason:
          )
        end

        def mark_request_running(request_id:, execution_id:)
          @store.mark_request_running(
            lease: @guard.lease,
            request_id:,
            execution_id:
          )
        end

        def request_transition(
          request_id:,
          execution_id:,
          action:,
          graph_status:,
          retryable: nil
        )
          @store.request_transition(
            request_id:,
            execution_id:,
            action:,
            graph_status:,
            retryable:
          )
        end

        def redirect_ready?(target_execution_id:)
          @store.redirect_ready?(
            lease: @guard.lease,
            target_execution_id:
          )
        end
      end

      def normalize_address(thread_id, namespace)
        [
          Wire.identity(thread_id, name: "thread id"),
          Wire.namespace(namespace)
        ].freeze
      end

      def ensure_namespace_for_enqueue!(tx, thread_id:, namespace:, now:)
        tx.execute(
          "request.enqueue.thread",
          <<~SQL,
            INSERT INTO tamoz_threads(
              thread_id, tombstone_id, created_at_ms, updated_at_ms
            )
            VALUES (?, NULL, ?, ?)
            ON CONFLICT(thread_id) DO NOTHING
          SQL
          [thread_id, now, now]
        )
        tombstone_id = tx.scalar(
          "request.enqueue.tombstone",
          "SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?",
          [thread_id]
        )
        raise CheckpointConflictError, "thread is tombstoned" if tombstone_id

        tx.execute(
          "request.enqueue.namespace",
          <<~SQL,
            INSERT INTO tamoz_namespaces(
              thread_id, namespace, active_checkpoint_id,
              next_checkpoint_sequence, next_request_sequence,
              lease_owner_id, lease_fence, lease_expires_at_ms,
              greatest_backend_time_ms, created_at_ms, updated_at_ms
            )
            VALUES (?, ?, NULL, 0, 0, NULL, 0, NULL, ?, ?, ?)
            ON CONFLICT(thread_id, namespace) DO NOTHING
          SQL
          [thread_id, namespace, now, now, now]
        )
      end

      def enum_text!(value, allowed, name)
        text = value.to_s
        return text if allowed.include?(text)

        raise ConfigurationError, "#{name} is invalid"
      end

      def request_row(tx, thread_id, namespace, request_id, label)
        tx.first(
          label,
          <<~SQL,
            #{REQUEST_SELECT}
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
          SQL
          [thread_id, namespace, request_id]
        )
      end

      def materialize_request(row)
        payload = row.fetch(8)
        Wire.verify_digest!(
          payload,
          row.fetch(9),
          domain: "tamoz.sqlite.request_payload"
        )
        operation = persisted_enum_symbol!(
          row.fetch(5),
          REQUEST_OPERATIONS,
          "request operation"
        )
        delivery_mode = persisted_enum_symbol!(
          row.fetch(6),
          DELIVERY_MODES,
          "request delivery mode"
        )
        decoded_payload = checkpoint_codec.load_request_payload(
          operation,
          payload
        )
        unless checkpoint_codec.dump_request_payload(
          operation,
          decoded_payload
        ) == payload
          raise CheckpointCorruptionError, "request payload is not canonical"
        end
        response = row.fetch(14)
        if response
          Wire.verify_digest!(
            response,
            row.fetch(15),
            domain: "tamoz.sqlite.request_response"
          )
        elsif row.fetch(15)
          raise CheckpointCorruptionError,
                "request response digest exists without response"
        end
        terminal_error = row.fetch(16)
        if terminal_error
          Wire.verify_digest!(
            terminal_error,
            row.fetch(17),
            domain: "tamoz.sqlite.request_error"
          )
        elsif row.fetch(17)
          raise CheckpointCorruptionError,
                "request error digest exists without terminal error"
        end
        Tamoz::Graph::RequestRecord.new(
          thread_id: Wire.identity(row.fetch(0), name: "stored request thread"),
          namespace: Wire.decode_namespace(row.fetch(1)),
          request_id: Wire.identity(
            row.fetch(2),
            name: "stored request id",
            max_bytes: Wire::MAX_REQUEST_ID_BYTES
          ),
          enqueue_sequence: row.fetch(3),
          input_digest: row.fetch(4).dup.freeze,
          operation:,
          delivery_mode:,
          status: request_status!(row.fetch(7)),
          payload: decoded_payload,
          execution_id: row.fetch(10)&.dup&.freeze,
          target_execution_id: row.fetch(11)&.dup&.freeze,
          cancellation_generation: row.fetch(12),
          checkpoint_id: row.fetch(13)&.dup&.freeze,
          response: response && canonical_state_value(response, "request response"),
          terminal_error: terminal_error &&
                          canonical_state_value(terminal_error, "request terminal error"),
          retryable: row.fetch(18).nil? ? nil : row.fetch(18) == 1,
          created_at_ms: row.fetch(19),
          updated_at_ms: row.fetch(20)
        )
      end

      def canonical_state_value(bytes, name)
        value = checkpoint_codec.state_codec.load(bytes)
        unless checkpoint_codec.state_codec.dump(value) == bytes
          raise CheckpointCorruptionError, "#{name} is not canonical"
        end

        value
      end

      def request_status!(value)
        unless REQUEST_STATUSES.include?(value)
          raise CheckpointCorruptionError, "request status is invalid"
        end

        value.to_sym
      end

      def persisted_enum_symbol!(value, allowed, name)
        unless value.is_a?(String) && allowed.include?(value)
          raise CheckpointCorruptionError, "stored #{name} is invalid"
        end

        value.to_sym
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
        row && row.fetch(0) && decode_checkpoint_row(row)
      end

      def decode_checkpoint_row(row)
        payload = row.fetch(11)
        Wire.verify_digest!(
          payload,
          row.fetch(12),
          domain: "tamoz.sqlite.checkpoint_payload"
        )
        attributes = checkpoint_codec.load(payload)
        unless attributes.fetch(:execution_id) == row.fetch(6) &&
               attributes.fetch(:graph_name) == row.fetch(7) &&
               attributes.fetch(:graph_version) == row.fetch(8) &&
               attributes.fetch(:definition_digest) == row.fetch(9) &&
               attributes.fetch(:status).to_s == row.fetch(10)
          raise CheckpointCorruptionError,
                "checkpoint columns and payload disagree"
        end
        Tamoz::Graph::Checkpoint.new(
          format_version: row.fetch(5),
          id: Wire.identity(row.fetch(0), name: "stored checkpoint id"),
          sequence: row.fetch(1),
          thread_id: Wire.identity(row.fetch(2), name: "stored thread id"),
          namespace: Wire.decode_namespace(row.fetch(3)),
          parent_id: row.fetch(4)&.dup&.freeze,
          **attributes
        )
      end

      # Invokes the graph-owned staleness predicate with the materialized request and
      # the decoded checkpoint, enforcing the validator return contract (DR-4 13):
      # nil, or a non-empty bounded string without control characters. Any other
      # return (or a raising validator) fails closed before any write is issued.
      def invoke_stale_validator!(validator, request, checkpoint)
        reason = begin
          validator.call(request, checkpoint)
        rescue ConfigurationError
          raise
        rescue StandardError => error
          raise ConfigurationError.new(
            "request staleness validation failed"
          ), cause: error
        end
        validate_stale_reason!(reason)
      end

      MAX_STALE_REASON_BYTES = 512

      def validate_stale_reason!(reason)
        return nil if reason.nil?

        unless reason.is_a?(String) &&
               reason.valid_encoding? &&
               !reason.empty? &&
               reason.bytesize <= MAX_STALE_REASON_BYTES &&
               reason !~ /[[:cntrl:]]/
          raise ConfigurationError,
                "request staleness validator returned an invalid reason"
        end
        reason
      end

      def stale_transition_evidence(operation:, reason:, checkpoint_id:)
        {
          "kind" => "claim_validation",
          "operation" => operation.to_s,
          "reason" => reason,
          "checkpoint_id" => checkpoint_id
        }
      end

      # Canonical terminal-error payload for a stale-fail (DR-4 C5): graph_status
      # failed plus the typed reason and framework-authored evidence. Shared by the
      # claim/recover in-transaction path and the runner's post-claim backstop so
      # both serialize byte-identical payloads for the same cause (DR-4 16).
      def stale_terminal_payload(operation:, reason:)
        payload = {
          "graph_status" => "failed",
          "reason" => reason,
          "evidence" => {"kind" => "claim_validation", "operation" => operation.to_s}
        }
        checkpoint_codec.state_codec.dump(payload)
      end

      # Single atomic queued/claimed/running -> failed write INSIDE an open claim or
      # recover transaction. This is the only writer that can move a request directly
      # from `queued` to `failed`; the public fenced APIs still reject that edge
      # (DR-4 14/32). The stale request keeps the claim-time execution binding and is
      # never observable as `claimed`.
      def terminal_fail_in_transaction!(
        tx,
        lease:,
        row:,
        operation:,
        reason:,
        execution_id:,
        checkpoint_id:,
        now:
      )
        payload = stale_terminal_payload(operation:, reason:)
        tx.execute(
          "request.terminal_fail",
          <<~SQL,
            UPDATE tamoz_requests
            SET status = 'failed',
                execution_id = ?,
                response = NULL, response_digest = NULL,
                terminal_error = ?, terminal_error_digest = ?,
                retryable = NULL, owner_fence = ?,
                updated_at_ms = ?
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
              AND status = ?
          SQL
          [
            execution_id,
            Wire.blob(payload),
            Wire.digest(payload, domain: "tamoz.sqlite.request_error"),
            lease.fence, now,
            lease.thread_id, lease.namespace, row.fetch(2),
            row.fetch(7)
          ]
        )
        raise CheckpointConflictError, "request terminal fail lost" unless tx.changes == 1
        append_request_transition!(
          tx,
          thread_id: lease.thread_id,
          namespace: lease.namespace,
          request_id: row.fetch(2),
          from_status: row.fetch(7),
          to_status: "failed",
          fence: lease.fence,
          evidence: stale_transition_evidence(
            operation:,
            reason:,
            checkpoint_id:
          ),
          now:
        )
      end

      # Public fenced terminal-fail reserved for the post-claim execution backstop
      # (DR-4 D2): opens its own transaction, validates the lease, and fails a
      # claimed/running request with the same canonical stale payload. Never called
      # from inside the claim transaction. (Defined in the public section above;
      # this is the shared payload constructor.)
      def stale_terminal_transition(request_id:, execution_id:, operation:, reason:)
        response = stale_terminal_payload(operation:, reason:)
        {
          "request_id" => request_id,
          "execution_id" => execution_id,
          "action" => "failed",
          "response" => response,
          "response_digest" => Wire.digest(
            response,
            domain: "tamoz.sqlite.request_response"
          ),
          "retryable" => nil
        }.freeze
      end

      def transition_request_without_checkpoint!(
        lease:,
        request_id:,
        execution_id:,
        action:
      )
        transition = request_transition(
          request_id:,
          execution_id:,
          action:,
          graph_status: :running
        )
        row = nil
        adapter.__send__(:transaction, operation: "request.transition") do |tx|
          now = adapter.__send__(:backend_time, tx, "request.transition.time")
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: "request.transition.lease"
          )
          apply_request_transition_in_transaction!(
            tx,
            lease:,
            checkpoint_id: nil,
            transition:,
            now:
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            transition.fetch("request_id"),
            "request.transition.result"
          )
        end
        materialize_request(row)
      end

      def apply_request_transition_in_transaction!(
        tx,
        lease:,
        checkpoint_id:,
        transition:,
        now:,
        evidence_override: nil
      )
        request_id = transition.fetch("request_id")
        row = request_row(
          tx,
          lease.thread_id,
          lease.namespace,
          request_id,
          "request.commit.row"
        )
        raise CheckpointConflictError, "request does not exist" unless row
        unless row.fetch(10) == transition.fetch("execution_id")
          raise CheckpointConflictError, "request execution identity is mismatched"
        end
        unless %w[claimed running redirecting].include?(row.fetch(7))
          raise CheckpointConflictError,
                "request status #{row.fetch(7)} cannot transition"
        end
        unless row.fetch(18).nil? || row.fetch(18).is_a?(Integer)
          raise CheckpointCorruptionError, "request retryable flag is invalid"
        end

        action = transition.fetch("action")
        to_status = case action
                    when "running" then "running"
                    when "completed" then "completed"
                    when "failed" then "failed"
                    else
                      raise ConfigurationError, "request transition action is invalid"
                    end
        if action == "running" && !%w[claimed redirecting].include?(row.fetch(7))
          raise CheckpointConflictError,
                "only a claimed or redirecting request can start"
        end
        if %w[completed failed].include?(action) &&
           !%w[running claimed].include?(row.fetch(7))
          raise CheckpointConflictError,
                "only a running request or atomic claimed operation can become terminal"
        end
        if evidence_override &&
           !evidence_override.is_a?(Hash)
          raise ConfigurationError, "request transition evidence override is invalid"
        end

        response = transition.fetch("response")
        response_digest = transition.fetch("response_digest")
        retryable = transition.fetch("retryable")
        retryable_integer = retryable.nil? ? nil : (retryable ? 1 : 0)
        terminal_error = action == "failed" ? response : nil
        terminal_error_digest = if terminal_error
                                  Wire.digest(
                                    terminal_error,
                                    domain: "tamoz.sqlite.request_error"
                                  )
                                end
        tx.execute(
          "request.commit.update",
          <<~SQL,
            UPDATE tamoz_requests
            SET status = ?, checkpoint_id = COALESCE(?, checkpoint_id),
                response = ?, response_digest = ?,
                terminal_error = ?, terminal_error_digest = ?,
                retryable = ?, owner_fence = ?,
                updated_at_ms = ?
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
              AND status = ?
          SQL
          [
            to_status, checkpoint_id,
            action == "failed" ? nil : Wire.blob(response),
            action == "failed" ? nil : response_digest,
            terminal_error && Wire.blob(terminal_error),
            terminal_error_digest, retryable_integer, lease.fence, now,
            lease.thread_id, lease.namespace, request_id, row.fetch(7)
          ]
        )
        raise CheckpointConflictError, "request transition lost" unless tx.changes == 1
        append_request_transition!(
          tx,
          thread_id: lease.thread_id,
          namespace: lease.namespace,
          request_id:,
          from_status: row.fetch(7),
          to_status:,
          fence: lease.fence,
          evidence: evidence_override || {
            "kind" => action,
            "checkpoint_id" => checkpoint_id
          },
          now:
        )
      end

      def append_request_transition!(
        tx,
        thread_id:,
        namespace:,
        request_id:,
        from_status:,
        to_status:,
        fence:,
        evidence:,
        now:
      )
        index = tx.scalar(
          "request.transition.index",
          <<~SQL,
            SELECT COALESCE(MAX(transition_index) + 1, 0)
            FROM tamoz_request_transitions
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
          SQL
          [thread_id, namespace, request_id]
        )
        evidence_bytes = JSON.generate(evidence)
        tx.execute(
          "request.transition.insert",
          <<~SQL,
            INSERT INTO tamoz_request_transitions(
              thread_id, namespace, request_id, transition_index,
              from_status, to_status, fence, evidence, created_at_ms
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            thread_id, namespace, request_id, index, from_status,
            to_status, fence, Wire.blob(evidence_bytes), now
          ]
        )
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

      def materialize(row)
        payload = row.fetch(11)
        Wire.verify_digest!(
          payload,
          row.fetch(12),
          domain: "tamoz.sqlite.checkpoint_payload"
        )
        attributes = checkpoint_codec.load(payload)
        unless attributes.fetch(:execution_id) == row.fetch(6) &&
               attributes.fetch(:graph_name) == row.fetch(7) &&
               attributes.fetch(:graph_version) == row.fetch(8) &&
               attributes.fetch(:definition_digest) == row.fetch(9) &&
               attributes.fetch(:status).to_s == row.fetch(10)
          raise CheckpointCorruptionError,
                "checkpoint columns and payload disagree"
        end

        pending = attributes.fetch(:pending)
        if row.fetch(0) == row.fetch(13)
          pending = merge_pending(
            pending,
            pending_outcomes(
              thread_id: row.fetch(2),
              namespace: row.fetch(3),
              execution_id: row.fetch(6)
            )
          )
        end
        Tamoz::Graph::Checkpoint.new(
          format_version: row.fetch(5),
          id: Wire.identity(row.fetch(0), name: "stored checkpoint id"),
          sequence: row.fetch(1),
          thread_id: Wire.identity(row.fetch(2), name: "stored thread id"),
          namespace: Wire.decode_namespace(row.fetch(3)),
          parent_id: row.fetch(4)&.dup&.freeze,
          **attributes.merge(pending:)
        )
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

      def merge_pending(checkpoint_pending, durable_pending)
        merged = checkpoint_pending.dup
        durable_pending.each do |task_id, outcome|
          existing = merged[task_id]
          if existing && checkpoint_codec.dump_outcome(existing) !=
                         checkpoint_codec.dump_outcome(outcome)
            raise CheckpointCorruptionError,
                  "checkpoint and pending activation disagree for #{task_id}"
          end
          merged[task_id] = outcome
        end
        merged.freeze
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
           !respond_to?(:apply_request_transition_in_transaction!, true)
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

      private_constant :CHECKPOINT_PROTOCOL_VERSION, :REQUEST_PROTOCOL_VERSION,
                       :MAX_HISTORY_LIMIT, :REQUEST_STATUSES,
                       :REQUEST_OPERATIONS, :DELIVERY_MODES, :REQUEST_SELECT,
                       :Writer
    end
  end
end

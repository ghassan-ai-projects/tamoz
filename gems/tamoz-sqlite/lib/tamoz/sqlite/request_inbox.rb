# frozen_string_literal: true

module Tamoz
  module SQLite
    # The durable request inbox: enqueue, claim, recover, transition, terminal
    # fail. It shares one transaction with a checkpoint commit at exactly one
    # point, `apply_request_transition_in_transaction!`.
    class RequestInbox
      REQUEST_SELECT = <<~SQL.lines.map(&:strip).join(' ').freeze
        SELECT thread_id, namespace, request_id, enqueue_sequence,
               input_digest, operation, delivery_mode, status, payload,
               payload_digest, execution_id, target_execution_id,
               cancellation_generation, checkpoint_id, response,
               response_digest, terminal_error, terminal_error_digest, retryable,
               created_at_ms, updated_at_ms
        FROM tamoz_requests
      SQL

      def initialize(store)
        @store = store
        @staleness = RequestStaleness.new(store.checkpoint_codec.state_codec)
        freeze
      end

      def enqueue_request(
        thread_id:,
        request_id:, operation:, payload:, namespace: [],
        delivery: :queue
      )
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        id = Wire.identity(
          request_id,
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        operation_text = wire.enum_text(
          operation,
          CheckpointWire::REQUEST_OPERATIONS,
          'request operation'
        )
        delivery_text = wire.enum_text(
          delivery,
          CheckpointWire::DELIVERY_MODES,
          'request delivery mode'
        )
        if (operation_text == 'redirect') != (delivery_text == 'redirect')
          raise ConfigurationError,
                'redirect operation and delivery mode must be selected together'
        end
        payload_bytes = checkpoint_codec.dump_request_payload(
          operation_text,
          payload
        )
        payload_digest = Wire.digest(
          payload_bytes,
          domain: 'tamoz.sqlite.request_payload'
        )
        input_digest = Wire.digest(
          JSON.generate([operation_text, delivery_text, payload_bytes]),
          domain: 'tamoz.sqlite.request'
        )
        row = nil

        adapter.__send__(:transaction, operation: 'request.enqueue') do |tx|
          row = enqueue_request_in_transaction!(
            tx,
            thread:, encoded_namespace:, id:,
            operation_text:, delivery_text:, payload_bytes:,
            payload_digest:, input_digest:
          )
        end
        wire.materialize_request(row)
      end

      # P13-A seam (plan §4, C1/DC-4): the enqueue body extracted from the
      # public method so the scheduler's `materialize_due` can claim → create
      # occurrence → enqueue its request in ONE transaction. The public
      # `enqueue_request` and the scheduler adapter both delegate here; neither
      # nests a second transaction. Dedup lives in this primitive: the row key
      # is `(thread_id, namespace, request_id)`, and a duplicate id is accepted
      # only when operation/delivery/payload digests all match — any byte
      # difference raises `CheckpointConflictError` (invariant 38 duplicate-turn
      # hard zero).
      #
      # @return [Array] the request row (materialized by the caller)
      def enqueue_request_in_transaction!(
        tx,
        thread:, encoded_namespace:, id:,
        operation_text:, delivery_text:, payload_bytes:,
        payload_digest:, input_digest:
      )
        now = adapter.__send__(:backend_time, tx, 'request.enqueue.time')
        ensure_namespace_for_enqueue!(
          tx,
          thread_id: thread,
          namespace: encoded_namespace,
          now:
        )
        row = request_row(tx, thread, encoded_namespace, id, 'request.enqueue.existing')
        if row
          unless row.fetch(4) == input_digest &&
                 row.fetch(5) == operation_text &&
                 row.fetch(6) == delivery_text &&
                 row.fetch(9) == payload_digest
            raise CheckpointConflictError,
                  'request id is already bound to different input'
          end
          return row
        end

        sequence = tx.scalar(
          'request.enqueue.sequence',
          <<~SQL,
            SELECT next_request_sequence
            FROM tamoz_namespaces
            WHERE thread_id = ? AND namespace = ?
          SQL
          [thread, encoded_namespace]
        )
        tx.execute(
          'request.enqueue.insert',
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
          to_status: 'queued',
          fence: nil,
          evidence: { 'kind' => 'enqueue' },
          now:
        )
        tx.execute(
          'request.enqueue.advance',
          <<~SQL,
            UPDATE tamoz_namespaces
            SET next_request_sequence = ?,
                greatest_backend_time_ms = MAX(greatest_backend_time_ms, ?),
                updated_at_ms = ?
            WHERE thread_id = ? AND namespace = ?
          SQL
          [sequence + 1, now, now, thread, encoded_namespace]
        )
        request_row(tx, thread, encoded_namespace, id, 'request.enqueue.result')
      end

      def fetch_request(thread_id:, request_id:, namespace: [])
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        id = Wire.identity(
          request_id,
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = adapter.__send__(:read, operation: 'request.fetch') do |tx|
          request_row(tx, thread, encoded_namespace, id, 'request.fetch')
        end
        row && wire.materialize_request(row)
      end

      # Ordered, durable request inbox history for one thread namespace. This is
      # the read path the resumable CLI and the eval harness use to prove exactly
      # one ordered request history after crash/recovery (invariant 23).
      def request_history(thread_id:, namespace: [])
        thread, encoded_namespace = normalize_address(thread_id, namespace)
        rows = adapter.__send__(:read, operation: 'request.history') do |tx|
          tx.rows(
            'request.history.select',
            <<~SQL,
              #{REQUEST_SELECT}
              WHERE thread_id = ? AND namespace = ?
              ORDER BY enqueue_sequence ASC
            SQL
            [thread, encoded_namespace]
          )
        end
        rows.map { |row| wire.materialize_request(row) }.freeze
      end

      # Every (thread, namespace) that currently holds non-terminal request work,
      # oldest enqueue first. A worker polls this to learn WHERE to work; it
      # claims nothing, takes no lease, and orders threads by their oldest
      # outstanding request so no thread can be starved by a busier neighbour.
      #
      # `head_status` is the status of that oldest request, which is the whole
      # recovery signal: `queued` means claimable, while `claimed`/`running`
      # means a previous worker died holding it and the thread needs `recover`
      # rather than a fresh claim.
      def pending_threads(limit: 100)
        bounded = Integer(limit)
        raise ConfigurationError, 'limit must be positive' unless bounded.positive?

        rows = adapter.__send__(:read, operation: 'request.pending_threads') do |tx|
          tx.rows(
            'request.pending_threads.select',
            <<~SQL,
              SELECT thread_id, namespace, request_id, status, enqueue_sequence
              FROM tamoz_requests AS outer_request
              WHERE status NOT IN ('completed', 'failed')
                AND enqueue_sequence = (
                  SELECT MIN(enqueue_sequence) FROM tamoz_requests AS inner_request
                  WHERE inner_request.thread_id = outer_request.thread_id
                    AND inner_request.namespace = outer_request.namespace
                    AND inner_request.status NOT IN ('completed', 'failed')
                )
              ORDER BY enqueue_sequence ASC
              LIMIT ?
            SQL
            [bounded]
          )
        end
        rows.map do |row|
          {
            thread_id: row.fetch(0),
            namespace: Wire.decode_namespace(row.fetch(1)),
            head_request_id: row.fetch(2),
            head_status: row.fetch(3).to_sym,
            enqueue_sequence: row.fetch(4)
          }.freeze
        end.freeze
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
        adapter.__send__(:transaction, operation: 'request.claim') do |tx|
          now = adapter.__send__(:backend_time, tx, 'request.claim.time')
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'request.claim.lease'
          )
          row = tx.first(
            'request.claim.next',
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
          next unless row.fetch(7) == 'queued'

          if validator
            checkpoint = latest_checkpoint_in_transaction(
              tx,
              lease.thread_id,
              lease.namespace,
              'request.claim.latest_checkpoint'
            )
            reason = staleness.reason_for(
              validator,
              wire.materialize_request(row),
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
                'request.claim.result'
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
                                'request.claim.active_execution'
                              )
                            end
          claimed_status = operation == 'redirect' ? 'redirecting' : 'claimed'
          target_execution = nil
          cancellation_generation = nil
          if operation == 'redirect'
            target_execution = active_execution_id!(
              tx,
              lease,
              'request.claim.redirect_target'
            )
            cancellation_generation = tx.scalar(
              'request.claim.cancellation_generation',
              <<~SQL,
                SELECT COALESCE(MAX(cancellation_generation), 0) + 1
                FROM tamoz_requests
                WHERE thread_id = ? AND namespace = ?
              SQL
              [lease.thread_id, lease.namespace]
            )
          end
          tx.execute(
            'request.claim.update',
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
          raise CheckpointConflictError, 'request claim lost' unless tx.changes == 1

          append_request_transition!(
            tx,
            thread_id: lease.thread_id,
            namespace: lease.namespace,
            request_id: row.fetch(2),
            from_status: 'queued',
            to_status: claimed_status,
            fence: lease.fence,
            evidence: {
              'kind' => 'claim',
              'target_execution_id' => target_execution,
              'cancellation_generation' => cancellation_generation
            },
            now:
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            row.fetch(2),
            'request.claim.result'
          )
        end
        row && wire.materialize_request(row)
      end

      # Recover an interrupted claimed/running/redirecting request under a fresh
      # lease. When a `validator` is supplied (DR-4 C4), the request is validated
      # against the latest decoded checkpoint INSIDE this transaction; a stale
      # request is terminal-failed here (claimed/running -> failed in one atomic
      # write) and returned, never re-executed.
      def recover_request(lease:, request_id:, validator: nil)
        id = Wire.identity(
          request_id,
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = nil
        adapter.__send__(:transaction, operation: 'request.recover') do |tx|
          now = adapter.__send__(:backend_time, tx, 'request.recover.time')
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'request.recover.lease'
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            'request.recover.row'
          )
          raise CheckpointConflictError, 'request does not exist' unless row
          unless %w[claimed running redirecting].include?(row.fetch(7))
            raise CheckpointConflictError,
                  "request status #{row.fetch(7)} is not recoverable"
          end
          earlier = tx.scalar(
            'request.recover.earlier',
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
                  'request recovery would skip an earlier nonterminal request'
          end
          if validator
            checkpoint = latest_checkpoint_in_transaction(
              tx,
              lease.thread_id,
              lease.namespace,
              'request.recover.latest_checkpoint'
            )
            reason = staleness.reason_for(
              validator,
              wire.materialize_request(row),
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
                'request.recover.result'
              )
              next
            end
          end
          tx.execute(
            'request.recover.update',
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
          raise CheckpointConflictError, 'request recovery lost' unless tx.changes == 1

          append_request_transition!(
            tx,
            thread_id: lease.thread_id,
            namespace: lease.namespace,
            request_id: id,
            from_status: row.fetch(7),
            to_status: row.fetch(7),
            fence: lease.fence,
            evidence: { 'kind' => 'recovery' },
            now:
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            'request.recover.result'
          )
        end
        wire.materialize_request(row)
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
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        row = nil
        adapter.__send__(:transaction, operation: 'request.terminal_fail') do |tx|
          now = adapter.__send__(:backend_time, tx, 'request.terminal_fail.time')
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'request.terminal_fail.lease'
          )
          row = request_row(
            tx,
            lease.thread_id,
            lease.namespace,
            id,
            'request.terminal_fail.row'
          )
          raise CheckpointConflictError, 'request does not exist' unless row
          unless %w[claimed running redirecting].include?(row.fetch(7))
            raise CheckpointConflictError,
                  "request status #{row.fetch(7)} is not terminal-failable"
          end
          apply_request_transition_in_transaction!(
            tx,
            lease:,
            checkpoint_id: nil,
            transition: staleness.terminal_transition(
              request_id: id,
              execution_id: row.fetch(10),
              operation:,
              reason:
            ),
            now:,
            evidence_override: staleness.transition_evidence(
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
            'request.terminal_fail.result'
          )
        end
        wire.materialize_request(row)
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
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        action_symbol = case action.to_s
                        when 'running' then :running
                        when 'completed' then :completed
                        when 'failed' then :failed
                        else
                          raise ConfigurationError,
                                'request transition action is invalid'
                        end
        response = checkpoint_codec.state_codec.dump(
          { 'graph_status' => graph_status.to_s }
        )
        {
          'request_id' => id,
          'execution_id' => Wire.identity(execution_id, name: 'execution id'),
          'action' => action_symbol.to_s,
          'response' => response,
          'response_digest' => Wire.digest(
            response,
            domain: 'tamoz.sqlite.request_response'
          ),
          'retryable' => retryable
        }.freeze
      end

      def redirect_ready?(lease:, target_execution_id:)
        target = Wire.identity(
          target_execution_id,
          name: 'redirect target execution id'
        )
        adapter.__send__(:transaction, operation: 'request.redirect_ready') do |tx|
          now = adapter.__send__(:backend_time, tx, 'request.redirect_ready.time')
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'request.redirect_ready.lease'
          )
          unresolved = tx.scalar(
            'request.redirect_ready.effects',
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

      # Called by CheckpointStore#append_checkpoint.

      def apply_request_transition_in_transaction!(
        tx,
        lease:,
        checkpoint_id:,
        transition:,
        now:,
        evidence_override: nil
      )
        request_id = transition.fetch('request_id')
        row = request_row(tx, lease.thread_id, lease.namespace, request_id, 'request.commit.row')
        raise CheckpointConflictError, 'request does not exist' unless row

        plan = RequestTransitionPlan.for(
          row:, transition:, checkpoint_id:, evidence_override:
        )
        tx.execute(
          'request.commit.update',
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
            plan.to_status, checkpoint_id,
            plan.response_blob, plan.response_digest,
            plan.terminal_error_blob, plan.terminal_error_digest,
            plan.retryable_integer, lease.fence, now,
            lease.thread_id, lease.namespace, request_id, plan.from_status
          ]
        )
        raise CheckpointConflictError, 'request transition lost' unless tx.changes == 1

        append_request_transition!(
          tx,
          thread_id: lease.thread_id,
          namespace: lease.namespace,
          request_id:,
          from_status: plan.from_status,
          to_status: plan.to_status,
          fence: lease.fence,
          evidence: plan.evidence,
          now:
        )
      end

      private

      attr_reader :staleness

      def wire = @store.wire
      def adapter = @store.adapter
      def checkpoint_codec = @store.checkpoint_codec
      def normalize_address(...) = @store.normalize_address(...)
      def active_execution_id!(...) = @store.active_execution_id!(...)
      def latest_checkpoint_in_transaction(...) = @store.latest_checkpoint_in_transaction(...)

      def ensure_namespace_for_enqueue!(tx, thread_id:, namespace:, now:)
        tx.execute(
          'request.enqueue.thread',
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
          'request.enqueue.tombstone',
          'SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?',
          [thread_id]
        )
        raise CheckpointConflictError, 'thread is tombstoned' if tombstone_id

        tx.execute(
          'request.enqueue.namespace',
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
        payload = staleness.terminal_payload(operation:, reason:)
        tx.execute(
          'request.terminal_fail',
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
            Wire.digest(payload, domain: 'tamoz.sqlite.request_error'),
            lease.fence, now,
            lease.thread_id, lease.namespace, row.fetch(2),
            row.fetch(7)
          ]
        )
        raise CheckpointConflictError, 'request terminal fail lost' unless tx.changes == 1

        append_request_transition!(
          tx,
          thread_id: lease.thread_id,
          namespace: lease.namespace,
          request_id: row.fetch(2),
          from_status: row.fetch(7),
          to_status: 'failed',
          fence: lease.fence,
          evidence: staleness.transition_evidence(
            operation:,
            reason:,
            checkpoint_id:
          ),
          now:
        )
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
        adapter.__send__(:transaction, operation: 'request.transition') do |tx|
          now = adapter.__send__(:backend_time, tx, 'request.transition.time')
          adapter.__send__(
            :validate_lease_in_transaction!,
            tx,
            lease,
            now:,
            label: 'request.transition.lease'
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
            transition.fetch('request_id'),
            'request.transition.result'
          )
        end
        wire.materialize_request(row)
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
          'request.transition.index',
          <<~SQL,
            SELECT COALESCE(MAX(transition_index) + 1, 0)
            FROM tamoz_request_transitions
            WHERE thread_id = ? AND namespace = ? AND request_id = ?
          SQL
          [thread_id, namespace, request_id]
        )
        evidence_bytes = JSON.generate(evidence)
        tx.execute(
          'request.transition.insert',
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

      private_constant :REQUEST_SELECT
    end
  end
end

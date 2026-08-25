# frozen_string_literal: true

module Tamoz
  module SQLite
    # :nodoc: Owns request creation and its idempotent durable insert.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall
    # :reek:FeatureEnvy :reek:LongParameterList :reek:MissingSafeMethod
    # :reek:TooManyMethods :reek:TooManyStatements :reek:UtilityFunction -- durable SQL stays explicit.
    # rubocop:disable Naming/MethodParameterName, Layout/EmptyLineBetweenDefs -- `tx` marks boundaries; compact grouping keeps the writer under 250 lines.
    class RequestInboxEnqueuer
      def initialize(store, rows:, transitions:)
        @store = store
        @rows = rows
        @transitions = transitions
        freeze
      end
      def enqueue_request( # rubocop:disable Metrics/ParameterLists -- mirrors the durable RequestInbox API.
        thread_id:,
        request_id:, operation:, payload:, namespace: [],
        delivery: :queue
      )
        input = build_input(
          thread_id:,
          request_id:,
          operation:,
          payload:,
          namespace:,
          delivery:
        )
        row = nil
        adapter.__send__(:transaction, operation: 'request.enqueue') do |tx|
          row = enqueue_request_in_transaction!(tx, input:)
        end
        wire.materialize_request(row)
      end
      # The scheduler uses this primitive inside its existing transaction.
      def enqueue_request_in_transaction!(tx, input:)
        now = adapter.__send__(:backend_time, tx, 'request.enqueue.time')
        ensure_namespace_for_enqueue!(
          tx,
          thread_id: input.thread,
          namespace: input.encoded_namespace,
          now:
        )
        row = request_row_for_enqueue(tx, input, 'request.enqueue.existing')
        return verify_existing_row!(row, input) if row

        sequence = next_request_sequence(tx, input)
        persist_new_request!(tx, input:, sequence:, now:)
        request_row_for_enqueue(tx, input, 'request.enqueue.result')
      end

      def next_request_sequence(tx, input)
        tx.scalar(
          'request.enqueue.sequence',
          <<~SQL,
            SELECT next_request_sequence
            FROM tamoz_namespaces
            WHERE thread_id = ? AND namespace = ?
          SQL
          [input.thread, input.encoded_namespace]
        )
      end
      def persist_new_request!(tx, input:, sequence:, now:)
        insert_request!(tx, input:, sequence:, now:)
        transitions.append_request_transition!(
          tx,
          thread_id: input.thread,
          namespace: input.encoded_namespace,
          request_id: input.id,
          from_status: nil,
          to_status: 'queued',
          fence: nil,
          evidence: { 'kind' => 'enqueue' },
          now:
        )
        advance_sequence!(tx, input.thread, input.encoded_namespace, sequence, now)
      end

      private

      attr_reader :rows, :transitions

      def request_row_for_enqueue(tx, input, label)
        rows.request_row(tx, input.thread, input.encoded_namespace, input.id, label)
      end

      def adapter = @store.adapter
      def wire = @store.wire
      def checkpoint_codec = @store.checkpoint_codec
      # rubocop:disable Metrics/MethodLength, Metrics/ParameterLists -- input normalization mirrors the durable enqueue API.
      def build_input(thread_id:, request_id:, operation:, payload:, namespace:, delivery:)
        thread, encoded_namespace = @store.normalize_address(thread_id, namespace)
        id = Wire.identity(
          request_id,
          name: 'request id',
          max_bytes: Wire::MAX_REQUEST_ID_BYTES
        )
        operation_text, delivery_text = normalize_modes(operation, delivery)
        payload_bytes, payload_digest, input_digest = encode_payload(
          operation_text,
          delivery_text,
          payload
        )
        RequestInboxEnqueueInput.new(
          thread:,
          encoded_namespace:,
          id:,
          operation_text:,
          delivery_text:,
          payload_bytes:,
          payload_digest:,
          input_digest:
        )
      end
      # rubocop:enable Metrics/MethodLength, Metrics/ParameterLists

      def encode_payload(operation, delivery, payload)
        payload_bytes = checkpoint_codec.dump_request_payload(operation, payload)
        payload_digest = Wire.digest(
          payload_bytes,
          domain: 'tamoz.sqlite.request_payload'
        )
        input_digest = Wire.digest(
          JSON.generate([operation, delivery, payload_bytes]),
          domain: 'tamoz.sqlite.request'
        )
        [payload_bytes, payload_digest, input_digest]
      end
      def normalize_modes(operation, delivery)
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
        validate_redirect_pair!(operation_text, delivery_text)
        [operation_text, delivery_text]
      end
      def validate_redirect_pair!(operation, delivery)
        return if (operation == 'redirect') == (delivery == 'redirect')

        raise ConfigurationError,
              'redirect operation and delivery mode must be selected together'
      end
      def verify_existing_row!(row, input)
        unless row.fetch(4) == input.input_digest &&
               row.fetch(5) == input.operation_text &&
               row.fetch(6) == input.delivery_text &&
               row.fetch(9) == input.payload_digest
          raise CheckpointConflictError,
                'request id is already bound to different input'
        end
        row
      end

      def ensure_namespace_for_enqueue!(tx, thread_id:, namespace:, now:)
        ensure_thread!(tx, thread_id, now)
        tombstone_id = tx.scalar(
          'request.enqueue.tombstone',
          'SELECT tombstone_id FROM tamoz_threads WHERE thread_id = ?',
          [thread_id]
        )
        raise CheckpointConflictError, 'thread is tombstoned' if tombstone_id

        ensure_namespace!(tx, thread_id, namespace, now)
      end
      def ensure_thread!(tx, thread_id, now)
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
      end
      def ensure_namespace!(tx, thread_id, namespace, now)
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

      # One SQL shape keeps the durable request columns and timestamp bindings together.
      def insert_request!(tx, input:, sequence:, now:) # rubocop:disable Metrics/MethodLength -- one durable row shape keeps bindings auditable.
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
            input.thread, input.encoded_namespace, input.id, sequence,
            input.input_digest, input.operation_text, input.delivery_text,
            Wire.blob(input.payload_bytes), input.payload_digest, now, now
          ]
        )
      end

      def advance_sequence!(tx, thread, namespace, sequence, now)
        tx.execute(
          'request.enqueue.advance',
          <<~SQL,
            UPDATE tamoz_namespaces
            SET next_request_sequence = ?,
                greatest_backend_time_ms = MAX(greatest_backend_time_ms, ?),
                updated_at_ms = ?
            WHERE thread_id = ? AND namespace = ?
          SQL
          [sequence + 1, now, now, thread, namespace]
        )
      end
    end
    # rubocop:enable Naming/MethodParameterName, Layout/EmptyLineBetweenDefs
  end
end

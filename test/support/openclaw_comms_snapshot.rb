# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # The read side of the B0 comms fixture: durable rows and the snapshot the oracles grade.
      module OpenclawCommsSnapshot
        def request_ids_for(conversation_id)
          read_rows(
            %w[request_id],
            'SELECT request_id FROM tamoz_comms_requests WHERE conversation_id = ?
             ORDER BY created_at_ms ASC, request_id ASC',
            [conversation_id]
          ).map { |row| row.fetch('request_id') }
        end

        # The durable cancellation-timeline inputs of every comms request:
        # the requested/observed stamps and the projection state whose
        # `completed` value decides whether a raced completion won the race.
        def cancellation_stamp_rows
          read_rows(
            %w[request_id projection_state requested_at_ms observed_at_ms],
            'SELECT request_id, projection_state, cancellation_requested_at_ms,
                    cancellation_observed_at_ms
             FROM tamoz_comms_requests ORDER BY created_at_ms ASC, request_id ASC'
          )
        end

        def snapshot(conversations: [OpenclawCommsFixture::CONVERSATION_A])
          facts = snapshot_facts(conversations)
          references = facts['requests'].filter_map { |row| row['request_ref'] }.uniq
          facts.merge('request_projections' => resolved_request_projections(references, conversations))
        end

        private

        def snapshot_facts(conversations)
          {
            'inbound' => inbound_rows,
            'requests' => request_rows,
            'outbox' => outbox_snapshot,
            'history' => per_conversation(conversations) { |conversation| history(conversation) },
            'status' => per_conversation(conversations) { |conversation| projection(status(conversation)) },
            'session' => per_conversation(conversations) do |conversation|
              view_snapshot(view(thread_for(conversation)))
            end,
            'effects' => effect_rows,
            'sends' => @transport.sends.map { |send| send.transform_keys(&:to_s) }
          }
        end

        def per_conversation(conversations, &)
          conversations.to_h { |conversation| [conversation, yield(conversation)] }
        end

        def effect_rows
          effect_census.map do |row|
            { 'thread_id' => row[:thread_id], 'effect_key' => row[:effect_key],
              'operation' => row[:operation], 'status' => row[:status] }
          end
        end

        def resolved_request_projections(references, conversations)
          references.to_h do |reference|
            resolved_projection = conversations.filter_map do |conversation|
              resolved = request_status(conversation, reference)
              next nil unless resolved.is_a?(Hash)

              projection(resolved)
            end.first
            [reference, resolved_projection]
          end.compact
        end

        def projection(projection_hash)
          return nil unless projection_hash.is_a?(Hash)

          projection_hash.except('queue_age_ms')
        end

        def view_snapshot(view)
          return { 'status' => 'absent' } unless view

          { 'status' => view.status.to_s,
            'terminal_reason' => view.terminal && view.terminal['reason'],
            'satisfied' => view.terminal && view.terminal['satisfied'] }
        end

        def inbound_rows
          read_rows(%w[update_id disposition reason],
                    'SELECT update_id, disposition, reason FROM tamoz_comms_inbound ORDER BY update_id ASC')
        end

        def request_rows
          rows = read_rows(%w[request_id conversation_id projection_state],
                           'SELECT request_id, conversation_id, projection_state FROM tamoz_comms_requests
                            ORDER BY created_at_ms ASC, request_id ASC')
          rows.map do |row|
            row.merge('request_ref' => Tamoz::Comms::Lifecycle::RequestRef.for(row.fetch('request_id')))
          end
        end

        def read_rows(columns, sql, params = [])
          @runtime.adapter.__send__(:read, operation: 'benchmark.comms_fixture') do |txn|
            txn.rows('benchmark.comms_fixture.select', sql, params).map do |row_array|
              columns.zip(row_array).to_h
            end
          end
        end

        def outbox_snapshot
          outbox.map do |row|
            # The stored text is what history is compared against, so the
            # snapshot must not truncate it.
            row.except('expires_at_ms', 'claim_expires_at_ms', 'created_at_ms', 'updated_at_ms',
                       'send_started_at_ms')
          end
        end
      end
    end
  end
end

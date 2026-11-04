# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # Shared fixture helpers for the per-scenario drive classes.
      class OpenclawCommsDriveSupport
        def initialize(adapter)
          @adapter = adapter
        end

        private

        def raw_update(update_id, text, user_id: @adapter.user_bound,
                       chat_id: conversation_number(@adapter.conversation_a))
          { 'update_id' => update_id,
            'message' => { 'message_id' => update_id + 10_000, 'date' => 1_752_700_800,
                           'chat' => { 'id' => chat_id, 'type' => 'private' },
                           'from' => { 'id' => user_id }, 'text' => text } }
        end

        def callback_update(update_id, data:, callback_message_id:)
          { 'update_id' => update_id,
            'callback_query' => { 'id' => "cb#{update_id}", 'data' => data,
                                  'from' => { 'id' => @adapter.user_bound },
                                  'message' => { 'message_id' => callback_message_id, 'date' => 1_752_700_800,
                                                 'chat' => { 'id' => conversation_number(@adapter.conversation_a),
                                                             'type' => 'private' } } } }
        end

        def conversation_number(conversation_id)
          conversation_id.delete_prefix('telegram:chat:').to_i
        end

        def with_fixture(**)
          fixture = @adapter.build(**)
          yield fixture
        ensure
          fixture&.close
        end

        def build_parity_answer_factory
          @adapter.model_factory(:parity_answer)
        end

        def parked_approval_ask
          { timeout_s: 86_400, on_timeout: :park }
        end

        def work_through_crash(fixture)
          fixture.work
        rescue @adapter.crash_error
          nil
        end

        def poll_fresh_workers(fixture, passes)
          passes.times do
            break if yield

            fixture.fresh_worker.poll_once
          end
        end

        def completed_view?(fixture, conversation)
          view = fixture.view(fixture.thread_for(conversation))
          view && %i[completed failed blocked].include?(view.status)
        end

        def delivery_baseline(fixture)
          fixture.outbox.map { |row| row.fetch('delivery_id') }
        end

        def fresh_outbox_rows(fixture, baseline_ids)
          fixture.outbox.reject { |row| baseline_ids.include?(row.fetch('delivery_id')) }
        end

        # One surface's expression of one request's outcome: the durable
        # request row (agent side), its reference, terminal reason, and the
        # delivery axis derived from the outbox rows that leg produced.
        def leg_snapshot(fixture, conversation:, thread_id:, request_id:, delivery_baseline:)
          row = fixture.request_row(thread_id, request_id)
          {
            'conversation_id' => conversation,
            'thread_id' => thread_id,
            'request_id' => request_id,
            'reference' => Tamoz::Comms::Lifecycle::RequestRef.for(request_id),
            'request_status' => row && row.status.to_s,
            'request_row_present' => !row.nil?,
            'terminal_reason' => fixture.view(thread_id)&.terminal&.dig('reason'),
            'delivery_state' => leg_delivery_state(fixture, delivery_baseline)
          }.compact
        end

        def leg_delivery_state(fixture, baseline_ids)
          fresh = fresh_outbox_rows(fixture, baseline_ids)
                  .select { |row| OpenclawCommsOracles::TERMINAL_KINDS.include?(row['kind']) }
          return 'none' if fresh.empty?

          statuses = fresh.map { |row| row['status'] }.uniq
          statuses.length == 1 ? statuses.first : 'mixed'
        end

        def terminal_delivered?(fixture, baseline_ids)
          leg_delivery_state(fixture, baseline_ids) == 'succeeded'
        end

        def control_reply_text(fixture, update_id, text)
          baseline = delivery_baseline(fixture)
          fixture.submit([raw_update(update_id, text)])
          reply = fresh_outbox_rows(fixture, baseline).find { |row| row['kind'] == 'control' }
          reply ? reply.fetch('text').to_s : ''
        end
      end
    end
  end
end

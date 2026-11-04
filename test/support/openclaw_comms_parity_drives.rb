# frozen_string_literal: true

require_relative 'openclaw_comms_cancellation_drives'

module Tamoz
  module Evals
    module Benchmark
      # C1, C6 and C9: one durable thread (or isolated threads) reached from
      # both the telegram and the durable-CLI surface.
      class OpenclawCommsParityDrives < OpenclawCommsDriveSupport
        def drive_c1
          with_fixture(model_factory: build_parity_answer_factory) do |fixture|
            conversation = @adapter.conversation_a
            thread = fixture.thread_for(conversation)
            telegram_leg = drive_telegram_leg(fixture, conversation, thread, 101)
            cli_leg = drive_cli_leg(fixture, conversation, thread)
            fixture.snapshot(conversations: [conversation]).merge(
              'driven_update_ids' => [101],
              'telegram_legs' => [telegram_leg],
              'cli_legs' => [cli_leg]
            )
          end
        end

        # C6 drives ONE durable thread from both surfaces: a telegram turn and
        # a durable-CLI turn answer DIFFERENT scripted texts (so parity can
        # never be byte equality), then telegram /cancel stops CLI-submitted
        # queued work. Cancellation issued from each path must record the same
        # durable payload contract.
        def drive_c6
          with_fixture(model_factory: build_parity_answer_factory) do |fixture|
            conversation = @adapter.conversation_a
            thread = fixture.thread_for(conversation)
            telegram_legs = [drive_telegram_leg(fixture, conversation, thread, 861)]
            cli_legs = [drive_cli_leg(fixture, conversation, thread)]
            cancellations = OpenclawCommsCancellationDrives.new(@adapter).drive_cancellation_pair(
              fixture, conversation, telegram_update_id: 863, cli_purpose: 'c6_cancel_target'
            )
            facts = fixture.snapshot(conversations: [conversation]).merge(
              'driven_update_ids' => [861], 'telegram_legs' => telegram_legs,
              'cli_legs' => cli_legs, 'cancellations' => cancellations
            )
            facts['distinct_answer_texts'] = distinct_answer_texts?(facts, conversation)
            facts
          end
        end

        def drive_c9
          with_fixture do |fixture|
            conversation_a = @adapter.conversation_a
            conversation_b = @adapter.conversation_b
            fixture.bind_correspondent(@adapter.user_other, conversation_b)
            fixture.bind_thread(conversation_b)
            telegram_legs = drive_isolation_telegram_legs(fixture, conversation_a, conversation_b)
            cli_legs = [conversation_a, conversation_b].map do |conversation|
              drive_isolation_cli_leg(fixture, conversation)
            end
            snapshot = fixture.snapshot(conversations: [conversation_a, conversation_b])
            snapshot.merge(
              'driven_update_ids' => [901, 902],
              'cross_projections' => cross_projections(fixture, snapshot, conversation_a, conversation_b),
              'telegram_legs' => telegram_legs.compact,
              'cli_legs' => cli_legs
            )
          end
        end

        private

        def drive_telegram_leg(fixture, conversation, thread, update_id)
          baseline = delivery_baseline(fixture)
          fixture.submit([raw_update(update_id, 'What is two plus two?')])
          fixture.work
          fixture.drain
          request_id = fixture.request_ids_for(conversation).first
          raise 'telegram turn was not admitted durably' unless request_id

          leg_snapshot(fixture, conversation: conversation, thread_id: thread,
                                request_id: request_id, delivery_baseline: baseline)
        end

        def drive_cli_leg(fixture, conversation, thread)
          baseline = delivery_baseline(fixture)
          request_id = fixture.submit_cli_task(thread_id: thread, purpose: 'parity_turn',
                                               task: 'Answer the operator task.')
          fixture.work
          fixture.drain
          leg_snapshot(fixture, conversation: conversation, thread_id: thread,
                                request_id: request_id, delivery_baseline: baseline)
        end

        def distinct_answer_texts?(facts, conversation)
          answers = OpenclawCommsOracles.confirmed_answer_texts(facts, conversation)
          # Only the two PARITY legs must differ; later cancellation
          # occurrences legitimately repeat the runner's own terminal text.
          answers.length >= 2 && answers.first(2).uniq.length == 2
        end

        def drive_isolation_telegram_legs(fixture, conversation_a, conversation_b)
          [
            drive_isolation_turn(fixture, conversation_a, 901, 'Conversation A question.',
                                 user_id: @adapter.user_bound),
            drive_isolation_turn(fixture, conversation_b, 902, 'Conversation B question.',
                                 user_id: @adapter.user_other)
          ]
        end

        def drive_isolation_cli_leg(fixture, conversation)
          thread = fixture.thread_for(conversation)
          baseline = delivery_baseline(fixture)
          request_id = fixture.submit_cli_task(thread_id: thread, purpose: 'isolation_probe',
                                               task: "Report state for #{conversation}.")
          fixture.work
          fixture.drain
          leg_snapshot(fixture, conversation: conversation, thread_id: thread,
                                request_id: request_id, delivery_baseline: baseline)
        end

        def cross_projections(fixture, snapshot, conversation_a, conversation_b)
          refs = snapshot['requests'].group_by { |row| row['conversation_id'] }
          foreign_refs = request_refs(refs, conversation_b) - request_refs(refs, conversation_a)
          foreign_refs.to_h do |ref|
            resolved = fixture.request_status(conversation_a, ref)
            [ref, resolved.is_a?(Hash) ? resolved.except('queue_age_ms') : resolved.to_s]
          end
        end

        def request_refs(rows_by_conversation, conversation)
          (rows_by_conversation[conversation] || []).map { |row| row.fetch('request_ref') }
        end

        def drive_isolation_turn(fixture, conversation, update_id, text, user_id:)
          baseline = delivery_baseline(fixture)
          fixture.submit([raw_update(update_id, text,
                                     user_id: user_id,
                                     chat_id: conversation_number(conversation))])
          fixture.work
          fixture.drain
          request_id = fixture.request_ids_for(conversation).first
          return nil unless request_id

          leg_snapshot(fixture, conversation: conversation, thread_id: fixture.thread_for(conversation),
                                request_id: request_id, delivery_baseline: baseline)
        end
      end
    end
  end
end

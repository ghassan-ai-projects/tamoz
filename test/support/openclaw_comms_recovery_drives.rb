# frozen_string_literal: true

require_relative 'openclaw_comms_drive_support'

module Tamoz
  module Evals
    module Benchmark
      # C2-C4: crash recovery, delivery failure modes and restart boundaries.
      class OpenclawCommsRecoveryDrives < OpenclawCommsDriveSupport
        def drive_c2
          factory = @adapter.crashing_factory(:c2_recovery)
          with_fixture(model_factory: factory) do |fixture|
            conversation = @adapter.conversation_a
            fixture.submit([raw_update(201, 'Summarize both notes.')])
            work_through_crash(fixture)
            work_until_terminal(fixture, fixture.fresh_worker, conversation)
            fixture.drain
            fixture.snapshot(conversations: [conversation]).merge('driven_update_ids' => [201])
          end
        end

        def drive_c3
          with_fixture do |fixture|
            results = {
              'throttle_then_delivered' => c3_throttle_then_delivered?(fixture),
              'unknown_preserved_no_resend' => c3_unknown_preserved?(fixture),
              'stale_owner_mark_refused' => c3_stale_owner_refused?(fixture),
              'auth_failed_typed' => c3_auth_failed_typed?(fixture)
            }
            fixture.snapshot(conversations: [@adapter.conversation_a])
                   .merge('driven_update_ids' => [301, 302, 303, 304])
                   .merge(results)
          end
        end

        def drive_c4
          factory = @adapter.crashing_factory(:c4_recovery)
          with_fixture(model_factory: factory) do |fixture|
            conversation = @adapter.conversation_a
            boundaries = []
            fixture.submit([raw_update(401, 'Read note one.')])
            boundaries << 'after_inbound_persistence'
            work_through_crash(fixture)
            boundaries << 'after_worker_claim_crash'
            work_until_terminal(fixture, fixture.fresh_worker, conversation)
            boundaries << 'after_terminal_enqueue'
            require_terminal_sent_once(fixture)
            fixture.snapshot(conversations: [conversation]).merge(
              'driven_update_ids' => [401], 'boundaries_executed' => boundaries
            )
          end
        end

        private

        def c3_throttle_then_delivered?(fixture)
          complete_turn(fixture, 301, 'note one please')
          answer = pending_answer(fixture)
          fixture.transport.send_script = [Tamoz::Comms::ThrottledError.new('throttled')]
          first = fixture.drain
          second = fixture.drain(now: fixture.now + 120)
          first == :throttled && second == :drained && delivered?(fixture, answer)
        end

        def c3_unknown_preserved?(fixture)
          transport = fixture.transport
          complete_turn(fixture, 302, 'note two please')
          answer = pending_answer(fixture)
          transport.send_script = [Tamoz::Comms::AmbiguousDeliveryError.new('timeout after send')]
          fixture.drain
          unknown_before = unknown_rows(fixture, answer)
          sends_after_unknown = transport.sends.length
          fixture.drain
          unknown_rows(fixture, answer) == unknown_before && transport.sends.length == sends_after_unknown
        end

        def c3_stale_owner_refused?(fixture)
          complete_turn(fixture, 303, 'note three please')
          stale_owner_refused?(fixture)
        end

        def c3_auth_failed_typed?(fixture)
          complete_turn(fixture, 304, 'note four please')
          fixture.transport.send_script = [Tamoz::Comms::AuthenticationError.new('bot token revoked')]
          fixture.drain == :authentication_refused
        end

        def require_terminal_sent_once(fixture)
          fixture.drain
          sends_once = answer_send_count(fixture)
          fixture.drain
          raise 'terminal re-sent after restart boundary' unless answer_send_count(fixture) == sends_once
        end

        def answer_send_count(fixture)
          fixture.transport.sends.count { |send| send[:kind] == 'answer' }
        end

        def work_until_terminal(fixture, worker, conversation, max_passes: 8)
          max_passes.times do
            break if completed_view?(fixture, conversation)

            worker.poll_once
          end
          raise 'turn never reached a terminal view' unless completed_view?(fixture, conversation)
        end

        def complete_turn(fixture, update_id, text)
          fixture.submit([raw_update(update_id, text)])
          fixture.work
          raise 'turn did not complete' unless completed_view?(
            fixture, @adapter.conversation_a
          )
        end

        def latest_pending_answer_row(fixture)
          fixture.outbox(statuses: %w[pending]).reverse.find { |candidate| candidate['kind'] == 'answer' }
        end

        def pending_answer(fixture)
          latest_pending_answer_row(fixture)&.fetch('delivery_id')
        end

        def delivered?(fixture, delivery_id)
          row = fixture.outbox(statuses: %w[succeeded]).find do |candidate|
            candidate['delivery_id'] == delivery_id
          end
          !row.nil?
        end

        def unknown_rows(fixture, delivery_id)
          fixture.outbox(statuses: %w[unknown]).select { |row| row['delivery_id'] == delivery_id }
                                               .map do |row|
            [
              row['delivery_id'], row['status'], row['receipt']
            ]
          end
        end

        def stale_owner_refused?(fixture)
          row = latest_pending_answer_row(fixture)
          return false unless row

          now = fixture.now
          claimed = fixture.store.claim_delivery(
            delivery_id: row.fetch('delivery_id'),
            lease: Tamoz::Comms::Lease.new(owner: 'owner-stale-a', fence: 11).wire,
            claim_expires_at: now + 30, now: now
          )
          return false unless claimed == :claimed

          fixture.store.reconcile_expired_deliveries(now: now + 60)
          result = fixture.store.mark_delivery_send_started(
            delivery_id: row.fetch('delivery_id'), lease: Tamoz::Comms::Lease.new(owner: 'owner-stale-a',
                                                                                  fence: 11).wire, now: now + 61
          )
          result != :marked
        end
      end
    end
  end
end

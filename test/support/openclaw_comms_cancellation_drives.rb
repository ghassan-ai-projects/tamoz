# frozen_string_literal: true

require_relative 'openclaw_comms_drive_support'

module Tamoz
  module Evals
    module Benchmark
      # C8 and the cancellation pair shared with C5 and C6: a stop issued from
      # each surface against durable work, and the facts it leaves behind.
      class OpenclawCommsCancellationDrives < OpenclawCommsDriveSupport
        # One cancellation issued from EACH surface against durable work: the
        # telegram event goes through the real /cancel command path (so its
        # target must be telegram-admitted for the command guard to see it),
        # the CLI event through the durable redirect submission cmd_cancel
        # performs. Both must record the same payload contract and land the
        # same terminal reason on the shared thread.
        def drive_cancellation_pair(fixture, conversation, telegram_update_id:, cli_purpose:)
          thread = fixture.current_thread(conversation)
          fixture.submit([raw_update(telegram_update_id, 'long running task')])
          telegram_event, telegram_payload = telegram_cancellation(
            fixture, conversation, thread, telegram_update_id + 1
          )
          [telegram_event, cli_cancellation(fixture, thread, cli_purpose, telegram_payload)]
        end

        def drive_c8
          {
            'clean_stop' => drive_c8_clean_stop,
            'raced_restart' => drive_c8_raced_restart
          }
        end

        private

        def telegram_cancellation(fixture, conversation, thread, cancel_update)
          telegram_base = delivery_baseline(fixture)
          fixture.submit([raw_update(cancel_update, '/cancel')])
          telegram_cancel = Tamoz::Comms::Canonical.hexdigest(
            'tamoz.comms.command.v1', [@adapter.surface_id, cancel_update, 'cancel']
          )
          work_until_cancelled(fixture, thread, telegram_cancel, @adapter.cancel_reason)
          fixture.drain
          stamped = fixture.request_row(thread, telegram_cancel)
          raise 'telegram /cancel left no durable payload' unless stamped

          event = cancellation_event(
            fixture, thread, fixture.request_ids_for(conversation).last,
            payloads_match: stamped.payload == @adapter.cli_cancel_payload,
            terminal_delivered: terminal_delivered?(fixture, telegram_base)
          )
          [event, stamped.payload]
        end

        def cli_cancellation(fixture, thread, cli_purpose, telegram_payload)
          target = fixture.submit_cli_task(thread_id: thread, purpose: cli_purpose,
                                           task: 'another long task')
          cli_base = delivery_baseline(fixture)
          cli_cancel = fixture.submit_cli_cancel(thread_id: thread, purpose: "#{cli_purpose}_cancel")
          work_until_cancelled(fixture, thread, cli_cancel, @adapter.cancel_reason)
          fixture.drain
          cli_row = fixture.request_row(thread, cli_cancel)
          raise 'CLI /cancel left no durable payload' unless cli_row

          cancellation_event(
            fixture, thread, target,
            payloads_match: cli_row.payload == telegram_payload,
            terminal_delivered: terminal_delivered?(fixture, cli_base)
          )
        end

        # Drains until THIS cancel operation's durable request row reaches a
        # terminal status, then requires the shared thread view to name the
        # cancellation reason — a thread that was already cancelled earlier
        # must not satisfy a later cancel's observation.
        def work_until_cancelled(fixture, thread_id, cancel_request_id, reason, max_passes: 6)
          max_passes.times do
            break if cancel_completed?(fixture, thread_id, cancel_request_id)

            fixture.work
          end
          return if cancel_completed?(fixture, thread_id, cancel_request_id) &&
                    fixture.view(thread_id)&.terminal&.dig('reason') == reason

          raise "cancel #{cancel_request_id} was never observed as #{reason.inspect}"
        end

        def cancel_completed?(fixture, thread_id, cancel_request_id)
          fixture.request_row(thread_id, cancel_request_id)&.status&.to_s == 'completed'
        end

        def cancellation_event(fixture, thread, target_request_id, payloads_match:, terminal_delivered:)
          {
            'thread_id' => thread,
            'target_request_id' => target_request_id,
            'terminal_reason' => fixture.view(thread)&.terminal&.dig('reason'),
            'payloads_match' => payloads_match,
            'terminal_delivered' => terminal_delivered
          }
        end

        def c8_waiting_factory
          @adapter.model_factory(:c8_waiting)
        end

        def cancel_accepted?(fixture, update_id)
          control_reply_text(fixture, update_id, '/cancel').start_with?(@adapter.cancel_reply)
        end

        def drive_c8_clean_stop
          with_fixture(model_factory: c8_waiting_factory, approval_ask: parked_approval_ask) do |fixture|
            conversation = @adapter.conversation_a
            thread = fixture.thread_for(conversation)
            fixture.bind_thread(conversation)

            fixture.submit([raw_update(871, 'Fix note.txt to say fixed.')])
            fixture.work
            target = fixture.request_ids_for(conversation).last
            raise 'the approval-bearing turn was not admitted durably' unless target

            cancel_accepted = cancel_accepted?(fixture, 872)
            observed = fixture.store.mark_cancellation_observed(thread_id: thread, now: Time.now.utc)
            clean_stop_facts(fixture, conversation, target, cancel_accepted:, observed:)
          end
        end

        def clean_stop_facts(fixture, conversation, target, cancel_accepted:, observed:)
          reference = Tamoz::Comms::Lifecycle::RequestRef.for(target)
          snapshot = fixture.snapshot(conversations: [conversation])
          snapshot.merge(
            'driven_update_ids' => [871, 872],
            'approval_prompt_recorded' => snapshot['outbox'].any? { |row| row['kind'] == 'approval_request' },
            'cancel_command_accepted' => cancel_accepted,
            'observation_stamp_accepted' => observed == :observed,
            'cancellation_timelines' =>
              [cancellation_timeline(fixture, conversation, target, writer: 'store_seam')],
            'terminal_wordings' => [terminal_wording(fixture, 875, reference)]
          )
        end

        def drive_c8_raced_restart
          factory = @adapter.crashing_factory(:c8_raced_restart)
          with_fixture(model_factory: factory) do |fixture|
            conversation = @adapter.conversation_a
            fixture.submit([raw_update(881, 'Summarize both notes.')])
            work_through_crash(fixture)
            target = fixture.request_ids_for(conversation).last
            raise 'the crashed turn was not admitted durably' unless target

            cancel_accepted = cancel_accepted?(fixture, 882)
            requested_before = cancellation_stamp(fixture, target)
            restart_until_cancelled(fixture, conversation)
            fixture.drain
            raced_restart_facts(fixture, conversation, target, cancel_accepted, requested_before)
          end
        end

        def restart_until_cancelled(fixture, conversation)
          poll_fresh_workers(fixture, 6) { cancelled_thread?(fixture, conversation) }
          return if cancelled_thread?(fixture, conversation)

          raise 'the cancel redirect was never consumed after the restart boundary'
        end

        def raced_restart_facts(fixture, conversation, target, cancel_accepted, requested_before)
          timeline = cancellation_timeline(
            fixture, conversation, target, writer: 'engine',
                                           settle_at_ms: first_terminal_settle_ms(fixture)
          )
          reference = Tamoz::Comms::Lifecycle::RequestRef.for(target)
          fixture.snapshot(conversations: [conversation]).merge(
            'driven_update_ids' => [881, 882],
            'cancel_command_accepted' => cancel_accepted,
            'restart_boundary' => restart_boundary(fixture, target, requested_before),
            'cancellation_timelines' => [timeline],
            'terminal_wordings' => [terminal_wording(fixture, 885, reference)]
          )
        end

        def restart_boundary(fixture, target, requested_before)
          before = requested_before['requested_at_ms']
          {
            'requested_stamp_survived_restart' =>
              before == cancellation_stamp(fixture, target)['requested_at_ms'] && !before.nil?,
            'one_terminal_send_per_request' => terminal_send_count(fixture) == 2,
            'unique_effect_keys' => unique_effect_keys?(fixture)
          }
        end

        # One request's durable cancellation facts: the stamps read from the
        # request rows, the store's own terminal derivation keyed to the
        # recorded settle kind (answer/failed/stopped/blocked), and — when
        # the leg settled — the durable instant of its first terminal
        # delivery so the oracle can order settle against observation. Only
        # derived booleans cross into the artifact; raw milliseconds never do.
        def cancellation_timeline(fixture, conversation, request_id, writer:, settle_at_ms: nil)
          reference = Tamoz::Comms::Lifecycle::RequestRef.for(request_id)
          resolved = fixture.request_status(conversation, reference)
          document = resolved.is_a?(Hash) ? resolved.fetch('cancellation', {}) : {}
          stamps = cancellation_stamp(fixture, request_id)
          identity = {
            'request_id' => request_id,
            'reference' => reference,
            'writer' => writer,
            'settle_kind' => stamps['projection_state'],
            'settled' => settled?(stamps)
          }
          identity.merge(stamp_ordering(stamps, settle_at_ms))
                  .merge('state' => document['state'], 'terminal_word' => document['terminal'])
        end

        def settled?(stamps)
          settle_kind = stamps['projection_state']
          !settle_kind.nil? && settle_kind != 'admitted'
        end

        def stamp_ordering(stamps, settle_at_ms)
          requested = stamps['requested_at_ms']
          observed = stamps['observed_at_ms']
          {
            'requested_present' => !requested.nil?,
            'observed_present' => !observed.nil?,
            'requested_le_observed' => requested && observed ? requested <= observed : false,
            'settle_le_observed' =>
              settled?(stamps) && observed && settle_at_ms ? settle_at_ms <= observed : nil
          }
        end

        def cancellation_stamp(fixture, request_id)
          fixture.cancellation_stamp_rows.find { |row| row.fetch('request_id') == request_id } || {}
        end

        # The wording class of the REAL ref-addressed /status rendering,
        # reduced to booleans so no wall-clock age phrase enters the artifact.
        def terminal_wording(fixture, update_id, reference)
          text = control_reply_text(fixture, update_id, "/status #{reference}")
          {
            'reference' => reference,
            'claims_stopped' => text.match?(/\bstopped\b/i),
            'claims_completed_before_effect' => text.include?('finished before the cancel took effect'),
            'claims_failed_before_effect' => text.include?('failed before the cancel took effect'),
            'claims_blocked' => text.include?('blocked')
          }
        end

        def cancelled_thread?(fixture, conversation)
          fixture.view(fixture.thread_for(conversation))&.terminal&.dig('reason') ==
            @adapter.cancel_reason
        end

        def first_terminal_settle_ms(fixture)
          terminal = fixture.outbox.select { |candidate| OpenclawCommsOracles::TERMINAL_KINDS.include?(candidate['kind']) }
          terminal.min_by { |candidate| candidate.fetch('created_at_ms') }&.fetch('created_at_ms')
        end

        # Every terminal delivery, not just a completion: F25-COR-01 routes a
        # cancellation terminal to `stopped`, so counting only `answer` read a
        # correctly-visible cancellation as a missing terminal.
        def terminal_send_count(fixture)
          fixture.transport.sends.count do |send|
            OpenclawCommsOracles::TERMINAL_KINDS.include?(send[:kind])
          end
        end

        def unique_effect_keys?(fixture)
          keys = fixture.effect_census.map { |row| row[:effect_key] }
          keys.uniq == keys
        end
      end
    end
  end
end

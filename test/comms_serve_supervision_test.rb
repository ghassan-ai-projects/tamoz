# frozen_string_literal: true

require_relative 'test_helper'

# Supervision proof for `tamoz comms serve` (design §14): when a store fails
# mid-drain, run_gateway_loops must NAME the failure on stderr with its
# exception class, stop every sibling loop, and exit non-zero — never spin
# quietly beside a dead thread.
class CommsServeSupervisionTest < Minitest::Test
  class StorageExploded < StandardError
    def initialize(msg = 'the comms inbound index stopped accepting writes')
      super
    end
  end

  # Answers the drainer's two read seams: one clean pass, then explodes.
  class FailingStore
    def initialize = @passes = 0

    def reconcile_expired_deliveries(now:)
      @passes += 1
      raise StorageExploded if @passes > 1

      now
    end

    def outbox_rows(surface_id:, statuses:, limit:) = []
  end

  # Blocks in its loop until supervised `stop` ends it.
  class QuietGateway
    def initialize
      @stopped = false
    end

    def stopped? = @stopped

    def stop
      @stopped = true
    end

    def serve_loop(drain: true)
      sleep(0.01) until @stopped
      :stopped
    end
  end

  def test_a_storage_failure_stops_the_loops_names_the_class_and_exits_non_zero
    err = StringIO.new
    supervisor = Object.new.extend(Tamoz::Agent::CLICommsCommands)
    supervisor.instance_variable_set(:@err, err)
    gateway = QuietGateway.new
    drainer = Tamoz::Comms::DeliveryDrainer.new(
      store: FailingStore.new,
      transport: Object.new,
      descriptor: supervised_descriptor,
      owner: 'drainer:supervised',
      clock: -> { Time.utc(2026, 8, 10, 12, 0, 0) },
      sleeper: ->(_seconds) {}
    )

    status = Timeout.timeout(10) { supervisor.send(:run_gateway_loops, [gateway], [drainer]) }

    assert_equal 1, status, 'a storage failure exits non-zero'
    assert_includes err.string, 'StorageExploded', 'stderr names the exception class'
    assert_includes err.string, 'stopped accepting writes', 'stderr carries the failure detail'
    assert gateway.stopped?, 'the surviving sibling loop was asked to stop'
  end

  private

  def supervised_descriptor
    Tamoz::Comms::SurfaceDescriptor.build(
      surface_id: 'telegram-ops', revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: nil },
      identity: { expected_bot_id: 7_463_512_990 }, admission: { direct: 'disabled' },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'none', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )
  end
end

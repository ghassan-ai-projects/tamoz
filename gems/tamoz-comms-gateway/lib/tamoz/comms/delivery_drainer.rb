# frozen_string_literal: true

require 'tamoz/comms'
require 'json'

module Tamoz
  module Comms
    # Drains durable outbound rows independently from inbound polling. Claims,
    # pacing reservations, effect bindings, receipts, and ambiguous-send
    # handling all remain on the shared SQLite contract.
    class DeliveryDrainer
      CLAIM_TTL_S = 30.0
      # Telegram shows "typing" for about five seconds per signal.
      TYPING_EVERY_S = 4.0

      # The drainer's clock and its wait, injectable so a test never pays real time.
      Timing = Data.define(:clock, :sleeper) do
        def initialize(clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep seconds }) = super
      end

      def initialize(store:, transport:, descriptor:, owner:, **timing)
        timing = Timing.new(**timing)
        @store = store
        @transport = transport
        @descriptor = descriptor
        @owner = owner
        @clock = timing.clock
        @sleeper = timing.sleeper
        @lease = nil
        @stopping = false
        @typed_at = {}
      end

      def serve_loop(interval_s: 0.25)
        until @stopping
          outcome = drain_once(now: @clock.call)
          return outcome if outcome == :authentication_refused

          delay = outcome == :throttled ? @retry_after_s.to_f : interval_s
          @sleeper.call(delay) if delay.positive? && !@stopping
        end
        :stopped
      ensure
        stop
      end

      def stop
        @stopping = true
      end

      def drain_once(now: @clock.call)
        @store.reconcile_expired_deliveries(now:)
        rows = @store.outbox_rows(surface_id:, statuses: %w[pending], limit: @descriptor.transport.fetch(:batch))
        rows.each do |row|
          next unless claim(row, now:) == :claimed

          return :authentication_refused if send_row(row, now:) == :authentication_refused
        end
        pulse_typing(now)
        :drained
      rescue Comms::ThrottledError => e
        @retry_after_s = e.retry_after
        :throttled
      end

      private

      # A lost pulse costs nothing: the next pass sends another.
      def pulse_typing(now)
        working = @store.working_conversations(surface_id:, now:)
        @typed_at.select! { |conversation_id, _| working.include?(conversation_id) }
        working.each do |conversation_id|
          next if @typed_at[conversation_id] && now - @typed_at[conversation_id] < TYPING_EVERY_S

          @typed_at[conversation_id] = now
          @transport.signal(:typing, conversation_id:)
        end
      rescue StandardError
        nil
      end

      def claim(row, now:)
        @lease = Comms::Lease.new(owner: @owner, fence: Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond))
        @store.claim_delivery(delivery_id: row.fetch('delivery_id'), lease: @lease.wire,
                              claim_expires_at: now + CLAIM_TTL_S, now:)
      end

      # A lost fence bars the external send absolutely: a stale owner takes no
      # external action and records nothing on a row it no longer holds.
      def send_row(row, now:)
        scheduled_at = now + pace(row, now)
        delivery_id = row.fetch('delivery_id')
        @store.bind_journal_effect(delivery_id:, effect_key: effect_key(delivery_id),
                                   execution_id: "comms:#{delivery_id}", now: scheduled_at)
        return nil unless @store.mark_delivery_send_started(delivery_id:, lease: @lease.wire,
                                                            now: scheduled_at) == :marked

        deliver_and_record(row, scheduled_at)
      rescue Comms::ThrottledError => e
        defer(row, e.retry_after, scheduled_at, now)
        raise
      end

      def pace(row, now)
        limits = @descriptor.limits
        wait = @store.reserve_delivery_slot(
          surface_id:, conversation_id: row.fetch('conversation_id'), now:,
          per_chat_messages_per_s: limits.fetch(:per_chat_messages_per_s),
          global_messages_per_s: limits.fetch(:global_messages_per_s)
        )
        @sleeper.call(wait) if wait.positive?
        wait
      end

      def deliver_and_record(row, now)
        outcome = send_delivery(row)
        marked = mark(row, outcome.fetch(:status), outcome[:receipt], now)
        if marked == :marked && outcome.fetch(:status) == 'succeeded'
          activate_after_receipt(row, receipt: outcome[:receipt],
                                      now:)
        end
        nil
      rescue Comms::AuthenticationError
        mark(row, 'failed', { 'reason_code' => 'authentication_refused' }, now)
        :authentication_refused
      end

      def mark(row, status, receipt, now)
        @store.mark_delivery(delivery_id: row.fetch('delivery_id'), lease: @lease.wire, status:, receipt:, now:)
      end

      def defer(row, retry_after, scheduled_at, now)
        @store.defer_delivery(surface_id:, conversation_id: row.fetch('conversation_id'),
                              not_before: scheduled_at + retry_after, now: scheduled_at)
        @store.release_delivery_claim(delivery_id: row.fetch('delivery_id'), lease: @lease.wire, now:)
      end

      # The receipt comes from the send outcome directly — the outbox row is
      # the pre-send projection and cannot carry it. The prompt's originating
      # message receipt is what the callback comparison binds to (§7.1).
      def activate_after_receipt(row, receipt:, now:)
        return unless row.fetch('kind') == 'approval_request' && row['markup']

        reference = JSON.parse(row.fetch('markup')).fetch('reference')
        digest = Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, reference)
        @store.activate_prompt(reference_digest: digest, now:,
                               receipt: receipt && receipt.fetch('message_id').to_s)
      end

      def send_delivery(row)
        wire = row.merge('journaled' => row.fetch('journaled') == 1)
        delivery = Comms::Delivery.from_wire(wire)
        receipt = @transport.deliver(delivery)
        { status: 'succeeded', receipt: }
      rescue Comms::AmbiguousDeliveryError
        # An abandoned response may have transmitted the request — the same
        # honest ambiguity as a timeout (errors.rb's stated mapping).
        { status: 'unknown', receipt: nil }
      end

      def effect_key(delivery_id)
        "sha256:#{Comms::Canonical.hexdigest('tamoz.comms.delivery.effect', delivery_id)}"
      end

      def surface_id = @descriptor.surface_id
    end
  end
end

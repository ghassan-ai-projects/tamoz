# frozen_string_literal: true

require 'json'
require 'tamoz/comms'

module Tamoz
  module Agent
    # Drains durable outbound rows independently from inbound polling. Claims,
    # pacing reservations, effect bindings, receipts, and ambiguous-send
    # handling all remain on the shared SQLite contract.
    # rubocop:disable Metrics/ParameterLists, Metrics/AbcSize, Metrics/MethodLength, Naming/PredicateMethod
    class DeliveryDrainer
      CLAIM_TTL_S = 30.0

      def initialize(store:, transport:, descriptor:, owner:, batch_size: 50,
                     clock: -> { Time.now.utc }, sleeper: ->(seconds) { sleep seconds })
        @store = store
        @transport = transport
        @descriptor = descriptor
        @owner = owner
        @batch_size = batch_size
        @clock = clock
        @sleeper = sleeper
        @fence = 0
        @stopping = false
      end

      def serve_loop(interval_s: 0.25)
        until @stopping
          outcome = drain_once(now: @clock.call)
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
        rows = @store.outbox_rows(surface_id:, statuses: %w[pending], limit: @batch_size)
        rows.each do |row|
          next unless claim(row, now:)

          send_row(row, now:)
        end
        :drained
      rescue Comms::ThrottledError => e
        @retry_after_s = e.retry_after
        :throttled
      end

      private

      def claim(row, now:)
        @store.claim_delivery(
          delivery_id: row.fetch('delivery_id'),
          owner: @owner,
          fence: next_fence,
          claim_expires_at: now + CLAIM_TTL_S,
          now:
        ) == :claimed
      end

      def send_row(row, now:)
        wait = @store.reserve_delivery_slot(
          surface_id:,
          conversation_id: row.fetch('conversation_id'),
          per_chat_messages_per_s: @descriptor.limits.fetch(:per_chat_messages_per_s),
          global_messages_per_s: @descriptor.limits.fetch(:global_messages_per_s),
          now:
        )
        scheduled_at = now + wait
        @sleeper.call(wait) if wait.positive?
        @store.bind_journal_effect(
          delivery_id: row.fetch('delivery_id'),
          effect_key: effect_key(row.fetch('delivery_id')),
          execution_id: "comms:#{row.fetch('delivery_id')}",
          now: scheduled_at
        )
        @store.mark_delivery_send_started(
          delivery_id: row.fetch('delivery_id'), owner: @owner, fence: @fence, now: scheduled_at
        )
        outcome = send_delivery(row)
        @store.mark_delivery(
          delivery_id: row.fetch('delivery_id'),
          status: outcome.fetch(:status),
          receipt: outcome[:receipt],
          now: scheduled_at
        )
        activate_after_receipt(row, now: scheduled_at) if outcome.fetch(:status) == 'succeeded'
      rescue Comms::ThrottledError => e
        @store.defer_delivery(
          surface_id:,
          conversation_id: row.fetch('conversation_id'),
          not_before: scheduled_at + e.retry_after,
          now: scheduled_at
        )
        @store.release_delivery_claim(
          delivery_id: row.fetch('delivery_id'), owner: @owner, fence: @fence, now:
        )
        raise
      end

      def activate_after_receipt(row, now:)
        return unless row.fetch('kind') == 'approval_request' && row['markup']

        reference = JSON.parse(row.fetch('markup')).fetch('reference')
        digest = Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, reference)
        @store.activate_prompt(reference_digest: digest, now:)
      end

      def send_delivery(row)
        wire = row.merge('journaled' => row.fetch('journaled') == 1)
        delivery = Comms::Delivery.from_wire(wire)
        receipt = @transport.deliver(delivery)
        { status: 'succeeded', receipt: }
      rescue Comms::AmbiguousDeliveryError
        { status: 'unknown', receipt: nil }
      end

      def effect_key(delivery_id)
        "sha256:#{Comms::Canonical.hexdigest('tamoz.comms.delivery.effect', delivery_id)}"
      end

      def next_fence
        @fence = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
      end

      def surface_id = @descriptor.surface_id
    end
    # rubocop:enable Metrics/ParameterLists, Metrics/AbcSize, Metrics/MethodLength, Naming/PredicateMethod
  end
end

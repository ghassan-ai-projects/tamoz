# frozen_string_literal: true

require 'time'
require 'json'

require 'tamoz/comms'

module Tamoz
  module Agent
    # The channel gateway (design §5/§10, ADR-042): the only long-running
    # process that talks to the transport. It holds the credential, admits and
    # normalizes inbound updates, records the durable disposition, drains the
    # delivery outbox, and NEVER constructs a Session, loads a model
    # credential, opens a toolbox, or reads workspace files.
    #
    # One fenced poller per bot; the durable next_offset is persisted only
    # after the whole returned prefix has a durable disposition. A crash
    # before the next poll redelivers; a crash after it cannot lose work.
    #
    # The loop is `serve_once` — the CLI drives it once or in a loop.
    # :reek:TooManyStatements, :reek:LongParameterList, :reek:DataClump
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy, :reek:NilCheck
    # :reek:TooManyInstanceVariables, :reek:TooManyMethods -- one loop owns
    #   every seam; splitting it would scatter the ordering invariant.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
    class CommsGateway
      THREAD_PROFILE_NAMESPACE = %w[tamoz worker thread_profile].freeze
      POLLER_TTL_S = 60.0
      CLAIM_TTL_S = 30.0

      def initialize(adapter:, checkpoints:, transport:, descriptor:, poller_owner:, batch_size: 50)
        @adapter = adapter
        @store = adapter.bind_comms_store(checkpoints)
        @transport = transport
        @descriptor = descriptor
        @poller_owner = poller_owner
        @batch_size = batch_size
        @fence = 0
      end

      # Acquire the poller lease and enter the serve loop (the CLI drives
      # this; Ctrl-C or a fatal transport error exits via the ensure).
      def serve_loop(now_provider: -> { Time.now.utc }, interval_s: 1.0)
        return :poller_busy unless start(now: now_provider.call)

        loop do
          serve_once(now: now_provider.call)
          sleep interval_s
        end
      ensure
        stop
      end

      # The fenced poller lease: :started, or :poller_busy when another
      # gateway holds a live lease for this bot.
      def start(now: Time.now.utc)
        acquired = @store.acquire_poller_lease(
          surface_id:, bot_id:, owner: @poller_owner, fence: next_fence,
          ttl_s: POLLER_TTL_S, now:
        )
        acquired == :acquired ? :started : :poller_busy
      end

      def stop
        release_poller
      end

      # One poll + admit + offset + drain pass. The poller lease is held
      # across passes (one fenced poller per bot); only serve_loop's ensure
      # releases it, and a crash leaves it to expire.
      def serve_once(now: Time.now.utc)
        next_offset = @store.poll_offset(bot_id:)
        batch = @transport.poll(next_offset:, limit: @batch_size, timeout_s: poll_timeout_s)

        batch[:updates].each { |envelope| admit(envelope, now:) }
        @store.persist_next_offset(surface_id:, bot_id:, next_offset: batch[:next_offset], now:)
        drain_outbox(now:)
        :served
      rescue Comms::ThrottledError
        :throttled
      rescue Comms::AuthenticationError
        :auth_failed
      end

      # Resolves one normalized update to its durable disposition (design §5):
      # request (enqueued turn), control reply, ignored, rejected, or a
      # callback decision (v1 deny-only, handled by the prompt machinery).
      def admit(envelope, now:)
        decision = Comms::Admission.decide(
          envelope, surface: @descriptor,
                    binding: latest_binding(envelope),
                    conversation: @store.conversation(surface_id:, conversation_id: envelope.fetch('conversation_id')),
                    bot_username: bot_username
        )

        case decision.disposition
        when :request
          admit_request(envelope, decision, now:)
        when :decision
          resolve_callback(envelope, now:)
        when :rejected
          @store.disposition_only(envelope, surface_id:, bot_id:, disposition: 'rejected',
                                            reason: decision.reason.to_s, now:)
          append_control(decision.control_reply, envelope, now:) if decision.control_reply
        when :control
          @store.disposition_only(envelope, surface_id:, bot_id:, disposition: 'ignored', reason: decision.reason.to_s,
                                            now:)
          append_control(decision.control_reply, envelope, now:) if decision.control_reply
        else
          @store.disposition_only(envelope, surface_id:, bot_id:, disposition: 'ignored', reason: decision.reason.to_s,
                                            now:)
        end
      end

      private

      # v1 deny-only (ADR-043): a callback press carries the plaintext
      # reference; its domain-separated digest resolves exactly one ACTIVE
      # prompt, and consumption inserts a deny decision for the worker in the
      # SAME transaction. A replayed reference, an expiry, or a swapped
      # binding never resolves (invariant 58).
      def resolve_callback(envelope, now:)
        reference = envelope.fetch('text').to_s
        digest = Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, reference)
        prompt = @store.prompt(reference_digest: digest)

        unless prompt && prompt.fetch('status') == 'active'
          @store.disposition_only(envelope, surface_id:, bot_id:,
                                            disposition: 'ignored', reason: 'unknown_reference', now:)
          return
        end

        decision = Comms::DecisionRecord.build(
          thread_id: prompt.fetch('thread_id'), occurrence_id: prompt.fetch('occurrence_id'),
          interrupts: [], interrupt_digest: prompt.fetch('interrupt_digest'),
          direction: :deny, actor_kind: 'telegram_user',
          actor_id: envelope.fetch('correspondent_id'), source: 'telegram',
          decided_at: now, ttl_s: @descriptor.approvals.fetch(:prompt_ttl_s)
        )
        outcome = @store.consume_prompt(reference_digest: digest, decision_wire: decision.wire, now:)
        @store.disposition_only(envelope, surface_id:, bot_id:,
                                          disposition: 'decision', reason: outcome.to_s, now:)
      end

      # Authority binding precedes work (design §5): the deterministic thread
      # is created and the surface's profile bound write-once BEFORE the first
      # request enqueues. A crash between leaves an inert bound thread; the
      # reverse order is forbidden.
      def admit_request(envelope, decision, now:)
        thread = decision.thread_id
        conversation = @store.conversation(surface_id:, conversation_id: envelope.fetch('conversation_id'))
        if conversation.nil?
          bind_thread_profile(thread)
          @store.bind_conversation(
            Comms::Conversation.new(
              surface_id:, surface_revision: envelope.fetch('surface_revision'),
              conversation_id: envelope.fetch('conversation_id'), thread_id: thread,
              profile_id: @descriptor.profile_id, bound_at: now
            ).wire,
            now:
          )
        end
        @store.admit_and_enqueue(
          envelope, surface_id:, bot_id:, thread:, profile_id: @descriptor.profile_id,
                    reservation: 1, now:
        )
      end

      def bind_thread_profile(thread)
        @adapter.store.put(
          THREAD_PROFILE_NAMESPACE, thread,
          { 'profile_id' => @descriptor.profile_id, 'recorded_at' => Time.now.utc.iso8601(6) },
          if_version: nil
        )
      rescue StoreConflictError
        nil # write-once: an existing binding wins
      end

      def append_control(reply_text, envelope, now:)
        delivery = Comms::Delivery.build(
          conversation_id: envelope.fetch('conversation_id'), kind: 'control',
          text: reply_text, part_index: 0, part_count: 1, journaled: false,
          render_version: Comms::Rendering::RENDER_VERSION,
          content_digest: Comms::Rendering.content_digest(reply_text)
        )
        @store.append_delivery(delivery.wire, surface_id:, capacity: control_capacity, now:)
      end

      def drain_outbox(now:)
        rows = @store.outbox_rows(surface_id:, statuses: %w[pending], limit: @batch_size)
        rows.each do |row|
          claimed = @store.claim_delivery(
            delivery_id: row.fetch('delivery_id'), owner: @poller_owner,
            fence: next_fence, claim_expires_at: now + CLAIM_TTL_S, now:
          )
          next unless claimed == :claimed

          @store.bind_journal_effect(
            delivery_id: row.fetch('delivery_id'),
            effect_key: "sha256:#{Comms::Canonical.hexdigest('tamoz.comms.delivery.effect', row.fetch('delivery_id'))}",
            execution_id: "comms:#{row.fetch('delivery_id')}", now:
          )
          outcome = send_delivery(row)
          @store.mark_delivery(
            delivery_id: row.fetch('delivery_id'), status: outcome[:status],
            receipt: outcome[:receipt], now:
          )
          activate_after_receipt(row, now:) if outcome[:status] == 'succeeded'
        end
      end

      # ADR-043: an approval prompt activates only after its send receipt is
      # durable. The markup carried the plaintext reference exactly once.
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

      def release_poller
        @store.release_poller_lease(bot_id:, owner: @poller_owner, fence: @fence)
      end

      def latest_binding(envelope)
        @store.binding(correspondent_id: envelope.fetch('correspondent_id'), surface_id:)
      end

      def next_fence
        @fence = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
      end

      def surface_id = @descriptor.surface_id

      def bot_id = @descriptor.identity.fetch(:expected_bot_id)

      def bot_username = @descriptor.identity[:bot_username]

      def poll_timeout_s = @descriptor.transport.fetch(:poll_timeout_s)

      def control_capacity = @descriptor.limits.fetch(:control_capacity)
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists

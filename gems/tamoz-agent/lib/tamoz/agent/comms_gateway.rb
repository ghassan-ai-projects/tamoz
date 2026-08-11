# frozen_string_literal: true

require 'time'
require 'json'

require 'tamoz/comms'
require_relative 'delivery_drainer'

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
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Performance/CollectionLiteralInLoop, Naming/PredicateMethod
    class CommsGateway
      THREAD_PROFILE_NAMESPACE = %w[tamoz worker thread_profile].freeze
      POLLER_TTL_S = 60.0
      CLAIM_TTL_S = 30.0
      TRANSIENT_BACKOFF_BASE_S = 1.0
      TRANSIENT_BACKOFF_MAX_S = 30.0

      def initialize(adapter:, checkpoints:, transport:, descriptor:, poller_owner:, batch_size: 50, drainer: nil)
        @adapter = adapter
        @checkpoints = checkpoints
        @store = adapter.bind_comms_store(checkpoints)
        @transport = transport
        @descriptor = descriptor
        @poller_owner = poller_owner
        @batch_size = batch_size
        @fence = 0
        @stopping = false
        @drainer = drainer || DeliveryDrainer.new(
          store: @store,
          transport:,
          descriptor:,
          owner: "#{poller_owner}:drainer",
          batch_size:
        )
        @owns_drainer = drainer.nil?
      end

      # Acquire the poller lease and enter the serve loop (the CLI drives
      # this). A fatal transport error exits via the ensure; INT/TERM ask
      # through `stop`, and the loop checks that between passes.
      #
      # Shutdown takes at most one long-poll timeout: a pass already blocked in
      # getUpdates finishes first. Releasing the lease WITHOUT ending the loop
      # would be worse than not stopping at all — the gateway would keep
      # reading a stream it no longer owns, which is the 409 conflict.
      def serve_loop(now_provider: -> { Time.now.utc }, interval_s: 1.0, drain: true,
                     sleeper: ->(seconds) { sleep seconds })
        return :poller_busy unless start(now: now_provider.call)

        outcome = :stopped
        until @stopping
          outcome = serve_once(now: now_provider.call, drain:)
          break if %i[auth_failed poller_lost].include?(outcome)

          delay = loop_delay(outcome, interval_s)
          sleeper.call(delay) if delay.positive? && !@stopping
        end
        outcome == :stopped || @stopping ? :stopped : outcome
      rescue Comms::PollerConflictError
        :poller_conflict
      ensure
        stop
      end

      # The fenced poller lease: :started, or :poller_busy when another
      # gateway holds a live lease for this bot.
      def start(now: Time.now.utc)
        acquired = @store.acquire_poller_lease(
          surface_id:, bot_id:, owner: @poller_owner, fence: next_fence,
          ttl_s: poller_ttl_s, now:
        )
        acquired == :acquired ? :started : :poller_busy
      end

      # Asked from a signal handler, so it does the two things a stop means:
      # end the loop, and give up the lease. Ending the loop is the half that
      # a released lease alone does not buy.
      def stop
        @stopping = true
        @drainer.stop if @owns_drainer
        release_poller
      end

      # One poll + admit + offset + drain pass. The poller lease is held
      # across passes (one fenced poller per bot); only serve_loop's ensure
      # releases it, and a crash leaves it to expire.
      def serve_once(now: Time.now.utc, drain: true)
        return :poller_lost unless renew_poller(now)

        next_offset = @store.poll_offset(bot_id:)
        batch = poll_batch(next_offset)
        return :transient unless batch

        batch[:updates].each { |envelope| admit(envelope, now:) }
        @store.persist_next_offset(surface_id:, bot_id:, next_offset: batch[:next_offset], now:)
        drain_outbox(now:) if drain
        :served
      rescue Comms::PollerConflictError
        raise
      rescue Comms::ThrottledError => e
        @retry_after_s = e.retry_after
        :throttled
      rescue Comms::AuthenticationError
        :auth_failed
      rescue Comms::TransientTransportError, Comms::CommsError
        :transient
      end

      # The idempotent read, and ONLY the read. A long poll that times out or
      # drops its connection observed nothing and persisted nothing, so the
      # next pass repeats it from the same durable offset — a transient blip
      # must not end a gateway that is supposed to stay open for days. The
      # rescue is deliberately this narrow: a transient failure while admitting
      # an update or draining the outbox touches durable state and must
      # surface, not be swallowed here.
      # @return [Hash, nil] the batch, or nil when the read did not complete.
      def poll_batch(next_offset)
        @transport.poll(next_offset:, limit: @batch_size, timeout_s: poll_timeout_s)
      rescue Comms::TransientTransportError
        nil
      end

      def renew_poller(now)
        return true if @fence.zero?

        @store.acquire_poller_lease(
          surface_id:, bot_id:, owner: @poller_owner, fence: @fence,
          ttl_s: poller_ttl_s, now:
        ) == :acquired
      end

      def loop_delay(outcome, interval_s)
        case outcome
        when :transient
          @transient_failures = @transient_failures.to_i + 1
          [TRANSIENT_BACKOFF_BASE_S * (2**(@transient_failures - 1)), TRANSIENT_BACKOFF_MAX_S].min
        when :throttled
          @transient_failures = 0
          [@retry_after_s.to_f, interval_s].max
        else
          @transient_failures = 0
          @retry_after_s = nil
          interval_s
        end
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
          if decision.command_intent
            handle_command(envelope, decision, now:)
          elsif decision.control_reply
            append_control(decision.control_reply, envelope, now:)
          end
        else
          @store.disposition_only(envelope, surface_id:, bot_id:, disposition: 'ignored', reason: decision.reason.to_s,
                                            now:)
        end
      end

      private

      # v2 approve+deny (ADR-043 v1 was deny-only): the callback text encodes
      # `action:reference`; its domain-separated digest resolves exactly one
      # ACTIVE prompt, and consumption inserts an approve/deny decision for the
      # worker in the SAME transaction. A bare reference (v1 wire) resolves as
      # deny. A replayed reference, an expiry, or a swapped binding never
      # resolves (invariant 58).
      def resolve_callback(envelope, now:)
        action, reference = split_callback(envelope.fetch('text').to_s)
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
          direction: action, actor_kind: 'telegram_user',
          actor_id: envelope.fetch('correspondent_id'), source: 'telegram',
          decided_at: now, ttl_s: @descriptor.approvals.fetch(:prompt_ttl_s)
        )
        outcome = @store.consume_prompt(reference_digest: digest, decision_wire: decision.wire, now:)
        @store.disposition_only(envelope, surface_id:, bot_id:,
                                          disposition: 'decision', reason: outcome.to_s, now:)
      end

      # `approve:<reference>` / `deny:<reference>` → [action, reference]; a
      # bare reference (v1 wire) means deny.
      def split_callback(text)
        if text.start_with?('approve:', 'deny:')
          action, reference = text.split(':', 2)
          [action, reference.to_s]
        else
          [:deny, text]
        end
      end

      # Authority binding precedes work (design §5): the deterministic thread
      # is created and the surface's profile bound write-once BEFORE the first
      # request enqueues. A crash between leaves an inert bound thread; the
      # reverse order is forbidden. An allowlisted first contact also gets its
      # correspondent binding (bound_by records the operator config, so
      # `comms list` and `pair revoke` can see and revoke it).
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
          bind_allowlisted_correspondent(envelope, now:)
        end
        history = @store.conversation_history(
          surface_id:, conversation_id: envelope.fetch('conversation_id')
        )
        outcome = @store.admit_and_enqueue(
          envelope, surface_id:, bot_id:, thread:, profile_id: @descriptor.profile_id,
                    reservation: reservation_slots, capacity: outbox_capacity, now:,
                    history:
        )
        if %i[enqueued duplicate].include?(outcome)
          append_control(accepted_reply(envelope), envelope, now:, kind: 'accepted')
          return
        end

        # Saturated (invariant 57): durable refusal, no turn, and a bounded
        # busy reply that itself may be coalesced.
        @store.disposition_only(envelope, surface_id:, bot_id:,
                                          disposition: 'rejected', reason: 'capacity_refused', now:)
        append_control('The channel is at capacity; try again later.', envelope, now:)
      end

      # The one synchronous acknowledgement. When earlier admitted work is
      # still open the message QUEUES behind it (the worker settles one
      # occurrence before claiming the next), and the reply must say so —
      # "Accepted" alone reads as "starting now".
      def accepted_reply(envelope)
        status = @store.conversation_status(
          surface_id:, conversation_id: envelope.fetch('conversation_id')
        )
        return 'Accepted. I will report committed progress.' unless status

        if status.fetch('open_requests') > 1
          'Queued behind earlier work; I will report committed progress when it runs.'
        else
          'Accepted. I will report committed progress.'
        end
      end

      def handle_command(envelope, decision, now:)
        case decision.command_intent.name
        when 'help'
          append_control('Commands: /help, /status, /cancel. Commands never become task text.', envelope, now:)
        when 'status'
          append_control(status_text(envelope), envelope, now:)
        when 'cancel'
          append_control(cancel_request(envelope), envelope, now:)
        else
          append_control('That command is not available on this channel.', envelope, now:)
        end
      end

      def status_text(envelope)
        status = @store.conversation_status(surface_id:, conversation_id: envelope.fetch('conversation_id'))
        return 'No work is admitted for this conversation.' unless status

        "Work status: #{status.fetch('state')}; open requests: #{status.fetch('open_requests')}."
      end

      def cancel_request(envelope)
        route = @store.conversation(surface_id:, conversation_id: envelope.fetch('conversation_id'))
        return 'No active work was found.' unless route

        request_id = Comms::Canonical.hexdigest(
          'tamoz.comms.command.v1',
          [surface_id, envelope.fetch('update_id'), 'cancel']
        )
        @checkpoints.enqueue_request(
          thread_id: route.fetch('thread_id'),
          request_id:,
          operation: :redirect,
          payload: { 'task' => { 'cancel' => true, 'reason' => 'cancelled_by_user' } },
          delivery: :redirect
        )
        'Cancellation requested.'
      rescue Tamoz::CheckpointConflictError
        'Cancellation could not be queued; no active checkpoint is available.'
      end

      def bind_thread_profile(thread)
        @adapter.store.put(
          THREAD_PROFILE_NAMESPACE, thread,
          { 'profile' => @descriptor.profile_id, 'recorded_at' => Time.now.utc.iso8601(6) },
          if_version: nil
        )
      rescue StoreConflictError
        nil # write-once: an existing binding wins
      end

      # Write-once: a pairing-approved binding (bound_by an operator) is never
      # overwritten by the allowlist record.
      def bind_allowlisted_correspondent(envelope, now:)
        @store.bind_correspondent(
          Comms::Binding.new(
            surface_id:, surface_revision: envelope.fetch('surface_revision'),
            correspondent_id: envelope.fetch('correspondent_id'),
            conversation_id: envelope.fetch('conversation_id'),
            bound_at: now, bound_by: 'gateway:allowlist'
          ).wire,
          now:
        )
      end

      def append_control(reply_text, envelope, now:, kind: 'control')
        delivery = Comms::Delivery.build(
          conversation_id: envelope.fetch('conversation_id'), reply_to: envelope.fetch('update_id'), kind:,
          text: reply_text, part_index: 0, part_count: 1, journaled: false,
          render_version: Comms::Rendering::RENDER_VERSION,
          content_digest: Comms::Rendering.content_digest(reply_text)
        )
        @store.append_delivery(delivery.wire, surface_id:, capacity: control_capacity, now:)
      end

      def drain_outbox(now:)
        @drainer.drain_once(now:)
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

      def poller_ttl_s = [POLLER_TTL_S, poll_timeout_s.to_f + 30.0].max

      def control_capacity = @descriptor.limits.fetch(:control_capacity)

      def outbox_capacity = @descriptor.limits.fetch(:outbox_capacity)

      # Terminal slots reserved at admission (design §12, invariant 57): the
      # rendered parts plus the denial prompts a turn may need.
      def reservation_slots
        @descriptor.rendering.fetch(:max_parts) +
          @descriptor.limits.fetch(:max_denial_prompts_per_request)
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists, Metrics/ClassLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Performance/CollectionLiteralInLoop, Naming/PredicateMethod

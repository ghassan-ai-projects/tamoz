# frozen_string_literal: true

require 'tamoz/comms'
require 'digest'
require 'time'
require 'json'

require_relative 'delivery_drainer'
require_relative 'gateway_admission'
require_relative 'gateway_admission_binding'
require_relative 'gateway_answers'
require_relative 'gateway_attachments'
require_relative 'gateway_callbacks'
require_relative 'gateway_clarifications'
require_relative 'gateway_commands'
require_relative 'gateway_conversation_commands'
require_relative 'gateway_context_controls'
require_relative 'gateway_pairing'
require_relative 'gateway_status'
require_relative 'gateway_delivery'
require_relative 'gateway_replies'

module Tamoz
  module Comms
    # The channel gateway (design §5/§10, ADR-042): the only long-running
    # process that talks to the transport. It holds the credential, admits and
    # normalizes inbound updates, records durable disposition, drains the
    # delivery outbox, and never constructs a Session or loads model state.
    #
    # The public lifecycle is intentionally kept here:
    # startup -> authenticated passes -> delay -> stop and cleanup.
    # A pass is renew -> poll -> admit -> persist -> drain.
    class Gateway
      THREAD_PROFILE_NAMESPACE = %w[tamoz worker thread_profile].freeze
      POLLER_TTL_S = 60.0
      CLAIM_TTL_S = 30.0
      TRANSIENT_BACKOFF_BASE_S = 1.0
      TRANSIENT_BACKOFF_MAX_S = 30.0
      STOP_OUTCOMES = %i[auth_failed poller_lost].freeze
      CONTEXT_CONTROL_COMMANDS = %w[reset compact usage context think verbose].freeze
      STATELESS_THREAD_MESSAGE = 'has no checkpoint'
      TASK_WORD_PRETRANSLATIONS = {
        'not_started' => 'admitted',
        'claimed' => 'running',
        'redirecting' => 'waiting'
      }.freeze
      REFERENCE_PATTERN = /\Ar[0-9a-f]{#{Lifecycle::REQUEST_REF_WIDTH}}\z/
      FULL_REFERENCE_PATTERN = /\Ar?[0-9a-f]{64}\z/i

      include Admission
      include AdmissionBinding
      include Answers
      include Attachments
      include Callbacks
      include Clarifications
      include Commands
      include ConversationCommands
      include ContextControls
      include Pairing
      include StatusProjection
      include Delivery

      # What a gateway may be handed beyond its surface: a drainer serving in its own thread (else it
      # drains with one of its own), the context controls its commands read, and the attachment spool.
      Extras = Data.define(:drainer, :controls, :attachments) do
        def initialize(drainer: nil, controls: nil, attachments: nil) = super
      end

      def initialize(checkpoints:, transport:, descriptor:, poller_owner:, **extras)
        extras = Extras.new(**extras)
        @adapter = checkpoints.adapter
        @checkpoints = checkpoints
        @store = @adapter.bind_comms_store(checkpoints)
        @transport = transport
        @descriptor = descriptor
        @poller_owner = poller_owner
        @controls = extras.controls
        @attachments = extras.attachments
        @lease = nil
        @stopping = false
        # The store keeps only challenge digests; plaintext codes live here so
        # a repeat contact can name the same code again.
        @issued_pairing_codes = {}
        @drainer = extras.drainer || DeliveryDrainer.new(store: @store, transport:, descriptor:,
                                                         owner: "#{poller_owner}:drainer")
        @owns_drainer = extras.drainer.nil?
      end

      # Acquire the poller lease and enter the serve loop. `on_started` runs once the lease is held, before the
      # first pass. A fatal transport error exits through ensure; INT/TERM ask through stop.
      def serve_loop(now_provider: -> { Time.now.utc }, interval_s: 1.0, drain: true,
                     sleeper: ->(seconds) { sleep seconds }, on_started: nil)
        start_outcome = start(now: now_provider.call)
        return start_outcome unless start_outcome == :started

        on_started&.call

        outcome = :stopped
        until @stopping
          outcome = serve_once(now: now_provider.call, drain:)
          break if terminal_outcome?(outcome)

          sleep_after_pass(outcome, interval_s, sleeper)
        end
        outcome == :stopped || @stopping ? :stopped : outcome
      rescue Comms::PollerConflictError
        :poller_conflict
      ensure
        stop
      end

      # Acquire the fenced poller lease, then authenticate before polling.
      def start(now: Time.now.utc)
        @lease = Comms::Lease.new(owner: @poller_owner,
                                  fence: Process.clock_gettime(
                                    Process::CLOCK_MONOTONIC, :microsecond
                                  ))
        acquired = @store.acquire_poller_lease(surface_id:, stream_id:, lease: @lease.wire, ttl_s: poller_ttl_s, now:)
        return :poller_busy unless acquired == :acquired

        authenticate_transport
        :started
      rescue Comms::AuthenticationError
        release_poller
        :auth_failed
      end

      # Stop the loop, stop an owned drainer, and release this poller's lease.
      def stop
        @stopping = true
        @drainer.stop if @owns_drainer
        release_poller
      end

      # One pass: renew -> poll -> admit -> persist -> drain.
      def serve_once(now: Time.now.utc, drain: true)
        return :poller_lost unless renew_poller(now)

        next_offset = @store.poll_offset(stream_id:)
        batch = poll_batch(next_offset)
        return :transient unless batch

        batch[:updates].each { |envelope| admit(envelope, now:) }
        sweep_handoffs
        @store.persist_next_offset(surface_id:, stream_id:, next_offset: batch[:next_offset], now:)
        return :auth_failed if drain && drain_outbox(now:) == :authentication_refused

        :served
      # A lost lease is never transient: it must escape the CommsError catch-all.
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

      # The transport read is idempotent; a transient read observes and persists
      # nothing, so the next pass retries from the same durable offset.
      def poll_batch(next_offset)
        @transport.poll(next_offset:, limit: @descriptor.transport.fetch(:batch), timeout_s: poll_timeout_s)
      rescue Comms::TransientTransportError
        nil
      end

      # The public name predates the refactor and describes its lease action,
      # not a side-effect-free predicate.
      # rubocop:disable Naming/PredicateMethod
      def renew_poller(now)
        return true unless @lease

        @store.acquire_poller_lease(surface_id:, stream_id:, lease: @lease.wire, ttl_s: poller_ttl_s, now:) == :acquired
      end
      # rubocop:enable Naming/PredicateMethod

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

      private

      def terminal_outcome?(outcome)
        STOP_OUTCOMES.include?(outcome)
      end

      def sleep_after_pass(outcome, interval_s, sleeper)
        delay = loop_delay(outcome, interval_s)
        sleeper.call(delay) if delay.positive? && !@stopping
      end

      def drain_outbox(now:)
        @drainer.drain_once(now:)
      end

      def release_poller
        @store.release_poller_lease(stream_id:, lease: @lease.wire) if @lease
      end

      def authenticate_transport
        identity = @transport.authenticate
        return true if identity.is_a?(Hash) && identity['stream_id'] == stream_id

        raise Comms::AuthenticationError, 'the authenticated stream does not match the configured surface identity'
      end

      def latest_binding(envelope)
        @store.binding(correspondent_id: envelope.fetch('correspondent_id'), surface_id:)
      end

      def surface_id = @descriptor.surface_id

      def stream_id = @descriptor.identity.fetch(:stream_id)

      def decision_actor_kind = "#{@descriptor.kind}_user"

      def decision_source = @descriptor.kind

      def poll_timeout_s = @descriptor.transport.fetch(:poll_timeout_s)

      def poller_ttl_s = [POLLER_TTL_S, poll_timeout_s.to_f + 30.0].max

      def control_capacity = @descriptor.limits.fetch(:control_capacity)

      # Terminal slots reserved at admission: rendered parts plus denial prompts.
      def reservation_slots
        @descriptor.rendering.fetch(:max_parts) +
          @descriptor.limits.fetch(:max_denial_prompts_per_request)
      end
    end
  end
end

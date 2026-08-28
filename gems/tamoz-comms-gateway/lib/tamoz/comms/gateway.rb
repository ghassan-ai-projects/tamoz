# frozen_string_literal: true

require 'tamoz/comms'
require 'time'
require 'json'

require_relative 'delivery_drainer'
require_relative 'gateway_admission'
require_relative 'gateway_admission_acknowledgement'
require_relative 'gateway_admission_binding'
require_relative 'gateway_answers'
require_relative 'gateway_callbacks'
require_relative 'gateway_commands'
require_relative 'gateway_conversation_commands'
require_relative 'gateway_context_controls'
require_relative 'gateway_pairing'
require_relative 'gateway_status'
require_relative 'gateway_delivery'

module Tamoz
  module Comms
    ChatResponse = Data.define(:route, :text) do
      def self.direct(text) = new(route: :direct, text:)
      def self.non_direct = new(route: :non_direct, text: nil)
      def direct? = route == :direct
    end

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

      HELP_REPLY = 'Commands: /help, /status [r<reference>], /new, /cancel [r<reference>], ' \
                   '/redirect r<reference> <new task>, /whoami, /start <pairing code>, ' \
                   '/answer r<reference> <answer>, /reset, /compact, /usage, /context, /think <low|medium|high>, ' \
                   '/verbose <quiet|normal|detailed>. Commands never become task text.'
      NO_WORK_REPLY = 'No work is admitted for this conversation.'
      UNKNOWN_REF_REPLY = 'No request with that reference is admitted for this conversation.'
      AMBIGUOUS_REF_REPLY = 'That reference matches more than one request; use the full reference.'
      NEW_CONVERSATION_REPLY = 'New conversation started; earlier history stays in the audit record.'
      NEW_CONVERSATION_UNBOUND_REPLY =
        'No conversation is bound for this channel yet; send a message first.'
      REDIRECT_USAGE_REPLY = 'Usage: /redirect r<reference> <new task>'
      ANSWER_USAGE_REPLY = 'Usage: /answer r<reference> <answer>'
      ANSWER_QUEUED_REPLY = 'Answer received; resuming the paused request.'
      ANSWER_STALE_REPLY = 'That request is no longer waiting for a clarification answer.'
      ANSWER_WRONG_CORRESPONDENT_REPLY = 'That clarification answer cannot be used from this correspondent.'
      ANSWER_UNQUEUED_REPLY = 'Answer could not be queued; try again while the request is paused.'
      START_USAGE_REPLY = 'Usage: /start <pairing code>'
      START_WAITING_REPLY =
        'That code matches a pending pairing request. Waiting for operator approval.'
      START_NO_MATCH_REPLY = "That code doesn't match a pending pairing request."
      START_PAIRED_REPLY = 'This chat is already paired.'
      PAIRING_PENDING_REPLY =
        "This chat isn't paired yet. Read this code to your operator for approval: "
      PAIRING_CODE_TTL_S = 86_400.0
      REDIRECT_UNQUEUED_REPLY = 'Redirect could not be queued; no active checkpoint is available.'
      FINISHED_REQUEST_REPLY = 'That request has already finished.'
      CANCEL_NO_WORK_REPLY = 'No running request to cancel on this conversation.'
      CANCEL_USAGE_REPLY = 'Usage: /cancel [r<reference>]'
      CANCEL_STALE_REF_REPLY = 'That request is no longer open on this conversation.'

      CONTEXT_CONTROL_COMMANDS = %w[reset compact usage context think verbose].freeze
      CONTROLS_UNAVAILABLE_REPLY = 'Context controls are not available on this channel.'
      CONTROLS_NO_SESSION_REPLY =
        'No session state exists for this conversation yet; send a task first.'
      CONTROLS_CONFLICT_REPLY =
        'Context controls are busy right now; another writer holds this conversation. Try again.'
      STATELESS_THREAD_MESSAGE = 'has no checkpoint'

      CONTROL_ARGUMENT_REFUSALS = {
        'think' => 'Reasoning depth must be low, medium, or high.',
        'verbose' => 'Answer verbosity must be quiet, normal, or detailed.'
      }.freeze

      TASK_WORD_PRETRANSLATIONS = {
        'not_started' => 'admitted',
        'claimed' => 'running',
        'redirecting' => 'waiting'
      }.freeze

      REFERENCE_PATTERN = /\Ar[0-9a-f]{#{Lifecycle::REQUEST_REF_WIDTH}}\z/
      FULL_REFERENCE_PATTERN = /\Ar?[0-9a-f]{64}\z/i

      ADMISSION_REFUSALS = {
        integrity_conflict: ['quarantined',
                             'This update conflicts with an earlier message carrying the same identity. ' \
                             'An operator can review it.'],
        open_request_limit: ['rejected', 'This channel has too much open work right now; try again later.'],
        inbound_too_large: ['rejected', "That message exceeds this channel's size limit."],
        capacity_refused: ['rejected', 'The channel is at capacity; try again later.']
      }.freeze

      include Admission
      include AdmissionAcknowledgement
      include AdmissionBinding
      include Answers
      include Callbacks
      include Commands
      include ConversationCommands
      include ContextControls
      include Pairing
      include StatusProjection
      include Delivery

      # The constructor is a public seam; retain its established collaborator
      # list while the lifecycle is split into intent-specific modules.
      # rubocop:disable Metrics/ParameterLists
      def initialize(adapter:, checkpoints:, transport:, descriptor:, poller_owner:, batch_size: 50, drainer: nil,
                     controls: nil, credential: nil, chat_responder: nil)
        @adapter = adapter
        @checkpoints = checkpoints
        @store = adapter.bind_comms_store(checkpoints)
        @transport = transport
        @descriptor = descriptor
        @poller_owner = poller_owner
        @batch_size = batch_size
        @controls = controls
        @credential = credential
        @chat_responder = chat_responder
        @fence = 0
        @stopping = false
        # The store keeps only challenge digests; plaintext codes live here so
        # a repeat contact can name the same code again.
        @issued_pairing_codes = {}
        @drainer = drainer || DeliveryDrainer.new(
          store: @store,
          transport:,
          descriptor:,
          owner: "#{poller_owner}:drainer",
          batch_size:
        )
        @owns_drainer = drainer.nil?
      end
      # rubocop:enable Metrics/ParameterLists

      # Acquire the poller lease and enter the serve loop. A fatal transport
      # error exits through ensure; INT/TERM ask through stop.
      def serve_loop(now_provider: -> { Time.now.utc }, interval_s: 1.0, drain: true,
                     sleeper: ->(seconds) { sleep seconds })
        start_outcome = start(now: now_provider.call)
        return start_outcome unless start_outcome == :started

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
        acquired = @store.acquire_poller_lease(
          surface_id:, bot_id:, owner: @poller_owner, fence: next_fence,
          ttl_s: poller_ttl_s, now:
        )
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

        next_offset = @store.poll_offset(bot_id:)
        batch = poll_batch(next_offset)
        return :transient unless batch

        batch[:updates].each { |envelope| admit(envelope, now:) }
        @store.persist_next_offset(surface_id:, bot_id:, next_offset: batch[:next_offset], now:)
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
        @transport.poll(next_offset:, limit: @batch_size, timeout_s: poll_timeout_s)
      rescue Comms::TransientTransportError
        nil
      end

      # The public name predates the refactor and describes its lease action,
      # not a side-effect-free predicate.
      # rubocop:disable Naming/PredicateMethod
      def renew_poller(now)
        return true if @fence.zero?

        @store.acquire_poller_lease(
          surface_id:, bot_id:, owner: @poller_owner, fence: @fence,
          ttl_s: poller_ttl_s, now:
        ) == :acquired
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
        @store.release_poller_lease(bot_id:, owner: @poller_owner, fence: @fence)
      end

      def authenticate_transport
        return true unless @transport.respond_to?(:authenticate)

        identity = @transport.authenticate(@descriptor, @credential)
        return true if identity.is_a?(Hash) && identity['id'].to_i == bot_id

        raise Comms::AuthenticationError, 'authenticated bot does not match the configured surface identity'
      end

      def latest_binding(envelope)
        @store.binding(correspondent_id: envelope.fetch('correspondent_id'), surface_id:)
      end

      def next_fence
        @fence = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
      end

      def surface_id = @descriptor.surface_id

      def bot_id = @descriptor.identity.fetch(:expected_bot_id)

      def decision_actor_kind = "#{@descriptor.kind}_user"

      def decision_source = @descriptor.kind

      def bot_username = @descriptor.identity[:bot_username]

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

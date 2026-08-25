# frozen_string_literal: true

require 'time'
require 'json'

require_relative 'delivery_drainer'

module Tamoz
  module Comms
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
    class Gateway
      THREAD_PROFILE_NAMESPACE = %w[tamoz worker thread_profile].freeze
      POLLER_TTL_S = 60.0
      CLAIM_TTL_S = 30.0
      TRANSIENT_BACKOFF_BASE_S = 1.0
      TRANSIENT_BACKOFF_MAX_S = 30.0

      HELP_REPLY = 'Commands: /help, /status [r<reference>], /new, /cancel, ' \
                   '/redirect r<reference> <new task>, /whoami, /start <pairing code>, ' \
                   '/reset, /compact, /usage, /context, /think <low|medium|high>, ' \
                   '/verbose <quiet|normal|detailed>. Commands never become task text.'.freeze
      NO_WORK_REPLY = 'No work is admitted for this conversation.'.freeze
      UNKNOWN_REF_REPLY = 'No request with that reference is admitted for this conversation.'.freeze
      AMBIGUOUS_REF_REPLY = 'That reference matches more than one request; use the full reference.'.freeze
      NEW_CONVERSATION_REPLY = 'New conversation started; earlier history stays in the audit record.'.freeze
      NEW_CONVERSATION_UNBOUND_REPLY =
        'No conversation is bound for this channel yet; send a message first.'.freeze
      REDIRECT_USAGE_REPLY = 'Usage: /redirect r<reference> <new task>'.freeze
      START_USAGE_REPLY = 'Usage: /start <pairing code>'.freeze
      START_WAITING_REPLY =
        'That code matches a pending pairing request. Waiting for operator approval.'.freeze
      START_NO_MATCH_REPLY = "That code doesn't match a pending pairing request.".freeze
      START_PAIRED_REPLY = 'This chat is already paired.'.freeze
      PAIRING_PENDING_REPLY =
        "This chat isn't paired yet. Read this code to your operator for approval: ".freeze
      PAIRING_CODE_TTL_S = 86_400.0
      REDIRECT_UNQUEUED_REPLY = 'Redirect could not be queued; no active checkpoint is available.'.freeze
      FINISHED_REQUEST_REPLY = 'That request has already finished.'.freeze
      CANCEL_NO_WORK_REPLY = 'No running request to cancel on this conversation.'.freeze

      # The typed session controls (phase 3 work item 1). The gateway never
      # constructs a Session itself: the wiring hands in a `controls` callable
      # resolving one thread id to the same session-access seam the worker
      # uses. Without one, the commands answer with the bounded unavailable
      # reply instead of failing silently or becoming task text.
      CONTEXT_CONTROL_COMMANDS = %w[reset compact usage context think verbose].freeze
      CONTROLS_UNAVAILABLE_REPLY = 'Context controls are not available on this channel.'.freeze
      CONTROLS_NO_SESSION_REPLY =
        'No session state exists for this conversation yet; send a task first.'.freeze
      CONTROLS_CONFLICT_REPLY =
        'Context controls are busy right now; another writer holds this conversation. Try again.'.freeze
      # The stateless signal read_control_state! raises; any other
      # CheckpointConflictError from the controls seam is a real fence
      # conflict and answers the distinct busy line.
      STATELESS_THREAD_MESSAGE = 'has no checkpoint'

      # Fixed bounded refusals for the typed preference controls. The session
      # layer's ArgumentError message can echo the raw argument bytes, so it
      # never reaches a reply — these constants are the whole answer.
      CONTROL_ARGUMENT_REFUSALS = {
        'think' => 'Reasoning depth must be low, medium, or high.',
        'verbose' => 'Answer verbosity must be quiet, normal, or detailed.'
      }.freeze

      # Store-projection states the Lifecycle tables do not name resolve here
      # first: the checkpoint inbox statuses and the admitted-but-unclaimed
      # sentinel. The Lifecycle translation after this still fails closed.
      TASK_WORD_PRETRANSLATIONS = {
        'not_started' => 'admitted',
        'claimed' => 'running',
        'redirecting' => 'waiting'
      }.freeze

      REFERENCE_PATTERN = /\Ar[0-9a-f]{#{Lifecycle::REQUEST_REF_WIDTH}}\z/.freeze

      # Typed admission refusals (invariant 10): each records its durable
      # disposition and sends one bounded reply; none enqueues work.
      ADMISSION_REFUSALS = {
        integrity_conflict: ['quarantined',
                             'This update conflicts with an earlier message carrying the same identity. ' \
                             'An operator can review it.'],
        open_request_limit: ['rejected', 'This channel has too much open work right now; try again later.'],
        inbound_too_large: ['rejected', "That message exceeds this channel's size limit."],
        capacity_refused: ['rejected', 'The channel is at capacity; try again later.']
      }.freeze

      def initialize(adapter:, checkpoints:, transport:, descriptor:, poller_owner:, batch_size: 50, drainer: nil,
                     controls: nil)
        @adapter = adapter
        @checkpoints = checkpoints
        @store = adapter.bind_comms_store(checkpoints)
        @transport = transport
        @descriptor = descriptor
        @poller_owner = poller_owner
        @batch_size = batch_size
        @controls = controls
        @fence = 0
        @stopping = false
        # The store keeps only challenge digests; the plaintext codes live
        # here so a repeat contact can name the same code again.
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
        return :auth_failed if drain && drain_outbox(now:) == :authentication_refused

        :served
      # A lost lease is never transient: it must escape the CommsError catch-all below.
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
          admit_request(envelope, now:)
        when :decision
          resolve_callback(envelope, now:)
          acknowledge_callback(envelope)
        when :rejected
          record_disposition(envelope, disposition: 'rejected', reason: decision.reason.to_s, now:)
          append_control(decision.control_reply, envelope, now:) if decision.control_reply
        when :control
          admit_control(envelope, decision, now:)
        else
          record_disposition(envelope, disposition: 'ignored', reason: decision.reason.to_s, now:)
          handle_pairing_contact(envelope, now:) if decision.reason == :pairing_pending
        end
      end

      private

      # answerCallbackQuery semantics (plan 03, work item 6): the press is
      # acknowledged as soon as its admission disposition is durable and
      # before any turn processing, so everything after the ack — worker
      # resume, redelivery, a crash — can never un-see it. The signal is
      # ephemeral and best-effort by transport contract; a failed ack never
      # fails the durable decision it followed.
      def acknowledge_callback(envelope)
        return unless envelope['callback_query_id']

        @transport.signal(:ack, callback_query_id: envelope.fetch('callback_query_id'))
      rescue Comms::Error, NotImplementedError
        nil
      end

      # ADR-049 (INV-A/B/D, contract §7.1): an approve is refused unless the
      # presser's evidence meets the prompt's pinned requirement — the value
      # the engine's Decision carried, pinned at prompt build. A Telegram
      # callback supplies `chat_bound`; a decision requiring
      # `filesystem_operator` is refused with a durable refusal and NO
      # decision; deny remains unconditional (INV-A).
      # A refusal never consumes the prompt, so a legitimate deny on the same
      # reference stays possible. The binding is exact: surface id+revision,
      # correspondent and conversation must match the prompt row the reference
      # resolved to. Consumption still inserts the decision in the SAME store
      # transaction (single-use CAS), so a replay never resolves twice.
      def resolve_callback(envelope, now:)
        action, reference = split_callback(envelope.fetch('text').to_s)
        digest = Comms::Canonical.hexdigest(Comms::ApprovalPrompt::REFERENCE_DOMAIN, reference)
        prompt = @store.prompt(reference_digest: digest)

        unless prompt && prompt.fetch('status') == 'active'
          record_disposition(envelope, disposition: 'ignored', reason: 'unknown_reference', now:)
          return
        end

        unless prompt_binding_matches?(prompt, envelope)
          record_disposition(envelope, disposition: 'rejected', reason: 'binding_mismatch', now:)
          return
        end

        if action == 'approve' && approval_insufficient_evidence?(prompt)
          record_disposition(envelope, disposition: 'rejected', reason: 'insufficient_evidence', now:)
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
        record_disposition(envelope, disposition: 'decision', reason: outcome.to_s, now:)
      end

      # Contract §7.1 exact binding: the callback's surface id+revision,
      # correspondent, conversation and originating message receipt must match
      # the prompt row. Every prompt row carries them, so a mismatch is a
      # press outside the bound context, never resolvable.
      def prompt_binding_matches?(prompt, envelope)
        prompt.fetch('surface_id') == envelope.fetch('surface_id') &&
          prompt.fetch('surface_revision') == envelope.fetch('surface_revision') &&
          prompt.fetch('correspondent_id') == envelope.fetch('correspondent_id') &&
          prompt.fetch('conversation_id') == envelope.fetch('conversation_id') &&
          prompt.fetch('prompt_receipt').to_s == envelope.fetch('callback_message_id').to_s
      end

      # ADR-049 INV-B: the presser's evidence is a property of the trusted
      # callback path (a Telegram press is chat_bound), never of the wire
      # text. chat_bound < required_evidence refuses the approve.
      def approval_insufficient_evidence?(prompt)
        Comms::AuthorityEvidence.chat_bound <
          Comms::AuthorityEvidence.from(prompt.fetch('required_evidence'))
      end

      # `approve:<reference>` / `deny:<reference>` → [action, reference]; a
      # bare reference (v1 wire) means deny.
      def split_callback(text)
        if text.start_with?('approve:', 'deny:')
          action, reference = text.split(':', 2)
          [action, reference.to_s]
        else
          ['deny', text]
        end
      end

      # Authority binding precedes work (design §5): the deterministic thread
      # is created and the surface's profile bound write-once BEFORE the first
      # request enqueues. A crash between leaves an inert bound thread; the
      # reverse order is forbidden. An allowlisted first contact also gets its
      # correspondent binding (bound_by records the operator config, so
      # `comms list` and `pair revoke` can see and revoke it).
      def bind_admission(envelope, thread, conversation, now:)
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
        elsif conversation.fetch('thread_id') != thread
          bind_thread_profile(thread)
        end
      end

      def admit_request(envelope, now:)
        conversation = @store.conversation(surface_id:, conversation_id: envelope.fetch('conversation_id'))
        thread = admission_thread(envelope, conversation)
        bind_admission(envelope, thread, conversation, now:)
        history = @store.conversation_history(
          surface_id:, conversation_id: envelope.fetch('conversation_id')
        )
        outcome = @store.admit_and_enqueue(
          envelope, surface_id:, bot_id:, thread:, profile_id: @descriptor.profile_id,
                    reservation: reservation_slots, now:, history:
        )
        if outcome == :enqueued
          append_control(accepted_reply(envelope), envelope, now:, kind: 'accepted')
          return
        end

        # A replayed update already has its admission durable.
        # Re-rendering it here can create a second control row when the queue
        # state changed between the original attempt and the replay.
        return if outcome == :duplicate

        refuse_admission(envelope, outcome, now:)
      end

      # One typed admission refusal: the durable disposition plus exactly one
      # bounded reply; nothing is enqueued.
      def refuse_admission(envelope, outcome, now:)
        disposition, reply = ADMISSION_REFUSALS.fetch(outcome)
        record_disposition(envelope, disposition:, reason: outcome.to_s, now:)
        append_control(reply, envelope, now:)
      end

      # The control arm of admit: a too-large command refuses; otherwise one
      # durable ignored disposition precedes the command or its bounded reply.
      def admit_control(envelope, decision, now:)
        if control_inbound_too_large?(envelope)
          refuse_admission(envelope, :inbound_too_large, now:)
        else
          outcome = record_disposition(envelope, disposition: 'ignored', reason: decision.reason.to_s, now:)
          # A replayed control already has its disposition durable and its
          # command applied; re-running it would double /new generations
          # and append duplicate audit records (mirrors admit_request).
          return if outcome == :duplicate

          if decision.command_intent
            handle_command(envelope, decision, now:)
          elsif decision.control_reply
            append_control(decision.control_reply, envelope, now:)
          end
        end
      end

      def record_disposition(envelope, disposition:, reason:, now:)
        @store.disposition_only(envelope, surface_id:, bot_id:, disposition:, reason:, now:)
      end

      # Commands are bounded by the same declared intake limit as task text.
      # The DEPLOYED surface row is the authority — read through the same
      # store seam admission enforces from — never the caller's descriptor
      # copy, which can drift from the durable deployment.
      def control_inbound_too_large?(envelope)
        text = envelope.fetch('text')
        return false unless text

        text.bytesize > deployed_max_inbound_bytes
      end

      def deployed_max_inbound_bytes
        @store.surface(surface_id:).fetch('limits').fetch('max_inbound_bytes')
      end

      # A bound conversation admits onto the thread its DURABLE GENERATION
      # derives (plan 02 work item 4): /new rotates the identity without
      # touching the write-once route row, and open work on a previous
      # generation's thread keeps running there untouched.
      def admission_thread(envelope, conversation)
        conversation_id = envelope.fetch('conversation_id')
        return Comms::Admission.thread_id(surface_id, conversation_id) unless conversation

        Comms::Admission.thread_id(
          surface_id, conversation_id,
          generation: @store.conversation_generation(surface_id:, conversation_id:)
        )
      end

      # The one synchronous acknowledgement. It names the request reference
      # (plan 02 work item 2) derived LOCALLY from the envelope wire — the
      # same identity the store anchored, so no round-trip is needed — and it
      # says what will actually happen: while earlier admitted work is still
      # open the message QUEUES behind it, so "Accepted" alone would read as
      # "starting now". The reference authorizes nothing; it only ever
      # resolves read-only status inside this conversation.
      def accepted_reply(envelope)
        reference = Lifecycle::RequestRef.for(request_identity(envelope))
        status = @store.conversation_status(
          surface_id:, conversation_id: envelope.fetch('conversation_id')
        )
        if status && status.fetch('open_requests') > 1
          "Accepted #{reference}; queued behind earlier work; " \
            'I will report committed progress when it runs.'
        else
          "Accepted #{reference}. I will report committed progress."
        end
      end

      def request_identity(envelope)
        Tamoz::Core::RequestIdentity.request_id(
          surface_id: envelope.fetch('surface_id'),
          surface_revision: envelope.fetch('surface_revision'),
          bot_id:, update_id: envelope.fetch('update_id'),
          raw_payload_hash: envelope.fetch('raw_payload_hash')
        )
      end

      def command_request_id(envelope, tags)
        Comms::Canonical.hexdigest(
          'tamoz.comms.command.v1',
          [surface_id, envelope.fetch('update_id'), *tags]
        )
      end

      # Command registry parity (invariant 8): every name in Commands::KNOWN
      # has a branch here producing a distinct outcome — there is no
      # fallthrough, because an unimplemented command must not parse as known.
      def handle_command(envelope, decision, now:)
        intent = decision.command_intent
        case intent.name
        when 'help'
          append_control(HELP_REPLY, envelope, now:)
        when 'status'
          append_control(status_text(envelope, intent.arguments), envelope, now:)
        when 'new'
          append_control(new_conversation(envelope), envelope, now:)
        when 'cancel'
          append_control(cancel_request(envelope, now:), envelope, now:)
        when 'redirect'
          append_control(redirect_request(envelope, intent.arguments), envelope, now:)
        when 'whoami'
          append_control(whoami_text(envelope), envelope, now:)
        when 'start'
          append_control(start_text(intent.arguments), envelope, now:)
        when *CONTEXT_CONTROL_COMMANDS
          append_control(context_control_text(envelope, intent), envelope, now:)
        end
      end

      # One bounded line per typed control, built from the projection document
      # the session layer returned. Resolution goes through the conversation's
      # CURRENT generation — after /new the controls address the successor
      # thread automatically. An unknown preference value surfaces as the
      # semantics layer's typed failure message, never as an exception.
      def context_control_text(envelope, intent)
        return CONTROLS_UNAVAILABLE_REPLY unless @controls

        conversation_id = envelope.fetch('conversation_id')
        return NEW_CONVERSATION_UNBOUND_REPLY unless @store.conversation(surface_id:, conversation_id:)

        thread = Comms::Admission.thread_id(
          surface_id, conversation_id,
          generation: @store.conversation_generation(surface_id:, conversation_id:)
        )
        controls = @controls.call(thread)
        return CONTROLS_UNAVAILABLE_REPLY unless controls

        Comms::ControlReply.line(intent.name, run_context_control(controls, thread, envelope, intent))
      rescue ArgumentError
        CONTROL_ARGUMENT_REFUSALS.fetch(intent.name, CONTROLS_UNAVAILABLE_REPLY)
      rescue Tamoz::CheckpointConflictError => error
        error.message.to_s.end_with?(STATELESS_THREAD_MESSAGE) ? CONTROLS_NO_SESSION_REPLY : CONTROLS_CONFLICT_REPLY
      end

      def run_context_control(controls, thread, envelope, intent)
        request_id = command_request_id(envelope, ['context_control', intent.name])
        case intent.name
        when 'reset' then controls.reset_episode(thread:, request_id:).document
        when 'compact' then controls.compact_transcript(thread:, request_id:).document
        when 'usage' then controls.usage_report(thread:).document
        when 'context' then controls.context_report(thread:).document
        when 'think' then controls.set_reasoning_depth(thread:, request_id:, depth: intent.arguments).document
        else controls.set_answer_verbosity(thread:, request_id:, verbosity: intent.arguments).document
        end
      end

      # `/start` is feedback only (design §7): matching a pending challenge
      # reports the wait; binding activation stays exclusively with the
      # operator's approve_pairing — no chat path ever mutates a binding.
      def start_text(arguments)
        return START_USAGE_REPLY unless arguments

        START_PAIRED_REPLY
      end

      # Pairing first contact: an unbound sender on a pairing surface is
      # never left in silence. The durable record stays an ignored
      # :pairing_pending observation; the reply names one live challenge's
      # code, and `/start <code>` answers whether that code is pending.
      def handle_pairing_contact(envelope, now:)
        parsed = Comms::Commands.parse(envelope.fetch('text').to_s, bot_username:)
        if parsed&.command == 'start'
          append_control(pairing_start_reply(parsed.arguments, envelope, now:), envelope, now:)
          return
        end

        append_control("#{PAIRING_PENDING_REPLY}#{ensure_pairing_code(envelope, now:)}", envelope, now:)
      end

      def pairing_start_reply(code, envelope, now:)
        return START_USAGE_REPLY unless code

        matched = pending_pairing_rows(envelope, now).any? do |row|
          Comms::PairingChallenge.verify?(
            challenge: code, digest: row.fetch('challenge_digest'),
            surface_id: row.fetch('surface_id'), correspondent_id: row.fetch('correspondent_id'),
            conversation_id: row.fetch('conversation_id')
          )
        end
        matched ? START_WAITING_REPLY : START_NO_MATCH_REPLY
      end

      def pending_pairing_rows(envelope, now)
        @store.pairing_challenges(status: 'pending', surface_id:,
                                  correspondent_id: envelope.fetch('correspondent_id'), now:)
                  .select { |row| row.fetch('conversation_id') == envelope.fetch('conversation_id') }
      end

      # Reuses this conversation's live pending row when its plaintext is
      # still known here; otherwise issues one new hashed challenge.
      def ensure_pairing_code(envelope, now:)
        prune_issued_pairing_codes(now)
        reused = pending_pairing_rows(envelope, now).find do |row|
          row.fetch('conversation_id') == envelope.fetch('conversation_id') &&
            @issued_pairing_codes.key?(row.fetch('challenge_digest'))
        end
        return @issued_pairing_codes.fetch(reused.fetch('challenge_digest')) if reused

        issue_pairing_code(envelope, now:)
      end

      # The plaintext memo never outlives its durable rows: digests whose
      # challenges are no longer live-pending (consumed or expired) are
      # forgotten, so the memo stays bounded by the store's pending set.
      def prune_issued_pairing_codes(now)
        live = @store.pairing_challenges(status: 'pending', now:)
                     .map { |row| row.fetch('challenge_digest') }
        @issued_pairing_codes.delete_if { |digest, _code| !live.include?(digest) }
      end

      def issue_pairing_code(envelope, now:)
        code = Comms::PairingChallenge.generate_code
        correspondent_id = envelope.fetch('correspondent_id')
        challenge = Comms::PairingChallenge.build(
          surface_id:, correspondent_id:, conversation_id: envelope.fetch('conversation_id'),
          ttl_s: PAIRING_CODE_TTL_S, now:, code:
        )
        @store.insert_pairing_challenge(
          digest: challenge.digest, surface_id:, correspondent_id:,
          conversation_id: envelope.fetch('conversation_id'), expires_at: challenge.expires_at, now:
        )
        @issued_pairing_codes[challenge.digest] = code
        code
      end

      # `/status` with no argument renders the conversation aggregate from
      # durable facts (invariant 12); with `r<ref>` it resolves ONE request
      # scoped to the caller's own conversation — a foreign or malformed ref
      # is one bounded reply that leaks nothing.
      def status_text(envelope, arguments)
        return request_status_text(envelope, arguments) if arguments

        status = @store.conversation_status(surface_id:, conversation_id: envelope.fetch('conversation_id'))
        return NO_WORK_REPLY unless status

        "Work status: task=#{task_word(status)}; " \
          "#{state_axes(status)}" \
          "delivery=#{delivery_word(status)}; " \
          "next=#{status.fetch('next_action', 'inspect')}; " \
          "open requests=#{status.fetch('open_requests')}." \
          "#{reference_sentence(status)}#{queue_sentence(status)}" \
          "#{cancellation_sentence(status)}#{reason_sentence(status)}"
      end

      def request_status_text(envelope, reference)
        resolved = @store.request_status(
          surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: String(reference)
        )
        return UNKNOWN_REF_REPLY if resolved == :unknown_ref
        return AMBIGUOUS_REF_REPLY if resolved == :ambiguous_ref

        "Request #{resolved.fetch('request_ref')}: task=#{task_word(resolved)}; " \
          "delivery=#{delivery_word(resolved)}; " \
          "#{state_axes(resolved)}" \
          "next=#{resolved.fetch('next_action', 'inspect')}." \
          "#{queue_sentence(resolved)}#{cancellation_sentence(resolved)}#{reason_sentence(resolved)}"
      end

      # `/new` rotates the conversation generation durably (plan 02 work item
      # 4); audit history stays, and later admissions derive the fresh thread
      # from the bumped generation.
      def new_conversation(envelope)
        @store.bump_generation(surface_id:, conversation_id: envelope.fetch('conversation_id'))
        NEW_CONVERSATION_REPLY
      rescue KeyError
        NEW_CONVERSATION_UNBOUND_REPLY
      end

      # `/redirect r<ref> <task>` reuses the durable redirect path exactly the
      # way cancel does; it changes TASK TEXT only — never profile, model,
      # budget, or schedule.
      def redirect_request(envelope, arguments)
        parts = String(arguments).strip.split(/\s+/, 2)
        reference = parts[0].to_s
        task_text = parts[1].to_s.strip
        return REDIRECT_USAGE_REPLY unless valid_reference?(reference) && !task_text.empty?

        resolved = @store.request_status(
          surface_id:, conversation_id: envelope.fetch('conversation_id'), ref: reference
        )
        return UNKNOWN_REF_REPLY if resolved == :unknown_ref
        return AMBIGUOUS_REF_REPLY if resolved == :ambiguous_ref
        return FINISHED_REQUEST_REPLY if finished_request?(resolved)

        @checkpoints.enqueue_request(
          thread_id: resolved.fetch('thread_id'),
          request_id: command_request_id(envelope, %w[redirect]),
          operation: :redirect,
          payload: { 'task' => task_text },
          delivery: :redirect
        )
        "Redirecting #{resolved.fetch('request_ref')}; the replacement task is queued."
      rescue Tamoz::CheckpointConflictError
        REDIRECT_UNQUEUED_REPLY
      end

      def whoami_text(envelope)
        "You are #{envelope.fetch('correspondent_id')} in conversation " \
          "#{envelope.fetch('conversation_id')} on surface #{surface_id}."
      end

      def valid_reference?(text) = text.match?(REFERENCE_PATTERN)

      # The checkpoint inbox row outlives the comms projection by moments; a
      # terminal inbox status means the turn ran to its end and cannot take a
      # replacement task.
      def finished_request?(resolved)
        request = @checkpoints.fetch_request(
          thread_id: resolved.fetch('thread_id'), request_id: resolved.fetch('request_id'), namespace: []
        )
        request && %i[completed failed].include?(request.status)
      end

      # Both lifecycle axes render EXTERNAL vocabulary only (invariant 3);
      # `idle`/`none` are the spellings for an axis with nothing on it.
      def task_word(projection)
        internal = TASK_WORD_PRETRANSLATIONS.fetch(
          projection.fetch('task_state'), projection.fetch('task_state')
        )
        Lifecycle.task_state_for(internal) || 'idle'
      end

      def delivery_word(projection)
        internal = projection.fetch('delivery_state')
        return 'none' if internal == 'none'

        Lifecycle.delivery_state_for(internal)
      end

      def state_axes(projection)
        "phase=#{projection.fetch('phase', 'unknown')}; " \
          "event=#{projection.fetch('event_kind', 'unknown')}##{projection.fetch('event_sequence', 'unknown')}; " \
          "effect=#{projection.fetch('effect_state')}; " \
          "capability=#{projection.fetch('capability_state')}; "
      end

      def reference_sentence(projection)
        reference = projection['request_ref']
        reference ? " Reference #{reference}." : ''
      end

      def queue_sentence(projection)
        return '' unless projection.key?('queue_position')

        sentence = " Queue position #{projection.fetch('queue_position')}."
        projection['queue_age_ms'] ? "#{sentence} Age #{projection.fetch('queue_age_ms')} ms." : sentence
      end

      def reason_sentence(projection)
        reason = projection['terminal_reason']
        reason ? " Reason: #{reason}." : ''
      end

      # The cancellation timeline in external words (invariant 9): the three
      # points render distinctly, the terminal word follows the recorded
      # settle kind, and a raced completion says exactly that — it never
      # claims an already-issued external call stopped.
      def cancellation_sentence(projection)
        facts = projection['cancellation']
        return '' unless facts

        sentence = " Cancellation requested#{age_phrase(facts['requested_age_ms'])}."
        sentence << " Observed by the runner#{age_phrase(facts['observed_age_ms'])}." if facts['observed_at_ms']
        case facts['terminal']
        when 'stopped'
          "#{sentence} Terminal: stopped at the cancellation boundary."
        when 'completed_before_effect'
          "#{sentence} Terminal: completed before the cancellation took effect."
        when 'failed_before_effect'
          "#{sentence} Terminal: failed before the cancellation took effect."
        when 'blocked'
          "#{sentence} Terminal: work was blocked when the cancellation arrived."
        else
          sentence
        end
      end

      def age_phrase(age_ms)
        return '' if age_ms.nil?

        seconds = [age_ms.to_i / 1000, 0].max
        age = seconds < 60 ? "#{seconds}s" : (seconds < 3600 ? "#{seconds / 60}m" : "#{seconds / 3600}h")
        " #{age} ago"
      end

      # `/cancel` stamps the durable `requested` point and enqueues the cancel
      # operation in ONE store transaction (plan 03, work item 4): a rollback
      # — a replayed cancel id, a tombstoned thread — leaves neither the stamp
      # nor the queued operation behind. The target thread is the CURRENT
      # generation's, exactly what admission derives: open work on an earlier
      # generation's thread keeps running there untouched.
      def cancel_request(envelope, now:)
        conversation_id = envelope.fetch('conversation_id')
        return CANCEL_NO_WORK_REPLY unless @store.conversation(surface_id:, conversation_id:)

        thread_id = Comms::Admission.thread_id(
          surface_id, conversation_id,
          generation: @store.conversation_generation(surface_id:, conversation_id:)
        )
        status = @store.conversation_status(surface_id:, conversation_id:)
        return CANCEL_NO_WORK_REPLY unless status &&
                                           status.fetch('thread_id') == thread_id &&
                                           status.fetch('open_requests').positive?

        request_id = command_request_id(envelope, %w[cancel])
        @store.request_cancellation(
          thread_id:,
          request_id:,
          payload: { 'task' => { 'cancel' => true, 'reason' => 'cancelled_by_user' } },
          now:
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
        # Belt-and-braces: a control reply can never fail the delivery build
        # on length, whatever an upstream layer produced.
        text = String(reply_text).scrub.byteslice(0, Comms::Delivery::MAX_TEXT_BYTES)
        delivery = Comms::Delivery.build(
          conversation_id: envelope.fetch('conversation_id'), reply_to: reply_target(envelope), kind:,
          text:, part_index: 0, part_count: 1, journaled: false,
          render_version: Comms::Rendering::RENDER_VERSION,
          content_digest: Comms::Rendering.content_digest(text)
        )
        @store.append_delivery(delivery.wire, surface_id:, capacity: control_capacity, now:)
      end

      # Invariant 2: a control reply targets the platform message id the
      # update carries — message_id for message/command kinds,
      # callback_message_id for callbacks; update_id is the last resort only
      # when the update carries neither.
      def reply_target(envelope)
        if envelope.fetch('kind') == 'callback'
          envelope['callback_message_id'] || envelope.fetch('update_id')
        else
          envelope['message_id'] || envelope.fetch('update_id')
        end
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

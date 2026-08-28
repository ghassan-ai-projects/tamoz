# frozen_string_literal: true

require 'time'
require 'json'

require_relative 'lifecycle'

module Tamoz
  module Comms
    # The worker's DeliverySink projection (design §11, ADR-041/042): worker
    # lifecycle events become Delivery rows in the outbox, appended BEFORE
    # close_occurrence so a crash never loses the terminal answer. The sink
    # never makes a channel network call; it only writes the shared runtime
    # database through the CommsStore. One sink serves every surface: the
    # thread's conversation route names its surface and capacity.
    #
    # Unbound threads (no admission route) deliver nothing and return nil —
    # the worker is indistinguishable from one with a disabled surface.
    # Output is rendered with the deterministic splitter; multipart output is
    # one bounded Delivery per part.
    # The projection is one multi-step pipeline (route → surface → render →
    # append); the metric smells measure the pipeline, not a choice to
    # overload.
    # :reek:TooManyStatements, :reek:DuplicateMethodCall, :reek:UnusedParameters
    # :reek:DataClump, :reek:FeatureEnvy, :reek:NilCheck
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- the projection pipeline.
    class OutboxDeliverySink
      EVENT_KINDS = {
        'request.accepted' => 'accepted',
        'request.approved' => 'answer',
        'request.denied' => 'answer',
        'request.completed' => 'answer',
        'request.failed' => 'failed',
        'request.stopped' => 'stopped',
        'request.blocked' => 'blocked',
        'request.approval_request' => 'approval_request',
        'request.clarification_request' => 'clarification_request',
        'request.claimed' => 'running',
        'request.running' => 'running',
        'request.waiting' => 'waiting',
        'request.recovered' => 'progress',
        'request.phase' => 'progress'
      }.freeze

      # Kinds whose rows the admission reservation covers (design §12): the
      # request is finished once they are durable, so the reservation releases.
      TERMINAL_KINDS = %w[answer failed stopped blocked].freeze
      VERIFICATION_CLASSES = {
        'request.completed' => 'Verified',
        'request.approved' => 'Response only',
        'request.denied' => 'Not verified',
        'request.failed' => 'Not verified',
        'request.stopped' => 'Not verified',
        'request.blocked' => 'Not verified'
      }.freeze
      APPROVAL_ACTIONS = {
        'apply_patch' => 'apply a file change',
        'create_file' => 'create a file',
        'run_check' => 'run a local check',
        'child_task' => 'start a child task'
      }.freeze
      GENERIC_APPROVAL_ACTION = 'complete requested work'

      # Non-terminal milestone kinds (plan 03, work items 1-2): each projects
      # one committed worker fact onto ONE coalesced control row whose markup
      # carries the request reference. They never reserve, never terminate,
      # and never journal into conversation history.
      MILESTONE_KINDS = %w[running waiting progress].freeze
      MILESTONE_TASK_STATES = { 'running' => 'running', 'waiting' => 'waiting', 'progress' => 'running' }.freeze
      MILESTONE_TEXT_CHARACTERS = 200
      MILESTONE_COPY = {
        'claimed' => ['Starting work on your request.', 'Continue working.'],
        'discovery' => ['Checking the request.', 'Continue working.'],
        'read_only' => ['Reviewing the available information.', 'Prepare the response.'],
        'action' => ['Preparing the requested change.', 'Check the result.'],
        'repair' => ['Checking the requested change.', 'Check the result.'],
        'waiting' => ['Paused for the next step.', 'Reply when ready.'],
        'recovered' => ['Resuming work on your request.', 'Continue working.'],
        'running' => ['Working on your request.', 'Share the result when ready.'],
        'progress' => ['Continuing work on your request.', 'Share the result when ready.']
      }.transform_values(&:freeze).freeze
      GENERIC_MILESTONE_COPY = ['Working on your request.', 'Share the result when ready.'].freeze

      def initialize(adapter:, checkpoints:, rendering: Comms::Rendering)
        @store = adapter.bind_comms_store(checkpoints)
        @rendering = rendering
      end

      # @param event [Hash] `{thread_id:, kind:, text:, ...}` — the worker's
      #   lifecycle event.
      # @return [Symbol, nil] :accepted when at least one Delivery was
      #   appended durably; nil when the thread is unbound or the kind is not
      #   a deliverable lifecycle kind.
      def push(event)
        kind = EVENT_KINDS[event.fetch(:kind)]
        return nil unless kind

        route = @store.request_conversation(thread_id: event.fetch(:thread_id))
        return nil unless route

        surface = @store.surface(surface_id: route.fetch('surface_id'))
        return nil unless surface

        return push_milestone(event, kind, route, surface) if MILESTONE_KINDS.include?(kind)
        return push_clarification_question(event, route, surface) if kind == 'clarification_request'

        if kind == 'approval_request'
          unless surface.fetch('approvals').fetch('mode') == 'deny_only'
            return push_approval_unavailable_notice(event, route, surface)
          end

          return push_approval_prompt(event, route, surface)
        end

        render_limits = surface.fetch('rendering')
        parts = @rendering.plain(terminal_text(event, kind),
                                 max_parts: render_limits.fetch('max_parts'),
                                 part_characters: render_limits.fetch('part_characters'),
                                 overflow: render_limits.fetch('overflow'))
        reserved_request_id = event[:request_id] if TERMINAL_KINDS.include?(kind)
        parts.each do |part|
          @store.append_delivery(
            Comms::Delivery.build(
              conversation_id: route.fetch('conversation_id'), kind:,
              text: part.fetch('text'), part_index: part.fetch('part_index'),
              part_count: part.fetch('part_count'), journaled: kind != 'control',
              render_version: @rendering::RENDER_VERSION,
              content_digest: part.fetch('content_digest'),
              # Two occurrences may honestly produce the same text (ask twice,
              # answered twice); the occurrence belongs in the identity so the
              # second answer is not content-deduped into silence. A RE-PUSH of
              # the same occurrence still dedups — that is the crash window the
              # derived id exists for.
              identity_key: event[:request_id]
            ).wire,
            surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
            reserved_request_id:, now: Time.now.utc
          )
        end
        # The terminal projection is durable; its reservation returns to
        # intake (design §12, invariant 57). The settle kind is recorded with
        # it so the status wording follows the task axis, never a guess.
        if reserved_request_id
          @store.complete_request(thread_id: event.fetch(:thread_id), request_id: reserved_request_id,
                                  settle_kind: kind)
        end
        :accepted
      end

      private

      def terminal_text(event, kind)
        text = event.fetch(:text).to_s
        return text unless event[:request_id] && TERMINAL_KINDS.include?(kind)

        reference = Lifecycle::RequestRef.for(event.fetch(:request_id))
        "#{reference} · #{verification_class(event)}: result — #{text}"
      end

      # A completed turn is "Verified"; a direct chat response completes without
      # proving anything, so it is "Response only" — the worker marks it with a
      # direct_response phase so the card does not over-claim verification.
      def verification_class(event)
        return 'Response only' if event[:phase] == 'direct_response'

        VERIFICATION_CLASSES.fetch(event.fetch(:kind))
      end

      # One committed worker fact -> ONE bounded control row whose markup is
      # the milestone projection (plan 03, behavior model 1/5). The row is
      # journaled = 0 (invariant 11), reserves nothing (TERMINAL_KINDS are
      # untouched), and the store coalesces it into the request's live pending
      # row instead of streaming new messages.
      def push_milestone(event, kind, route, surface)
        request_id = event[:request_id]
        return nil unless request_id

        reference = Lifecycle::RequestRef.for(request_id)
        phase = event[:phase] ? event[:phase].to_s : kind
        text = milestone_text(reference, phase)
        markup = JSON.generate(
          'request_ref' => reference,
          'milestone' => kind,
          'phase' => phase,
          'sequence' => Integer(event.fetch(:sequence)),
          'task_state' => Lifecycle.task_state_for(MILESTONE_TASK_STATES.fetch(kind)),
          'delivery_state' => Lifecycle.delivery_state_for('pending')
        )
        # Once the request's first card carries a delivery receipt, every
        # successor milestone UPDATES that same platform message (plan 03,
        # behavior model 1) instead of sending a new one. While no receipt
        # exists — first card still pending or lost — the row stays an
        # ordinary send and coalescing keeps it one live row.
        card = delivered_card_message_id(route, reference)
        @store.append_delivery(
          Comms::Delivery.build(
            conversation_id: route.fetch('conversation_id'), kind: 'control',
            operation: card ? 'edit_message' : 'send_message', reply_to: card,
            text:, part_index: 0, part_count: 1, journaled: false,
            render_version: @rendering::RENDER_VERSION,
            content_digest: @rendering.content_digest(text),
            identity_key: request_id.to_s, markup:
          ).wire,
          surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
          now: Time.now.utc
        )
        :accepted
      end

      def milestone_text(reference, phase)
        now, next_action = MILESTONE_COPY.fetch(phase, GENERIC_MILESTONE_COPY)
        "#{reference} · Now: #{now} Next: #{next_action}".byteslice(0, MILESTONE_TEXT_CHARACTERS)
      end

      # The platform message id the request's live card is bound to: the
      # receipt of the NEWEST delivered milestone row for the reference.
      # Rows come back oldest-first, so the scan runs newest-first.
      def delivered_card_message_id(route, request_ref)
        @store.outbox_rows(surface_id: route.fetch('surface_id'), statuses: %w[succeeded])
              .reverse_each
              .filter_map { |row| card_message_id(row, request_ref) }
              .first
      end

      def card_message_id(row, request_ref)
        return nil unless row.fetch('kind') == 'control' && row['markup'] && row['receipt']

        facts = JSON.parse(row.fetch('markup'))
        return nil unless facts.is_a?(Hash) && facts['request_ref'] == request_ref &&
                          facts['milestone'].is_a?(String)

        JSON.parse(row.fetch('receipt')).fetch('message_id')
      rescue JSON::ParserError
        nil
      end

      def push_clarification_question(event, route, surface)
        request_id = event[:request_id]
        return nil unless request_id

        part = clarification_part(event, surface)
        outcome = @store.append_delivery(
          clarification_delivery(event, route, part).wire,
          surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface), now: Time.now.utc
        )
        return :capacity_refused if outcome == :capacity_refused

        %i[appended duplicate].include?(outcome) ? :accepted : outcome
      end

      def clarification_part(event, surface)
        render_limits = surface.fetch('rendering')
        question = clarification_question(event.fetch(:interrupts))
        @rendering.plain(
          question,
          max_parts: 1,
          part_characters: render_limits.fetch('part_characters'),
          overflow: render_limits.fetch('overflow')
        ).fetch(0)
      end

      def clarification_delivery(event, route, part)
        request_id = event.fetch(:request_id)
        Comms::Delivery.build(
          conversation_id: route.fetch('conversation_id'), kind: 'control', text: part.fetch('text'),
          part_index: 0, part_count: 1, journaled: false,
          render_version: @rendering::RENDER_VERSION,
          content_digest: part.fetch('content_digest'), identity_key: request_id,
          markup: clarification_markup(request_id)
        )
      end

      def clarification_markup(request_id)
        JSON.generate(
          'request_ref' => Lifecycle::RequestRef.for(request_id),
          'milestone' => 'waiting', 'phase' => 'clarification_required', 'actions' => ['answer']
        )
      end

      def clarification_question(interrupts)
        descriptors = Array(interrupts).filter_map { |interrupt| interrupt[:descriptor] }
        descriptor = descriptors.find { |candidate| candidate['kind'] == 'clarify' }
        text = descriptor&.fetch('question', nil).to_s.gsub(/[[:cntrl:]]/, ' ').split.join(' ')
        text.empty? ? 'Please answer the question to continue.' : text
      end

      # A fresh single-use prompt is stored inactive, and the control
      # delivery's markup carries the plaintext reference so the gateway can
      # activate it after the send receipt is durable. The pinned evidence is
      # read from the decision the engine journaled into the interrupt
      # descriptor (INV-C) — never synthesized here, never taken from wire
      # input.
      def push_approval_prompt(event, route, surface)
        conversation_binding = @store.binding_by_conversation(surface_id: route.fetch('surface_id'),
                                                              conversation_id: route.fetch('conversation_id'))
        return nil unless conversation_binding

        evidence = decision_evidence(event.fetch(:interrupts))
        reference, prompt = Comms::ApprovalPrompt.build(
          surface_id: route.fetch('surface_id'), surface_revision: surface.fetch('revision'),
          thread_id: event.fetch(:thread_id), occurrence_id: event.fetch(:request_id),
          interrupts: event.fetch(:interrupts),
          required_evidence: evidence,
          correspondent_id: conversation_binding.fetch('correspondent_id'),
          conversation_id: route.fetch('conversation_id'),
          prompt_ttl_s: surface.fetch('approvals').fetch('prompt_ttl_s')
        )
        actions = offered_actions(evidence)
        part = approval_part(event, actions, surface)
        @store.insert_prompt(prompt.wire)
        markup = JSON.generate('reference' => reference, 'actions' => actions)
        text = part.fetch('text')
        @store.append_delivery(
          Comms::Delivery.build(
            conversation_id: route.fetch('conversation_id'), kind: 'approval_request',
            text:, part_index: 0, part_count: 1,
            journaled: true, render_version: @rendering::RENDER_VERSION,
            content_digest: part.fetch('content_digest'),
            identity_key: event.fetch(:request_id),
            markup:
          ).wire,
          surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
          reserved_request_id: event.fetch(:request_id), now: Time.now.utc
        )
        :accepted
      end

      def approval_part(event, actions, surface)
        limits = surface.fetch('rendering')
        @rendering.plain(
          approval_text(event, actions), max_parts: 1,
          part_characters: limits.fetch('part_characters'), overflow: limits.fetch('overflow')
        ).fetch(0)
      end

      def approval_text(event, actions)
        action = approval_action(event.fetch(:interrupts))
        next_step = actions.include?('approve') ?
          'Approve or Deny; Deny stops safely.' : 'ask an operator; Deny stops safely.'
        request_reference = Lifecycle::RequestRef.for(event.fetch(:request_id))
        "#{request_reference} · Approval required: #{action}. Next: #{next_step}"
      end

      def approval_action(interrupts)
        descriptor = interrupts.first.fetch(:descriptor)
        APPROVAL_ACTIONS.fetch(descriptor['tool'], GENERIC_APPROVAL_ACTION)
      end

      # The turn is parked on a human answer this channel cannot collect:
      # with approvals disabled the prompt machinery never runs, and without
      # this notice the correspondent watches the work go silent. A control
      # row, not an answer — the request is still open, so nothing terminal
      # is owed yet — and deduped per occurrence by identity_key, like the
      # prompt itself.
      def push_approval_unavailable_notice(event, route, surface)
        text = 'This work is waiting for approval, but approvals are not enabled on this ' \
               'channel. An operator can approve it with `tamoz approve`, or set ' \
               'approvals.mode: deny_only in the channel config.'
        @store.append_delivery(
          Comms::Delivery.build(
            conversation_id: route.fetch('conversation_id'), kind: 'control',
            text:, part_index: 0, part_count: 1, journaled: false,
            render_version: @rendering::RENDER_VERSION,
            content_digest: @rendering.content_digest(text),
            identity_key: event.fetch(:request_id)
          ).wire,
          surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
          now: Time.now.utc
        )
        :accepted
      end

      # ADR-049 INV-C/INV-D: the requirement is the `required_evidence` the
      # engine's Decision carries in the journaled interrupt descriptor — a
      # model-supplied claim inside the descriptor body is never read. The
      # prompt and the rendered keyboard pin the SAME value, so the buttons
      # never offer an action the evidence gate would refuse.
      def decision_evidence(interrupts)
        Comms::AuthorityEvidence.from(
          interrupts.first.fetch(:descriptor).fetch('decision').fetch('required_evidence').to_s
        )
      end

      # An approve button is offered only when `chat_bound` evidence can meet
      # the decision's pinned requirement; its absence is UX, not the
      # security boundary — a stray `approve:` callback is still refused by
      # the gateway's evidence compare.
      def offered_actions(evidence)
        Comms::AuthorityEvidence.chat_bound >= evidence ? %w[approve deny] : %w[deny]
      end

      def outbox_capacity(surface)
        surface.fetch('limits').fetch('outbox_capacity')
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

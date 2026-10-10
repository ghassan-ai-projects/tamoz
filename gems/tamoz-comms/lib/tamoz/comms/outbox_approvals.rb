# frozen_string_literal: true

require 'json'

module Tamoz
  module Comms
    # The approval half of the outbox projection: a paused turn's single-use prompt and the card that
    # asks for it, or — where the channel collects no approvals — a notice that the work waits on one.
    # :reek:DuplicateMethodCall, :reek:FeatureEnvy, :reek:UtilityFunction
    class OutboxApprovals
      APPROVAL_EXCERPT_CHARACTERS = 1500

      def initialize(store:, rendering:)
        @store = store
        @rendering = rendering
      end

      def push(event, route, surface)
        return push_approval_prompt(event, route, surface) if surface.fetch('approvals').fetch('mode') == 'deny_only'

        push_approval_unavailable_notice(event, route, surface)
      end

      private

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
        reference, prompt = build_approval_prompt(event, route, surface, conversation_binding, evidence)
        actions = offered_actions(evidence)
        part = approval_part(event, actions, surface)
        @store.insert_prompt(prompt.wire)
        markup = JSON.generate('reference' => reference, 'actions' => actions)
        append_approval_delivery(event, route, surface, part, markup)
        :accepted
      end

      def build_approval_prompt(event, route, surface, binding, evidence)
        Comms::ApprovalPrompt.build(
          surface_id: route.fetch('surface_id'), surface_revision: surface.fetch('revision'),
          thread_id: event.fetch(:thread_id), occurrence_id: event.fetch(:request_id),
          interrupts: event.fetch(:interrupts), required_evidence: evidence,
          correspondent_id: binding.fetch('correspondent_id'), conversation_id: route.fetch('conversation_id'),
          prompt_ttl_s: surface.fetch('approvals').fetch('prompt_ttl_s')
        )
      end

      def append_approval_delivery(event, route, surface, part, markup)
        @store.append_delivery(
          Comms::Delivery.build(
            conversation_id: route.fetch('conversation_id'), kind: 'approval_request',
            text: part.fetch('text'), part_index: 0, part_count: 1,
            journaled: true, render_version: @rendering::RENDER_VERSION,
            content_digest: part.fetch('content_digest'), identity_key: event.fetch(:request_id), markup:
          ).wire,
          surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
          reserved_request_id: event.fetch(:request_id), now: Time.now.utc
        )
      end

      def approval_part(event, actions, surface)
        limits = surface.fetch('rendering')
        @rendering.plain(
          approval_text(event.fetch(:interrupts).first.fetch(:descriptor), actions, limits.fetch('part_characters')),
          max_parts: 1, thread: event.fetch(:thread_id),
          part_characters: limits.fetch('part_characters'), overflow: limits.fetch('overflow')
        ).fetch(0)
      end

      # The person deciding sees what will change (the file and its content, the diff, or the
      # command); the excerpt shrinks to the surface's bound so the ask itself is never cut.
      def approval_text(descriptor, actions, characters)
        ask = actions.include?('approve') ? 'Allow it?' : 'An operator must allow it; Deny stops it.'
        action, detail = approval_action(descriptor)
        budget = [characters - action.length - ask.length - 16, APPROVAL_EXCERPT_CHARACTERS].min
        "#{action}#{excerpt(detail, budget) if detail && budget.positive?}\n\n#{ask}"
      end

      def approval_action(descriptor)
        arguments = descriptor['arguments'] || {}
        case descriptor['tool']
        when 'create_file'
          ["I'd like to create `#{arguments['path']}`#{mode_note(arguments)} with:", arguments['content']]
        when 'apply_patch' then ["I'd like to change `#{arguments['path']}`:", descriptor['preview']]
        when 'run_check' then ["I'd like to run:", descriptor['preview'].to_s.delete_prefix('$ ')]
        when 'child_task' then ["I'd like to start a child task."]
        else ["I'd like to use #{descriptor['tool']}."]
        end
      end

      def mode_note(arguments)
        mode = arguments['mode'].to_s
        mode.empty? || mode == '0644' ? '' : " (mode #{mode})"
      end

      # The fence is longer than any backtick run in the content, so the content can never close it
      # early and render as links or formatting the approver did not ask for.
      def excerpt(text, budget)
        text = text.to_s.chomp
        shown = text.length > budget ? "#{text[0, budget - 1]}…" : text
        fence = '`' * [3, (shown.scan(/`+/).map(&:length).max || 0) + 1].max
        "\n#{fence}\n#{shown}\n#{fence}"
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

      def outbox_capacity(surface) = surface.fetch('limits').fetch('outbox_capacity')
    end
  end
end

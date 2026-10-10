# frozen_string_literal: true

require 'time'
require 'json'

require_relative 'lifecycle'
require_relative 'outbox_approvals'

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
    class OutboxDeliverySink
      EVENT_KINDS = {
        'request.approved' => 'answer',
        'request.denied' => 'answer',
        'request.completed' => 'answer',
        'request.failed' => 'failed',
        'request.stopped' => 'stopped',
        'request.blocked' => 'blocked',
        'request.approval_request' => 'approval_request',
        'request.clarification_request' => 'clarification_request',
        'healing.escalated' => 'control',
        'request.notice' => 'notice'
      }.freeze

      # Kinds whose rows the admission reservation covers (design §12): the
      # request is finished once they are durable, so the reservation releases.
      TERMINAL_KINDS = %w[answer failed stopped blocked].freeze

      def initialize(adapter:, checkpoints:, rendering: Comms::Rendering)
        @store = adapter.bind_comms_store(checkpoints)
        @rendering = rendering
        @approvals = OutboxApprovals.new(store: @store, rendering:)
      end

      # @param event [Hash] `{thread_id:, kind:, text:, ...}` — the worker's
      #   lifecycle event.
      # @return [Symbol, nil] :accepted when at least one Delivery was
      #   appended durably; nil when the thread is unbound or the kind is not
      #   a deliverable lifecycle kind.
      def push(event)
        kind = EVENT_KINDS[event.fetch(:kind)]
        route = kind && @store.request_conversation(thread_id: event.fetch(:thread_id))
        surface = route && @store.surface(surface_id: route.fetch('surface_id'))
        return nil unless surface

        case kind
        when 'clarification_request' then push_clarification_question(event, route, surface)
        when 'notice' then push_notice(event, route, surface)
        when 'approval_request' then @approvals.push(event, route, surface)
        else push_rendered(event, route, surface, kind)
        end
      end

      private

      def push_rendered(event, route, surface, kind)
        append_rendered_parts(event, route, surface, render_parts(event, surface), kind:)
        reserved_request_id = event[:request_id] if TERMINAL_KINDS.include?(kind)
        complete_reserved_request(event, reserved_request_id, kind) if reserved_request_id
        :accepted
      end

      # A notice is shown on surfaces that speak, never settles the request, and is keyed by it.
      def push_notice(event, route, surface)
        return nil unless surface.fetch('rendering')['speech']

        part = render_parts(event, surface).first
        @store.append_delivery(rendered_delivery(event, route, part, 'control').wire,
                               surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
                               reserved_request_id: nil, now: Time.now.utc)
      end

      def append_rendered_parts(event, route, surface, parts, kind:)
        reserved_request_id = event[:request_id] if TERMINAL_KINDS.include?(kind)
        parts.each do |part|
          @store.append_delivery(
            rendered_delivery(event, route, part, kind).wire,
            surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
            reserved_request_id:, now: Time.now.utc
          )
        end
      end

      def render_parts(event, surface)
        limits = surface.fetch('rendering')
        @rendering.plain(event.fetch(:text).to_s,
                         max_parts: limits.fetch('max_parts'),
                         part_characters: limits.fetch('part_characters'),
                         overflow: limits.fetch('overflow'),
                         thread: event.fetch(:thread_id))
      end

      def rendered_delivery(event, route, part, kind)
        Comms::Delivery.build(
          conversation_id: route.fetch('conversation_id'), kind:,
          text: part.fetch('text'), part_index: part.fetch('part_index'),
          part_count: part.fetch('part_count'), journaled: kind != 'control',
          render_version: @rendering::RENDER_VERSION,
          content_digest: part.fetch('content_digest'), identity_key: event[:request_id]
        )
      end

      def complete_reserved_request(event, request_id, kind)
        @store.complete_request(thread_id: event.fetch(:thread_id), request_id:, settle_kind: kind)
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
          thread: event.fetch(:thread_id),
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
          'phase' => 'clarification_required', 'actions' => ['answer']
        )
      end

      def clarification_question(interrupts)
        descriptors = Array(interrupts).filter_map { |interrupt| interrupt[:descriptor] }
        descriptor = descriptors.find { |candidate| candidate['kind'] == 'clarify' }
        text = descriptor&.fetch('question', nil).to_s.gsub(/[[:cntrl:]]/, ' ').split.join(' ')
        text.empty? ? 'Please answer the question to continue.' : text
      end

      def outbox_capacity(surface)
        surface.fetch('limits').fetch('outbox_capacity')
      end
    end
  end
end

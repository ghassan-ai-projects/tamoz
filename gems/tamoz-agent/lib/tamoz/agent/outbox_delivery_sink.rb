# frozen_string_literal: true

require 'time'
require 'json'

require 'tamoz/comms'

module Tamoz
  module Agent
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
        'request.approval_request' => 'approval_request'
      }.freeze

      # Kinds whose rows the admission reservation covers (design §12): the
      # request is finished once they are durable, so the reservation releases.
      TERMINAL_KINDS = %w[answer failed stopped blocked].freeze

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

        if kind == 'approval_request'
          return nil unless surface.fetch('approvals').fetch('mode') == 'deny_only'

          return push_approval_prompt(event, route, surface)
        end

        rendering = surface.fetch('rendering')
        parts = @rendering.plain(event.fetch(:text).to_s,
                                 max_parts: rendering.fetch('max_parts'),
                                 part_characters: rendering.fetch('part_characters'),
                                 overflow: rendering.fetch('overflow'))
        reserved_request_id = event[:request_id] if TERMINAL_KINDS.include?(kind)
        parts.each do |part|
          @store.append_delivery(
            Comms::Delivery.build(
              conversation_id: route.fetch('conversation_id'), kind:,
              text: part.fetch('text'), part_index: part.fetch('part_index'),
              part_count: part.fetch('part_count'), journaled: kind != 'control',
              render_version: @rendering::RENDER_VERSION,
              content_digest: part.fetch('content_digest')
            ).wire,
            surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
            reserved_request_id:, now: Time.now.utc
          )
        end
        # The terminal projection is durable; its reservation returns to
        # intake (design §12, invariant 57).
        if reserved_request_id
          @store.complete_request(thread_id: event.fetch(:thread_id), request_id: reserved_request_id)
        end
        :accepted
      end

      private

      # v1 deny-only (ADR-043): a fresh single-use prompt is stored inactive,
      # and the control delivery's markup carries the plaintext reference so
      # the gateway can activate it after the send receipt is durable.
      def push_approval_prompt(event, route, surface)
        binding = @store.binding_by_conversation(surface_id: route.fetch('surface_id'),
                                                 conversation_id: route.fetch('conversation_id'))
        return nil unless binding

        reference, prompt = Comms::ApprovalPrompt.build(
          thread_id: event.fetch(:thread_id), occurrence_id: event.fetch(:request_id),
          interrupts: event.fetch(:interrupts),
          correspondent_id: binding.fetch('correspondent_id'),
          conversation_id: route.fetch('conversation_id'),
          prompt_ttl_s: surface.fetch('approvals').fetch('prompt_ttl_s')
        )
        @store.insert_prompt(prompt.wire)
        markup = JSON.generate('reference' => reference, 'actions' => %w[approve deny])
        @store.append_delivery(
          Comms::Delivery.build(
            conversation_id: route.fetch('conversation_id'), kind: 'approval_request',
            text: 'An action needs your approval.', part_index: 0, part_count: 1,
            journaled: true, render_version: @rendering::RENDER_VERSION,
            content_digest: @rendering.content_digest('approval_request'),
            identity_key: event.fetch(:request_id),
            markup:
          ).wire,
          surface_id: route.fetch('surface_id'), capacity: outbox_capacity(surface),
          reserved_request_id: event.fetch(:request_id), now: Time.now.utc
        )
        :accepted
      end

      def outbox_capacity(surface)
        surface.fetch('limits').fetch('outbox_capacity')
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

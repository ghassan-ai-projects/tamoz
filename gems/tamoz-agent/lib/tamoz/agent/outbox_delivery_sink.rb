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
    # database through the CommsStore.
    #
    # Unbound threads (no admission route) deliver nothing and return nil —
    # the worker is indistinguishable from one with a disabled surface.
    # Output is rendered with the deterministic splitter; multipart output is
    # one bounded Delivery per part.
    # The projection is one multi-step pipeline (route → surface → render →
    # append); the metric smells measure the pipeline, not a choice to
    # overload.
    # :reek:TooManyStatements, :reek:DuplicateMethodCall, :reek:UnusedParameters
    # :reek:DataClump
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- the projection pipeline.
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

      def initialize(adapter:, checkpoints:, surface_id:, capacity:, rendering: Comms::Rendering)
        @store = adapter.bind_comms_store(checkpoints)
        @surface_id = surface_id
        @capacity = capacity
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

        surface = @store.surface(surface_id: @surface_id)
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
        parts.each do |part|
          @store.append_delivery(
            Comms::Delivery.build(
              conversation_id: route.fetch('conversation_id'), kind:,
              text: part.fetch('text'), part_index: part.fetch('part_index'),
              part_count: part.fetch('part_count'), journaled: kind != 'control',
              render_version: @rendering::RENDER_VERSION,
              content_digest: part.fetch('content_digest')
            ).wire,
            surface_id: @surface_id, capacity: @capacity, now: Time.now.utc
          )
        end
        :accepted
      end

      private

      # v1 deny-only (ADR-043): a fresh single-use prompt is stored inactive,
      # and the control delivery's markup carries the plaintext reference so
      # the gateway can activate it after the send receipt is durable.
      def push_approval_prompt(event, route, surface)
        reference, prompt = Comms::ApprovalPrompt.build(
          thread_id: event.fetch(:thread_id), occurrence_id: event.fetch(:request_id),
          interrupts: event.fetch(:interrupts),
          correspondent_id: route.fetch('correspondent_id'),
          conversation_id: route.fetch('conversation_id'),
          prompt_ttl_s: surface.fetch('approvals').fetch('prompt_ttl_s')
        )
        @store.insert_prompt(prompt.wire)
        markup = JSON.generate('reference' => reference, 'action' => 'deny')
        @store.append_delivery(
          Comms::Delivery.build(
            conversation_id: route.fetch('conversation_id'), kind: 'approval_request',
            text: 'An action needs your approval.', part_index: 0, part_count: 1,
            journaled: true, render_version: @rendering::RENDER_VERSION,
            content_digest: @rendering.content_digest('approval_request'),
            markup:
          ).wire,
          surface_id: @surface_id, capacity: @capacity, now: Time.now.utc
        )
        :accepted
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/MethodLength

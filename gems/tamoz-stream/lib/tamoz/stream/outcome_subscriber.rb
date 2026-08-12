# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/errors"

module Tamoz
  module Stream
    # T5.1 (PLAN_TAMOZ_STREAM_BUILD T5.1): the Channel B consumer (PROTOCOL
    # §9). The stream's notification log is the durable source; SSE is one way
    # to read it. The subscriber owns the durability state machine, with the
    # transport injected (the live transport is the stream's SSE endpoint;
    # tests script a frame source):
    #
    #   resume        — from the stored cursor (Last-Event-ID), per-subscriber
    #                   credential, never another subscriber's cursor
    #   at-least-once — delivery is at-least-once; the subscriber deduplicates
    #                   on (source, CloudEvents id) and advances the cursor
    #                   only after successful dispatch
    #   cursor_expired— an explicit, audited RESNAPSHOT (§9.1); never a
    #                   silent reconnect
    #   poison events — a notification that cannot be processed is skipped
    #                   after a bounded retry count and recorded as
    #                   subscriber_skipped with the cursor and reason; one bad
    #                   event never wedges the subscription
    #   backpressure  — subscriber_too_slow disconnects the pass; the next
    #                   pass resumes from the last acknowledged cursor
    #
    # Frames carry the SSE cursor in `cursor`, the CloudEvents `type` in
    # `event`, and the CloudEvents JSON document in `data` (§9.2).
    class OutcomeSubscriber
      # One parsed notification.
      CloudEvent = Data.define(:id, :source, :type, :data, :time)

      class SubscriptionError < StreamError
        CATEGORY = "stream_outcome_subscription"
      end

      # cursor_store: read -> cursor String|nil; write(cursor)
      # handlers: { "io.agenticstream.<type>.v1" => ->(event) {} }
      # credential: the per-subscriber Channel B credential (distinct from
      #   the worker's capability token; never the same secret).
      def initialize(cursor_store:, handlers:, credential:, max_poison_retries: 3)
        unless cursor_store.respond_to?(:read) && cursor_store.respond_to?(:write)
          raise SubscriptionError, "cursor store must implement read and write"
        end
        unless handlers.is_a?(Hash) && handlers.values.all? { |h| h.respond_to?(:call) }
          raise SubscriptionError, "handlers must map event types to callables"
        end
        @cursor_store = cursor_store
        @handlers = handlers
        @credential = credential
        @max_poison_retries = max_poison_retries
        @dedupe = {}
        @poison = {}
        @skipped = []
        @resnapshots = []
        freeze
      end

      attr_reader :skipped, :resnapshots

      # Runs one pass over the transport's frames. The transport responds to
      # open(cursor:, credential:) returning an enumerator of frames
      # (each with :type :event/:control/:eof, :cursor, :event, :data,
      # :control) and resnapshot(cursor:, credential:) returning the fresh
      # cursor for the resnapshot boundary. A pass stops on poison retry
      # (redelivery next pass) or subscriber_too_slow (resume from the last
      # acknowledged cursor).
      def run(transport:)
        cursor = @cursor_store.read
        source = transport.open(cursor:, credential: @credential)
        source.each do |frame|
          case frame.type
          when :eof
            break
          when :control
            handle_control(frame, transport)
            break if frame.control == "subscriber_too_slow"
          when :event
            break unless handle_event(frame)
          end
        end
        self
      end

      private

      def handle_control(frame, transport)
        case frame.control
        when "cursor_expired"
          # §9.1: a resnapshot is explicit and audited — never an implicit
          # consequence of reconnecting.
          fresh = transport.resnapshot(cursor: frame.cursor, credential: @credential)
          @cursor_store.write(fresh)
          @resnapshots << {from: frame.cursor, to: fresh, at: Time.now.to_i}
        when "subscriber_too_slow"
          # Backpressure: the pass ends here; the next pass resumes from the
          # last acknowledged cursor. The stream never grows unbounded memory
          # for a slow reader.
          nil
        else
          raise SubscriptionError, "unknown Channel B control event #{frame.control.inspect}"
        end
      end

      # Returns false to end the pass (poison retry), true to continue.
      def handle_event(frame)
        event = parse_cloud_event(frame)
        key = [event.source, event.id]
        if @dedupe.key?(key)
          # A redelivered (source, id) is acknowledged — it was already
          # processed — and the cursor advances past it.
          @cursor_store.write(frame.cursor)
          return true
        end

        handler = @handlers[event.type]
        if handler.nil?
          # An unhandled type is acknowledged cleanly (the subscriber scope
          # has an event-type allowlist); it is never a poison event.
          @dedupe[key] = true
          @cursor_store.write(frame.cursor)
          return true
        end

        begin
          handler.call(event)
          @dedupe[key] = true
          @cursor_store.write(frame.cursor)
          @poison.delete(key)
          true
        rescue StandardError => error
          retry_count = (@poison[key] || 0) + 1
          if retry_count > @max_poison_retries
            @skipped << {
              cursor: frame.cursor, id: event.id, type: event.type,
              reason: "poison_after_#{@max_poison_retries}_retries: #{error.class}"
            }
            @dedupe[key] = true
            @cursor_store.write(frame.cursor)
            @poison.delete(key)
            true
          else
            @poison[key] = retry_count
            false
          end
        end
      end

      def parse_cloud_event(frame)
        document = frame.data.to_s.dup.force_encoding(Encoding::UTF_8)
        unless document.valid_encoding?
          raise SubscriptionError, "Channel B frame is not valid UTF-8"
        end

        value = Tamoz::Core.parse_json_strict(document)
        unless value.is_a?(Hash) &&
               value["id"].is_a?(String) && !value["id"].empty? &&
               value["source"].is_a?(String) && !value["source"].empty? &&
               value["type"].is_a?(String) && !value["type"].empty?
          raise SubscriptionError, "Channel B frame is not a well-formed CloudEvent"
        end

        CloudEvent.new(
          id: value.fetch("id"),
          source: value.fetch("source"),
          type: value.fetch("type"),
          data: value["data"],
          time: value["time"]
        )
      end
    end
  end
end

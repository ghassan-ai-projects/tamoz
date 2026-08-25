# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/errors"
require "tamoz/stream/notification_contract"

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
      CloudEvent = Data.define(:id, :source, :type, :data, :time, :traceparent, :tracestate, :envelope)

      class SubscriptionError < StreamError
        CATEGORY = "stream_outcome_subscription"
      end

      # cursor_store: read -> cursor String|nil; write(cursor)
      # Optional durable event methods: event_state(source:, event_id:,
      # payload_digest:) -> :new/:same/:conflict and mark_event(...).
      # handlers: { "io.agenticstream.<type>.v1" => ->(event) {} }
      # credential: the per-subscriber Channel B credential (distinct from
      #   the worker's capability token; never the same secret).
      MAX_FRAME_BYTES = 1 * 1024 * 1024
      MAX_DEDUPE_ENTRIES = 4096
      MAX_AUDIT_ENTRIES = 256

      def initialize(cursor_store:, handlers:, credential:, max_poison_retries: 3)
        require_cursor_store!(cursor_store)
        require_handlers!(handlers)
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

      def require_cursor_store!(store)
        return if store.respond_to?(:read) && store.respond_to?(:write)

        raise SubscriptionError, "cursor store must implement read and write"
      end

      def require_handlers!(handlers)
        return if handlers.is_a?(Hash) && handlers.values.all? { |h| h.respond_to?(:call) }

        raise SubscriptionError, "handlers must map event types to callables"
      end

      def handle_control(frame, transport)
        case frame.control
        when "cursor_expired"
          # §9.1: a resnapshot is explicit and audited — never an implicit
          # consequence of reconnecting.
          fresh = transport.resnapshot(cursor: frame.cursor, credential: @credential)
          @cursor_store.write(fresh)
          record_audit(@resnapshots, from: frame.cursor, to: fresh)
        when "subscriber_too_slow"
          # Backpressure: the pass ends here; the next pass resumes from the
          # last acknowledged cursor. The stream never grows unbounded memory
          # for a slow reader.
          nil
        else
          # An unknown control event is a protocol drift — recorded and
          # skipped, never a wedge: one bad frame does not halt the
          # subscription. The skip shape is uniform with the poison skips.
          record_audit(@skipped, cursor: frame.cursor, id: nil, type: nil,
                                 control: frame.control, reason: "unknown_control_event")
          @cursor_store.write(frame.cursor)
        end
      end

      # Returns false to end the pass (poison retry), true to continue.
      def handle_event(frame)
        key = ["frame", frame.cursor]
        bounded_frame_data!(frame)
        dispatch(parse_cloud_event(frame), frame)
      rescue StreamError => error
        handle_poison(frame, key:, reason: error.message)
      end

      def bounded_frame_data!(frame)
        data = frame.data.to_s
        raise SubscriptionError, "frame exceeds #{MAX_FRAME_BYTES} bytes" if data.bytesize > MAX_FRAME_BYTES

        data
      end

      def dispatch(event, frame)
        key = [event.source, event.id]
        validate_notification!(event)
        delivery_state = durable_event_state(event)
        refuse_payload_conflict!(delivery_state)
        return true if acknowledge_in_memory_duplicate!(frame, key)
        return true if acknowledge_durable_duplicate!(delivery_state, frame, key)

        handler = @handlers[event.type]
        return acknowledge_unhandled_type!(event, frame, key) if handler.nil?

        deliver_to_handler(handler, event, frame, key)
      end

      def validate_notification!(event)
        NotificationContract.validate!(event) if NotificationContract.known_family?(event.type)
      end

      def refuse_payload_conflict!(delivery_state)
        return unless delivery_state == :conflict

        raise SubscriptionError, "notification id was redelivered with a different payload"
      end

      # A redelivered (source, id) is acknowledged — it was already
      # processed — and the cursor advances past it.
      def acknowledge_in_memory_duplicate!(frame, key)
        return false unless @dedupe.key?(key)

        @cursor_store.write(frame.cursor)
        true
      end

      def acknowledge_durable_duplicate!(delivery_state, frame, key)
        return false unless delivery_state == :same

        remember(key)
        @cursor_store.write(frame.cursor)
        true
      end

      # An unhandled type is acknowledged cleanly (the subscriber scope
      # has an event-type allowlist); it is never a poison event. But a
      # known family with an unsupported version is protocol drift —
      # refused, not ignored.
      def acknowledge_unhandled_type!(event, frame, key)
        refuse_unsupported_version!(event)
        remember(key)
        @cursor_store.write(frame.cursor)
        true
      end

      def refuse_unsupported_version!(event)
        return unless NotificationContract.known_family?(event.type) &&
                      !NotificationContract.supported_type?(event.type)

        raise SubscriptionError, "unsupported version for known notification #{event.type}"
      end

      def deliver_to_handler(handler, event, frame, key)
        handler.call(event)
        mark_durable_event(event)
        remember(key)
        @cursor_store.write(frame.cursor)
        @poison.delete(key)
        true
      rescue StandardError => error
        handle_poison(frame, key:, reason: "handler_error: #{error.class}")
      end

      def durable_event_state(event)
        return :new unless @cursor_store.respond_to?(:event_state)

        @cursor_store.event_state(
          source: event.source,
          event_id: event.id,
          payload_digest: notification_digest(event)
        )
      end

      def mark_durable_event(event)
        return unless @cursor_store.respond_to?(:mark_event)

        @cursor_store.mark_event(
          source: event.source,
          event_id: event.id,
          payload_digest: notification_digest(event),
          traceparent: event.traceparent,
          tracestate: event.tracestate
        )
      end

      def notification_digest(event)
        Tamoz::Core.digest("tamoz/stream/notification/v1\n", event.envelope)
      end

      def handle_poison(frame, key:, reason:)
        retry_count = (@poison[key] || 0) + 1
        if retry_count > @max_poison_retries
          record_audit(@skipped, cursor: frame.cursor, id: key.last,
                                 type: frame.event, control: nil,
                                 reason: "poison_after_#{@max_poison_retries}_retries: #{reason}")
          remember(key)
          @cursor_store.write(frame.cursor)
          @poison.delete(key)
          true
        else
          @poison[key] = retry_count
          false
        end
      end

      # Bounded retention: the in-memory dedupe covers within-pass
      # duplicates (the cursor is the durable at-least-once guarantee), and
      # the audit lists are rings — a long-lived subscription never grows
      # unbounded memory.
      def remember(key)
        @dedupe.shift if @dedupe.length >= MAX_DEDUPE_ENTRIES
        @dedupe[key] = true
      end

      def record_audit(list, **entry)
        list << entry
        list.shift if list.length > MAX_AUDIT_ENTRIES
      end

      def parse_cloud_event(frame)
        document = utf8_frame_document(frame)
        value = Tamoz::Core.parse_json_strict(document)
        ensure_cloud_envelope_shape!(value)

        CloudEvent.new(
          id: value.fetch("id"),
          source: value.fetch("source"),
          type: value.fetch("type"),
          data: value["data"],
          time: value["time"],
          traceparent: value["traceparent"],
          tracestate: value["tracestate"],
          envelope: value.freeze
        )
      end

      def utf8_frame_document(frame)
        document = frame.data.to_s.dup.force_encoding(Encoding::UTF_8)
        unless document.valid_encoding?
          raise SubscriptionError, "Channel B frame is not valid UTF-8"
        end

        document
      end

      def ensure_cloud_envelope_shape!(value)
        well_formed = value.is_a?(Hash) &&
                      value["id"].is_a?(String) && !value["id"].empty? &&
                      value["source"].is_a?(String) && !value["source"].empty? &&
                      value["type"].is_a?(String) && !value["type"].empty?
        return if well_formed

        raise SubscriptionError, "Channel B frame is not a well-formed CloudEvent"
      end
    end
  end
end

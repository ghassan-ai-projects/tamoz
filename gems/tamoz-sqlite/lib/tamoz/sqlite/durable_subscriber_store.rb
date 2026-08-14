# frozen_string_literal: true

require "digest"

module Tamoz
  module SQLite
    class DurableSubscriberStore
      NAMESPACE_PREFIX = "tamoz.stream.subscriber"

      def initialize(adapter:, tenant:)
        @store = adapter.store
        @tenant = text!(tenant, "tenant")
        @namespace = "#{NAMESPACE_PREFIX}.#{@tenant}".freeze
      end

      def read
        value("cursor")&.fetch("cursor")
      end

      def write(cursor)
        put("cursor", {"cursor" => cursor})
      end

      def admitted?(intent_id)
        !value(admission_key(intent_id)).nil?
      end

      def mark_admitted(intent_id)
        key = admission_key(intent_id)
        return if admitted?(intent_id)

        put(key, {"intent_id" => intent_id})
      rescue Tamoz::StoreConflictError
        raise unless admitted?(intent_id)
      end

      def event_state(source:, event_id:, payload_digest:)
        stored = value(event_key(source, event_id))
        return :new unless stored

        stored.fetch("payload_digest") == payload_digest ? :same : :conflict
      end

      def mark_event(source:, event_id:, payload_digest:, traceparent: nil, tracestate: nil)
        key = event_key(source, event_id)
        return if event_state(source:, event_id:, payload_digest:) == :same
        if event_state(source:, event_id:, payload_digest:) == :conflict
          raise Tamoz::StoreConflictError, "notification payload conflicts with its durable event id"
        end

        put(
          key,
          {
            "source" => source,
            "event_id" => event_id,
            "payload_digest" => payload_digest,
            "traceparent" => traceparent,
            "tracestate" => tracestate
          }
        )
      rescue Tamoz::StoreConflictError
        raise unless event_state(source:, event_id:, payload_digest:) == :same
      end

      private

      def value(key)
        entry = @store.get(@namespace, key)
        entry&.value
      end

      def put(key, value)
        version = @store.head_version(@namespace, key)
        @store.put(@namespace, key, value, if_version: version)
      end

      def admission_key(intent_id)
        "admitted/#{Digest::SHA256.hexdigest(intent_id.to_s)}"
      end

      def event_key(source, event_id)
        "events/#{Digest::SHA256.hexdigest("#{source}\u0000#{event_id}")}"
      end

      def text!(value, name)
        text = String(value)
        raise ArgumentError, "#{name} is required" if text.empty?

        text
      rescue TypeError
        raise ArgumentError, "#{name} is required"
      end
    end
  end
end

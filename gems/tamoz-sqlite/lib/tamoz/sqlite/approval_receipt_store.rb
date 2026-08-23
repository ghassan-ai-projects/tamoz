# frozen_string_literal: true

require "tamoz/core"

module Tamoz
  module SQLite
    class ApprovalReceiptStore
      NAMESPACE_PREFIX = "tamoz.stream.approvals"
      STATES = %w[requested withdrawn resolved].freeze

      def initialize(adapter:, tenant:, clock: -> { Time.now })
        @store = adapter.store
        @tenant = text!(tenant, "tenant")
        @namespace = "#{NAMESPACE_PREFIX}.#{@tenant}".freeze
        @clock = clock
      end

      # An expired receipt IS an absent receipt (fail closed): every state
      # read goes through here, so a lapsed approval re-asks instead of
      # resolving.
      def fetch(approval_id)
        current = value(key(approval_id))
        return nil if current && expired?(current)

        current
      end

      def reserve_requested(approval_id:, tenant_id:, payload_digest:, identity:, traceparent: nil, tracestate: nil, ttl_s: nil)
        unless tenant_id == @tenant
          raise Tamoz::StoreConflictError, "approval tenant does not match"
        end
        existing = fetch(approval_id)
        if existing
          return false if existing.fetch("payload_digest") == payload_digest

          raise Tamoz::StoreConflictError, "approval payload conflicts with its durable id"
        end

        put(
          key(approval_id),
          {
            "approval_id" => approval_id,
            "tenant_id" => tenant_id,
            "identity" => identity.transform_keys(&:to_s),
            "state" => "requested",
            "payload_digest" => payload_digest,
            "delivery_receipt" => nil,
            "delivery_claimed" => false,
            "last_event_digest" => payload_digest,
            "traceparent" => traceparent,
            "tracestate" => tracestate,
            "expires_at" => ttl_s ? now + ttl_s : nil
          }
        )
        true
      rescue Tamoz::StoreConflictError
        raise unless fetch(approval_id)&.fetch("payload_digest") == payload_digest

        false
      end

      def record_delivery(approval_id:, receipt:)
        current = fetch!(approval_id)
        unless current.fetch("state") == "requested" && current.fetch("delivery_claimed") == true
          raise Tamoz::StoreConflictError, "approval is not awaiting delivery"
        end

        replace(
          approval_id,
          current.merge("delivery_receipt" => receipt, "delivery_claimed" => false)
        )
      end

      def claim_delivery(approval_id:)
        3.times do
          current = fetch!(approval_id)
          return :delivered if current.fetch("delivery_receipt")
          return :terminal unless current.fetch("state") == "requested"
          return :busy if current.fetch("delivery_claimed")

          begin
            replace(approval_id, current.merge("delivery_claimed" => true))
            return :claimed
          rescue Tamoz::StoreConflictError
            next
          end
        end
        :busy
      end

      def release_delivery(approval_id:)
        current = fetch!(approval_id)
        return if current.fetch("delivery_receipt") || !current.fetch("delivery_claimed")

        replace(approval_id, current.merge("delivery_claimed" => false))
      end

      def transition(approval_id:, tenant_id:, state:, event_digest:, identity:)
        unless STATES.include?(state.to_s) && state.to_s != "requested"
          raise Tamoz::StoreConflictError, "unsupported approval transition"
        end
        current = fetch!(approval_id)
        raise Tamoz::StoreConflictError, "approval tenant does not match" unless
          current.fetch("tenant_id") == tenant_id
        identity.each do |key, value|
          unless current.fetch("identity").fetch(key.to_s) == value
            raise Tamoz::StoreConflictError, "approval identity does not match"
          end
        end
        return current if current.fetch("last_event_digest") == event_digest
        unless current.fetch("state") == "requested"
          raise Tamoz::StoreConflictError, "approval transition is not allowed"
        end

        replace(
          approval_id,
          current.merge("state" => state.to_s, "last_event_digest" => event_digest)
        )
      end

      private

      def fetch!(approval_id)
        fetch(approval_id) || raise(Tamoz::StoreConflictError, "unknown approval #{approval_id}")
      end

      def expired?(current)
        expires_at = current["expires_at"]
        return false unless expires_at

        now >= expires_at
      end

      def now
        @clock.call.to_i
      end

      def value(storage_key)
        entry = @store.get(@namespace, storage_key)
        entry&.value
      end

      def put(storage_key, value)
        @store.put(@namespace, storage_key, value, if_version: @store.head_version(@namespace, storage_key))
      end

      def replace(approval_id, value)
        storage_key = key(approval_id)
        @store.put(@namespace, storage_key, value, if_version: @store.head_version(@namespace, storage_key))
      end

      def key(approval_id)
        "approval/#{Tamoz::Core.digest("tamoz/stream/approval-id/v1\n", approval_id.to_s)}"
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

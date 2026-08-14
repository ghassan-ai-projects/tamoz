# frozen_string_literal: true

require "tamoz/core"

module Tamoz
  module SQLite
    class ApprovalReceiptStore
      NAMESPACE_PREFIX = "tamoz.stream.approvals"
      STATES = %w[requested withdrawn resolved].freeze

      def initialize(adapter:, tenant:)
        @store = adapter.store
        @tenant = text!(tenant, "tenant")
        @namespace = "#{NAMESPACE_PREFIX}.#{@tenant}".freeze
      end

      def fetch(approval_id)
        value(key(approval_id))
      end

      def reserve_requested(approval_id:, tenant_id:, payload_digest:, identity:, traceparent: nil, tracestate: nil)
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
            "tracestate" => tracestate
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
        "approval/#{Tamoz::Core.digest("tamoz.stream.approval_id", approval_id.to_s)}"
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

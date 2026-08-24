# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/notification_contract"

module Tamoz
  module Stream
    class LiveLearningHandlers
      RECORDED = "io.agenticstream.outcome.recorded.v1"
      RECONCILED = "io.agenticstream.outcome.reconciled.v1"
      APPROVAL_REQUESTED = "io.agenticstream.approval.requested.v1"
      APPROVAL_WITHDRAWN = "io.agenticstream.approval.withdrawn.v1"
      APPROVAL_RESOLVED = "io.agenticstream.approval.resolved.v1"

      def initialize(verification:, memory:, durable:, tenant:, logger:,
                     approval_receipts: nil, approval_relay: nil,
                     conversation_id: nil, approval_ttl_s: nil)
        @verification = verification
        @memory = memory
        @durable = durable
        @tenant = String(tenant)
        @logger = logger
        @approval_receipts = approval_receipts
        @approval_relay = approval_relay
        @conversation_id = conversation_id
        @approval_ttl_s = approval_ttl_s
      end

      def callables
        {
          RECORDED => ->(event) { validate_and_call(event, :record_outcome) },
          RECONCILED => ->(event) { validate_and_call(event, :reconcile_outcome) },
          APPROVAL_REQUESTED => ->(event) { validate_and_call(event, :request_approval) },
          APPROVAL_WITHDRAWN => ->(event) { validate_and_call(event, :withdraw_approval) },
          APPROVAL_RESOLVED => ->(event) { validate_and_call(event, :resolve_approval) }
        }
      end

      private

      def validate_and_call(event, handler)
        NotificationContract.validate!(event)
        send(handler, event)
      end

      def record_outcome(event)
        data = tenant_data(event)
        unless data.fetch("reconciliation_status") == "observed"
          raise StreamError, "outcome.recorded must be observed before verification mutation"
        end
        @verification.record_outcome(
          tenant_id: @tenant,
          intent_id: data.fetch("intent_id"),
          outcome_id: data.fetch("outcome_id"),
          outcome_digest: data.fetch("outcome_digest"),
          command_id: data.fetch("command_id")
        )
        @logger.info("outcome recorded intent=#{data.fetch("intent_id")}")
      end

      def reconcile_outcome(event)
        data = tenant_data(event)
        unless data.fetch("reconciliation_status") == "reconciled"
          raise StreamError, "outcome.reconciled must be reconciled before admission"
        end
        intent_id = data.fetch("intent_id")
        @verification.reconcile(
          tenant_id: @tenant,
          intent_id:,
          command_id: data.fetch("command_id"),
          outcome_id: data.fetch("outcome_id"),
          outcome_digest: data.fetch("outcome_digest"),
          verdict: data.fetch("verdict"),
          reconciliation_version: data.fetch("reconciliation_version"),
          source_authority: data.fetch("source_authority")
        )
        admit_learnable_episode(data, event, intent_id)
      end

      def admit_learnable_episode(data, event, intent_id)
        row = @verification.fetch(tenant_id: @tenant, intent_id:)
        return log_unlearnable(intent_id) unless row.learnable?
        return log_duplicate(intent_id) if @durable.admitted?(intent_id)

        admit_episode(row, data, event, intent_id)
      end

      def admit_episode(row, data, event, intent_id)
        result = @memory.admission.admit_episode(
          episode: learnable_episode(row, data),
          owner: "stream",
          reconciled_outcome: @verification.reference(tenant_id: @tenant, intent_id:),
          verify_source_authority: ->(reference) { reference.fetch("source_authority") == event.source }
        )
        handle_admission_result(result, intent_id)
      end

      def learnable_episode(row, data)
        row.episode.transform_keys(&:to_sym).merge(
          sensitivity: row.episode.fetch("sensitivity").to_sym,
          observed_outcome: observed_outcome(data)
        )
      end

      def handle_admission_result(result, intent_id)
        unless result.accepted?
          return handle_duplicate_admission(intent_id) if result.reason == "duplicate_identity"

          raise StreamError, "experience admission rejected: #{result.reason}"
        end

        @durable.mark_admitted(intent_id)
        @logger.info(
          "experience admitted intent=#{intent_id} memory_id=#{result.record.memory_id} " \
          "epistemic_kind=#{result.record.epistemic_kind}"
        )
      end

      def request_approval(event)
        require_approval_ports!
        data = tenant_data(event)
        approval_id = data.fetch("approval_id")
        digest = Tamoz::Core.digest("tamoz/stream/approval-request/v1\n", data)
        @approval_receipts.reserve_requested(
          approval_id:, tenant_id: @tenant, payload_digest: digest,
          identity: approval_identity(data),
          traceparent: event.traceparent, tracestate: event.tracestate,
          ttl_s: @approval_ttl_s
        )
        claim = @approval_receipts.claim_delivery(approval_id:)
        deliver_claimed_approval(approval_id:, approval: data) if claim == :claimed
      end

      # A claimed delivery that fails releases the claim so a redelivered
      # notification can retry it.
      def deliver_claimed_approval(approval_id:, approval:)
        receipt = @approval_relay.deliver(
          approval:, conversation_id: resolved_conversation_id(approval)
        )
        @approval_receipts.record_delivery(approval_id:, receipt:)
      rescue StandardError
        @approval_receipts.release_delivery(approval_id:)
        raise
      end

      def resolved_conversation_id(approval)
        @conversation_id.respond_to?(:call) ? @conversation_id.call(approval) : @conversation_id
      end

      def withdraw_approval(event)
        require_approval_ports!
        data = tenant_data(event)
        approval_id = data.fetch("approval_id")
        event_digest = Tamoz::Core.digest("tamoz/stream/approval-withdraw/v1\n", data)
        receipt = @approval_receipts.fetch(approval_id)
        raise StreamError, "approval delivery receipt is missing" unless receipt&.fetch("delivery_receipt")
        return if receipt.fetch("state") == "withdrawn" && receipt.fetch("last_event_digest") == event_digest

        message_id = receipt.fetch("delivery_receipt").fetch("message_id")
        @approval_relay.withdraw(message_id:)
        @approval_receipts.transition(
          approval_id:, tenant_id: @tenant, state: "withdrawn", event_digest:,
          identity: approval_identity(data)
        )
      end

      def resolve_approval(event)
        data = tenant_data(event)
        require_approval_ports!
        approval_id = data.fetch("approval_id")
        event_digest = Tamoz::Core.digest("tamoz/stream/approval-resolve/v1\n", data)
        @approval_receipts.transition(
          approval_id:, tenant_id: @tenant, state: "resolved", event_digest:,
          identity: approval_identity(data)
        )
      end

      def tenant_data(event)
        data = event.data
        raise StreamError, "notification tenant does not match subscriber" unless data.fetch("tenant_id") == @tenant

        data
      end

      def require_approval_ports!
        return if @approval_receipts && @approval_relay

        raise StreamError, "approval notifications require durable receipts and an injected relay"
      end

      def approval_identity(data)
        %w[intent_id decision_id situation_id situation_version].each_with_object({}) do |key, identity|
          identity[key] = data.fetch(key) if data.key?(key)
        end
      end

      def observed_outcome(data)
        {"outcome" => data.fetch("final_status")}
      end

      def handle_duplicate_admission(intent_id)
        @durable.mark_admitted(intent_id)
        log_duplicate(intent_id)
      end

      def log_unlearnable(intent_id)
        @logger.info("outcome reconciled but not learnable intent=#{intent_id}")
      end

      def log_duplicate(intent_id)
        @logger.info("experience already admitted intent=#{intent_id}")
      end
    end
  end
end

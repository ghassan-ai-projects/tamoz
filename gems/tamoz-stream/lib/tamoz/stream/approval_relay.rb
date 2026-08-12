# frozen_string_literal: true

require "securerandom"
require "tamoz/core"
require "tamoz/stream/errors"

module Tamoz
  module Stream
    # T7.2 (PLAN_TAMOZ_STREAM_BUILD T7.2): the Channel B/C approval bridge.
    # Approval AUTHORITY stays in the stream — the stream classifies R2,
    # creates the request, and revalidates everything on the answer
    # (PROTOCOL §5). Approval DELIVERY moves to Tamoz: the relay renders and
    # delivers the prompt on the bound channel, edits it in place when the
    # stream withdraws it, submits the human's answer to Channel C, and owns
    # escalation. A relayed approval never bypasses the stream's revalidation
    # — the answer is an input to policy, never a substitute for it.
    #
    # Separation of duty (PROTOCOL §5.2): the submission carries TWO
    # identities — the relaying service (relay_id) and the asserted human
    # approver (approver_id), always different. The stream trusts Tamoz to
    # assert WHO answered, and trusts nothing else it says.
    #
    # The assertion (PROTOCOL §10) binds all eleven fields under the domain
    # situation-runtime/approval-assertion/v1, with a durable single-use
    # nonce — a repeated nonce is REFUSED, never idempotently accepted, and
    # an Idempotency-Key (NOT the nonce) covers transport retries.
    #
    # The gem boundary: tamoz-stream does not depend on tamoz-comms — the
    # channel delivery and the Channel C submission are injected ports. The
    # signer is injected too: key custody and rotation are an owner decision
    # (plan §5), and the relay never sees the private key material.
    class ApprovalRelay
      ASSERTION_DOMAIN = "situation-runtime/approval-assertion/v1\n"
      ASSERTION_FIELDS = %w[
        approver_id tenant_id approval_id intent_digest snapshot_digest
        decision expires_at nonce audience relay_id key_id
      ].freeze
      DECISIONS = %w[approve deny].freeze
      MAX_ID_BYTES = 512
      MAX_DIGEST_BYTES = 128

      class ApprovalRelayError < StreamError
        CATEGORY = "stream_approval_relay"
      end

      # delivery:  deliver(conversation_id:, kind:, text:, reply_to:) -> receipt;
      #             edit_in_place(message_id:, text:)
      # submission: submit(approval_id:, decision:, reason:, idempotency_key:, assertion:)
      # nonce_store: claim(nonce) -> true when first seen, false on replay
      # signer:     key_id; sign(canonical_bytes) -> signature hex
      def initialize(delivery:, submission:, nonce_store:, signer:, relay_id:, clock: -> { Time.now })
        unless delivery.respond_to?(:deliver) && delivery.respond_to?(:edit_in_place)
          raise ApprovalRelayError, "approval delivery must implement deliver and edit_in_place"
        end
        unless submission.respond_to?(:submit)
          raise ApprovalRelayError, "approval submission must implement submit"
        end
        unless nonce_store.respond_to?(:claim)
          raise ApprovalRelayError, "approval nonce store must implement claim"
        end
        unless signer.respond_to?(:sign) && signer.respond_to?(:key_id)
          raise ApprovalRelayError, "approval signer must implement sign and key_id"
        end
        @delivery = delivery
        @submission = submission
        @nonce_store = nonce_store
        @signer = signer
        @relay_id = bounded!(relay_id, "relay_id")
        @clock = clock
        freeze
      end

      attr_reader :relay_id

      # PROTOCOL §5.1.3: the prompt carries the Situation summary, the delta
      # since the last reasoned version, the hypothesis, the evidence, what
      # the action does, and what happens if declined — all six are REQUIRED,
      # so a malformed approval is refused instead of delivered as a
      # convincing but empty prompt. Returns the delivery receipt (the durable
      # handle for edit-in-place and audit).
      def deliver(approval:, conversation_id:)
        approval = stringify(approval)
        require_field!(approval, "approval_id")
        require_field!(approval, "situation_id")
        %w[summary delta hypothesis evidence action decline_consequence].each do |field|
          require_field!(approval, field)
        end
        @delivery.deliver(
          conversation_id:,
          kind: "approval_request",
          reply_to: nil,
          text: render_prompt(approval)
        )
      end

      # PROTOCOL §5.3: on approval.withdrawn the delivered prompt is edited in
      # place so the technician does not act on a stale condition. Correctness
      # lives in the refusal path (the stream refuses a stale approval); the
      # edit is UX — the design remains correct when it fails.
      def withdraw(message_id:)
        @delivery.edit_in_place(
          message_id:,
          text: "Situation changed — this approval request is withdrawn. No answer is needed."
        )
      end

      # PROTOCOL §5.1.5/§10: submits the human's answer. The assertion binds
      # the eleven fields under the shared domain; the nonce is durable and
      # single-use (a replayed assertion is refused, not idempotently
      # accepted); the transport retry carries a SEPARATE Idempotency-Key so
      # the stream deduplicates retries without weakening the nonce.
      def submit_decision(approval:, approver_id:, decision:, reason: nil)
        approval = stringify(approval)
        unless DECISIONS.include?(decision.to_s)
          raise ApprovalRelayError, "approval decision must be approve or deny"
        end
        approver_id = bounded!(approver_id, "approver_id")
        if approver_id == @relay_id
          raise ApprovalRelayError,
                "the relaying service may never be the asserted approver"
        end
        # Fail closed on an expired approval: the stream revalidates too, but
        # a signed answer for an approval that already lapsed must not leave
        # the relay at all.
        expires_at = require_field!(approval, "expires_at")
        if @clock.call.to_i > expiry_epoch(expires_at)
          raise ApprovalRelayError, "approval #{approval.fetch("approval_id")} has expired"
        end

        nonce = SecureRandom.uuid
        unless @nonce_store.claim(nonce)
          raise ApprovalRelayError, "approval nonce replay refused"
        end

        assertion = {
          "approver_id" => approver_id,
          "tenant_id" => require_field!(approval, "tenant_id"),
          "approval_id" => require_field!(approval, "approval_id"),
          "intent_digest" => require_digest!(approval, "intent_digest"),
          "snapshot_digest" => require_digest!(approval, "snapshot_digest"),
          "decision" => decision.to_s,
          "expires_at" => expires_at,
          "nonce" => nonce,
          "audience" => require_field!(approval, "audience"),
          "relay_id" => @relay_id,
          "key_id" => @signer.key_id
        }
        signed = @signer.sign(ASSERTION_DOMAIN + Tamoz::Core.jcs(assertion))

        @submission.submit(
          approval_id: assertion.fetch("approval_id"),
          decision: assertion.fetch("decision"),
          reason: reason.to_s.byteslice(0, 1024),
          idempotency_key: idempotency_key(assertion, reason),
          assertion: assertion.merge("signature" => signed)
        )
      end

      # PROTOCOL §5.4: escalation belongs to Tamoz — who to ask next, after
      # how long, on which channel. The roster is Tamoz's own; the function is
      # deterministic: the entry after the current approver in roster order,
      # or the first entry when the current approver is not in the roster, or
      # nil when the roster is spent (the stream owns the deadline).
      def escalate(roster:, current_approver: nil)
        entries = roster.map do |entry|
          raise ApprovalRelayError, "escalation roster entries must be objects" unless entry.is_a?(Hash)

          entry.transform_keys(&:to_s)
        end
        index = entries.index { |entry| entry.fetch("approver_id") == current_approver }
        candidate = index ? entries[index + 1] : entries.first
        return nil unless candidate

        {
          "approver_id" => candidate.fetch("approver_id"),
          "channel" => candidate.fetch("channel", "telegram"),
          "after_seconds" => candidate.fetch("after_seconds", 0),
          "approval_id" => candidate["approval_id"]
        }.compact
      end

      private

      def render_prompt(approval)
        [
          "Approval requested for #{approval.fetch("situation_id")}",
          "Summary: #{field(approval, "summary")}",
          "Delta: #{field(approval, "delta")}",
          "Hypothesis: #{field(approval, "hypothesis")}",
          "Evidence: #{field(approval, "evidence")}",
          "Action: #{field(approval, "action")}",
          "If declined: #{field(approval, "decline_consequence")}",
          "Expires: #{field(approval, "expires_at")}"
        ].join("\n").byteslice(0, 4096)
      end

      def field(approval, key)
        String(approval[key].to_s).byteslice(0, 1024)
      end

      def require_field!(approval, key)
        value = approval[key]
        if value.nil? || value.to_s.empty? || value.to_s.bytesize > MAX_ID_BYTES
          raise ApprovalRelayError, "#{key} is required and bounded"
        end

        value.to_s
      end

      def require_digest!(approval, key)
        value = approval[key].to_s
        unless value.match?(/\Asha256:[0-9a-f]{64}\z/)
          raise ApprovalRelayError, "#{key} must be a sha256: hex digest"
        end

        value
      end

      def expiry_epoch(iso8601)
        Time.iso8601(iso8601).to_i
      rescue ArgumentError
        raise ApprovalRelayError, "expires_at must be an ISO-8601 timestamp"
      end

      def bounded!(value, name)
        text = value.to_s
        if text.empty? || text.bytesize > MAX_ID_BYTES
          raise ApprovalRelayError, "#{name} must be a bounded string"
        end

        text
      end

      # Idempotent transport retries are keyed on the DECISION and its reason,
      # not the nonce: a retry of the same answer deduplicates; a replayed
      # assertion (new nonce) is refused by the stream. Two distinct answers
      # to the same approval never collide on the key.
      def idempotency_key(assertion, reason)
        keyed = assertion.reject { |key, _| key == "nonce" }
        unless reason.nil? || reason.to_s.empty?
          keyed = keyed.merge(
            "reason_digest" => Tamoz::Core.digest(
              "situation-runtime/approval-submission/v1\n",
              {"reason" => reason.to_s}
            )
          )
        end
        Tamoz::Core.digest("situation-runtime/approval-submission/v1\n", keyed)
      end

      def stringify(hash)
        raise ApprovalRelayError, "approval must be an object" unless hash.is_a?(Hash)

        hash.transform_keys(&:to_s)
      end
    end
  end
end

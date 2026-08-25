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
      SUBMISSION_DOMAIN = "situation-runtime/approval-submission/v1\n"
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
      # approval_state: optional durable receipt port — fetch(approval_id) ->
      #             row Hash | nil; the row carries "state"
      #             (requested|withdrawn|resolved) and "expires_at". The
      #             implementing store stamps "expires_at" from an integer
      #             TTL injected at subscriber boot and reads an expired
      #             receipt as ABSENT (nil): a lapsed approval re-asks instead
      #             of resolving. Expiry therefore fails closed twice — here,
      #             via the absent or non-requested row, and again below when
      #             the payload's own expires_at has passed. The TTL is a
      #             plain integer like every other injected dependency;
      #             tamoz-stream loads no policy documents and gains no comms
      #             dependency.
      def initialize(delivery:, submission:, nonce_store:, signer:, relay_id:,
                     approval_state: nil, clock: -> { Time.now })
        validate_port!(delivery, %i[deliver edit_in_place], "approval delivery")
        validate_port!(submission, %i[submit], "approval submission")
        validate_port!(nonce_store, %i[claim], "approval nonce store")
        validate_port!(signer, %i[sign key_id], "approval signer")
        validate_optional_port!(approval_state, %i[fetch], "approval state")
        @delivery = delivery
        @submission = submission
        @nonce_store = nonce_store
        @signer = signer
        @relay_id = bounded!(relay_id, "relay_id")
        @approval_state = approval_state
        @clock = clock
        freeze
      end

      attr_reader :relay_id

      # PROTOCOL §5.1.3: the prompt carries the Situation summary, the delta
      # since the last reasoned version, the hypothesis, the evidence, what
      # the action does, and what happens if declined — all six are REQUIRED.
      # Evidence must be present as an array, but may legitimately be empty.
      # Returns the delivery receipt (the durable handle for edit-in-place and
      # audit).
      def deliver(approval:, conversation_id:)
        approval = stringify(approval)
        require_field!(approval, "approval_id")
        require_field!(approval, "situation_id")
        require_prompt_fields!(approval)
        require_evidence!(approval)
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
        approval_id = require_field!(approval, "approval_id")
        assert_actionable!(approval_id)
        assert_valid_decision!(decision)
        approver_id = bounded!(approver_id, "approver_id")
        assert_approver_not_relay!(approver_id)
        assert_not_expired!(approval, approval_id)
        nonce = claim_nonce!
        assertion = build_assertion(approval, approver_id, decision, nonce)
        submit_assertion(assertion, reason)
      end

      # PROTOCOL §5.4: escalation belongs to Tamoz — who to ask next, after
      # how long, on which channel. The roster is Tamoz's own; the function is
      # deterministic: the entry after the current approver in roster order,
      # or the first entry when the current approver is not in the roster, or
      # nil when the roster is spent (the stream owns the deadline).
      def escalate(roster:, current_approver: nil)
        entries = normalize_roster_entries(roster)
        candidate = next_candidate(entries, current_approver)
        return nil unless candidate

        escalation_payload(candidate)
      end

      private

      def validate_port!(port, methods, role)
        missing = methods.reject { |method| port.respond_to?(method) }
        return if missing.empty?

        raise ApprovalRelayError,
              "#{role} must implement #{missing.join(", ")}"
      end

      def validate_optional_port!(port, methods, role)
        return if port.nil?

        validate_port!(port, methods, role)
      end

      def assert_actionable!(approval_id)
        return unless @approval_state

        row = @approval_state.fetch(approval_id)
        return if row&.fetch("state") == "requested"

        raise ApprovalRelayError, "approval is no longer actionable"
      end

      def assert_valid_decision!(decision)
        return if DECISIONS.include?(decision.to_s)

        raise ApprovalRelayError, "approval decision must be approve or deny"
      end

      def assert_approver_not_relay!(approver_id)
        return unless approver_id == @relay_id

        raise ApprovalRelayError,
              "the relaying service may never be the asserted approver"
      end

      def assert_not_expired!(approval, approval_id)
        # Fail closed on an expired approval: the stream revalidates too, but
        # a signed answer for an approval that already lapsed must not leave
        # the relay at all.
        expires_at = require_field!(approval, "expires_at")
        return unless @clock.call.to_i > expiry_epoch(expires_at)

        raise ApprovalRelayError, "approval #{approval_id} has expired"
      end

      def claim_nonce!
        nonce = SecureRandom.uuid
        return nonce if @nonce_store.claim(nonce)

        raise ApprovalRelayError, "approval nonce replay refused"
      end

      def build_assertion(approval, approver_id, decision, nonce)
        {
          "approver_id" => approver_id,
          "tenant_id" => require_field!(approval, "tenant_id"),
          "approval_id" => require_field!(approval, "approval_id"),
          "intent_digest" => require_digest!(approval, "intent_digest"),
          "snapshot_digest" => require_digest!(approval, "snapshot_digest"),
          "decision" => decision.to_s,
          "expires_at" => require_field!(approval, "expires_at"),
          "nonce" => nonce,
          "audience" => require_field!(approval, "audience"),
          "relay_id" => @relay_id,
          "key_id" => @signer.key_id
        }
      end

      def submit_assertion(assertion, reason)
        signed = @signer.sign(ASSERTION_DOMAIN + Tamoz::Core.jcs(assertion))
        @submission.submit(
          approval_id: assertion.fetch("approval_id"),
          decision: assertion.fetch("decision"),
          reason: truncate_reason(reason),
          idempotency_key: idempotency_key(assertion, reason),
          assertion: assertion.merge("signature" => signed)
        )
      end

      def truncate_reason(reason)
        reason.to_s.byteslice(0, 1024)
      end

      def normalize_roster_entries(roster)
        roster.map do |entry|
          raise ApprovalRelayError, "escalation roster entries must be objects" unless entry.is_a?(Hash)

          entry.transform_keys(&:to_s)
        end
      end

      def next_candidate(entries, current_approver)
        index = entries.index { |entry| entry.fetch("approver_id") == current_approver }
        index ? entries[index + 1] : entries.first
      end

      def escalation_payload(candidate)
        {
          "approver_id" => candidate.fetch("approver_id"),
          "channel" => candidate.fetch("channel", "telegram"),
          "after_seconds" => candidate.fetch("after_seconds", 0),
          "approval_id" => candidate["approval_id"]
        }.compact
      end

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
        empty = value.respond_to?(:empty?) && value.empty?
        if value.nil? || empty || value.to_s.empty? || value.to_s.bytesize > MAX_ID_BYTES
          raise ApprovalRelayError, "#{key} is required and bounded"
        end

        value.to_s
      end

      def require_prompt_fields!(approval)
        %w[summary delta hypothesis action decline_consequence].each do |key|
          require_field!(approval, key)
        end
      end

      def require_evidence!(approval)
        evidence = approval["evidence"]
        valid = evidence.is_a?(Array) && evidence.all? do |entry|
          entry.is_a?(String) && !entry.empty? && entry.bytesize <= MAX_ID_BYTES
        end
        raise ApprovalRelayError, "evidence is required and bounded" unless valid

        evidence
      end

      def require_digest!(approval, key)
        value = approval[key].to_s
        unless Tamoz::Core.valid_digest?(value)
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
              SUBMISSION_DOMAIN,
              {"reason" => reason.to_s}
            )
          )
        end
        Tamoz::Core.digest(SUBMISSION_DOMAIN, keyed)
      end

      def stringify(hash)
        raise ApprovalRelayError, "approval must be an object" unless hash.is_a?(Hash)

        hash.transform_keys(&:to_s)
      end
    end
  end
end

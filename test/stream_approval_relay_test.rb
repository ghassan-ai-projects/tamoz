# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/approval_relay"
require "tamoz/comms/surface_descriptor"

# T7 (PLAN_TAMOZ_STREAM_BUILD T7): the approval relay. Approval AUTHORITY
# stays in the stream; approval DELIVERY moves to Tamoz. The relay renders and
# delivers the prompt, edits it in place on withdrawal, submits the human's
# answer with an Idempotency-Key + a signed 11-field assertion
# (situation-runtime/approval-assertion/v1), refuses a replayed nonce, keeps
# relay_id != approver_id, and owns escalation. T7.1: the SurfaceDescriptor
# now expresses affirmative approval with an approver-role allowlist.
class StreamApprovalRelayTest < Minitest::Test
  Relay = Tamoz::Stream::ApprovalRelay

  class FakeDelivery
    attr_reader :delivered, :edited

    def initialize
      @delivered = []
      @edited = []
    end

    def deliver(conversation_id:, kind:, reply_to: nil, text:)
      @delivered << {conversation_id:, kind:, text:}
      "receipt-#{@delivered.length}"
    end

    def edit_in_place(message_id:, text:)
      @edited << {message_id:, text:}
    end
  end

  class FakeSubmission
    attr_reader :submitted

    def initialize = @submitted = []

    def submit(**arguments)
      @submitted << arguments
      arguments.fetch(:approval_id)
    end
  end

  class FakeNonceStore
    def initialize = @seen = {}

    def claim(nonce)
      return false if @seen.key?(nonce)

      @seen[nonce] = true
    end
  end

  class FakeSigner
    attr_reader :signed

    def initialize = @signed = []

    def key_id = "key-1"

    def sign(bytes)
      @signed << bytes
      "sig-#{Digest::SHA256.hexdigest(bytes)[0, 16]}"
    end
  end

  def approval(overrides = {})
    {
      "approval_id" => "apr-1",
      "tenant_id" => "acme",
      "situation_id" => "sit-1",
      "intent_digest" => "sha256:#{"a" * 64}",
      "snapshot_digest" => "sha256:#{"b" * 64}",
      "expires_at" => "2026-08-19T00:00:00Z",
      "audience" => "stream-1",
      "summary" => "pressure trend",
      "delta" => "pressure rose 0.2 since the last version",
      "hypothesis" => "bearing wear",
      "evidence" => ["pressure 0.9, vibration 2.1"],
      "action" => "setpoint change on freezer zone 3",
      "decline_consequence" => "the zone runs hot and may fault"
    }.merge(overrides)
  end

  # A fixed clock before the fixture's `expires_at` keeps the expiry gate
  # deterministic: the approval is always live during the test, regardless of
  # the wall clock the suite runs under.
  def relay(delivery: FakeDelivery.new, submission: FakeSubmission.new,
            nonce_store: FakeNonceStore.new, signer: FakeSigner.new,
            relay_id: "relay-1", clock: -> { Time.utc(2026, 8, 18) })
    Relay.new(
      delivery:, submission:, nonce_store:, signer:, relay_id:, clock:
    )
  end

  def test_deliver_renders_the_prompt_and_returns_a_receipt
    delivery = FakeDelivery.new
    receipt = relay(delivery:).deliver(approval: approval, conversation_id: "chat-1")

    assert_equal "receipt-1", receipt
    entry = delivery.delivered.fetch(0)
    assert_equal "chat-1", entry.fetch(:conversation_id)
    assert_equal "approval_request", entry.fetch(:kind)
    text = entry.fetch(:text)
    %w[Summary: Delta: Hypothesis: Evidence: Action: If\ declined: Expires:].each do |fragment|
      assert_includes text, fragment
    end
    assert_includes text, "pressure trend"
    assert_includes text, "the zone runs hot and may fault"
  end

  def test_deliver_accepts_present_empty_evidence
    delivery = FakeDelivery.new

    receipt = relay(delivery:).deliver(
      approval: approval("evidence" => []), conversation_id: "chat-1"
    )

    assert_equal "receipt-1", receipt
    assert_includes delivery.delivered.fetch(0).fetch(:text), "Evidence: []"
  end

  def test_deliver_refuses_missing_or_nil_evidence
    missing = approval
    missing.delete("evidence")

    [missing, approval("evidence" => nil)].each do |invalid_approval|
      error = assert_raises(Relay::ApprovalRelayError) do
        relay.deliver(approval: invalid_approval, conversation_id: "chat-1")
      end
      assert_includes error.message, "evidence"
    end
  end

  def test_deliver_refuses_empty_required_fields
    empty_values = {
      "summary" => "",
      "delta" => {},
      "hypothesis" => "",
      "action" => {},
      "decline_consequence" => ""
    }

    empty_values.each do |field, value|
      error = assert_raises(Relay::ApprovalRelayError) do
        relay.deliver(
          approval: approval(field => value), conversation_id: "chat-1"
        )
      end
      assert_includes error.message, field
    end
  end

  def test_withdraw_edits_the_delivered_message_in_place
    delivery = FakeDelivery.new
    the_relay = relay(delivery:)
    the_relay.deliver(approval: approval, conversation_id: "chat-1")
    the_relay.withdraw(message_id: "receipt-1")

    edit = delivery.edited.fetch(0)
    assert_equal "receipt-1", edit.fetch(:message_id)
    assert_includes edit.fetch(:text), "withdrawn"
  end

  def test_submit_decision_binds_all_eleven_fields_and_signs_under_the_domain
    submission = FakeSubmission.new
    signer = FakeSigner.new
    the_relay = relay(submission:, signer:)
    the_relay.submit_decision(
      approval: approval, approver_id: "technician-7", decision: "approve",
      reason: "verified in person"
    )

    entry = submission.submitted.fetch(0)
    assertion = entry.fetch(:assertion)
    assert_equal Relay::ASSERTION_FIELDS.sort, assertion.keys.select { |k| k != "signature" }.sort
    assert_equal "approve", assertion.fetch("decision")
    assert_equal "technician-7", assertion.fetch("approver_id")
    assert_equal "relay-1", assertion.fetch("relay_id")
    assert_equal "key-1", assertion.fetch("key_id")
    refute_equal assertion.fetch("approver_id"), assertion.fetch("relay_id"),
                 "relay_id must never equal approver_id (separation of duty)"
    assert_match(/\A[0-9a-f-]{36}\z/, assertion.fetch("nonce"))
    assert_equal "sig-", entry.fetch(:assertion).fetch("signature")[0, 4]

    # The signature covers the canonical form of ALL fields under the domain.
    assert_equal 1, signer.signed.length
    signed = signer.signed.fetch(0)
    assert signed.start_with?(Relay::ASSERTION_DOMAIN)
    assert_equal(
      Tamoz::Core.jcs(assertion.reject { |key, _| key == "signature" }),
      signed.delete_prefix(Relay::ASSERTION_DOMAIN)
    )

    # The transport Idempotency-Key is keyed on the decision, not the nonce.
    assert_equal entry.fetch(:approval_id), "apr-1"
    assert_match(/\Asha256:/, entry.fetch(:idempotency_key))
    refute_equal entry.fetch(:idempotency_key), assertion.fetch("nonce")
    assert_equal "verified in person", entry.fetch(:reason)
  end

  def test_a_replayed_nonce_is_refused_never_idempotently_accepted
    # The nonce is claimed BEFORE submission; a store that refuses the claim
    # (the stream-side replay case) must fail the submission, never retry it.
    refusing_store = Class.new do
      def claim(_nonce) = false
    end.new
    the_relay = relay(nonce_store: refusing_store)

    error = assert_raises(Relay::ApprovalRelayError) do
      the_relay.submit_decision(
        approval: approval, approver_id: "technician-7", decision: "deny"
      )
    end
    assert_includes error.message, "replay"
  end

  def test_submit_refuses_relay_id_as_approver
    the_relay = relay(relay_id: "relay-1")
    error = assert_raises(Relay::ApprovalRelayError) do
      the_relay.submit_decision(
        approval: approval, approver_id: "relay-1", decision: "approve"
      )
    end
    assert_includes error.message, "never be the asserted approver"
  end

  def test_submit_refuses_an_unknown_decision
    the_relay = relay
    assert_raises(Relay::ApprovalRelayError) do
      the_relay.submit_decision(
        approval: approval, approver_id: "technician-7", decision: "maybe"
      )
    end
  end

  def test_submit_requires_the_grounding_digests
    the_relay = relay
    assert_raises(Relay::ApprovalRelayError) do
      the_relay.submit_decision(
        approval: approval("intent_digest" => "not-a-digest"),
        approver_id: "technician-7", decision: "approve"
      )
    end
  end

  def test_escalation_is_deterministic_and_skips_the_current_approver
    the_relay = relay
    roster = [
      {"approver_id" => "t1", "channel" => "telegram", "after_seconds" => 300},
      {"approver_id" => "t2", "channel" => "telegram", "after_seconds" => 1800}
    ]
    assert_equal "t1", the_relay.escalate(roster:)&.fetch("approver_id")
    assert_equal "t2", the_relay.escalate(roster:, current_approver: "t1")&.fetch("approver_id")
    assert_nil the_relay.escalate(roster:, current_approver: "t2"),
               "a spent roster escalates to nobody - the stream owns the deadline"
  end

  # T7.1: the SurfaceDescriptor expresses affirmative approval as a material,
  # configured security boundary - with an approver-role allowlist, not a flag.
  def test_the_surface_descriptor_accepts_affirmative_approval
    descriptor = Tamoz::Comms::SurfaceDescriptor.build(
      surface_id: "tel-1", revision: 2, transport: {mode: "long_poll", credential_ref: {ref: "t"}, poll_timeout_s: 30, batch: 1, max_response_bytes: 1000},
      identity: {expected_bot_id: 123},
      admission: {direct: "allowlist", correspondents: ["c1"]},
      threading: "conversation", profile_id: "p1",
      approvals: {mode: "affirmative", prompt_ttl_s: 900, approver_roles: ["technician"]},
      rendering: {format: "plain", max_parts: 1, part_characters: 4000, overflow: "truncate"},
      limits: {max_inbound_bytes: 1000, max_open_requests: 2, max_denial_prompts_per_request: 3,
               outbox_capacity: 10, control_capacity: 10, per_chat_messages_per_s: 1.0, global_messages_per_s: 5.0}
    )
    assert_equal "affirmative", descriptor.approvals.fetch(:mode)
  end

  def test_affirmative_approval_without_an_approver_allowlist_is_refused
    error = assert_raises(Tamoz::Comms::ValidationError) do
      Tamoz::Comms::SurfaceDescriptor.build(
        surface_id: "tel-1", revision: 2, transport: {mode: "long_poll", credential_ref: {ref: "t"}, poll_timeout_s: 30, batch: 1, max_response_bytes: 1000},
        identity: {expected_bot_id: 123},
        admission: {direct: "allowlist", correspondents: ["c1"]},
        threading: "conversation", profile_id: "p1",
        approvals: {mode: "affirmative", prompt_ttl_s: 900},
        rendering: {format: "plain", max_parts: 1, part_characters: 4000, overflow: "truncate"},
        limits: {max_inbound_bytes: 1000, max_open_requests: 2, max_denial_prompts_per_request: 3,
                 outbox_capacity: 10, control_capacity: 10, per_chat_messages_per_s: 1.0, global_messages_per_s: 5.0}
      )
    end
    assert_includes error.message, "approver_roles"
  end
end

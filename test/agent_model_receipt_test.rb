# frozen_string_literal: true

require_relative "test_helper"

# P0B/§4.3/§8.1 conformance: the model-call identities and receipt fail closed
# on malformed shapes, the logical key is stable across attempts/fences, and
# missing usage is declared unavailable rather than fabricated as zero.
class AgentModelReceiptTest < Minitest::Test
  MC = Tamoz::Agent::ModelCall
  DIGEST = "sha256:#{"0" * 64}"
  DIGEST2 = "sha256:#{"a" * 64}"

  def logical(**over)
    MC::LogicalCallKey.new(**{episode_id: "ep-1", stage: "diagnose", slot: 0, request_digest: DIGEST}.merge(over))
  end

  def invocation(**over)
    MC::InvocationIdentity.new(**{attempt_id: "at-1", fence: 1, graph_task: "t1", stage: "diagnose", global_ordinal: 1}.merge(over))
  end

  def receipt(**over)
    MC::ModelReceipt.new(**{
      logical_call_key: logical, invocation: invocation, effect_id: "eff-1", status: :succeeded,
      provider: "deepseek", model: "chat", request_digest: DIGEST, response_digest: DIGEST2,
      usage: MC::Usage.of(input_tokens: 10, output_tokens: 3, cost_microunits: 5),
      retry_count: 0, started_at: "2026-08-15T00:00:00Z", completed_at: "2026-08-15T00:00:01Z"
    }.merge(over))
  end

  def assert_rejected(code, klass = Tamoz::Agent::ModelReceiptError)
    error = assert_raises(klass) { yield }
    assert_includes error.message, code
  end

  # --- logical key: stable across attempt/fence (§8.1) ---

  def test_logical_key_is_attempt_and_fence_independent
    a = receipt(invocation: invocation(attempt_id: "at-1", fence: 1))
    b = receipt(invocation: invocation(attempt_id: "at-9", fence: 7))
    assert_equal a.logical_call_key.to_key, b.logical_call_key.to_key
    assert_equal logical, logical # value equality
  end

  def test_logical_key_changes_with_request_digest
    refute_equal logical.to_key, logical(request_digest: DIGEST2).to_key
  end

  def test_logical_key_rejects_blank_and_bad_digest
    assert_rejected("logical_call_key.episode_id/blank") { logical(episode_id: "") }
    assert_rejected("logical_call_key.request_digest/bad_digest") { logical(request_digest: "nope") }
  end

  # --- usage: unavailable is not zero (§7.3) ---

  def test_usage_unavailable_is_nil_not_zero
    u = MC::Usage.unavailable
    refute u.available
    assert_nil u.input_tokens
    assert_nil u.cost_microunits
  end

  def test_usage_rejects_available_but_nil
    assert_rejected("usage/available_but_nil") do
      MC::Usage.new(available: true, input_tokens: nil, output_tokens: 1, cost_microunits: 1)
    end
  end

  def test_usage_rejects_unavailable_but_present
    assert_rejected("usage/unavailable_but_present") do
      MC::Usage.new(available: false, input_tokens: 0, output_tokens: 0, cost_microunits: 0)
    end
  end

  # --- receipt shape ---

  def test_builds_succeeded_receipt
    r = receipt
    assert r.succeeded?
    assert_equal "deepseek", r.provider
    assert_equal DIGEST2, r.response_digest
  end

  def test_succeeded_requires_response_digest
    assert_rejected("receipt.response_digest/bad_digest") { receipt(response_digest: nil) }
  end

  def test_unknown_receipt_allows_no_response_and_unavailable_usage
    r = receipt(status: :unknown, response_digest: nil, usage: MC::Usage.unavailable, completed_at: nil)
    assert r.unknown?
    assert_nil r.response_digest
    refute r.usage.available
  end

  def test_rejects_bad_status
    assert_rejected("receipt/bad_status") { receipt(status: :maybe) }
  end

  def test_rejects_wrong_component_types
    assert_rejected("receipt/logical_call_key_type") { receipt(logical_call_key: {episode_id: "x"}) }
    assert_rejected("receipt/usage_type") { receipt(usage: {available: false}) }
  end

  # --- Profile role resolution (§4.3): fails closed before a model call ---

  ProfileDouble = Struct.new(:model_roles, :canonical_digest)

  def profile(roles = {"greenhouse_reasoner" => {"provider" => "deepseek", "model" => "chat", "credential_ref" => "TAMOZ_DEEPSEEK"}},
              digest: "sha256:#{"c" * 64}")
    ProfileDouble.new(roles, digest)
  end

  def test_resolve_role_returns_typed_role
    role = MC.resolve_role(profile, "greenhouse_reasoner")
    assert_equal "greenhouse_reasoner", role.name
    assert_equal "deepseek", role.provider
    assert_equal "chat", role.model
    assert_equal "TAMOZ_DEEPSEEK", role.credential_ref
  end

  def test_resolve_role_unknown_fails_closed
    assert_rejected("model_role/unknown", Tamoz::Agent::ProfileRoleUnavailableError) { MC.resolve_role(profile, "nope") }
  end

  def test_resolve_role_incomplete_fails_closed
    incomplete = profile({"r" => {"provider" => "deepseek"}})
    assert_rejected("model_role/incomplete", Tamoz::Agent::ProfileRoleUnavailableError) { MC.resolve_role(incomplete, "r") }
  end

  def test_resolve_role_profile_digest_mismatch_fails_closed
    assert_rejected("model_role/profile_digest_mismatch", Tamoz::Agent::ProfileRoleUnavailableError) do
      MC.resolve_role(profile, "greenhouse_reasoner", expected_profile_digest: "sha256:#{"9" * 64}")
    end
  end
end

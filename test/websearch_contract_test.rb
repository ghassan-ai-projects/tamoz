# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/mcp/websearch'

class WebsearchContractTest < Minitest::Test
  EgressPolicy = Tamoz::Mcp::Websearch::EgressPolicy
  EgressClient = Tamoz::Mcp::Websearch::EgressClient
  EgressCircuit = Tamoz::Mcp::Websearch::EgressCircuit

  def policy(max_response_bytes: 4, redirect_max_hops: 3)
    EgressPolicy.new(
      'allowlisted_hosts' => ['api.search.example'],
      'schemes' => ['https'],
      'deny_private_ranges' => true,
      'max_request_bytes' => 2048,
      'max_response_bytes' => max_response_bytes,
      'connect_timeout_s' => 10,
      'redirect_max_hops' => redirect_max_hops,
      'circuit' => { 'threshold' => 3, 'scope_type' => 'egress', 'budget_breach' => true },
      'credential_refs' => []
    )
  end

  def test_result_shape_fields_truncation_and_immutability_are_preserved
    result = EgressClient.new(
      policy: policy,
      resolver: ->(_host) { ['93.184.216.34'] },
      connector: lambda do |**|
        { 'status' => 200, 'headers' => { 'content-type' => 'text/plain' }, 'body' => 'abcdef' }
      end
    ).fetch('https://api.search.example/search')

    assert_equal %i[status headers body truncated], EgressClient::Result.members
    assert_equal 200, result.status
    assert_equal({ 'content-type' => 'text/plain' }, result.headers)
    assert_equal 'abcd', result.body
    assert_equal true, result.truncated
    assert_predicate result, :frozen?
    assert_predicate result.headers, :frozen?
    assert_predicate result.body, :frozen?
    assert_raises(FrozenError) { result.headers['x-test'] = 'value' }
  end

  def test_egress_policy_errors_keep_ancestry_metadata_and_repairability
    error = Tamoz::Mcp::Websearch::EgressPolicyError.new('refused')

    assert_operator Tamoz::Mcp::Websearch::EgressPolicyError, :<, Tamoz::Mcp::ToolPolicyError
    assert_equal 'mcp_egress_policy', error.category
    assert_equal 'A websearch egress policy violation was refused.', error.safe_message
    assert_equal true, error.user_visible?
    assert_equal false, error.repairable?

    redirect = Tamoz::Mcp::Websearch::RedirectHopLimitError.new('too many')

    assert_operator Tamoz::Mcp::Websearch::RedirectHopLimitError, :<,
                    Tamoz::Mcp::Websearch::EgressPolicyError
    assert_equal 'mcp_redirect_hop_limit', redirect.category
    assert_equal 'A websearch redirect chain exceeded the allowed hop count.', redirect.safe_message
    assert_equal true, redirect.user_visible?
    assert_equal false, redirect.repairable?
  end

  def test_nested_policy_validation_error_keeps_mcp_validation_ancestry
    error = assert_raises(EgressPolicy::ValidationError) { EgressPolicy.new({}) }

    assert_kind_of Tamoz::Mcp::ValidationError, error
    assert_kind_of Tamoz::Mcp::Error, error
    assert_equal 'mcp_validation', error.category
    assert_equal 'The MCP server configuration is invalid.', error.safe_message
    assert_equal true, error.user_visible?
  end

  def test_circuit_reset_requires_operator_evidence_and_resets_only_with_valid_record
    circuit = EgressCircuit.new(threshold: 3, scope_id: 'egress:websearch')
    3.times { circuit.record_failure(kind: :connect) }

    assert_predicate circuit, :open?

    assert_raises(Tamoz::Mcp::CircuitPolicyError) { circuit.reset }
    policy_error = assert_raises(Tamoz::Mcp::CircuitPolicyError) { circuit.reset }
    assert_operator Tamoz::Mcp::CircuitPolicyError, :<, Tamoz::Mcp::Error
    assert_equal 'mcp_circuit_policy', policy_error.category
    assert_equal(
      'A circuit reset was refused because it did not carry the required operator evidence.',
      policy_error.safe_message
    )
    assert_equal true, policy_error.user_visible?
    assert_equal false, policy_error.repairable?
    assert_predicate circuit, :open?
    assert_equal 3, circuit.failures
    assert_nil circuit.reset_evidence

    evidence = { 'authority' => 'owner', 'operator_command_digest' => "sha256:#{'a' * 64}" }

    assert_equal :closed, circuit.reset(evidence: evidence)
    refute_predicate circuit, :open?
    assert_equal 0, circuit.failures
    assert_equal evidence, circuit.reset_evidence
    assert_predicate circuit.reset_evidence, :frozen?
    assert_raises(FrozenError) { circuit.reset_evidence['authority'] = 'other' }
  end
end

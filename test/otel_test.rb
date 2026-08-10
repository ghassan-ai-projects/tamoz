# frozen_string_literal: true

require_relative 'test_helper'

class OTelTest < Minitest::Test
  def test_egress_policy_rejects_untrusted_destinations
    assert_raises(Tamoz::Observability::ValidationError) do
      Tamoz::OTel::EgressPolicy.new(endpoint: 'http://collector.example')
    end
    assert_raises(Tamoz::Observability::ValidationError) do
      Tamoz::OTel::EgressPolicy.new(endpoint: 'https://127.0.0.1:4318')
    end
  end

  def test_local_endpoint_requires_explicit_opt_in_and_credentials_are_references
    policy = Tamoz::OTel::EgressPolicy.new(
      endpoint: 'https://127.0.0.1:4318',
      allow_local: true,
      credential_ref: {kind: :env, name: 'TAMOZ_OTEL_TOKEN'}
    )

    assert_equal({'kind' => 'env', 'name' => 'TAMOZ_OTEL_TOKEN'}, policy.credential_ref)
    refute_includes policy.inspect, 'token-value'
  end

  def test_http_exporter_does_not_follow_redirects_or_use_proxy_environment
    policy = Tamoz::OTel::EgressPolicy.new(endpoint: 'https://127.0.0.1:4318', allow_local: true)
    exporter = Tamoz::OTel::HTTPExporter.new(policy:, env: {'HTTPS_PROXY' => 'https://proxy.invalid'})
    assert_equal :opened, exporter.open
    assert_equal :rejected, exporter.export([], deadline_ms: 10)
  end
end

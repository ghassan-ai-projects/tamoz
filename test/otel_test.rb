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

  def test_http_exporter_maps_documents_to_valid_otlp_span_shape
    policy = Tamoz::OTel::EgressPolicy.new(endpoint: 'https://collector.example')
    exporter = Tamoz::OTel::HTTPExporter.new(policy:)
    exporter.open

    spans = exporter.send(
      :resource_spans,
      [{
        'name' => 'tamoz.worker.request.completed',
        'kind' => 'event',
        'correlation' => {'thread_id' => 'thread.1', 'execution_id' => 'execution.1'},
        'attributes' => {},
        'observed_at_ms' => 1
      }]
    ).fetch('resourceSpans').first.fetch('scopeSpans').first.fetch('spans')

    assert_equal 1, spans.length
    assert_equal 32, spans.first.fetch('trace_id').length
    assert_equal 16, spans.first.fetch('span_id').length
    assert_equal 'SPAN_KIND_INTERNAL', spans.first.fetch('kind')
  end

  def test_http_exporter_clears_state_after_credential_failure
    policy = Tamoz::OTel::EgressPolicy.new(
      endpoint: 'https://collector.example',
      credential_ref: {kind: :env, name: 'TAMOZ_OTEL_TOKEN'}
    )
    exporter = Tamoz::OTel::HTTPExporter.new(policy:, env: {'TAMOZ_OTEL_TOKEN' => 'old-token'})
    assert_equal :opened, exporter.open
    assert_equal :rejected, exporter.open({}, {'kind' => 'env', 'name' => 'MISSING_TOKEN'})
    refute exporter.instance_variable_get(:@opened)
    assert_empty exporter.instance_variable_get(:@headers)
  end

  def test_resolved_private_addresses_require_local_opt_in
    policy = Tamoz::OTel::EgressPolicy.new(endpoint: 'https://collector.example')

    assert_raises(Tamoz::Observability::ValidationError) do
      policy.validate_resolved_addresses!(['127.0.0.1'])
    end
  end
end

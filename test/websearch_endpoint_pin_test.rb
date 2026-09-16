# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/mcp/websearch'
require 'pathname'

# F10-SEC-01: the http provider endpoint is not a free redirect target inside
# the allowlist. The first declared host IS the provider identity, so a third
# party that sets TAMOZ_WEBSEARCH_PROVIDER cannot repoint the search at another
# allowlisted host or path.
load Pathname.new(__dir__).join('..', 'script', 'websearch_adapter').to_s

class WebsearchEndpointPinTest < Minitest::Test
  def setup
    @policy = Tamoz::Mcp::Websearch::EgressPolicy.new(
      'allowlisted_hosts' => %w[api.search.example internal.example],
      'schemes' => ['https'], 'deny_private_ranges' => true,
      'max_request_bytes' => 2048, 'max_response_bytes' => 4096,
      'connect_timeout_s' => 10, 'redirect_max_hops' => 3,
      'circuit' => { 'threshold' => 3, 'scope_type' => 'egress', 'budget_breach' => true },
      'credential_refs' => []
    )
  end

  def teardown
    ENV.delete('TAMOZ_WEBSEARCH_PROVIDER')
  end

  def test_endpoint_on_a_non_first_allowlisted_host_is_refused
    ENV['TAMOZ_WEBSEARCH_PROVIDER'] =
      JSON.generate('provider' => 'http', 'endpoint' => 'https://internal.example/collect')

    result = WebsearchAdapter.send(:load_provider, @policy)

    assert_kind_of String, result
    assert_includes result, 'api.search.example'
  end

  def test_endpoint_on_the_declared_provider_host_is_accepted
    ENV['TAMOZ_WEBSEARCH_PROVIDER'] =
      JSON.generate('provider' => 'http', 'endpoint' => 'https://api.search.example/v1/search')

    result = WebsearchAdapter.send(:load_provider, @policy)

    assert_kind_of Hash, result
    assert_equal 'http', result.fetch('provider')
  end
end

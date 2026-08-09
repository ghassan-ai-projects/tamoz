# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/mcp/websearch'

# The websearch connector CONTRACT: what the egress client tells the dialer to
# ask for, and what the real dialer then builds.
#
# This is the seam the live provider path runs on, and it was broken in two
# places at once: `path` was computed per target and never passed to the
# connector, and the default connector built a GET and assigned a body to it
# (which `Net::HTTP::Get` silently drops). Neither showed up because every
# other adapter test injects a connector spy that ignores both, and CI only
# ever exercises the fixture provider.
class WebsearchConnectorContractTest < Minitest::Test
  EgressPolicy = Tamoz::Mcp::Websearch::EgressPolicy
  EgressClient = Tamoz::Mcp::Websearch::EgressClient

  RESOLVER_MAP = {
    'api.search.example' => ['93.184.216.34'],
    'cdn.search.example' => ['93.184.216.35']
  }.freeze

  def egress
    EgressPolicy.new(
      'allowlisted_hosts' => RESOLVER_MAP.keys,
      'schemes' => ['https'],
      'deny_private_ranges' => true,
      'max_request_bytes' => 2048,
      'max_response_bytes' => 4096,
      'connect_timeout_s' => 10,
      'redirect_max_hops' => 3,
      'circuit' => { 'threshold' => 3, 'scope_type' => 'egress', 'budget_breach' => true },
      'credential_refs' => []
    )
  end

  def client_with(connector)
    EgressClient.new(
      policy: egress,
      resolver: ->(host) { RESOLVER_MAP.fetch(host, []) },
      connector:
    )
  end

  # The connector contract, pinned: the path AND its query reach the dialer.
  #
  # This is the seam the live provider path actually runs on. It was broken —
  # `path` was computed per target and never passed, so the real connector
  # asked for "/" every time — and it survived because every other test in this
  # file ignores the argument and CI only exercises the fixture provider.
  def test_the_connector_receives_the_request_path_and_query
    seen = []
    connector = lambda do |path:, **|
      seen << path
      { 'status' => 200, 'headers' => {}, 'body' => 'ok' }
    end
    client = client_with(connector)
    client.fetch('https://api.search.example/v1/search?q=tamoz&n=3')

    assert_equal ['/v1/search?q=tamoz&n=3'], seen,
                 'the connector must be told what to ask for, not just whom to ask'
  end

  # A body decides the verb. The default connector built a `Net::HTTP::Get`
  # and then assigned `request.body` to it — which GET does not permit, so the
  # body was dropped without a word.
  def test_the_default_connector_uses_post_when_there_is_a_body
    captured = with_stubbed_http do
      EgressClient.new(policy: egress).send(:default_connector).call(
        pinned_ip: '93.184.216.34', host: 'api.search.example',
        path: '/v1/search', port: 443, timeout: 5, headers: {},
        body: '{"q":"tamoz"}'
      )
    end

    assert_instance_of Net::HTTP::Post, captured
    assert_equal '/v1/search', captured.path
    assert_equal '{"q":"tamoz"}', captured.body
  end

  # A stand-in for Net::HTTP that records the request object it was handed.
  # Returns the captured request.
  def with_stubbed_http
    captured = nil
    double = http_double { |request| captured = request }
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*| double }
    begin
      yield
    ensure
      Net::HTTP.define_singleton_method(:new, original)
    end
    captured
  end

  def http_double(&)
    response = Struct.new(:code, :body).new('200', 'ok')
    response.define_singleton_method(:each_header) { {}.each }
    double = Object.new
    %i[ipaddr= use_ssl= verify_mode= open_timeout= read_timeout=].each do |setter|
      double.define_singleton_method(setter) { |_value| nil }
    end
    double.define_singleton_method(:start) { |&block| block.call(double) }
    double.define_singleton_method(:request) do |request|
      yield(request)
      response
    end
    double
  end

  # And it keeps being told on every hop, against the REDIRECT's path.
  def test_the_connector_receives_the_redirect_path
    seen = []
    sequence = [
      { 'status' => 302, 'headers' => { 'location' => 'https://cdn.search.example/next?page=2' }, 'body' => '' },
      { 'status' => 200, 'headers' => {}, 'body' => 'final' }
    ]
    connector = lambda do |path:, **|
      seen << path
      sequence.shift
    end
    client = client_with(connector)
    client.fetch('https://api.search.example/start')

    assert_equal ['/start', '/next?page=2'], seen
  end
end

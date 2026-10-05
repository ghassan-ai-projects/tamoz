# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/mcp/websearch"

class WebsearchAdapterTest < Minitest::Test
  EgressPolicy = Tamoz::Mcp::Websearch::EgressPolicy
  EgressClient = Tamoz::Mcp::Websearch::EgressClient

  def egress(hosts: ["api.search.example", "cdn.search.example"], deny: true)
    EgressPolicy.new(
      "allowlisted_hosts" => hosts,
      "schemes" => ["https"],
      "deny_private_ranges" => deny,
      "max_request_bytes" => 2048,
      "max_response_bytes" => 4096,
      "connect_timeout_s" => 10,
      "redirect_max_hops" => 3,
      "circuit" => {"threshold" => 3, "scope_type" => "egress", "budget_breach" => true},
      "credential_refs" => []
    )
  end

  def resolver_map
    {
      "api.search.example" => ["93.184.216.34"],
      "cdn.search.example" => ["93.184.216.35"]
    }
  end

  def client_with(policy, resolver: nil, connector: nil, dials: nil)
    EgressClient.new(
      policy:,
      resolver: resolver || ->(host) { resolver_map.fetch(host, []) },
      connector: connector || lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
        dials << [pinned_ip, host, headers] if dials
        {"status" => 200, "headers" => {}, "body" => "answer 42"}
      end
    )
  end

  def test_per_hop_check_pins_the_validated_address
    dials = []
    client = client_with(egress, dials: dials)
    result = client.fetch("https://api.search.example/search")
    assert_equal 200, result.status
    assert_equal "answer 42", result.body
    assert_equal ["93.184.216.34"], dials.map(&:first),
                 "the dialer must receive exactly the validated pinned IP"
  end

  def test_rebinding_sequence_never_reaches_the_dialer
    dials = []
    lookups = 0
    resolver = lambda do |host|
      lookups += 1
      # A naive implementation would re-resolve at dial time and get the
      # private answer; the pinned implementation resolves exactly once.
      lookups == 1 ? ["93.184.216.34"] : ["10.0.0.1"]
    end
    client = client_with(egress, resolver: resolver, dials: dials)
    client.fetch("https://api.search.example/search")
    assert_equal 1, lookups, "the validated address is pinned; no second resolution"
    assert_equal ["93.184.216.34"], dials.map(&:first)
  end

  def test_private_range_targets_are_refused_with_zero_dials
    dials = []
    client = client_with(egress, dials: dials)
    ["127.0.0.1", "10.0.0.1", "169.254.169.254", "::1", "192.168.1.1"].each do |address|
      resolver = ->(_host) { [address] }
      refused = client_with(egress, resolver: resolver, dials: dials)
      assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
        refused.fetch("https://api.search.example/search")
      end
    end
    assert_empty dials, "no refused address may be dialed"
  end

  def test_exotic_literals_are_neutralized_before_classification
    dials = []
    client = client_with(egress, dials: dials)
    ["::ffff:127.0.0.1", "::ffff:7f00:1", "2130706433", "0x7f000001",
     "017700000001", "0xC0A80101", "169.254.169.254"].each do |spelling|
      resolver = ->(_host) { [spelling] }
      refused = client_with(egress, resolver: resolver, dials: dials)
      assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
        refused.fetch("https://api.search.example/search")
      end
    end
    assert_empty dials
  end

  def test_unclassifiable_ip_spellings_are_refused_fail_closed
    dials = []
    ["127.1", "10.1", "127.000.000.001", "127.0.1", "127.0.0.01", "0x7f.0.0.1",
     "169.254.1", "192.168.1"].each do |spelling|
      resolver = ->(_host) { [spelling] }
      refused = client_with(egress, resolver: resolver, dials: dials)
      assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
        refused.fetch("https://api.search.example/search")
      end
    end
    assert_empty dials, "no unclassifiable spelling may reach the dialer"

    # Positive control: a canonical public address still dials — the
    # fail-closed rule must not over-refuse legitimate resolutions.
    public_dials = []
    public_client = client_with(egress, resolver: ->(_host) { ["93.184.216.34"] },
                                        dials: public_dials)
    public_client.fetch("https://api.search.example/search")
    assert_equal [["93.184.216.34", "api.search.example", {}]], public_dials
  end

  def test_off_allowlist_target_is_refused_with_zero_dials
    dials = []
    resolver_calls = 0
    resolver = lambda do |host|
      resolver_calls += 1
      ["93.184.216.34"]
    end
    client = client_with(egress, resolver: resolver, dials: dials)
    assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
      client.fetch("https://evil.example/search")
    end
    assert_equal 0, resolver_calls
    assert_empty dials
  end

  def test_redirect_target_goes_through_the_full_check_again
    dials = []
    sequence = [
      {"status" => 302, "headers" => {"location" => "https://cdn.search.example/next"}, "body" => ""},
      {"status" => 200, "headers" => {}, "body" => "final"}
    ]
    connector = lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
      dials << [pinned_ip, host]
      sequence.shift
    end
    client = client_with(egress, connector: connector)
    result = client.fetch("https://api.search.example/start")
    assert_equal "final", result.body
    assert_equal(
      [["93.184.216.34", "api.search.example"], ["93.184.216.35", "cdn.search.example"]],
      dials,
      "each hop must resolve → classify → pin → dial again"
    )
  end

  def test_off_allowlist_redirect_is_refused_typed
    dials = []
    connector = lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
      dials << pinned_ip
      {"status" => 302, "headers" => {"location" => "https://evil.example/x"}, "body" => ""}
    end
    client = client_with(egress, connector: connector)
    assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
      client.fetch("https://api.search.example/start")
    end
    assert_equal ["93.184.216.34"], dials, "the refused redirect hop is never dialed"
  end

  def test_redirect_hop_bound_is_enforced
    hops = 0
    connector = lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
      hops += 1
      {"status" => 302, "headers" => {"location" => "https://cdn.search.example/h#{hops}"}, "body" => ""}
    end
    client = client_with(egress, connector: connector)
    error = assert_raises(Tamoz::Mcp::Websearch::RedirectHopLimitError) do
      client.fetch("https://api.search.example/start")
    end
    assert_match(/3 hops/, error.message)
  end

  def test_credential_headers_are_not_forwarded_across_hosts
    seen = []
    sequence = [
      {"status" => 302, "headers" => {"location" => "https://cdn.search.example/next"}, "body" => ""},
      {"status" => 200, "headers" => {}, "body" => "ok"}
    ]
    connector = lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
      seen << [host, headers]
      sequence.shift
    end
    client = client_with(egress, connector: connector)
    client.fetch(
      "https://api.search.example/start",
      headers: {"Authorization" => "Bearer sekrit", "Cookie" => "session=abc", "X-Subscription-Token" => "t",
                "Accept" => "application/json"}
    )
    assert seen[0][1].key?("Authorization"), "the first host gets the credential header"
    refute seen[1][1].key?("Authorization"), "the second host must not inherit Authorization"
    refute seen[1][1].key?("Cookie"), "the second host must not inherit Cookie"
    refute seen[1][1].key?("X-Subscription-Token"), "a provider's own credential header must not follow either"
    assert_equal "application/json", seen[1][1]["Accept"], "the content-negotiation headers are kept"
  end

  def test_metadata_ssrf_via_exotic_redirect_spellings_is_refused
    dials = []
    connector = lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
      dials << pinned_ip
      {"status" => 302, "headers" => {"location" => "https://0x7f000001/x"}, "body" => ""}
    end
    client = client_with(egress, connector: connector)
    assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
      client.fetch("https://api.search.example/start")
    end
    assert dials.none? { |ip| ip.include?("127") || ip.include?("169.254") }

    connector2 = lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
      dials << pinned_ip
      {"status" => 302, "headers" => {"location" => "https://2130706433/x"}, "body" => ""}
    end
    client2 = client_with(egress, connector: connector2)
    assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
      client2.fetch("https://api.search.example/start")
    end
    assert dials.none? { |ip| ip.include?("127") }
  end

  # W2: an oversize response body is bounded to max_response_bytes and marked
  # truncated (the caller turns that into the budget-breach circuit record).
  def test_response_is_bounded_to_max_response_bytes
    connector = lambda do |pinned_ip:, host:, path:, port:, timeout:, headers:, body:|
      {"status" => 200, "headers" => {}, "body" => "x" * 20_000}
    end
    client = client_with(egress, connector: connector)
    result = client.fetch("https://api.search.example/search")
    assert result.truncated
    assert_operator result.body.bytesize, :<=, 4096
  end

  # The config rule: an IP-literal target (any spelling) is refused even when
  # deny_private_ranges is off, because v1 allowlists exact FQDNs only.
  def test_ip_literal_targets_are_refused_even_without_range_checks
    policy = egress(deny: false)
    client = client_with(policy)
    ["93.184.216.34", "0x5d8ad822"].each do |host|
      assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
        client.fetch("https://#{host}/search")
      end
    end
  end

  def test_fixture_server_contains_no_resolver_or_dialer
    source = File.read(ROOT.join("script", "mcp_test_server").to_s, encoding: Encoding::UTF_8)
    refute_match(/Resolv|TCPSocket|Net::HTTP|Socket\./ , source)
  end
end

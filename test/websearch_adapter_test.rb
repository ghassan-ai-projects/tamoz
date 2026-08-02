# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/mcp/websearch"

# P17 W3/W4 (corrections 1/3): the REAL adapter's per-hop egress units behind
# the injectable resolver + connector seams. The fixture server contains no
# resolver and no dialer, so every one of these rows exercises adapter code,
# never the fixture. The dial-spy (the connector seam) records exactly the
# pinned, validated address passed to the socket dialer.
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
      connector: connector || lambda do |pinned_ip:, host:, port:, timeout:, headers:, body:|
        dials << [pinned_ip, host, headers] if dials
        {"status" => 200, "headers" => {}, "body" => "answer 42"}
      end
    )
  end

  # W3 / P17-08: resolve → range-check → allowlist-check runs on EVERY
  # connection; the dial-spy receives exactly the validated pinned IP.
  def test_per_hop_check_pins_the_validated_address
    dials = []
    client = client_with(egress, dials: dials)
    result = client.fetch("https://api.search.example/search")
    assert_equal 200, result.status
    assert_equal "answer 42", result.body
    assert_equal ["93.184.216.34"], dials.map(&:first),
                 "the dialer must receive exactly the validated pinned IP"
  end

  # W3 / P17-09: the pinned IP is dialed — a second resolution never happens,
  # so a TTL-0 rebinding answer (public at check, private at "dial") cannot
  # reach the dialer.
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

  # W3 / P17-10: private/localhost/loopback/mapped/exotic spellings are refused
  # at connect with a typed failure and ZERO dials.
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

  # W3 / P17-10 + P17-A1: IPv4-mapped, decimal, hex, and octal spellings of a
  # private address are neutralized before classification.
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

  # W3 / P17-08: an off-allowlist target is refused before any resolution or
  # dial.
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

  # W3 / P17-08: every redirect target re-runs the full resolve→classify→pin→
  # dial sequence.
  def test_redirect_target_goes_through_the_full_check_again
    dials = []
    sequence = [
      {"status" => 302, "headers" => {"location" => "https://cdn.search.example/next"}, "body" => ""},
      {"status" => 200, "headers" => {}, "body" => "final"}
    ]
    connector = lambda do |pinned_ip:, host:, port:, timeout:, headers:, body:|
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

  # W3 / P17-08: an off-allowlist redirect is refused typed with no dial for
  # the refused hop.
  def test_off_allowlist_redirect_is_refused_typed
    dials = []
    connector = lambda do |pinned_ip:, host:, port:, timeout:, headers:, body:|
      dials << pinned_ip
      {"status" => 302, "headers" => {"location" => "https://evil.example/x"}, "body" => ""}
    end
    client = client_with(egress, connector: connector)
    assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
      client.fetch("https://api.search.example/start")
    end
    assert_equal ["93.184.216.34"], dials, "the refused redirect hop is never dialed"
  end

  # W4 / P17-11: the redirect hop bound is enforced, not advisory.
  def test_redirect_hop_bound_is_enforced
    hops = 0
    connector = lambda do |pinned_ip:, host:, port:, timeout:, headers:, body:|
      hops += 1
      {"status" => 302, "headers" => {"location" => "https://cdn.search.example/h#{hops}"}, "body" => ""}
    end
    client = client_with(egress, connector: connector)
    error = assert_raises(Tamoz::Mcp::Websearch::RedirectHopLimitError) do
      client.fetch("https://api.search.example/start")
    end
    assert_match(/3 hops/, error.message)
  end

  # W4 / P17-11: no credential/header forwarding across hosts (invariant 24).
  def test_credential_headers_are_not_forwarded_across_hosts
    seen = []
    sequence = [
      {"status" => 302, "headers" => {"location" => "https://cdn.search.example/next"}, "body" => ""},
      {"status" => 200, "headers" => {}, "body" => "ok"}
    ]
    connector = lambda do |pinned_ip:, host:, port:, timeout:, headers:, body:|
      seen << [host, headers]
      sequence.shift
    end
    client = client_with(egress, connector: connector)
    client.fetch(
      "https://api.search.example/start",
      headers: {"Authorization" => "Bearer sekrit", "Cookie" => "session=abc", "X-Custom" => "kept"}
    )
    assert seen[0][1].key?("Authorization"), "the first host gets the credential header"
    refute seen[1][1].key?("Authorization"), "the second host must not inherit Authorization"
    refute seen[1][1].key?("Cookie"), "the second host must not inherit Cookie"
    assert_equal "kept", seen[1][1]["X-Custom"], "non-credential headers are preserved"
  end

  # W2 / P17-A1: a redirect Location pointing at a metadata address through an
  # exotic spelling is refused with zero dials to any spelling of that address.
  def test_metadata_ssrf_via_exotic_redirect_spellings_is_refused
    dials = []
    connector = lambda do |pinned_ip:, host:, port:, timeout:, headers:, body:|
      dials << pinned_ip
      {"status" => 302, "headers" => {"location" => "https://0x7f000001/x"}, "body" => ""}
    end
    client = client_with(egress, connector: connector)
    assert_raises(Tamoz::Mcp::Websearch::EgressPolicyError) do
      client.fetch("https://api.search.example/start")
    end
    assert dials.none? { |ip| ip.include?("127") || ip.include?("169.254") }

    connector2 = lambda do |pinned_ip:, host:, port:, timeout:, headers:, body:|
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
    connector = lambda do |pinned_ip:, host:, port:, timeout:, headers:, body:|
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

  # The fixture (script/mcp_test_server) contains no resolver and no dialer, so
  # the W3 suite demonstrably runs against adapter code, never the fixture
  # (P17-03). Read as UTF-8 explicitly so the check is locale-independent.
  def test_fixture_server_contains_no_resolver_or_dialer
    source = File.read(ROOT.join("script", "mcp_test_server").to_s, encoding: Encoding::UTF_8)
    refute_match(/Resolv|TCPSocket|Net::HTTP|Socket\./ , source)
  end
end

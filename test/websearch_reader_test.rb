# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/mcp/websearch'

# The research side of websearch: Brave search with its fixed endpoint, the page reader over the egress client's
# reader mode, the HTML-to-text extraction, and the fixture web the offline tests read.
# rubocop:disable Minitest/MultipleAssertions -- each case reads one request or page from several sides.
class WebsearchReaderTest < Minitest::Test
  W = Tamoz::Mcp::Websearch
  PUBLIC = { 'news.example.org' => ['93.184.216.40'], 'api.search.brave.com' => ['93.184.216.41'],
             'intranet.example.org' => ['10.0.0.7'] }.freeze
  ARTICLE = <<~HTML
    <html><head><title>Ignored title</title><meta property="og:title" content="Oslo grows">
    <meta property="article:published_time" content="2025-02-01"><script>alert(1)</script></head>
    <body><nav>Home | News</nav><header>Site header</header>
    <article><h1>Oslo grows again</h1><p>Oslo had   717,710 residents
    in 2025.</p><ul><li>Up 1.2%</li></ul><aside>Ads</aside></article><footer>Contact</footer></body></html>
  HTML

  def test_the_reader_mode_reaches_a_public_host_nobody_listed
    dials = []
    body = reader_client(dials, { 'content-type' => 'text/html' }) { ARTICLE }.fetch('https://news.example.org/a').body

    assert_includes body, 'Oslo grows again'
    assert_equal([['93.184.216.40', 'news.example.org']], dials.map { |dial| dial.first(2) })
  end

  def test_the_reader_mode_still_refuses_private_addresses_ip_literals_and_http
    client = reader_client([], {}) { 'x' }

    assert_raises(W::EgressPolicyError) { client.fetch('https://intranet.example.org/') }
    assert_raises(W::EgressPolicyError) { client.fetch('https://10.0.0.7/') }
    assert_raises(W::EgressPolicyError) { client.fetch('http://news.example.org/') }
  end

  def test_the_reader_mode_needs_the_declared_opt_in_and_bounds_its_body
    assert_raises(Tamoz::Mcp::ValidationError) { W::EgressClient.new(policy: policy(deny: false), reach: :public) }
    assert_raises(Tamoz::Mcp::ValidationError) do
      W::EgressClient.new(policy: policy(page_reads: 'none'), reach: :public)
    end
    large = reader_client([], { 'content-type' => 'text/plain' }) { 'a' * (3 * 1024 * 1024) }.fetch('https://news.example.org/')

    assert large.truncated
    assert_equal W::EgressClient::READER_MAX_RESPONSE_BYTES, large.body.bytesize
  end

  def test_a_redirect_from_a_public_page_to_a_private_address_or_an_ip_literal_is_refused
    %w[https://intranet.example.org/admin https://169.254.169.254/latest].each do |location|
      dials = []
      client = W::EgressClient.new(
        policy:, reach: :public, resolver: ->(host) { PUBLIC.fetch(host, []) },
        connector: lambda do |host:, **|
          dials << host
          { 'status' => 302, 'headers' => { 'location' => location }, 'body' => '' }
        end
      )

      assert_raises(W::EgressPolicyError) { client.fetch('https://news.example.org/a') }
      assert_equal ['news.example.org'], dials
    end
  end

  def test_a_brave_redirect_to_another_host_carries_no_token
    seen = []
    W::BraveSearch.new(client: redirecting_brave(seen), token: 'brave-token').search('q', 1)

    assert_equal 'brave-token', seen.first.last.fetch('X-Subscription-Token')
    refute seen.last.last.key?('X-Subscription-Token')
    assert seen.last.last.key?('Accept')
  end

  def test_ipv6_blocks_that_tunnel_to_ipv4_are_refused
    refused = %w[64:ff9b::a00:7 2002:a00:7::1 2001:0:4136:e378::1 fec0::1 2001:db8::1]

    refused.each { |address| assert(policy.private_range?(address), "#{address} must be refused") }

    refute policy.private_range?('2606:4700::6810:84e5')
  end

  def test_the_search_mode_still_refuses_a_host_off_the_allowlist
    client = W::EgressClient.new(policy: policy, resolver: ->(host) { PUBLIC.fetch(host, []) },
                                 connector: ->(**) { { 'status' => 200, 'headers' => {}, 'body' => '' } })

    assert_raises(W::EgressPolicyError) { client.fetch('https://news.example.org/') }
  end

  def test_page_text_keeps_the_article_and_drops_the_page_furniture
    page = W::PageText.extract(ARTICLE)

    assert_equal 'Oslo grows', page.title
    assert_equal '2025-02-01', page.published
    assert_equal "# Oslo grows again\n\nOslo had 717,710 residents in 2025.\n\n- Up 1.2%", page.text
    %w[alert Home Contact Ads header].each { |furniture| refute_includes page.text, furniture }
  end

  def test_page_text_prefers_the_largest_article_and_keeps_text_in_divs
    html = <<~HTML
      <body><form><article><p>Related: a teaser.</p></article>
      <main><div>Intro sentence in a div.<p>Para one.</p><p>Para two.</p>Tail in the div.</div></main></form></body>
    HTML
    text = W::PageText.extract(html).text

    assert_equal "Intro sentence in a div.\n\nPara one.\n\nPara two.\n\nTail in the div.", text
  end

  def test_a_credential_shaped_link_does_not_eat_the_page
    html = '<body><p>Reset <a href="/r?password=x">here</a>.</p><p>Next paragraph stays.</p></body>'
    page = W::PageReader.new(client: reader_client([], { 'content-type' => 'text/html' }) { html })
                        .read('https://news.example.org/r')

    assert_includes page.fetch('text'), 'Next paragraph stays.'
  end

  def test_page_text_finds_a_date_in_a_time_element_or_json_ld
    timed = W::PageText.extract('<body><time datetime="2024-05-06">May</time><p>Body text here.</p></body>')
    json_ld = W::PageText.extract('<head><script type="application/ld+json">{"datePublished":"2023-01-02"}</script>' \
                                  '</head><body><p>Body.</p></body>')

    assert_equal '2024-05-06', timed.published
    assert_equal '2023-01-02', json_ld.published
  end

  def test_the_page_reader_takes_markdown_as_served_and_refuses_what_is_not_text
    markdown = W::PageReader.new(client: reader_client([], { 'content-type' => 'text/markdown; charset=utf-8' }) do
      "# Title\n\nBody from a markdown-serving site."
    end).read('https://news.example.org/md')

    assert_equal "# Title\n\nBody from a markdown-serving site.", markdown.fetch('text')
    image = W::PageReader.new(client: reader_client([], { 'content-type' => 'image/png' }) { 'PNG' })

    assert_raises(W::EgressPolicyError) { image.read('https://news.example.org/i.png') }
  end

  def test_the_page_reader_asks_for_markdown_first_and_reports_http_failures
    seen = []
    reader = W::PageReader.new(client: reader_client(seen, { 'content-type' => 'text/html' }, status: 404) { '' })

    assert_raises(W::EgressPolicyError) { reader.read('https://news.example.org/gone') }
    assert_match(%r{\Atext/markdown}, seen.first.last.fetch('Accept'))
  end

  def test_brave_search_uses_its_fixed_endpoint_and_token_and_clamps_the_count
    requests = []
    search = W::BraveSearch.new(client: brave_client(requests), token: 'brave-token')
    results = search.search('oslo population', 50)

    assert_equal [{ 'title' => 'Oslo facts', 'url' => 'https://ssb.no/oslo', 'snippet' => 'Oslo has 717,710.',
                    'age' => '2025-02-01' }], results
    host, path, headers = requests.first

    assert_equal 'api.search.brave.com', host
    assert_includes path, 'count=10'
    assert_includes path, 'q=oslo+population'
    assert_equal 'brave-token', headers.fetch('X-Subscription-Token')
  end

  def test_brave_search_refuses_a_policy_that_does_not_allowlist_it
    other = policy(hosts: ['other.example.org'])
    client = W::EgressClient.new(policy: other, resolver: ->(_) { [] }, connector: ->(**) {})

    assert_raises(Tamoz::Mcp::ValidationError) { W::BraveSearch.new(client:, token: 't') }
    assert_raises(Tamoz::Mcp::ValidationError) { W::BraveSearch.new(client: brave_client([]), token: '') }
    unnamed = W::EgressClient.new(policy: W::EgressPolicy.new(declaration_without_refs),
                                  resolver: ->(_) { [] }, connector: ->(**) {})

    assert_raises(Tamoz::Mcp::ValidationError) { W::BraveSearch.new(client: unnamed, token: 't') }
  end

  def test_the_fixture_web_finds_pages_by_the_words_of_a_query
    web = W::FixtureWeb.new('pages' => [
      { 'url' => 'https://a.org/1', 'title' => 'Oslo population',
        'text' => 'Oslo has 717,710.' },
      { 'url' => 'https://b.org/2', 'title' => 'Bergen', 'text' => 'Bergen is rainy.' }
    ])

    assert_equal(['https://a.org/1'], web.search('population of Oslo', 5).map { |hit| hit.fetch('url') })
    assert_empty web.search('zz', 5)
    assert_equal 'Bergen is rainy.', web.read('https://b.org/2').fetch('text')
    assert_raises(W::EgressPolicyError) { web.read('https://c.org/unknown') }
  end

  private

  def policy(deny: true, hosts: ['api.search.brave.com'], page_reads: 'public')
    W::EgressPolicy.new(
      'allowlisted_hosts' => hosts, 'schemes' => ['https'], 'deny_private_ranges' => deny, 'page_reads' => page_reads,
      'max_request_bytes' => 2048, 'max_response_bytes' => 65_536, 'connect_timeout_s' => 10,
      'redirect_max_hops' => 3, 'circuit' => { 'threshold' => 3, 'scope_type' => 'egress', 'budget_breach' => true },
      'credential_refs' => ['TAMOZ_BRAVE_API_KEY']
    )
  end

  def redirecting_brave(seen)
    W::EgressClient.new(
      policy: policy(hosts: %w[api.search.brave.com news.example.org]), resolver: ->(host) { PUBLIC.fetch(host, []) },
      connector: lambda do |host:, headers:, **|
        seen << [host, headers]
        next { 'status' => 302, 'headers' => { 'location' => 'https://news.example.org/x' }, 'body' => '' } if
          host == 'api.search.brave.com'

        { 'status' => 200, 'headers' => {}, 'body' => '{"web":{"results":[]}}' }
      end
    )
  end

  def declaration_without_refs
    { 'allowlisted_hosts' => ['api.search.brave.com'], 'schemes' => ['https'], 'deny_private_ranges' => true,
      'max_request_bytes' => 2048, 'max_response_bytes' => 65_536, 'connect_timeout_s' => 10, 'redirect_max_hops' => 3,
      'circuit' => { 'threshold' => 3, 'scope_type' => 'egress', 'budget_breach' => true }, 'credential_refs' => [] }
  end

  def reader_client(dials, response_headers, status: 200, &body)
    W::EgressClient.new(
      policy:, reach: :public, max_response_bytes: W::EgressClient::READER_MAX_RESPONSE_BYTES,
      resolver: ->(host) { PUBLIC.fetch(host, []) },
      connector: lambda do |pinned_ip:, host:, headers:, **|
        dials << [pinned_ip, host, headers]
        { 'status' => status, 'headers' => response_headers, 'body' => yield }
      end
    )
  end

  def brave_client(requests)
    body = JSON.generate('web' => { 'results' => [{ 'title' => '<strong>Oslo</strong> facts', 'url' => 'https://ssb.no/oslo',
                                                    'description' => 'Oslo has <strong>717,710</strong>.',
                                                    'page_age' => '2025-02-01' }] })
    W::EgressClient.new(
      policy:, resolver: ->(host) { PUBLIC.fetch(host, []) },
      connector: lambda do |host:, path:, headers:, **|
        requests << [host, path, headers]
        { 'status' => 200, 'headers' => {}, 'body' => body }
      end
    )
  end
end
# rubocop:enable Minitest/MultipleAssertions

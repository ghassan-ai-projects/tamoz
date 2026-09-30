# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/mcp/websearch'
require 'pathname'

# The operator-side adapter's gate and page rules, without a subprocess.
load Pathname.new(__dir__).join('..', 'script', 'websearch_adapter').to_s unless defined?(WebsearchAdapter)

# -- each case reads one adapter response from several sides.
class WebsearchProviderTest < Minitest::Test
  FLAGS = %w[TAMOZ_WEBSEARCH_GRANT TAMOZ_WEBSEARCH_EGRESS TAMOZ_WEBSEARCH_PROVIDER].freeze

  def setup
    @saved = ENV.to_h.slice(*FLAGS)
    @dir = Dir.mktmpdir('tamoz-websearch-provider')
    @web = File.join(@dir, 'web.json')
    @document = JSON.generate('pages' => [
      { 'url' => 'https://ssb.no/oslo', 'title' => "Oslo population #{'"é' * 300}", 'published' => '2025-02-01',
        'text' => "Oslo had 717,710 residents. #{"\"\\é\u0001" * 2000}" }
    ])
    File.write(@web, @document)
    ENV['TAMOZ_WEBSEARCH_GRANT'] = '1'
    ENV['TAMOZ_WEBSEARCH_EGRESS'] = JSON.generate(egress)
    ENV['TAMOZ_WEBSEARCH_PROVIDER'] = JSON.generate('search' => 'fixture', 'reader' => 'fixture', 'web' => @web)
    WebsearchAdapter.reset!
  end

  def teardown
    FLAGS.each { |name| ENV.delete(name) }
    @saved.each { |name, value| ENV[name] = value }
    FileUtils.remove_entry(@dir)
  end

  def test_a_search_answers_json_results_and_a_page_read_follows_one
    results = JSON.parse(text(WebsearchAdapter.search_response('Oslo population', 3))).fetch('results')

    assert_equal(['https://ssb.no/oslo'], results.map { |result| result.fetch('url') })
    page = JSON.parse(text(WebsearchAdapter.read_page_response('https://ssb.no/oslo')))

    assert page.fetch('title').start_with?('Oslo population')
    assert_includes page.fetch('text'), 'Oslo had 717,710 residents.'
  end

  def test_a_page_read_refuses_a_url_no_search_returned
    response = WebsearchAdapter.read_page_response('https://ssb.no/oslo')

    assert_predicate response, :error?
    assert_includes text(response), 'a search on this server returned'
  end

  def test_a_page_is_fetched_once_and_cut_to_the_output_budget
    WebsearchAdapter.search_response('Oslo', 3)
    first = JSON.parse(text(WebsearchAdapter.read_page_response('https://ssb.no/oslo')))
    File.write(@web, JSON.generate('pages' => []))
    again = JSON.parse(text(WebsearchAdapter.read_page_response('https://ssb.no/oslo')))

    assert_equal first, again
    assert first.fetch('truncated')
    assert_operator text(WebsearchAdapter.read_page_response('https://ssb.no/oslo')).bytesize, :<=,
                    egress.fetch('max_response_bytes')
  end

  def test_the_providers_are_named_never_an_endpoint
    ['{"provider":"http","endpoint":"https://evil.example/collect"}',
     '{"search":"brave","reader":"direct","endpoint":"https://evil.example"}',
     '{"search":"fixture","reader":"fixture"}'].each do |config|
      ENV['TAMOZ_WEBSEARCH_PROVIDER'] = config

      assert_includes text(WebsearchAdapter.search_response('Oslo', 1)), 'must name search'
    end
  end

  def test_nothing_is_served_without_the_operator_grant
    ENV.delete('TAMOZ_WEBSEARCH_GRANT')

    assert_includes text(WebsearchAdapter.search_response('Oslo', 1)), 'operator grant'
    assert_includes text(WebsearchAdapter.read_page_response('https://ssb.no/oslo')), 'operator grant'
  end

  def test_three_provider_failures_in_a_row_open_the_declared_circuit
    File.write(@web, '{broken')
    3.times { assert_predicate WebsearchAdapter.search_response('Oslo', 3), :error? }

    refusal = WebsearchAdapter.search_response('Oslo', 3)

    assert_includes text(refusal), 'circuit is open'
  end

  def test_a_success_between_failures_keeps_the_circuit_closed
    File.write(@web, '{broken')
    2.times { assert_predicate WebsearchAdapter.search_response('Oslo', 3), :error? }
    File.write(@web, @document)

    refute_predicate WebsearchAdapter.search_response('Oslo', 3), :error?

    File.write(@web, '{broken')
    refusal = WebsearchAdapter.search_response('Oslo', 3)

    assert_predicate refusal, :error?
    refute_includes text(refusal), 'circuit is open'
  end

  private

  def text(response) = response.content.first.fetch(:text)

  def egress
    { 'allowlisted_hosts' => ['api.search.brave.com'], 'schemes' => ['https'], 'deny_private_ranges' => true,
      'max_request_bytes' => 2048, 'max_response_bytes' => 4096, 'connect_timeout_s' => 10, 'redirect_max_hops' => 3,
      'circuit' => { 'threshold' => 3, 'scope_type' => 'egress', 'budget_breach' => true },
      'credential_refs' => ['TAMOZ_BRAVE_API_KEY'], 'page_reads' => 'public' }
  end
end

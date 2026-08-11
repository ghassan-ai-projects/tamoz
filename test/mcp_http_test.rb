# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/mcp_http_fixture_server'

# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength

class McpHttpTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Catalog = Tamoz::Mcp::Catalog
  Invocation = Tamoz::Mcp::Invocation
  HttpSupervisor = Tamoz::Mcp::HttpSupervisor

  def with_server
    server = McpHttpFixtureServer.new
    begin
      yield server
    ensure
      server.stop
    end
  end

  def config(server, credential_refs: [], credential_headers: {})
    ServerConfig.new(
      server_id: 'remote',
      transport: :http,
      endpoint: server.url,
      headers: { 'X-Tamoz-Client' => 'test' },
      credential_refs:,
      credential_headers:
    )
  end

  def test_catalog_and_invocation_use_the_real_streamable_http_client
    with_server do |server|
      original = ENV.fetch('TAMOZ_MCP_HTTP_TOKEN', nil)
      ENV['TAMOZ_MCP_HTTP_TOKEN'] = 'secret-token'
      remote = config(
        server,
        credential_refs: ['TAMOZ_MCP_HTTP_TOKEN'],
        credential_headers: { 'Authorization' => 'TAMOZ_MCP_HTTP_TOKEN' }
      )

      snapshot = Catalog.compile(remote)
      entry = snapshot.entries.fetch(0)
      descriptor = Invocation.descriptor_for(entry, snapshot:, effect_class: :read_only)
      supervisor = HttpSupervisor.new(remote)
      outcome = Invocation.call(descriptor, {}, snapshot:, supervisor:)

      assert_equal 'done', outcome.observation.text
      assert_equal :http, remote.transport
      assert_equal 'http', remote.describe.fetch('transport')
      post_requests = server.requests.select { |request| request.fetch(:method) == 'POST' }

      assert_equal(%w[initialize notifications/initialized tools/list initialize notifications/initialized tools/call],
                   post_requests.map { |request| request.fetch(:payload).fetch('method') })
      assert(post_requests.all? { |request| request.fetch(:headers).fetch('authorization') == 'secret-token' })
      assert(post_requests.all? { |request| request.fetch(:headers).fetch('x-tamoz-client') == 'test' })
    ensure
      supervisor&.close
      ENV['TAMOZ_MCP_HTTP_TOKEN'] = original
    end
  end

  def test_missing_http_credential_fails_before_any_request
    with_server do |server|
      remote = config(
        server,
        credential_refs: ['TAMOZ_MCP_HTTP_TOKEN'],
        credential_headers: { 'Authorization' => 'TAMOZ_MCP_HTTP_TOKEN' }
      )

      error = assert_raises(Tamoz::Mcp::ValidationError) { HttpSupervisor.new(remote, environ: {}).start }
      assert_match(/TAMOZ_MCP_HTTP_TOKEN/, error.message)
      assert_empty server.requests
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength

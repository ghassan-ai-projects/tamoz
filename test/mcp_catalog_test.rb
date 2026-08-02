# frozen_string_literal: true

require_relative "test_helper"

class McpCatalogTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Budgets = ServerConfig::Budgets
  Catalog = Tamoz::Mcp::Catalog

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  # Inherited by the child so plain Ruby finds its gems regardless of the
  # operator's locale or bundler setup. All entries are non-credential names.
  BASE_ENV_ALLOWLIST = %w[
    PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB
  ].freeze

  # Exact digest expectations for the fixture below (6 tools — P17 added the
  # deterministic `search` fixture tool; protocol 2026-07-28, server_id
  # "test-server"). Pinned from a real compile; the determinism test below
  # proves the compiler reproduces them.
  EXPECTED_SNAPSHOT_DIGEST =
    "sha256:1f6d55d7d7733b8c1a83309e23a9ca05fccaaf3b26274ceeddeb55bc71a16f8b"
  EXPECTED_ENTRY_DIGESTS = {
    "echo_constant" => "sha256:d60e00d326bed04f3c898de73049f0659689e1569b01063ecc5a5235718450a1",
    "set_answer" => "sha256:7aae47642bbb1aa31d94ed1cc1d7e4e178d20944d0f86256c7c6a91f7a7f13fe",
    "needs_input" => "sha256:340fcbbb7cd6cab13926eaf6fde0e15c27f95b4c4ac2a9bcc5e64e709296fb6b",
    "churn" => "sha256:99dc452b9edb93bb6795f3fae206d792d646d417d89425b96d25581d42bec07b",
    "sleep_ms" => "sha256:b34d03e93dfc08e0ee02f82065cddd920b25d87ac1c63be527cc0c9d7468375e",
    "search" => "sha256:b781ffafcb164d5ff1bce99bc148afa85ba09e420a3a7a0b6b37af410360726c"
  }.freeze

  def setup
    @dir = Dir.mktmpdir("tamoz-mcp-catalog")
    @saved_flags = ENV.to_h.slice(*env_flag_names)
  end

  def teardown
    env_flag_names.each { |name| ENV.delete(name) }
    @saved_flags.each { |name, value| ENV[name] = value }
    FileUtils.remove_entry(@dir)
  end

  def env_flag_names
    %w[
      MCP_TEST_SERVER_MALFORMED_FRAMES MCP_TEST_SERVER_MALFORMED_MID_CALL
      MCP_TEST_SERVER_EXIT_MID_CALL
      MCP_TEST_SERVER_OVERSIZE_OUTPUT MCP_TEST_SERVER_EXTRA_TOOLS
      MCP_TEST_SERVER_LONG_DESCRIPTION MCP_TEST_SERVER_PROTOCOL_VERSION
      MCP_TEST_SERVER_GRANDCHILD
    ]
  end

  def build_config(overrides = {})
    ServerConfig.new(
      **{
        server_id: "test-server",
        transport: :stdio,
        command: RbConfig.ruby,
        arguments: [SERVER_SCRIPT, File.join(@dir, "answer.txt")],
        working_directory: @dir,
        env_allowlist: BASE_ENV_ALLOWLIST + env_flag_names
      }.merge(overrides)
    )
  end

  # --- successful compile ----------------------------------------------------

  def test_compile_produces_immutable_catalog_with_exact_digests
    catalog = Catalog.compile(build_config)

    assert_predicate catalog, :frozen?
    assert_predicate catalog.entries, :frozen?
    assert(catalog.entries.all?(&:frozen?))
    assert_raises(FrozenError) { catalog.entries << nil }

    assert_equal "test-server", catalog.server_id
    assert_equal "2026-07-28", catalog.protocol_version
    assert_equal EXPECTED_SNAPSHOT_DIGEST, catalog.snapshot_digest
    assert_equal EXPECTED_ENTRY_DIGESTS.keys.sort, catalog.entries.map(&:name).sort
    catalog.entries.each do |entry|
      assert_equal :tool, entry.kind
      assert_equal EXPECTED_ENTRY_DIGESTS.fetch(entry.name), entry.definition_digest
      assert_match(/\Asha256:[0-9a-f]{64}\z/, entry.definition_digest)
      assert_predicate entry.schema, :frozen?
    end
  end

  def test_compile_is_deterministic_across_runs
    first = Catalog.compile(build_config)
    second = Catalog.compile(build_config)

    assert_equal first.snapshot_digest, second.snapshot_digest
    assert_equal(
      first.entries.map(&:definition_digest),
      second.entries.map(&:definition_digest)
    )
  end

  def test_compile_leaves_no_process_behind
    supervisor_pid = nil
    factory = lambda do |supervisor|
      client = MCP::Client.new(transport: supervisor)
      supervisor_pid = supervisor
      client
    end
    Catalog.compile(build_config, client_factory: factory)

    assert_raises(Errno::ESRCH) { Process.kill(0, -supervisor_pid.pid) }
  end

  # --- protocol negotiation ---------------------------------------------------

  def test_protocol_outside_configured_range_fails_closed
    # The server falls back to 2024-11-05 when the offered version is unknown
    # to it; the configured range excludes that, so the compile must stop.
    ENV["MCP_TEST_SERVER_PROTOCOL_VERSION"] = "2024-11-05"
    config = build_config(protocol_range: ["2030-01-01", "2031-01-01"])

    error = assert_raises(Tamoz::Mcp::ProtocolError) { Catalog.compile(config) }
    assert_equal "mcp_protocol", error.category
    assert_match(/outside the configured range/, error.message)
  end

  def test_malformed_frames_fail_as_protocol_error_without_server_content
    ENV["MCP_TEST_SERVER_MALFORMED_FRAMES"] = "1"

    error = assert_raises(Tamoz::Mcp::ProtocolError) { Catalog.compile(build_config) }
    refute_match(/not a json-rpc frame/i, error.message)
  end

  # --- budgets -----------------------------------------------------------------

  def test_catalog_exceeding_max_catalog_entries_is_rejected
    ENV["MCP_TEST_SERVER_EXTRA_TOOLS"] = "10"
    config = build_config(budgets: Budgets.new(max_catalog_entries: 8))

    error = assert_raises(Tamoz::Mcp::ProtocolError) { Catalog.compile(config) }
    assert_match(/16 entries/, error.message)
    assert_match(/budget of 8/, error.message)
  end

  def test_descriptions_are_control_stripped_and_byte_bounded
    ENV["MCP_TEST_SERVER_LONG_DESCRIPTION"] = "1"
    config = build_config(budgets: Budgets.new(max_description_bytes: 100))

    catalog = Catalog.compile(config)
    verbose = catalog.entries.find { |entry| entry.name == "verbose" }

    refute_nil verbose
    assert_operator verbose.description.bytesize, :<=, 100
    refute_match(/[\x00-\x1f\x7f]/, verbose.description)
    assert_predicate verbose.description, :valid_encoding?
  end

  # --- credential hygiene -------------------------------------------------------

  def test_credential_values_never_appear_in_errors_or_stderr_metadata
    secret = "tamoz-test-credential-9f8e7d6c"
    ENV["TAMOZ_MCP_TEST_CREDENTIAL"] = secret
    ENV["MCP_TEST_SERVER_MALFORMED_FRAMES"] = "1"
    config = build_config(credential_refs: %w[TAMOZ_MCP_TEST_CREDENTIAL])

    supervisor = nil
    factory = lambda do |sup|
      supervisor = sup
      MCP::Client.new(transport: sup)
    end
    error = assert_raises(Tamoz::Mcp::ProtocolError) do
      Catalog.compile(config, client_factory: factory)
    end

    refute_includes error.message, secret
    refute_includes error.full_message, secret
    refute_includes supervisor.stderr_tail, secret
    refute_includes config.describe.to_s, secret
  ensure
    ENV.delete("TAMOZ_MCP_TEST_CREDENTIAL")
  end

  def test_missing_credential_ref_fails_closed_naming_only_the_variable
    ENV.delete("TAMOZ_MCP_TEST_CREDENTIAL")
    config = build_config(credential_refs: %w[TAMOZ_MCP_TEST_CREDENTIAL])

    error = assert_raises(Tamoz::Mcp::ValidationError) { Catalog.compile(config) }
    assert_match(/TAMOZ_MCP_TEST_CREDENTIAL/, error.message)
  end
end

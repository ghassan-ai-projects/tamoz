# frozen_string_literal: true

require_relative "test_helper"

class McpServerConfigTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Budgets = ServerConfig::Budgets
  ValidationError = Tamoz::Mcp::ValidationError

  def setup
    @dir = Dir.mktmpdir("tamoz-mcp-config", "/private/tmp")
    @workspace = Dir.mktmpdir("tamoz-mcp-workspace", "/private/tmp")
    @command = File.join(@dir, "server")
    File.write(@command, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, @command)
  end

  def teardown
    FileUtils.remove_entry(@dir)
    FileUtils.remove_entry(@workspace)
  end

  def valid_attributes(overrides = {})
    {
      server_id: "test-server",
      transport: :stdio,
      command: @command,
      working_directory: @dir
    }.merge(overrides)
  end

  def build(overrides = {})
    ServerConfig.new(**valid_attributes(overrides))
  end

  def assert_invalid(overrides, pattern)
    error = assert_raises(ValidationError) { build(overrides) }
    assert_match pattern, error.message
    error
  end

  # --- happy path -----------------------------------------------------------

  def test_valid_config_applies_defaults_and_deep_freezes
    config = build

    assert_equal "test-server", config.server_id
    assert_equal :stdio, config.transport
    assert_equal @command, config.command
    assert_equal [], config.arguments
    assert_equal [], config.env_allowlist
    assert_equal [], config.credential_refs
    assert_equal @dir, config.working_directory
    assert_equal ["2025-11-25", "2026-07-28"], config.protocol_range
    assert_equal [:tools], config.primitives
    assert_equal Budgets.new, config.budgets

    assert_predicate config, :frozen?
    assert_predicate config.arguments, :frozen?
    assert_predicate config.env_allowlist, :frozen?
    assert_predicate config.credential_refs, :frozen?
    assert_predicate config.protocol_range, :frozen?
    assert_predicate config.primitives, :frozen?
    assert_raises(FrozenError) { config.arguments << "x" }
  end

  def test_valid_config_accepts_full_surface
    config = build(
      arguments: ["--port", "8080"],
      env_allowlist: %w[PATH HOME LANG],
      credential_refs: %w[TAMOZ_MCP_TOKEN],
      protocol_range: ["2025-11-25", "2025-11-25"],
      primitives: %i[tools resources prompts],
      budgets: Budgets.new(max_concurrent: 1, request_timeout: 5),
      workspace_root: @workspace
    )

    assert_equal ["--port", "8080"], config.arguments
    assert_equal %w[PATH HOME LANG], config.env_allowlist
    assert_equal %w[TAMOZ_MCP_TOKEN], config.credential_refs
    assert_equal ["2025-11-25", "2025-11-25"], config.protocol_range
    assert_equal %i[tools resources prompts], config.primitives
    assert_equal 1, config.budgets.max_concurrent
    assert_equal 5, config.budgets.request_timeout
    assert(config.arguments.all?(&:frozen?))
    assert(config.env_allowlist.all?(&:frozen?))
  end

  def test_describe_previews_names_only_never_values
    config = build(
      arguments: ["serve"],
      env_allowlist: %w[PATH],
      credential_refs: %w[TAMOZ_MCP_TOKEN]
    )
    preview = config.describe

    assert_predicate preview, :frozen?
    assert_equal @command, preview.fetch("command")
    assert_equal [@command, "serve"], preview.fetch("argv")
    assert_equal %w[PATH], preview.fetch("env_allowlist")
    assert_equal %w[TAMOZ_MCP_TOKEN], preview.fetch("credential_refs")
    assert_equal "stdio", preview.fetch("transport")
    assert_equal ["2025-11-25", "2026-07-28"], preview.fetch("protocol_range")
    assert_equal %w[tools], preview.fetch("primitives")
    assert_equal 64 * 1024, preview.dig("budgets", "max_output_bytes")
    # Names only: no entry anywhere in the preview carries an environment value.
    refute preview.to_s.include?(ENV.fetch("HOME", "\u0000never"))
  end

  # --- server_id ------------------------------------------------------------

  def test_server_id_pattern_is_enforced
    assert_invalid({server_id: "Test"}, /server_id/)
    assert_invalid({server_id: "1server"}, /server_id/)
    assert_invalid({server_id: "server!"}, /server_id/)
    assert_invalid({server_id: "a" * 65}, /server_id/)
    assert_invalid({server_id: :"test-server"}, /server_id/)
    assert_equal "a#{"b" * 63}", build(server_id: "a#{"b" * 63}").server_id
  end

  # --- transport --------------------------------------------------------------

  def test_http_transport_requires_an_endpoint
    assert_invalid({transport: :http}, /endpoint/)
  end

  def test_http_transport_accepts_a_loopback_endpoint_without_a_process
    config = ServerConfig.new(server_id: "remote", transport: :http, endpoint: "http://127.0.0.1:8787/mcp")

    assert_nil config.command
    assert_nil config.working_directory
    assert_equal "http://127.0.0.1:8787/mcp", config.endpoint
  end

  def test_remote_http_requires_tls
    assert_invalid({transport: :http, endpoint: "http://remote.example/mcp"}, /https/)
  end

  def test_private_http_accepts_an_explicit_opt_in
    config = ServerConfig.new(
      server_id: "remote", transport: :http,
      endpoint: "http://10.0.0.1:8787/mcp", allow_insecure_http: true
    )

    assert config.allow_insecure_http
    assert config.describe.fetch("allow_insecure_http")
  end

  def test_private_http_opt_in_does_not_allow_a_public_host
    assert_invalid(
      {transport: :http, endpoint: "http://remote.example/mcp", allow_insecure_http: true},
      /https/
    )
  end

  def test_private_http_opt_in_must_be_boolean
    assert_invalid(
      {transport: :http, endpoint: "http://10.0.0.1:8787/mcp", allow_insecure_http: "true"},
      /allow_insecure_http.*boolean/
    )
  end

  def test_http_credential_headers_are_names_only_and_must_reference_a_credential
    config = ServerConfig.new(
      server_id: "remote",
      transport: :http,
      endpoint: "http://127.0.0.1:8787/mcp",
      credential_refs: ["TAMOZ_MCP_TOKEN"],
      credential_headers: { "Authorization" => "TAMOZ_MCP_TOKEN" }
    )

    assert_equal({ "Authorization" => "TAMOZ_MCP_TOKEN" }, config.credential_headers)
    assert_equal ["Authorization"], config.describe.fetch("credential_headers")
    error = assert_raises(ValidationError) do
      ServerConfig.new(
        server_id: "remote",
        transport: :http,
        endpoint: "http://127.0.0.1:8787/mcp",
        credential_headers: { "Authorization" => "TAMOZ_MCP_TOKEN" }
      )
    end
    assert_match(/credential_headers/, error.message)
  end

  def test_unknown_transport_is_rejected
    assert_invalid({transport: :websocket}, /transport/)
    assert_invalid({transport: "stdio"}, /transport/)
  end

  # --- command ----------------------------------------------------------------

  def test_command_must_be_absolute
    assert_invalid({command: "server"}, /absolute/)
    assert_invalid({command: "./server"}, /absolute/)
    assert_invalid({command: nil}, /absolute/)
  end

  def test_command_must_exist_as_a_file
    assert_invalid({command: File.join(@dir, "missing")}, /does not exist/)
    assert_invalid({command: @dir}, /does not exist/)
  end

  def test_command_must_be_executable
    plain = File.join(@dir, "plain")
    File.write(plain, "x")
    File.chmod(0o644, plain)

    assert_invalid({command: plain}, /not executable/)
  end

  def test_command_must_not_be_a_symlink
    link = File.join(@dir, "link")
    File.symlink(@command, link)

    assert_invalid({command: link}, /symlink/)
  end

  def test_command_must_not_be_inside_the_workspace
    inner = File.join(@workspace, "bin", "server")
    FileUtils.mkdir_p(File.dirname(inner))
    File.write(inner, "#!/bin/sh\nexit 0\n")
    File.chmod(0o755, inner)

    assert_invalid({command: inner, workspace_root: @workspace}, /workspace/)
  end

  def test_command_outside_workspace_is_accepted_when_root_is_supplied
    config = build(workspace_root: @workspace)

    assert_equal @command, config.command
  end

  def test_workspace_root_must_be_absolute_and_existing_when_supplied
    assert_invalid({workspace_root: "relative"}, /workspace_root/)
    assert_invalid({workspace_root: File.join(@dir, "missing")}, /workspace_root/)
  end

  # --- arguments --------------------------------------------------------------

  def test_arguments_must_be_strings
    assert_invalid({arguments: "serve"}, /array/)
    assert_invalid({arguments: [1]}, /strings/)
    assert_invalid({arguments: [nil]}, /strings/)
    assert_invalid({arguments: [:serve]}, /strings/)
  end

  def test_arguments_reject_nul_and_control_characters
    assert_invalid({arguments: ["a\x00b"]}, /NUL/)
    assert_invalid({arguments: ["a\nb"]}, /control character/)
    assert_invalid({arguments: ["a\x7fb"]}, /control character/)
  end

  def test_arguments_reject_shell_metacharacters
    ["a;b", "a|b", "a>b", "a<b", "a&b", "a$b", "a`b", "a*b"].each do |element|
      assert_invalid({arguments: [element]}, /metacharacters/)
    end
  end

  def test_arguments_reject_oversize_elements
    assert_invalid({arguments: ["a" * 4097]}, /4096/)
  end

  # --- env_allowlist ----------------------------------------------------------

  def test_env_allowlist_entries_must_be_valid_names
    assert_invalid({env_allowlist: "PATH"}, /array/)
    assert_invalid({env_allowlist: ["1PATH"]}, /valid names/)
    assert_invalid({env_allowlist: ["MY VAR"]}, /valid names/)
    assert_invalid({env_allowlist: [nil]}, /valid names/)
  end

  def test_env_allowlist_rejects_credential_shaped_names
    %w[
      API_KEY MY_API_KEY SECRET_KEY AWS_ACCESS_KEY_ID OPENAI_API_KEY
      SESSION_TOKEN PASSWORD DB_PASSWD CREDENTIALS PASSPHRASE PRIVATE_KEY
      my_secret_token
    ].each do |name|
      assert_invalid({env_allowlist: [name]}, /credential-shaped/)
    end
  end

  def test_env_allowlist_accepts_ordinary_names
    config = build(env_allowlist: %w[PATH HOME LANG TMPDIR BUNDLE_GEMFILE])

    assert_equal %w[PATH HOME LANG TMPDIR BUNDLE_GEMFILE], config.env_allowlist
  end

  # --- credential_refs ----------------------------------------------------------

  def test_credential_refs_must_be_explicit_tamoz_names
    assert_invalid({credential_refs: "TAMOZ_MCP_TOKEN"}, /array/)
    assert_invalid({credential_refs: ["OPENAI_API_KEY"]}, /credential_refs/)
    assert_invalid({credential_refs: ["tamoz_mcp_token"]}, /credential_refs/)
    assert_invalid({credential_refs: [nil]}, /credential_refs/)
    assert_equal %w[TAMOZ_MCP_TOKEN], build(credential_refs: %w[TAMOZ_MCP_TOKEN]).credential_refs
  end

  # --- working_directory --------------------------------------------------------

  def test_working_directory_must_be_absolute_and_existing
    assert_invalid({working_directory: "relative"}, /absolute/)
    assert_invalid({working_directory: nil}, /absolute/)
    assert_invalid({working_directory: File.join(@dir, "missing")}, /does not exist/)
    assert_invalid({working_directory: @command}, /does not exist/)
  end

  def test_working_directory_must_not_be_the_workspace_root
    command_in_dir = @command
    assert_invalid(
      {command: command_in_dir, working_directory: @workspace, workspace_root: @workspace},
      /workspace root/
    )
  end

  # --- protocol_range -----------------------------------------------------------

  def test_protocol_range_shape_and_order
    assert_invalid({protocol_range: "2025-11-25"}, /protocol_range/)
    assert_invalid({protocol_range: ["2025-11-25"]}, /protocol_range/)
    assert_invalid({protocol_range: ["2025-11-25", "2026-07-28", "x"]}, /protocol_range/)
    assert_invalid({protocol_range: ["20251125", "2026-07-28"]}, /protocol_range/)
    assert_invalid({protocol_range: ["2026-07-28", "2025-11-25"]}, /after max/)
  end

  # --- primitives ---------------------------------------------------------------

  def test_primitives_must_be_a_non_empty_subset
    assert_invalid({primitives: []}, /primitives/)
    assert_invalid({primitives: [:sampling]}, /primitives/)
    assert_invalid({primitives: ["tools"]}, /primitives/)
    assert_invalid({primitives: :tools}, /primitives/)
    assert_equal %i[tools prompts], build(primitives: %i[tools prompts tools]).primitives
  end

  # --- budgets ------------------------------------------------------------------

  def test_budget_defaults
    budgets = Budgets.new

    assert_equal 256, budgets.max_catalog_entries
    assert_equal 4096, budgets.max_description_bytes
    assert_equal 64 * 1024, budgets.max_output_bytes
    assert_equal 10.0, budgets.connect_timeout
    assert_equal 30.0, budgets.request_timeout
    assert_equal 4, budgets.max_concurrent
    assert_equal 300.0, budgets.idle_timeout
    assert_equal 3600.0, budgets.max_lifetime
    assert_equal 8 * 1024, budgets.stderr_bytes
    assert_predicate budgets, :frozen?
  end

  def test_budget_caps_are_enforced
    assert_raises(ValidationError) { Budgets.new(max_catalog_entries: 257) }
    assert_raises(ValidationError) { Budgets.new(max_description_bytes: 4097) }
    assert_raises(ValidationError) { Budgets.new(max_output_bytes: 64 * 1024 + 1) }
    assert_raises(ValidationError) { Budgets.new(max_catalog_entries: 0) }
    assert_raises(ValidationError) { Budgets.new(max_output_bytes: 1.5) }
  end

  def test_budget_timeouts_must_be_positive_and_finite
    assert_raises(ValidationError) { Budgets.new(connect_timeout: 0) }
    assert_raises(ValidationError) { Budgets.new(request_timeout: -1) }
    assert_raises(ValidationError) { Budgets.new(idle_timeout: Float::INFINITY) }
    assert_raises(ValidationError) { Budgets.new(max_lifetime: Float::NAN) }
    assert_raises(ValidationError) { Budgets.new(connect_timeout: "10") }
  end

  def test_budget_concurrency_and_stderr_bounds
    assert_raises(ValidationError) { Budgets.new(max_concurrent: 0) }
    assert_raises(ValidationError) { Budgets.new(max_concurrent: 1.5) }
    assert_raises(ValidationError) { Budgets.new(stderr_bytes: 0) }
    assert_raises(ValidationError) { Budgets.new(stderr_bytes: -1) }
  end

  def test_budgets_must_be_a_budgets_value
    assert_invalid({budgets: {max_concurrent: 1}}, /budgets/)
  end

  # --- error taxonomy -----------------------------------------------------------

  def test_errors_are_typed_under_tamoz_error
    assert_operator Tamoz::Mcp::Error, :<, Tamoz::Error
    assert_operator ValidationError, :<, Tamoz::Mcp::Error
    assert_operator Tamoz::Mcp::ProtocolError, :<, Tamoz::Mcp::Error
    assert_operator Tamoz::Mcp::CatalogSnapshotUnavailableError, :<, Tamoz::Mcp::Error

    error = assert_invalid({transport: :http}, /endpoint/)
    assert_equal "mcp_validation", error.category
    assert_predicate error, :user_visible?
    refute_predicate error, :retryable?
  end

  # --- where the gem's constants actually live -----------------------------
  #
  # `Data.define(...) do … end` is instance_exec'd, so a constant assigned in
  # that block does NOT land on the Data class: it lands on the enclosing
  # lexical scope, `Tamoz::Mcp`. Four files across the gem read such constants
  # bare and resolved through that accident, and two blocks assigning the same
  # name would have silently overwritten each other module-wide with no warning
  # at either site.
  #
  # The shared ones now have an explicit home. This pins that they are there,
  # and that nothing re-introduces a block-local twin under the same name.
  def test_the_shared_constants_have_an_explicit_home
    assert_equal(/[\x00-\x1f\x7f]/, Tamoz::Mcp::CONTROL_CHARACTER_PATTERN)
    assert_equal({name: "tamoz-mcp", version: Tamoz::Mcp::VERSION}, Tamoz::Mcp::CLIENT_INFO)

    refute ServerConfig.const_defined?(:CONTROL_CHARACTER_PATTERN, false),
           "the pattern is shared; a config-local twin would shadow it for this file only"
    refute Tamoz::Mcp::Catalog.const_defined?(:CLIENT_INFO, false),
           "client info is shared; a catalog-local twin would shadow it for this file only"
  end

  # Every constant a Data.define block in this gem writes ends up on
  # `Tamoz::Mcp`. That is tolerable when it is deliberate and unique; it is a
  # silent overwrite when two blocks pick the same name. This is the check that
  # says which.
  def test_no_two_data_define_blocks_claim_the_same_constant_name
    sources = Dir.glob(File.expand_path("../gems/tamoz-mcp/lib/**/*.rb", __dir__))
    claims = Hash.new { |store, key| store[key] = [] }
    sources.each do |path|
      inside = false
      File.readlines(path, encoding: Encoding::UTF_8).each do |line|
        inside = true if line.match?(/Data\.define\(.*\) do|^\s+\) do\s*$/)
        next unless inside

        name = line[/^\s+([A-Z][A-Z0-9_]*)\s*=/, 1]
        claims[name] << File.basename(path) if name
      end
    end

    collisions = claims.select { |_name, files| files.uniq.length > 1 }
    assert_empty collisions,
                 "these constant names are claimed by blocks in more than one file, " \
                 "and the later load silently wins on Tamoz::Mcp"
  end
end

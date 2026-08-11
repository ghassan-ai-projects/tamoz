# frozen_string_literal: true

# Governed MCP and websearch through operator configuration, against the REAL
# MCP test server this repository ships — a supervised subprocess speaking the
# real protocol, not a stub.
#
# The rules being proven are the ones that make an MCP server safe to hand to an
# unattended worker: the catalog is pinned, risk classification is the operator's
# and not the server's, and the workspace cannot configure any of it.

require_relative "test_helper"
require_relative "support/autonomy_case"

class AgentWorkerMcpTest < Minitest::Test
  include AutonomyCase

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  ENV_ALLOWLIST = %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB].freeze

  def configure_mcp(rt, settings)
    path = File.join(rt.dir, "config.yaml")
    document = Psych.safe_load_file(path)
    document["sources"] = settings
    File.write(path, Psych.dump(document))
  end

  def server_settings(extra = {})
    {
      "command" => RbConfig.ruby,
      "arguments" => [SERVER_SCRIPT],
      "env_allowlist" => ENV_ALLOWLIST
    }.merge(extra)
  end

  def test_mcp_is_absent_until_the_operator_configures_a_server
    with_runtime do |rt|
      rt.cli(%w[status --json])
      assert_empty JSON.parse(rt.out).fetch("capability_catalog").grep(/^mcp:/),
                   "an MCP capability existed with no server configured"
    end
  end

  # The real server, spawned and spoken to. Its tools reach the dispatchable
  # catalog under source-qualified names.
  def test_an_operator_configured_server_reaches_the_dispatchable_catalog
    with_runtime do |rt|
      configure_mcp(rt, {"mcp" => {"enabled" => true,
                                   "servers" => [server_settings("id" => "probe")]}})

      status = rt.cli(%w[status --json])

      assert_equal 0, status, rt.err
      catalog = JSON.parse(rt.out).fetch("capability_catalog")
      assert_includes catalog, "mcp:probe/echo_constant"
      # Names are always source-qualified: a bare tool name is never dispatchable,
      # so one server can never shadow another's tool or a local one.
      refute_includes catalog, "echo_constant"
    end
  end

  # Websearch is an MCP server with a reserved id, which is what keeps it one of
  # the four closed-world sources rather than a fifth.
  def test_websearch_is_configured_as_its_own_source
    with_runtime do |rt|
      configure_mcp(rt, {"websearch" => server_settings.merge("enabled" => true)})

      status = rt.cli(%w[status --json])

      assert_equal 0, status, rt.err
      document = JSON.parse(rt.out)
      assert_includes document.fetch("capability_sources"), "websearch"
      assert_includes document.fetch("capability_catalog"), "mcp:websearch/search"
    end
  end

  # The reserved id cannot be claimed through the generic server list, which
  # would let an ordinary server inherit websearch's source classification.
  def test_the_websearch_id_cannot_be_claimed_by_a_generic_server
    with_runtime do |rt|
      configure_mcp(rt, {"mcp" => {"enabled" => true,
                                   "servers" => [server_settings("id" => "websearch")]}})

      status = rt.cli(%w[status --json])

      assert_equal 1, status
      assert_match(/reserved/, rt.err)
    end
  end

  # Risk classification is operator policy. A server describes its tools; it does
  # not get to say how dangerous they are, and anything unlisted stays unknown.
  def test_risk_classification_comes_from_the_operator_not_the_server
    with_runtime do |rt|
      configure_mcp(rt, {"mcp" => {"enabled" => true,
                                   "servers" => [server_settings(
                                     "id" => "probe",
                                     "read_only_tools" => %w[echo_constant]
                                   )]}})

      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      begin
        source = runtime.mcp_source

        assert source.read_only?("mcp:probe/echo_constant"),
               "the operator's read-only classification was not honoured"
        # `set_answer` mutates and was NOT listed, so it stays unknown-effects.
        refute source.read_only?("mcp:probe/set_answer"),
               "an unlisted tool was treated as read-only"
      ensure
        runtime.close
      end
    end
  end

  # The catalog is pinned at construction: the session records the digest it ran
  # against, so a server that grows a tool later cannot silently widen authority.
  def test_the_catalog_digest_is_pinned
    with_runtime do |rt|
      configure_mcp(rt, {"mcp" => {"enabled" => true,
                                   "servers" => [server_settings("id" => "probe")]}})
      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      begin
        pinned = runtime.mcp_source.mcp_catalogs

        assert_equal ["probe"], pinned.keys
        assert_match(/\Asha256:[0-9a-f]{64}\z/, pinned.fetch("probe"))
      ensure
        runtime.close
      end
    end
  end

  def test_workspace_content_cannot_configure_an_mcp_server
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "tamoz.yaml"), Psych.dump(
        "sources" => {"mcp" => {"enabled" => true,
                                "servers" => [server_settings("id" => "sneaky")]}}
      ))

      rt.cli(%w[status --json])

      assert_empty JSON.parse(rt.out).fetch("capability_catalog").grep(/^mcp:/),
                   "workspace content configured an MCP server"
    end
  end

  def test_a_server_without_a_command_is_refused
    with_runtime do |rt|
      configure_mcp(rt, {"mcp" => {"enabled" => true, "servers" => [{"id" => "broken"}]}})

      status = rt.cli(%w[status --json])

      assert_equal 1, status
      assert_match(/missing command/, rt.err)
    end
  end

  def test_invalid_server_config_is_reported_without_masking_the_validation_error
    with_runtime do |rt|
      configure_mcp(rt, {"mcp" => {"enabled" => true,
                                   "servers" => [server_settings(
                                     "id" => "broken",
                                     "working_directory" => rt.workspace
                                   )]}})

      status = rt.cli(%w[status --json])

      assert_equal 1, status
      assert_match(/MCP server "broken" is misconfigured/, rt.err)
      refute_match(/NameError|uninitialized constant/, rt.err)
    end
  end
end

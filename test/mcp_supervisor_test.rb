# frozen_string_literal: true

require_relative "test_helper"

class McpSupervisorTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Budgets = ServerConfig::Budgets

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  BASE_ENV_ALLOWLIST = %w[
    PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB
  ].freeze

  def setup
    @dir = Dir.mktmpdir("tamoz-mcp-supervisor")
    @saved_flags = ENV.to_h.slice("MCP_TEST_SERVER_GRANDCHILD")
  end

  def teardown
    ENV.delete("MCP_TEST_SERVER_GRANDCHILD")
    @saved_flags.each { |name, value| ENV[name] = value }
    FileUtils.remove_entry(@dir)
  end

  def build_config(overrides = {})
    ServerConfig.new(
      **{
        server_id: "test-server",
        transport: :stdio,
        command: RbConfig.ruby,
        arguments: [SERVER_SCRIPT, File.join(@dir, "answer.txt")],
        working_directory: @dir,
        env_allowlist: BASE_ENV_ALLOWLIST + %w[MCP_TEST_SERVER_GRANDCHILD]
      }.merge(overrides)
    )
  end

  def group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  end

  def test_child_environment_is_restricted_to_allowlist_and_credential_refs
    ENV["TAMOZ_MCP_TEST_CREDENTIAL"] = "secret-value"
    config = build_config(
      env_allowlist: %w[PATH],
      credential_refs: %w[TAMOZ_MCP_TEST_CREDENTIAL]
    )
    supervisor = Supervisor.new(config)
    env = supervisor.send(:child_environment)

    assert_equal %w[PATH TAMOZ_MCP_TEST_CREDENTIAL].sort, env.keys.sort
    assert_equal ENV.fetch("PATH"), env.fetch("PATH")
    refute env.key?("HOME")
    refute env.keys.any? { |name| ServerConfig.credential_env_name?(name) && name != "TAMOZ_MCP_TEST_CREDENTIAL" }
  ensure
    ENV.delete("TAMOZ_MCP_TEST_CREDENTIAL")
  end

  def test_teardown_kills_the_whole_process_group
    ENV["MCP_TEST_SERVER_GRANDCHILD"] = "1"
    supervisor = Supervisor.new(build_config)
    supervisor.start
    pid = supervisor.pid
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.1 while group_member_count(pid) < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    assert_operator group_member_count(pid), :>=, 2, "grandchild never spawned"

    supervisor.close
    refute group_alive?(pid), "process group survived teardown"
    assert_equal :retired, supervisor.state
  end

  def test_teardown_is_reliable_for_a_server_that_ignores_stdin_close
    supervisor = Supervisor.new(build_config)
    supervisor.start
    pid = supervisor.pid
    assert_equal :starting, supervisor.state

    supervisor.close
    refute group_alive?(pid)
    # Idempotent: a second close is a no-op.
    assert_nil supervisor.close
  end

  def test_request_timeout_fires_against_a_sleeping_server
    config = build_config(budgets: Budgets.new(request_timeout: 0.5))
    supervisor = Supervisor.new(config)
    client = MCP::Client.new(transport: supervisor)
    client.connect
    assert_equal :ready, supervisor.state

    assert_raises(MCP::Client::RequestHandlerError) do
      client.call_tool(name: "sleep_ms", arguments: { ms: 5_000 })
    end
  ensure
    supervisor.close
  end

  def test_stderr_tail_is_bounded
    noisy_script = File.join(@dir, "noisy.rb")
    File.write(noisy_script, "STDERR.write('x' * 4096)\n")
    noisy = ServerConfig.new(
      server_id: "test-server",
      transport: :stdio,
      command: RbConfig.ruby,
      arguments: [noisy_script],
      working_directory: @dir,
      env_allowlist: BASE_ENV_ALLOWLIST,
      budgets: Budgets.new(stderr_bytes: 64)
    )
    supervisor = Supervisor.new(noisy)
    supervisor.start
    sleep 0.3
    supervisor.close

    assert_operator supervisor.stderr_tail.bytesize, :<=, 64
    assert_operator supervisor.stderr_tail.bytesize, :>, 0
  end

  private

  def group_member_count(pid)
    `pgrep -g #{pid}`.split.length
  end

  Supervisor = Tamoz::Mcp::Supervisor
end

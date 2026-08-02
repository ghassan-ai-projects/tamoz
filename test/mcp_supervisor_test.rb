# frozen_string_literal: true

require_relative "test_helper"

class McpSupervisorTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Budgets = ServerConfig::Budgets
  Catalog = Tamoz::Mcp::Catalog

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  BASE_ENV_ALLOWLIST = %w[
    PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB
  ].freeze

  # Minimal duck-typed CircuitStore implementation that records calls, proving
  # the caller-injected seam (DR-2) rather than hard-coded in-memory state.
  class CircuitProbe
    attr_reader :calls

    def initialize(calls)
      @calls = calls
    end

    def record_failure(kind: :transport, context: nil)
      @calls << :record_failure
      :degraded
    end

    def record_success
      @calls << :record_success
      :closed
    end

    def open? = false

    def failures = 0

    def reset(evidence: nil)
      @calls << :reset
      :closed
    end

    def reset_evidence = nil

    def last_failure_kind = nil

    def last_failure_context = nil

    def conditions_digest(_server_id) = "sha256:probe"
  end

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
  rescue Errno::EPERM
    # A zombie group leader (or a group in another session) signals EPERM;
    # treat it as still present, matching the supervisor's own probe.
    true
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

  # --- §8 circuit ----------------------------------------------------------

  def test_health_states_and_circuit_transitions
    supervisor = Supervisor.new(build_config, circuit_threshold: 3)
    assert_equal :disabled, supervisor.state

    supervisor.start
    assert_equal :starting, supervisor.state
    MCP::Client.new(transport: supervisor).connect
    assert_equal :ready, supervisor.state

    supervisor.record_failure
    assert_equal :degraded, supervisor.state
    supervisor.record_failure
    assert_equal :degraded, supervisor.state
    assert_equal 2, supervisor.consecutive_failures

    supervisor.record_failure
    assert supervisor.open?
    assert_equal :open, supervisor.state

    # An open circuit closes only through the caller's reset, never through a
    # success recorded behind its back.
    supervisor.record_success
    assert supervisor.open?
    assert_equal :open, supervisor.state

    supervisor.reset(evidence: { "actor" => "operator", "command_digest" => "sha256:reset" })
    refute supervisor.open?
    assert_equal 0, supervisor.consecutive_failures
    assert_equal :ready, supervisor.state

    supervisor.close
    assert_equal :retired, supervisor.state
  ensure
    supervisor&.close
  end

  def test_reset_requires_hash_evidence_and_records_a_typed_conditions_digest
    supervisor = Supervisor.new(build_config, circuit_threshold: 1)
    supervisor.start
    supervisor.record_failure(
      kind: :timeout,
      context: { "tool_name" => "sleep_ms", "failure_class" => "Timeout::Error" }
    )
    assert supervisor.open?
    assert_equal :timeout, supervisor.last_failure_kind

    assert_raises(Tamoz::Mcp::ValidationError) { supervisor.reset(evidence: "not-a-hash") }

    supervisor.reset(evidence: { "actor" => "operator", "command_digest" => "sha256:abc123" })
    refute supervisor.open?

    evidence = supervisor.reset_evidence
    assert_equal "server", evidence["scope"]
    assert_equal "test-server", evidence["server_id"]
    assert_equal "sha256:abc123", evidence["command_digest"]
    assert_match(/\Asha256:[0-9a-f]{64}\z/, evidence["conditions_digest"])
  ensure
    supervisor.close
  end

  def test_circuit_store_seam_is_duck_typed_and_caller_injected
    calls = []
    store = CircuitProbe.new(calls)
    supervisor = Supervisor.new(build_config, circuit_store: store)

    supervisor.record_failure(kind: :transport)
    supervisor.record_success
    supervisor.reset(evidence: { "actor" => "operator" })

    assert_equal %i[record_failure record_success reset], calls
  end

  def test_injected_circuit_store_must_satisfy_the_contract
    incomplete = Object.new
    error = assert_raises(Tamoz::Mcp::ValidationError) do
      Supervisor.new(build_config, circuit_store: incomplete)
    end
    assert_match(/circuit_store must respond to/, error.message)
  end

  def test_consecutive_failures_are_reset_by_a_success
    supervisor = Supervisor.new(build_config, circuit_threshold: 3)
    supervisor.start

    supervisor.record_failure
    supervisor.record_failure
    supervisor.record_success
    assert_equal 0, supervisor.consecutive_failures
    refute supervisor.open?
  ensure
    supervisor.close
  end

  def test_failure_changes_availability_never_the_pinned_catalog
    supervisor = Supervisor.new(build_config, circuit_threshold: 1)
    catalog = Catalog.compile(build_config)
    supervisor.start

    supervisor.record_failure
    assert supervisor.open?
    assert_equal :open, supervisor.state

    # The catalog stays exactly as compiled while availability collapses.
    assert_equal 5, catalog.entries.length
    assert_match(/\Asha256:[0-9a-f]{64}\z/, catalog.snapshot_digest)
  ensure
    supervisor.close
  end

  # --- §8 restart backoff ------------------------------------------------------

  def test_restart_backoff_is_exponential_jittered_and_bounded
    supervisor = Supervisor.new(
      build_config, base_backoff: 1.0, max_backoff: 30.0, random: Random.new(42)
    )

    assert_equal 0.0, supervisor.backoff_delay(0)

    first = supervisor.backoff_delay(1)
    second = supervisor.backoff_delay(2)
    fifth = supervisor.backoff_delay(5)
    tenth = supervisor.backoff_delay(10)

    # base * (1 ± 0.2), bounded by max_backoff
    assert_in_delta 1.0, first, 0.2
    assert_in_delta 2.0, second, 0.4
    assert_in_delta 16.0, fifth, 3.2
    assert_operator tenth, :<=, 30.0
    assert_operator tenth, :>=, 24.0

    assert_operator second, :>, first
    assert_operator fifth, :>, second
    # Bounded even for an unbounded failure streak (both clamp to max_backoff).
    assert_operator supervisor.backoff_delay(100), :<=, 30.0
    assert_operator supervisor.backoff_delay(101), :<=, 30.0
    assert_operator supervisor.backoff_delay(100), :>=, 24.0
  end

  def test_restart_replaces_the_process_group_without_orphans
    ENV["MCP_TEST_SERVER_GRANDCHILD"] = "1"
    supervisor = Supervisor.new(build_config, base_backoff: 0.01, max_backoff: 0.05, random: Random.new(7))
    supervisor.start
    MCP::Client.new(transport: supervisor).connect
    original_pid = supervisor.pid
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.1 while group_member_count(original_pid) < 2 && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    assert_operator group_member_count(original_pid), :>=, 2

    Process.kill("KILL", -original_pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.05 while group_alive?(original_pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    refute group_alive?(original_pid)

    supervisor.restart
    refute_nil supervisor.pid
    refute_equal original_pid, supervisor.pid
    assert group_alive?(supervisor.pid), "a fresh process group must be running"
    assert_equal :starting, supervisor.state
    refute group_alive?(original_pid), "the old process group must not survive a restart"
  ensure
    ENV.delete("MCP_TEST_SERVER_GRANDCHILD")
    supervisor&.close
    refute group_alive?(original_pid) if original_pid
  end

  # --- output flood ------------------------------------------------------------

  def test_oversized_frame_raises_the_typed_output_limit_error
    ENV["MCP_TEST_SERVER_OVERSIZE_OUTPUT"] = "1"
    config = build_config(env_allowlist: BASE_ENV_ALLOWLIST + %w[MCP_TEST_SERVER_OVERSIZE_OUTPUT])
    supervisor = Supervisor.new(config)
    client = MCP::Client.new(transport: supervisor)
    client.connect

    assert_raises(Tamoz::Mcp::OutputLimitError) do
      client.call_tool(name: "echo_constant", arguments: { "value" => "x" })
    end
  ensure
    ENV.delete("MCP_TEST_SERVER_OVERSIZE_OUTPUT")
    supervisor&.close
  end

  def test_invalid_supervisor_circuit_arguments_are_rejected
    assert_raises(Tamoz::Mcp::ValidationError) { Supervisor.new(build_config, circuit_threshold: 0) }
    assert_raises(Tamoz::Mcp::ValidationError) { Supervisor.new(build_config, retry_budget: -1) }
    assert_raises(Tamoz::Mcp::ValidationError) { Supervisor.new(build_config, base_backoff: 0) }
    assert_raises(Tamoz::Mcp::ValidationError) { Supervisor.new(build_config, max_backoff: 0.5, base_backoff: 1.0) }
  end

  private

  def group_member_count(pid)
    `pgrep -g #{pid}`.split.length
  end

  Supervisor = Tamoz::Mcp::Supervisor
end

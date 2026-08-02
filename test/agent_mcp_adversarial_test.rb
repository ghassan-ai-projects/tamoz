# frozen_string_literal: true

require_relative "test_helper"

# P10 §10.2 adversarial rows driven through the slice-4 glue: the caller-supplied
# McpCapabilitySource inside the durable session, against the REAL test server on
# the REAL wire. Every row proves the typed taxonomy survives the glue: the
# caller's executor maps tamoz-mcp's taxonomy onto the agent surface, the effect
# journal grants one attempt, the circuit counts across callers, and teardown
# leaves no process behind.
class AgentMcpAdversarialTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Catalog = Tamoz::Mcp::Catalog
  Supervisor = Tamoz::Mcp::Supervisor
  Invocation = Tamoz::Mcp::Invocation
  Source = Tamoz::Agent::McpCapabilitySource

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  BASE_ENV_ALLOWLIST = %w[
    PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB
  ].freeze
  FLAG_NAMES = %w[
    MCP_TEST_SERVER_MALFORMED_FRAMES MCP_TEST_SERVER_MALFORMED_MID_CALL
    MCP_TEST_SERVER_EXIT_MID_CALL MCP_TEST_SERVER_OVERSIZE_OUTPUT
    MCP_TEST_SERVER_EXTRA_TOOLS MCP_TEST_SERVER_LONG_DESCRIPTION
    MCP_TEST_SERVER_PROTOCOL_VERSION MCP_TEST_SERVER_GRANDCHILD
  ].freeze

  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  def setup
    @dir = Dir.mktmpdir("tamoz-agent-mcp-adv")
    @saved_flags = ENV.to_h.slice(*FLAG_NAMES)
  end

  def teardown
    FLAG_NAMES.each { |name| ENV.delete(name) }
    @saved_flags.each { |name, value| ENV[name] = value }
    FileUtils.remove_entry(@dir)
  end

  def build_config(answer_file, overrides = {})
    ServerConfig.new(
      **{
        server_id: "test-server",
        transport: :stdio,
        command: RbConfig.ruby,
        arguments: [SERVER_SCRIPT, answer_file],
        working_directory: @dir,
        env_allowlist: BASE_ENV_ALLOWLIST + FLAG_NAMES
      }.merge(overrides)
    )
  end

  def descriptor_for(snapshot, name, effect_class: :unknown_effects)
    entry = snapshot.entries.find { |candidate| candidate.name == name }
    Invocation.descriptor_for(entry, snapshot: snapshot, effect_class:)
  end

  # The caller's taxonomy mapping: repairable MCP rows become agent
  # ToolArgumentError; protocol rows stay terminal; transport rows stay terminal
  # (the caller may choose to classify open-circuit as retryable — these tests
  # prove the session stops either way).
  def mcp_executor(supervisor:, snapshot:)
    lambda do |_context, descriptor, arguments|
      outcome = Invocation.call(
        descriptor, arguments, snapshot: snapshot, supervisor: supervisor
      )
      case outcome.status
      when :succeeded then outcome.observation.text
      when :denied
        raise Tamoz::Agent::ToolError,
              "MCP elicitation denied: #{outcome.denial.fetch("reason")}"
      when :interrupt
        raise Tamoz::Agent::ToolError,
              "MCP elicitation interrupt #{outcome.interrupt.fetch("effect_key")} " \
              "was not auto-answered"
      end
    rescue Tamoz::Mcp::ToolArgumentError => error
      raise Tamoz::Agent::ToolArgumentError, error.message
    rescue Tamoz::Mcp::ToolPolicyError, Tamoz::Mcp::UnavailableError,
           Tamoz::Mcp::AmbiguousOutcomeError => error
      raise Tamoz::Agent::ToolError, error.message
    end
  end

  def source_for(snapshot, supervisor:, names:, effect_class: :unknown_effects)
    descriptors = names.map { |name| descriptor_for(snapshot, name, effect_class:) }
    Source.new(
      catalogs: {snapshot.server_id => snapshot},
      descriptors:,
      executor: mcp_executor(supervisor:, snapshot:)
    )
  end

  def with_session_workspace
    Dir.mktmpdir("tamoz-session-adv") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 5.0)
      )
      begin
        yield File.realpath(root), adapter
      ensure
        adapter.close
      end
    end
  end

  def read_only_session(root:, adapter:, source:, tool:, arguments:)
    toolbox = Tamoz::Agent::Toolbox.new(root:)
    model = ScriptedModel.new(
      plan: [plan_for(tool, arguments)],
      review: [accepted_review],
      verify: []
    )
    session = Tamoz::Agent::Session.new(model:, toolbox:, checkpointer: adapter, mcp: source)
    [session, model]
  end

  def plan_for(tool, arguments, id: "s1")
    {
      "goal" => "answer the task",
      "done_when" => ["the tool returned evidence"],
      "steps" => [
        {
          "id" => id,
          "purpose" => "gather evidence",
          "tool" => tool,
          "arguments" => arguments,
          "verification" => "the output is present"
        }
      ]
    }
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "sound"}
  end

  def group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def approved_outcome(session, outcome, thread:, request_id:)
    current = outcome
    index = 0
    while current.status == :paused && index < 8
      index += 1
      task_id = session.view(thread:).interrupts.first.task_id
      current = session.resume(
        {task_id => {0 => true}},
        thread:,
        request_id: "#{request_id}.#{index}"
      )
    end
    current
  end

  def test_mid_call_wire_corruption_is_terminal_through_the_session_and_counts_the_circuit
    with_session_workspace do |root, adapter|
      config = build_config(File.join(@dir, "answer.txt"))
      snapshot = Catalog.compile(config)
      ENV["MCP_TEST_SERVER_MALFORMED_MID_CALL"] = "1"
      supervisor = Supervisor.new(config)
      begin
        source = source_for(snapshot, supervisor:, names: %w[echo_constant], effect_class: :read_only)
        session, model = read_only_session(
          root:, adapter:, source:,
          tool: "mcp:test-server/echo_constant", arguments: {"value" => "x"}
        )

        outcome = session.start(
          "Echo a constant through the MCP server.",
          thread: "adv.mid-call",
          request_id: "request.1"
        )

        assert_equal :failed, outcome.status, "wire corruption is terminal, never retried"
        assert_equal 1, supervisor.consecutive_failures
        assert_equal :corruption, supervisor.last_failure_kind
        refute supervisor.open?, "one failure stays below the default threshold"
        # The plan ran once: corruption is never turned into a repair-able value.
        assert_equal %i[plan review], model.calls.map { |call| call.fetch(:stage) }
      ensure
        supervisor.close
      end
    end
  end

  def test_connect_phase_wire_corruption_is_terminal_through_the_session
    with_session_workspace do |root, adapter|
      config = build_config(File.join(@dir, "answer.txt"))
      snapshot = Catalog.compile(config)
      ENV["MCP_TEST_SERVER_MALFORMED_FRAMES"] = "1"
      supervisor = Supervisor.new(config)
      begin
        source = source_for(snapshot, supervisor:, names: %w[echo_constant], effect_class: :read_only)
        session, = read_only_session(
          root:, adapter:, source:,
          tool: "mcp:test-server/echo_constant", arguments: {"value" => "x"}
        )

        outcome = session.start(
          "Echo a constant through the MCP server.",
          thread: "adv.connect",
          request_id: "request.1"
        )

        assert_equal :failed, outcome.status
        assert_equal :corruption, supervisor.last_failure_kind
        assert_equal 1, supervisor.consecutive_failures
      ensure
        supervisor.close
      end
    end
  end

  # "Across callers": the circuit lives in the supervisor, not in any one source
  # or session. Three corrupt calls from one caller open it; a second caller
  # sharing the supervisor gets the typed unavailable before any client or child
  # process is built.
  def test_open_circuit_protects_a_second_caller_without_spawning
    with_session_workspace do |root, adapter|
      config = build_config(File.join(@dir, "answer.txt"))
      snapshot = Catalog.compile(config)
      ENV["MCP_TEST_SERVER_MALFORMED_MID_CALL"] = "1"
      supervisor = Supervisor.new(config)
      begin
        source_a = source_for(snapshot, supervisor:, names: %w[echo_constant], effect_class: :read_only)
        source_b = source_for(snapshot, supervisor:, names: %w[echo_constant], effect_class: :read_only)

        3.times do
          assert_raises(Tamoz::Agent::ToolError) do
            source_a.execute(:context, "mcp:test-server/echo_constant", {"value" => "x"})
          end
        end
        assert supervisor.open?
        assert_equal 3, supervisor.consecutive_failures
        spawned = supervisor.pid

        error = assert_raises(Tamoz::Agent::ToolError) do
          source_b.execute(:context, "mcp:test-server/echo_constant", {"value" => "x"})
        end
        assert_match(/circuit is open/, error.message)
        assert_equal spawned, supervisor.pid, "the open circuit must not re-spawn"
        assert_equal 3, supervisor.consecutive_failures

        # A resumed session bound to the same supervisor stops the same way; the
        # glue never bypasses the circuit.
        session, = read_only_session(
          root:, adapter:, source: source_b,
          tool: "mcp:test-server/echo_constant", arguments: {"value" => "x"}
        )
        outcome = session.start(
          "Echo a constant.",
          thread: "adv.caller-b",
          request_id: "request.1"
        )
        assert_equal :failed, outcome.status
      ensure
        supervisor.close
      end
    end
  end

  # Crash mid-call on a non-idempotent effect: the outcome is genuinely ambiguous
  # and the journal grants exactly one attempt — the caller never retries a guess.
  def test_crash_mid_call_is_typed_unknown_and_never_retried
    with_session_workspace do |root, adapter|
      config = build_config(
        File.join(@dir, "answer.txt"),
        budgets: ServerConfig::Budgets.new(request_timeout: 1.0)
      )
      snapshot = Catalog.compile(config)
      ENV["MCP_TEST_SERVER_EXIT_MID_CALL"] = "1"
      supervisor = Supervisor.new(config)
      begin
        source = source_for(snapshot, supervisor:, names: %w[sleep_ms])
        session, model = read_only_session(
          root:, adapter:, source:,
          tool: "mcp:test-server/sleep_ms", arguments: {"ms" => 1}
        )

        outcome = session.start(
          "Sleep one millisecond on the MCP server.",
          thread: "adv.crash",
          request_id: "request.1"
        )
        outcome = approved_outcome(session, outcome, thread: "adv.crash", request_id: "request.1")

        assert_equal :failed, outcome.status
        assert_equal 1, supervisor.consecutive_failures
        refute supervisor.open?
        # One plan, one review, one step: an ambiguous effect is never turned into
        # a repairable value the planner can iterate on.
        assert_equal %i[plan review], model.calls.map { |call| call.fetch(:stage) }
      ensure
        supervisor.close
      end
    end
  end

  def test_output_flood_is_bounded_and_typed_through_the_session
    with_session_workspace do |root, adapter|
      config = build_config(File.join(@dir, "answer.txt"))
      snapshot = Catalog.compile(config)
      ENV["MCP_TEST_SERVER_OVERSIZE_OUTPUT"] = "1"
      supervisor = Supervisor.new(config, retry_budget: 0)
      begin
        source = source_for(snapshot, supervisor:, names: %w[echo_constant], effect_class: :read_only)
        session, = read_only_session(
          root:, adapter:, source:,
          tool: "mcp:test-server/echo_constant", arguments: {"value" => "x"}
        )

        outcome = session.start(
          "Echo a constant.",
          thread: "adv.flood",
          request_id: "request.1"
        )

        assert_equal :failed, outcome.status
        assert_equal 1, supervisor.consecutive_failures
        assert_equal :output_limit, supervisor.last_failure_kind
      ensure
        supervisor.close
      end
    end
  end

  def test_credential_shaped_env_names_are_rejected_at_admission
    error = assert_raises(Tamoz::Mcp::ValidationError) do
      ServerConfig.new(
        server_id: "test-server",
        transport: :stdio,
        command: RbConfig.ruby,
        arguments: [SERVER_SCRIPT, File.join(@dir, "answer.txt")],
        working_directory: @dir,
        env_allowlist: BASE_ENV_ALLOWLIST + ["ANTHROPIC_API_KEY"]
      )
    end
    assert_match(/credential/i, error.message)
    assert ServerConfig.credential_env_name?("OPENAI_API_KEY")
    refute ServerConfig.credential_env_name?("PATH")
  end

  def test_no_orphan_server_survives_teardown
    config = build_config(File.join(@dir, "answer.txt"))
    snapshot = Catalog.compile(config)
    supervisor = Supervisor.new(config)
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)
    begin
      Invocation.call(descriptor, {"value" => "x"}, snapshot: snapshot, supervisor: supervisor)
      assert group_alive?(supervisor.pid), "the server must be running while in use"
    ensure
      supervisor.close
    end

    refute group_alive?(supervisor.pid), "closing the supervisor reaps the process group"
    orphans = `pgrep -fl mcp_test_server 2>/dev/null || true`.lines.reject do |line|
      line.include?(File.basename(__FILE__))
    end
    assert_empty orphans, "no mcp_test_server may survive the suite"
  end

  def test_bare_tool_name_never_resolves_and_unknown_names_raise_typed
    config = build_config(File.join(@dir, "answer.txt"))
    snapshot = Catalog.compile(config)
    supervisor = Supervisor.new(config)
    begin
      source = source_for(snapshot, supervisor:, names: %w[echo_constant], effect_class: :read_only)
      refute source.name?("echo_constant"), "a bare server tool name is never in the surface"
      refute source.name?("mcp:test-server/delete")
      refute source.name?("mcp:test-server/../escape")

      error = assert_raises(Tamoz::Agent::ToolError) do
        source.descriptor_for!("mcp:test-server/delete")
      end
      assert_match(/unknown tool/, error.message)
    ensure
      supervisor.close
    end
  end
end

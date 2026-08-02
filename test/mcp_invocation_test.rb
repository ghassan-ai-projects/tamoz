# frozen_string_literal: true

require_relative "test_helper"

class McpInvocationTest < Minitest::Test
  ServerConfig = Tamoz::Mcp::ServerConfig
  Budgets = ServerConfig::Budgets
  Catalog = Tamoz::Mcp::Catalog
  Supervisor = Tamoz::Mcp::Supervisor
  Invocation = Tamoz::Mcp::Invocation
  Elicitation = Tamoz::Mcp::Elicitation
  Descriptor = Invocation::Descriptor

  SERVER_SCRIPT = ROOT.join("script", "mcp_test_server").to_s
  BASE_ENV_ALLOWLIST = %w[
    PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB
  ].freeze
  FLAG_NAMES = %w[
    MCP_TEST_SERVER_MALFORMED_FRAMES MCP_TEST_SERVER_EXIT_MID_CALL
    MCP_TEST_SERVER_OVERSIZE_OUTPUT MCP_TEST_SERVER_EXTRA_TOOLS
    MCP_TEST_SERVER_LONG_DESCRIPTION MCP_TEST_SERVER_PROTOCOL_VERSION
    MCP_TEST_SERVER_GRANDCHILD
  ].freeze

  # SDK-shaped client that stands in for server behavior the real test server
  # cannot produce deterministically (JSON-RPC errors, isError results, mid-call
  # malformed frames, structured content, MRTR completion). Only the client is
  # faked — the supervisor, config, snapshot, and digests are real.
  class FakeMrtrClient < MCP::Client
    attr_reader :calls

    def initialize(responses: [])
      @responses = responses
      @calls = []
      super(transport: Object.new)
    end

    def connect(client_info: nil, protocol_version: nil, capabilities: {})
      { "protocolVersion" => protocol_version || "2026-07-28" }
    end

    def call_tool(name: nil, tool: nil, arguments: nil, **)
      @calls << { method: "tools/call", name: name, arguments: arguments }
      next_response
    end

    def request(method:, params: nil, meta: nil, cancellation: nil)
      @calls << { method: method, params: params }
      next_response
    end

    private

    def next_response
      item = @responses.shift
      raise item if item.is_a?(Exception)
      # Mirror the SDK client's request pipeline: an "error" member is raised
      # as a ServerError before any result-shape handling.
      if item.is_a?(Hash) && item["error"].is_a?(Hash)
        raise MCP::Client::ServerError.new(
          item["error"]["message"].to_s,
          code: item["error"]["code"],
          data: item["error"]["data"]
        )
      end

      item
    end
  end

  def setup
    @dir = Dir.mktmpdir("tamoz-mcp-invocation")
    @saved_flags = ENV.to_h.slice(*FLAG_NAMES)
  end

  def teardown
    FLAG_NAMES.each { |name| ENV.delete(name) }
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
        env_allowlist: BASE_ENV_ALLOWLIST + FLAG_NAMES
      }.merge(overrides)
    )
  end

  # Compiles the real catalog (snapshot) and returns a fresh supervisor for the
  # calls, mirroring how a session pins a catalog and then drives calls through
  # its own supervised client.
  def setup_environment(overrides = {}, flags = {})
    flags.each { |name, value| ENV[name] = value }
    config = build_config(overrides)
    snapshot = Catalog.compile(config)
    supervisor = Supervisor.new(config)
    [config, snapshot, supervisor]
  end

  def descriptor_for(snapshot, name, effect_class: :unknown_effects, output_schema: nil)
    entry = snapshot.entries.find { |candidate| candidate.name == name }
    Invocation.descriptor_for(entry, snapshot: snapshot, effect_class: effect_class, output_schema: output_schema)
  end

  def group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  # --- §6 happy path + bounding / attribution ---------------------------------

  def test_success_attributes_every_content_block_and_returns_text
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)

    outcome = Invocation.call(descriptor, { "value" => "hello" }, snapshot: snapshot, supervisor: supervisor)

    assert_equal :succeeded, outcome.status
    observation = outcome.observation
    assert_equal "test-server", observation.server_id
    assert_equal "hello", observation.text
    assert observation.attributed?
    assert observation.content_blocks.all? do |block|
      block["attribution"] == "remote content from server test-server"
    end
    refute observation.truncated
    assert_match(/\Asha256:[0-9a-f]{64}\z/, outcome.effect_key)
    assert_equal 0, supervisor.consecutive_failures
  ensure
    supervisor&.close
  end

  def test_effect_key_is_deterministic_and_argument_sensitive
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)

    first = Invocation.effect_key(descriptor, { "value" => "a" })
    second = Invocation.effect_key(descriptor, { "value" => "a" })
    different = Invocation.effect_key(descriptor, { "value" => "b" })

    assert_equal first, second
    refute_equal first, different
  ensure
    supervisor&.close
  end

  def test_output_is_bounded_to_budget_and_marked_truncated
    config, snapshot, supervisor = setup_environment(budgets: Budgets.new(max_output_bytes: 512))
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)

    outcome = Invocation.call(descriptor, { "value" => "y" * 2000 }, snapshot: snapshot, supervisor: supervisor)

    assert_equal :succeeded, outcome.status
    assert outcome.observation.truncated
    assert_operator outcome.observation.text.bytesize, :<=, 512
  ensure
    supervisor&.close
  end

  def test_output_control_characters_are_stripped
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)

    outcome = Invocation.call(descriptor, { "value" => "a\x00b\x07c" }, snapshot: snapshot, supervisor: supervisor)

    assert_equal :succeeded, outcome.status
    refute_match(/[\x00-\x1f\x7f]/, outcome.observation.text)
    assert_equal "a b c", outcome.observation.text
    assert_predicate outcome.observation.text, :valid_encoding?
  ensure
    supervisor&.close
  end

  # --- argument validation: no I/O on repairable failures ---------------------

  def test_unknown_property_is_rejected_with_no_io
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, { "value" => "x", "extra" => 1 }, snapshot: snapshot, supervisor: supervisor)
    end

    assert error.repairable?
    assert_equal "mcp_arguments", error.category
    assert_equal false, supervisor.started?, "no server process may be spawned"
  ensure
    supervisor&.close
  end

  def test_missing_required_argument_is_rejected_with_no_io
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, {}, snapshot: snapshot, supervisor: supervisor)
    end

    assert error.repairable?
    assert_match(/value/, error.message)
    assert_equal false, supervisor.started?
  ensure
    supervisor&.close
  end

  def test_over_depth_arguments_are_rejected_with_no_io
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)
    deep = "leaf"
    105.times { deep = { "nested" => deep } }

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, { "value" => deep }, snapshot: snapshot, supervisor: supervisor)
    end

    assert error.repairable?
    assert_match(/nesting/, error.message)
    assert_equal false, supervisor.started?
  ensure
    supervisor&.close
  end

  def test_non_hash_arguments_are_rejected_with_no_io
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, ["not", "an", "object"], snapshot: snapshot, supervisor: supervisor)
    end

    assert error.repairable?
    assert_equal false, supervisor.started?
  ensure
    supervisor&.close
  end

  # --- pinned digest gate: stops before ANY I/O -------------------------------

  def test_definition_digest_mismatch_stops_before_any_io
    _config, snapshot, supervisor = setup_environment
    entry = snapshot.entries.find { |candidate| candidate.name == "echo_constant" }
    descriptor = Invocation.descriptor_for(entry, snapshot: snapshot, effect_class: :read_only)
    tampered = Descriptor.new(
      id: descriptor.id,
      name: descriptor.name,
      source_id: descriptor.source_id,
      definition_digest: "sha256:#{"0" * 64}",
      input_schema: descriptor.input_schema,
      output_schema: nil,
      effect_class: :read_only,
      protocol_profile: "2026-07-28"
    )
    factory = lambda do |_supervisor|
      raise "the client must never be built when the pinned digest does not match"
    end

    error = assert_raises(Tamoz::Mcp::CatalogSnapshotUnavailableError) do
      Invocation.call(tampered, { "value" => "x" }, snapshot: snapshot, supervisor: supervisor, client_factory: factory)
    end

    assert_equal "mcp_catalog_snapshot_unavailable", error.category
    assert_equal false, supervisor.started?
  ensure
    supervisor&.close
  end

  def test_descriptor_for_builds_source_qualified_id_and_pinned_digest
    _config, snapshot, supervisor = setup_environment
    entry = snapshot.entries.find { |candidate| candidate.name == "set_answer" }

    descriptor = Invocation.descriptor_for(entry, snapshot: snapshot, effect_class: :unknown_effects)

    assert_equal "mcp:test-server/set_answer", descriptor.id
    assert_equal "set_answer", descriptor.name
    assert_equal "test-server", descriptor.source_id
    assert_equal entry.definition_digest, descriptor.definition_digest
    assert_equal "2026-07-28", descriptor.protocol_profile
    assert_predicate descriptor, :frozen?
    refute descriptor.read_only?
  ensure
    supervisor&.close
  end

  # --- §6 taxonomy rows --------------------------------------------------------

  # Row: JSON-RPC invalid params / schema validation failure → ToolArgumentError
  def test_json_rpc_error_is_repairable_with_remote_error_prefix
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)
    fake = FakeMrtrClient.new(responses: [
      { "error" => { "code" => -32602, "message" => "invalid params" } }
    ])

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, { "value" => "x" }, snapshot: snapshot, supervisor: supervisor,
                      client_factory: ->(_sup) { fake })
    end

    assert_match(/\Amcp_remote_error:/, error.message)
    assert_match(/-32602/, error.message)
    assert error.repairable?
    assert_equal 0, supervisor.consecutive_failures, "remote errors are not transport failures"
  ensure
    supervisor&.close
  end

  # Row: server-declared tool error result → ToolArgumentError with mcp_remote_error:
  def test_server_declared_tool_error_is_repairable_with_remote_error_prefix
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)
    fake = FakeMrtrClient.new(responses: [
      { "result" => { "content" => [{ "type" => "text", "text" => "boom" }], "isError" => true } }
    ])

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, { "value" => "x" }, snapshot: snapshot, supervisor: supervisor,
                      client_factory: ->(_sup) { fake })
    end

    assert_match(/\Amcp_remote_error:/, error.message)
    assert error.repairable?
    assert_equal 0, supervisor.consecutive_failures
  ensure
    supervisor&.close
  end

  # Row: timeout before the request was sent → ToolArgumentError (mcp_unavailable:),
  # provably no effect.
  def test_timeout_before_send_is_repairable_unavailable
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "sleep_ms")
    MCP::Client.new(transport: supervisor).connect
    Process.kill("KILL", -supervisor.pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.02 while group_alive?(supervisor.pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

    error = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, { "ms" => 1 }, snapshot: snapshot, supervisor: supervisor)
    end

    assert_match(/\Amcp_unavailable:/, error.message)
    assert error.repairable?
    assert_equal 1, supervisor.consecutive_failures
  ensure
    supervisor&.close
  end

  # Row: timeout/crash/disconnect after send with non-idempotent effect_class →
  # propagates with the effect marked :unknown (never guess).
  def test_timeout_after_send_with_non_idempotent_effect_propagates_unknown
    config, snapshot, supervisor = setup_environment(budgets: Budgets.new(request_timeout: 0.5))
    descriptor = descriptor_for(snapshot, "sleep_ms")

    error = assert_raises(Tamoz::Mcp::AmbiguousOutcomeError) do
      Invocation.call(descriptor, { "ms" => 5_000 }, snapshot: snapshot, supervisor: supervisor)
    end

    assert_equal "mcp_effect_unknown", error.category
    assert_equal false, error.retryable?
    assert_match(/effect is unknown/, error.message)
    assert_equal 1, supervisor.consecutive_failures
  ensure
    supervisor&.close
  end

  def test_crash_mid_call_with_non_idempotent_effect_propagates_unknown
    config, snapshot, supervisor = setup_environment({}, "MCP_TEST_SERVER_EXIT_MID_CALL" => "1")
    descriptor = descriptor_for(snapshot, "sleep_ms")

    error = assert_raises(Tamoz::Mcp::AmbiguousOutcomeError) do
      Invocation.call(descriptor, { "ms" => 1 }, snapshot: snapshot, supervisor: supervisor)
    end

    assert_equal "mcp_effect_unknown", error.category
    assert_match(/request to mcp:test-server\/sleep_ms was sent/, error.message)
    assert_equal 1, supervisor.consecutive_failures
  ensure
    supervisor&.close
  end

  # Row: same as above with effect_class :read_only → typed unavailable, retryable
  # by the caller.
  def test_timeout_after_send_with_read_only_effect_is_typed_unavailable_and_retryable
    config, snapshot, supervisor = setup_environment(budgets: Budgets.new(request_timeout: 0.5))
    descriptor = descriptor_for(snapshot, "sleep_ms", effect_class: :read_only)
    supervisor_without_retry = Supervisor.new(config, retry_budget: 0)

    error = assert_raises(Tamoz::Mcp::UnavailableError) do
      Invocation.call(descriptor, { "ms" => 5_000 }, snapshot: snapshot, supervisor: supervisor_without_retry)
    end

    assert error.retryable?
    assert_equal "mcp_unavailable", error.category
    assert_match(/\Amcp_unavailable:/, error.message)
    assert_match(/read-only/, error.message)
    assert_equal 1, supervisor_without_retry.consecutive_failures
  ensure
    supervisor_without_retry&.close
    supervisor&.close
  end

  # Row: wire/protocol corruption → ToolPolicyError; the circuit counts it.
  def test_wire_corruption_is_terminal_policy_error_and_counts_toward_the_circuit
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)
    fake = FakeMrtrClient.new(responses: [
      MCP::Client::RequestHandlerError.new(
        "Failed to parse server response",
        { method: "tools/call" },
        error_type: :internal_error,
        original_error: JSON::ParserError.new("unexpected token")
      )
    ])

    error = assert_raises(Tamoz::Mcp::ToolPolicyError) do
      Invocation.call(descriptor, { "value" => "x" }, snapshot: snapshot, supervisor: supervisor,
                      client_factory: ->(_sup) { fake })
    end

    assert_equal "mcp_protocol", error.category
    assert_equal false, error.repairable?
    assert_equal 1, supervisor.consecutive_failures
  ensure
    supervisor&.close
  end

  # Row: malformed result shape on the wire → ToolPolicyError.
  def test_result_without_content_array_is_protocol_violation
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)
    fake = FakeMrtrClient.new(responses: [{ "result" => { "noContent" => true } }])

    error = assert_raises(Tamoz::Mcp::ToolPolicyError) do
      Invocation.call(descriptor, { "value" => "x" }, snapshot: snapshot, supervisor: supervisor,
                      client_factory: ->(_sup) { fake })
    end

    assert_equal "mcp_protocol", error.category
  ensure
    supervisor&.close
  end

  # --- output flood (real 8 MiB server response) -------------------------------

  def test_output_flood_is_bounded_typed_and_counts_toward_the_circuit
    config, snapshot, supervisor = setup_environment({}, "MCP_TEST_SERVER_OVERSIZE_OUTPUT" => "1")
    flood_supervisor = Supervisor.new(config, retry_budget: 0)
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)

    error = assert_raises(Tamoz::Mcp::UnavailableError) do
      Invocation.call(descriptor, { "value" => "x" }, snapshot: snapshot, supervisor: flood_supervisor)
    end

    assert error.retryable?
    assert_equal "mcp_unavailable", error.category
    assert_equal 1, flood_supervisor.consecutive_failures, "output-limit violations open the circuit counter"
  ensure
    flood_supervisor&.close
    supervisor&.close
  end

  # --- structured content against the declared output schema -------------------

  def test_structured_content_is_validated_against_declared_output_schema
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(
      snapshot, "echo_constant", effect_class: :read_only,
      output_schema: {
        "type" => "object",
        "properties" => { "result" => { "type" => "integer" } },
        "required" => ["result"],
        "additionalProperties" => false
      }
    )
    fake = FakeMrtrClient.new(responses: [
      { "result" => {
        "content" => [{ "type" => "text", "text" => "ok" }],
        "structuredContent" => { "result" => "not-an-integer" }
      } }
    ])

    error = assert_raises(Tamoz::Mcp::ToolPolicyError) do
      Invocation.call(descriptor, { "value" => "x" }, snapshot: snapshot, supervisor: supervisor,
                      client_factory: ->(_sup) { fake })
    end

    assert_equal "mcp_protocol", error.category
    assert_match(/output schema/, error.message)
  ensure
    supervisor&.close
  end

  def test_valid_structured_content_is_attributed_and_returned
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(
      snapshot, "echo_constant", effect_class: :read_only,
      output_schema: {
        "type" => "object",
        "properties" => { "result" => { "type" => "integer" } },
        "required" => ["result"],
        "additionalProperties" => false
      }
    )
    fake = FakeMrtrClient.new(responses: [
      { "result" => {
        "content" => [{ "type" => "text", "text" => "ok" }],
        "structuredContent" => { "result" => 42 }
      } }
    ])

    outcome = Invocation.call(descriptor, { "value" => "x" }, snapshot: snapshot, supervisor: supervisor,
                              client_factory: ->(_sup) { fake })

    assert_equal :succeeded, outcome.status
    assert_equal({ "result" => 42 }, outcome.observation.structured_content)
    assert outcome.observation.attributed?
  ensure
    supervisor&.close
  end

  # --- elicitation rows (§7) ----------------------------------------------------

  def test_input_required_becomes_durable_interrupt_descriptor_never_a_tool_error
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "needs_input")

    outcome = Invocation.call(descriptor, {}, snapshot: snapshot, supervisor: supervisor)

    assert_equal :interrupt, outcome.status
    interrupt = outcome.interrupt
    assert_equal "mcp_elicitation", interrupt["kind"]
    assert_equal "test-server", interrupt["server_id"]
    assert_equal descriptor.id, interrupt["capability"]
    assert_equal descriptor.definition_digest, interrupt["definition_digest"]
    assert_equal outcome.effect_key, interrupt["effect_key"]
    assert_equal 1, interrupt["fields"].length
    field = interrupt["fields"].first
    assert_equal "elicit-1", field["id"]
    assert_equal "Which value should be used?", field["message"]
    assert_equal "string", field["schema"]["properties"]["value"]["type"]
    assert_equal "tamoz-test-state", interrupt["request_state"]
    refute interrupt.key?("url")
    assert_predicate interrupt, :frozen?
    assert_equal 0, supervisor.consecutive_failures, "elicitation is not a transport failure"
  ensure
    supervisor&.close
  end

  def test_headless_runs_deny_elicitation_with_typed_value
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "needs_input")

    outcome = Invocation.call(descriptor, {}, snapshot: snapshot, supervisor: supervisor, headless: true)

    assert_equal :denied, outcome.status
    denial = outcome.denial
    assert_equal "mcp_elicitation_denied", denial["kind"]
    assert_equal false, denial["consent"]
    assert_equal "test-server", denial["server_id"]
    assert_nil outcome.interrupt
    assert_equal 0, supervisor.consecutive_failures
  ensure
    supervisor&.close
  end

  # --- circuit (§8) --------------------------------------------------------------

  def test_circuit_opens_after_threshold_and_fails_typed_until_caller_resets
    _config, snapshot, supervisor = setup_environment({}, "MCP_TEST_SERVER_EXIT_MID_CALL" => "1")
    descriptor = descriptor_for(snapshot, "sleep_ms")

    error1 = assert_raises(Tamoz::Mcp::AmbiguousOutcomeError) do
      Invocation.call(descriptor, { "ms" => 1 }, snapshot: snapshot, supervisor: supervisor)
    end
    assert_equal 1, supervisor.consecutive_failures
    assert_equal :degraded, supervisor.state

    error2 = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, { "ms" => 1 }, snapshot: snapshot, supervisor: supervisor)
    end
    assert_match(/\Amcp_unavailable:/, error2.message)
    assert_equal 2, supervisor.consecutive_failures

    error3 = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, { "ms" => 1 }, snapshot: snapshot, supervisor: supervisor)
    end
    assert_match(/\Amcp_unavailable:/, error3.message)
    assert_equal 3, supervisor.consecutive_failures
    assert supervisor.open?
    assert_equal :open, supervisor.state

    # While open every call fails typed-unavailable before any client is built.
    factory = lambda do |_supervisor|
      raise "no client may be built while the circuit is open"
    end
    error4 = assert_raises(Tamoz::Mcp::UnavailableError) do
      Invocation.call(descriptor, { "ms" => 1 }, snapshot: snapshot, supervisor: supervisor, client_factory: factory)
    end
    assert error4.retryable?
    assert_equal "mcp_unavailable", error4.category
    assert_match(/circuit is open/, error4.message)

    # Caller reset closes the circuit; calls are attempted again (typed, since
    # the server is still dead) instead of being circuit-blocked. The reset
    # carries operator evidence per DR-2.
    supervisor.reset(evidence: { "actor" => "operator", "command_digest" => "sha256:reset-1" })
    refute supervisor.open?
    assert_equal 0, supervisor.consecutive_failures
    evidence = supervisor.reset_evidence
    assert_equal "server", evidence["scope"]
    assert_equal "test-server", evidence["server_id"]
    assert_match(/\Asha256:[0-9a-f]{64}\z/, evidence["conditions_digest"])
    assert_equal "sha256:reset-1", evidence["command_digest"]

    error5 = assert_raises(Tamoz::Mcp::ToolArgumentError) do
      Invocation.call(descriptor, { "ms" => 1 }, snapshot: snapshot, supervisor: supervisor)
    end
    assert_match(/\Amcp_unavailable:/, error5.message)
    refute supervisor.open?
  ensure
    supervisor&.close
  end

  def test_a_successful_call_resets_the_consecutive_failure_streak
    _config, snapshot, supervisor = setup_environment({}, "MCP_TEST_SERVER_EXIT_MID_CALL" => "1")
    echo = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)
    sleeper = descriptor_for(snapshot, "sleep_ms")

    assert_raises(Tamoz::Mcp::AmbiguousOutcomeError) do
      Invocation.call(sleeper, { "ms" => 1 }, snapshot: snapshot, supervisor: supervisor)
    end
    assert_equal 1, supervisor.consecutive_failures
    assert_equal :degraded, supervisor.state

    supervisor.restart # caller recovers the crashed process; the streak survives

    outcome = Invocation.call(echo, { "value" => "ok" }, snapshot: snapshot, supervisor: supervisor)

    assert_equal :succeeded, outcome.status
    assert_equal 0, supervisor.consecutive_failures, "a successful round-trip breaks the consecutive streak"
    assert_equal :ready, supervisor.state
  ensure
    supervisor&.close
  end

  def test_read_only_calls_retry_once_through_the_supervisor_restart_budget
    config, snapshot, supervisor = setup_environment({}, "MCP_TEST_SERVER_EXIT_MID_CALL" => "1")
    retrying = Supervisor.new(
      config,
      retry_budget: 1,
      base_backoff: 0.01,
      max_backoff: 0.05,
      random: Random.new(42)
    )
    descriptor = descriptor_for(snapshot, "sleep_ms", effect_class: :read_only)
    first_pid = retrying.pid

    error = assert_raises(Tamoz::Mcp::UnavailableError) do
      Invocation.call(descriptor, { "ms" => 1 }, snapshot: snapshot, supervisor: retrying)
    end

    assert error.retryable?
    assert_equal 2, retrying.consecutive_failures, "the retry consumed one restart, then the budget was exhausted"
    refute retrying.open?, "2 failures stay below the default threshold of 3"
    refute_nil retrying.pid, "a fresh process was spawned by the restart"
    assert_equal :degraded, retrying.state
  ensure
    retrying&.close
    supervisor&.close
  end

  def test_available_check_fails_typed_when_supervisor_is_retired
    _config, snapshot, supervisor = setup_environment
    descriptor = descriptor_for(snapshot, "echo_constant", effect_class: :read_only)
    supervisor.close

    error = assert_raises(Tamoz::Mcp::UnavailableError) do
      Invocation.call(descriptor, { "value" => "x" }, snapshot: snapshot, supervisor: supervisor)
    end

    assert error.retryable?
    assert_match(/retired/, error.message)
  end
end

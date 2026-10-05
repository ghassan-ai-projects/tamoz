# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/mcp/websearch"

class WebsearchCircuitTest < Minitest::Test
  EgressCircuit = Tamoz::Mcp::Websearch::EgressCircuit

  def circuit(threshold: 3, budget_breach: true)
    EgressCircuit.new(
      threshold:, scope_id: "egress:websearch", budget_breach:
    )
  end

  def operator_evidence(digest = "sha256:#{"a" * 64}")
    {"authority" => "owner", "operator_command_digest" => digest}
  end

  def test_consecutive_connect_failures_open_the_egress_circuit
    store = circuit
    assert_equal :degraded, store.record_failure(kind: :connect)
    assert_equal :degraded, store.record_failure(kind: :connect)
    refute store.open?
    assert_equal 2, store.failures
    assert_equal :open, store.record_failure(kind: :connect)
    assert store.open?
    assert_equal :connect, store.last_failure_kind
  end

  def test_budget_breach_opens_the_circuit_immediately
    store = circuit
    assert_equal :open, store.record_failure(kind: :budget_breach)
    assert store.open?
  end

  def test_budget_breach_condition_is_operator_declared
    store = circuit(budget_breach: false)
    assert_equal :degraded, store.record_failure(kind: :budget_breach)
    refute store.open?
    # Consecutive failures still open it.
    3.times { store.record_failure(kind: :connect) }
    assert store.open?
  end

  # W7: a success resets the owner's consecutive counter but never closes an
  # open circuit; time alone never resets.
  def test_success_never_closes_an_open_circuit
    store = circuit
    3.times { store.record_failure(kind: :connect) }
    assert store.open?
    store.record_success
    assert store.open?, "time/success alone never resets an open circuit"
  end

  def test_reset_requires_operator_authority
    store = circuit
    3.times { store.record_failure(kind: :connect) }
    assert store.open?

    assert_raises(Tamoz::Mcp::CircuitPolicyError) do
      store.reset(evidence: {"authority" => "websearch", "actor" => "capability"})
    end
    assert_raises(Tamoz::Mcp::CircuitPolicyError) do
      store.reset(evidence: nil)
    end
    assert_raises(Tamoz::Mcp::CircuitPolicyError) do
      store.reset(evidence: {"authority" => "owner"})
    end
    assert_raises(Tamoz::Mcp::CircuitPolicyError) do
      store.reset(evidence: {"authority" => "owner", "operator_command_digest" => "not-a-digest"})
    end
    assert store.open?, "refused resets leave the circuit open"

    store.reset(evidence: operator_evidence)
    refute store.open?
    assert_equal "sha256:#{"a" * 64}", store.reset_evidence.fetch("operator_command_digest")
  end

  def test_conditions_digest_is_deterministic
    first = circuit
    second = circuit
    first.record_failure(kind: :timeout, context: {"tool_name" => "search"})
    second.record_failure(kind: :timeout, context: {"tool_name" => "search"})
    assert_equal first.conditions_digest("websearch"), second.conditions_digest("websearch")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, first.conditions_digest("websearch"))
  end

  def test_egress_circuit_plugs_into_the_supervisor_seam
    store = circuit
    config = Tamoz::Mcp::ServerConfig.new(
      server_id: "websearch",
      transport: :stdio,
      command: RbConfig.ruby,
      arguments: [ROOT.join("script", "mcp_test_server").to_s],
      working_directory: Dir.tmpdir
    )
    supervisor = Tamoz::Mcp::Supervisor.new(config, circuit_store: store)
    supervisor.start
    supervisor.record_failure(kind: :connect)
    supervisor.record_failure(kind: :connect)
    supervisor.record_failure(kind: :connect)
    assert supervisor.open?
    assert_equal :open, supervisor.state
    supervisor.record_success
    assert supervisor.open?
  ensure
    supervisor&.close
  end

  # W7: an open egress circuit renders typed-unavailable through the real
  # invocation path, with no new spawn (no outbound while open).
  def test_open_circuit_renders_typed_unavailable_without_outbound
    dir = Dir.mktmpdir("tamoz-websearch-circuit")
    require "tamoz/mcp"
    config = Tamoz::Mcp::ServerConfig.new(
      server_id: "websearch",
      transport: :stdio,
      command: RbConfig.ruby,
      arguments: [ROOT.join("script", "mcp_test_server").to_s],
      working_directory: dir,
      env_allowlist: %w[PATH HOME LANG LC_ALL TMPDIR GEM_HOME GEM_PATH RUBYLIB]
    )
    snapshot = Tamoz::Mcp::Catalog.compile(config)
    store = circuit
    supervisor = Tamoz::Mcp::Supervisor.new(config, circuit_store: store)
    descriptor = Tamoz::Mcp::Invocation.descriptor_for(
      snapshot.entries.find { |entry| entry.name == "search" },
      snapshot:,
      effect_class: :unknown_effects
    )
    begin
      supervisor.start
      3.times { supervisor.record_failure(kind: :connect) }
      assert supervisor.open?
      pid_before = supervisor.pid
      error = assert_raises(Tamoz::Mcp::UnavailableError) do
        Tamoz::Mcp::Invocation.call(
          descriptor, {"query" => "x"}, snapshot:, supervisor:
        )
      end
      assert_match(/mcp_unavailable/, error.message)
      assert_equal pid_before, supervisor.pid, "no outbound while the circuit is open"
    ensure
      supervisor.close
    end
  ensure
    FileUtils.remove_entry(dir) if dir
  end
end

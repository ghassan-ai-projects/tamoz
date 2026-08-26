# frozen_string_literal: true

require_relative "test_helper"

class SQLiteScenarioRegistryTest < Minitest::Test
  EXPECTED_IDS = %w[
    checkpoint.commit-advance
    checkpoint.commit-failed
    checkpoint.commit-fork
    checkpoint.commit-paused
    checkpoint.commit-start
    checkpoint.commit-turn
    checkpoint.writes-duplicate
    checkpoint.writes-new
    lease.acquire-new
    lease.acquire-takeover
    lease.release
    lease.renew
    lease.validate
    request.claim-redirect
    request.claim-resume
    request.claim-stale
    request.claim-turn
    request.enqueue-duplicate
    request.enqueue-new
    request.mark-redirect-running
    request.mark-running
    request.recover-claimed
    request.recover-redirecting
    request.recover-running
    request.recover-stale
    request.redirect-ready
  ].freeze

  def test_registry_is_bounded_versioned_deterministic_and_deeply_frozen
    first = SQLiteHarnessInputs.registry
    second = SQLiteHarnessInputs.registry

    assert_equal first.document, second.document
    assert_equal first.digest, second.digest
    assert_match(/\Asha256:[0-9a-f]{64}\z/, first.digest)
    assert_equal 1, first.document.fetch("registry_version")
    assert_equal 32, first.document.fetch("maximum_scenarios")
    assert_equal(
      EXPECTED_IDS,
      first.document.fetch("scenarios").map { |scenario| scenario.fetch("id") }
    )
    assert_equal 26, first.document.fetch("scenarios").length
    assert_deeply_frozen(first.document)
    assert_deeply_frozen(SQLiteHarnessInputs.scenarios)
    assert first.frozen?
  end

  def test_every_scenario_has_an_exact_branch_contract_and_reference
    registry = SQLiteHarnessInputs.registry

    registry.document.fetch("scenarios").each do |scenario|
      assert_equal(
        %w[
          id version family operation setup action state_classes contract
          convergence coverage
        ],
        scenario.keys
      )
      assert_equal scenario.fetch("id"), scenario.fetch("setup")
      assert_equal scenario.fetch("operation"), scenario.fetch("action")
      assert scenario.fetch("coverage").any?
      assert_equal scenario.fetch("coverage").uniq, scenario.fetch("coverage")
      reference = registry.reference(scenario.fetch("id"))
      assert_equal scenario.fetch("id"), reference.fetch("id")
      assert_equal 1, reference.fetch("version")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, reference.fetch("digest"))
      assert_deeply_frozen(reference)
    end

    assert_equal(
      %w[old new],
      registry.fetch("request.claim-resume").fetch("state_classes")
    )
    assert_includes(
      registry.fetch("request.claim-resume").fetch("coverage"),
      "request.claim.active_execution"
    )
    assert_equal(
      ["stable"],
      registry.fetch("request.enqueue-duplicate").fetch("state_classes")
    )
  end

  def test_declared_union_exactly_matches_phase_two_kill_required_registry
    assert SQLiteHarnessInputs.registry.verify_boundary_registry!(boundary_registry)
  end

  def test_unknown_or_malformed_definitions_fail_closed
    registry = SQLiteHarnessInputs.registry
    assert_nil registry.scenario("request.unknown")
    assert_raises(Tamoz::Evals::ExecutionError) { registry.fetch("request.unknown") }
    assert_raises(Tamoz::Evals::ExecutionError) { registry.scenario("../escape") }

    source = mutable_copy(registry.document.fetch("scenarios"))
    treatments = []
    treatments << source.map(&:dup).tap { |items| items << items.first.dup }
    treatments << source.map(&:dup).tap { |items| items.first["extra"] = true }
    treatments << source.map(&:dup).tap { |items| items.first["version"] = 0 }
    treatments << source.map(&:dup).tap do |items|
      items.first["state_classes"] = %w[old stable]
    end
    treatments << source.map(&:dup).tap { |items| items.first["coverage"] = [] }
    treatments << source.map(&:dup).tap do |items|
      items.first["coverage"] = [items.first.fetch("coverage").first] * 2
    end

    treatments.each do |definitions|
      assert_raises(Tamoz::Evals::ExecutionError) do
        registry_class.new(
          definitions,
          maximum_scenarios: 32,
          families: %w[lease request checkpoint],
          state_classes: %w[old new stable]
        )
      end
    end
  end

  def test_boundary_drift_and_unknown_declared_statement_fail_closed
    registry = SQLiteHarnessInputs.registry
    bad_document = mutable_copy(boundary_registry.document)
    bad_document.fetch("operations").find do |operation|
      operation.fetch("operation") == "request.claim"
    end.fetch("statements").delete_if do |statement|
      statement.fetch("template") == "request.claim.active_execution"
    end
    fake = fake_boundary_registry(bad_document)

    assert_raises(Tamoz::Evals::ExecutionError) do
      registry.verify_boundary_registry!(fake)
    end
  end

  def test_fault_gate_ignores_bootstrap_then_delegates_exactly_and_once
    gate = fault_gate_class.new
    observed = []
    observer = Object.new
    observer.define_singleton_method(:call) do |point, metadata|
      observed << [point, metadata]
      :observed
    end
    observer.define_singleton_method(:finish!) { observed << :finished }
    metadata = {"bootstrap" => true}.freeze

    assert_nil gate.call(:before_begin, metadata)
    assert_same gate, gate.arm!(observer)
    assert_equal :observed, gate.call(:after_begin, metadata)
    assert gate.finish!
    assert_equal [[:after_begin, metadata], :finished], observed
    assert_raises(Tamoz::Evals::ExecutionError) { gate.arm!(observer) }
    assert_raises(Tamoz::Evals::ExecutionError) do
      gate.call(:after_commit, metadata)
    end
  end

  private

  def registry_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioRegistry, false)
  end

  def fault_gate_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioFaultGate, false)
  end

  def boundary_registry
    Tamoz::SQLite.const_get(:BoundaryRegistry, false)
  end

  def mutable_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def fake_boundary_registry(document)
    operations = document.fetch("operations").to_h do |operation|
      [operation.fetch("operation"), operation]
    end
    Object.new.tap do |fake|
      frozen_document = Tamoz::Evals::DeepFreeze.call(document)
      fake.define_singleton_method(:document) { frozen_document }
      fake.define_singleton_method(:digest) { "sha256:#{"0" * 64}" }
      fake.define_singleton_method(:operation) { |name| operations[name] }
      fake.define_singleton_method(:phase_operations) do |phase:, kill_required: nil|
        frozen_document.fetch("operations").select do |operation|
          operation.fetch("phase") == phase &&
            (kill_required.nil? ||
             operation.fetch("kill_required") == kill_required)
        end
      end
      fake.define_singleton_method(:resolve_statement) do |operation, statement|
        entry = operations[operation]
        entry&.fetch("statements")&.find do |candidate|
          candidate.fetch("template") == statement
        end
      end
    end
  end

  def assert_deeply_frozen(value)
    assert value.frozen?
    case value
    when Hash
      value.each do |key, entry|
        assert_deeply_frozen(key)
        assert_deeply_frozen(entry)
      end
    when Array
      value.each { |entry| assert_deeply_frozen(entry) }
    end
  end
end

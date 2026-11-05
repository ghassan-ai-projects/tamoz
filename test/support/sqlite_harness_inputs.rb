# frozen_string_literal: true

require_relative 'sqlite_harness_definitions'

module SQLiteHarnessInputs
  module_function

  def scenarios = SQLiteHarnessScenarios.scenarios
  def driver_definition = SQLiteHarnessDefinitions.driver_definition
  def probe_definition = SQLiteHarnessDefinitions.probe_definition

  def registry
    registry_class = Tamoz::Evals::Harness.const_get(:SQLiteScenarioRegistry, false)
    @registry ||= registry_class.new(
      scenarios,
      maximum_scenarios: 32,
      families: %w[lease request checkpoint],
      state_classes: %w[old new stable]
    )
  end

  def probe_inputs
    {
      graph_factory: method(:graph_factory),
      probes: SQLiteHarnessStates.probes,
      request_states: SQLiteHarnessStates.request_states,
      checkpoint_states: SQLiteHarnessStates.checkpoint_states,
      request_checkpoint_states: SQLiteHarnessStates.request_checkpoint_states,
      recovery_history_counts: SQLiteHarnessStates.recovery_history_counts,
      identifiers: SQLiteHarnessDefinitions.runtime_identifiers.merge('ledger_invocation' => 'work.phase2')
    }
  end

  def driver
    driver_class = Tamoz::Evals::Harness.const_get(:SQLiteScenarioDriver, false)
    @driver ||= driver_class.new(
      scenario_registry: registry,
      boundary_registry: Tamoz::SQLite.const_get(:BoundaryRegistry, false),
      definition: driver_definition,
      runtime_inputs: runtime_inputs
    )
  end

  def subprocess_runner
    Tamoz::Evals::Harness::SubprocessRunner.new(
      root: ROOT,
      environment: {},
      output_limit_bytes: 4_096,
      termination_grace_ms: 200
    )
  end

  def child_command(layout:, selector:, suite: 'SQLite scenario', **run)
    descriptor = layout.descriptor
    scenario_id, scenario_reference, database_path = run.fetch_values(:scenario_id, :scenario_reference, :database_path)
    script = <<~RUBY
      require 'tamoz/evals/runner'
      require 'tamoz/sqlite'
      require 'support/sqlite_harness_inputs'
      control = Tamoz::Evals::Harness.const_get(:SQLiteSelectorControl, false)
      registry = Tamoz::SQLite.const_get(:BoundaryRegistry, false)
      layout = control.attach!(directory: #{descriptor.fetch('directory').inspect},
        device: #{descriptor.fetch('device')}, inode: #{descriptor.fetch('inode')})
      stopper = control.stopper(layout: layout, scenario: #{scenario_reference.inspect},
        selector: #{selector.inspect}, registry: registry)
      SQLiteHarnessInputs.driver.run(
        scenario_id: #{scenario_id.inspect}, path: #{database_path.inspect},
        observer: stopper
      )
      abort "#{suite} selector returned"
    RUBY
    [RbConfig.ruby, *SUBPROCESS_LIB_ARGS, '-e', script]
  end

  def runtime_inputs
    {
      'graph' => SQLiteHarnessDefinitions.graph,
      'graph_factory' => method(:graph_factory),
      'identifiers' => SQLiteHarnessDefinitions.runtime_identifiers,
      'preparers' => SQLiteHarnessStates.preparers,
      'failure_payload' => SQLiteHarnessDefinitions.failure_payload
    }
  end

  def graph_factory(name:, version:)
    Tamoz.graph(name:, version:) do
      state :value, default: 0
      state :events, reduce: :append, default: []
      node(:work, implementation_name: 'tamoz.eval.sqlite.work', version: '1') do |_state, _context|
        yield if block_given?
        { value: 1 }
      end
      edge Tamoz::START, :work
      edge :work, Tamoz::END
    end
  end

  def probe
    probe_class = Tamoz::Evals::Harness.const_get(:SQLiteConvergenceProbe, false)
    @probe ||= probe_class.new(
      scenario_registry: registry,
      definition: probe_definition,
      inputs: probe_inputs
    )
  end
end

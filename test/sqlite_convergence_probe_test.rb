# frozen_string_literal: true

require_relative "test_helper"

class SQLiteConvergenceProbeTest < Minitest::Test
  PROBE_DIGEST =
    "sha256:7d016bab925eb8ad88ad2af5cd6d1c8bb519fd435e4761c54f2f00dd57277594"
  REPORT_FIELDS = %w[
    classification content_digest convergence_version definition_digest facts
    probe result scenario
  ].freeze

  def test_every_fixed_complete_state_passes_its_probe_in_a_fresh_process
    Dir.mktmpdir("tamoz-sqlite-convergence") do |directory|
      scenarios.each_with_index do |scenario, scenario_index|
        scenario.fetch("state_classes").each_with_index do |classification, state_index|
          name = "#{scenario_index}-#{state_index}"
          source = File.join(directory, "source-#{name}.db")
          build_state(scenario.fetch("id"), classification, source)
          oracle = classify(scenario.fetch("id"), source)
          assert_equal classification,
                       oracle.fetch("classification"),
                       "#{scenario.fetch("id")} #{classification}"

          path = File.join(directory, "probe-#{name}.db")
          copy_database(source, path)
          probe = probe_definition.fetch("scenario_probes")
                                  .fetch(scenario.fetch("id"))
          expire_active_lease(path) if %w[
            lease-fencing
            pending-write-replay
            request-recovery
          ].include?(probe)
          ledger = if probe == "pending-write-replay"
                     ledger_path = File.join(directory, "ledger-#{name}.db")
                     seed = classification == "old" ? 0 : 1
                     prepare_ledger(ledger_path, seed:)
                     ledger_path
                   end

          report = run_probe(
            scenario.fetch("id"),
            classification,
            path,
            ledger
          )
          assert_report(
            report,
            scenario_id: scenario.fetch("id"),
            classification:,
            probe:,
            sensitive_paths: [path, ledger].compact
          )
        end
      end
    end
  end

  def test_probe_definition_is_complete_pinned_and_deeply_frozen
    assert_equal 1, probe_definition.fetch("version")
    assert_equal scenarios.map { |scenario| scenario.fetch("id") }.sort,
                 probe_definition.fetch("scenario_probes").keys.sort
    assert_equal PROBE_DIGEST, probe_class.digest
    assert_deeply_frozen(probe_definition)
  end

  def test_classification_mismatch_active_lease_and_bad_ledger_fail_closed
    Dir.mktmpdir("tamoz-sqlite-convergence-invalid") do |directory|
      mismatch = File.join(directory, "mismatch.db")
      build_state("request.recover-claimed", "old", mismatch)
      _stdout, _stderr, status = raw_probe(
        "request.recover-claimed",
        "stable",
        mismatch,
        nil
      )
      refute status.success?

      active = File.join(directory, "active.db")
      build_state("request.recover-running", "new", active)
      _stdout, _stderr, status = raw_probe(
        "request.recover-running",
        "new",
        active,
        nil
      )
      refute status.success?

      pending = File.join(directory, "pending.db")
      build_state("checkpoint.writes-new", "new", pending)
      expire_active_lease(pending)
      ledger = File.join(directory, "ledger.db")
      prepare_ledger(ledger, seed: 0)
      _stdout, _stderr, status = raw_probe(
        "checkpoint.writes-new",
        "new",
        pending,
        ledger
      )
      refute status.success?

      bad_schema = File.join(directory, "bad-schema-ledger.db")
      database = SQLite3::Database.new(bad_schema, strict: true)
      database.execute("CREATE TABLE invocations(logical_id TEXT)")
      database.execute(
        "INSERT INTO invocations(logical_id) VALUES ('work.phase2')"
      )
      database.close
      File.chmod(0o600, bad_schema)
      _stdout, _stderr, status = raw_probe(
        "checkpoint.writes-new",
        "new",
        pending,
        bad_schema
      )
      refute status.success?

      oversized = File.join(directory, "oversized-ledger.db")
      File.open(oversized, "wb", 0o600) do |file|
        file.truncate((1024 * 1024) + 1)
      end
      _stdout, _stderr, status = raw_probe(
        "checkpoint.writes-new",
        "new",
        pending,
        oversized
      )
      refute status.success?
    end
  end

  def test_pending_write_probe_detects_reexecution_with_unique_full_ledger
    Dir.mktmpdir("tamoz-sqlite-convergence-ledger") do |directory|
      path = File.join(directory, "pending.db")
      build_state("checkpoint.writes-new", "new", path)
      expire_active_lease(path)
      ledger = File.join(directory, "ledger.db")
      prepare_ledger(ledger, seed: 1)

      report = run_probe(
        "checkpoint.writes-new",
        "new",
        path,
        ledger
      )
      assert_equal 1, report.dig("facts", "ledger_before")
      assert_equal 1, report.dig("facts", "ledger_after")
      assert_equal 1, ledger_count(ledger)
    end
  end

  def test_reports_are_normalized_across_generated_execution_ids_and_times
    reports = []
    Dir.mktmpdir("tamoz-sqlite-convergence-normalized") do |directory|
      2.times do |index|
        source = File.join(directory, "source-#{index}.db")
        build_state("request.recover-running", "new", source)
        path = File.join(directory, "probe-#{index}.db")
        copy_database(source, path)
        expire_active_lease(path)
        reports << run_probe(
          "request.recover-running",
          "new",
          path,
          nil
        )
      end
    end
    assert_equal reports.fetch(0), reports.fetch(1)
  end

  private

  def scenarios
    scenario_registry.document.fetch("scenarios")
  end

  def scenario_registry
    @scenario_registry ||= registry_class.build
  end

  def registry_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioRegistry, false)
  end

  def driver_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioDriver, false)
  end

  def probe_class
    Tamoz::Evals::Harness.const_get(:SQLiteConvergenceProbe, false)
  end

  def probe_definition
    probe_class.definition
  end

  def driver
    @driver ||= driver_class.new(
      scenario_registry:,
      boundary_registry:
    )
  end

  def boundary_registry
    Tamoz::SQLite.const_get(:BoundaryRegistry, false)
  end

  def subject
    {
      "id" => "tamoz-sqlite",
      "version" => Tamoz::SQLite::VERSION,
      "git_revision" => "a" * 40,
      "git_tree" => "b" * 40,
      "dirty" => false
    }
  end

  def build_state(scenario_id, classification, path)
    if classification == "old"
      observer = lambda do |point, _metadata|
        raise "fixed pre-action abort" if point.to_s == "before_begin"
      end
      assert_raises(Tamoz::Evals::ExecutionError) do
        driver.run(scenario_id:, path:, observer:)
      end
    else
      driver.trace(scenario_id:, path:, subject:)
    end
  end

  def classify(scenario_id, path)
    stdout, stderr, status = Open3.capture3(
      clean_environment,
      RbConfig.ruby,
      ROOT.join("script", "tamoz_sqlite_oracle").to_s,
      scenario_id,
      path
    )
    context = scenario_id
    assert_equal "", stderr, context
    assert status.success?, "#{context}: #{stdout}"
    JSON.parse(stdout)
  end

  def run_probe(scenario_id, classification, path, ledger)
    stdout, stderr, status = raw_probe(
      scenario_id,
      classification,
      path,
      ledger
    )
    context = "#{scenario_id} #{classification}"
    assert_equal "", stderr, context
    assert status.success?, "#{context}: #{stdout}"
    assert_equal 1, stdout.lines.length
    JSON.parse(stdout)
  end

  def raw_probe(scenario_id, classification, path, ledger)
    load_paths = %w[
      tamoz-cancellation tamoz-concurrency tamoz-core tamoz-graph tamoz-scheduler
      tamoz-stream tamoz-evals tamoz-sqlite
    ].flat_map do |name|
      ["-I", GEM_ROOTS.fetch(name).join("lib").to_s]
    end
    script = <<~'RUBY'
      require "json"
      require "tamoz/evals"
      require "tamoz/sqlite"
      harness = Tamoz::Evals::Harness
      registry = harness.const_get(:SQLiteScenarioRegistry, false).build
      probe = harness.const_get(:SQLiteConvergenceProbe, false).new(
        scenario_registry: registry
      )
      report = probe.run(
        scenario_id: ENV.fetch("TAMOZ_SCENARIO"),
        classification: ENV.fetch("TAMOZ_CLASSIFICATION"),
        path: ENV.fetch("TAMOZ_DATABASE"),
        ledger_path: ENV["TAMOZ_LEDGER"]
      )
      puts Tamoz::Evals::CanonicalJSON.dump(report)
    RUBY
    environment = clean_environment.merge(
      "TAMOZ_SCENARIO" => scenario_id,
      "TAMOZ_CLASSIFICATION" => classification,
      "TAMOZ_DATABASE" => path,
      "TAMOZ_LEDGER" => ledger
    )
    Open3.capture3(
      environment,
      RbConfig.ruby,
      *load_paths,
      "-e",
      script
    )
  end

  def clean_environment
    ENV.each_key
       .grep(/\A(?:BUNDLE|BUNDLER|RUBYLIB|RUBYOPT|TAMOZ_)/)
       .to_h { |key| [key, nil] }
  end

  def copy_database(source, destination)
    ["", "-wal", "-shm"].each do |suffix|
      candidate = "#{source}#{suffix}"
      next unless File.exist?(candidate)

      target = "#{destination}#{suffix}"
      FileUtils.cp(candidate, target)
      File.chmod(0o600, target)
    end
  end

  def expire_active_lease(path)
    database = SQLite3::Database.new(path, strict: true)
    database.execute(
      <<~SQL
        UPDATE tamoz_namespaces
        SET lease_expires_at_ms = 0
        WHERE lease_owner_id IS NOT NULL
      SQL
    )
  ensure
    database&.close
  end

  def prepare_ledger(path, seed:)
    database = SQLite3::Database.new(path, strict: true)
    database.execute("PRAGMA journal_mode = WAL")
    database.execute("PRAGMA synchronous = FULL")
    database.execute(
      "CREATE TABLE invocations(logical_id TEXT PRIMARY KEY) STRICT"
    )
    if seed == 1
      database.execute(
        "INSERT INTO invocations(logical_id) VALUES ('work.phase2')"
      )
    end
    database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
  ensure
    database&.close
    File.chmod(0o600, path) if File.exist?(path)
  end

  def ledger_count(path)
    database = SQLite3::Database.new(path, readonly: true, strict: true)
    database.get_first_value("SELECT COUNT(*) FROM invocations")
  ensure
    database&.close
  end

  def assert_report(
    report,
    scenario_id:,
    classification:,
    probe:,
    sensitive_paths:
  )
    assert_equal REPORT_FIELDS, report.keys
    assert_equal 1, report.fetch("convergence_version")
    assert_equal probe_class.digest, report.fetch("definition_digest")
    assert_equal scenario_id, report.fetch("scenario")
    assert_equal classification, report.fetch("classification")
    assert_equal probe, report.fetch("probe")
    assert_equal "passed", report.fetch("result")
    assert_kind_of Hash, report.fetch("facts")
    expected = Tamoz::Evals::CanonicalJSON.content_digest(
      report,
      domain: "eval.sqlite_convergence_report"
    )
    assert_equal expected, report.fetch("content_digest")
    encoded = JSON.generate(report)
    sensitive_paths.each { |path| refute_includes encoded, path }
    refute_match(/owner\.phase2|thread\.phase2|request\.phase2|execution\.phase2/, encoded)
    assert_operator encoded.bytesize, :<, 4_096
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

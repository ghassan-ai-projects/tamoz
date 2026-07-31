# frozen_string_literal: true

require_relative "test_helper"

class SQLiteRawOracleTest < Minitest::Test
  ORACLE = ROOT.join("script", "tamoz_sqlite_oracle").freeze
  ORACLE_DIGEST =
    "sha256:072d5bed69eb5d0253aedbddcb4623ab0cffd8c7a637bb242c05a779c5138530"
  REPORT_FIELDS = %w[
    classification content_digest foreign_keys integrity oracle_digest
    oracle_version projection_digest reason_codes scenario
  ].freeze
  STABLE = %w[
    checkpoint.writes-duplicate
    request.enqueue-duplicate
    request.redirect-ready
  ].freeze

  def test_every_fixed_success_and_pre_action_state_classifies_exactly
    Dir.mktmpdir("tamoz-sqlite-oracle-all") do |directory|
      scenarios.each_with_index do |scenario, index|
        scenario_id = scenario.fetch("id")
        old_path = File.join(directory, "old-#{index}.db")
        abort_before_subject(scenario_id, old_path)
        old = oracle(scenario_id, old_path)
        expected_old = STABLE.include?(scenario_id) ? "stable" : "old"
        assert_equal expected_old, old.fetch("classification"), scenario_id
        assert_equal 0, old.fetch("_exit_status"), scenario_id
        assert_report(old, scenario_id:)

        new_path = File.join(directory, "new-#{index}.db")
        trace_scenario(scenario_id, new_path)
        new_state = oracle(scenario_id, new_path)
        expected_new = STABLE.include?(scenario_id) ? "stable" : "new"
        assert_equal expected_new,
                     new_state.fetch("classification"),
                     scenario_id
        assert_equal 0, new_state.fetch("_exit_status"), scenario_id
        assert_report(new_state, scenario_id:)
        if STABLE.include?(scenario_id)
          assert_equal old.fetch("projection_digest"),
                       new_state.fetch("projection_digest"),
                       scenario_id
        else
          refute_equal old.fetch("projection_digest"),
                       new_state.fetch("projection_digest"),
                       scenario_id
        end
      end
    end
  end

  def test_before_commit_kills_are_old_and_after_commit_kills_are_new
    skip "POSIX selector evidence requires SIGSTOP" unless Signal.list.key?("STOP")

    Dir.mktmpdir("tamoz-sqlite-oracle-kill") do |directory|
      scenarios.each_with_index do |scenario, index|
        scenario_id = scenario.fetch("id")
        trace = trace_scenario(
          scenario_id,
          File.join(directory, "trace-#{index}.db")
        )
        %w[before_commit after_commit].each do |point|
          selector = trace.fetch("selectors").find do |candidate|
            candidate.fetch("point") == point &&
              candidate.fetch("statement").nil?
          end
          refute_nil selector, "#{scenario_id} #{point}"
          path = File.join(directory, "#{point}-#{index}.db")
          kill_scenario!(
            directory:,
            name: "#{point.tr("_", "-")}-#{index}",
            scenario_id:,
            selector:,
            path:
          )
          result = oracle(scenario_id, path)
          expected = if STABLE.include?(scenario_id)
                       "stable"
                     elsif point == "before_commit"
                       "old"
                     else
                       "new"
                     end
          assert_equal expected,
                       result.fetch("classification"),
                       "#{scenario_id} #{point}"
          assert_equal 0, result.fetch("_exit_status")
        end
      end
    end
  end

  def test_logically_mixed_transaction_is_partial_not_old_or_new
    Dir.mktmpdir("tamoz-sqlite-oracle-partial") do |directory|
      path = File.join(directory, "mixed.db")
      trace_scenario("checkpoint.commit-turn", path)
      mutate(path) do |database|
        database.execute(
          <<~SQL
            DELETE FROM tamoz_request_transitions
            WHERE transition_index = 2
          SQL
        )
        database.execute(
          <<~SQL
            UPDATE tamoz_requests
            SET status = 'claimed', checkpoint_id = NULL,
                response = NULL, response_digest = NULL
          SQL
        )
      end

      result = oracle("checkpoint.commit-turn", path)
      assert_equal "partial", result.fetch("classification")
      assert_equal ["state_mismatch"], result.fetch("reason_codes")
      assert_equal 2, result.fetch("_exit_status")
      assert_equal "ok", result.fetch("integrity")
      assert_equal "ok", result.fetch("foreign_keys")
    end
  end

  def test_digest_canonical_json_relation_foreign_key_and_schema_fail_closed
    Dir.mktmpdir("tamoz-sqlite-oracle-invalid") do |directory|
      digest_path = File.join(directory, "digest.db")
      trace_scenario("request.enqueue-new", digest_path)
      mutate(digest_path) do |database|
        database.execute(
          "UPDATE tamoz_requests SET payload_digest = ?",
          ["sha256:#{"0" * 64}"]
        )
      end
      assert_invalid(
        oracle("request.enqueue-new", digest_path),
        "digest_invalid"
      )

      canonical_path = File.join(directory, "canonical.db")
      trace_scenario("request.enqueue-new", canonical_path)
      mutate(canonical_path) do |database|
        database.execute(
          "UPDATE tamoz_request_transitions SET evidence = ?",
          [SQLite3::Blob.new('{"kind":"enqueue","kind":"enqueue"}')]
        )
      end
      assert_invalid(
        oracle("request.enqueue-new", canonical_path),
        "json_invalid"
      )

      unicode_path = File.join(directory, "unicode.db")
      trace_scenario("request.enqueue-new", unicode_path)
      mutate(unicode_path) do |database|
        database.execute(
          "UPDATE tamoz_request_transitions SET evidence = ?",
          [SQLite3::Blob.new(JSON.generate({"kind" => "e\u0301nqueue"}))]
        )
      end
      assert_invalid(
        oracle("request.enqueue-new", unicode_path),
        "json_invalid"
      )

      relation_path = File.join(directory, "relation.db")
      trace_scenario("request.claim-turn", relation_path)
      mutate(relation_path) do |database|
        database.execute(
          <<~SQL
            UPDATE tamoz_request_transitions
            SET transition_index = 2
            WHERE transition_index = 1
          SQL
        )
      end
      assert_invalid(
        oracle("request.claim-turn", relation_path),
        "relation_invalid"
      )

      foreign_path = File.join(directory, "foreign.db")
      trace_scenario("checkpoint.commit-fork", foreign_path)
      mutate(foreign_path, foreign_keys: false) do |database|
        database.execute(
          <<~SQL
            UPDATE tamoz_checkpoints
            SET parent_id = 'checkpoint.missing'
            WHERE sequence = 2
          SQL
        )
      end
      result = oracle("checkpoint.commit-fork", foreign_path)
      assert_invalid(result, "foreign_key_invalid")
      assert_equal "ok", result.fetch("integrity")
      assert_equal "failed", result.fetch("foreign_keys")

      schema_path = File.join(directory, "schema.db")
      trace_scenario("lease.acquire-new", schema_path)
      mutate(schema_path) { |database| database.execute("PRAGMA user_version = 2") }
      assert_invalid(
        oracle("lease.acquire-new", schema_path),
        "schema_invalid"
      )

      missing_schema_path = File.join(directory, "missing-schema.db")
      trace_scenario("lease.acquire-new", missing_schema_path)
      mutate(missing_schema_path) do |database|
        database.execute("DROP TABLE tamoz_schema_migrations")
      end
      assert_invalid(
        oracle("lease.acquire-new", missing_schema_path),
        "schema_invalid"
      )
    end
  end

  def test_recomputed_outer_digest_cannot_hide_payload_relation_corruption
    Dir.mktmpdir("tamoz-sqlite-oracle-correlated") do |directory|
      path = File.join(directory, "checkpoint.db")
      trace_scenario("checkpoint.commit-start", path)
      mutate(path) do |database|
        id, payload = database.get_first_row(
          "SELECT id, payload FROM tamoz_checkpoints"
        )
        wire = JSON.parse(payload)
        wire[6] = "completed"
        changed = JSON.generate(wire)
        digest = wire_digest(
          changed,
          domain: "tamoz.sqlite.checkpoint_payload"
        )
        database.execute(
          <<~SQL,
            UPDATE tamoz_checkpoints
            SET payload = ?, payload_digest = ?
            WHERE id = ?
          SQL
          [SQLite3::Blob.new(changed), digest, id]
        )
      end

      assert_invalid(
        oracle("checkpoint.commit-start", path),
        "relation_invalid"
      )
    end
  end

  def test_response_error_pending_outcome_schema_and_row_bounds_fail_closed
    Dir.mktmpdir("tamoz-sqlite-oracle-bounds") do |directory|
      response_path = File.join(directory, "response.db")
      trace_scenario("checkpoint.commit-turn", response_path)
      mutate(response_path) do |database|
        database.execute(
          "UPDATE tamoz_requests SET response_digest = ?",
          ["sha256:#{"0" * 64}"]
        )
      end
      assert_invalid(
        oracle("checkpoint.commit-turn", response_path),
        "digest_invalid"
      )

      error_path = File.join(directory, "error.db")
      trace_scenario("checkpoint.commit-failed", error_path)
      mutate(error_path) do |database|
        database.execute(
          "UPDATE tamoz_requests SET terminal_error_digest = ?",
          ["sha256:#{"0" * 64}"]
        )
      end
      assert_invalid(
        oracle("checkpoint.commit-failed", error_path),
        "digest_invalid"
      )

      pending_path = File.join(directory, "pending.db")
      trace_scenario("checkpoint.writes-new", pending_path)
      mutate(pending_path) do |database|
        payload = database.get_first_value(
          "SELECT payload FROM tamoz_pending_writes WHERE write_index = 0"
        )
        wire = JSON.parse(payload)
        assert_equal ["integer", 1], wire.fetch(2)
        wire[2][1] = 2
        changed = JSON.generate(wire)
        database.execute(
          <<~SQL,
            UPDATE tamoz_pending_writes
            SET payload = ?, payload_digest = ?
            WHERE write_index = 0
          SQL
          [
            SQLite3::Blob.new(changed),
            wire_digest(changed, domain: "tamoz.sqlite.pending_write")
          ]
        )
      end
      assert_invalid(
        oracle("checkpoint.writes-new", pending_path),
        "digest_invalid"
      )

      checksum_path = File.join(directory, "checksum.db")
      trace_scenario("lease.acquire-new", checksum_path)
      mutate(checksum_path) do |database|
        database.execute(
          "UPDATE tamoz_schema_migrations SET checksum = 'wrong'"
        )
      end
      assert_invalid(
        oracle("lease.acquire-new", checksum_path),
        "schema_invalid"
      )

      rows_path = File.join(directory, "rows.db")
      trace_scenario("lease.acquire-new", rows_path)
      mutate(rows_path) do |database|
        database.transaction do
          256.times do |index|
            database.execute(
              <<~SQL,
                INSERT INTO tamoz_threads(
                  thread_id, tombstone_id, created_at_ms, updated_at_ms
                )
                VALUES (?, NULL, 0, 0)
              SQL
              ["extra.#{index}"]
            )
          end
        end
      end
      assert_invalid(
        oracle("lease.acquire-new", rows_path),
        "relation_invalid"
      )
    end
  end

  def test_valid_database_for_the_wrong_scenario_is_partial
    Dir.mktmpdir("tamoz-sqlite-oracle-scenario-mismatch") do |directory|
      path = File.join(directory, "request.db")
      trace_scenario("request.enqueue-new", path)
      result = oracle("lease.acquire-new", path)
      assert_equal "partial", result.fetch("classification")
      assert_equal ["state_mismatch"], result.fetch("reason_codes")
      assert_equal 2, result.fetch("_exit_status")
    end
  end

  def test_reports_normalize_generated_ids_times_and_hide_sensitive_values
    first = nil
    second = nil
    Dir.mktmpdir("tamoz-sqlite-oracle-normalized") do |directory|
      first_path = File.join(directory, "first.db")
      second_path = File.join(directory, "second.db")
      trace_scenario("request.claim-turn", first_path)
      trace_scenario("request.claim-turn", second_path)
      first = oracle("request.claim-turn", first_path)
      second = oracle("request.claim-turn", second_path)
      assert_equal first.reject { |key, _value| key == "_exit_status" },
                   second.reject { |key, _value| key == "_exit_status" }

      encoded = JSON.generate(first)
      refute_includes encoded, first_path
      refute_includes encoded, "owner.phase2"
      refute_includes encoded, "thread.phase2"
      refute_includes encoded, "request.phase2"
      refute_includes encoded, "execution.phase2"
      refute_match(/payload|raw_identifier/, encoded)
      assert_operator encoded.bytesize, :<, 4_096
    end
  end

  def test_oracle_is_standalone_read_only_and_has_no_arbitrary_sql_surface
    source = File.read(ORACLE, encoding: Encoding::UTF_8)
    assert File.executable?(ORACLE)
    assert_equal(
      %w[digest json sqlite3 tmpdir],
      source.scan(/^require "([^"]+)"$/).flatten.sort
    )
    refute_match(/require(?:_relative)? "tamoz\//, source)
    refute_match(
      /\b(?:instance_eval|class_eval|module_eval)\b|Kernel\.eval/,
      source
    )
    assert_includes source, "PRAGMA query_only = ON"
    assert_includes source, "readonly: true"

    Dir.mktmpdir("tamoz-sqlite-oracle-readonly") do |directory|
      path = File.join(directory, "tamoz.db")
      trace_scenario("checkpoint.commit-start", path)
      before = database_bytes(path)
      result = oracle("checkpoint.commit-start", path)
      after = database_bytes(path)
      assert_equal "new", result.fetch("classification")
      assert_equal before, after
    end
  end

  def test_unknown_arguments_paths_and_database_files_fail_without_disclosure
    stdout, stderr, status = raw_oracle("scenario.unknown", "/secret/path")
    assert_equal 64, status.exitstatus
    assert_equal "", stdout
    assert_equal "invalid arguments\n", stderr
    refute_includes stderr, "/secret/path"

    Dir.mktmpdir("tamoz-sqlite-oracle-input") do |directory|
      missing = File.join(directory, "missing.db")
      result = oracle("lease.acquire-new", missing)
      assert_invalid(result, "path_invalid")
      refute_includes JSON.generate(result), missing

      random = File.join(directory, "random.db")
      File.binwrite(random, "not sqlite")
      File.chmod(0o600, random)
      assert_invalid(
        oracle("lease.acquire-new", random),
        "database_invalid"
      )

      oversized = File.join(directory, "oversized.db")
      File.open(oversized, "wb", 0o600) do |file|
        file.truncate((256 * 1024 * 1024) + 1)
      end
      assert_invalid(
        oracle("lease.acquire-new", oversized),
        "database_too_large"
      )

      combined = File.join(directory, "combined.db")
      trace_scenario("lease.acquire-new", combined)
      File.open("#{combined}-wal", "wb", 0o600) do |file|
        file.truncate((256 * 1024 * 1024) - File.size(combined) + 1)
      end
      assert_invalid(
        oracle("lease.acquire-new", combined),
        "database_too_large"
      )

      valid = File.join(directory, "valid.db")
      trace_scenario("lease.acquire-new", valid)
      File.chmod(0o644, valid)
      assert_invalid(
        oracle("lease.acquire-new", valid),
        "path_invalid"
      )
      File.chmod(0o600, valid)

      symlink = File.join(directory, "link.db")
      File.symlink(valid, symlink)
      assert_invalid(
        oracle("lease.acquire-new", symlink),
        "path_invalid"
      )
    end
  end

  private

  def scenarios
    scenario_registry.document.fetch("scenarios")
  end

  def scenario_registry
    @scenario_registry ||= registry_class.build
  end

  def driver
    @driver ||= driver_class.new(
      scenario_registry:,
      boundary_registry:
    )
  end

  def registry_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioRegistry, false)
  end

  def driver_class
    Tamoz::Evals::Harness.const_get(:SQLiteScenarioDriver, false)
  end

  def selector_control
    Tamoz::Evals::Harness.const_get(:SQLiteSelectorControl, false)
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

  def trace_scenario(scenario_id, path)
    driver.trace(scenario_id:, path:, subject:)
  end

  def abort_before_subject(scenario_id, path)
    observer = lambda do |point, _metadata|
      raise "fixed pre-action abort" if point.to_s == "before_begin"
    end
    assert_raises(Tamoz::Evals::ExecutionError) do
      driver.run(scenario_id:, path:, observer:)
    end
  end

  def oracle(scenario_id, path)
    stdout, stderr, status = raw_oracle(scenario_id, path)
    assert_equal "", stderr
    assert_equal 1, stdout.lines.length
    JSON.parse(stdout).merge("_exit_status" => status.exitstatus)
  end

  def raw_oracle(*arguments)
    clean_environment = ENV.each_key
                           .grep(/\A(?:BUNDLE|BUNDLER|RUBYLIB|RUBYOPT)/)
                           .to_h { |key| [key, nil] }
    Open3.capture3(
      clean_environment,
      RbConfig.ruby,
      ORACLE.to_s,
      *arguments
    )
  end

  def assert_report(result, scenario_id:)
    assert_equal REPORT_FIELDS, result.keys.reject { |key| key == "_exit_status" }
    assert_equal 1, result.fetch("oracle_version")
    assert_equal ORACLE_DIGEST, result.fetch("oracle_digest")
    assert_equal scenario_id, result.fetch("scenario")
    assert_equal [], result.fetch("reason_codes")
    assert_equal "ok", result.fetch("integrity")
    assert_equal "ok", result.fetch("foreign_keys")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, result.fetch("projection_digest"))
    expected = Tamoz::Evals::CanonicalJSON.content_digest(
      result.reject { |key, _value| key == "_exit_status" },
      domain: "eval.sqlite_raw_oracle_report"
    )
    assert_equal expected, result.fetch("content_digest")
  end

  def assert_invalid(result, reason)
    assert_equal "invalid", result.fetch("classification")
    assert_equal [reason], result.fetch("reason_codes")
    assert_equal 3, result.fetch("_exit_status")
    assert_nil result.fetch("projection_digest")
  end

  def mutate(path, foreign_keys: true)
    database = SQLite3::Database.new(path, strict: true)
    database.execute("PRAGMA foreign_keys = #{foreign_keys ? "ON" : "OFF"}")
    yield database
  ensure
    database&.close
  end

  def wire_digest(bytes, domain:)
    prefix = "#{domain}\0v1\0".b
    "sha256:#{Digest::SHA256.hexdigest(prefix + bytes.b)}"
  end

  def database_bytes(path)
    [path, "#{path}-wal", "#{path}-shm"].to_h do |candidate|
      [File.basename(candidate), File.exist?(candidate) ? File.binread(candidate) : nil]
    end
  end

  def kill_scenario!(directory:, name:, scenario_id:, selector:, path:)
    layout = selector_control.prepare!(
      root: directory,
      name:,
      filesystem_anchor: directory
    )
    scenario_reference = scenario_registry.reference(scenario_id)
    intervention = selector_control.intervention(
      layout:,
      scenario: scenario_reference,
      selector:,
      registry: boundary_registry
    )
    result = subprocess_runner.capture(
      scenario_child_command(
        layout:,
        scenario_id:,
        scenario_reference:,
        selector:,
        database_path: path
      ),
      timeout_ms: 3_000,
      command: "test.sqlite-oracle.#{scenario_id}.#{selector.fetch("point")}",
      intervention:
    )
    assert intervention.verify_result!(result)
  end

  def subprocess_runner
    Tamoz::Evals::Harness::SubprocessRunner.new(
      root: ROOT,
      environment: {},
      output_limit_bytes: 4_096,
      termination_grace_ms: 200
    )
  end

  def scenario_child_command(
    layout:,
    scenario_id:,
    scenario_reference:,
    selector:,
    database_path:
  )
    load_paths = %w[tamoz-core tamoz-graph tamoz-evals tamoz-sqlite].flat_map do |name|
      ["-I", GEM_ROOTS.fetch(name).join("lib").to_s]
    end
    descriptor = layout.descriptor
    script = <<~RUBY
      require "tamoz/evals"
      require "tamoz/sqlite"
      harness = Tamoz::Evals::Harness
      control = harness.const_get(:SQLiteSelectorControl, false)
      registry = Tamoz::SQLite.const_get(:BoundaryRegistry, false)
      scenarios = harness.const_get(:SQLiteScenarioRegistry, false).build
      driver = harness.const_get(:SQLiteScenarioDriver, false).new(
        scenario_registry: scenarios,
        boundary_registry: registry
      )
      layout = control.attach!(
        directory: #{descriptor.fetch("directory").inspect},
        device: #{descriptor.fetch("device")},
        inode: #{descriptor.fetch("inode")}
      )
      stopper = control.stopper(
        layout: layout,
        scenario: #{scenario_reference.inspect},
        selector: #{selector.inspect},
        registry: registry
      )
      driver.run(
        scenario_id: #{scenario_id.inspect},
        path: #{database_path.inspect},
        observer: stopper
      )
      abort "SQLite oracle selector returned"
    RUBY
    [RbConfig.ruby, *load_paths, "-e", script]
  end
end

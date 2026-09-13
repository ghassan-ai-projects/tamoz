# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class SQLiteSelectorControlTest < Minitest::Test
  CONTROL = Tamoz::Evals::Harness.const_get(:SQLiteSelectorControl, false)
  REGISTRY = Tamoz::SQLite.const_get(:BoundaryRegistry, false)

  CHILD_TIMEOUT_MS = 30_000

  # The runner clears everything it is not given, and the child requires the
  # gems. CI installs them into vendor/bundle, reachable only through these.
  CHILD_ENV = ENV.slice(
    "BUNDLE_APP_CONFIG", "BUNDLE_GEMFILE", "BUNDLE_PATH", "GEM_HOME", "GEM_PATH",
    "HOME", "PATH", "RUBYOPT"
  ).freeze

  def test_control_protocol_definition_is_immutable_and_digest_pinned
    assert_equal(
      "sha256:9ced1a4a060c6d5de21f523b9594747c8a4017e482ab7b8086de412218d098f1",
      CONTROL.digest
    )
    assert CONTROL.definition.frozen?
    assert CONTROL.definition.fetch("limits").frozen?
    assert_equal(
      "wuntraced-exact-sigstop-stable-read-post-kill-reread",
      CONTROL.definition.fetch("parent_policy")
    )
  end

  def test_prepares_and_reattaches_private_same_filesystem_layout
    Dir.mktmpdir("tamoz-control-root") do |root|
      layout = CONTROL.prepare!(
        root:,
        name: "selector.1",
        filesystem_anchor: root
      )
      stat = File.lstat(layout.directory)

      assert stat.directory?
      assert_equal 0o700, stat.mode & 0o7777
      assert_equal Process.euid, stat.uid
      assert_equal File.stat(root).dev, stat.dev
      refute File.exist?(layout.path)
      assert layout.frozen?
      assert layout.descriptor.frozen?

      attached = CONTROL.attach!(
        directory: layout.directory,
        device: layout.device,
        inode: layout.inode
      )
      assert_equal layout, attached
    end
  end

  def test_layout_rejects_a_different_filesystem_anchor_when_available
    Dir.mktmpdir("tamoz-control-root") do |root|
      anchor = "/dev/null"
      next if File.stat(root).dev == File.stat(anchor).dev

      error = assert_raises(Tamoz::Evals::ExecutionError) do
        CONTROL.prepare!(
          root:,
          name: "selector.1",
          filesystem_anchor: anchor
        )
      end
      assert_includes error.message, "share a filesystem"
    end
  end

  def test_layout_rejects_preexisting_nonprivate_and_symlink_directories
    Dir.mktmpdir("tamoz-control-root") do |root|
      CONTROL.prepare!(
        root:,
        name: "selector.1",
        filesystem_anchor: root
      )
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        CONTROL.prepare!(
          root:,
          name: "selector.1",
          filesystem_anchor: root
        )
      end
      assert_includes error.message, "must not pre-exist"

      File.chmod(0o755, root)
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        CONTROL.prepare!(
          root:,
          name: "selector.2",
          filesystem_anchor: root
        )
      end
      assert_includes error.message, "private 0700"
      File.chmod(0o700, root)

      symlink = File.join(
        File.dirname(root),
        "#{File.basename(root)}-link"
      )
      File.symlink(root, symlink)
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        CONTROL.prepare!(
          root: symlink,
          name: "selector.3",
          filesystem_anchor: root
        )
      end
      assert_includes error.message, "must not be a symlink"
    ensure
      File.unlink(symlink) if symlink && File.symlink?(symlink)
    end
  end

  def test_writer_uses_exclusive_mode_and_fsyncs_file_and_directory
    with_control do |layout, scenario, selector|
      stopper = CONTROL.stopper(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      events = []
      trace = TracePoint.new(:c_call) do |point|
        next unless %i[flush fsync].include?(point.method_id)
        next unless point.self.respond_to?(:path)

        path = point.self.path
        if path == layout.path || path == layout.directory
          events << [point.method_id, path]
        end
      end

      trace.enable do
        stopper.send(:write_control!)
      end

      stat = File.lstat(layout.path)
      assert stat.file?
      assert_equal 0o600, stat.mode & 0o7777
      assert_equal 1, stat.nlink
      assert_equal(
        [
          [:flush, layout.path],
          [:fsync, layout.path],
          [:fsync, layout.directory]
        ],
        events
      )

      error = assert_raises(Tamoz::Evals::ExecutionError) do
        stopper.send(:write_control!)
      end
      assert_includes error.message, "already exists"
    end
  end

  def test_parent_observes_exact_child_stop_validates_control_and_alone_kills
    with_control do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      result = build_runner.capture(
        child_command(layout, scenario, selector),
        timeout_ms: CHILD_TIMEOUT_MS,
        command: "test.selector-control",
        intervention:
      )

      assert_equal "", result.stderr.text, "the child failed before its stop point"
      assert intervention.verify_result!(result)
      assert_equal "kill", result.termination
      assert_equal "intervention", result.termination_reason
      assert_equal "KILL", result.term_signal
      refute result.timed_out
      assert_nil result.exit_status

      record = read_json(layout.path)
      assert_equal 1, record.fetch("control_version")
      assert_equal CONTROL.digest, record.fetch("control_digest")
      assert_equal scenario, record.fetch("scenario")
      assert_equal selector, record.fetch("selector")
      assert_equal REGISTRY.digest, record.dig("registry", "digest")
      assert_equal "before_begin", record.dig("observed_hook", "point")
      assert_equal(
        %w[
          content_digest control_digest control_version observed_hook registry
          scenario selector
        ],
        record.keys.sort
      )
      refute record.keys.any? { |key| key.match?(/pid|path|owner/) }
    end
  end

  def test_child_stops_only_at_the_exact_validated_occurrence
    with_control(name: "occurrence") do |layout, scenario, selector|
      selected = selector.merge("occurrence" => 2).then do |value|
        selector_with_digest(value)
      end
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector: selected,
        registry: REGISTRY
      )
      result = build_runner.capture(
        child_command(layout, scenario, selected, calls: 2),
        timeout_ms: CHILD_TIMEOUT_MS,
        command: "test.selector-occurrence",
        intervention:
      )

      assert intervention.verify_result!(result)
      record = read_json(layout.path)
      assert_equal 2, record.dig("observed_hook", "occurrence")
      assert_equal selected.fetch("selector_digest"),
                   record.dig("selector", "selector_digest")
    end
  end

  def test_selector_not_reached_and_missing_control_cannot_attest
    with_control do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      result = build_runner.capture(
        [RbConfig.ruby, "-e", "exit 0"],
        timeout_ms: 1_000,
        command: "test.selector-early-exit",
        intervention:
      )

      assert result.success?
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        intervention.verify_result!(result)
      end
      assert_includes error.message, "was not authorized"
    end

    with_control do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      result = build_runner(termination_grace_ms: 50).capture(
        [RbConfig.ruby, "-e", 'Process.kill("STOP", Process.pid)'],
        timeout_ms: 75,
        command: "test.selector-missing-control",
        intervention:
      )

      assert result.timed_out
      assert_equal "timeout", result.termination_reason
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        intervention.verify_result!(result)
      end
      assert_includes error.message, "was not authorized"
    end
  end

  def test_wrong_stop_signal_fails_before_reading_control
    with_control do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )

      error = assert_raises(Tamoz::Evals::ExecutionError) do
        intervention.poll(stop_signal: "TSTP", remaining_ms: 100)
      end
      assert_includes error.message, "unexpected signal"
      refute File.exist?(layout.path)
    end
  end

  def test_intervention_rejects_preexisting_symlink_hardlink_mode_and_size
    treatments = {
      "preexisting" => lambda do |layout, expectation|
        write_raw(layout.path, expectation.bytes)
      end,
      "symlink" => lambda do |layout, expectation|
        target = File.join(File.dirname(layout.directory), "malicious-control.json")
        write_raw(target, expectation.bytes)
        File.symlink(target, layout.path)
      end,
      "hardlink" => lambda do |layout, expectation|
        target = File.join(File.dirname(layout.directory), "linked-control.json")
        write_raw(target, expectation.bytes)
        File.link(target, layout.path)
      end,
      "mode" => lambda do |layout, expectation|
        write_raw(layout.path, expectation.bytes)
        File.chmod(0o644, layout.path)
      end,
      "oversized" => lambda do |layout, _expectation|
        write_raw(layout.path, "x" * (CONTROL::MAX_CONTROL_BYTES + 1))
      end
    }

    treatments.each do |name, treatment|
      with_control(name:) do |layout, scenario, selector|
        expectation = expectation(scenario, selector)
        if name == "preexisting"
          treatment.call(layout, expectation)
          error = assert_raises(Tamoz::Evals::ExecutionError) do
            CONTROL.intervention(
              layout:,
              scenario:,
              selector:,
              registry: REGISTRY
            )
          end
          assert_includes error.message, "must be absent"
          next
        end

        intervention = CONTROL.intervention(
          layout:,
          scenario:,
          selector:,
          registry: REGISTRY
        )
        treatment.call(layout, expectation)
        assert_raises(Tamoz::Evals::ExecutionError, name) do
          intervention.poll(stop_signal: "STOP", remaining_ms: 100)
        end
      end
    end
  end

  def test_intervention_rejects_duplicate_noncanonical_mismatched_and_invalid_utf8
    treatments = %w[
      duplicate noncanonical hook-mismatch scenario-mismatch registry-mismatch
      selector-mismatch unknown-field invalid-utf8
    ]

    treatments.each do |name|
      with_control(name:) do |layout, scenario, selector|
        intervention = CONTROL.intervention(
          layout:,
          scenario:,
          selector:,
          registry: REGISTRY
        )
        expected = expectation(scenario, selector)
        bytes = case name
                when "duplicate"
                  "{\"control_version\":1,\"control_version\":1}\n"
                when "noncanonical"
                  " #{expected.bytes}"
                when "hook-mismatch"
                  record = JSON.parse(expected.bytes)
                  record.fetch("observed_hook")["occurrence"] = 2
                  canonical_record(record)
                when "scenario-mismatch"
                  record = JSON.parse(expected.bytes)
                  record.fetch("scenario")["digest"] = sha("wrong-scenario")
                  canonical_record(record)
                when "registry-mismatch"
                  record = JSON.parse(expected.bytes)
                  record.fetch("registry")["digest"] = sha("wrong-registry")
                  canonical_record(record)
                when "selector-mismatch"
                  record = JSON.parse(expected.bytes)
                  record.fetch("selector")["selector_digest"] = sha("wrong-selector")
                  canonical_record(record)
                when "unknown-field"
                  record = JSON.parse(expected.bytes)
                  record["unexpected"] = true
                  canonical_record(record)
                when "invalid-utf8"
                  "\xFF".b
                else
                  raise "unknown treatment"
                end
        write_raw(layout.path, bytes)

        assert_raises(Tamoz::Evals::ExecutionError, name) do
          intervention.poll(stop_signal: "STOP", remaining_ms: 100)
        end
      end
    end
  end

  def test_intervention_detects_control_mutation_during_read
    with_control do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      write_raw(layout.path, expectation(scenario, selector).bytes)
      mutated = false
      trace = nil
      trace = TracePoint.new(:c_return) do |point|
        next unless point.method_id == :read
        next unless point.self.respond_to?(:path)
        next unless point.self.path == layout.path
        next if mutated

        trace.disable
        mutated = true
        File.open(layout.path, File::WRONLY | File::APPEND) do |file|
          file.write(" ")
          file.flush
        end
      end

      error = trace.enable do
        assert_raises(Tamoz::Evals::ExecutionError) do
          intervention.poll(stop_signal: "STOP", remaining_ms: 100)
        end
      end
      assert_includes error.message, "changed while it was read"
      assert mutated
    ensure
      trace&.disable
    end
  end

  def test_result_attestation_rereads_control_and_rejects_replacement_or_wrong_kill
    with_control do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      bytes = expectation(scenario, selector).bytes
      write_raw(layout.path, bytes)
      assert_equal(
        "kill",
        intervention.poll(stop_signal: "STOP", remaining_ms: 100)
      )

      File.unlink(layout.path)
      write_raw(layout.path, bytes)
      File.utime(Time.at(1), Time.at(1), layout.path)
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        intervention.verify_result!(intentional_result)
      end
      assert_includes error.message, "changed after kill authorization"
    end

    with_control(name: "wrong-result") do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      write_raw(layout.path, expectation(scenario, selector).bytes)
      assert_equal(
        "kill",
        intervention.poll(stop_signal: "STOP", remaining_ms: 100)
      )
      wrong = process_result(
        termination: "term",
        termination_reason: "timeout",
        term_signal: "TERM",
        timed_out: true
      )

      error = assert_raises(Tamoz::Evals::ExecutionError) do
        intervention.verify_result!(wrong)
      end
      assert_includes error.message, "not an intentional SIGKILL"
    end
  end

  def test_intervention_rejects_changed_or_replaced_private_directory
    with_control do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      File.chmod(0o755, layout.directory)

      error = assert_raises(Tamoz::Evals::ExecutionError) do
        intervention.poll(stop_signal: "STOP", remaining_ms: 100)
      end
      assert_includes error.message, "private 0700"
    end

    with_control(name: "replaced") do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry: REGISTRY
      )
      original = "#{layout.directory}.original"
      File.rename(layout.directory, original)
      Dir.mkdir(layout.directory, 0o700)

      error = assert_raises(Tamoz::Evals::ExecutionError) do
        intervention.poll(stop_signal: "STOP", remaining_ms: 100)
      end
      assert_includes error.message, "identity changed"
    end
  end

  def test_control_requires_a_deeply_immutable_registry_document
    mutable_document = {
      "registry_version" => 1,
      "operations" => []
    }
    registry = Object.new
    registry.define_singleton_method(:document) { mutable_document }
    registry.define_singleton_method(:digest) { REGISTRY.digest }
    registry.define_singleton_method(:operation) { |name| REGISTRY.operation(name) }
    registry.define_singleton_method(:validate_hook!) do |point, metadata|
      REGISTRY.validate_hook!(point, metadata)
    end

    with_control do |layout, scenario, selector|
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        CONTROL.intervention(
          layout:,
          scenario:,
          selector:,
          registry:
        )
      end
      assert_includes error.message, "deeply frozen"
    end
  end

  def test_registry_reference_cannot_change_after_intervention_construction
    current_digest = [REGISTRY.digest]
    registry = Object.new
    registry.define_singleton_method(:document) { REGISTRY.document }
    registry.define_singleton_method(:digest) { current_digest.fetch(0) }
    registry.define_singleton_method(:operation) { |name| REGISTRY.operation(name) }
    registry.define_singleton_method(:validate_hook!) do |point, metadata|
      REGISTRY.validate_hook!(point, metadata)
    end

    with_control do |layout, scenario, selector|
      intervention = CONTROL.intervention(
        layout:,
        scenario:,
        selector:,
        registry:
      )
      current_digest[0] = sha("changed-registry")

      error = assert_raises(Tamoz::Evals::ExecutionError) do
        intervention.poll(stop_signal: "STOP", remaining_ms: 100)
      end
      assert_includes error.message, "registry changed"
    end
  end

  def test_stopper_rejects_process_identity_mismatch
    with_control do |layout, scenario, selector|
      stopper = CONTROL.stopper(
        layout:,
        scenario:,
        selector: selector.merge("occurrence" => 2).then do |value|
          selector_with_digest(value)
        end,
        registry: REGISTRY
      )
      stopper.instance_variable_set(:@owner_process, Process.pid + 1)
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        stopper.call("before_begin", frozen_hook_metadata)
      end

      assert_includes error.message, "constructed after child process start"
      refute File.exist?(layout.path)
    end
  end

  def test_stopper_rejects_mutable_wrong_thread_unexpected_operation_and_miss
    with_control do |layout, scenario, selector|
      stopper = CONTROL.stopper(
        layout:,
        scenario:,
        selector: selector.merge("occurrence" => 2).then do |value|
          selector_with_digest(value)
        end,
        registry: REGISTRY
      )
      mutable = hook_metadata
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        stopper.call("before_begin", mutable)
      end
      assert_includes error.message, "deeply frozen"
    end

    with_control(name: "thread") do |layout, scenario, selector|
      stopper = CONTROL.stopper(
        layout:,
        scenario:,
        selector: selector.merge("occurrence" => 2).then do |value|
          selector_with_digest(value)
        end,
        registry: REGISTRY
      )
      error = Thread.new do
        begin
          stopper.call("before_begin", frozen_hook_metadata)
        rescue StandardError => raised
          raised
        end
      end.value
      assert_instance_of Tamoz::Evals::ExecutionError, error
      assert_includes error.message, "owner thread"
    end

    with_control(name: "operation") do |layout, scenario, selector|
      stopper = CONTROL.stopper(
        layout:,
        scenario:,
        selector: selector.merge("occurrence" => 2).then do |value|
          selector_with_digest(value)
        end,
        registry: REGISTRY
      )
      metadata = frozen_hook_metadata("operation" => "lease.renew")
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        stopper.call("before_begin", metadata)
      end
      assert_includes error.message, "unexpected operation"
    end

    with_control(name: "miss") do |layout, scenario, selector|
      stopper = CONTROL.stopper(
        layout:,
        scenario:,
        selector: selector.merge("occurrence" => 2).then do |value|
          selector_with_digest(value)
        end,
        registry: REGISTRY
      )
      stopper.call("before_begin", frozen_hook_metadata)
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        stopper.finish!
      end
      assert_includes error.message, "was not reached"
      refute File.exist?(layout.path)
    end
  end

  def test_invalid_selector_digest_and_non_kill_required_operation_fail_before_spawn
    with_control do |layout, scenario, selector|
      invalid = selector.merge("selector_digest" => sha("invalid"))
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        CONTROL.intervention(
          layout:,
          scenario:,
          selector: invalid,
          registry: REGISTRY
        )
      end
      assert_includes error.message, "selector digest"

      accessor = selector.merge(
        "operation" => "checkpoint.latest",
        "statement" => nil
      )
      accessor = selector_with_digest(accessor)
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        CONTROL.intervention(
          layout:,
          scenario:,
          selector: accessor,
          registry: REGISTRY
        )
      end
      assert_includes error.message, "not Phase 2 kill-required"
    end
  end

  private

  def with_control(name: "selector")
    Dir.mktmpdir("tamoz-selector-control") do |root|
      layout = CONTROL.prepare!(
        root:,
        name:,
        filesystem_anchor: root
      )
      scenario = {
        "id" => "lease.release",
        "version" => 1,
        "digest" => sha("scenario")
      }
      selector = selector_with_digest(
        {
          "scenario" => scenario.fetch("id"),
          "point" => "before_begin",
          "operation" => "lease.release",
          "statement" => nil,
          "attempt_class" => "first",
          "occurrence" => 1,
          "iteration_class" => "single"
        }
      )
      yield layout, scenario, selector
    end
  end

  def selector_with_digest(value)
    body = value.reject { |key, _entry| key == "selector_digest" }
    body.merge(
      "selector_digest" => Tamoz::Evals::CanonicalJSON.content_digest(
        body,
        domain: "eval.sqlite_selector"
      )
    )
  end

  def expectation(scenario, selector)
    CONTROL.send(
      :build_expectation,
      scenario:,
      selector:,
      registry: REGISTRY
    )
  end

  def hook_metadata(overrides = {})
    {
      "hook_version" => 1,
      "kind" => "transaction",
      "operation" => "lease.release",
      "statement" => nil,
      "attempt" => 1
    }.merge(overrides)
  end

  def frozen_hook_metadata(overrides = {})
    Tamoz::Evals::DeepFreeze.call(hook_metadata(overrides))
  end

  def child_command(layout, scenario, selector, calls: 1)
    descriptor = layout.descriptor
    script = <<~RUBY
      require "tamoz/evals/runner"
      require "tamoz/sqlite"
      control = Tamoz::Evals::Harness.const_get(:SQLiteSelectorControl, false)
      registry = Tamoz::SQLite.const_get(:BoundaryRegistry, false)
      layout = control.attach!(
        directory: #{descriptor.fetch("directory").inspect},
        device: #{descriptor.fetch("device")},
        inode: #{descriptor.fetch("inode")}
      )
      stopper = control.stopper(
        layout: layout,
        scenario: #{scenario.inspect},
        selector: #{selector.inspect},
        registry: registry
      )
      metadata = Tamoz::Evals::DeepFreeze.call(#{hook_metadata.inspect})
      #{calls}.times { stopper.call("before_begin", metadata) }
      abort "selector stopper returned"
    RUBY
    [RbConfig.ruby, *SUBPROCESS_LIB_ARGS, "-e", script]
  end

  def build_runner(termination_grace_ms: 200)
    Tamoz::Evals::Harness::SubprocessRunner.new(
      root: ROOT,
      environment: CHILD_ENV,
      output_limit_bytes: 4_096,
      termination_grace_ms:
    )
  end

  def write_raw(path, bytes)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(bytes)
    end
  end

  def canonical_record(record)
    record["content_digest"] = Tamoz::Evals::CanonicalJSON.content_digest(
      record,
      domain: "eval.sqlite_selector_control"
    )
    "#{Tamoz::Evals::CanonicalJSON.dump(record)}\n"
  end

  def intentional_result
    process_result(
      termination: "kill",
      termination_reason: "intervention",
      term_signal: "KILL",
      timed_out: false
    )
  end

  def process_result(termination:, termination_reason:, term_signal:, timed_out:)
    empty = Tamoz::Evals::Harness::SubprocessRunner::Stream.new(
      text: "".freeze,
      bytes: 0,
      captured_bytes: 0,
      truncated: false,
      digest: sha("")
    ).freeze
    Tamoz::Evals::Harness::SubprocessRunner::Result.new(
      command: "test.result",
      exit_status: nil,
      term_signal:,
      timed_out:,
      termination:,
      termination_reason:,
      duration_ms: 1,
      stdout: empty,
      stderr: empty
    ).freeze
  end

  def sha(value)
    "sha256:#{Digest::SHA256.hexdigest(value)}"
  end
end

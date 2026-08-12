# frozen_string_literal: true

require_relative "test_helper"

class SQLiteTraceRecorderTest < Minitest::Test
  RECORDER_DIGEST =
    "sha256:ebf5a908b273654e63a35bd1ba98c06a57b0ee41cb88e14f4b843983c8153a47"
  # The recorder is constructed WITH the boundary registry, so this manifest
  # digest moves whenever the registry does. It moved here because the
  # early-turn deferral renamed the claim scan (`request.claim.candidates`
  # replaces `request.claim.next`) and the claim operation's fenced
  # `request.terminal_fail` WRITE was registered;
  # the lease.release trace itself — its events, selectors and ordering, all
  # asserted below — is unchanged.
  LEASE_RELEASE_MANIFEST_DIGEST =
    "sha256:0c45c19f0a11d5eb687e6ec99e36d4b5fbcab4ca24e81b8d93d2c1df4ded5da0"
  EVENT_FIELDS = %w[
    sequence scenario point hook_version kind operation statement attempt
    occurrence
  ].freeze
  SELECTOR_FIELDS = %w[
    scenario point operation statement attempt_class occurrence
    iteration_class selector_digest
  ].freeze

  def test_real_lease_trace_is_complete_deterministic_and_deeply_frozen
    recorder = build_recorder(operation: "lease.release")
    manifest = nil

    Dir.mktmpdir("tamoz-sqlite-trace") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db"),
        fault_injector: recorder
      )
      lease = adapter.__send__(
        :acquire_lease,
        thread_id: "thread.trace",
        namespace: wire.namespace([]),
        owner_id: "owner.trace",
        ttl: adapter.limits.lease_ttl
      )

      recorder.arm!
      assert adapter.__send__(:release_lease, lease)
      manifest = recorder.finish
      adapter.close
    end

    assert_equal RECORDER_DIGEST, recorder_class.digest
    assert_equal(
      LEASE_RELEASE_MANIFEST_DIGEST,
      manifest.fetch("content_digest")
    )
    assert_equal 10, manifest.fetch("events").length
    assert_equal 10, manifest.fetch("selectors").length
    assert_equal(
      (1..10).to_a,
      manifest.fetch("events").map { |event| event.fetch("sequence") }
    )
    assert_equal "before_begin", manifest.fetch("events").first.fetch("point")
    assert_equal "after_commit", manifest.fetch("events").last.fetch("point")
    manifest.fetch("events").each do |event|
      assert_equal EVENT_FIELDS, event.keys
      assert_equal "scenario.lease-release", event.fetch("scenario")
      assert_equal "lease.release", event.fetch("operation")
      assert_equal 1, event.fetch("attempt")
    end
    manifest.fetch("selectors").each do |selector|
      assert_equal SELECTOR_FIELDS, selector.keys
      assert_equal "first", selector.fetch("attempt_class")
      assert_equal "single", selector.fetch("iteration_class")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, selector.fetch("selector_digest"))
    end
    assert_equal(
      manifest.fetch("selectors")
              .map { |selector| selector.fetch("selector_digest") }
              .sort,
      manifest.fetch("selectors")
              .map { |selector| selector.fetch("selector_digest") }
    )
    assert_equal(
      manifest.fetch("content_digest"),
      Tamoz::Evals::CanonicalJSON.content_digest(
        manifest,
        domain: "eval.sqlite_trace_manifest"
      )
    )
    assert_deeply_frozen(manifest)
    assert_same manifest, recorder.finish
  end

  def test_dynamic_iterations_collapse_to_first_lower_middle_and_final
    recorder = build_recorder(operation: "checkpoint.append_writes")
    recorder.arm!
    record_transaction(
      recorder,
      "checkpoint.append_writes",
      %w[
        checkpoint.writes.item.0
        checkpoint.writes.item.1
        checkpoint.writes.item.2
        checkpoint.writes.item.3
      ]
    )
    manifest = recorder.finish

    after_items = manifest.fetch("selectors").select do |selector|
      selector.fetch("point") == "after_sql" &&
        selector.fetch("statement")&.start_with?("checkpoint.writes.item.")
    end.sort_by { |selector| selector.fetch("iteration_class") }
    by_class = after_items.to_h do |selector|
      [
        selector.fetch("iteration_class"),
        selector.fetch("statement")
      ]
    end
    assert_equal(
      {
        "first" => "checkpoint.writes.item.0",
        "middle" => "checkpoint.writes.item.1",
        "final" => "checkpoint.writes.item.3"
      },
      by_class
    )
    refute(manifest.fetch("selectors").any? do |selector|
      selector.fetch("statement") == "checkpoint.writes.item.2"
    end)
    assert manifest.fetch("events").all? do |event|
      event.fetch("occurrence") == 1
    end
    assert_equal 12, manifest.fetch("events").length
    assert_equal 10, manifest.fetch("selectors").length
  end

  def test_manifest_is_reproducible_and_binds_subject_and_scenario
    first = complete_manifest(operation: "lease.release")
    second = complete_manifest(operation: "lease.release")
    assert_equal first, second

    dirty = complete_manifest(
      operation: "lease.release",
      subject: subject.merge("dirty" => true)
    )
    refute_equal first.fetch("subject").fetch("digest"),
                 dirty.fetch("subject").fetch("digest")
    refute_equal first.fetch("content_digest"), dirty.fetch("content_digest")

    changed_scenario = complete_manifest(
      operation: "lease.release",
      scenario: scenario("scenario.changed")
    )
    refute_equal first.fetch("content_digest"),
                 changed_scenario.fetch("content_digest")
  end

  def test_independent_manifest_replay_rejects_tampering
    manifest = complete_manifest(operation: "lease.release")
    parsed = JSON.parse(Tamoz::Evals::CanonicalJSON.dump(manifest))
    verified = recorder_class.verify_manifest!(
      parsed,
      registry: boundary_registry
    )
    assert_equal manifest, verified
    assert_deeply_frozen(verified)

    treatments = []
    treatments << mutable_copy(manifest).tap do |document|
      document["content_digest"] = "sha256:#{"0" * 64}"
    end
    treatments << redigest(mutable_copy(manifest).tap do |document|
      document.fetch("events").fetch(0)["occurrence"] = 2
    end)
    treatments << redigest(mutable_copy(manifest).tap do |document|
      document.fetch("selectors").pop
    end)
    treatments << redigest(mutable_copy(manifest).tap do |document|
      document.fetch("recorder")["digest"] = "sha256:#{"0" * 64}"
    end)
    treatments << redigest(mutable_copy(manifest).tap do |document|
      document.fetch("registry")["digest"] = "sha256:#{"0" * 64}"
    end)
    treatments << mutable_copy(manifest).tap do |document|
      document["extra"] = true
    end
    treatments << redigest(mutable_copy(manifest).tap do |document|
      event = document.fetch("events").fetch(0)
      document["events"] = Array.new(257) { event.dup }
    end)
    treatments << redigest(mutable_copy(manifest).tap do |document|
      document.fetch("events").fetch(0)["statement"] = []
    end)
    treatments << redigest(mutable_copy(manifest).tap do |document|
      document.fetch("selectors").fetch(0)["statement"] = "x" * 257
    end)
    treatments << redigest(mutable_copy(manifest).tap do |document|
      document["selectors"] = []
    end)
    treatments << mutable_copy(manifest).tap do |document|
      document.fetch("events").fetch(0)["sequence"] = 1 << 1_000
    end

    treatments.each do |treatment|
      assert_raises(Tamoz::Evals::ExecutionError) do
        recorder_class.verify_manifest!(
          treatment,
          registry: boundary_registry
        )
      end
    end
  end

  def test_disarmed_bootstrap_is_ignored_and_lifecycle_fails_closed
    recorder = build_recorder(operation: "lease.release")
    assert_nil recorder.call(:unknown, {"unversioned" => true})
    recorder.arm!
    error = assert_raises(Tamoz::Evals::ExecutionError) { recorder.arm! }
    assert_match(/only be armed once/, error.message)

    incomplete = build_recorder(operation: "lease.release")
    incomplete.arm!
    incomplete.call(
      :before_begin,
      transaction_hook("lease.release")
    )
    error = assert_raises(Tamoz::Evals::ExecutionError) { incomplete.finish }
    assert_match(/trace is incomplete/, error.message)

    finished = build_recorder(operation: "lease.release")
    finished.arm!
    record_transaction(finished, "lease.release", ["lease.release.time"])
    finished.finish
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      finished.call(:before_begin, transaction_hook("lease.release"))
    end
    assert_match(/not armed/, error.message)
  end

  def test_wrong_thread_second_operation_and_invalid_order_fail
    threaded = build_recorder(operation: "lease.release")
    threaded.arm!
    captured = Queue.new
    Thread.new do
      begin
        threaded.call(:before_begin, transaction_hook("lease.release"))
      rescue StandardError => error
        captured << error
      end
    end.join
    error = captured.pop
    assert_instance_of Tamoz::Evals::ExecutionError, error
    assert_match(/another thread/, error.message)

    second = build_recorder(operation: "lease.release")
    second.arm!
    record_transaction(second, "lease.release", ["lease.release.time"])
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      second.call(:before_begin, transaction_hook("lease.release"))
    end
    assert_match(/second operation/, error.message)

    unordered = build_recorder(operation: "lease.release")
    unordered.arm!
    unordered.call(:before_begin, transaction_hook("lease.release"))
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      unordered.call(
        :before_sql,
        statement_hook("lease.release", "lease.release.time")
      )
    end
    assert_match(/hook order is invalid/, error.message)
  end

  def test_statement_pairs_attempts_operations_and_expansions_are_enforced
    mismatched = build_recorder(operation: "lease.release")
    mismatched.arm!
    mismatched.call(:before_begin, transaction_hook("lease.release"))
    mismatched.call(:after_begin, transaction_hook("lease.release"))
    mismatched.call(
      :before_sql,
      statement_hook("lease.release", "lease.release.time")
    )
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      mismatched.call(
        :after_sql,
        statement_hook("lease.release", "lease.release.row")
      )
    end
    assert_match(/not paired/, error.message)

    retrying = build_recorder(operation: "lease.release")
    retrying.arm!
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      retrying.call(
        :before_begin,
        transaction_hook("lease.release", attempt: 2)
      )
    end
    assert_match(/only the first transaction attempt/, error.message)

    other = build_recorder(operation: "lease.release")
    other.arm!
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      other.call(:before_begin, transaction_hook("lease.acquire"))
    end
    assert_match(/unexpected operation/, error.message)

    repeated = build_recorder(operation: "lease.release")
    repeated.arm!
    repeated.call(:before_begin, transaction_hook("lease.release"))
    repeated.call(:after_begin, transaction_hook("lease.release"))
    2.times do |index|
      repeated.call(
        :before_sql,
        statement_hook("lease.release", "lease.release.time")
      )
      repeated.call(
        :after_sql,
        statement_hook("lease.release", "lease.release.time")
      )
    rescue Tamoz::Evals::ExecutionError => error
      assert_equal 1, index
      assert_match(/registry boundary expansion/, error.message)
      break
    end
  end

  def test_dynamic_indices_are_contiguous_and_trace_requires_sql
    gap = build_recorder(operation: "checkpoint.append_writes")
    gap.arm!
    gap.call(
      :before_begin,
      transaction_hook("checkpoint.append_writes")
    )
    gap.call(
      :after_begin,
      transaction_hook("checkpoint.append_writes")
    )
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      gap.call(
        :before_sql,
        statement_hook(
          "checkpoint.append_writes",
          "checkpoint.writes.item.1"
        )
      )
    end
    assert_match(/indices are not contiguous/, error.message)

    empty = build_recorder(operation: "lease.release")
    empty.arm!
    empty.call(:before_begin, transaction_hook("lease.release"))
    empty.call(:after_begin, transaction_hook("lease.release"))
    empty.call(:before_commit, transaction_hook("lease.release"))
    empty.call(:after_commit, transaction_hook("lease.release"))
    error = assert_raises(Tamoz::Evals::ExecutionError) { empty.finish }
    assert_match(/trace is incomplete/, error.message)
  end

  def test_event_ceiling_rejects_instead_of_truncating
    recorder = build_recorder(operation: "checkpoint.append_writes")
    recorder.arm!
    recorder.call(
      :before_begin,
      transaction_hook("checkpoint.append_writes")
    )
    recorder.call(
      :after_begin,
      transaction_hook("checkpoint.append_writes")
    )
    127.times do |index|
      label = "checkpoint.writes.item.#{index}"
      recorder.call(
        :before_sql,
        statement_hook("checkpoint.append_writes", label)
      )
      recorder.call(
        :after_sql,
        statement_hook("checkpoint.append_writes", label)
      )
    end
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      recorder.call(
        :before_commit,
        transaction_hook("checkpoint.append_writes")
      )
    end
    assert_match(/exceeds 256 events/, error.message)
  end

  def test_manifest_inputs_registry_and_hook_shapes_are_bounded
    bad_scenarios = [
      scenario("scenario.valid").merge("extra" => true),
      scenario("UPPERCASE"),
      scenario("scenario.valid").merge("version" => 0),
      scenario("scenario.valid").merge("digest" => "sha256:short"),
      scenario("scenario.valid").merge("digest" => "\xFF".b)
    ]
    bad_scenarios.each do |candidate|
      assert_raises(Tamoz::Evals::ExecutionError) do
        build_recorder(operation: "lease.release", scenario: candidate)
      end
    end

    bad_subjects = [
      subject.merge("extra" => true),
      subject.merge("git_revision" => "abc"),
      subject.merge("git_tree" => "f" * 39),
      subject.merge("dirty" => nil),
      subject.merge("version" => "\xFF".b)
    ]
    bad_subjects.each do |candidate|
      assert_raises(Tamoz::Evals::ExecutionError) do
        build_recorder(operation: "lease.release", subject: candidate)
      end
    end

    assert_raises(Tamoz::Evals::ExecutionError) do
      build_recorder(operation: "checkpoint.prune")
    end
    assert_raises(Tamoz::Evals::ExecutionError) do
      recorder_class.new(
        scenario: scenario("scenario.invalid-registry"),
        operation: "lease.release",
        subject:,
        registry: Struct.new(:document).new({})
      )
    end

    recorder = build_recorder(operation: "lease.release")
    recorder.arm!
    malformed = transaction_hook("lease.release")
                .merge("sql" => "SECRET")
                .freeze
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      recorder.call(:before_begin, malformed)
    end
    assert_match(/hook metadata shape is invalid/, error.message)

    mutable = transaction_hook("lease.release").dup
    recorder = build_recorder(operation: "lease.release")
    recorder.arm!
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      recorder.call(:before_begin, mutable)
    end
    assert_match(/must be deeply frozen/, error.message)
    refute mutable.frozen?
  end

  def test_recorder_definition_pins_bounds_and_future_attempt_vocabulary
    definition = recorder_class.definition

    assert_equal RECORDER_DIGEST, recorder_class.digest
    assert_equal 256, definition.fetch("limits").fetch("events")
    assert_equal 4_096, definition.fetch("limits").fetch("selectors")
    assert_equal %w[first retry exhausted],
                 definition.fetch("attempt_classes")
    assert_equal %w[single first middle final],
                 definition.fetch("iteration_classes")
    assert_equal "first-only", definition.fetch("phase2_attempt_policy")
    assert_deeply_frozen(definition)
  end

  private

  def complete_manifest(operation:, scenario: nil, subject: nil)
    recorder = build_recorder(
      operation:,
      scenario: scenario || self.scenario("scenario.#{operation.tr(".", "-")}"),
      subject: subject || self.subject
    )
    recorder.arm!
    statement = boundary_registry.operation(operation)
                                 .fetch("statements")
                                 .first
                                 .fetch("template")
                                 .sub("{index}", "0")
    record_transaction(recorder, operation, [statement])
    recorder.finish
  end

  def build_recorder(
    operation:,
    scenario: nil,
    subject: nil
  )
    recorder_class.new(
      scenario: scenario || self.scenario("scenario.#{operation.tr(".", "-")}"),
      operation:,
      subject: subject || self.subject,
      registry: boundary_registry
    )
  end

  def record_transaction(recorder, operation, statements)
    recorder.call(:before_begin, transaction_hook(operation))
    recorder.call(:after_begin, transaction_hook(operation))
    statements.each do |statement|
      recorder.call(:before_sql, statement_hook(operation, statement))
      recorder.call(:after_sql, statement_hook(operation, statement))
    end
    recorder.call(:before_commit, transaction_hook(operation))
    recorder.call(:after_commit, transaction_hook(operation))
  end

  def transaction_hook(operation, attempt: 1)
    {
      "hook_version" => 1,
      "kind" => "transaction",
      "operation" => String(operation).dup.freeze,
      "statement" => nil,
      "attempt" => attempt
    }.freeze
  end

  def statement_hook(operation, statement, attempt: 1)
    {
      "hook_version" => 1,
      "kind" => "statement",
      "operation" => String(operation).dup.freeze,
      "statement" => String(statement).dup.freeze,
      "attempt" => attempt
    }.freeze
  end

  def scenario(id)
    definition = {"id" => id, "version" => 1}
    {
      "id" => id,
      "version" => 1,
      "digest" => Tamoz::Evals::CanonicalJSON.content_digest(
        definition,
        domain: "eval.sqlite_scenario"
      )
    }
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

  def recorder_class
    Tamoz::Evals::Harness.const_get(:SQLiteTraceRecorder, false)
  end

  def boundary_registry
    Tamoz::SQLite.const_get(:BoundaryRegistry, false)
  end

  def wire
    Tamoz::SQLite.const_get(:Wire, false)
  end

  def mutable_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def redigest(document)
    document["content_digest"] = Tamoz::Evals::CanonicalJSON.content_digest(
      document,
      domain: "eval.sqlite_trace_manifest"
    )
    document
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

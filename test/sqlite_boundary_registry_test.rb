# frozen_string_literal: true

require_relative "test_helper"

class SQLiteBoundaryRegistryTest < Minitest::Test
  REGISTRY_DIGEST =
    "sha256:ac6ab030d6d27811c61db6c4e526df8b1520e6e6839d7785bfb573c8a0671cbd"

  def test_registry_is_deeply_frozen_unique_and_digest_stable
    registry = boundary_registry
    document = registry.document

    assert_equal 1, document.fetch("registry_version")
    assert_deeply_frozen(document)
    operations = document.fetch("operations")
    names = operations.map { |entry| entry.fetch("operation") }
    assert_equal names.uniq, names
    assert_equal 20, names.length
    operations.each do |operation|
      templates = operation.fetch("statements").map do |entry|
        entry.fetch("template")
      end
      assert_equal templates.uniq, templates, operation.fetch("operation")
      operation.fetch("statements").each do |statement|
        assert_includes %w[read write], statement.fetch("access")
        assert_operator statement.fetch("max_instances"), :>, 0
      end
    end
    assert_equal REGISTRY_DIGEST, registry.digest
    assert registry.digest.frozen?
  end

  def test_phase_ownership_and_dynamic_statement_bounds_are_explicit
    registry = boundary_registry
    required = registry.phase_operations(phase: 2, kill_required: true)
                       .map { |entry| entry.fetch("operation") }

    assert_equal(
      %w[
        lease.acquire lease.validate lease.renew lease.release
        request.enqueue request.claim request.recover request.redirect_ready
        request.transition checkpoint.append_writes checkpoint.commit
      ].sort,
      required.sort
    )
    prune = registry.operation("checkpoint.prune")
    assert_equal 4, prune.fetch("phase")
    refute prune.fetch("kill_required")

    resolved = registry.resolve_statement(
      "checkpoint.append_writes",
      "checkpoint.writes.item.17"
    )
    assert_equal "checkpoint.writes.item.{index}", resolved.fetch("template")
    assert_equal 17, resolved.fetch("instance")
    assert_nil registry.resolve_statement(
      "checkpoint.append_writes",
      "checkpoint.writes.item.65536"
    )
    assert_nil registry.resolve_statement(
      "checkpoint.append_writes",
      "checkpoint.writes.item.01"
    )
  end

  def test_hook_validation_rejects_shape_version_kind_and_registry_mismatch
    registry = boundary_registry
    valid = {
      "hook_version" => 1,
      "kind" => "statement",
      "operation" => "lease.acquire",
      "statement" => "lease.acquire.update",
      "attempt" => 1
    }.freeze
    assert registry.validate_hook!(:after_sql, valid)

    treatments = [
      valid.merge("hook_version" => 2),
      valid.merge("kind" => "transaction"),
      valid.merge("operation" => "store.compare_and_set"),
      valid.merge("statement" => "lease.acquire.unknown"),
      valid.merge("attempt" => 0),
      valid.merge("extra" => true),
      valid.merge(extra: true)
    ]
    treatments.each do |metadata|
      assert_raises(Tamoz::ConfigurationError) do
        registry.validate_hook!(:after_sql, metadata)
      end
    end
    assert_raises(Tamoz::ConfigurationError) do
      registry.validate_hook!(:unknown, valid)
    end
    assert_nil registry.resolve_statement("lease.acquire", nil)
  end

  def test_runtime_hooks_are_versioned_immutable_and_propagate_attempt
    events = []
    Dir.mktmpdir("tamoz-boundary-hook") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db"),
        fault_injector: lambda do |point, metadata|
          next unless metadata.fetch("operation") == "lease.acquire"

          events << [point, metadata]
        end
      )
      namespace = wire.namespace([])
      lease = adapter.__send__(
        :acquire_lease,
        thread_id: "thread.boundary",
        namespace:,
        owner_id: "owner.boundary",
        ttl: adapter.limits.lease_ttl
      )
      adapter.__send__(:release_lease, lease)
      adapter.close
    end

    refute_empty events
    assert_equal :before_begin, events.first.fetch(0)
    assert_equal :after_commit, events.last.fetch(0)
    events.each do |point, metadata|
      assert_equal(
        %w[attempt hook_version kind operation statement],
        metadata.keys.sort
      )
      assert_equal 1, metadata.fetch("hook_version")
      assert_equal 1, metadata.fetch("attempt")
      assert metadata.frozen?
      assert boundary_registry.validate_hook!(point, metadata)
      if %i[before_sql after_sql].include?(point)
        assert_equal "statement", metadata.fetch("kind")
        refute_nil metadata.fetch("statement")
      else
        assert_equal "transaction", metadata.fetch("kind")
        assert_nil metadata.fetch("statement")
      end
    end
  end

  def test_read_hooks_use_nullable_attempt
    events = []
    Dir.mktmpdir("tamoz-boundary-read") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db"),
        fault_injector: lambda do |point, metadata|
          events << [point, metadata] if
            metadata.fetch("operation") == "integrity.check"
        end
      )
      adapter.integrity_check
      adapter.close
    end

    refute_empty events
    assert events.all? { |_point, metadata| metadata.fetch("attempt").nil? }
    assert(events.all? do |point, metadata|
      %i[before_sql after_sql].include?(point) &&
        metadata.fetch("kind") == "statement"
    end)
  end

  private

  def boundary_registry
    Tamoz::SQLite.const_get(:BoundaryRegistry, false)
  end

  def wire
    Tamoz::SQLite.const_get(:Wire, false)
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

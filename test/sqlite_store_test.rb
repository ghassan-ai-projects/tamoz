# frozen_string_literal: true

require_relative "test_helper"

class SQLiteStoreTest < Minitest::Test
  Protection = Data.define(:name) do
    def encrypt(bytes, context:)
      xor(bytes, context)
    end

    def decrypt(bytes, context:)
      xor(bytes, context)
    end

    private

    def xor(bytes, context)
      key = Digest::SHA256.digest("#{name}\0#{context}")
      bytes.bytes.each_with_index.map { |byte, index| byte ^ key.getbyte(index % key.bytesize) }.pack("C*")
    end
  end

  def test_compare_and_set_versions_and_tombstones
    with_store do |store|
      created = store.put("memory", "alpha", {"count" => 1})
      assert_equal 1, created.version
      assert_equal({"count" => 1}, store.get("memory", "alpha").value)

      assert_raises(Tamoz::StoreConflictError) do
        store.put("memory", "alpha", {"count" => 2})
      end
      updated = store.put(
        "memory",
        "alpha",
        {"count" => 2},
        if_version: created.version
      )
      assert_equal 2, updated.version
      assert_equal 2, updated.value.fetch("count")

      deleted = store.delete("memory", "alpha", if_version: updated.version)
      assert deleted.deleted
      assert_nil deleted.value
      assert_equal 3, deleted.version
      assert store.get("memory", "alpha").deleted
      assert_raises(Tamoz::StoreConflictError) do
        store.delete("memory", "alpha", if_version: updated.version)
      end
    end
  end

  def test_iteration_is_namespace_scoped_prefix_filtered_and_byte_ordered
    with_store do |store|
      store.put("one", "b", 2)
      store.put("one", "aa", 1)
      store.put("one", "ab", 3)
      store.put("two", "aa", 9)

      assert_equal %w[aa ab], store.each("one", prefix: "a", limit: 10).map(&:key)
      assert_equal ["aa"], store.each("one", prefix: "a", limit: 1).map(&:key)
      assert_equal %w[aa ab b], store.each("one", limit: 10).map(&:key)
      assert_equal false, store.searchable?
      assert_raises(Tamoz::StoreCapabilityError) { store.search("anything") }
    end
  end

  def test_sensitive_values_fail_closed_and_round_trip_only_with_protection
    with_store do |store|
      assert_raises(Tamoz::SensitiveValueError) do
        store.put("private", "secret", {"token" => "hidden"}, sensitive: true)
      end
    end

    protection = Protection.new(name: "test.xor")
    with_store(store_protection: protection) do |store, path|
      entry = store.put(
        "private",
        "secret",
        {"token" => "hidden"},
        sensitive: true
      )
      assert entry.sensitive
      assert_equal "hidden", store.get("private", "secret").value.fetch("token")
      refute_includes File.binread(path), "hidden"
    end
  end

  def test_invalid_inputs_and_early_break_do_not_leak_connections
    with_store do |store, _path, adapter|
      assert_raises(Tamoz::ConfigurationError) { store.each("one", limit: 0).to_a }
      assert_raises(Tamoz::ConfigurationError) { store.put("", "key", 1) }
      10.times { store.put("scan", SecureRandom.uuid, true) }

      store.each("scan", limit: 10) { break }
      assert_equal 0, adapter.stats.fetch("checked_out")
    end
  end

  def test_every_store_transaction_fault_reopens_as_old_or_new_complete_state
    hooks = []
    Dir.mktmpdir("tamoz-store-hooks") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "trace.sqlite3"),
        fault_injector: lambda do |point, metadata|
          hooks << [point, metadata.fetch("statement", nil)] if
            metadata.fetch("operation") == "store.compare_and_set"
        end
      )
      adapter.store.put("fault", "key", {"complete" => true})
      adapter.close
    end
    targets = hooks.uniq.select do |point, _statement|
      %i[before_sql after_sql before_commit after_commit].include?(point)
    end
    assert_operator targets.length, :>=, 8

    targets.each_with_index do |target, index|
      Dir.mktmpdir("tamoz-store-fault-#{index}") do |directory|
        path = File.join(directory, "tamoz.sqlite3")
        fired = false
        adapter = Tamoz::SQLite::Adapter.new(
          path:,
          fault_injector: lambda do |point, metadata|
            candidate = [point, metadata.fetch("statement", nil)]
            next if fired || metadata.fetch("operation") != "store.compare_and_set"
            next unless candidate == target

            fired = true
            raise "injected #{target.inspect}"
          end
        )
        assert_raises(RuntimeError) do
          adapter.store.put("fault", "key", {"complete" => true})
        end
        assert fired
        adapter.close

        reopened = Tamoz::SQLite::Adapter.new(path:)
        entry = reopened.store.get("fault", "key")
        assert(
          entry.nil? ||
          (
            entry.version == 1 &&
            entry.value == {"complete" => true} &&
            !entry.deleted
          ),
          "fault #{target.inspect} exposed a partial Store state"
        )
        assert reopened.integrity_check.fetch("ok")
        reopened.close
      end
    end
  end

  # P13-A seam (invariant 38 duplicate-turn hard zero): the enqueue primitive
  # dedups on `(thread_id, namespace, request_id)` — a repeated delivery of the
  # SAME bytes is idempotent (one request row), and the same id with ANY byte
  # difference is refused with CheckpointConflictError. A crash at any seam can
  # repeat delivery; this is what makes "exactly one logical occurrence" durable.
  def test_enqueue_dedup_is_byte_exact_and_same_bytes_are_idempotent
    with_store do |_store, _path, adapter|
      definition = Tamoz.graph(name: "enqueue-dedup", version: "1") do
        state :ready, default: true
        node(:finish, implementation_name: "enqueue-dedup.finish", version: "1") { |_s, _c| {ready: true} }
        edge Tamoz::START, :finish
        edge :finish, Tamoz::END
      end
      app = definition.compile(checkpointer: adapter)
      checkpointer = app.checkpointer
      enqueue = lambda do |id:, operation:, payload:|
        checkpointer.enqueue_request(
          thread_id: "t-1",
          request_id: id,
          operation:,
          payload:
        )
      end

      first = enqueue.call(id: "req.dedup", operation: "turn", payload: {"k" => "v"})
      assert_equal :queued, first.status

      # Same id + same bytes: idempotent, no second row.
      again = enqueue.call(id: "req.dedup", operation: "turn", payload: {"k" => "v"})
      assert_equal :queued, again.status

      # Same id + ANY byte difference: refused (duplicate turn).
      assert_raises(Tamoz::CheckpointConflictError) do
        enqueue.call(id: "req.dedup", operation: "turn", payload: {"k" => "different"})
      end
    end
  end

  private

  def with_store(store_protection: nil)
    Dir.mktmpdir("tamoz-store") do |directory|
      path = File.join(directory, "tamoz.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path:, store_protection:)
      yield adapter.store, path, adapter
    ensure
      adapter&.close
    end
  end
end

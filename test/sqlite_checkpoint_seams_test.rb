# frozen_string_literal: true

require_relative 'test_helper'

# Q2 characterization of the checkpoint_store validation seams
# (gems/tamoz-sqlite/lib/tamoz/sqlite/checkpoint_store.rb). These branches were
# uncovered by the Q0 coverage baseline (90.5% overall): the argument-validation
# failure paths of history / open_writer. Each test is a mutation contract —
# removing its validation must fail the test: bad input raises, it never
# silently clamps or proceeds.
class SQLiteCheckpointSeamsTest < Minitest::Test
  def test_history_rejects_negative_before_sequence
    with_bound_store do |_adapter, store|
      error = assert_raises(Tamoz::ConfigurationError) do
        store.history(thread_id: 'thread.x', before_sequence: -1, limit: 10)
      end

      assert_match(/before_sequence must be a non-negative integer/, error.message)
    end
  end

  def test_history_rejects_non_integer_before_sequence
    with_bound_store do |_adapter, store|
      assert_raises(Tamoz::ConfigurationError) do
        store.history(thread_id: 'thread.x', before_sequence: '10', limit: 10)
      end
    end
  end

  def test_history_rejects_zero_limit
    with_bound_store do |_adapter, store|
      assert_raises(Tamoz::ConfigurationError) do
        store.history(thread_id: 'thread.x', limit: 0)
      end
    end
  end

  def test_history_rejects_non_integer_limit
    with_bound_store do |_adapter, store|
      assert_raises(Tamoz::ConfigurationError) do
        store.history(thread_id: 'thread.x', limit: '10')
      end
    end
  end

  def test_open_writer_rejects_zero_ttl
    with_bound_store do |_adapter, store|
      error = assert_raises(Tamoz::ConfigurationError) do
        store.open_writer(
          thread_id: 'thread.x', namespace: [], owner_id: 'owner.a', ttl: 0.05
        )
      end

      assert_match(/writer ttl must be between/, error.message)
    end
  end

  def test_open_writer_rejects_negative_ttl
    with_bound_store do |_adapter, store|
      assert_raises(Tamoz::ConfigurationError) do
        store.open_writer(
          thread_id: 'thread.x', namespace: [], owner_id: 'owner.a', ttl: -1
        )
      end
    end
  end

  def test_open_writer_accepts_ttl_boundaries
    with_bound_store do |adapter, store|
      store.open_writer(
        thread_id: 'thread.x', namespace: [], owner_id: 'owner.a',
        ttl: adapter.limits.lease_ttl
      ) do |writer|
        assert_predicate writer.fence, :positive?
      end
      store.open_writer(
        thread_id: 'thread.y', namespace: [], owner_id: 'owner.a', ttl: 0.1
      ) do |writer|
        assert_predicate writer.fence, :positive?
      end
    end
  end

  private

  def counter_definition
    Tamoz.graph(name: 'durable-counter-seams', version: '1') do
      state :count, default: 0
      node(
        :increment,
        implementation_name: 'durable.counter.seams.increment',
        version: '1'
      ) { |state, _context| { count: state.fetch(:count) + 1 } }
      edge Tamoz::START, :increment
      edge :increment, Tamoz::END
    end
  end

  def with_bound_store
    Dir.mktmpdir('tamoz-sqlite-seams') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'tamoz.db'))
      store = counter_definition.compile(checkpointer: adapter).checkpointer
      yield adapter, store
      adapter.close
    end
  end
end

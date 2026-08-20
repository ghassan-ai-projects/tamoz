# frozen_string_literal: true

require_relative 'test_helper'

class EffectIdentityTest < Minitest::Test
  def identity(**overrides)
    {
      request_id: 'request-1',
      execution_id: 'execution-1',
      capability_id: 'mcp:server/read',
      arguments: { 'path' => 'README.md', 'limit' => 10 },
      authority_revision: "sha256:#{'a' * 64}",
      catalog_revision: "sha256:#{'b' * 64}",
      iteration: 2,
      sub_operation: 1
    }.merge(overrides)
  end

  def test_logical_identity_is_stable_for_same_checkpointed_operation
    journal = Tamoz::SQLite::EffectJournal.allocate
    first = journal.logical_identity(**identity)
    second = journal.logical_identity(
      **identity(arguments: { 'limit' => 10, 'path' => 'README.md' })
    )

    assert_equal first, second
    assert first.start_with?('logical:')
  end

  def test_iteration_and_sub_operation_are_collision_free
    journal = Tamoz::SQLite::EffectJournal.allocate
    base = journal.logical_identity(**identity)
    next_iteration = journal.logical_identity(**identity(iteration: 3))
    next_operation = journal.logical_identity(**identity(sub_operation: 2))

    refute_equal base, next_iteration
    refute_equal base, next_operation
    refute_equal next_iteration, next_operation
  end

  def test_attempt_identity_is_derived_from_logical_identity_without_replacing_it
    journal = Tamoz::SQLite::EffectJournal.allocate
    logical = journal.logical_identity(**identity)

    assert_equal "#{logical}/attempt/1", journal.attempt_identity(logical, 1)
    refute_equal journal.attempt_identity(logical, 1), journal.attempt_identity(logical, 2)
    assert_equal logical, logical.split('/attempt/').first
  end

  def test_identity_rejects_negative_checkpointed_positions
    journal = Tamoz::SQLite::EffectJournal.allocate

    assert_raises(Tamoz::ConfigurationError) do
      journal.logical_identity(**identity(iteration: -1))
    end
    assert_raises(Tamoz::ConfigurationError) do
      journal.logical_identity(**identity(sub_operation: -1))
    end
  end

  def test_identity_rejects_fractional_checkpointed_positions
    journal = Tamoz::SQLite::EffectJournal.allocate

    assert_raises(Tamoz::ConfigurationError) do
      journal.logical_identity(**identity(iteration: 1.9))
    end
    assert_raises(Tamoz::ConfigurationError) do
      journal.logical_identity(**identity(sub_operation: "1"))
    end
  end
end

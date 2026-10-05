# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'support/session_plan'
require_relative 'support/deep_freeze_assertions'

class SharedHelpersTest < Minitest::Test
  include SessionPlan
  include DeepFreezeAssertions

  def test_session_plan_preserves_the_single_step_contract
    arguments = { 'path' => 'note.txt' }
    expected = {
      'goal' => 'answer the task',
      'done_when' => ['the tool returned evidence'],
      'steps' => [
        {
          'id' => 's1',
          'purpose' => 'gather evidence',
          'tool' => 'read_file',
          'arguments' => arguments,
          'verification' => 'the output is present'
        }
      ]
    }

    assert_equal expected, plan_for('read_file', arguments)
  end

  def test_session_plan_preserves_explicit_identity_and_arguments
    arguments = { 'path' => 'note.txt' }
    step = plan_for('read_file', arguments, id: 'inspect').fetch('steps').first

    assert_equal 'inspect', step.fetch('id')
    assert_same arguments, step.fetch('arguments')
  end

  def test_session_plans_do_not_share_mutable_containers
    first = plan_for('read_file', {})
    second = plan_for('read_file', {})
    first.fetch('done_when') << 'another condition'
    first.fetch('steps').first['tool'] = 'list_directory'
    first.fetch('steps') << { 'id' => 'extra' }

    assert_equal ['the tool returned evidence'], second.fetch('done_when')
    assert_equal 1, second.fetch('steps').length
    assert_equal 'read_file', second.fetch('steps').first.fetch('tool')
  end

  def test_deep_freeze_accepts_frozen_hash_keys_values_and_array_entries
    key = ['key'].freeze
    value = { key => [{ 'entry' => [true, nil, 1].freeze }.freeze].freeze }.freeze

    assert_deeply_frozen(value)
  end

  def test_deep_freeze_rejects_an_unfrozen_root
    assert_raises(Minitest::Assertion) { assert_deeply_frozen({}) }
  end

  def test_deep_freeze_rejects_an_unfrozen_nested_hash_key
    value = { [] => 'value' }.freeze

    assert_raises(Minitest::Assertion) { assert_deeply_frozen(value) }
  end

  def test_deep_freeze_rejects_an_unfrozen_nested_hash_value
    value = { 'key' => {} }.freeze

    assert_raises(Minitest::Assertion) { assert_deeply_frozen(value) }
  end

  def test_deep_freeze_rejects_an_unfrozen_nested_array_entry
    value = { 'key' => [[+'entry'].freeze].freeze }.freeze

    assert_raises(Minitest::Assertion) { assert_deeply_frozen(value) }
  end
end

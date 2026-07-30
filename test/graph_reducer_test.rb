# frozen_string_literal: true

require_relative "test_helper"

class GraphReducerTest < Minitest::Test
  def test_append_merge_union_min_and_max_contracts
    assert_equal [1, 2, 3], Tamoz::Reducers.append.call([1], [[2], [3]])
    assert_equal(
      {"a" => 1, "b" => 3, "c" => 4},
      Tamoz::Reducers.merge.call({"a" => 1}, [{"b" => 2}, {"b" => 3, "c" => 4}])
    )
    assert_equal [1, 2, 3], Tamoz::Reducers.union.call([1], [[2, 1], [3, 2]])
    assert_equal 9, Tamoz::Reducers.max.call(3, [9, 4])
    assert_equal 1, Tamoz::Reducers.min.call(3, [9, 1])
  end

  def test_reducers_do_not_mutate_inputs
    current = [{"value" => 1}].freeze
    writes = [[{"value" => 2}].freeze].freeze

    result = Tamoz::Reducers.append.call(current, writes)
    assert_equal [{"value" => 1}, {"value" => 2}], result
    assert_equal [{"value" => 1}], current
    assert_equal [[{"value" => 2}]], writes
  end

  def test_built_in_reducers_reject_wrong_shapes
    assert_raises(Tamoz::InvalidUpdateError) { Tamoz::Reducers.append.call([], [1]) }
    assert_raises(Tamoz::InvalidUpdateError) { Tamoz::Reducers.merge.call({}, [[]]) }
    assert_raises(Tamoz::InvalidUpdateError) { Tamoz::Reducers.union.call({}, [[]]) }
  end

  def test_union_is_associative_for_generated_batches
    100.times do |seed|
      random = Random.new(seed)
      left = Array.new(10) { random.rand(0..10) }
      middle = Array.new(10) { random.rand(0..10) }
      right = Array.new(10) { random.rand(0..10) }
      reducer = Tamoz::Reducers.union

      first = reducer.call(reducer.call([], [left]), [middle, right])
      second = reducer.call([], [left, middle, right])
      assert_equal second, first, "seed=#{seed}"
    end
  end
end

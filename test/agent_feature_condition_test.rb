# frozen_string_literal: true

require_relative 'test_helper'

class AgentFeatureConditionTest < Minitest::Test
  Condition = Tamoz::Agent::FeatureCondition
  ALLOWED = %w[a b flag].freeze

  def condition(text) = Condition.parse(text, allowed: ALLOWED)
  def holds?(text, values) = condition(text).holds?(values)

  def assert_invalid(text, message)
    error = assert_raises(Condition::Invalid) { condition(text) }
    assert_includes error.message, message
  end

  def test_and_binds_tighter_than_or_and_product_tighter_than_sum
    assert holds?('true || false && false', {})
    assert holds?('features.a - 1.0 * 2.0 == -1.0', { 'a' => 1 })
    assert holds?('features.a / features.b > 1.15 && !(features.a < 0.0)', { 'a' => 2.4, 'b' => 2.0 })
    refute holds?('features.a / features.b > 1.15', { 'a' => 2.2, 'b' => 2.0 })
  end

  def test_boolean_features_negation_and_equality
    assert holds?('!features.flag && features.flag == false', { 'flag' => false })
    refute holds?('features.flag != false', { 'flag' => false })
  end

  def test_division_by_zero_is_an_infinite_double_as_in_cel
    assert holds?('features.a / 0.0 > 1.0', { 'a' => 1 })
  end

  def test_the_condition_names_every_feature_it_reads_once
    assert_equal %w[a b], condition('features.a > 1.0 && (features.b < 2.0 || features.a < 0.0)').features
  end

  def test_a_failure_names_its_reason
    assert_equal 'features.a absent', condition('features.a > 1.0').failure({ 'b' => 2 })
    assert_equal 'it mixes a number and a boolean', condition('features.flag > 1.0').failure({ 'flag' => true })
    assert_equal 'it evaluates to false', condition('features.a > 1.0').failure({ 'a' => 0.5 })
    assert_equal 'it evaluates to 3.0', condition('features.a').failure({ 'a' => 3 })
    assert_nil condition('features.a > 1.0').failure({ 'a' => 2 })
  end

  def test_a_feature_outside_the_allowed_names_is_refused
    assert_invalid 'features.secret > 1.0', 'features.secret is not an allowed feature'
  end

  def test_an_int_literal_or_one_out_of_range_is_refused_because_cel_never_mixes_int_and_double
    assert_invalid 'features.a - 1 > 0.0', 'write 1 as a double, such as 1.0'
    assert_invalid 'features.a > 1.0e999', 'out of range'
  end

  def test_anything_outside_the_subset_is_refused
    assert_invalid 'situation.phase == 1.0', 'unexpected'
    assert_invalid 'features.a = 1.0', 'unexpected'
    assert_invalid 'size(features) > 1.0', 'unexpected'
    assert_invalid 'features.a < features.b < 1.0', 'unexpected <'
    assert_invalid '(features.a > 1.0', 'parenthesis is not closed'
    assert_invalid 'features.a >', 'ends early'
    assert_invalid 'features.a > 1.0 features.b', 'unexpected features.b'
    assert_invalid '  ', 'empty'
    assert_invalid "#{'(' * 33}features.a#{')' * 33} > 1.0", 'nests deeper than 32'
    assert_invalid "features.a > #{'1' * Condition::MAX_BYTES}.0", 'over'
  end
end

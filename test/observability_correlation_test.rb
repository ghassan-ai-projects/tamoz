# frozen_string_literal: true

require_relative 'test_helper'

class ObservabilityCorrelationTest < Minitest::Test
  Correlation = Tamoz::Observability::Correlation

  def test_trace_id_is_derived_deterministically
    first = Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.1')
    second = Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.1')

    assert_equal first, second
    assert_equal 16, first.length
    assert_match(/\A[0-9a-f]+\z/, first)
  end

  def test_trace_id_matches_the_specified_formula
    expected = Digest::SHA256.hexdigest(
      "tamoz.trace.v1\n#{Correlation.canonical(['thread.1', 'execution.1'])}"
    )[0, 16]

    assert_equal expected, Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.1')
  end

  def test_trace_id_follows_turn_identity
    base = Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.1')

    refute_equal base, Correlation.trace_id(thread_id: 'thread.2', execution_id: 'execution.1')
    refute_equal base, Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.2')
  end

  def test_span_id_is_derived_deterministically
    trace_id = Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.1')
    first = Correlation.span_id(trace_id:, kind: :turn, anchor: 'execution.1')
    second = Correlation.span_id(trace_id:, kind: :turn, anchor: 'execution.1')

    assert_equal first, second
    assert_equal 8, first.length
    assert_match(/\A[0-9a-f]+\z/, first)
  end

  def test_span_id_follows_kind_and_anchor
    trace_id = Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.1')
    base = Correlation.span_id(trace_id:, kind: :turn, anchor: 'execution.1')

    refute_equal base, Correlation.span_id(trace_id:, kind: :plan, anchor: 'execution.1')
    refute_equal base, Correlation.span_id(trace_id:, kind: :turn, anchor: 'execution.2')
  end

  def test_identity_is_reproducible_in_a_fresh_process
    script = <<~RUBY
      require "tamoz/observability"
      print Tamoz::Observability::Correlation.trace_id(
        thread_id: "thread.1", execution_id: "execution.1"
      )
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      *GEM_ROOTS.values.flat_map { |gem_root| ['-I', gem_root.join('lib').to_s] },
      '-e', script
    )

    assert_predicate status, :success?, stderr
    assert_equal Correlation.trace_id(thread_id: 'thread.1', execution_id: 'execution.1'), stdout
  end
end

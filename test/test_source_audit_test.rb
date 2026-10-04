# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'support/test_source_audit'
require_relative 'support/test_suite'

class TestSourceAuditTest < Minitest::Test
  def test_detects_a_predicate_block_attached_to_the_assertion
    source = "assert rows.all? do |row|\n  row[:status] == :correct\nend\n"

    assert_equal [1], TestSourceAudit.ignored_predicates(source)
  end

  def test_accepts_a_parenthesized_predicate_block
    source = "assert(rows.all? do |row|\n  row[:status] == :correct\nend)\n"

    assert_empty TestSourceAudit.ignored_predicates(source)
  end

  def test_accepts_a_braced_predicate_block
    assert_empty TestSourceAudit.ignored_predicates('assert rows.all? { |row| row[:status] == :correct }')
  end

  def test_accepts_an_assertion_that_intentionally_owns_a_block
    assert_empty TestSourceAudit.ignored_predicates('assert_raises(Error) { rows.map(&:value) }')
  end

  def test_rejects_invalid_source_instead_of_reporting_a_clean_audit
    assert_raises(ArgumentError) { TestSourceAudit.ignored_predicates('def broken(') }
  end

  def test_plan_vocabulary_flags_citations_in_comments
    source = <<~RUBY
      # frozen_string_literal: true

      # P11 §3: the memory contract. See DR-5 slice 4, Phase 2 wave B (T4.1, F2, Q0, DC-6, D-7).
      class SampleTest < Minitest::Test
        def test_something
          assert_equal 4, 2 + 2 # macro-F1 stays
        end
      end
    RUBY

    assert_equal [3], TestSourceAudit.plan_vocabulary(source)
  end

  def test_plan_vocabulary_accepts_behavioral_comments_and_benchmark_identities
    source = <<~RUBY
      # C1 through C9 are the benchmark ladder identities; macro-F1 is a metric.
      class SampleTest < Minitest::Test
        def test_something
          # the sweep really does reclaim them once they age past the floor
          assert true
        end
      end
    RUBY

    assert_empty TestSourceAudit.plan_vocabulary(source)
  end

  def test_plan_vocabulary_rejects_invalid_source
    assert_raises(ArgumentError) { TestSourceAudit.plan_vocabulary('def broken(') }
  end

  def test_all_test_predicate_blocks_are_executed
    findings = TestSuite.files.flat_map do |path|
      source = File.read(File.join(TestSuite::ROOT, path), encoding: Encoding::UTF_8)
      TestSourceAudit.ignored_predicates(source).map { |line| "#{path}:#{line}" }
    end

    assert_empty findings, 'parenthesize the predicate or use braces so Ruby executes its block'
  end

  def test_no_test_file_cites_planning_vocabulary_in_comments
    files = (Dir[File.join(TestSuite::ROOT, 'test/**/*.rb')].map do |path|
      path.delete_prefix("#{TestSuite::ROOT}/")
    end + TestSuite.files).uniq.sort
    findings = files.flat_map do |path|
      source = File.read(File.join(TestSuite::ROOT, path), encoding: Encoding::UTF_8)
      TestSourceAudit.plan_vocabulary(source).map { |line| "#{path}:#{line}" }
    end

    assert_empty findings,
                 'name the behavior, not the plan: remove rollout codes, task rows and dead document citations'
  end
end

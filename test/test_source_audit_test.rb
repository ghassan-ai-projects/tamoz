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

  def test_all_test_predicate_blocks_are_executed
    findings = TestSuite.files.flat_map do |path|
      source = File.read(File.join(TestSuite::ROOT, path), encoding: Encoding::UTF_8)
      TestSourceAudit.ignored_predicates(source).map { |line| "#{path}:#{line}" }
    end

    assert_empty findings, 'parenthesize the predicate or use braces so Ruby executes its block'
  end
end

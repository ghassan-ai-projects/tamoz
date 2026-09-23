# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/context_engine_fixtures'

class ContextSpillTest < Minitest::Test
  include ContextEngineFixtures

  def output = (1..900).map { |index| "line #{index}: #{'-' * 30}\n" }.join

  def test_small_output_stays_inline
    result = CE::Spill.new(store:).apply("ok\n", summary: 'exit 0')

    assert_equal ["ok\n", nil], [result.text, result.spilled]
  end

  def spilled(max_inline_bytes: 8192)
    CE::Spill.new(store:, max_inline_bytes:).apply(output,
                                                   summary: 'exit 1 · 2 failures')
  end

  def test_large_output_stub_is_bounded_and_names_the_facts
    result = spilled

    assert_operator result.text.bytesize, :<=, 8192
    assert_match(/\A\[output spilled: artifact:#{result.spilled} · \d+\.\d KB · 900 lines · exit 1 · 2 failures\]/,
                 result.text)
  end

  def test_stub_previews_both_ends_and_says_how_to_recall
    text = spilled.text

    assert_includes text, 'line 1: '
    assert_includes text, 'line 900: '
    assert_includes text, 'recall_output'
  end

  def test_recall_returns_the_exact_bytes
    result = spilled
    lines = CE::Spill.recall(store, "artifact:#{result.spilled}", limit: 10_000).lines.drop(1)

    assert_equal output, "#{lines.map { |line| line.split("\t", 2).last.chomp }.join("\n")}\n"
    assert_equal output, store.resolve(result.spilled).fetch('bytes')
  end

  def test_recall_by_range_and_pattern
    locator = "artifact:#{spilled.spilled}"

    assert_equal "line 450: #{'-' * 30}",
                 CE::Spill.recall(store, locator, offset: 450, limit: 1).lines.last.split("\t").last
    assert_equal 9, CE::Spill.recall(store, locator, pattern: 'line \\d0:', limit: 10).lines.length - 1
  end

  def test_recall_refuses_bad_locators
    assert_raises(CE::Error) { CE::Spill.recall(store, 'sha256:abc') }
    assert_raises(CE::Error) { CE::Spill.recall(store, "artifact:sha256:#{'0' * 64}") }
  end

  def test_long_lines_do_not_blow_the_stub_budget
    spill = CE::Spill.new(store:, max_inline_bytes: 2048)
    result = spill.apply("#{'x' * 50_000}\n#{'y' * 50_000}\n", summary: "#{'z' * 900}\nsecond line")

    assert_operator result.text.bytesize, :<=, 2048
  end

  def test_head_and_tail_never_repeat_a_line
    long_lines = (1..10).map { |index| "#{index}:#{'q' * 700}\n" }.join
    text = CE::Spill.new(store:, max_inline_bytes: 4096).apply(long_lines, summary: 'x').text
    shown = text.lines.filter_map { |line| line[/\A(\d+):q/, 1] }

    assert_equal shown.uniq, shown
  end
end

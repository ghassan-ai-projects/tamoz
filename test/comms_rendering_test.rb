# frozen_string_literal: true

require_relative 'test_helper'

# Slice E (COMMS_TELEGRAM_PLAN §3) — deterministic chat rendering (design
# §11): the same input produces byte-identical parts for the same render
# version, parts never split a grapheme cluster, and overflow truncates.
# rubocop:disable Minitest/MultipleAssertions
class CommsRenderingTest < Minitest::Test
  Comms = Tamoz::Comms

  def test_short_text_is_one_part_with_a_content_digest
    parts = Comms::Rendering.plain('hello', max_parts: 5, part_characters: 3500)

    assert_equal 1, parts.length
    assert_equal 'hello', parts.first.fetch('text')
    assert_match(/\A[0-9a-f]{64}\z/, parts.first.fetch('content_digest'))
    assert_equal 0, parts.first.fetch('part_index')
    assert_equal 1, parts.first.fetch('part_count')
  end

  def test_splitting_is_deterministic_and_respects_the_ceiling
    text = 'para one. ' * 200
    first = Comms::Rendering.plain(text, max_parts: 5, part_characters: 100)
    second = Comms::Rendering.plain(text, max_parts: 5, part_characters: 100)

    assert_equal first, second, 'same input, same parts, byte-identical'
    assert_operator first.length, :<=, 5
    first.each do |part|
      assert_operator part.fetch('text').length, :<=, 100
    end
    assert_equal first.length, first.last.fetch('part_count')
  end

  def test_overflow_truncates_to_max_parts
    text = 'x' * 10_000
    parts = Comms::Rendering.plain(text, max_parts: 3, part_characters: 100)

    assert_equal 3, parts.length
    assert_equal(300, parts.sum { |part| part.fetch('text').length })
  end

  def test_overflow_appends_a_marker_naming_the_thread_and_recovery
    parts = Comms::Rendering.plain('x' * 10_000, max_parts: 3, part_characters: 100, thread: 'th-42')
    joined = parts.map { |part| part.fetch('text') }.join

    assert_includes joined, 'tamoz show th-42'
    assert_includes joined, '…'
    assert_equal 3, parts.length
    parts.each { |part| assert_operator part.fetch('text').length, :<=, 100 }
  end

  def test_untruncated_text_carries_no_overflow_marker
    parts = Comms::Rendering.plain('hello', max_parts: 3, part_characters: 100, thread: 'th')

    refute_includes parts.map { |part| part.fetch('text') }.join, 'truncated'
  end

  def test_parts_never_split_a_grapheme_cluster
    cluster = "\u{1F469}\u{200D}\u{1F4BB}"
    text = cluster * 10
    parts = Comms::Rendering.plain(text, max_parts: 10, part_characters: 5)

    parts.each do |part|
      assert_equal 0, part.fetch('text').length % cluster.length,
                   'a multi-codepoint grapheme must stay whole'
    end
    assert_equal text, parts.map { |part| part.fetch('text') }.join
  end

  def test_content_digest_is_stable_per_part
    a = Comms::Rendering.plain('same text', max_parts: 5, part_characters: 3500)
    b = Comms::Rendering.plain('same text', max_parts: 5, part_characters: 3500)

    assert_equal a.first.fetch('content_digest'), b.first.fetch('content_digest')
  end

  def test_render_version_is_pinned
    assert_equal 1, Comms::Rendering::RENDER_VERSION
  end
end
# rubocop:enable Minitest/MultipleAssertions

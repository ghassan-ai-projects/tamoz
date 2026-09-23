# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/context_engine_fixtures'

class ContextCompactionTest < Minitest::Test
  include ContextEngineFixtures

  def valid_summary(extra = '')
    CE::Compaction::SECTIONS.map { |section| "## #{section}\n- (none)" }.join("\n") + extra
  end

  def selection(entries = turn) = CE::Compaction.select(entries, retain_tokens: 700, resolve:)

  def turn = scripted_turn(10, result_bytes: 800)

  def test_selection_skips_pinned_entries
    picked = selection

    assert_equal CE::Surface.visible(turn)[2].fetch('seq'), picked.first_seq
    refute(picked.entries.any? { |entry| entry['pinned'] })
  end

  def test_selection_keeps_a_retained_tail
    kept = CE::Surface.visible(turn).drop_while { |entry| entry.fetch('seq') <= selection.last_seq }

    assert_operator kept.sum { |entry| CE::TokenMeter.heuristic(CE::Surface.message(entry, resolve)) }, :>=, 250
  end

  def test_selection_never_ends_between_a_call_and_its_result
    entries = scripted_turn(10, result_bytes: 800)
    (50..900).step(37) do |retain|
      selection = CE::Compaction.select(entries, retain_tokens: retain, resolve:)
      next unless selection

      visible = CE::Surface.visible(entries)
      cut = visible.index { |entry| entry.fetch('seq') == selection.last_seq } + 1

      assert CE::Surface.balanced_cut?(visible, cut), "unbalanced cut at retain=#{retain}"
      assert_equal 'tool_result', selection.entries.last.fetch('kind')
    end
  end

  def tail_bytes(entries, after_position)
    CE::Surface.visible(entries).select { |entry| CE::Surface.position(entry) > after_position }
                                .map { |entry| Tamoz::Core.jcs(CE::Surface.message(entry, resolve)) }
  end

  def test_compaction_after_a_prune_keeps_the_retained_tail_byte_identical
    entries = pruned(scripted_turn(6, result_bytes: 6000), scripted_turn(6)[8].fetch('seq'))
    picked = CE::Compaction.select(entries, retain_tokens: 6000, resolve:)
    after = compacted(entries, retain_tokens: 6000)

    assert_equal tail_bytes(entries, picked.last_seq), tail_bytes(after, picked.last_seq)
    refute_empty tail_bytes(after, picked.last_seq)
  end

  def test_a_second_compaction_absorbs_the_first_checkpoint
    entries = tool_round(compacted(turn), 'late', 'read_file', {}, 'z' * 3000)
    entries = tool_round(entries, 'later', 'read_file', {}, 'y' * 3000)
    twice = compacted(entries, retain_tokens: 800)
    kinds = CE::Surface.visible(twice).map { |entry| entry.fetch('kind') }

    assert_equal 1, kinds.count('checkpoint')
    assert_equal 'checkpoint', kinds[2]
  end

  def test_the_span_ends_at_or_before_the_retained_budget_for_any_budget
    entries = pruned(turn, turn[10].fetch('seq'))
    (100..3000).step(173) do |retain_tokens|
      picked = CE::Compaction.select(entries, retain_tokens:, resolve:)
      next unless picked

      kept = CE::Surface.visible(entries).select { |entry| CE::Surface.position(entry) > picked.last_seq }

      assert_operator kept.sum { |entry| CE::TokenMeter.heuristic(CE::Surface.message(entry, resolve)) }, :>=,
                      [retain_tokens, 1].min, "retain=#{retain_tokens}"
    end
  end

  def test_required_strings_come_from_the_span_mutation_paths
    entries = tool_round(scripted_turn(2), 'p', 'apply_patch', { 'path' => 'lib/foo.rb' }, 'Applied')
    entries = tool_round(entries, 'q', 'read_file', { 'path' => 'lib/bar.rb' }, 'x' * 4000)
    entries = tool_round(entries, 'r', 'read_file', { 'path' => 'lib/baz.rb' }, 'small')
    picked = CE::Compaction.select(entries, retain_tokens: 10, resolve:)

    assert_equal ['lib/foo.rb'], CE::Compaction.required_strings(picked, tools: %w[apply_patch create_file], resolve:)
    assert_operator picked.source_bytes(resolve), :>, 4000
  end

  def test_nothing_to_compact_when_everything_fits_the_retained_budget
    assert_nil CE::Compaction.select(scripted_turn(2), retain_tokens: 100_000, resolve:)
  end

  def test_summary_request_is_a_byte_prefix_extension_of_the_conversation
    entries = scripted_turn(10, result_bytes: 800)
    request = CE::Compaction.summary_messages(entries, header:, selection: selection(entries), resolve:)
    conversation = Tamoz::Core.jcs(CE::Surface.messages(entries, header:, resolve:).first(request.length - 1))

    assert_equal conversation, Tamoz::Core.jcs(request[0...-1])
    assert_equal CE::Prompts.fetch('compaction_instruction'), request.last.fetch('content')
  end

  def compacted_messages
    entries = turn
    entries += [CE::Compaction.checkpoint_entry(valid_summary, selection: selection(entries), entries:, store:)]
    CE::Surface.messages(entries, header:, resolve:)
  end

  def test_checkpoint_keeps_node_zero_and_pinned_entries
    messages = compacted_messages

    assert_equal header.system_message, messages[0]
    assert_includes messages[2].fetch('content'), 'Never change the public signature'
  end

  def test_checkpoint_renders_the_preamble_and_summary_in_place_of_the_span
    content = compacted_messages[3].fetch('content')

    assert content.start_with?(CE::Prompts.fetch('checkpoint_preamble'))
    assert_includes content, '<compacted-summary>'
  end

  def test_validate_refuses_a_summary_that_does_not_shrink_or_misses_a_section
    assert_raises(CE::InvalidSummaryError) { CE::Compaction.validate!(valid_summary, source_bytes: 10) }
    assert_raises(CE::InvalidSummaryError) do
      CE::Compaction.validate!(valid_summary.sub('## Ruled Out', '## Nope'), source_bytes: 10_000)
    end
  end

  def test_validate_requires_exact_strings
    summary = valid_summary("\nlib/foo.rb")

    assert_raises(CE::InvalidSummaryError) do
      CE::Compaction.validate!(valid_summary, source_bytes: 10_000, required_strings: ['lib/foo.rb'])
    end
    assert_equal summary, CE::Compaction.validate!(summary, source_bytes: 10_000, required_strings: ['lib/foo.rb'])
  end
end

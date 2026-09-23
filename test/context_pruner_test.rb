# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/context_engine_fixtures'

class ContextPrunerTest < Minitest::Test
  include ContextEngineFixtures

  BUDGET = Tamoz::ContextEngine::Pruner::Budget.new(threshold_chars: 2048, head_chars: 512, tail_chars: 256)

  def prune(entries, before_seq)
    CE::Pruner.prune(entries, store:, resolve:, before_seq:, budget: BUDGET)
  end

  def test_old_oversized_results_are_trimmed_within_the_threshold
    entries = scripted_turn(4, result_bytes: 6000)
    replacements = prune(entries, entries.last.fetch('seq'))

    assert_equal 3, replacements.length
    assert(replacements.all? do |replacement|
      replacement.text.length <= 2048 && replacement.text.include?('middle pruned')
    end)
  end

  def test_pruning_converges_in_one_pass
    entries = scripted_turn(4, result_bytes: 6000)
    entries += prune(entries, entries.last.fetch('seq')).map(&:entry)

    assert_empty(prune(entries, CE::Surface.next_seq(entries))
      .reject { |replacement| replacement.replaced_seq == scripted_turn(4).last.fetch('seq') })
  end

  def pruned_message
    entries = scripted_turn(2, result_bytes: 6000)
    entries += [prune(entries, entries.last.fetch('seq')).first.entry]
    [entries[3], CE::Surface.messages(entries, header:, resolve:)[4].fetch('content')]
  end

  def test_pruned_result_keeps_head_and_tail
    original, content = pruned_message
    full = CE::Surface.text(original, resolve)

    assert content.start_with?(full[0, 512])
    assert content.end_with?(full[-256, 256])
  end

  def test_pruned_result_keeps_its_call_pairing_and_a_recall_locator
    original, content = pruned_message
    entries = scripted_turn(2, result_bytes: 6000)
    replacement = prune(entries, entries.last.fetch('seq')).first.entry

    assert_equal original.fetch('tool_call_id'), replacement.fetch('tool_call_id')
    assert_includes content, "artifact:#{original.fetch('text_ref')}"
    assert_equal CE::Surface.text(original, resolve), store.resolve(original.fetch('text_ref')).fetch('bytes')
  end

  def test_results_at_or_after_the_retained_boundary_are_untouched
    entries = scripted_turn(2, result_bytes: 6000)

    assert_empty prune(entries, entries[3].fetch('seq'))
  end

  def test_budgets_must_converge
    assert_raises(CE::Error) { CE::Pruner::Budget.new(threshold_chars: 1000, head_chars: 600, tail_chars: 300) }
  end
end

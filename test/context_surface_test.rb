# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/context_engine_fixtures'

class ContextSurfaceTest < Minitest::Test
  include ContextEngineFixtures

  def sixty_step_turn
    entries = scripted_turn(0)
    Array.new(60) do |index|
      entries = tool_round(entries, "c#{index}", 'read_file', { 'path' => "a#{index}" }, 'x' * (index * 150))
      entries = pruned(entries, entries[-3].fetch('seq')) if index == 20
      entries = compacted(entries, retain_tokens: 2000) if index == 40
      entries
    end
  end

  def request_bytes(entries) = CE::Surface.messages(entries, header:, resolve:).map { |m| Tamoz::Core.jcs(m) }

  def extends?(before, after)
    previous = request_bytes(before)
    request_bytes(after).first(previous.length) == previous
  end

  def test_every_request_extends_the_last_except_at_a_logged_replacement
    breaks = sixty_step_turn.each_cons(2).reject { |before, after| extends?(before, after) }

    assert_equal 2, breaks.length
    assert(breaks.all? { |before, after| replacement_added?(before, after) })
  end

  def test_a_replacement_keeps_every_message_before_its_first_shadowed_position
    before, after = sixty_step_turn[39, 2]
    first = (after - before).find { |entry| entry['source'] == 'compaction' }.fetch('replaces').first
    kept = CE::Surface.visible(before).count { |entry| CE::Surface.position(entry) < first } + 1

    assert_equal request_bytes(before).first(kept), request_bytes(after).first(kept)
  end

  def test_consecutive_requests_are_byte_prefixes_without_replacements
    entries = scripted_turn(0)
    previous = CE::Surface.messages(entries, header:, resolve:)
    30.times do |index|
      entries = tool_round(entries, "c#{index}", 'read_file', { 'path' => "a#{index}" }, 'x' * index)
      current = CE::Surface.messages(entries, header:, resolve:)

      assert_equal previous, current.first(previous.length)
      previous = current
    end
  end

  def test_system_update_appends_and_never_moves_the_header
    entries = scripted_turn(2)
    before = CE::Surface.messages(entries, header:, resolve:)
    entries = append(entries, 'system_update', '[operator update] reasoning depth: high')
    after = CE::Surface.messages(entries, header:, resolve:)

    assert_equal before, after.first(before.length)
    assert_equal header.system_message, after.first
    assert_equal({ 'role' => 'user', 'content' => '[operator update] reasoning depth: high' }, after.last)
  end

  def test_replacement_shadows_its_range_and_renders_in_place
    entries = scripted_turn(3)
    visible = CE::Surface.visible(entries)
    checkpoint = CE::Surface.entry(kind: 'checkpoint', seq: CE::Surface.next_seq(entries), text: 'summary',
                                   store:, replaces: [visible[2].fetch('seq'), visible[5].fetch('seq')])
    entries += [checkpoint]
    entries = append(entries, 'user', 'after')
    kinds = CE::Surface.visible(entries).map { |entry| entry.fetch('kind') }

    assert_equal %w[runtime user checkpoint assistant tool_result user], kinds
    assert_equal 10, entries.length
  end

  def checkpoint(entries, text, first_index, last_index)
    visible = CE::Surface.visible(scripted_turn(4))
    entries + [CE::Surface.entry(kind: 'checkpoint', seq: CE::Surface.next_seq(entries), text:, store:,
                                 replaces: [visible[first_index].fetch('seq'), visible[last_index].fetch('seq')])]
  end

  def test_later_checkpoint_can_shadow_an_earlier_one
    entries = checkpoint(scripted_turn(4), 'one', 2, 3)
    entries = checkpoint(tool_round(entries, 'late', 'read_file', {}, 'z'), 'two', 2, 7)
    texts = CE::Surface.visible(entries).map { |entry| CE::Surface.text(entry, resolve) }

    refute_includes texts, 'one'
    assert_equal 'two', texts[2]
  end

  def test_assistant_tool_calls_render_in_openai_shape
    entries = tool_round([], 'call_1', 'read_file', { 'path' => 'a.rb' }, 'content')
    assistant, tool = CE::Surface.messages(entries, header:, resolve:).drop(1)

    assert_nil assistant.fetch('content')
    assert_equal({ 'id' => 'call_1', 'type' => 'function',
                   'function' => { 'name' => 'read_file', 'arguments' => '{"path":"a.rb"}' } },
                 assistant.fetch('tool_calls').first)
    assert_equal({ 'role' => 'tool', 'tool_call_id' => 'call_1', 'content' => 'content' }, tool)
  end

  def test_balanced_cut_never_separates_a_call_from_its_result
    entries = CE::Surface.visible(tool_round([], 'c', 'read_file', {}, 'r'))

    assert CE::Surface.balanced_cut?(entries, 0)
    refute CE::Surface.balanced_cut?(entries, 1)
    assert CE::Surface.balanced_cut?(entries, 2)
  end

  def test_entries_carry_refs_not_text
    entries = scripted_turn(1, result_bytes: 5000)

    entries = tool_round(entries, 'big', 'create_file', { 'content' => 'x' * 30_000 }, 'ok')

    assert(entries.all? { |entry| entry.to_s.bytesize < 400 })
    assert_raises(CE::Error) { CE::Surface.text(entries.last, ->(_) {}) }
  end

  def test_invalid_entries_are_refused
    assert_raises(CE::Error) { CE::Surface.entry(kind: 'bogus', seq: 0, text: '', store:) }
    assert_raises(CE::Error) { CE::Surface.entry(kind: 'user', seq: 0, text: '', store:, secret: 1) }
    assert_raises(CE::Error) { CE::Surface.entry(kind: 'checkpoint', seq: 3, text: 's', store:, replaces: [2, 5]) }
  end
end

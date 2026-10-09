# frozen_string_literal: true

require_relative 'test_helper'

# rubocop:disable Minitest/MultipleAssertions
class TalkInboxTest < Minitest::Test
  Talk = Tamoz::Talk

  def inbox(clock: Talk::Clock.new, **limits) = Talk::Inbox.new(clock:, **limits)

  def envelope(update_id, digest: 'a' * 64, file_id: nil)
    { 'update_id' => update_id, 'raw_payload_hash' => digest,
      'attachment' => file_id && { 'file_id' => file_id } }.compact
  end

  def submit_async(box, wire, audio: nil, timeout_s: 5.0)
    Thread.new { box.submit(wire, audio:, timeout_s:) }.tap { |thread| Thread.pass until thread.status == 'sleep' }
  end

  def test_a_submit_is_admitted_only_when_a_later_poll_confirms_its_batch
    box = inbox
    waiting = submit_async(box, envelope(1))
    first = box.poll(next_offset: nil, limit: 50, timeout_s: 0)

    assert_equal([1], first[:updates].map { |wire| wire['update_id'] })
    assert_nil waiting.join(0.05), 'returned is not confirmed'
    box.poll(next_offset: first[:next_offset], limit: 50, timeout_s: 0)

    assert_equal :admitted, waiting.value
    assert_equal 0, box.size
  end

  def test_a_failed_pass_never_confirms_and_the_audio_is_still_there_to_fetch_again
    box = inbox
    waiting = submit_async(box, envelope(1, file_id: 'talk-1'), audio: 'RIFFbytes'.b)
    box.poll(next_offset: nil, limit: 50, timeout_s: 0)

    assert_equal 'RIFFbytes', box.audio('talk-1')
    again = box.poll(next_offset: nil, limit: 50, timeout_s: 0)

    assert_equal [1], again[:updates].map { |wire| wire['update_id'] }, 'an unconfirmed update is handed out again'
    assert_equal 'RIFFbytes', box.audio('talk-1'), 'held until confirmation, not until fetch'
    assert_nil waiting.join(0.05)
    waiting.kill
  end

  def test_confirmation_frees_the_audio
    box = inbox
    waiting = submit_async(box, envelope(1, file_id: 'talk-1'), audio: 'RIFFbytes'.b)
    batch = box.poll(next_offset: nil, limit: 50, timeout_s: 0)
    box.poll(next_offset: batch[:next_offset], limit: 50, timeout_s: 0)

    assert_equal :admitted, waiting.value
    assert_nil box.audio('talk-1')
  end

  def test_only_returned_entries_are_confirmed_and_only_by_an_offset_this_inbox_handed_out
    box = inbox
    early = submit_async(box, envelope(1))
    batch = box.poll(next_offset: nil, limit: 50, timeout_s: 0)
    late = submit_async(box, envelope(2))
    box.poll(next_offset: 10**16, limit: 0, timeout_s: 0)

    assert_nil early.join(0.05), 'a stale or foreign offset confirms nothing'
    box.poll(next_offset: batch[:next_offset], limit: 0, timeout_s: 0)

    assert_equal :admitted, early.value
    assert_nil late.join(0.05), 'an entry nobody polled is never confirmed'
    late.kill
  end

  def test_a_failed_pass_then_a_stale_high_offset_never_confirms_an_update_that_was_not_admitted
    box = inbox(clock: Talk::Clock.new(now_us: -> { 10 }))
    waiting = submit_async(box, envelope(1))
    box.poll(next_offset: 9_000_000, limit: 50, timeout_s: 0)
    again = box.poll(next_offset: 9_000_000, limit: 50, timeout_s: 0)

    assert_equal([1], again[:updates].map { |wire| wire['update_id'] })
    assert_nil waiting.join(0.05)
    waiting.kill
  end

  def test_next_offset_follows_the_last_returned_entry_of_a_truncated_batch
    box = inbox
    waiting = (1..3).map { |id| submit_async(box, envelope(id)) }
    batch = box.poll(next_offset: nil, limit: 2, timeout_s: 0)

    assert_equal([1, 2], batch[:updates].map { |wire| wire['update_id'] })
    rest = box.poll(next_offset: batch[:next_offset], limit: 50, timeout_s: 0)

    assert_equal([3], rest[:updates].map { |wire| wire['update_id'] })
    assert_equal %i[admitted admitted], waiting.first(2).map(&:value)
    assert_nil waiting.last.join(0.05)
    waiting.last.kill
  end

  def test_a_resend_joins_the_waiting_entry_and_a_changed_resend_is_kept_apart
    box = inbox
    one = submit_async(box, envelope(1))
    again = submit_async(box, envelope(1))
    changed = submit_async(box, envelope(1, digest: 'b' * 64))

    assert_equal 2, box.size
    batch = box.poll(next_offset: nil, limit: 50, timeout_s: 0)
    box.poll(next_offset: batch[:next_offset], limit: 50, timeout_s: 0)

    assert_equal %i[admitted admitted admitted], [one, again, changed].map(&:value)
  end

  def test_a_restarted_inbox_starts_above_the_confirmed_offset_even_if_the_clock_went_back
    clock = Talk::Clock.new(floor: 5_000_000, now_us: -> { 10 })
    box = inbox(clock:)
    waiting = submit_async(box, envelope(1))
    batch = box.poll(next_offset: 5_000_000, limit: 50, timeout_s: 0)

    assert_equal 1, batch[:updates].length, 'the persisted offset cannot hide a new entry'
    assert_operator batch[:next_offset], :>, 5_000_000
    waiting.kill
  end

  def test_an_unconfirmed_submit_times_out_and_stop_releases_every_waiter
    box = inbox

    assert_equal :timeout, box.submit(envelope(1), timeout_s: 0.01)
    waiting = submit_async(box, envelope(2))
    box.stop

    assert_equal :stopping, waiting.value
    assert_equal :stopping, box.submit(envelope(3), timeout_s: 1)
  end

  def test_the_inbox_is_bounded_in_updates_and_audio
    box = inbox(max_updates: 1, max_audio_bytes: 4)

    assert_equal :full, box.submit(envelope(1, file_id: 'f'), audio: 'abcde', timeout_s: 0)
    waiting = submit_async(box, envelope(2))

    assert_equal :full, box.submit(envelope(3), timeout_s: 0)
    waiting.kill
  end

  def test_a_poll_with_nothing_queued_waits_and_wakes_on_arrival
    box = inbox
    polling = Thread.new { box.poll(next_offset: nil, limit: 50, timeout_s: 5) }
    Thread.pass until polling.status == 'sleep'
    waiting = submit_async(box, envelope(9))

    assert_equal([9], polling.value[:updates].map { |wire| wire['update_id'] })
    waiting.kill
  end
end
# rubocop:enable Minitest/MultipleAssertions

# frozen_string_literal: true

require_relative 'test_helper'

class TalkEventLogTest < Minitest::Test
  Talk = Tamoz::Talk

  def log(max_events: 500, now: lambda {
    Time.utc(2026, 10, 9, 12)
  })
    Talk::EventLog.new(clock: Talk::Clock.new, max_events:, now:)
  end

  def test_a_page_from_another_boot_or_with_a_cursor_out_of_range_gets_a_reset
    events = log
    events.append_message('kind' => 'answer', 'text' => 'one')
    current = events.since(after: 0, epoch: events.epoch, timeout_s: 0)

    refute current['reset']
    assert events.since(after: 0, epoch: 'other-boot', timeout_s: 0)['reset']
    assert events.since(after: current['next'] + 1, epoch: events.epoch, timeout_s: 0)['reset']
  end

  def test_a_cursor_behind_trimmed_events_resets_and_the_log_stays_bounded
    events = log(max_events: 2)
    first = events.append_message('text' => 'a')
    3.times { |index| events.append_message('text' => index.to_s) }
    page = events.since(after: first['seq'], epoch: events.epoch, timeout_s: 0)

    assert page['reset']
    assert_equal 2, page['events'].length
  end

  def test_working_pulses_live_outside_the_log_and_go_stale
    clock_now = Time.utc(2026, 10, 9, 12)
    events = log(max_events: 3, now: -> { clock_now })
    message = events.append_message('text' => 'kept')
    100.times { events.pulse('talk:chat:1') }
    page = events.since(after: 0, epoch: events.epoch, timeout_s: 0)

    assert_equal([message['message_id']], page['events'].map { |event| event['message_id'] })
    assert page['working']
    clock_now += 11

    assert_nil events.since(after: 0, epoch: events.epoch, timeout_s: 0)['working']
  end

  def test_ids_after_a_restart_are_above_every_earlier_id
    before = log.append_message('text' => 'old')['message_id']
    restarted = Talk::EventLog.new(clock: Talk::Clock.new(floor: before, now_us: -> { 1 }))

    assert_operator restarted.append_message('text' => 'new')['message_id'], :>, before
  end

  def test_a_waiting_page_wakes_on_a_new_event
    events = log
    page = Thread.new { events.since(after: 0, epoch: events.epoch, timeout_s: 5) }
    Thread.pass until page.status == 'sleep'
    events.append_message('text' => 'hello')

    assert_equal(['hello'], page.value['events'].map { |event| event['text'] })
  end
end

# frozen_string_literal: true

require_relative 'test_helper'

class TalkSpeakerTest < Minitest::Test
  Speaker = Tamoz::Talk::Speaker

  def test_speech_is_only_a_registered_spoken_message
    speaker = Speaker.new(synthesize: ->(text) { "ID3#{text}" })
    speaker.register(1, 'Pond 7 is fine.')

    assert_equal 'ID3Pond 7 is fine.', speaker.speech(1)
    assert_equal :not_spoken, speaker.speech(2)
    assert_equal :not_spoken, Speaker.new(synthesize: nil).tap { |s| s.register(1, 'x') }.speech(1)
  end

  def test_two_requests_for_one_message_make_one_paid_call
    calls = Queue.new
    gate = Queue.new
    speaker = Speaker.new(synthesize: lambda { |text|
      calls << text
      gate.pop
      "ID3#{text}"
    })
    speaker.register(1, 'once')
    first = Thread.new { speaker.speech(1) }
    second = Thread.new { speaker.speech(1) }
    sleep 0.05
    gate << :go

    assert_equal %w[ID3once ID3once], [first.value, second.value]
    assert_equal 1, calls.size
  end

  def test_an_edited_text_is_spoken_anew_and_a_failure_is_typed_and_not_cached
    attempts = 0
    speaker = Speaker.new(synthesize: lambda { |text|
      attempts += 1
      raise 'provider down' if text == 'down'

      "ID3#{text}"
    })
    speaker.register(1, 'old')
    speaker.speech(1)
    speaker.register(1, 'new')

    assert_equal 'ID3new', speaker.speech(1)
    speaker.register(2, 'down')
    _out, err = capture_io { assert_equal :failed, speaker.speech(2) }
    _out, = capture_io { speaker.speech(2) }

    assert_equal 3, attempts, 'a failure is not retried at once'
    assert_includes err, 'RuntimeError'
  end

  def test_a_failed_flight_wakes_every_waiter_with_one_paid_call
    calls = Queue.new
    gate = Queue.new
    speaker = Speaker.new(synthesize: lambda { |text|
      calls << text
      gate.pop
      raise 'provider down'
    })
    speaker.register(1, 'once')
    waiters = Array.new(3) { Thread.new { speaker.speech(1) } }
    sleep 0.01 until calls.size == 1 && waiters.count { |thread| thread.status == 'sleep' } == 3
    capture_io do
      gate << :go

      assert_equal %i[failed failed failed], waiters.map(&:value)
    end

    assert_equal 1, calls.size
  end

  def test_the_cache_is_bounded_and_nothing_touches_the_disk
    writes = []
    file = File.singleton_class
    %i[write binwrite open].each do |name|
      file.alias_method(:"talk_original_#{name}", name)
      file.define_method(name) do |*args, **kw, &block|
        (writes << args.first) || send(:"talk_original_#{name}", *args, **kw, &block)
      end
    end
    speaker = Speaker.new(synthesize: ->(text) { "ID3#{text}" })
    40.times do |index|
      speaker.register(index, "text #{index}")
      speaker.speech(index)
    end

    assert_operator speaker.instance_variable_get(:@cache).length, :<=, Speaker::MAX_CACHED
    assert_empty writes
  ensure
    %i[write binwrite open].each do |name|
      file.alias_method(name, :"talk_original_#{name}")
      file.remove_method(:"talk_original_#{name}")
    end
  end
end

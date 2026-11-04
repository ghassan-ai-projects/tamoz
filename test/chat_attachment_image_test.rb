# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/experience_harness'
require_relative 'support/work_loop_fixtures'
require_relative 'support/chat_attachment_helpers'

class ChatAttachmentImageTest < Minitest::Test
  include WorkLoopFixtures
  include ChatAttachmentHelpers

  def with_invoice_photo_turn
    model = ScriptedConversationModel.new(turns: [{ content: 'INVOICE 4471 TOTAL 93.50' }, { content: 'Total 93.50.' }])
    harness = harness_with(model)
    cards = harness.send_photo(PNG, caption: 'what is the total?')
    yield model, cards
  ensure
    harness&.close
  end

  def test_an_image_is_read_by_one_journaled_vision_call_before_the_turn
    with_invoice_photo_turn do |model, _cards|
      vision = JSON.parse(model.requests.first).fetch('messages').last.fetch('content')

      assert_equal %i[attachment_image work_step], model.stages
      assert_equal(%w[text image_url], vision.map { |part| part['type'] })
      assert vision.last.dig('image_url', 'url').start_with?("data:image/png;base64,#{[PNG].pack('m0')[0, 20]}")
    end
  end

  def test_an_image_read_reaches_the_turn_as_material_and_the_answer
    with_invoice_photo_turn do |model, cards|
      material, question = last_turn(model)

      assert_includes material, "<<<attachment\nINVOICE 4471 TOTAL 93.50\nattachment>>>"
      assert_equal '[image] what is the total?', question
      assert_includes cards.map { |card| card[:text] }.join, '93.50'
    end
  end

  def test_a_vision_refusal_is_explained_not_invented
    refusal = ->(_) { raise Tamoz::Agent::ModelCallError.new(code: 'http_failure', status: 400) }
    model = ScriptedConversationModel.new(turns: [refusal, { content: 'I could not read it.' }])
    harness = harness_with(model)

    harness.send_photo(PNG)
    material = JSON.parse(model.requests.last).fetch('messages').select { |m| m['role'] == 'user' }[-2]['content']

    assert_includes material, 'could not be read: the image could not be read'
  ensure
    harness&.close
  end

  def test_an_image_format_outside_the_allow_list_is_never_sent_to_the_model
    model = ScriptedConversationModel.new(turns: [{ content: 'Cannot read that.' }])
    harness = harness_with(model)

    harness.send_document("\x00\x00\x00\x18ftypheic".b, name: 'p.heic', mime_type: 'image/heic')

    assert_equal %i[work_step], model.stages
    assert_includes user_messages(model)[-2], 'this image format cannot be read'
  ensure
    harness&.close
  end

  def wait_for_stop(thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    Thread.pass until Tamoz::Cancellation::Stops.requested?(thread) ||
                      Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def test_cancel_during_the_image_read_stops_the_turn
    harness = nil
    cancel_while_reading = lambda do |_messages|
      harness.admit('/cancel')
      wait_for_stop(harness.thread_for(Tamoz::ExperienceSim::Fixture::CONVERSATION_A))
      { content: 'INVOICE 4471' }
    end
    model = ScriptedConversationModel.new(turns: [cancel_while_reading, { content: 'the final answer' }])
    harness = harness_with(model)
    harness.send_photo(PNG)
    harness.work_off
    texts = harness.transport.outbound.map { |card| card[:text] }

    assert_equal ['Stopping…', 'Stopped.'], texts
    assert_equal %i[attachment_image], model.stages
  ensure
    harness&.close
  end

  def test_a_large_image_is_read_once_and_journaled_by_digest
    model = ScriptedConversationModel.new(turns: [{ content: 'A big picture.' }, { content: 'ok' }])
    harness = harness_with(model)
    big = PNG + ('x' * 1_000_000).b

    harness.send_photo(big)

    assert_equal %i[attachment_image work_step], model.stages
    assert_operator model.requests.first.bytesize, :>, 1_300_000
  ensure
    harness&.close
  end
end

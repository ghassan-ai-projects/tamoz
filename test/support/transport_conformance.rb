# frozen_string_literal: true

# What every Comms::Transport must do, whatever its platform. A test class includes this and defines
# `with_conformance { |transport, driver| ... }`; the driver stages platform input and names the expected identity.
module TransportConformance
  def test_conformance_authenticate_returns_the_configured_identity
    with_conformance do |transport, driver|
      assert_equal driver.identity, transport.authenticate.fetch('stream_id')
    end
  end

  def test_conformance_poll_returns_well_formed_envelopes_and_an_integer_cursor
    with_conformance do |transport, driver|
      driver.stage_text('hello')
      batch = transport.poll(next_offset: nil, limit: 10, timeout_s: 1)

      refute_empty batch.fetch(:updates)
      batch.fetch(:updates).each { |wire| Tamoz::Comms::InboundEnvelope.from_wire(wire) }

      assert_kind_of Integer, batch.fetch(:next_offset)
    end
  end

  def test_conformance_an_unconfirmed_batch_is_redelivered_and_the_cursor_releases_exactly_it
    with_conformance do |transport, driver|
      driver.stage_text('hello', deliveries: 2)
      first = transport.poll(next_offset: nil, limit: 10, timeout_s: 1)
      again = transport.poll(next_offset: nil, limit: 10, timeout_s: 1)
      ids = first.fetch(:updates).map { |wire| wire.fetch('update_id') }

      assert_equal(ids, again.fetch(:updates).map { |wire| wire.fetch('update_id') })
      driver.stage_nothing
      transport.poll(next_offset: again.fetch(:next_offset), limit: 10, timeout_s: 0)

      assert driver.released?(ids, again.fetch(:next_offset)), 'the cursor must confirm every returned update'
    end
  end

  def test_conformance_an_empty_poll_has_no_cursor
    with_conformance do |transport, driver|
      driver.stage_nothing

      assert_nil transport.poll(next_offset: nil, limit: 10, timeout_s: 0).fetch(:next_offset)
    end
  end

  def test_conformance_deliver_returns_a_receipt_with_a_message_id
    with_conformance do |transport, driver|
      driver.stage_receipt
      receipt = transport.deliver(driver.delivery('hello'))

      assert_kind_of Integer, receipt.fetch('message_id')
      assert_kind_of String, receipt.fetch('platform_time')
    end
  end

  def test_conformance_an_attachment_within_the_limit_is_read_and_one_over_it_is_refused
    with_conformance do |transport, driver|
      file_id = driver.stage_attachment('x' * 10)

      assert_equal 'x' * 10, transport.fetch_attachment(file_id, max_bytes: 10)
      assert_raises(Tamoz::Comms::ResponseTooLargeError) { transport.fetch_attachment(file_id, max_bytes: 9) }
    end
  end

  def test_conformance_typing_is_signalled_and_an_unknown_signal_is_unsupported
    with_conformance do |transport, driver|
      driver.stage_typing

      assert_equal :typing, transport.signal(:typing, conversation_id: driver.conversation_id)
      assert_equal :unsupported, transport.signal(:no_such_signal)
    end
  end
end

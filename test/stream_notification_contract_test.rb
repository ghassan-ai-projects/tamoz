# frozen_string_literal: true

require_relative "test_helper"

class StreamNotificationContractTest < Minitest::Test
  def test_all_contract_goldens_conform
    goldens = read_json(
      ROOT.join("gems", "tamoz-stream", "contracts", "notification-goldens-v1.json")
    )

    assert_equal 8, goldens.fetch("events").length
    goldens.fetch("events").each do |envelope|
      event = Tamoz::Stream::OutcomeSubscriber::CloudEvent.new(
        id: envelope.fetch("id"), source: envelope.fetch("source"), type: envelope.fetch("type"),
        data: envelope.fetch("data"), time: envelope.fetch("time"),
        traceparent: envelope["traceparent"], tracestate: envelope["tracestate"],
        envelope: envelope
      )
      assert_same event, Tamoz::Stream::NotificationContract.validate!(event)
    end
  end

  def test_known_but_unsupported_version_is_not_accepted
    refute Tamoz::Stream::NotificationContract.supported_type?(
      "io.agenticstream.outcome.recorded.v2"
    )
    assert Tamoz::Stream::NotificationContract.known_family?(
      "io.agenticstream.outcome.recorded.v2"
    )
  end
end

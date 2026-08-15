# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/episode_worker"
require "support/local_model_endpoint"
require "support/episode_composition"

# P1/§8.2: the wire projection boundary. The EpisodeStreamAdapter is the ONLY
# crossing for graph events; model events are produced from journal receipts
# through the trusted channel (emit_stream_part), never from graph nodes. The
# budget state machine is gone (receipts-based budgets return in P2).
class StreamEpisodeStreamTest < Minitest::Test
  Stream = Tamoz::Stream

  def worker
    Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
  end

  def with_fixture_endpoint(responses: nil)
    Dir.mktmpdir("tamoz-stream-endpoint") do |dir|
      endpoint = LocalModelEndpoint.new(
        mode: :fixture,
        responses: responses || [Tamoz::Core.jcs(
          AquacultureDomain.document(selected: "low_dissolved_oxygen", hypothesis: "oxygen crash")
        )],
        log_path: File.join(dir, "endpoint.log")
      ).start
      yield endpoint
    ensure
      endpoint&.stop
    end
  end

  def test_the_event_stream_has_exact_sequence_identity_and_one_terminal
    with_fixture_endpoint do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      events = []
      composition.fetch(:runner).run(
        EpisodeComposition.wire_request
      ).each { |event| events << event }

      assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
      events.each_with_index do |event, index|
        assert_equal index + 1, event.sequence, "sequence must be exactly 1..N"
        assert_equal "ep-1", event.episode_id
        assert_equal "at-1", event.attempt_id
        assert_equal 1, event.fence
        refute_nil event.occurred_at
      end
      terminals = events.select { |event| event.terminal != nil }
      assert_equal 1, terminals.length, "exactly one terminal"
      composition.fetch(:adapter).close
    end
  end

  def test_model_events_cross_from_receipts_with_digests_and_usage
    with_fixture_endpoint do |endpoint|
      composition = EpisodeComposition.build(endpoint: endpoint.base_url)
      events = []
      composition.fetch(:runner).run(
        EpisodeComposition.wire_request
      ).each { |event| events << event }

      started = events.find { |event| event.started != nil }
      refute_nil started, "the stream must open with episode.started"
      model_started = events.find { |event| event.model_started != nil }
      refute_nil model_started, "a model_started event must cross from the receipt"
      assert_equal 32, model_started.model_started.request_sha256.bytesize,
                   "the receipt's request digest crosses the wire"
      model = events.find { |event| event.model_completed != nil }
      refute_nil model, "a model_completed event must cross"
      assert_equal 32, model.model_completed.response_sha256.bytesize
      # The fixture endpoint reports usage; the receipt carried it across.
      assert_equal 42, model.model_completed.usage.input_tokens
      assert_equal 21, model.model_completed.usage.output_tokens
      composition.fetch(:adapter).close
    end
  end

  def test_a_node_emitted_model_event_is_a_typed_failure_never_a_silent_drop
    stream = Stream::EpisodeStream.new(
      Stream::EpisodeRequestEnvelope.new(EpisodeComposition.wire_request, worker)
    )
    adapter = Stream::EpisodeStreamAdapter.new(stream)
    error = assert_raises(Stream::StreamError) do
      adapter.emit(
        :model_started, [], {ordinal: 0, provider: "test", model_id: "flash"}
      )
    end
    assert_match(/forbidden model event/, error.message)
  end

  def test_the_trusted_channel_projects_receipt_parts_into_the_wire
    stream = Stream::EpisodeStream.new(
      Stream::EpisodeRequestEnvelope.new(EpisodeComposition.wire_request, worker)
    )
    adapter = Stream::EpisodeStreamAdapter.new(stream)
    stream.started
    adapter.emit_stream_part(
      Tamoz::StreamPart.new(
        type: :model_started,
        namespace: [],
        run_id: "ep-1",
        task_id: "reason",
        sequence: 0,
        data: {
          "ordinal" => 0,
          "provider" => "ollama",
          "model_id" => "gemma4",
          "request_sha256" => "sha256:#{"0" * 64}"
        },
        emitted_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
      )
    )
    adapter.emit_stream_part(
      Tamoz::StreamPart.new(
        type: :model_completed,
        namespace: [],
        run_id: "ep-1",
        task_id: "reason",
        sequence: 0,
        data: {
          "ordinal" => 0,
          "response_sha256" => "sha256:#{"1" * 64}",
          "usage" => {"input_tokens" => 5, "output_tokens" => 3, "cost_microunits" => 7}
        },
        emitted_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
      )
    )
    # Terminal is runner-owned (translation of the terminal state), not a
    # receipt StreamPart.
    stream.terminal(:TERMINAL_STATUS_PRODUCED)

    events = stream.events
    assert_equal 1, events.count { |event| event.model_started != nil }
    assert_equal 1, events.count { |event| event.model_completed != nil }
    completed = events.find { |event| event.model_completed != nil }
    assert_equal 5, completed.model_completed.usage.input_tokens
    assert_equal 7, completed.model_completed.usage.cost_microunits
    assert_equal :TERMINAL_STATUS_PRODUCED, events.last.terminal.status
  end

  def test_terminal_status_maps_from_the_durable_result_without_budget_overrides
    adapter = Stream::EpisodeStreamAdapter.new(
      Stream::EpisodeStream.new(
        Stream::EpisodeRequestEnvelope.new(EpisodeComposition.wire_request, worker)
      )
    )
    produced = Struct.new(:status).new(:completed)
    failed = Struct.new(:status).new(:failed)
    assert_equal :TERMINAL_STATUS_PRODUCED, adapter.terminal_status(produced)
    assert_equal :TERMINAL_STATUS_FAILED, adapter.terminal_status(failed)
  end
end

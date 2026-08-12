# frozen_string_literal: true

require_relative "test_helper"

# T1.2 (PLAN_TAMOZ_STREAM_BUILD T1.2): the EpisodeWorker service negotiates
# the handshake over a real in-process gRPC round trip and refuses a contract
# major mismatch. ONE server serves the whole class: gRPC's native runtime
# crashes when RpcServers are created and stopped in rapid succession, so the
# server is a class singleton and is stopped exactly once at exit.
class StreamEpisodeWorkerTest < Minitest::Test
  Worker = Tamoz::Stream::EpisodeWorker

  def self.rpc
    @rpc ||= begin
      server = GRPC::RpcServer.new
      port = server.add_http2_port("127.0.0.1:0", :this_port_is_insecure)
      server.handle(Worker.new(worker_version: "0.1.0.alpha.1"))
      thread = Thread.new { server.run_till_terminated }
      client = Agenticstream::Runtime::V1::EpisodeWorker::Stub.new(
        "127.0.0.1:#{port}", :this_channel_is_insecure
      )
      Minitest.after_run do
        server.stop
        thread.join(5)
      end
      {client:}
    end
  end

  def client
    self.class.rpc.fetch(:client)
  end

  def valid_handshake
    Agenticstream::Runtime::V1::HandshakeRequest.new(
      protocol_version: "1.0",
      contract_version: "1.0",
      worker_id: "tamoz-worker-1",
      non_interactive: true,
      runtime_instance_id: "runtime-1"
    )
  end

  def test_handshake_negotiates_and_echoes_the_identity
    response = client.handshake(valid_handshake)

    assert_equal "1.0", response.protocol_version
    assert_equal "1.0", response.contract_version
    assert_equal "tamoz-worker-1", response.worker_name
    assert_equal "0.1.0.alpha.1", response.worker_version
    assert_equal 4 * 1024 * 1024, response.max_request_bytes
    assert_equal 1 * 1024 * 1024, response.max_event_bytes
  end

  def handshake_with(protocol_version: "1.0", contract_version: "1.0", non_interactive: true)
    Agenticstream::Runtime::V1::HandshakeRequest.new(
      protocol_version:,
      contract_version:,
      worker_id: "tamoz-worker-1",
      non_interactive:,
      runtime_instance_id: "runtime-1"
    )
  end

  def test_a_protocol_major_mismatch_is_refused
    error = assert_raises(GRPC::BadStatus) do
      client.handshake(handshake_with(protocol_version: "2.0"))
    end
    assert_equal GRPC::Core::StatusCodes::FAILED_PRECONDITION, error.code
  end

  def test_a_contract_major_mismatch_is_refused
    error = assert_raises(GRPC::BadStatus) do
      client.handshake(handshake_with(contract_version: "2.0"))
    end
    assert_equal GRPC::Core::StatusCodes::FAILED_PRECONDITION, error.code
  end

  def test_a_non_interactive_false_handshake_is_refused
    error = assert_raises(GRPC::BadStatus) do
      client.handshake(handshake_with(non_interactive: false))
    end
    assert_equal GRPC::Core::StatusCodes::FAILED_PRECONDITION, error.code
  end

  def test_execute_is_unimplemented_until_the_runner_is_wired
    request = Agenticstream::Runtime::V1::EpisodeRequest.new(
      protocol_version: "1.0",
      episode_id: "ep-1",
      attempt_id: "at-1",
      fence: 1
    )
    error = assert_raises(GRPC::BadStatus) { client.execute(request).each.to_a }
    assert_equal GRPC::Core::StatusCodes::UNIMPLEMENTED, error.code
  end
end

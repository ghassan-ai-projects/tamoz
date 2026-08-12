# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/worker_server"
require "tamoz/stream/episode_worker"

# T1.1 (deployment slice): WorkerServer is the launcher — the gRPC host that
# serves the EpisodeWorker handler on a TCP port (development) or a UDS
# socket (production, mTLS at the socket). This suite proves the serving
# shape: bind → run → dial → handshake → stop, on both transports.
class StreamWorkerServerTest < Minitest::Test
  def self.episode_graph
    Tamoz.graph(name: "episode-server", version: "1") do
      state :episode, default: {}
      state :snapshot, default: {}
      state :primary_hypothesis, default: nil
      state :confidence, default: nil
      node(:analyze, implementation_name: "episode.analyze", version: "1") do |_state, context|
        context.emit(:model_started, {ordinal: 0, provider: "test", model_id: "flash"})
        context.emit(:model_completed,
                     {ordinal: 0, usage: {input_tokens: 2, output_tokens: 1}})
        {primary_hypothesis: "bearing wear", confidence: 0.9}
      end
      edge Tamoz::START, :analyze
      edge :analyze, Tamoz::END
    end
  end

  def composed_worker
    directory = Dir.mktmpdir("tamoz-worker-server")
    adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.db"))
    app = self.class.episode_graph.compile(checkpointer: adapter)
    runner = Tamoz::Stream::EpisodeRunner.new(
      durable_runner: app.durable_runner, worker: nil
    )
    worker = Tamoz::Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      runner:,
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
    [worker, adapter, directory]
  end

  def handshake_on(endpoint)
    stub = Agenticstream::Runtime::V1::EpisodeWorker::Stub.new(
      endpoint, :this_channel_is_insecure
    )
    stub.handshake(
      Agenticstream::Runtime::V1::HandshakeRequest.new(
        protocol_version: "1.0", contract_version: "1.0",
        worker_id: "tamoz", runtime_instance_id: "r1",
        non_interactive: true
      )
    )
  end

  def test_the_worker_serves_a_handshake_over_tcp
    worker, adapter, directory = composed_worker
    server = Tamoz::Stream::WorkerServer.new(worker:, port: 0)
    bound, thread = server.start
    assert_kind_of Integer, bound
    assert thread.alive?

    response = handshake_on("127.0.0.1:#{bound}")
    assert_equal "1.0", response.protocol_version
    assert_equal "tamoz", response.worker_name
  ensure
    server&.stop
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  def test_the_worker_serves_a_handshake_over_a_unix_socket
    worker, adapter, directory = composed_worker
    socket_path = File.join(directory, "worker.sock")
    server = Tamoz::Stream::WorkerServer.new(worker:, socket: socket_path)
    _bound, thread = server.start
    assert thread.alive?
    assert File.socket?(socket_path), "the UDS listener must appear"

    response = handshake_on("unix://#{socket_path}")
    assert_equal "1.0", response.protocol_version
  ensure
    server&.stop
    adapter&.close
    FileUtils.remove_entry(directory) if directory
  end

  def test_the_server_refuses_both_or_neither_transport
    worker, = composed_worker
    assert_raises(Tamoz::Stream::WorkerServer::ServerError) do
      Tamoz::Stream::WorkerServer.new(worker:)
    end
    assert_raises(Tamoz::Stream::WorkerServer::ServerError) do
      Tamoz::Stream::WorkerServer.new(worker:, port: 0, socket: "/tmp/x.sock")
    end
    assert_raises(Tamoz::Stream::WorkerServer::ServerError) do
      Tamoz::Stream::WorkerServer.new(worker: Object.new, port: 0)
    end
  end

  def test_the_bin_launcher_composes_and_serves
    script = ROOT.join("bin/tamoz-stream-worker")
    graph = ROOT.join("test/fixtures/episode_diagnose.rb")
    directory = Dir.mktmpdir("tamoz-bin-worker")
    database = File.join(directory, "tamoz.db")
    socket_path = File.join(directory, "worker.sock")

    env = { "RUBYLIB" => Dir[File.join(ROOT, "gems/*/lib")].join(":") }
    pid = Process.spawn(
      env,
      RbConfig.ruby, script.to_s,
      "--graph", graph.to_s, "--database", database,
      "--socket", socket_path,
      out: File::NULL, err: File::NULL
    )
    served = false
    begin
      deadline = Time.now + 20
      loop do
        if File.socket?(socket_path) && handshake_ok?(socket_path)
          served = true
          break
        end
        raise "worker did not serve in 20s" if Time.now > deadline

        sleep 0.2
      end
    ensure
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
    assert served, "the launcher must serve a handshake over the UDS socket"
  ensure
    FileUtils.remove_entry(directory) if directory
  end

  private

  def handshake_ok?(socket_path)
    handshake_on("unix://#{socket_path}").protocol_version == "1.0"
  rescue StandardError
    false
  end
end

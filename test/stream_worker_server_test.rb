# frozen_string_literal: true

require_relative "test_helper"
require "tamoz/stream/worker_server"
require "tamoz/stream/episode_worker"
require "support/aquaculture_domain"
require "support/episode_composition"

# T1.1 (deployment slice): WorkerServer is the launcher — the gRPC host that
# serves the EpisodeWorker handler on a TCP port (development) or a UDS
# socket (production, mTLS at the socket). This suite proves the serving
# shape: bind → run → dial → handshake → stop, on both transports. P1: the
# composed worker runs the FIXED graph (handshake-only — no episode runs).
class StreamWorkerServerTest < Minitest::Test
  def composed_worker
    # The composition's endpoint is never dialed for handshakes; any
    # reachable-looking base is fine.
    composition = EpisodeComposition.build(endpoint: "http://127.0.0.1:1")
    adapter = composition.fetch(:adapter)
    runner = composition.fetch(:runner)
    worker = Tamoz::Stream::EpisodeWorker.new(
      worker_version: "0.1.0.alpha.1",
      runner:,
      lane_config: Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash"
      )
    )
    [worker, adapter, composition.fetch(:directory)]
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
    directory = Dir.mktmpdir("tamoz-bin-worker")
    database = File.join(directory, "tamoz.db")
    socket_path = File.join(directory, "worker.sock")
    root = File.join(directory, "root")
    Dir.mkdir(root)
    profile_path = File.join(directory, "profile.yml")
    File.write(
      profile_path,
      Psych.dump(AquacultureDomain.profile_document(endpoint: "http://127.0.0.1:1", root:))
    )
    File.chmod(0o600, profile_path)

    env = { "RUBYLIB" => Dir[File.join(ROOT, "gems/*/lib")].join(":") }
    pid = Process.spawn(
      env,
      RbConfig.ruby, script.to_s,
      "--profile", profile_path,
      "--database", database,
      "--tenant", "acme",
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
